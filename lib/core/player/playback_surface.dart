import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:THLRedLook/core/player/luna_exo_player.dart';
import 'package:THLRedLook/core/player/playback_engine.dart';

class PlaybackSurface {
  Player? _player;
  VideoController? _video;
  Future<void>? _closing;

  Player acquire({required PlaybackEngine engine, Player Function()? factory}) {
    if (_closing != null) throw StateError('播放器已关闭');
    return _player ??=
        factory?.call() ??
        ((Platform.isAndroid || Platform.isIOS)
            ? LunaExoPlayer(engine: engine)
            : Player(
                configuration: const PlayerConfiguration(
                  bufferSize: 32 * 1024 * 1024,
                  logLevel: MPVLogLevel.error,
                ),
              ));
  }

  VideoController? get video {
    final player = _player;
    if (player == null || player is LunaExoPlayer) return null;
    return _video ??= VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: !Platform.isIOS,
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
