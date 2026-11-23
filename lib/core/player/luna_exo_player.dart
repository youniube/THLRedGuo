import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as kit;
import 'package:video_player/video_player.dart';
import 'package:THLRedLook/core/player/hls_compatibility.dart';
import 'package:THLRedLook/core/player/playback_engine.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';
import 'package:THLRedLook/utils/diary/diary_service.dart';
import 'package:THLRedLook/utils/screen/app_layout.dart';
import 'package:THLRedLook/core/player/playback_diagnostics.dart';
import 'package:THLRedLook/core/player/playback_preferences.dart';
import 'package:THLRedLook/core/player/playback_recovery.dart';
import 'package:THLRedLook/utils/media/video_output_size.dart';

VideoParams _systemVideoParameters(VideoPlayerValue value) {
  final size = value.size;
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) {
    return const VideoParams();
  }
  return VideoParams(
    w: size.width.round(),
    h: size.height.round(),
    dw: size.width.round(),
    dh: size.height.round(),
    rotate: value.rotationCorrection,
  );
}

/// 模拟与 media_kit.PlayerStream 接口对齐的流集合
class LunaPlayerStreams implements PlayerStream {
  final StreamController<Duration> positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> durationController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> completedController =
      StreamController<bool>.broadcast();
  final StreamController<String> errorController =
      StreamController<String>.broadcast();
  final StreamController<double> volumeController =
      StreamController<double>.broadcast();
  final StreamController<double> rateController =
      StreamController<double>.broadcast();
  final StreamController<VideoParams> videoParamsController =
      StreamController<VideoParams>.broadcast();
  final StreamController<PlayerLog> logController =
      StreamController<PlayerLog>.broadcast();
  final StreamController<double> pitchController =
      StreamController<double>.broadcast();

  @override
  Stream<Duration> get position => positionController.stream;

  @override
  Stream<Duration> get duration => durationController.stream;

  @override
  Stream<Duration> get buffer => bufferController.stream;

  @override
  Stream<bool> get playing => playingController.stream;

  @override
  Stream<bool> get buffering => bufferingController.stream;

  @override
  Stream<bool> get completed => completedController.stream;

  @override
  Stream<String> get error => errorController.stream;

  @override
  Stream<double> get volume => volumeController.stream;

  @override
  Stream<double> get rate => rateController.stream;

  @override
  Stream<VideoParams> get videoParams => videoParamsController.stream;

  @override
  Stream<PlayerLog> get log => logController.stream;

  @override
  Stream<double> get pitch => pitchController.stream;

  void dispose() {
    positionController.close();
    durationController.close();
    bufferController.close();
    playingController.close();
    bufferingController.close();
    completedController.close();
    errorController.close();
    volumeController.close();
    rateController.close();
    videoParamsController.close();
    logController.close();
    pitchController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      return const Stream<dynamic>.empty();
    }
    return null;
  }
}

class _LunaVideoPlayerController extends VideoPlayerController {
  _LunaVideoPlayerController.file(super.file, {super.videoPlayerOptions})
    : super.file();

  _LunaVideoPlayerController.networkUrl(
    super.uri, {
    super.formatHint,
    super.httpHeaders,
    super.videoPlayerOptions,
  }) : super.networkUrl();

  final _pendingSeeks = <Future<void>>{};
  bool _retiring = false;
  Future<void>? _releaseFuture;

  @override
  Future<void> seekTo(Duration position) async {
    if (_retiring) return;
    final completion = Completer<void>();
    _pendingSeeks.add(completion.future);
    try {
      await super.seekTo(position);
    } finally {
      _pendingSeeks.remove(completion.future);
      completion.complete();
    }
  }

  @override
  Future<void> dispose() {
    _retiring = true;
    return _releaseFuture ??= () async {
      await Future.wait(_pendingSeeks.toList());
      await super.dispose();
    }();
  }
}

/// 采用和 LunaTV-Mobile 完全相同架构的 ExoPlayer (AndroidX Media3) 播放器封装，
/// 同时对上层播控 UI (PlayerControls & TelevisionControls) 暴露完全兼容的 Player 契约。
class LunaExoPlayer implements Player {
  LunaExoPlayer({
    this.initializationTimeout = const Duration(seconds: 30),
    this.engine = PlaybackEngine.automatic,
  }) {
    state = const PlayerState().copyWith(volume: 100.0);
  }

  VideoPlayerController? _controller;
  final Duration initializationTimeout;
  PlaybackEngine engine;
  VoidCallback? _valueListener;
  Timer? _positionPollTimer;
  Timer? _watchdogTimer;
  int _zeroSizeTicks = 0;
  int _bufferingEventsCount = 0;
  Media? _currentMedia;
  bool _playIntent = true;
  PlaybackDecoderMode _decoderMode = PlaybackDecoderMode.hardware;

  PlaybackDecoderMode get decoderMode => _decoderMode;
  bool get isHardwareDecoding => _decoderMode == PlaybackDecoderMode.hardware;
  int get bufferingEventsCount => _bufferingEventsCount;

  void setDecoderMode(PlaybackDecoderMode mode) {
    _decoderMode = mode;
  }

