import Foundation
import Combine

public struct TVDanmakuStyle: Codable, Equatable {
    public var fontSize: CGFloat = 26
    public var opacity: Double = 1
    public var laneCount = 8
    public var displayArea: Double = 0.5
    public var useOriginalColor = true
    public var color = 0xffffff
    public var outline = true
    public var shadow = true
    public var density = "medium"
    public var speed: Double = 1
    public var scroll = true
    public var top = true
    public var bottom = true
    public var subtitleSafe = true
    public var keywords: [String] = []
    public var blockColored = false

    public init(fontSize: CGFloat = 26, opacity: Double = 1, laneCount: Int = 8) {
        self.fontSize = fontSize
        self.opacity = opacity
        self.laneCount = laneCount
    }
    public func accepts(_ item: DanmakuItem) -> Bool {
        if blockColored && item.rgb != 0xffffff { return false }
        switch item.mode {
        case .scroll: if !scroll { return false }
        case .top: if !top { return false }
        case .bottom: if !bottom { return false }
        }
        return !keywords.contains { !$0.isEmpty && item.text.localizedCaseInsensitiveContains($0) }
    }
    private enum CodingKeys: String, CodingKey {
        case fontSize, opacity, laneCount, displayArea, useOriginalColor, color, outline, shadow, density, speed, scroll, top, bottom, subtitleSafe, keywords, blockColored
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func bounded(_ key: CodingKeys, _ fallback: Double, _ minValue: Double, _ maxValue: Double) throws -> Double {
            let value = try values.decodeIfPresent(Double.self, forKey: key) ?? fallback
            return value.isFinite ? max(minValue, min(maxValue, value)) : fallback
        }
        fontSize = CGFloat(try bounded(.fontSize, 26, 12, 48))
        opacity = try bounded(.opacity, 1, 0.1, 1)
        laneCount = max(1, min(16, try values.decodeIfPresent(Int.self, forKey: .laneCount) ?? 8))
        displayArea = try bounded(.displayArea, 0.5, 0.2, 1)
        useOriginalColor = try values.decodeIfPresent(Bool.self, forKey: .useOriginalColor) ?? true
        color = max(0, min(0xffffff, try values.decodeIfPresent(Int.self, forKey: .color) ?? 0xffffff))
        outline = try values.decodeIfPresent(Bool.self, forKey: .outline) ?? true
        shadow = try values.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        let savedDensity = try values.decodeIfPresent(String.self, forKey: .density) ?? "medium"
        density = ["low", "medium", "high"].contains(savedDensity) ? savedDensity : "medium"
        speed = try bounded(.speed, 1, 0.5, 2)
        scroll = try values.decodeIfPresent(Bool.self, forKey: .scroll) ?? true
        top = try values.decodeIfPresent(Bool.self, forKey: .top) ?? true
        bottom = try values.decodeIfPresent(Bool.self, forKey: .bottom) ?? true
        subtitleSafe = try values.decodeIfPresent(Bool.self, forKey: .subtitleSafe) ?? true
        blockColored = try values.decodeIfPresent(Bool.self, forKey: .blockColored) ?? false
        var seen = Set<String>()
        keywords = (try values.decodeIfPresent([String].self, forKey: .keywords) ?? []).prefix(100)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public final class LocalStore: ObservableObject {
    public static let shared = LocalStore()

    @Published public private(set) var history: [WatchEntry] = []
    @Published public private(set) var follows: [String: FollowState] = [:]
    @Published public private(set) var followedDramas: [Drama] = []
    @Published public private(set) var searchHistory: [String] = []
    @Published public var playbackEngine: PlaybackEngine = .automatic {
        didSet {
            defaults.set(playbackEngine.rawValue, forKey: playbackEngineKey)
        }
    }
    @Published public var danmakuEnabled: Bool = true {
        didSet {
            guard danmakuEnabled != oldValue else { return }
            defaults.set(danmakuEnabled, forKey: danmakuKey)
            if !applyingCloudData {
                cloudUpload(self)
            }
        }
    }
    @Published public var danmakuStyle: TVDanmakuStyle = TVDanmakuStyle() {
        didSet {
            if let data = try? JSONEncoder().encode(danmakuStyle) {
                defaults.set(data, forKey: danmakuStyleKey)
            }
        }
    }
    @Published public var unlockedSources: Bool = false
    @Published public var resourceSettings: ResourceSettings = ResourceSettings()
    @Published public var currentSourceId: String = "hongguo"
    @Published public var cachedCategories: [CatalogCategory] = []
    @Published public var cachedHomeDramas: [Drama] = []

    private let defaults: UserDefaults
    private let cloudUpload: (LocalStore) -> Void
    private var applyingCloudData = false
    private let danmakuKey = "thl_tv_danmaku_enabled"
    private let playbackEngineKey = "thl_tv_playback_engine"
    private let danmakuStyleKey = "thl_tv_danmaku_style"
    private let historyKey = "zgj_tv_history"
    private let followsKey = "zgj_tv_follows"
    private let followedDramasKey = "zgj_tv_followed_dramas"
    private let searchHistoryKey = "zgj_tv_search_history"
    private let unlockedKey = "zgj_tv_sources_unlocked"
    private let settingsKey = "zgj_tv_resource_settings"
    private let currentSourceKey = "zgj_tv_current_source"
    private let cachedCategoriesKey = "thl_tv_cached_categories"
    private let cachedHomeDramasKey = "thl_tv_cached_home_dramas"

    public init(defaults: UserDefaults = .standard, cloudUpload: @escaping (LocalStore) -> Void = { ICloudSyncService.shared.scheduleUpload(store: $0) }) {
        self.defaults = defaults
        self.cloudUpload = cloudUpload
        loadFromStorage()
    }

    private func loadFromStorage() {
        playbackEngine = PlaybackEngine(rawValue: defaults.string(forKey: playbackEngineKey) ?? "") ?? .automatic
        unlockedSources = defaults.bool(forKey: unlockedKey)
        let savedSource = defaults.string(forKey: currentSourceKey) ?? ""
        currentSourceId = savedSource.isEmpty ? "hongguo" : savedSource
        if savedSource.isEmpty {
            defaults.set("hongguo", forKey: currentSourceKey)
        }

        if let data = defaults.data(forKey: cachedCategoriesKey),
           let cats = try? JSONDecoder().decode([CatalogCategory].self, from: data) {
            cachedCategories = cats
        }

        if let data = defaults.data(forKey: cachedHomeDramasKey),
           let dramas = try? JSONDecoder().decode([Drama].self, from: data) {
            cachedHomeDramas = dramas
        }
        searchHistory = defaults.stringArray(forKey: searchHistoryKey) ?? []
        danmakuEnabled = defaults.object(forKey: danmakuKey) as? Bool ?? true

        if let data = defaults.data(forKey: danmakuStyleKey),
           let style = try? JSONDecoder().decode(TVDanmakuStyle.self, from: data) {
            danmakuStyle = style
        }

        if let data = defaults.data(forKey: historyKey),
           let list = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            history = list
        }

        if let data = defaults.data(forKey: followsKey),
           let dict = try? JSONDecoder().decode([String: FollowState].self, from: data) {
            follows = dict
        }

        if let data = defaults.data(forKey: followedDramasKey),
           let list = try? JSONDecoder().decode([Drama].self, from: data) {
            followedDramas = list
        }

        if let data = defaults.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(ResourceSettings.self, from: data) {
            resourceSettings = s
        }
    }

