import SwiftUI
import UIKit

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
            let width = (text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: fontSize)]).width + 36
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

public enum TVDanmakuPlanner {
    public static func calculateDuration(for id: String, text: String) -> Double {
        return 8.0
    }

    public static func plan(danmakus: [DanmakuItem], screenWidth: CGFloat, laneCount: Int = 8, fontSize: CGFloat = 26.0) -> [TVPlannedDanmaku] {
        let coordinator = TVDanmakuTrackCoordinator()
        let maxTime = danmakus.map { Double($0.timeMs) / 1000.0 }.max() ?? 0
        return coordinator.updateAndGetFlights(danmakus: danmakus, currentTime: maxTime, screenWidth: screenWidth, laneCount: laneCount, fontSize: fontSize)
    }
}

public struct TVDanmakuView: View {
    public let danmakus: [DanmakuItem]
    public let position: Double
    public let anchor: Date
    public let rate: Double
    public let moving: Bool
    public var style: TVDanmakuStyle = TVDanmakuStyle()

    @State private var coordinator = TVDanmakuTrackCoordinator()

    public var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width > 0 ? proxy.size.width : 1920

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
                let time = position + (moving ? min(0.75, max(0, timeline.date.timeIntervalSince(anchor))) * rate : 0)
                let flights = coordinator.updateAndGetFlights(
                    danmakus: danmakus,
                    currentTime: time,
                    screenWidth: w,
                    laneCount: min(style.laneCount, max(0, Int((proxy.size.height * CGFloat(style.displayArea) - 54) / (style.fontSize * 1.85 + 10)))),
                    fontSize: style.fontSize,
                    style: style,
                    totalRows: max(0, Int((proxy.size.height - (style.subtitleSafe ? proxy.size.height * 0.12 : 12) - 54) / (style.fontSize * 1.85 + 10)))
                )

                ZStack(alignment: .topLeading) {
                    ForEach(flights) { item in
                        let age = time - item.time
                        if age >= 0 && age < item.duration {
                            let progress = age / item.duration
                            let trackHeight = style.fontSize * 1.85 + 10
                            let yPosition = CGFloat(item.lane) * trackHeight + 54

                            danmakuItemView(item: item)
                                .position(
                                    x: item.mode == .scroll ? w + item.width / 2 - (w + item.width) * progress : w / 2,
                                    y: yPosition
                                )
                        }
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func danmakuItemView(item: TVPlannedDanmaku) -> some View {
        let rgb = style.useOriginalColor ? item.color : style.color
        let color = Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        Text(item.text)
            .lineLimit(1)
            .font(.system(size: style.fontSize, weight: .heavy, design: .rounded))
            .foregroundColor(color.opacity(style.opacity))
            // 8 方向 1.5pt 高对比度深黑描边（强光、白底、复杂背景下字体轮廓极其锐利清爽）
            .shadow(color: .black.opacity(style.outline ? style.opacity : 0), radius: 0, x: 1.5, y: 0)
            .shadow(color: .black.opacity(style.outline ? style.opacity : 0), radius: 0, x: -1.5, y: 0)
            .shadow(color: .black.opacity(style.outline ? style.opacity : 0), radius: 0, x: 0, y: 1.5)
            .shadow(color: .black.opacity(style.outline ? style.opacity : 0), radius: 0, x: 0, y: -1.5)
            .shadow(color: .black.opacity(style.outline ? style.opacity * 0.95 : 0), radius: 0, x: 1.2, y: 1.2)
            .shadow(color: .black.opacity(style.outline ? style.opacity * 0.95 : 0), radius: 0, x: -1.2, y: -1.2)
            .shadow(color: .black.opacity(style.outline ? style.opacity * 0.95 : 0), radius: 0, x: 1.2, y: -1.2)
            .shadow(color: .black.opacity(style.outline ? style.opacity * 0.95 : 0), radius: 0, x: -1.2, y: 1.2)
            // 外部柔和深影增强大屏立体感
            .shadow(color: .black.opacity(style.shadow ? style.opacity * 0.8 : 0), radius: 4, x: 0, y: 2)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.32 * style.opacity))
            )
            .fixedSize()
            .frame(width: item.width)
    }
}