  int _openGeneration = 0;
  int _seekSequence = 0;
  int _pendingSeekSequence = 0;
  Future<void> _seekOperations = Future<void>.value();
  Future<void> _lifecycleQueue = Future<void>.value();
  bool _disposed = false;
  Future<void>? _disposeFuture;
  String? _controllerError;
  Player? _streamPlayer;
  kit.VideoController? _streamVideo;
  final List<StreamSubscription<dynamic>> _streamSubscriptions = [];
  final _compatibilityProbe = HlsCompatibilityProbe();
  bool _compatibilityPlayback = false;

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  @override
  PlayerState state = const PlayerState();

  void prepareForDispose() {
    _disposed = true;
    _compatibilityProbe.cancel();
    _openGeneration++;
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  Future<T> _enqueueLifecycle<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lifecycleQueue = _lifecycleQueue.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _disposeControllerSafely(
    VideoPlayerController? controller, {
    VoidCallback? listener,
  }) async {
    if (controller == null) return;
    if (listener != null) {
      try {
        controller.removeListener(listener);
      } catch (_) {}
    }
    try {
      await controller.setVolume(0);
    } catch (_) {}
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  Future<void> _disposeNativePlayerSafely(Player? native) async {
    if (native == null) return;
    try {
      await native.setVolume(0);
    } catch (_) {}
    try {
      await native.pause();
    } catch (_) {}
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        final platform = native.platform;
        if (platform is NativePlayer) {
          await platform.command(['stop']);
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    try {
      await native.dispose();
    } catch (_) {}
  }

  Future<void> _fallbackToMediaKit({
    required Media media,
    String? key,
    required bool play,
    required int sourceGeneration,
  }) {
    if (_disposed || sourceGeneration != _openGeneration) {
      return Future<void>.value();
    }
    final fallbackGen = ++_openGeneration;
    return _enqueueLifecycle(() async {
      if (_disposed || fallbackGen != _openGeneration) return;
      await _openWithMediaKitLocked(
        media,
        key: key ?? '',
        play: play,
        hwdec: false,
        expectedGen: fallbackGen,
      );
    });
  }

  @override
  final LunaPlayerStreams stream = LunaPlayerStreams();

  @override
  PlatformPlayer? get platform => _streamPlayer?.platform;

  @override
  Future<int> get handle => Future<int>.value(0);

  VideoPlayerController? get controller => _controller;
  bool get streamingDecryption => _streamPlayer != null;
  bool get compatibilityPlayback => _compatibilityPlayback;
  String get mediaUri {
    final playlist = _streamPlayer?.state.playlist.medias;
    if (playlist != null && playlist.isNotEmpty) return playlist.first.uri;
    return _controller?.dataSource ?? '';
  }

  Future<void> waitForVideoFrame() async {
    await _streamVideo?.waitUntilFirstFrameRendered;
  }

  Future<int> audioTrackCount() async {
    final native = _streamPlayer;
    if (native != null) {
      return native.state.tracks.audio
          .where((track) => track.id != 'auto' && track.id != 'no')
          .length;
    }
    return (await _controller?.getAudioTracks())?.length ?? 0;
  }

  Future<void> _openWithMediaKitLocked(
    Media media, {
    String key = '',
    required bool play,
    required bool hwdec,
    required int expectedGen,
  }) async {
    if (key.isNotEmpty && !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(key)) {
      throw const FormatException('视频内容密钥无效');
    }
    await _stopInternal();
    if (_disposed || expectedGen != _openGeneration) return;
    _currentMedia = media;
    _playIntent = play;
    MediaKit.ensureInitialized();
    final generation = expectedGen;
    final volume = state.volume;
    final rate = state.rate;
    final native = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );
    _streamPlayer = native;
    _compatibilityPlayback = key.isEmpty;
    _streamVideo = kit.VideoController(
      native,
      configuration: kit.VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec,
        hwdec: hwdec ? 'auto-safe' : 'no',
      ),
    );
    revision.value++;
    WidgetsBinding.instance.scheduleFrame();
    void mirror<T>(
      Stream<T> input,
      StreamController<T> output, {
      bool repaint = false,
    }) {
      _streamSubscriptions.add(
        input.listen((value) {
          if (_disposed ||
              generation != _openGeneration ||
              !identical(native, _streamPlayer)) {
            return;
          }
          state = native.state;
          _safeAdd(output, value);
          if (repaint) revision.value++;
        }),
      );
    }

    mirror(native.stream.position, stream.positionController);
    mirror(native.stream.duration, stream.durationController);
    mirror(native.stream.buffer, stream.bufferController);
    mirror(native.stream.playing, stream.playingController, repaint: true);
    _streamSubscriptions.add(
      native.stream.buffering.listen((buffering) {
        if (_disposed ||
            generation != _openGeneration ||
            !identical(native, _streamPlayer)) {
          return;
        }
        if (buffering) {
          _bufferingEventsCount++;
          DiaryService.add(
            '[MediaKit] 发生缓冲卡顿等待 (累计卡顿: $_bufferingEventsCount 次)',
          );
        }
        state = native.state;
        _safeAdd(stream.bufferingController, buffering);
        revision.value++;
      }),
    );
    mirror(native.stream.completed, stream.completedController, repaint: true);
    mirror(
      native.stream.videoParams,
      stream.videoParamsController,
      repaint: true,
    );
    mirror(native.stream.error, stream.errorController);
    _streamSubscriptions.add(
      native.stream.log.listen((log) {
        if (_disposed ||
            generation != _openGeneration ||
            !identical(native, _streamPlayer)) {
          return;
        }
        _safeAdd(stream.logController, log);
        final logText = log.text.toLowerCase();
        if (hwdec &&
            (logText.contains('hardware decoding failed') ||
                logText.contains('mediacodec error') ||
                logText.contains('mediacodec failed'))) {
          DiaryService.add('[MediaKit] 捕获硬件解码异常: ${log.text}，自动回退到兼容软解引擎...');
          final startPos = native.state.position;
          final recoveryMedia = Media(
            media.uri,
            httpHeaders: media.httpHeaders,
            start: startPos > Duration.zero ? startPos : null,
            extras: media.extras,
          );
          unawaited(
            _fallbackToMediaKit(
              media: recoveryMedia,
              key: key,
              play: _playIntent,
              sourceGeneration: generation,
            ).catchError((Object e) {
              DiaryService.add('[MediaKit] 软解回退自愈失败: $e');
            }),
          );
        }
        if (PlaybackRecovery.videoOutputFailed(log.text)) {
          _safeAdd(stream.errorController, log.text);
        }
      }),
    );
    mirror(native.stream.volume, stream.volumeController);
    mirror(native.stream.rate, stream.rateController);
    try {
      final backend = native.platform as NativePlayer;
      await backend.setProperty('hwdec', hwdec ? 'auto-safe' : 'no');
      if (key.isNotEmpty) {
        await backend.setProperty('demuxer-lavf-o', 'decryption_key=$key');
      }
      await backend.setProperty('network-timeout', '20');
      if (Platform.isIOS || Platform.isMacOS) {
        await backend.setProperty('audio-channels', 'stereo');
        await backend.setProperty('audio-format', 'float');
        await backend.setProperty('audio-stream-silence', 'yes');
        await backend.setProperty('audio-wait-open', '0.1');
        await backend.setProperty('hwdec', hwdec ? 'videotoolbox' : 'no');
      } else if (Platform.isAndroid) {
        if (hwdec) {
          await backend.setProperty('hwdec', 'mediacodec');
          await backend.setProperty('hwdec-codecs', 'all');
        } else {
          await backend.setProperty('hwdec', 'no');
        }
        await backend.setProperty('framedrop', 'vo');
        await backend.setProperty('video-sync', 'audio');
        await backend.setProperty('vd-lavc-fast', 'yes');
        await backend.setProperty('vd-lavc-threads', '4');
        await backend.setProperty('demuxer-readahead-secs', '20');
        await backend.setProperty('demuxer-max-bytes', '${32 * 1024 * 1024}');
        await backend.setProperty(
          'demuxer-max-back-bytes',
          '${8 * 1024 * 1024}',
        );
        await backend.setProperty('scale', 'bilinear');
        await backend.setProperty('cscale', 'bilinear');
        await backend.setProperty('dscale', 'bilinear');
      }
      await native.setVolume(volume);
      await native.setRate(rate);
      if (_disposed || generation != _openGeneration) {
        if (identical(_streamPlayer, native)) {
          _streamPlayer = null;
          _streamVideo = null;
        }
        for (final subscription in _streamSubscriptions.toList()) {
          await subscription.cancel();
        }
        _streamSubscriptions.clear();
        await _disposeNativePlayerSafely(native);
        return;
      }
      await native.open(media, play: play);
      if (!_disposed && generation == _openGeneration) {
        revision.value++;
        _startMediaKitWatchdog(
          native,
          media,
          key: key,
          hwdec: hwdec,
          generation: generation,
        );
      }
    } catch (_) {
      if (identical(native, _streamPlayer)) {
        await _stopInternal();
      } else {
        await _disposeNativePlayerSafely(native);
      }
      rethrow;
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) {
    if (_disposed || playable is! Media) return Future<void>.value();
    final url = playable.uri;
    if (url.isEmpty) return Future<void>.value();
    _compatibilityProbe.cancel();
    final requestGen = ++_openGeneration;
    return _enqueueLifecycle(
      () => _openLocked(playable, requestGen: requestGen, play: play),
    );
  }

  Future<void> _openLocked(
    Media media, {
    required int requestGen,
    bool play = true,
  }) async {
    if (_disposed || requestGen != _openGeneration) return;
    final url = media.uri;
    _bufferingEventsCount = 0;
    final key = media.extras?['decryptionKey']?.toString() ?? '';
    final hardware = _decoderMode == PlaybackDecoderMode.hardware;
    if (key.isNotEmpty ||
        engine == PlaybackEngine.mpv ||
        (engine == PlaybackEngine.automatic && !hardware)) {
      return _openWithMediaKitLocked(
        media,
        key: key,
        play: play,
        hwdec: hardware,
        expectedGen: requestGen,
      );
    }
    if (_streamPlayer != null) await _stopInternal();
    if (_disposed || requestGen != _openGeneration) return;

    final myGen = requestGen;
    _pendingSeekSequence = 0;
    _seekOperations = Future<void>.value();
    _positionPollTimer?.cancel();
    _watchdogTimer?.cancel();

    final old = _controller;
    _controller = null;
    if (old != null) {
      final listener = _valueListener;
      _valueListener = null;
      revision.value++;
      await _disposeControllerSafely(old, listener: listener);
      if (Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    if (_disposed || myGen != _openGeneration) return;

    state = state.copyWith(completed: false);
    _safeAdd(stream.completedController, false);

    final Map<String, String> headers = <String, String>{};
    try {
      if (media.httpHeaders != null) {
        headers.addAll(Map<String, String>.from(media.httpHeaders!));
      }
    } catch (_) {}

    // 针对防盗链 CDN 注入标准移动端 UA
    if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }

    bool isHls =
        url.toLowerCase().contains('.m3u8') ||
        url.toLowerCase().contains('hls') ||
        (headers['accept']?.contains('mpegurl') ?? false);
    var confirmedMp4 = false;

    final uri = Uri.tryParse(url);
    if (uri == null && !url.startsWith('/')) {
      DiaryService.add('[ExoPlayer] 错误: 无效的播放地址 $url');
      throw Exception('无效的播放地址: $url');
    }

    final isLoopbackStream =
        uri != null &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1') &&
        uri.path.endsWith('.mp4');

    if (isLoopbackStream) {
      confirmedMp4 = true;
      isHls = false;
    } else if (!isHls &&
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 3));
        headers.forEach((k, v) => req.headers.set(k, v));
        req.headers.set('Range', 'bytes=0-512');
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final cType = resp.headers.contentType?.toString().toLowerCase() ?? '';
        final chunks = await resp
            .take(1)
            .timeout(const Duration(seconds: 3))
            .toList();
        final firstChunk = chunks.isNotEmpty
            ? String.fromCharCodes(chunks.first)
            : '';
        confirmedMp4 =
            cType.contains('video/mp4') ||
            firstChunk.length >= 8 && firstChunk.substring(4, 8) == 'ftyp';
        DiaryService.add(
          '[Sniff] 探测结果: status=${resp.statusCode}, contentType=$cType, prefix=${firstChunk.length > 20 ? firstChunk.substring(0, 20) : firstChunk}',
        );
        if (cType.contains('mpegurl') || firstChunk.contains('#EXTM3U')) {
          isHls = true;
          DiaryService.add(
            '[Sniff] 自动识别为 HLS 流，注入 formatHint: VideoFormat.hls',
          );
        }
      } catch (e) {
        DiaryService.add('[Sniff] 探测警告 (非致命): $e');
      } finally {
        client.close(force: true);
      }
    }

    VideoFormat? formatHint = isHls ? VideoFormat.hls : null;

    Media compatibilityMedia() => Media(
      media.uri,
      httpHeaders: headers,
      extras: media.extras,
      start: media.start,
      end: media.end,
    );

    if (engine == PlaybackEngine.automatic &&
        (Platform.isAndroid || Platform.isIOS) &&
        isHls &&
        uri != null &&
        {'http', 'https'}.contains(uri.scheme)) {
      final needsMpv = await _compatibilityProbe.requiresMpv(uri, headers);
      if (_disposed || myGen != _openGeneration) return;
      if (needsMpv) {
        return _openWithMediaKitLocked(
          compatibilityMedia(),
          play: play,
          hwdec: hardware,
          expectedGen: myGen,
        );
      }
    }
    if (_disposed || myGen != _openGeneration) return;

    DiaryService.add(
      '[ExoPlayer] open(gen=$myGen): local=${url.startsWith('/') || uri?.scheme == 'file'}, host=${uri?.host}, isHls=$isHls, formatHint=$formatHint',
    );

    VideoPlayerController c;
    if (url.startsWith('/') || (uri != null && uri.scheme == 'file')) {
      final filePath = uri != null && uri.scheme == 'file'
          ? uri.toFilePath()
          : url;
      DiaryService.add('[ExoPlayer] 本地缓存播放');
      c = _LunaVideoPlayerController.file(
        File(filePath),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
    } else {
      c = _LunaVideoPlayerController.networkUrl(
        uri!,
        formatHint: formatHint,
        httpHeaders: headers,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
    }

    try {
      DiaryService.add(
        '[ExoPlayer] c.initialize() 开始 (formatHint=$formatHint)...',
      );
      await c.initialize().timeout(initializationTimeout);
      DiaryService.add(
        '[ExoPlayer] c.initialize() 成功! duration=${c.value.duration}, size=${c.value.size}, isInitialized=${c.value.isInitialized}',
      );
    } catch (e, stack) {
      DiaryService.add('[ExoPlayer] 首次 initialize 失败: $e');
      if (!confirmedMp4 &&
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        final alternateFormat = formatHint == VideoFormat.hls
            ? null
            : VideoFormat.hls;
        DiaryService.add(
          '[ExoPlayer] 启动自愈重试，切换格式为 formatHint=$alternateFormat...',
        );
        try {
          await c.dispose();
        } catch (_) {}

        final retryHeaders = Map<String, String>.from(headers);
        if (alternateFormat == VideoFormat.hls) {
          retryHeaders['Accept'] =
              'application/vnd.apple.mpegurl,application/x-mpegURL,*/*';
        }
        c = _LunaVideoPlayerController.networkUrl(
          uri,
          formatHint: alternateFormat,
          httpHeaders: retryHeaders,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
        try {
          await c.initialize().timeout(initializationTimeout);
          formatHint = alternateFormat;
          DiaryService.add('[ExoPlayer] 自愈重试成功! duration=${c.value.duration}');
        } catch (retryErr, retryStack) {
          DiaryService.add(
            '[ExoPlayer] 自愈重试依然失败! 异常: $retryErr\n堆栈: $retryStack',
          );
          try {
            await c.dispose();
          } catch (_) {}
          if (_disposed || myGen != _openGeneration) return;
          if (engine == PlaybackEngine.system) rethrow;
          return _openWithMediaKitLocked(
            compatibilityMedia(),
            play: play,
            hwdec: hardware && !Platform.isAndroid,
            expectedGen: myGen,
          );
        }
      } else {
        DiaryService.add('[ExoPlayer] c.initialize() 失败! 异常: $e\n堆栈: $stack');
        try {
          await c.dispose();
        } catch (_) {}
        if (_disposed || myGen != _openGeneration) return;
        if (engine == PlaybackEngine.system) rethrow;
        return _openWithMediaKitLocked(
          compatibilityMedia(),
          play: play,
          hwdec: hardware && !Platform.isAndroid,
          expectedGen: myGen,
        );
      }
    }

    if (_disposed || myGen != _openGeneration) {
      try {
        await c.dispose();
      } catch (_) {}
      return;
    }

    if ((Platform.isAndroid || Platform.isIOS) &&
        (c.value.size.width <= 0 || c.value.size.height <= 0)) {
      await c.dispose();
      if (_disposed || myGen != _openGeneration) return;
      if (engine == PlaybackEngine.system) {
        throw StateError('系统内核未识别视频轨，请切换 MPV 内核后重试');
      }
      DiaryService.add('[MPV] 系统播放器未识别视频轨，切换兼容播放');
      return _openWithMediaKitLocked(
        compatibilityMedia(),
        play: play,
        hwdec: hardware && !Platform.isAndroid,
        expectedGen: myGen,
      );
    }

    _controller = c;
    _currentMedia = compatibilityMedia();
    _playIntent = play;
    _controllerError = null;
    final dur = c.value.duration;
    final videoParams = _systemVideoParameters(c.value);
    final displaySize = videoDisplaySize(videoParams);

    state = state.copyWith(
      duration: dur,
      position: Duration.zero,
      playing: play,
      buffering: c.value.isBuffering,
      width: displaySize?.width.round(),
      height: displaySize?.height.round(),
      videoParams: videoParams,
    );

    _safeAdd(stream.durationController, dur);
    _safeAdd(stream.positionController, Duration.zero);
    _safeAdd(stream.playingController, play);
    _safeAdd(stream.bufferingController, c.value.isBuffering);
    _safeAdd(stream.videoParamsController, videoParams);

    _valueListener = () => _onControllerValue(c);
    c.addListener(_valueListener!);

    // 定时轮询真实播放位置 (与 LunaTV-Mobile 对齐)
    _startPositionPolling();
    _startVideoWatchdog(c, myGen);

    if (media.start != null && media.start! > Duration.zero) {
      try {
        await c.seekTo(media.start!);
        state = state.copyWith(position: media.start!);
        _safeAdd(stream.positionController, media.start!);
      } catch (_) {}
    }

    if (play) {
      try {
        await c.play();
      } catch (_) {}
    }
    revision.value++;
  }

  void _startVideoWatchdog(VideoPlayerController controller, int generation) {
    _watchdogTimer?.cancel();
    _zeroSizeTicks = 0;
    if (!Platform.isAndroid || engine != PlaybackEngine.automatic) return;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed ||
          generation != _openGeneration ||
          _controller != controller) {
        timer.cancel();
        return;
      }
      final value = controller.value;
      if (!value.isInitialized ||
          !value.isPlaying ||
          value.isBuffering ||
          value.position <= const Duration(seconds: 1)) {
        _zeroSizeTicks = 0;
        return;
      }
      if (value.size.width > 0 && value.size.height > 0) {
        _zeroSizeTicks = 0;
        return;
      }
      _zeroSizeTicks++;
      if (_zeroSizeTicks == 2) {
        unawaited(
          controller
              .seekTo(value.position)
              .timeout(const Duration(seconds: 1))
              .catchError((Object _) {}),
        );
      } else if (_zeroSizeTicks >= 3) {
        timer.cancel();
        unawaited(_recoverVideoWithSoftware(controller, generation));
      }
    });
  }

