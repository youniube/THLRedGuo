import Foundation

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