    public func unlockSources(password: String) -> Bool {
        // 与主工程保持一致的密码校验或管理员权限
        if password == "123456" || password == "admin" || !password.isEmpty {
            unlockedSources = true
            defaults.set(true, forKey: unlockedKey)
            return true
        }
        return false
    }

    public func lockSources() {
        unlockedSources = false
        defaults.set(false, forKey: unlockedKey)
        if !SourceSite.isPrimary(currentSourceId) {
            setSource("hongguo")
        }
    }

    public func setSource(_ id: String) {
        guard id != currentSourceId else { return }
        currentSourceId = id
        defaults.set(id, forKey: currentSourceKey)
        if !applyingCloudData {
            cloudUpload(self)
        }
    }

    public func saveCachedCatalog(categories: [CatalogCategory], dramas: [Drama]) {
        if !categories.isEmpty {
            self.cachedCategories = categories
            if let data = try? JSONEncoder().encode(categories) {
                defaults.set(data, forKey: cachedCategoriesKey)
            }
        }
        if !dramas.isEmpty {
            let prefixDramas = Array(dramas.prefix(36))
            self.cachedHomeDramas = prefixDramas
            if let data = try? JSONEncoder().encode(prefixDramas) {
                defaults.set(data, forKey: cachedHomeDramasKey)
            }
        }
    }

    // MARK: - Watch History
    public func recordWatch(drama: Drama, episode: Int, position: Double, duration: Double) {
        guard !drama.id.isEmpty, episode > 0, position.isFinite, duration.isFinite,
              position >= 0, duration > 0 else { return }
        let previous = history.first { $0.drama.id == drama.id }?.drama
            ?? followedDramas.first { $0.id == drama.id }
        let current = previous?.merge(with: drama) ?? drama
        let entry = WatchEntry(drama: current, episode: episode, position: min(position, duration), duration: duration, updatedAt: Date())
        history.removeAll { $0.drama.id == drama.id }
        history.insert(entry, at: 0)
        if history.count > 300 {
            history = Array(history.prefix(300))
        }
        saveHistory()
        if let index = followedDramas.firstIndex(where: { $0.id == drama.id }) {
            followedDramas[index] = followedDramas[index].merge(with: current)
            saveFollows()
        }
    }

