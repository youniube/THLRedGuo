import SwiftUI
import Metal
import Libmpv

private final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1 && newValue.height > 1 { super.drawableSize = newValue } }
    }
}

private final class MPVSurfaceView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metal = layer as? CAMetalLayer else { return }
        metal.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        metal.drawableSize = CGSize(width: bounds.width * metal.contentsScale, height: bounds.height * metal.contentsScale)
    }
}

@MainActor
public final class MPVPlaybackController: ObservableObject {
    struct Snapshot {
        let position: Double
        let duration: Double
        let playing: Bool
        let buffering: Bool
        let ready: Bool
    }

    let surface: UIView = MPVSurfaceView()
    var onUpdate: ((Snapshot) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var handle: OpaquePointer?
    private var timer: Timer?
    private var loaded = false
    private var renderedVideo = false
    private var requestedPlayback = true
    private var loadedAt = Date()
    private var lastPosition = 0.0
    private var lastDuration = 0.0
    private var completedPosition: Double?

    init(plan: PlaybackPlan, position: Double, rate: Float, play: Bool) throws {
        guard let context = mpv_create() else { throw Self.failure("无法初始化兼容播放器") }
        handle = context
        do {
            surface.backgroundColor = .black
            var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(surface.layer).toOpaque()))
            try check(mpv_set_option(context, "wid", MPV_FORMAT_INT64, &layerPointer))
            for (name, value) in [
                "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
                "hwdec": "auto-safe", "idle": "yes", "keep-open": "no",
                "network-timeout": "20", "pause": play ? "no" : "yes",
                "start": String(max(0, position)), "speed": String(rate)
            ] {
                try check(mpv_set_option_string(context, name, value))
            }
            try setHeaders(plan.headers, context: context)
            try check(mpv_initialize(context))
            requestedPlayback = play
            try command(["loadfile", plan.url, "replace"])
            loadedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch {
            close()
            throw error
        }
    }

    func play(rate: Float) {
        setRate(rate)
        requestedPlayback = true
        setFlag("pause", false)
    }

    func pause() {
        requestedPlayback = false
        setFlag("pause", true)
    }

    func seek(to position: Double) {
        do { try command(["seek", String(max(0, position)), "absolute+exact"]) }
        catch { onFailure?(error.localizedDescription) }
    }

    func setRate(_ rate: Float) {
        guard let handle else { return }
        var value = Double(rate)
        mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    var position: Double { completedPosition ?? number("time-pos") }

    func close() {
        timer?.invalidate()
        timer = nil
        onUpdate = nil
        onEnded = nil
        onFailure = nil
        if let handle {
            self.handle = nil
            mpv_terminate_destroy(handle)
        }
    }

    private func poll() {
        guard let handle else { return }
        var ended = false
        var failure: String?
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            if event.pointee.event_id == MPV_EVENT_FILE_LOADED { loaded = true }
            if event.pointee.event_id == MPV_EVENT_END_FILE, let data = event.pointee.data {
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_EOF { ended = true }
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    failure = String(cString: mpv_error_string(end.error))
                }
            }
        }
        if ended {
            completedPosition = max(lastPosition, lastDuration)
            requestedPlayback = false
            timer?.invalidate()
            timer = nil
            onEnded?()
            return
        }
        let ready = loaded && number("video-params/w") > 0 && number("video-params/h") > 0
        renderedVideo = renderedVideo || ready
        if !renderedVideo && Date().timeIntervalSince(loadedAt) > 30 { failure = "兼容播放器加载视频超时" }
        let buffering = !ready || flag("paused-for-cache")
        lastPosition = position
        let duration = number("duration")
        if duration > 0 { lastDuration = duration }
        onUpdate?(Snapshot(position: lastPosition, duration: duration, playing: requestedPlayback && ready && !buffering && !flag("pause"), buffering: requestedPlayback && buffering, ready: ready))
        if let failure {
            let callback = onFailure
            pause()
            timer?.invalidate()
            timer = nil
            callback?(failure)
        }
    }

    private func number(_ name: String) -> Double {
        guard let handle else { return 0 }
        var value = 0.0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return 0 }
        return max(0, value)
    }

    private func flag(_ name: String) -> Bool {
        guard let handle else { return false }
        var value: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
        return value != 0
    }

    private func setFlag(_ name: String, _ enabled: Bool) {
        guard let handle else { return }
        var value: Int32 = enabled ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value)
    }

    private func setHeaders(_ headers: [String: String], context: OpaquePointer) throws {
        var nodes = headers.sorted { $0.key < $1.key }.map { field -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = strdup("\(field.key): \(field.value)")
            return node
        }
        defer { nodes.forEach { free($0.u.string) } }
        let count = Int32(nodes.count)
        if count == 0 { return }
        try nodes.withUnsafeMutableBufferPointer { buffer in
            var list = mpv_node_list(num: count, values: buffer.baseAddress, keys: nil)
            try withUnsafeMutablePointer(to: &list) { pointer in
                var root = mpv_node()
                root.format = MPV_FORMAT_NODE_ARRAY
                root.u.list = pointer
                try check(mpv_set_option(context, "http-header-fields", MPV_FORMAT_NODE, &root))
            }
        }
    }

    private func command(_ arguments: [String]) throws {
        guard let handle else { return }
        var values = arguments.map { UnsafePointer<CChar>(strdup($0)) }
        values.append(nil)
        defer { values.forEach { if let value = $0 { free(UnsafeMutablePointer(mutating: value)) } } }
        try check(mpv_command(handle, &values))
    }

    private func check(_ result: Int32) throws {
        if result < 0 { throw Self.failure(String(cString: mpv_error_string(result))) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CompatibilityPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct MPVPlayerView: UIViewRepresentable {
    let controller: MPVPlaybackController

    func makeUIView(context: Context) -> UIView { controller.surface }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