  Future<void> _recoverVideoWithSoftware(
    VideoPlayerController controller,
    int generation,
  ) async {
    final media = _currentMedia;
    if (_disposed ||
        generation != _openGeneration ||
        _controller != controller ||
        engine != PlaybackEngine.automatic ||
        media == null) {
      return;
    }
    final position = controller.value.position;
    final recovery = Media(
      media.uri,
      httpHeaders: media.httpHeaders,
      extras: media.extras,
      start: position > Duration.zero ? position : media.start,
      end: media.end,
    );
    DiaryService.add('[MPV] Android 系统解码失败或无画面，保留进度切换软解');
    try {
      await _fallbackToMediaKit(
        media: recovery,
        play: _playIntent,
        sourceGeneration: generation,
      );
    } catch (error) {
      if (!_disposed && generation + 1 == _openGeneration) {
        _safeAdd(stream.errorController, error.toString());
      }
    }
  }

  void _startPositionPolling() {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final pos = c.value.position;
      if (_pendingSeekSequence == 0 && pos != state.position) {
        state = state.copyWith(position: pos);
        _safeAdd(stream.positionController, pos);
      }
    });
  }

  void _startMediaKitWatchdog(
    Player native,
    Media media, {
    String? key,
    bool hwdec = false,
    required int generation,
  }) {
    _watchdogTimer?.cancel();
    _zeroSizeTicks = 0;
    if (!hwdec) return;

    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 1000), (
      timer,
    ) async {
      if (_disposed ||
          generation != _openGeneration ||
          !identical(native, _streamPlayer)) {
        timer.cancel();
        return;
      }
      if (native.state.playing &&
          native.state.position > const Duration(seconds: 1)) {
        final w = native.state.videoParams.w ?? 0;
        final h = native.state.videoParams.h ?? 0;
        if (w == 0 || h == 0) {
          _zeroSizeTicks++;
          DiaryService.add(
            '[MediaKit Watchdog] 警告: 播放中画面尺寸为 0x0 (tick=$_zeroSizeTicks)',
          );
          if (_zeroSizeTicks >= 3) {
            timer.cancel();
            DiaryService.add(
              '[MediaKit Watchdog] 判定电视硬解黑屏/无画面：立即激活 MediaKit 软解兼容模式自愈恢复画面！',
            );
            if (!_disposed && generation == _openGeneration) {
              final startPos = native.state.position;
              final recoveryMedia = Media(
                media.uri,
                httpHeaders: media.httpHeaders,
                start: startPos > Duration.zero ? startPos : null,
                extras: media.extras,
              );
              try {
                await _fallbackToMediaKit(
                  media: recoveryMedia,
                  key: key,
                  play: _playIntent,
                  sourceGeneration: generation,
                );
              } catch (e) {
                DiaryService.add('[MediaKit Watchdog] 软解自愈失败: $e');
              }
            }
          }
        } else {
          _zeroSizeTicks = 0;
          timer.cancel();
        }
      }
    });
  }

  String? _readMpvString(NativePlayer player, String property) {
    if (player.disposed || player.ctx == nullptr) return null;
    final name = property.toNativeUtf8();
    try {
      final value = player.mpv.mpv_get_property_string(player.ctx, name.cast());
      if (value == nullptr) return null;
      try {
        return value.cast<Utf8>().toDartString();
      } finally {
        player.mpv.mpv_free(value.cast());
      }
    } catch (_) {
      return null;
    } finally {
      calloc.free(name);
    }
  }

  Future<PlaybackTechnicalDiagnostics> getDiagnostics({
    int requestedQuality = 0,
    int actualQuality = 0,
    List<int> availableQualities = const [],
    String? mediaHost,
  }) async {
    final native = _streamPlayer;
    final c = _controller;
    final isStream = native != null;
    final engine = isStream
        ? 'MediaKit (libmpv)'
        : 'ExoPlayer (AndroidX Media3)';

    String decoder = '未知';
    bool hwActive = false;
    int? w;
    int? h;
    double? fps;
    int dropped = 0;
    Duration buf = Duration.zero;

    if (isStream) {
      final params = native.state.videoParams;
      w = params.w;
      h = params.h;
      decoder = 'hevc';
      buf = native.state.buffer;

      if (native.platform is NativePlayer) {
        final backend = native.platform as NativePlayer;
        final mpvCodec =
            _readMpvString(backend, 'video-codec') ??
            _readMpvString(backend, 'video-format');
        if (mpvCodec != null && mpvCodec.isNotEmpty) {
          decoder = mpvCodec;
        }
        final hwdecCurrent = _readMpvString(backend, 'hwdec-current');
        if (hwdecCurrent != null &&
            hwdecCurrent != 'no' &&
            hwdecCurrent.isNotEmpty) {
          hwActive = true;
          decoder = '$decoder ($hwdecCurrent)';
        } else {
          hwActive = false;
          decoder = '$decoder (software)';
        }
        final dropStr =
            _readMpvString(backend, 'decoder-frame-drop-count') ??
            _readMpvString(backend, 'frame-drop-count');
        if (dropStr != null) {
          dropped = int.tryParse(dropStr) ?? 0;
        }
        final fpsStr =
            _readMpvString(backend, 'container-fps') ??
            _readMpvString(backend, 'estimated-vf-fps');
        if (fpsStr != null) {
          fps = double.tryParse(fpsStr);
        }
      }
    } else if (c != null && c.value.isInitialized) {
      w = c.value.size.width.toInt();
      h = c.value.size.height.toInt();
      final resolved = resolveAndroidExoCodecDiagnostics(
        await _queryAndroidMediaCodecDiagnostics(),
        _decoderMode,
      );
      decoder = resolved.decoder;
      hwActive = resolved.hwActive;
      if (c.value.buffered.isNotEmpty) {
        final last = c.value.buffered.last.end;
        final pos = c.value.position;
        if (last > pos) buf = last - pos;
      }
    }

    return PlaybackTechnicalDiagnostics(
      playerEngine: engine,
      decoderName: decoder,
      isHardwareAccelerated: hwActive,
      videoWidth: w,
      videoHeight: h,
      fps: fps,
      droppedFrames: dropped,
      bufferDuration: buf,
      bufferingEventsCount: _bufferingEventsCount,
      requestedQuality: requestedQuality,
      actualQuality: actualQuality,
      availableQualities: availableQualities,
      isEncrypted:
          streamingDecryption ||
          (mediaUri.contains('crypto') ||
              (c == null &&
                  _currentMedia?.extras?['decryptionKey']
                          ?.toString()
                          .isNotEmpty ==
                      true)),
      mediaHost: mediaHost ?? (Uri.tryParse(mediaUri)?.host),
      timestamp: DateTime.now(),
    );
  }

  void _onControllerValue(VideoPlayerController c) {
    if (_disposed || _controller != c) return;
    final v = c.value;

    bool stateChanged = false;
    final parameters = _systemVideoParameters(v);
    final displaySize = videoDisplaySize(parameters);
    if (displaySize != null && parameters != state.videoParams) {
      state = state.copyWith(
        width: displaySize.width.round(),
        height: displaySize.height.round(),
        videoParams: parameters,
      );
      _safeAdd(stream.videoParamsController, parameters);
      stateChanged = true;
    }
    if (v.isPlaying != state.playing) {
      DiaryService.add('[ExoPlayer] isPlaying 变为: ${v.isPlaying}');
      state = state.copyWith(playing: v.isPlaying);
      _safeAdd(stream.playingController, v.isPlaying);
      stateChanged = true;
    }
    if (v.isBuffering != state.buffering) {
      if (v.isBuffering) {
        _bufferingEventsCount++;
        DiaryService.add(
          '[ExoPlayer] 发生缓冲卡顿等待 (累计卡顿: $_bufferingEventsCount 次)',
        );
      }
      DiaryService.add('[ExoPlayer] isBuffering 变为: ${v.isBuffering}');
      state = state.copyWith(buffering: v.isBuffering);
      _safeAdd(stream.bufferingController, v.isBuffering);
      stateChanged = true;
    }
    if (v.hasError) {
      final error = v.errorDescription ?? '视频读取失败';
      if (_controllerError != error) {
        _controllerError = error;
        DiaryService.add('[ExoPlayer] controller error: $error');
        if (Platform.isAndroid && engine == PlaybackEngine.automatic) {
          unawaited(_recoverVideoWithSoftware(c, _openGeneration));
          return;
        }
        _safeAdd(stream.errorController, error);
      }
    }
    final dur = v.duration;
    if (dur > Duration.zero && dur != state.duration) {
      state = state.copyWith(duration: dur);
      _safeAdd(stream.durationController, dur);
      stateChanged = true;
    }
    final pos = v.position;
    if (_pendingSeekSequence == 0 && pos != state.position) {
      state = state.copyWith(position: pos);
      _safeAdd(stream.positionController, pos);
    }
    if (v.buffered.isNotEmpty) {
      final lastRange = v.buffered.last;
      if (lastRange.end != state.buffer) {
        state = state.copyWith(buffer: lastRange.end);
        _safeAdd(stream.bufferController, state.buffer);
      }
    }
    if (v.isCompleted != state.completed) {
      state = state.copyWith(completed: v.isCompleted);
      _safeAdd(stream.completedController, v.isCompleted);
      stateChanged = true;
    }

    if (stateChanged) {
      revision.value++;
    }
  }

  @override
  Future<void> play() async {
    _playIntent = true;
    if (_streamPlayer != null) return _streamPlayer!.play();
    final c = _controller;
    if (c == null) return;
    try {
      await c.play();
    } catch (_) {}
  }

  @override
  Future<void> pause() async {
    _playIntent = false;
    if (_streamPlayer != null) return _streamPlayer!.pause();
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
    } catch (_) {}
  }

  @override
  Future<void> playOrPause() async {
    if (_streamPlayer != null) return _streamPlayer!.playOrPause();
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration target) async {
    if (_streamPlayer != null) return _streamPlayer!.seek(target);
    final c = _controller;
    if (c == null) return;
    final generation = _openGeneration;
    final sequence = ++_seekSequence;
    final bounded = target < Duration.zero
        ? Duration.zero
        : c.value.duration > Duration.zero && target > c.value.duration
        ? c.value.duration
        : target;
    _pendingSeekSequence = sequence;
    final operation = _seekOperations.catchError((Object _) {}).then((_) async {
      bool current() =>
          !_disposed &&
          _controller == c &&
          generation == _openGeneration &&
          sequence == _seekSequence;
      if (!current()) return;
      try {
        await c.seekTo(bounded);
        if (!current()) return;
        state = state.copyWith(position: bounded);
        _safeAdd(stream.positionController, bounded);
        if (state.completed) {
          state = state.copyWith(completed: false);
          _safeAdd(stream.completedController, false);
        }
      } finally {
        if (current()) _pendingSeekSequence = 0;
      }
    });
    _seekOperations = operation;
    await operation;
  }

  @override
  Future<void> setRate(double rate) async {
    if (_streamPlayer != null) return _streamPlayer!.setRate(rate);
    final r = rate.clamp(0.25, 4.0);
    state = state.copyWith(rate: r);
    _safeAdd(stream.rateController, r);
    final c = _controller;
    if (c == null) return;
    try {
      await c.setPlaybackSpeed(r);
    } catch (_) {}
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_streamPlayer != null) return _streamPlayer!.setVolume(volume);
    final v = volume.clamp(0.0, 100.0);
    state = state.copyWith(volume: v);
    _safeAdd(stream.volumeController, v);
    final c = _controller;
    if (c == null) return;
    try {
      await c.setVolume(v / 100.0);
    } catch (_) {}
  }

  @override
  Future<void> stop() {
    _openGeneration++;
    _compatibilityProbe.cancel();
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    return _enqueueLifecycle(_stopInternal);
  }

  Future<void> _stopInternal() async {
    _pendingSeekSequence = 0;
    _seekOperations = Future<void>.value();
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _currentMedia = null;
    _playIntent = false;
    final c = _controller;
    _controller = null;
    _controllerError = null;
    final native = _streamPlayer;
    _streamPlayer = null;
    _streamVideo = null;
    _compatibilityPlayback = false;
    for (final subscription in _streamSubscriptions.toList()) {
      await subscription.cancel();
    }
    _streamSubscriptions.clear();
    final listener = _valueListener;
    _valueListener = null;
    state = state.copyWith(
      playlist: const Playlist([]),
      playing: false,
      buffering: false,
      completed: false,
      position: Duration.zero,
      duration: Duration.zero,
      buffer: Duration.zero,
      width: 0,
      height: 0,
      videoParams: const VideoParams(),
    );
    _safeAdd(stream.playingController, false);
    _safeAdd(stream.bufferingController, false);
    _safeAdd(stream.positionController, Duration.zero);
    _safeAdd(stream.videoParamsController, const VideoParams());
    if (!_disposed) revision.value++;
    await _disposeControllerSafely(c, listener: listener);
    await _disposeNativePlayerSafely(native);
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _disposePlayer();

  Future<void> _disposePlayer() async {
    prepareForDispose();
    await _enqueueLifecycle(_stopInternal);
    stream.dispose();
  }

  Future<Map<String, dynamic>?> _queryAndroidMediaCodecDiagnostics() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    final cached = _androidCodecDiagCache[this];
    if (cached != null) return cached;
    try {
      final raw = await AppDevice.channel
          .invokeMapMethod<String, dynamic>('mediaCodecDiagnostics')
          .timeout(const Duration(milliseconds: 500));
      if (raw != null && raw.isNotEmpty) {
        final normalized = Map<String, dynamic>.from(raw);
        _androidCodecDiagCache[this] = normalized;
        return normalized;
      }
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
    return null;
  }

  void _safeAdd<T>(StreamController<T> ctl, T value) {
    if (!ctl.isClosed) ctl.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) return null;
    if (invocation.isMethod) return Future<void>.value();
    return null;
  }
}