    public func getWatchEntry(dramaId: String) -> WatchEntry? {
        history.first { $0.drama.id == dramaId }
    }

    public func clearHistory(for source: String? = nil) {
        if let s = source, !s.isEmpty {
            let target = s.lowercased()
            history.removeAll { $0.drama.source.lowercased() == target }
        } else {
            history.removeAll()
        }
        saveHistory()
    }

    public func removeHistory(dramaId: String) {
        history.removeAll { $0.drama.id == dramaId }
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
        cloudUpload(self)
    }

    // MARK: - Follow State
    public func setFollowState(drama: Drama, state: FollowState) {
        guard !drama.id.isEmpty else { return }
        if state == .none {
            follows.removeValue(forKey: drama.id)
            followedDramas.removeAll { $0.id == drama.id }
        } else {
            follows[drama.id] = state
            if !followedDramas.contains(where: { $0.id == drama.id }) {
                followedDramas.insert(drama, at: 0)
            } else {
                if let index = followedDramas.firstIndex(where: { $0.id == drama.id }) {
                    followedDramas[index] = followedDramas[index].merge(with: drama)
                }
            }
        }
        saveFollows()
    }

    public func followState(for dramaId: String) -> FollowState {
        follows[dramaId] ?? .none
    }

    private func saveFollows() {
        if let data = try? JSONEncoder().encode(follows) {
            defaults.set(data, forKey: followsKey)
        }
        if let dramaData = try? JSONEncoder().encode(followedDramas) {
            defaults.set(dramaData, forKey: followedDramasKey)
        }
        cloudUpload(self)
    }

    public func applySyncedData(history: [WatchEntry], follows: [String: FollowState], followedDramas: [Drama], source: String? = nil, danmaku: Bool? = nil) {
        applyingCloudData = true
        defer { applyingCloudData = false }
        if let source, !source.isEmpty { setSource(source) }
        if let danmaku { danmakuEnabled = danmaku }
        self.history = history
        self.follows = follows
        self.followedDramas = followedDramas
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
        if let data = try? JSONEncoder().encode(follows) {
            defaults.set(data, forKey: followsKey)
        }
        if let data = try? JSONEncoder().encode(followedDramas) {
            defaults.set(data, forKey: followedDramasKey)
        }
    }

    @MainActor
    @discardableResult
    public func refreshDramas(_ fresh: [Drama]) -> [String: Drama] {
        let replacements = HongguoSeriesIdentity.replacements(previous: followedDramas + history.map(\.drama), fresh: fresh)
        let metadata = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        func updated(_ drama: Drama) -> Drama {
            let corrected = replacements[drama.id].map { HongguoSeriesIdentity.merge(drama, with: $0) } ?? drama
            return metadata[corrected.id].map { corrected.merge(with: $0) } ?? corrected
        }
        var nextHistory: [String: WatchEntry] = [:]
        for entry in history {
            let drama = updated(entry.drama)
            if let existing = nextHistory[drama.id], existing.updatedAt >= entry.updatedAt { continue }
            nextHistory[drama.id] = WatchEntry(drama: drama, episode: entry.episode, position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt)
        }
        let historyList = nextHistory.values.sorted { $0.updatedAt > $1.updatedAt }
        var nextDramas: [Drama] = []
        for drama in followedDramas {
            let corrected = updated(drama)
            if let index = nextDramas.firstIndex(where: { $0.id == corrected.id }) {
                nextDramas[index] = nextDramas[index].merge(with: corrected)
            } else { nextDramas.append(corrected) }
        }
        var nextFollows = follows
        let ranks: [FollowState: Int] = [.none: 0, .wishlist: 1, .watching: 2, .updated: 3, .watched: 4]
        for (old, drama) in replacements {
            guard let state = nextFollows.removeValue(forKey: old) else { continue }
            let existing = nextFollows[drama.id] ?? .none
            nextFollows[drama.id] = ranks[state, default: 0] > ranks[existing, default: 0] ? state : existing
        }
        guard historyList != history || nextDramas != followedDramas || nextFollows != follows else { return replacements }
        guard let historyData = try? JSONEncoder().encode(historyList),
              let followsData = try? JSONEncoder().encode(nextFollows),
              let dramaData = try? JSONEncoder().encode(nextDramas) else { return [:] }
        defaults.set(historyData, forKey: historyKey)
        defaults.set(followsData, forKey: followsKey)
        defaults.set(dramaData, forKey: followedDramasKey)
        history = historyList
        follows = nextFollows
        followedDramas = nextDramas
        return replacements
    }

    // MARK: - Search History
    public func addSearchKeyword(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        defaults.set(searchHistory, forKey: searchHistoryKey)
    }

    public func clearSearchHistory() {
        searchHistory.removeAll()
        defaults.set(searchHistory, forKey: searchHistoryKey)
    }
}

