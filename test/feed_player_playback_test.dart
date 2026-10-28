import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/feed/feed_playback_policy.dart';
import 'package:THLRedLook/core/player/luna_exo_player.dart';
import 'package:THLRedLook/core/player/playback_lease.dart';
import 'package:THLRedLook/core/player/playback_preferences.dart';
import 'package:THLRedLook/core/player/playback_surface.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/pages/player/player_page.dart';
import 'package:THLRedLook/views/feed/feed_player_overlay.dart';
import 'package:THLRedLook/views/player/player_viewport_view.dart';

const _movie = Drama(
  id: 'hongguo:synthetic-movie',
  source: 'hongguo',
  title: '合成电影',
  category: '电影',
);
const _short = Drama(
  id: 'hongguo:synthetic-short',
  source: 'hongguo',
  title: '合成短剧',
  category: '短剧',
);

DramaDetail _detail(Drama drama) => DramaDetail(drama, [
  for (var index = 1; index <= 3; index++)
    Episode({'id': '${drama.id}:$index'}, index),
]);

class _Repository extends AppRepository {
  final resolved = <int>[];

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolved.add(episode.number);
    return PlaybackPlan(
      url: 'https://synthetic.invalid/${episode.number}.mp4',
      session: '${drama.id}:${episode.number}',
    );
  }

  @override
  Future<void> release(String session) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Player extends LunaExoPlayer {
  Duration mediaDuration = const Duration(minutes: 45);
  bool seekFails = false;
  bool portrait = false;
  int closes = 0;
  int stops = 0;
  Timer? _clock;
  final opens = <bool>[];
  final seeks = <Duration>[];
  final audibleStarts = <Duration>[];

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens.add(play);
    final media = playable as Media;
    final parameters = VideoParams(
      w: portrait ? 720 : 1280,
      h: portrait ? 1280 : 720,
    );
    state = state.copyWith(
      duration: mediaDuration,
      position: media.start ?? Duration.zero,
      videoParams: parameters,
      playing: false,
      buffering: false,
      completed: false,
      buffer: mediaDuration,
    );
    stream.durationController.add(mediaDuration);
    stream.videoParamsController.add(parameters);
    if (play) await this.play();
  }

  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
    if (seekFails) throw StateError('合成不可定位媒体');
    emit(target);
  }

  void emit(Duration position) {
    state = state.copyWith(position: position);
    stream.positionController.add(position);
  }

  @override
  Future<void> play() async {
    if (state.volume > 0) audibleStarts.add(state.position);
    state = state.copyWith(playing: true);
    stream.playingController.add(true);
    _clock ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (state.playing && !state.buffering) {
        emit(state.position + const Duration(milliseconds: 100));
      }
    });
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    stream.playingController.add(false);
  }

  @override
  Future<void> stop() async {
    stops++;
    _clock?.cancel();
    _clock = null;
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    closes++;
    await super.dispose();
  }
}

