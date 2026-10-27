import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/player/luna_exo_player.dart';
import 'package:THLRedLook/core/player/playback_preferences.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/pages/player/player_page.dart';
import 'package:THLRedLook/views/player/player_controls_view.dart';
import 'package:THLRedLook/views/player/player_menu.dart';
import 'package:THLRedLook/views/player/player_quality_sheet_view.dart';
import 'package:THLRedLook/views/player/player_viewport_view.dart';
import 'package:THLRedLook/utils/media/video_output_size.dart';

const _drama = Drama(
  id: 'synthetic:quality',
  source: 'synthetic',
  title: '合成画质测试',
  episodes: 1,
);

class _QualityRepository extends AppRepository {
  _QualityRepository(this.plan);

  final PlaybackPlan plan;

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => plan;

  @override
  Future<void> release(String session) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _QualityPlayer extends LunaExoPlayer {
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(playing: play, duration: const Duration(minutes: 2));
    stream.durationController.add(state.duration);
  }

  void emitSize(int width, int height, {int rotation = 0}) {
    final parameters = VideoParams(
      w: width,
      h: height,
      dw: width,
      dh: height,
      rotate: rotation,
    );
    state = state.copyWith(
      width: width,
      height: height,
      videoParams: parameters,
    );
    stream.videoParamsController.add(parameters);
  }
}

class _SizedVideoPlayer extends LunaExoPlayer {
  _SizedVideoPlayer(Size size, int rotation)
    : surfaceController = VideoPlayerController.networkUrl(
        Uri.parse('https://synthetic.invalid/frame.mp4'),
      ) {
    surfaceController.value = VideoPlayerValue(
      duration: const Duration(minutes: 1),
      isInitialized: true,
      size: size,
      rotationCorrection: rotation,
    );
  }

  final VideoPlayerController surfaceController;

  @override
  VideoPlayerController get controller => surfaceController;
}

class _FallbackRepository extends _QualityRepository {
  _FallbackRepository(this.exhausted)
    : super(
        const PlaybackPlan(
          url: 'https://synthetic.invalid/first.mp4',
          session: 'original',
          quality: 1080,
          routeCount: 2,
        ),
      );

  final bool exhausted;
  final released = <String>[];
  int fallbacks = 0;
  int refreshes = 0;

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async {
    fallbacks++;
    expect(released, isNot(contains(current.session)));
    if (exhausted) throw AppFailure('无备用播放流', code: 'NO_ALTERNATIVE');
    return const PlaybackPlan(
      url: 'https://synthetic.invalid/backup.mp4',
      session: 'original',
      quality: 720,
      routeIndex: 1,
      routeCount: 2,
    );
  }

  @override
  Future<PlaybackPlan> refreshPlayback(
    Drama drama,
    Episode episode,
    PlaybackPlan current, {
    int quality = 0,
  }) async {
    refreshes++;
    return const PlaybackPlan(
      url: 'https://synthetic.invalid/fresh.mp4',
      session: 'fresh',
      quality: 720,
    );
  }

  @override
  Future<void> release(String session) async => released.add(session);
}

class _FailingQualityPlayer extends _QualityPlayer {
  int opens = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (opens++ == 0) throw StateError('合成原生播放失败');
    await super.open(playable, play: play);
  }
}

Future<_QualityPlayer> _openPlayer(
  WidgetTester tester, {
  PlaybackPlan plan = const PlaybackPlan(
    url: 'https://synthetic.invalid/video.mp4',
  ),
  int requestedQuality = 0,
  _QualityRepository? repository,
  _QualityPlayer? player,
}) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  await store.setPlaybackPreferences(
    PlaybackPreferences(
      quality: requestedQuality,
      danmaku: false,
      preload: false,
    ),
  );
  final activePlayer = player ?? _QualityPlayer();
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerScreen(
        detail: DramaDetail(_drama, [
          Episode({'id': 'episode-1'}, 1),
        ]),
        initialIndex: 0,
        repository: repository ?? _QualityRepository(plan),
        store: store,
        playerFactory: () => activePlayer,
        videoBuilder: (controls) => controls,
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return activePlayer;
}

