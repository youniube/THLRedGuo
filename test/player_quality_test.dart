import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/player/luna_exo_player.dart';
import 'package:THLRedLook/core/player/playback_preferences.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/pages/player/player_page.dart';
import 'package:THLRedLook/views/player/player_controls_view.dart';
import 'package:THLRedLook/views/player/player_menu.dart';
import 'package:THLRedLook/views/player/player_quality_sheet_view.dart';

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

  void emitSize(int width, int height) {
    final parameters = VideoParams(w: width, h: height, dw: width, dh: height);
    state = state.copyWith(
      width: width,
      height: height,
      videoParams: parameters,
    );
    stream.videoParamsController.add(parameters);
  }
}

Future<_QualityPlayer> _openPlayer(
  WidgetTester tester, {
  PlaybackPlan plan = const PlaybackPlan(
    url: 'https://synthetic.invalid/video.mp4',
  ),
  int requestedQuality = 0,
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
  final player = _QualityPlayer();
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerScreen(
        detail: DramaDetail(_drama, [
          Episode({'id': 'episode-1'}, 1),
        ]),
        initialIndex: 0,
        repository: _QualityRepository(plan),
        store: store,
        playerFactory: () => player,
        videoBuilder: (controls) => controls,
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return player;
}

String _qualityLabel(WidgetTester tester) =>
    tester.widget<PlayerControls>(find.byType(PlayerControls)).qualityLabel;

void main() {
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
