import Foundation
import Combine
import CryptoKit

public struct TVDanmakuMedia: Equatable {
    public let workID: String
    public let title: String
    public let year: Int
    public let kind: String
    public let season: Int?
    public let episode: Int?
    public let episodeKey: String
    public var seriesKey: String { String(data: (try? JSONEncoder().encode([workID, title, String(year), kind, season.map(String.init) ?? ""])) ?? Data(), encoding: .utf8) ?? "" }
    public var key: String { seriesKey + ":" + (episode.map(String.init) ?? "") + ":" + episodeKey }

    public init(drama: Drama, episode: Episode) {
        workID = drama.id
        title = drama.title
        year = drama.year
        kind = Self.kind(drama.mediaType.isEmpty ? drama.category : drama.mediaType)
        let raw = episode.rawChapter ?? [:]
        season = raw["seasonNumber"] as? Int ?? raw["season"] as? Int ?? Self.season(episode.title) ?? Self.season(drama.title)
        self.episode = Self.episode(raw["title"] as? String ?? (episode.raw == nil ? episode.title : "")) ?? raw["currentEpisode"] as? Int
        episodeKey = episode.id.isEmpty ? episode.title : episode.id
    }

    static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
        }
        return nil
    }

    static func number(_ text: String?) -> Int? {
        guard let text else { return nil }
        if let number = Int(text) { return number > 0 ? number : nil }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, digit = 0
        for char in text {
            if char == "十" || char == "百" { total += max(1, digit) * (char == "十" ? 10 : 100); digit = 0 }
            else if let value = digits[char] { digit = value }
            else { return nil }
        }
        return total + digit > 0 ? total + digit : nil
    }

    static func season(_ title: String) -> Int? { number(capture(title, "第([\\d一二两三四五六七八九十百零〇]+)季|\\b(?:season\\s*|s)(\\d{1,2})(?=\\b|e\\d)")) }
    static func episode(_ title: String) -> Int? { number(capture(title, "第\\s*([\\d一二两三四五六七八九十百零〇]+)\\s*[集话期]|(?:\\b(?:ep?\\s*|episode\\s*)|s\\d{1,2}e)(\\d+)\\b|^(\\d+)(?:\\s|$)")) }
    static func normalized(_ title: String) -> String {
        var value = title.lowercased()
        for pattern in ["[（(](?:19|20)\\d{2}[)）]", "[【\\[](?:腾讯|爱奇艺|优酷|芒果|哔哩哔哩|bilibili|qq|qiyi|youku|imgo|红果|dandan)[】\\]]", "第[\\d一二两三四五六七八九十百零〇]+季|\\b(?:season\\s*|s)\\d{1,2}\\b", "[\\s\\-_:：·.,，。!！?？《》「」“”\"'()（）\\[\\]【】]+"] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value
    }
    static func kind(_ value: String) -> String {
        switch value.lowercased() {
        case "movie", "电影", "剧场版": return "movie"
        case "tv", "tvseries", "电视剧", "短剧", "真人剧": return "tv"
        case "anime", "动画", "动漫", "漫剧", "tv动画", "网络动画", "ova", "ona": return "anime"
        case "variety", "综艺": return "variety"
        case "documentary", "纪录片": return "documentary"
        default: return ""
        }
    }
}

public struct TVDanmakuCandidate: Identifiable {
    public let id: String
    public let title: String
    let year: Int
    let kind: String
    let season: Int?
    func matches(_ media: TVDanmakuMedia) -> Bool {
        TVDanmakuMedia.normalized(title) == TVDanmakuMedia.normalized(media.title) && (media.year == 0 || media.year == year) && (media.kind.isEmpty || media.kind == kind) &&
            (media.season == season || media.season == 1 && season == nil || media.season == nil && (season == nil || season == 1))
    }
}

public struct TVLibraryEpisode: Identifiable {
    public let id: String
    public let title: String
}

public struct TVExternalDanmakuTrack {
    let items: [DanmakuItem]
    let durationMs: Int64
}

