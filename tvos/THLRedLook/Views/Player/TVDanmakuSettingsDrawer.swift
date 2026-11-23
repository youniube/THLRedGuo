import SwiftUI

// MARK: - 弹幕偏好与参数调节大屏抽屉
public struct TVDanmakuSettingsDrawer: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isPresented: Bool

    @FocusState private var focusedButton: String?
    @State private var showingLibrary = false
    @State private var showingDisplay = false

    public init(viewModel: PlayerViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("弹幕设置")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(TVColors.textPrimary)
                        Text("个性化调整弹幕大小、透明度与展示区域")
                            .font(.system(size: 20))
                            .foregroundColor(TVColors.textSecondary)
                    }
                    Spacer()
                    Text("按 Menu 返回")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(TVColors.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.bottom, 8)

                Divider()
                    .background(TVColors.borderSubtle)

                // 1. 弹幕总开关
                VStack(alignment: .leading, spacing: 14) {
                    Text("弹幕显示")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVColors.textSecondary)
                    HStack(spacing: 16) {
                        settingOptionButton(
                            title: "开启",
                            isSelected: viewModel.danmakuEnabled,
                            id: "danmaku.switch.on",
                            down: "danmaku.font.small",
                            right: "danmaku.switch.off"
                        ) {
                            if !viewModel.danmakuEnabled { viewModel.danmakuEnabled = true }
                        }
                        settingOptionButton(
                            title: "关闭",
                            isSelected: !viewModel.danmakuEnabled,
                            id: "danmaku.switch.off",
                            down: "danmaku.font.large",
                            left: "danmaku.switch.on"
                        ) {
                            if viewModel.danmakuEnabled { viewModel.danmakuEnabled = false }
                        }
                    }
                }

                // 2. 字体大小
                VStack(alignment: .leading, spacing: 14) {
                    Text("字体大小")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVColors.textSecondary)
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
                VStack(alignment: .leading, spacing: 14) {
                    Text("不透明度")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVColors.textSecondary)
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
                VStack(alignment: .leading, spacing: 14) {
                    Text("显示区域")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(TVColors.textSecondary)
                    HStack(spacing: 16) {
                        settingOptionButton(
                            title: "半屏 (4轨)",
                            isSelected: viewModel.danmakuStyle.laneCount == 4,
                            id: "danmaku.area.half",
                            up: "danmaku.opacity.50",
                            down: "danmaku.sources",
                            right: "danmaku.area.full"
                        ) {
                            viewModel.setDanmakuLaneCount(4)
                        }
                        settingOptionButton(
                            title: "全屏 (8轨)",
                            isSelected: viewModel.danmakuStyle.laneCount == 8,
                            id: "danmaku.area.full",
                            up: "danmaku.opacity.100",
                            down: "danmaku.advanced",
                            left: "danmaku.area.half"
                        ) {
                            viewModel.setDanmakuLaneCount(8)
                        }
                    }
                }

                HStack(spacing: 16) {
                    settingOptionButton(title: "弹幕来源", isSelected: false, id: "danmaku.sources",
                                        up: "danmaku.area.half", right: "danmaku.advanced") {
                        showingLibrary = true
                    }
                    settingOptionButton(title: "高级设置", isSelected: false, id: "danmaku.advanced",
                                        up: "danmaku.area.full", left: "danmaku.sources") {
                        showingDisplay = true
                    }
                }
                Spacer()
            }
            .padding(40)
            .frame(width: 720)
            .frame(maxHeight: .infinity)
            .background(TVColors.drawerBackground)
            .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .sheet(isPresented: $showingLibrary) {
            TVUniversalDanmakuControls(session: viewModel.universalDanmaku, onChanged: viewModel.reloadDanmaku)
        }
        .sheet(isPresented: $showingDisplay) {
            TVDanmakuDisplayControls(viewModel: viewModel)
        }
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
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .heavy))
                    .opacity(isSelected ? 1.0 : 0.0)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected
                          ? (isFocused ? TVColors.primaryHover : TVColors.primary)
                          : (isFocused ? TVColors.surfaceFocused : TVColors.surfaceCard))
            )
            .foregroundColor(TVColors.textPrimary)
            .tvFocusBorder(isFocused: isFocused, cornerRadius: 14)
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

#Preview("TVDanmakuSettingsDrawer") {
    TVDanmakuSettingsDrawer(
        viewModel: PlayerViewModel(drama: Drama(id: "1", title: "测试"), allEpisodes: [Episode(id: "1", title: "第 1 集", number: 1)]),
        isPresented: .constant(true)
    )
}

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