/// 采用和 LunaTV-Mobile 完全相同架构的 ExoPlayer 视图组件
class LunaExoVideoView extends StatelessWidget {
  const LunaExoVideoView({
    super.key,
    required this.player,
    this.fit = BoxFit.contain,
    this.controls,
  });

  final LunaExoPlayer player;
  final BoxFit fit;
  final Widget Function(BuildContext)? controls;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player.revision,
      builder: (context, _) {
        final nativeVideo = player._streamVideo;
        final c = player.controller;
        final hasVideo = c != null && c.value.isInitialized;
        final size = hasVideo
            ? videoDisplaySize(_systemVideoParameters(c.value))
            : videoDisplaySize(player.state.videoParams);
        final ratio = size?.aspectRatio;

        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppColors.black),
            if (nativeVideo != null)
              kit.Video(
                key: ObjectKey(nativeVideo),
                controller: nativeVideo,
                fit: fit,
                aspectRatio: ratio,
                controls: kit.NoVideoControls,
              )
            else if (hasVideo && ratio != null)
              Center(
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: VideoPlayer(key: ObjectKey(c), c),
                ),
              ),
            if (controls != null) controls!(context),
          ],
        );
      },
    );
  }
}

final Expando<Map<String, dynamic>> _androidCodecDiagCache =
    Expando<Map<String, dynamic>>('_androidCodecDiagCache');

