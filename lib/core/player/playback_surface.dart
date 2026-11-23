import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:THLRedLook/core/player/luna_exo_player.dart';
import 'package:THLRedLook/core/player/playback_engine.dart';
import 'package:THLRedLook/core/player/playback_preferences.dart';

class PlaybackSurface {
  Player? _player;
  VideoController? _video;
  Future<void>? _closing;
  PlaybackDecoderMode _decoderMode = PlaybackDecoderMode.hardware;

  Player acquire({
    required PlaybackEngine engine,
    required PlaybackDecoderMode decoderMode,
    Player Function()? factory,
  }) {
    if (_closing != null) throw StateError('播放器已关闭');
    _decoderMode = decoderMode;
    final player = _player ??=
        factory?.call() ??
        ((Platform.isAndroid || Platform.isIOS)
            ? LunaExoPlayer(engine: engine)
            : Player(
                configuration: const PlayerConfiguration(
                  bufferSize: 32 * 1024 * 1024,
                  logLevel: MPVLogLevel.error,
                ),
              ));
    if (player is LunaExoPlayer) {
      player.engine = engine;
      player.setDecoderMode(decoderMode);
    }
    return player;
  }

  VideoController? get video {
    final player = _player;
    if (player == null || player is LunaExoPlayer) return null;
    final hardware = _decoderMode == PlaybackDecoderMode.hardware;
    return _video ??= VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: !Platform.isIOS && hardware,
        hwdec: !hardware
            ? 'no'
            : (Platform.isWindows ? 'auto-copy-safe' : 'auto-safe'),
      ),
    );
  }

  Future<void> close() => _closing ??= _dispose();

  Future<void> _dispose() async {
    await _player?.dispose();
    _video = null;
    _player = null;
  }
}