String _qualityLabel(WidgetTester tester) =>
    tester.widget<PlayerControls>(find.byType(PlayerControls)).qualityLabel;

void main() {
  test('显示尺寸使用完整的显示宽高、旋转及像素比例，缺失时不混用尺寸', () {
    expect(
      videoDisplaySize(const VideoParams(w: 1920, h: 1080, rotate: 90)),
      const Size(1080, 1920),
    );
    expect(
      videoDisplaySize(const VideoParams(w: 1920, h: 1080, rotate: -90)),
      const Size(1080, 1920),
    );
    expect(
      videoDisplaySize(const VideoParams(w: 720, h: 576, dw: 1024, dh: 576)),
      const Size(1024, 576),
    );
    expect(
      videoDisplaySize(const VideoParams(w: 720, h: 576, dw: 1024)),
      const Size(720, 576),
    );
    expect(
      videoDisplaySize(const VideoParams(w: 720, h: 576, aspect: 16 / 9)),
      const Size(1024, 576),
    );
    expect(
      videoDisplaySize(const VideoParams(w: 720, h: 576, par: 64 / 45)),
      const Size(1024, 576),
    );
    expect(videoDisplaySize(const VideoParams()), isNull);
    expect(videoDisplaySize(const VideoParams(w: 1920, h: 0)), isNull);
  });

  for (final viewport in [const Size(390, 800), const Size(800, 390)]) {
    for (final (width, height, rotation, expected) in [
      (1080.0, 1920.0, 0, 9 / 16),
      (1920.0, 1080.0, 0, 16 / 9),
      (1920.0, 1080.0, 90, 9 / 16),
      (1080.0, 1920.0, 270, 16 / 9),
      (1000.0, 1000.0, 0, 1.0),
      (2520.0, 1080.0, 0, 21 / 9),
    ]) {
      testWidgets('$width×$height 旋转 $rotation 在 $viewport 中完整等比居中', (
        tester,
      ) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final player = _SizedVideoPlayer(Size(width, height), rotation);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: LunaExoVideoView(player: player)),
          ),
        );
        final frame = tester.getRect(find.byType(AspectRatio));
        expect(frame.width / frame.height, closeTo(expected, 0.000001));
        expect(frame.left, greaterThanOrEqualTo(-0.000001));
        expect(frame.top, greaterThanOrEqualTo(-0.000001));
        expect(frame.right, lessThanOrEqualTo(viewport.width + 0.000001));
        expect(frame.bottom, lessThanOrEqualTo(viewport.height + 0.000001));
        expect(frame.center.dx, closeTo(viewport.width / 2, 0.000001));
        expect(frame.center.dy, closeTo(viewport.height / 2, 0.000001));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await player.surfaceController.dispose();
        await player.dispose();
      });
    }
  }

  testWidgets('实际尺寸未识别和切换视频时清除旧比例，横竖画幅按解码尺寸更新', (tester) async {
    final player = await _openPlayer(tester);
    double? ratio() => tester
        .widget<PlayerViewportView>(find.byType(PlayerViewportView))
        .aspectRatio;
    expect(ratio(), isNull);
    player.emitSize(1080, 1920);
    await tester.pumpAndSettle();
    expect(ratio(), 9 / 16);
    player.emitSize(0, 0);
    await tester.pumpAndSettle();
    expect(ratio(), isNull);
    player.emitSize(1920, 1080);
    await tester.pumpAndSettle();
    expect(ratio(), 16 / 9);
    player.emitSize(1920, 1080, rotation: 90);
    await tester.pumpAndSettle();
    expect(ratio(), 9 / 16);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final exhausted in [false, true]) {
    testWidgets(exhausted ? '备用流耗尽时刷新地址，不重复尝试失效会话' : '原生播放失败自动切备用流，并保留当前会话', (
      tester,
    ) async {
      final repository = _FallbackRepository(exhausted);
      await _openPlayer(
        tester,
        repository: repository,
        player: _FailingQualityPlayer(),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(repository.fallbacks, 1);
      expect(repository.refreshes, exhausted ? 1 : 0);
      expect(_qualityLabel(tester), '720P');
      if (!exhausted) expect(repository.released, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('JS 源未提供画质时显示自动，不把已保存的偏好当作实际画质', (tester) async {
    await _openPlayer(tester, requestedQuality: 1080);

    expect(_qualityLabel(tester), '自动');
    expect(find.text('0P'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('未读取视频尺寸时显示源返回的画质', (tester) async {
    await _openPlayer(
      tester,
      plan: const PlaybackPlan(
        url: 'https://synthetic.invalid/video.mp4',
        quality: 720,
        qualities: [720],
      ),
      requestedQuality: 1080,
    );

    expect(_qualityLabel(tester), '720P');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('实际视频尺寸更新画质，横竖屏都按短边计算并保留 4K 分辨率', (tester) async {
    final player = await _openPlayer(tester);
    expect(_qualityLabel(tester), '自动');

    for (final (width, height, expected) in [
      (720, 1280, '720P'),
      (1920, 1080, '1080P'),
      (1080, 1920, '1080P'),
      (3840, 2160, '2160P'),
    ]) {
      player.emitSize(width, height);
      await tester.pumpAndSettle();
      expect(_qualityLabel(tester), expected);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('本地文件继续显示本地原画', (tester) async {
    final player = await _openPlayer(
      tester,
      plan: const PlaybackPlan(url: 'synthetic.mp4', local: true),
    );
    player.emitSize(720, 1280);
    await tester.pump();

    expect(_qualityLabel(tester), '本地原画');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('移动端不会把检测到的尺寸当作源提供的可切换档位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerQualitySheetView(
            qualities: const [],
            selectedQuality: 0,
            actualQuality: 720,
            isLocal: false,
            onQualitySelected: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('当前正在播放 720P 高清'), findsOneWidget);
    expect(find.byKey(const ValueKey('quality-option-0')), findsOneWidget);
    for (final quality in [1080, 720, 360]) {
      expect(find.byKey(ValueKey('quality-option-$quality')), findsNothing);
    }
  });

  testWidgets('移动端仅列出源声明的有效档位并正确回传选择', (tester) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerQualitySheetView(
            qualities: const [720, 2160, 720, 0, -1],
            selectedQuality: 0,
            actualQuality: 0,
            isLocal: false,
            onQualitySelected: (quality) => selected = quality,
          ),
        ),
      ),
    );

    expect(find.text('按源站默认画质播放'), findsOneWidget);
    for (final quality in [0, 2160, 720]) {
      expect(find.byKey(ValueKey('quality-option-$quality')), findsOneWidget);
    }
    for (final quality in [1080, 360, -1]) {
      expect(find.byKey(ValueKey('quality-option-$quality')), findsNothing);
    }
    await tester.tap(find.byKey(const ValueKey('quality-option-720')));
    expect(selected, 720);
  });

  testWidgets('通用清晰度菜单仅使用源声明的档位并显示实际分辨率', (tester) async {
    for (final available in <List<int>>[
      [],
      [720, 2160, 720, -1],
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerMenu(
              key: ValueKey(available),
              section: PlayerMenuSection.quality,
              episodes: const [],
              currentIndex: 0,
              preferences: const PlaybackPreferences(),
              qualities: available,
              actualQuality: 480,
              local: false,
              favorite: false,
              mobile: false,
              onEpisode: (_) {},
              onFavorite: () async {},
              onPreferences: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('当前播放 480P'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(available.isEmpty ? 1 : 3));
      expect(find.byKey(const ValueKey('menu-quality-0')), findsOneWidget);
      for (final quality in [1080, 360, -1]) {
        expect(find.byKey(ValueKey('menu-quality-$quality')), findsNothing);
      }
    }
  });
}