Future<void> _pump(WidgetTester tester, [int count = 15]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late LocalStore store;
  late _Repository repository;
  late _Player player;
  late PlaybackLeaseQueue queue;
  late PlaybackSurface surface;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    await store.setPlaybackPreferences(
      const PlaybackPreferences(danmaku: false, preload: false),
    );
    repository = _Repository();
    player = _Player();
    queue = PlaybackLeaseQueue();
    surface = PlaybackSurface();
  });

  Future<void> open(
    WidgetTester tester,
    Drama drama,
    FeedPlaybackPlan plan, {
    Future<bool> Function()? onFinished,
    VoidCallback? onFull,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerScreen(
            key: ValueKey(drama.id),
            detail: _detail(drama),
            initialIndex: plan.initialIndex,
            initialPosition: plan.initialPosition,
            repository: repository,
            store: store,
            feed: true,
            playbackSurface: surface,
            playbackQueue: queue,
            feedPlayback: plan,
            playerFactory: () => player,
            videoBuilder: (controls) => controls,
            onPreviewFinished: onFinished == null ? null : (_) => onFinished(),
            onOpenFull: onFull,
          ),
        ),
      ),
    );
    await _pump(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, 2);
    await queue.idle;
    await surface.close();
    store.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('先静音定位才展示试看，定时保存、暂停与退出均不覆盖正片历史', (tester) async {
    final entry = WatchEntry(
      drama: _movie,
      episode: 2,
      position: 123,
      duration: 2700,
      updatedAt: DateTime(2026),
    );
    await store.saveWatch(entry);
    final plan = FeedPlaybackPlan(
      drama: _movie,
      resumeIndex: 1,
      resumePosition: 123,
      episodeCount: 3,
      random: Random(4),
    );
    await open(tester, _movie, plan);
    expect(player.opens, everyElement(false));
    expect(player.seeks.single, plan.preview!.start);
    expect(player.audibleStarts, isNotEmpty);
    expect(
      player.audibleStarts.first,
      greaterThanOrEqualTo(plan.preview!.start),
    );
    expect(
      tester
          .widget<PlayerViewportView>(find.byType(PlayerViewportView))
          .obscureVideo,
      false,
    );
    await _pump(tester, 60);
    await tester.tap(find.byKey(const ValueKey('feed-play-surface')));
    await tester.pump();
    expect(store.watched(_movie.id)?.episode, 2);
    expect(store.watched(_movie.id)?.position, 123);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, 2);
    expect(store.watched(_movie.id)?.position, 123);
    await close(tester);
  });

  testWidgets('试看终点只通知一次且不进入下一集，暂停期间不按墙上时间切片', (tester) async {
    var finished = 0;
    final plan = FeedPlaybackPlan(
      drama: _movie,
      resumeIndex: 0,
      resumePosition: 0,
      episodeCount: 3,
    );
    await open(
      tester,
      _movie,
      plan,
      onFinished: () async {
        finished++;
        return false;
      },
    );
    await tester.tap(find.byKey(const ValueKey('feed-play-surface')));
    await _pump(tester, 500);
    expect(finished, 0);
    await tester.tap(find.byKey(const ValueKey('feed-play-surface')));
    await tester.pump();
    player.emit(plan.preview!.end);
    await _pump(tester, 2);
    player.stream.positionController.add(plan.preview!.end);
    await tester.pump();
    expect(finished, 1);
    expect(repository.resolved, hasLength(1));
    expect(store.watched(_movie.id), isNull);
    await close(tester);
  });

  testWidgets('短剧正常续播并保存进度，切换作品复用同一个播放器', (tester) async {
    player.mediaDuration = const Duration(seconds: 90);
    final shortPlan = FeedPlaybackPlan(
      drama: _short,
      resumeIndex: 1,
      resumePosition: 12,
      episodeCount: 3,
    );
    await open(tester, _short, shortPlan);
    await _pump(tester, 50);
    expect(store.watched(_short.id)?.episode, 2);
    expect(store.watched(_short.id)?.position, greaterThanOrEqualTo(12));
    expect(
      tester.widget<FeedPlayerOverlay>(find.byType(FeedPlayerOverlay)).preview,
      false,
    );
    final moviePlan = FeedPlaybackPlan(
      drama: _movie,
      resumeIndex: 0,
      resumePosition: 0,
      episodeCount: 3,
    );
    player.mediaDuration = const Duration(minutes: 45);
    await open(tester, _movie, moviePlan);
    expect(player.opens, hasLength(2));
    expect(player.closes, 0);
    expect(player.stops, greaterThanOrEqualTo(2));
    await close(tester);
    expect(player.closes, 1);
  });

  testWidgets('定位失败保留正片入口，快速退出的旧任务不会触发换片', (tester) async {
    player.seekFails = true;
    var full = 0;
    var finished = 0;
    final plan = FeedPlaybackPlan(
      drama: _movie,
      resumeIndex: 0,
      resumePosition: 0,
      episodeCount: 3,
    );
    await open(
      tester,
      _movie,
      plan,
      onFull: () => full++,
      onFinished: () async {
        finished++;
        return false;
      },
    );
    expect(
      find.byKey(const ValueKey('feed-open-full-unavailable')),
      findsOneWidget,
    );
    expect(player.state.playing, false);
    await tester.tap(find.byKey(const ValueKey('feed-open-full-unavailable')));
    expect(full, 1);
    await close(tester);
    expect(finished, 0);
  });
}