public actor TVExternalDanmakuAPI {
    public static let shared = TVExternalDanmakuAPI()
    private var tracks: [String: Task<TVExternalDanmakuTrack, Error>] = [:]
    private var loaded: [String: Date] = [:]
    private var details: [String: [TVLibraryEpisode]] = [:]
    private var detailTitles: [String: String] = [:]
    private var searches: [String: (Date, [TVDanmakuCandidate])] = [:]

    private func get(_ base: String, _ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        guard !base.isEmpty, var components = URLComponents(string: base + "/api/v2/" + path) else { throw failure("请先配置通用弹幕 API") }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw failure("弹幕 API 地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw failure("弹幕 API 请求失败") }
        guard bytes.count <= 12 * 1024 * 1024, let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], data["success"] as? Bool != false,
              (data["errorCode"] as? Int ?? 0) == 0 else { throw failure("弹幕 API 数据无效") }
        return data
    }

    public func search(base: String, keyword: String) async throws -> [TVDanmakuCandidate] {
        let key = base + "|" + keyword
        if let value = searches[key], Date().timeIntervalSince(value.0) < 120 { return value.1 }
        let response = try await get(base, "search/anime", ["keyword": keyword])
        guard let rows = response["animes"] as? [[String: Any]] else { throw failure("弹幕搜索结果无效") }
        let result: [TVDanmakuCandidate] = rows.prefix(100).compactMap { row in
            guard let rawID = row["animeId"], let title = row["animeTitle"] as? String, !title.isEmpty else { return nil }
            let date = row["startDate"] as? String ?? ""
            let yearText = TVDanmakuMedia.capture(date, "((?:19|20)\\d{2})") ?? TVDanmakuMedia.capture(title, "[（(]((?:19|20)\\d{2})[)）]")
            let description = TVDanmakuMedia.kind(row["typeDescription"] as? String ?? "")
            return TVDanmakuCandidate(id: String(describing: rawID), title: title, year: Int(yearText ?? "") ?? 0,
                kind: description.isEmpty ? TVDanmakuMedia.kind(row["type"] as? String ?? "") : description, season: TVDanmakuMedia.season(title))
        }
        if searches.count >= 20, let first = searches.keys.first { searches.removeValue(forKey: first) }
        searches[key] = (Date(), result)
        return result
    }

    public func episodes(base: String, id: String, expectedTitle: String? = nil) async throws -> [TVLibraryEpisode] {
        let key = base + "|" + id
        if let cached = details[key] {
            guard expectedTitle == nil || detailTitles[key] == expectedTitle else { throw failure("弹幕库作品标识已变化，请重新匹配") }
            return cached
        }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let response = try await get(base, "bangumi/" + encoded)
        guard let bangumi = response["bangumi"] as? [String: Any], let rawID = bangumi["animeId"], String(describing: rawID) == id,
              let title = bangumi["animeTitle"] as? String, expectedTitle == nil || title == expectedTitle,
              let rows = bangumi["episodes"] as? [[String: Any]] else { throw failure("弹幕剧集信息不匹配") }
        let result = rows.prefix(10000).compactMap { row -> TVLibraryEpisode? in
            guard let rawID = row["episodeId"] else { return nil }
            return TVLibraryEpisode(id: String(describing: rawID), title: row["episodeTitle"] as? String ?? "")
        }
        if details.count >= 20, let first = details.keys.first { details.removeValue(forKey: first); detailTitles.removeValue(forKey: first) }
        details[key] = result
        detailTitles[key] = title
        return result
    }

    public func track(base: String, id: String, identity: String = "") async throws -> TVExternalDanmakuTrack {
        let key = base + "|" + id + "|" + identity
        if let date = loaded[key], Date().timeIntervalSince(date) > 7200 { tracks.removeValue(forKey: key); loaded.removeValue(forKey: key) }
        if let cached = tracks[key] { return try await cached.value }
        if tracks.count >= 3, let first = tracks.keys.first { tracks.removeValue(forKey: first); loaded.removeValue(forKey: first) }
        let task = Task<TVExternalDanmakuTrack, Error> {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let response = try await self.get(base, "comment/" + encoded, ["format": "json", "duration": "true"])
            guard let rows = response["comments"] as? [[String: Any]], rows.count <= 200000 else { throw self.failure("弹幕列表格式无效") }
            var seen = Set<String>(), items: [DanmakuItem] = []
            for row in rows {
                guard let p = row["p"] as? String, let first = p.split(separator: ",").first, let time = Double(first), time.isFinite, time >= 0, time <= 86400, let content = row["m"] as? String else { continue }
                let text = content.replacingOccurrences(of: "[\\x00-\\x1f\\x7f-\\x9f\\u2028\\u2029]", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let ms = Int64((time * 1000).rounded())
                let identity = SHA256.hash(data: Data("\(id):\(ms):\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
                if seen.insert(identity).inserted { items.append(DanmakuItem(id: "external:" + identity, text: String(text.prefix(181)), timeMs: ms)) }
            }
            let seconds = (response["videoDuration"] as? NSNumber)?.doubleValue ?? 0
            return TVExternalDanmakuTrack(items: items.sorted { $0.timeMs < $1.timeMs }, durationMs: seconds.isFinite && seconds > 0 && seconds <= 86400 ? Int64((seconds * 1000).rounded()) : 0)
        }
        tracks[key] = task
        do { let result = try await task.value; loaded[key] = Date(); return result }
        catch { tracks.removeValue(forKey: key); throw error }
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "THLRedLook.Danmaku.API", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
    public func clearMatchingCache() { details.removeAll(); detailTitles.removeAll(); searches.removeAll() }
}

@MainActor
public final class TVUniversalDanmaku: ObservableObject {
    @Published public private(set) var status = ""
    @Published public var baseURL: String
    @Published public var mode: String
    @Published public private(set) var media: TVDanmakuMedia?
    private let defaults: UserDefaults
    private let api: TVExternalDanmakuAPI
    private static let settingsKey = "thl_tv_external_danmaku"
    private let bindingsKey = "thl_tv_danmaku_bindings"
    public init(defaults: UserDefaults = .standard, api: TVExternalDanmakuAPI = .shared) {
        self.defaults = defaults
        self.api = api
        let settings = defaults.dictionary(forKey: Self.settingsKey) ?? [:]
        baseURL = settings["baseUrl"] as? String ?? ""
        mode = settings["mode"] as? String ?? "automatic"
    }
    private var bindingKey: String { baseURL + "|" + (media?.key ?? "") }
    private var seriesKey: String { baseURL + "|series:" + (media?.seriesKey ?? "") }
    private func binding(_ key: String) -> [String: Any] { (defaults.dictionary(forKey: bindingsKey) ?? [:])[key] as? [String: Any] ?? [:] }
    private func save(_ key: String, _ value: [String: Any]?) {
        var rows = defaults.dictionary(forKey: bindingsKey) ?? [:]
        rows[key] = value
        while rows.count > 2000, let first = rows.keys.first { rows.removeValue(forKey: first) }
        defaults.set(rows, forKey: bindingsKey)
    }
    public var offsetMs: Int64 { (binding(bindingKey)["offsetMs"] as? NSNumber)?.int64Value ?? 0 }
    public func useExternal(_ plan: PlaybackPlan) -> Bool { mode == "external" || mode != "native" && (plan.danmakuId.isEmpty || binding(bindingKey)["manual"] as? Bool == true) }
    public func setMedia(_ value: TVDanmakuMedia) { if media != value { media = value; status = "" } }
    public func configure(_ address: String, mode: String) throws {
        var base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/api/v2") { base = String(base.dropLast(7)) }
        if !base.isEmpty {
            guard let url = URLComponents(string: base), ["http", "https"].contains(url.scheme ?? ""), !(url.host ?? "").isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw NSError(domain: "THLRedLook.Danmaku.API", code: -1, userInfo: [NSLocalizedDescriptionKey: "请输入有效的 HTTP(S) 弹幕 API 基础地址"]) }
        }
        guard ["automatic", "native", "external"].contains(mode) else { return }
        baseURL = base
        self.mode = mode
        defaults.set(["baseUrl": base, "mode": mode], forKey: Self.settingsKey)
        status = ""
    }
    public func search(_ keyword: String) async throws -> [TVDanmakuCandidate] { try await api.search(base: baseURL, keyword: keyword) }
    public func episodes(_ candidate: TVDanmakuCandidate) async throws -> [TVLibraryEpisode] { try await api.episodes(base: baseURL, id: candidate.id) }
    public func choose(_ candidate: TVDanmakuCandidate, _ episode: TVLibraryEpisode) {
        save(bindingKey, ["animeId": candidate.id, "animeTitle": candidate.title, "episodeId": episode.id, "episodeTitle": episode.title, "title": candidate.title + " · " + episode.title, "manual": true, "offsetMs": offsetMs])
        save(seriesKey, ["animeId": candidate.id, "title": candidate.title])
        status = "已手动匹配 " + candidate.title + " · " + episode.title
    }
    public func setOffset(_ value: Int64) { var record = binding(bindingKey); record["offsetMs"] = max(-1800000, min(1800000, value)); save(bindingKey, record); objectWillChange.send() }
    public func reset() async { let offset = offsetMs; save(bindingKey, offset == 0 ? nil : ["offsetMs": offset]); save(seriesKey, nil); await api.clearMatchingCache(); status = "" }
    public func reportFailure() { status = "通用弹幕暂不可用，可检查 API 或重新匹配" }
    public func page(start: Int64, duration: Int64) async throws -> [DanmakuItem] {
        guard let query = media, !baseURL.isEmpty else { status = "请配置通用弹幕 API"; return [] }
        let base = baseURL, key = bindingKey
        var record = binding(key)
        if record["episodeId"] == nil {
            let series = binding(seriesKey)
            let candidate: TVDanmakuCandidate
            if let id = series["animeId"] as? String { candidate = TVDanmakuCandidate(id: id, title: series["title"] as? String ?? query.title, year: query.year, kind: query.kind, season: query.season) }
            else {
                let candidates = try await api.search(base: base, keyword: query.title).filter { $0.matches(query) }
                guard candidates.count == 1 else { status = candidates.isEmpty ? "没有确认到对应作品，请手动搜索" : "有多个同名版本，请手动选择"; return [] }
                candidate = candidates[0]
            }
            let episodes = try await api.episodes(base: base, id: candidate.id, expectedTitle: candidate.title)
            let matching = episodes.filter { query.episode != nil && TVDanmakuMedia.episode($0.title) == query.episode || query.kind == "movie" && episodes.count == 1 && ["正片", "电影", "剧场版"].contains(TVDanmakuMedia.normalized($0.title)) }
            guard matching.count == 1 else { status = "分集信息不足，请手动选择"; return [] }
            record.merge(["animeId": candidate.id, "animeTitle": candidate.title, "episodeId": matching[0].id, "episodeTitle": matching[0].title, "title": candidate.title + " · " + matching[0].title, "manual": false]) { _, value in value }
            guard !Task.isCancelled, media == query, baseURL == base else { return [] }
            save(key, record)
        }
        guard let episodeID = record["episodeId"] as? String else { return [] }
        guard let animeID = record["animeId"] as? String, let title = record["animeTitle"] as? String else { return [] }
        let confirmed = try await api.episodes(base: base, id: animeID, expectedTitle: title)
        guard confirmed.contains(where: { $0.id == episodeID && $0.title == record["episodeTitle"] as? String }) else { throw NSError(domain: "THLRedLook.Danmaku.API", code: -1, userInfo: [NSLocalizedDescriptionKey: "弹幕库分集标识已变化，请重新匹配"]) }
        let track = try await api.track(base: base, id: episodeID, identity: title + "|" + (record["episodeTitle"] as? String ?? ""))
        guard !Task.isCancelled, media == query, baseURL == base else { return [] }
        if track.durationMs > 0, record["manual"] as? Bool != true, abs(track.durationMs - duration) > max(15000, min(300000, Int64(Double(duration) * 0.15))) { status = "视频与弹幕时长不符，请手动确认"; return [] }
        let offset = (record["offsetMs"] as? NSNumber)?.int64Value ?? 0
        let end = min(start + 30000, duration)
        let rows = track.items.filter { $0.timeMs + offset >= start && $0.timeMs + offset < end }
        let sampled = rows.count <= 90 ? rows : (0..<90).map { rows[$0 * rows.count / 90] }
        status = track.items.isEmpty ? "已匹配，本集暂无弹幕" : "已匹配 " + (record["title"] as? String ?? "")
        return sampled.map { DanmakuItem(id: $0.id, text: $0.text, timeMs: $0.timeMs + offset) }
    }
}