@visibleForTesting
({String decoder, bool hwActive}) resolveAndroidExoCodecDiagnostics(
  Map<String, dynamic>? diag,
  PlaybackDecoderMode mode,
) {
  final hwFallback = mode == PlaybackDecoderMode.hardware;
  if (diag == null || diag.isEmpty) {
    return (decoder: 'MediaCodec', hwActive: hwFallback);
  }
  String? trimOrNull(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  final hevcHw = trimOrNull(diag['hevcHardware']);
  final avcHw = trimOrNull(diag['avcHardware']);
  final hevcSw = trimOrNull(diag['hevcSoftware']);
  final avcSw = trimOrNull(diag['avcSoftware']);
  final hw = trimOrNull(diag['hardware']);
  final refreshRate = diag['refreshRate'] is num
      ? (diag['refreshRate'] as num).toDouble()
      : null;

  final hasHw = hevcHw != null || avcHw != null;
  final hwActive = hwFallback && hasHw;

  final codecParts = <String>[];
  if (hevcHw != null) {
    codecParts.add('HEVC:$hevcHw');
  } else if (hevcSw != null) {
    codecParts.add('HEVC:$hevcSw(仅软解)');
  }
  if (avcHw != null) {
    codecParts.add('AVC:$avcHw');
  } else if (avcSw != null) {
    codecParts.add('AVC:$avcSw(仅软解)');
  }

  final envParts = <String>[
    ?hw,
    if (refreshRate != null && refreshRate.isFinite && refreshRate > 0)
      '${refreshRate.toStringAsFixed(0)}Hz',
  ];
  final envLabel = envParts.isEmpty ? '' : ' [${envParts.join(' · ')}]';
  final codecLabel = codecParts.isEmpty ? '' : ' (${codecParts.join(' / ')})';
  return (decoder: 'MediaCodec$envLabel$codecLabel', hwActive: hwActive);
}
