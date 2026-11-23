import SwiftUI
import UIKit

public struct TVDanmakuView: View {
    public let danmakus: [DanmakuItem]
    public let position: Double
    public let anchor: Date
    public let rate: Double
    public let moving: Bool
    public var style: TVDanmakuStyle = TVDanmakuStyle()

    @Environment(\.displayScale) private var displayScale
    @State private var coordinator = TVDanmakuTrackCoordinator()

    public init(
        danmakus: [DanmakuItem],
        position: Double,
        anchor: Date,
        rate: Double,
        moving: Bool,
        style: TVDanmakuStyle = TVDanmakuStyle()
    ) {
        self.danmakus = danmakus
        self.position = position
        self.anchor = anchor
        self.rate = rate
        self.moving = moving
        self.style = style
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = size.width
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                let time = playbackTime(at: timeline.date)
                ZStack(alignment: .topLeading) {
                    ForEach(sprites, id: \.flight.id) { sprite in
                        let item = sprite.flight
                        let age = time - item.time
                        if age >= 0, age < item.duration {
                            let x = item.mode == .scroll
                                ? width + item.width / 2 - (width + item.width) * age / item.duration
                                : width / 2
                            let y = CGFloat(item.lane) * (style.fontSize * 1.85 + 10) + 54
                            sprite.image.opacity(style.opacity).position(x: x, y: y)
                        }
                    }
                }
            }
            .onAppear { refresh(size: size) }
            .onChange(of: danmakus) { _, _ in refresh(size: size) }
            .onChange(of: position) { _, _ in refresh(size: size) }
            .onChange(of: style) { _, _ in rebuild(size: size) }
            .onChange(of: size) { _, _ in rebuild(size: size) }
            .onChange(of: displayScale) { _, _ in rebuild(size: size) }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @State private var sprites: [Sprite] = []

    private struct Sprite {
        let flight: TVPlannedDanmaku
        let image: Image
    }

    func playbackTime(at date: Date) -> Double {
        position + (moving ? min(0.75, max(0, date.timeIntervalSince(anchor))) * rate : 0)
    }

    private func rebuild(size: CGSize) {
        coordinator.reset()
        sprites = []
        refresh(size: size)
    }

    private func refresh(size: CGSize) {
        guard !danmakus.isEmpty else {
            coordinator.reset()
            sprites = []
            return
        }
        let rowHeight = style.fontSize * 1.85 + 10
        let inset = style.subtitleSafe ? size.height * 0.12 : 12
        let totalRows = max(0, Int((size.height - inset - 54) / rowHeight))
        let visibleRows = max(0, Int((size.height * CGFloat(style.displayArea) - 54) / rowHeight))
        let flights = coordinator.updateAndGetFlights(
            danmakus: danmakus, currentTime: position, screenWidth: size.width,
            laneCount: min(style.laneCount, visibleRows), fontSize: style.fontSize,
            style: style, totalRows: totalRows
        )
        let existing = Dictionary(uniqueKeysWithValues: sprites.map { ($0.flight.id, $0) })
        sprites = flights.map { flight in
            if let sprite = existing[flight.id], sprite.flight == flight { return sprite }
            let image = Self.renderText(
                flight.text, fontSize: style.fontSize, width: flight.width, scale: displayScale,
                rgb: style.useOriginalColor ? flight.color : style.color,
                drawsOutline: style.outline, drawsShadow: style.shadow
            )
            return Sprite(flight: flight, image: Image(uiImage: image).renderingMode(.original))
        }
    }

    static func renderText(
        _ text: String, fontSize: CGFloat, width: CGFloat, scale: CGFloat,
        rgb: Int = 0xffffff, drawsOutline: Bool = true, drawsShadow: Bool = true
    ) -> UIImage {
        let font = UIFont.boldSystemFont(ofSize: fontSize)
        let size = CGSize(width: ceil(width), height: ceil(font.lineHeight) + 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let origin = CGPoint(x: 8, y: 4)
            let outline = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black])
            if drawsShadow {
                context.cgContext.saveGState()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: UIColor.black.withAlphaComponent(0.8).cgColor)
                outline.draw(at: origin)
                context.cgContext.restoreGState()
            }
            if drawsOutline {
                for offset in [CGPoint(x: 1.5, y: 0), CGPoint(x: -1.5, y: 0),
                               CGPoint(x: 0, y: 1.5), CGPoint(x: 0, y: -1.5),
                               CGPoint(x: 1.2, y: 1.2), CGPoint(x: -1.2, y: -1.2),
                               CGPoint(x: 1.2, y: -1.2), CGPoint(x: -1.2, y: 1.2)] {
                    outline.draw(at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y))
                }
            }
            let color = UIColor(
                red: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1
            )
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                .draw(at: origin)
        }.withRenderingMode(.alwaysOriginal)
    }
}

#Preview("TVDanmakuView") {
    TVDanmakuView(
        danmakus: [
            DanmakuItem(id: "1", text: "前方高能！", timeMs: 1000),
            DanmakuItem(id: "2", text: "太刺激了这剧！", timeMs: 2500)
        ],
        position: 2.0,
        anchor: Date(),
        rate: 1.0,
        moving: true
    )
    .background(TVColors.background)
}
