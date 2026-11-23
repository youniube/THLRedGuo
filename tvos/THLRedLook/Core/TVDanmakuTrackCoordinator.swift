import UIKit

public final class TVDanmakuTrackCoordinator {
    private var flightsById: [String: TVPlannedDanmaku] = [:]
    private var lastObservedTime: Double = 0
    private var lastStyle: TVDanmakuStyle?
    private var lastWidth: CGFloat = 0
    private var lastRows = 0
    public init() {}
    public func updateAndGetFlights(danmakus: [DanmakuItem], currentTime: Double, screenWidth: CGFloat,
        laneCount: Int, fontSize: CGFloat, style: TVDanmakuStyle? = nil, totalRows: Int? = nil) -> [TVPlannedDanmaku] {
        guard screenWidth > 0, (totalRows ?? laneCount) > 0 else { return [] }
        let settings = style ?? TVDanmakuStyle(fontSize: fontSize, laneCount: laneCount)
        let count = max(1, min(16, totalRows ?? laneCount))
        if settings != lastStyle || screenWidth != lastWidth || count != lastRows || abs(currentTime - lastObservedTime) > 2.5 || currentTime < lastObservedTime - 0.5 {
            flightsById.removeAll(keepingCapacity: true)
        }
        lastStyle = settings; lastWidth = screenWidth; lastRows = count; lastObservedTime = currentTime
        flightsById = flightsById.filter { currentTime >= $0.value.time && currentTime < $0.value.time + $0.value.duration }
        let allowed = danmakus.filter { settings.accepts($0) }.sorted { $0.timeMs < $1.timeMs }
        let bottomRows = settings.bottom && (totalRows != nil || allowed.contains(where: { $0.mode == .bottom })) ? min(2, count) : 0
        let regularRows = max(0, min(laneCount, count - bottomRows))
        let gap: CGFloat = settings.density == "low" ? 64 : settings.density == "high" ? 16 : 28
        let capacity = settings.density == "low" ? 12 : settings.density == "high" ? 60 : 40
        for item in allowed {
            let time = Double(item.timeMs) / 1000
            let duration = item.mode == .scroll ? 8 / max(0.5, min(2, settings.speed)) : 4
            guard !item.id.isEmpty, item.timeMs >= 0, time <= currentTime, currentTime < time + duration,
                flightsById[item.id] == nil, flightsById.count < capacity else { continue }
            let text = String(item.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !text.isEmpty else { continue }
            let width = (text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: fontSize)]).width + 16
            let lanes = item.mode == .bottom ? Array((count - bottomRows)..<count).reversed().map { $0 } : Array(0..<regularRows)
            for lane in lanes {
                if let previous = flightsById.values.filter({ $0.lane == lane }).max(by: { $0.time < $1.time }) {
                    let elapsed = time - previous.time
                    if elapsed < 0 { continue }
                    if elapsed < previous.duration {
                        guard item.mode == .scroll, previous.mode == .scroll else { continue }
                        let clearance = (screenWidth + previous.width) * CGFloat(elapsed / previous.duration) - previous.width
                        let exit = screenWidth - (screenWidth + width) * CGFloat((previous.duration - elapsed) / duration)
                        if clearance < gap || exit < gap { continue }
                    }
                }
                flightsById[item.id] = TVPlannedDanmaku(id: item.id, text: text, time: time, duration: duration, lane: lane, width: width, color: item.rgb, mode: item.mode)
                break
            }
        }
        return flightsById.values.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }
    public func reset() { flightsById.removeAll(); lastStyle = nil; lastObservedTime = 0 }
}
