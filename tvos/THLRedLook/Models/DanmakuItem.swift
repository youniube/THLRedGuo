import Foundation

public enum DanmakuMode: String, Codable {
    case scroll, top, bottom
    public static func parse(_ value: Any?) -> DanmakuMode {
        switch value.map({ String(describing: $0) }) ?? "" {
        case "4", "bottom": return .bottom
        case "5", "top": return .top
        default: return .scroll
        }
    }
}

public struct DanmakuItem: Identifiable, Hashable, Codable {
    public let id: String
    public let text: String
    public let timeMs: Int64
    public let color: String
    public let mode: DanmakuMode
    public var rgb: Int { Int(color.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xffffff }

    public init(id: String = UUID().uuidString, text: String, timeMs: Int64, color: String = "#FFFFFF", mode: DanmakuMode = .scroll) {
        self.id = id
        self.text = text
        self.timeMs = timeMs
        self.color = color
        self.mode = mode
    }
    public static func colorString(_ value: Any?) -> String {
        if let value = value as? NSNumber { return String(format: "#%06X", max(0, min(0xffffff, value.intValue))) }
        let text = value as? String ?? ""
        let rgb = text.hasPrefix("#") ? Int(String(text.dropFirst()), radix: 16) : Int(text) ?? Int(text, radix: 16)
        return String(format: "#%06X", max(0, min(0xffffff, rgb ?? 0xffffff)))
    }
    private enum CodingKeys: String, CodingKey { case id, text, timeMs, color, mode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        timeMs = try values.decode(Int64.self, forKey: .timeMs)
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "#FFFFFF"
        mode = try values.decodeIfPresent(DanmakuMode.self, forKey: .mode) ?? .scroll
    }
}
