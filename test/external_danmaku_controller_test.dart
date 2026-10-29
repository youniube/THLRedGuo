import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/danmaku/danmaku_controller.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_api.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';
import 'package:THLRedLook/views/player/external_danmaku_controls.dart';
import 'package:THLRedLook/views/player/player_danmaku_sheet_view.dart';

class _Repository extends AppRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
  _Repository(this.read);
  final Future<DanmakuPage> Function(PlaybackPlan, int, int) read;
  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required String source,
    required int startMs,
    required int durationMs,
  }) => read(plan, startMs, durationMs);
}

void _update(DanmakuController controller, [int position = 0]) =>
    controller.update(
      position: Duration(milliseconds: position),
      duration: const Duration(minutes: 2),
      speed: 1,
      playing: false,
      buffering: false,
      foreground: true,
      available: true,
    );

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    await store.setExternalDanmakuSettings(
      const ExternalDanmakuSettings(baseUrl: 'https://synthetic.invalid'),
    );
  });
  tearDown(() => store.dispose());

  test(
    'native danmaku remains preferred and supports timing adjustment',
    () async {
      var externalCalls = 0;
      final session = ExternalDanmakuSession(
        store,
        api: ExternalDanmakuApi(
          client: MockClient((_) async {
            externalCalls++;
            return http.Response('{}', 500);
          }),
        ),
      )..setMedia(const DanmakuMedia(workId: 'test', title: '合成', episode: 1));
      addTearDown(session.dispose);
      await session.setOffset(1000);
      final repository = _Repository(
        (plan, start, duration) async => DanmakuPage(
          episodeId: plan.danmakuId,
          startMs: start,
          nextMs: 30000,
          items: const [
            DanmakuItem(
              id: 'native:1',
              text: '原站',
              timeMs: 1000,
              color: 0xff0000,
              mode: DanmakuMode.bottom,
            ),
          ],
        ),
      );
      final controller =
          DanmakuController(repository, source: 'hongguo', external: session)
            ..setPlan(
              const PlaybackPlan(
                url: 'synthetic',
                session: 'one',
                danmakuId: 'hongguo:test',
              ),
            );
      addTearDown(controller.dispose);
      _update(controller);
      await _flush();
      expect(controller.items.single.timeMs, 2000);
      expect(controller.items.single.color, 0xff0000);
      expect(controller.items.single.mode, DanmakuMode.bottom);
      expect(externalCalls, 0);
      controller.setEnabled(false);
      expect(controller.visible, isFalse);
    },
  );

  test(
    'responses from a previous episode never enter the current timeline',
    () async {
      final replies = <String, Completer<DanmakuPage>>{};
      final repository = _Repository(
        (plan, start, duration) =>
            (replies[plan.danmakuId] = Completer<DanmakuPage>()).future,
      );
      final controller = DanmakuController(repository, source: 'test');
      addTearDown(controller.dispose);
      for (final id in ['old', 'new']) {
        controller.setPlan(
          PlaybackPlan(url: 'synthetic', session: id, danmakuId: id),
        );
        _update(controller);
      }
      for (final id in ['new', 'old']) {
        replies[id]!.complete(
          DanmakuPage(
            episodeId: id,
            startMs: 0,
            nextMs: 30000,
            items: [DanmakuItem(id: id, text: id, timeMs: 1000)],
          ),
        );
        await _flush();
      }
      expect(controller.items.map((item) => item.text), ['new']);
    },
  );

  test(
    'saved identifiers are revalidated before any comment request',
    () async {
      const media = DanmakuMedia(workId: 'test', title: '原作品', episode: 1);
      await store.setDanmakuBinding('https://synthetic.invalid|${media.key}', {
        'animeId': '1',
        'animeTitle': '原作品',
        'episodeId': '11',
        'episodeTitle': '第1集',
      });
      var comments = 0;
      final api = ExternalDanmakuApi(
        client: MockClient((request) async {
          if (request.url.path.contains('/comment/')) comments++;
          return http.Response(
            jsonEncode({
              'bangumi': {
                'animeId': 1,
                'animeTitle': '其他作品',
                'episodes': [
                  {'episodeId': 11, 'episodeTitle': '第1集'},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final session = ExternalDanmakuSession(store, api: api)..setMedia(media);
      addTearDown(session.dispose);
      await expectLater(session.page(0, 120000), throwsFormatException);
      expect(comments, 0);
    },
  );

  test(
    'ambiguous media can be corrected manually and restored after restart',
    () async {
      const media = DanmakuMedia(workId: 'test', title: '别名作品', episode: 1);
      const candidate = DanmakuCandidate(id: '2', title: '明确选择的作品');
      final session = ExternalDanmakuSession(store)..setMedia(media);
      await session.choose(candidate, const DanmakuLibraryEpisode('21', '第1集'));
      await session.setOffset(2000);
      session.dispose();
      final api = ExternalDanmakuApi(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.contains('/bangumi/')
                  ? {
                      'bangumi': {
                        'animeId': 2,
                        'animeTitle': '明确选择的作品',
                        'episodes': [
                          {'episodeId': '21', 'episodeTitle': '第1集'},
                        ],
                      },
                    }
                  : {
                      'comments': [
                        {'p': '1,1,0,user', 'm': '手动纠正'},
                      ],
                    },
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final restored = ExternalDanmakuSession(store, api: api)..setMedia(media);
      addTearDown(restored.dispose);
      expect((await restored.page(0, 120000)).items.single.timeMs, 3000);
    },
  );

  test(
    'JS playback without danmakuId uses the configured library and keeps seek cache',
    () async {
      var nativeCalls = 0, commentCalls = 0;
      final api = ExternalDanmakuApi(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.contains('/comment/')) commentCalls++;
          final value = path.endsWith('/search/anime')
              ? {
                  'animes': [
                    {'animeId': 1, 'animeTitle': '合成剧', 'type': 'tvseries'},
                  ],
                }
              : path.endsWith('/bangumi/1')
              ? {
                  'bangumi': {
                    'animeId': 1,
                    'animeTitle': '合成剧',
                    'episodes': [
                      {'episodeId': 12, 'episodeTitle': '第2集'},
                    ],
                  },
                }
              : {
                  'comments': [
                    {'p': '1.25,1,0,u', 'm': '来自通用接口'},
                    {'p': '31,1,0,u', 'm': '拖动后仍可使用缓存'},
                  ],
                };
          return http.Response(
            jsonEncode(value),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final session = ExternalDanmakuSession(store, api: api)
        ..setMedia(
          const DanmakuMedia(
            workId: 'test:external',
            title: '合成剧',
            season: 1,
            episode: 2,
          ),
        );
      addTearDown(session.dispose);
      final repository = _Repository((plan, start, duration) async {
        nativeCalls++;
        throw StateError('Native source must not be called');
      });
      final controller = DanmakuController(
        repository,
        source: 'synthetic',
        external: session,
      )..setPlan(const PlaybackPlan(url: 'synthetic', session: 'external'));
      addTearDown(controller.dispose);
      Future<void> waitFor(int time) {
        final ready = Completer<void>();
        void listener() {
          if (!ready.isCompleted &&
              !controller.loading &&
              controller.items.any((row) => row.timeMs == time)) {
            ready.complete();
          }
        }

        controller.addListener(listener);
        addTearDown(() => controller.removeListener(listener));
        return ready.future.timeout(const Duration(seconds: 10));
      }

      final initial = waitFor(1250);
      _update(controller);
      await initial;
      expect(controller.usesExternal, isTrue);
      final seek = waitFor(31000);
      _update(controller, 31000);
      await seek;
      expect(nativeCalls, 0);
      expect(commentCalls, 1);
      controller.setPlan(
        const PlaybackPlan(url: 'local', local: true, session: 'offline'),
      );
      _update(controller);
      expect(controller.supported, isFalse);
      expect(commentCalls, 1);
    },
  );

  testWidgets('style sheet keeps one opacity section and no duplicate switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ExternalDanmakuSession(store)
      ..setMedia(const DanmakuMedia(workId: 'test', title: '合成', episode: 1));
    var selected = const DanmakuStyle();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('sheet-review'),
            child: PlayerDanmakuSheetView(
              style: selected,
              onStyleChanged: (value) => selected = value,
              sourceControls: ExternalDanmakuControls(
                session: session,
                onChanged: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('数据源'));
    await tester.pumpAndSettle();
    expect(find.text('弹幕来源'), findsOneWidget);
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    expect(find.text('不透明度'), findsOneWidget);
    expect(find.text('显示弹幕'), findsNothing);
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('sheet-review')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/verification').createSync(recursive: true);
      File(
        'build/verification/external-danmaku-sheet.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final opacity = find.byKey(const ValueKey('danmaku-opacity-0.4'));
    await tester.ensureVisible(opacity);
    await tester.tap(opacity);
    expect(selected.opacity, .4);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}
