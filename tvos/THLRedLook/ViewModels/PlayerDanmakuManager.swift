import Foundation
import Combine
import SwiftUI

@MainActor
final class PlayerDanmakuManager: ObservableObject {
    @Published var activeDanmakus: [DanmakuItem] = []
    @Published var danmakuEnabled: Bool
    @Published var danmakuStyle: TVDanmakuStyle
    let universal = TVUniversalDanmaku()

    private let repository: NativeRepository
    private let store: LocalStore
    private var danmakuCache: [DanmakuItem] = []
    private var danmakuPages: [Int64: [DanmakuItem]] = [:]
    private var danmakuRetryAfter: [Int64: Date] = [:]
    private var danmakuTask: Task<Void, Never>?
    private var danmakuRequestSequence = 0

    init(store: LocalStore = .shared, repository: NativeRepository = .shared) {
        self.store = store
        self.repository = repository
        self.danmakuEnabled = store.danmakuEnabled
        self.danmakuStyle = store.danmakuStyle
    }

    func toggleDanmaku() {
        setDanmakuEnabled(!danmakuEnabled)
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        guard danmakuEnabled != enabled else { return }
        danmakuEnabled = enabled
        store.danmakuEnabled = enabled
    }

    func updateStyle(_ style: TVDanmakuStyle) {
        danmakuStyle = style
        store.danmakuStyle = style
    }

    func setFontSize(_ size: CGFloat) {
        var next = danmakuStyle
        next.fontSize = size
        updateStyle(next)
    }

    func setOpacity(_ op: Double) {
        var next = danmakuStyle
        next.opacity = op
        updateStyle(next)
    }

    func setLaneCount(_ lanes: Int) {
        var next = danmakuStyle
        next.laneCount = lanes
        next.displayArea = lanes <= 4 ? 0.5 : 1
        updateStyle(next)
    }

    func reset() {
        danmakuRequestSequence += 1
        danmakuTask?.cancel()
        danmakuTask = nil
        danmakuPages.removeAll()
        danmakuRetryAfter.removeAll()
        danmakuCache = []
        activeDanmakus = []
    }

    func updateActiveDanmakus(currentTime: Double, duration: Double, plan: PlaybackPlan?, drama: Drama, episode: Episode?) {
        if let episode { universal.setMedia(TVDanmakuMedia(drama: drama, episode: episode)) }
        guard danmakuEnabled, currentTime.isFinite, duration.isFinite, duration > 0, duration <= 86400 else {
            activeDanmakus = []
            return
        }
        let currentMs = Int64(max(0, min(currentTime, duration)) * 1000)
        let durationMs = Int64(duration * 1000)
        let scrollingLifetime = Int64(8000 / max(0.5, min(2, danmakuStyle.speed)))
        let visible = danmakuCache.filter {
            $0.timeMs <= currentMs && currentMs - $0.timeMs < ($0.mode == .scroll ? scrollingLifetime : 4000)
        }
        if visible != activeDanmakus { activeDanmakus = visible }

        guard let plan, !plan.local, episode != nil,
              universal.useExternal(plan) || !plan.danmakuId.isEmpty else { return }
        let start = currentMs / 30000 * 30000
        requestDanmaku(plan: plan, source: drama.source, start: start, durationMs: durationMs, currentTime: currentTime)
        if danmakuPages[start] != nil && currentMs >= start + 22000 {
            requestDanmaku(plan: plan, source: drama.source, start: start + 30000, durationMs: durationMs, currentTime: currentTime)
        }
    }

    private func requestDanmaku(plan: PlaybackPlan, source: String, start: Int64, durationMs: Int64, currentTime: Double) {
        guard danmakuTask == nil, danmakuPages[start] == nil,
              start < durationMs, danmakuRetryAfter[start, default: .distantPast] <= Date() else { return }

        danmakuRequestSequence += 1
        let sequence = danmakuRequestSequence
        danmakuTask = Task { [weak self] in
            guard let self else { return }
            defer { if sequence == self.danmakuRequestSequence { self.danmakuTask = nil } }
            do {
                let rows = try await self.loadPage(plan: plan, source: source, start: start, duration: durationMs)
                guard !Task.isCancelled, sequence == self.danmakuRequestSequence, self.danmakuEnabled else { return }
                self.danmakuPages[start] = rows
                let position = Int64(currentTime * 1000)
                let nearest = self.danmakuPages.keys.sorted { abs($0 - position) < abs($1 - position) }
                for key in nearest.dropFirst(6) { self.danmakuPages.removeValue(forKey: key) }
                self.danmakuRetryAfter.removeValue(forKey: start)
                var seen = Set<String>()
                self.danmakuCache = self.danmakuPages.values.flatMap { $0 }.sorted { $0.timeMs < $1.timeMs }.filter { seen.insert($0.id).inserted }
                self.danmakuTask = nil
            } catch {
                guard !Task.isCancelled, sequence == self.danmakuRequestSequence else { return }
                self.danmakuRetryAfter[start] = Date().addingTimeInterval(15)
            }
        }
    }

    private func loadPage(plan: PlaybackPlan, source: String, start: Int64, duration: Int64) async throws -> [DanmakuItem] {
        if universal.useExternal(plan) {
            return try await universal.page(start: start, duration: duration)
        }
        let offset = universal.offsetMs
        let end = min(start + 30000, duration)
        var cursor = max(0, start - offset)
        var rows: [DanmakuItem] = []
        while cursor < min(duration, end - offset) {
            let page = try await repository.loadDanmaku(plan: plan, source: source, startMs: cursor, durationMs: duration)
            rows += page.compactMap { item in
                let time = item.timeMs + offset
                guard time >= start, time < end else { return nil }
                return DanmakuItem(id: item.id, text: item.text, timeMs: time, color: item.color, mode: item.mode)
            }
            cursor = (cursor / 30000 + 1) * 30000
        }
        return rows
    }
}