public struct TVEpisodeDrawer: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isPresented: Bool

    @FocusState private var focusedEpisode: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)

    public var body: some View {
        ZStack(alignment: .trailing) {
            // 全屏一体化深色蒙层（彻底覆盖包含安全区的所有视口，杜绝局部非全屏色块）
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // 右侧抽屉卡片主体
            VStack(alignment: .leading, spacing: 0) {
                // 顶部标题与提示
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选集播放")
                            .font(.title2)
                            .bold()
                            .foregroundColor(TVTheme.textPrimary)
                        Text("共 \(viewModel.allEpisodes.count) 集 · 当前第 \(viewModel.currentEpisodeIndex) 集")
                            .font(.subheadline)
                            .foregroundColor(TVTheme.textSecondary)
                    }
                    Spacer()
                    Text("按 Menu 返回")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(TVTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 20)

                Divider()
                    .background(Color.white.opacity(0.12))

                // 集数网格
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 5), spacing: 20) {
                            ForEach(viewModel.allEpisodes) { ep in
                                let isCurrent = (viewModel.currentEpisodeIndex == ep.number)
                                Button(action: {
                                    let targetNumber = ep.number
                                    NSLog("🎬 [Drawer] 点击 第%d集 按钮", targetNumber)
                                    isPresented = false
                                    Task {
                                        await viewModel.selectEpisode(number: targetNumber)
                                    }
                                }) {
                                    VStack(spacing: 6) {
                                        Text("\(ep.number)")
                                            .font(.system(size: 24, weight: isCurrent ? .black : .bold))
                                        if ep.vip {
                                            Text("VIP")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(TVTheme.vipAccent)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 76)
                                }
                                .buttonStyle(TvButtonStyle(
                                    variant: isCurrent ? .primary : .plain,
                                    cornerRadius: 14,
                                    isFocused: focusedEpisode == ep.number
                                ))
                                .focused($focusedEpisode, equals: ep.number)
                                .accessibilityIdentifier("drawer.episode.\(ep.number)")
                                .id(ep.number)
                                .padding(4)
                            }
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                        .padding(.horizontal, 28)
                    }
                    .onAppear {
                        scrollProxy.scrollTo(viewModel.currentEpisodeIndex, anchor: .center)
                    }
                }
            }
            .frame(width: 760)
            .frame(maxHeight: .infinity)
            .background(
                Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.96)
            )
            .ignoresSafeArea()
            .defaultFocus($focusedEpisode, viewModel.currentEpisodeIndex)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onExitCommand {
            isPresented = false
        }
        .onAppear {
            let targetEp = viewModel.currentEpisodeIndex
            NSLog("🎬 [Drawer] TVEpisodeDrawer onAppear, targetEp=%d", targetEp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedEpisode = targetEp
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if focusedEpisode == nil {
                    focusedEpisode = targetEp
                }
            }
        }
    }
}

