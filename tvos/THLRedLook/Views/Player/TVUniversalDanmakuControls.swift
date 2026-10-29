import SwiftUI

@MainActor
public struct TVUniversalDanmakuControls: View {
    @ObservedObject var session: TVUniversalDanmaku
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var apiName = ""
    @State private var editingURL: String?
    @State private var notice = ""
    @State private var keyword = ""
    @State private var offset = "0"
    @State private var mode = "automatic"
    @State private var error = ""
    @State private var candidates: [TVDanmakuCandidate] = []
    @State private var episodes: [TVLibraryEpisode] = []
    @State private var selected: TVDanmakuCandidate?
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var mediaKey: String?

    public var body: some View {
        NavigationStack {
            Form {
                if !session.sources.isEmpty {
                    Section("已保存 API") {
                        ForEach(session.sources) { source in
                            HStack {
                                Button((session.baseURL == source.baseURL ? "✓ " : "") + source.name) {
                                    session.selectAPI(source.baseURL); edit(source); clearSearch(); onChanged()
                                }
                                Menu("管理") {
                                    Button("编辑") { edit(source) }
                                    Button("检测连接") { Task {
                                        do { try await session.probe(source); notice = source.name + "：连接与搜索格式正常" }
                                        catch { notice = source.name + "：检测失败，请检查服务地址" }
                                    } }
                                    Button("删除", role: .destructive) {
                                        session.deleteAPI(source.baseURL); address = session.baseURL
                                        apiName = session.sources.first(where: { $0.baseURL == address })?.name ?? ""
                                        editingURL = address.isEmpty ? nil : address
                                        clearSearch(); onChanged()
                                    }
                                }
                            }
                        }
                    }
                }
                Section("通用弹幕 API") {
                    TextField("API 名称", text: $apiName)
                    TextField("HTTP(S) 服务基础地址，可包含路径或令牌", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("弹幕来源", selection: $mode) {
                        Text("自动：优先原站，否则通用 API").tag("automatic")
                        Text("仅使用原站弹幕").tag("native")
                        Text("使用通用弹幕 API").tag("external")
                    }
                    Button("保存 API") {
                        do { try session.saveAPI(name: apiName, address: address, replacing: editingURL)
                            try session.configure(address, mode: mode); editingURL = session.baseURL
                            error = ""; clearSearch(); onChanged() }
                        catch { self.error = error.localizedDescription }
                    }
                    Button("添加其他 API") { apiName = ""; address = ""; editingURL = nil }.disabled(session.sources.count >= 16)
                    Button("保存弹幕来源设置") {
                        do { try session.configure(session.baseURL, mode: mode); error = ""; onChanged() }
                        catch { self.error = error.localizedDescription }
                    }
                    Toggle("自动匹配", isOn: Binding(get: { session.autoMatch }, set: { session.setAutoMatch($0); onChanged() }))
                    Text(session.status.isEmpty ? "兼容 danmu_api，不设置固定的公共服务器。" : session.status)
                    if !notice.isEmpty { Text(notice) }
                }
                if session.media != nil {
                    Section("手动匹配弹幕") {
                        TextField("影视名称", text: $keyword)
                        Button(loading ? "正在查询…" : "搜索作品") { search() }.disabled(loading || session.baseURL.isEmpty || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let selected {
                            Text(selected.title)
                            ForEach(episodes) { episode in
                                Button(episode.title) {
                                    guard session.media?.key == mediaKey else { error = "播放分集已变化，请关闭后重新匹配"; return }
                                    session.choose(selected, episode)
                                    onChanged()
                                    dismiss()
                                }
                            }
                        } else {
                            ForEach(candidates) { candidate in Button(candidate.title) { loadEpisodes(candidate) }.disabled(loading) }
                        }
                        Button("重新自动匹配") { Task { await session.reset(); onChanged(); candidates = []; episodes = []; selected = nil } }
                    }
                    Section("弹幕时间偏移") {
                        TextField("秒，正数延后，负数提前", text: $offset)
                        Button("保存时间偏移") {
                            guard session.media?.key == mediaKey else { error = "播放分集已变化，请关闭后重新匹配"; return }
                            guard let value = Double(offset), value.isFinite, abs(value) <= 1800 else { error = "请输入 -1800 到 1800 秒"; return }
                            session.setOffset(Int64((value * 1000).rounded()))
                            onChanged()
                        }
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
                Button("完成") { dismiss() }
            }
            .navigationTitle("弹幕来源与匹配")
        }
        .onAppear {
            address = session.baseURL
            apiName = session.sources.first(where: { $0.baseURL == session.baseURL })?.name ?? ""
            editingURL = address.isEmpty ? nil : address
            mode = session.mode
            keyword = session.media?.title ?? ""
            offset = String(Double(session.offsetMs) / 1000)
            mediaKey = session.media?.key
        }
        .onDisappear { requestID = UUID() }
        .onExitCommand { dismiss() }
    }

    private func edit(_ source: TVDanmakuAPISource) {
        apiName = source.name; address = source.baseURL; editingURL = source.baseURL
    }
    private func clearSearch() { requestID = UUID(); loading = false; candidates = []; episodes = []; selected = nil }

    private func search() {
        loading = true
        error = ""
        let ticket = UUID()
        requestID = ticket
        Task {
            defer { if requestID == ticket { loading = false } }
            do {
                let rows = try await session.search(keyword)
                guard requestID == ticket else { return }
                candidates = rows
                episodes = []
                selected = nil
                if rows.isEmpty { error = "没有搜索结果，请尝试其他片名" }
            } catch { if requestID == ticket { self.error = "弹幕查询失败，请检查 API 后重试" } }
        }
    }

    private func loadEpisodes(_ candidate: TVDanmakuCandidate) {
        loading = true
        error = ""
        let ticket = UUID()
        requestID = ticket
        Task {
            defer { if requestID == ticket { loading = false } }
            do {
                let rows = try await session.episodes(candidate)
                guard requestID == ticket else { return }
                selected = candidate
                episodes = rows
            } catch { if requestID == ticket { self.error = "分集查询失败，请重试" } }
        }
    }
}
