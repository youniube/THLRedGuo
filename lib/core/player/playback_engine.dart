import 'package:flutter/foundation.dart';

enum PlaybackEngine {
  automatic,
  system,
  mpv;

  String get label => switch (this) {
    automatic => '自动',
    system => systemPlaybackEngineLabel,
    mpv => 'MPV',
  };

  String get description => switch (this) {
    automatic => '优先使用系统内核，格式不兼容或加载失败时自动尝试 MPV。',
    system => '使用系统内核播放；部分加密视频仍需 MPV 解密。',
    mpv =>
      defaultTargetPlatform == TargetPlatform.iOS
          ? '始终使用 MPV 播放，暂不支持 iOS 系统画中画。'
          : '始终使用 MPV 播放，支持更多视频格式。',
  };
}

bool get supportsSystemPlaybackEngine =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

String get systemPlaybackEngineLabel => switch (defaultTargetPlatform) {
  TargetPlatform.android => '系统内核（ExoPlayer）',
  TargetPlatform.iOS => '系统内核（AVPlayer）',
  _ => '系统内核',
};

List<PlaybackEngine> get availablePlaybackEngines =>
    supportsSystemPlaybackEngine
    ? PlaybackEngine.values
    : const [PlaybackEngine.mpv];