public struct TVDanmakuSettingsDrawer: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isPresented: Bool

    @FocusState private var focusedButton: String?
    @State private var showingLibrary = false
    @State private var showingDisplay = false

    public var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("弹幕设置")
                            .font(.title2)
                            .bold()
                            .foregroundColor(TVTheme.textPrimary)
                        Text("个性化调整弹幕大小、透明度与展示区域")
                            .font(.subheadline)
                            .foregroundColor(TVTheme.textSecondary)
                    }
                    Spacer()
                    Text("按 Menu 返回")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(TVTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 8)

                Divider()
                    .background(Color.white.opacity(0.12))

                // 1. 弹幕总开关
                VStack(alignment: .leading, spacing: 12) {
                    Text("弹幕显示")
                        .font(.headline)
                        .foregroundColor(TVTheme.textSecondary)
                    HStack(spacing: 16) {
                        settingOptionButton(
                            title: "开启",
                            isSelected: viewModel.danmakuEnabled,
                            id: "danmaku.switch.on",
                            down: "danmaku.font.small",
                            right: "danmaku.switch.off"
                        ) {
                            if !viewModel.danmakuEnabled { viewModel.toggleDanmaku() }
                        }
                        settingOptionButton(
                            title: "关闭",
                            isSelected: !viewModel.danmakuEnabled,
                            id: "danmaku.switch.off",
                            down: "danmaku.font.large",
                            left: "danmaku.switch.on"
                        ) {
                            if viewModel.danmakuEnabled { viewModel.toggleDanmaku() }
                        }
                    }
                }

                // 2. 字体大小
                VStack(alignment: .leading, spacing: 12) {
                    Text("字体大小")
                        .font(.headline)
                        .foregroundColor(TVTheme.textSecondary)
                    HStack(spacing: 16) {
                        settingOptionButton(
                            title: "小 (20pt)",
                            isSelected: viewModel.danmakuStyle.fontSize == 20.0,
                            id: "danmaku.font.small",
                            up: "danmaku.switch.on",
                            down: "danmaku.opacity.50",
                            right: "danmaku.font.standard"
                        ) {
                            viewModel.setDanmakuFontSize(20.0)
                        }
                        settingOptionButton(
                            title: "标准 (26pt)",
                            isSelected: viewModel.danmakuStyle.fontSize == 26.0,
                            id: "danmaku.font.standard",
                            up: "danmaku.switch.on",
                            down: "danmaku.opacity.75",
                            left: "danmaku.font.small",
                            right: "danmaku.font.large"
                        ) {
                            viewModel.setDanmakuFontSize(26.0)
                        }
                        settingOptionButton(
                            title: "大 (34pt)",
                            isSelected: viewModel.danmakuStyle.fontSize == 34.0,
                            id: "danmaku.font.large",
                            up: "danmaku.switch.off",
                            down: "danmaku.opacity.100",
                            left: "danmaku.font.standard"
                        ) {
                            viewModel.setDanmakuFontSize(34.0)
                        }
                    }
                }

                // 3. 不透明度
                VStack(alignment: .leading, spacing: 12) {
                    Text("不透明度")
                        .font(.headline)
                        .foregroundColor(TVTheme.textSecondary)
                    HStack(spacing: 16) {
                        settingOptionButton(
                            title: "50%",
                            isSelected: viewModel.danmakuStyle.opacity == 0.5,
                            id: "danmaku.opacity.50",
                            up: "danmaku.font.small",
                            down: "danmaku.area.half",
                            right: "danmaku.opacity.75"
                        ) {
                            viewModel.setDanmakuOpacity(0.5)
                        }
                        settingOptionButton(
                            title: "75%",
                            isSelected: viewModel.danmakuStyle.opacity == 0.75,
                            id: "danmaku.opacity.75",
                            up: "danmaku.font.standard",
                            down: "danmaku.area.half",
                            left: "danmaku.opacity.50",
                            right: "danmaku.opacity.100"
                        ) {
                            viewModel.setDanmakuOpacity(0.75)
                        }
                        settingOptionButton(
                            title: "100%",
                            isSelected: viewModel.danmakuStyle.opacity == 1.0,
                            id: "danmaku.opacity.100",
                            up: "danmaku.font.large",
                            down: "danmaku.area.full",
                            left: "danmaku.opacity.75"
                        ) {
                            viewModel.setDanmakuOpacity(1.0)
                        }
                    }
                }

                // 4. 显示区域
                VStack(alignment: .leading, spacing: 12) {
                    Text("显示区域")
                        .font(.headline)
                        .foregroundColor(TVTheme.textSecondary)
                    HStack(spacing: 16) {
                        settingOptionButton(
                            title: "半屏 (4轨)",
                            isSelected: viewModel.danmakuStyle.laneCount == 4,
                            id: "danmaku.area.half",
                            up: "danmaku.opacity.50",
                            down: "danmaku.library",
                            right: "danmaku.area.full"
                        ) {
                            viewModel.setDanmakuLaneCount(4)
                        }
                        settingOptionButton(
                            title: "全屏 (8轨)",
                            isSelected: viewModel.danmakuStyle.laneCount == 8,
                            id: "danmaku.area.full",
                            up: "danmaku.opacity.100",
                            down: "danmaku.library",
                            left: "danmaku.area.half"
                        ) {
                            viewModel.setDanmakuLaneCount(8)
                        }
                    }
                }

                HStack(spacing: 16) {
                    settingOptionButton(title: "显示与高级设置", isSelected: false, id: "danmaku.display", up: "danmaku.area.half", down: "danmaku.close", right: "danmaku.library") { showingDisplay = true }
                    settingOptionButton(title: "弹幕来源与匹配", isSelected: false, id: "danmaku.library", up: "danmaku.area.full", down: "danmaku.close", left: "danmaku.display") { showingLibrary = true }
                }

                Spacer()

                Button(action: {
                    isPresented = false
                }) {
                    Text("完成设置")
                        .font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(focusedButton == "danmaku.close" ? TVTheme.primaryHover : TVTheme.primary)
                        )
                        .foregroundColor(.white)
                        .tvFocusBorder(isFocused: focusedButton == "danmaku.close", cornerRadius: 14)
                }
                .buttonStyle(TVZeroHighlightButtonStyle())
                .focused($focusedButton, equals: "danmaku.close")
                .accessibilityIdentifier("danmaku.close")
                .focusEffectDisabled()
                .onMoveCommand { dir in
                    if dir == .up { focusedButton = "danmaku.library" }
                }
            }
            .padding(40)
            .frame(width: 720)
            .frame(maxHeight: .infinity)
            .background(
                Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.96)
            )
            .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .sheet(isPresented: $showingLibrary) {
            TVUniversalDanmakuControls(session: viewModel.universalDanmaku, onChanged: viewModel.reloadDanmaku)
        }
        .sheet(isPresented: $showingDisplay) { TVDanmakuDisplayControls(viewModel: viewModel) }
        .onExitCommand {
            isPresented = false
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedButton = viewModel.danmakuEnabled ? "danmaku.switch.on" : "danmaku.switch.off"
            }
        }
    }

    @ViewBuilder
    private func settingOptionButton(
        title: String,
        isSelected: Bool,
        id: String,
        up: String? = nil,
        down: String? = nil,
        left: String? = nil,
        right: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = (focusedButton == id)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .opacity(isSelected ? 1.0 : 0.0)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected
                          ? (isFocused ? TVTheme.primaryHover : TVTheme.primary)
                          : (isFocused ? TVTheme.surfaceFocused : TVTheme.surfaceCard))
            )
            .foregroundColor(TVTheme.textPrimary)
            .tvFocusBorder(isFocused: isFocused, cornerRadius: 12)
        }
        .buttonStyle(TVZeroHighlightButtonStyle())
        .focused($focusedButton, equals: id)
        .accessibilityIdentifier(id)
        .focusEffectDisabled()
        .onMoveCommand { dir in
            switch dir {
            case .up:
                if let up { focusedButton = up }
            case .down:
                if let down { focusedButton = down }
            case .left:
                if let left { focusedButton = left }
            case .right:
                if let right { focusedButton = right }
            default: break
            }
        }
    }
}

