import Foundation

public struct TVPlannedDanmaku: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let time: Double
    public let duration: Double
    public let lane: Int
    public let width: CGFloat
    public let color: Int
    public let mode: DanmakuMode
    public init(id: String, text: String, time: Double, duration: Double, lane: Int, width: CGFloat, color: Int = 0xffffff, mode: DanmakuMode = .scroll) {
        self.id = id; self.text = text; self.time = time; self.duration = duration; self.lane = lane; self.width = width; self.color = color; self.mode = mode
    }
}