public struct TVSpeedSelectionDrawer: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isPresented: Bool

    @FocusState private var focusedSpeed: Float?

    private let speedOptions: [(label: String, rate: Float, id: String)] = [
        ("0.75x", 0.75, "player.speed.0.75"),
        ("1.0x (正常)", 1.0, "player.speed.1.0"),
        ("1.25x", 1.25, "player.speed.1.25"),
        ("1.5x", 1.5, "player.speed.1.5"),
        ("2.0x", 2.0, "player.speed.2.0")
    ]

    public var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("播放倍速")
                            .font(.title2)
                            .bold()
                            .foregroundColor(TVTheme.textPrimary)
                        Text("选择当前视频的播放速率")
                            .font(.subheadline)
                            .foregroundColor(TVTheme.textSecondary)
                    }
                    Spacer()
                    Text("按 Menu 返回")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(TVTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 8)

                Divider()
                    .background(Color.white.opacity(0.12))

                VStack(spacing: 16) {
                    ForEach(speedOptions, id: \.rate) { opt in
                        let isSelected = abs(viewModel.playbackRate - opt.rate) < 0.05
                        let isFocused = (focusedSpeed == opt.rate)

                        Button(action: {
                            NSLog("🎬 [SpeedSheet] 选择倍速: %.2fx", opt.rate)
                            viewModel.setRate(opt.rate)
                            viewModel.showToast("已切换至 \(opt.label) 倍速")
                            isPresented = false
                        }) {
                            HStack {
                                Text(opt.label)
                                    .font(.system(size: 22, weight: isSelected ? .black : .bold))
                                    .foregroundColor(TVTheme.textPrimary)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(TVTheme.textPrimary)
                                    .opacity(isSelected ? 1.0 : 0.0)
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(isSelected
                                          ? (isFocused ? TVTheme.primaryHover : TVTheme.primary)
                                          : (isFocused ? TVTheme.surfaceFocused : TVTheme.surfaceCard))
                            )
                            .tvFocusBorder(isFocused: isFocused, cornerRadius: 14)
                        }
                        .buttonStyle(TVZeroHighlightButtonStyle())
                        .focused($focusedSpeed, equals: opt.rate)
                        .accessibilityIdentifier(opt.id)
                        .focusEffectDisabled()
                        .onMoveCommand { dir in
                            guard let idx = speedOptions.firstIndex(where: { abs($0.rate - opt.rate) < 0.05 }) else { return }
                            if dir == .up && idx > 0 {
                                focusedSpeed = speedOptions[idx - 1].rate
                            } else if dir == .down && idx < speedOptions.count - 1 {
                                focusedSpeed = speedOptions[idx + 1].rate
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(40)
            .frame(width: 640)
            .frame(maxHeight: .infinity)
            .background(
                Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.96)
            )
            .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onExitCommand {
            isPresented = false
        }
        .onAppear {
            let currentRate = viewModel.playbackRate
            let matched = speedOptions.first { abs($0.rate - currentRate) < 0.05 }?.rate ?? 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedSpeed = matched
            }
        }
    }
}

@MainActor
public struct TVDanmakuDisplayControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var words = ""
    private func field<T>(_ key: WritableKeyPath<TVDanmakuStyle, T>) -> Binding<T> {
        Binding(get: { viewModel.danmakuStyle[keyPath: key] }, set: { value in
            var next = viewModel.danmakuStyle; next[keyPath: key] = value; viewModel.updateDanmakuStyle(next)
        })
    }
    public var body: some View {
        NavigationStack {
            Form {
                display
                layout
                filtering
                Button("恢复默认样式与过滤") { viewModel.updateDanmakuStyle(TVDanmakuStyle()); words = "" }
                Text("保留数据源、匹配记录和分集时间偏移。")
                Button("完成") { dismiss() }
            }.navigationTitle("弹幕显示与高级设置")
        }
        .onAppear { words = viewModel.danmakuStyle.keywords.joined(separator: "，") }
        .onExitCommand { dismiss() }
    }
    private var display: some View {
        Section("文字显示") {
            Text("这是一条弹幕效果预览")
                .font(.system(size: viewModel.danmakuStyle.fontSize, weight: .bold))
                .opacity(viewModel.danmakuStyle.opacity)
            Picker("字体大小", selection: field(\.fontSize)) {
                Text("小").tag(CGFloat(20)); Text("标准").tag(CGFloat(26)); Text("大").tag(CGFloat(34)); Text("特大").tag(CGFloat(40))
            }
            Picker("不透明度", selection: field(\.opacity)) {
                ForEach([0.1, 0.25, 0.4, 0.6, 0.8, 1.0], id: \.self) { value in Text("\(Int(value * 100))%").tag(value) }
            }
            Toggle("使用 API 原色", isOn: field(\.useOriginalColor))
            if !viewModel.danmakuStyle.useOriginalColor {
                Picker("统一颜色", selection: field(\.color)) {
                    Text("白色").tag(0xffffff); Text("柔黄").tag(0xffe6a7); Text("浅蓝").tag(0xa5e8ff); Text("薄荷").tag(0xc7f4c2); Text("浅粉").tag(0xffc8dd)
                }
            }
            Toggle("细描边", isOn: field(\.outline))
            Toggle("柔和阴影", isOn: field(\.shadow))
        }
    }
    private var layout: some View {
        Section("画面布局") {
            Picker("滚动与顶部弹幕区域", selection: field(\.displayArea)) {
                ForEach([0.25, 0.4, 0.5, 0.75, 1.0], id: \.self) { value in Text(value == 1 ? "全屏" : "\(Int(value * 100))%").tag(value) }
            }
            Picker("最多显示行数", selection: field(\.laneCount)) { ForEach([4, 8, 12, 16], id: \.self) { Text("\($0) 行").tag($0) } }
            Picker("弹幕密度", selection: field(\.density)) { Text("低 · 舒适").tag("low"); Text("中 · 均衡").tag("medium"); Text("高 · 热闹").tag("high") }
            Picker("滚动速度", selection: field(\.speed)) { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%.2fx", $0)).tag($0) } }
            Toggle("滚动弹幕", isOn: field(\.scroll))
            Toggle("顶部固定", isOn: field(\.top))
            Toggle("底部固定", isOn: field(\.bottom))
            Toggle("字幕避让", isOn: field(\.subtitleSafe))
        }
    }
    private var filtering: some View {
        Section("内容过滤") {
            TextField("屏蔽关键词，以逗号分隔", text: $words)
            Button("保存关键词") {
                var next = viewModel.danmakuStyle
                var seen = Set<String>()
                next.keywords = words.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
                    .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(100).map { $0 }
                viewModel.updateDanmakuStyle(next)
                words = next.keywords.joined(separator: "，")
            }
            Toggle("屏蔽彩色弹幕", isOn: field(\.blockColored))
            Text("过滤来源中带颜色的弹幕。")
        }
    }
}
