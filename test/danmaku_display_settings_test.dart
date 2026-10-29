import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_api.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';
import 'package:THLRedLook/views/danmaku/danmaku_overlay.dart';
import 'package:THLRedLook/views/player/external_danmaku_controls.dart';
import 'package:THLRedLook/views/player/player_danmaku_sheet_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final bytes = await font.readAsBytes();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  test(
    'old style migrates and extended style persists without losing source settings',
    () async {
      final old = DanmakuStyle.fromJson({
        'fontSizeScale': 1.25,
        'opacity': .6,
        'displayArea': .75,
      });
      expect(old.fontSizeScale, 1.25);
      expect(old.speed, 1);
      final style = old.copyWith(
        speed: 1.5,
        color: 0xa5e8ff,
        useOriginalColor: false,
        outline: true,
        shadow: false,
        density: DanmakuDensity.high,
        scroll: false,
        bottom: false,
        subtitleSafe: false,
        keywords: ['剧透', 'SPOILER'],
        blockColored: true,
      );
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setPlaybackPreferences(
        store.playbackPreferences.copyWith(danmakuStyle: style),
      );
      await store.setExternalDanmakuSettings(
        const ExternalDanmakuSettings(
          baseUrl: 'https://synthetic.invalid/token',
        ),
      );
      final restored = LocalStore(await SharedPreferences.getInstance());
      addTearDown(restored.dispose);
      expect(
        restored.playbackPreferences.danmakuStyle.toJson(),
        style.toJson(),
      );
      expect(
        restored.externalDanmakuSettings.baseUrl,
        'https://synthetic.invalid/token',
      );
      expect(restored.externalDanmakuSettings.endpoints.single.name, '默认 API');
    },
  );
  test('invalid style values are bounded and keywords normalized', () {
    final value = DanmakuStyle.fromJson({
      'speed': double.infinity,
      'opacity': -1,
      'fontSizeScale': double.nan,
      'displayArea': 5,
      'density': 'invalid',
      'keywords': [' ', '剧透', '剧透', 12],
    });
    expect(value.speed, 1);
    expect(value.opacity, .1);
    expect(value.fontSizeScale, 1);
    expect(value.displayArea, 1);
    expect(value.keywords, ['剧透']);
  });
  test(
    'filters, source colors and text effects have real display semantics',
    () {
      const white = DanmakuItem(id: 'w', text: '正常', timeMs: 0);
      const colored = DanmakuItem(
        id: 'c',
        text: 'Spoiler',
        timeMs: 0,
        color: 0xff0000,
        mode: DanmakuMode.top,
      );
      expect(
        const DanmakuStyle(keywords: ['spoiler']).accepts(colored),
        isFalse,
      );
      expect(const DanmakuStyle(blockColored: true).accepts(colored), isFalse);
      expect(const DanmakuStyle(blockColored: true).accepts(white), isTrue);
      expect(const DanmakuStyle(top: false).accepts(colored), isFalse);
      final paint = danmakuTextStyle(
        const DanmakuStyle(
          useOriginalColor: false,
          color: 0xa5e8ff,
          outline: true,
          shadow: false,
        ),
        16,
        itemColor: colored.color,
      );
      expect(paint.color, const Color(0xffa5e8ff));
      expect(paint.shadows, hasLength(4));
      expect(
        danmakuTextStyle(
          const DanmakuStyle(outline: false, shadow: false),
          16,
        ).shadows,
        isEmpty,
      );
    },
  );
  test(
    'native pages preserve optional color and mode while old rows stay white scroll',
    () {
      final page = DanmakuPage.fromJson(
        {
          'episodeId': 'test',
          'startMs': 0,
          'nextMs': 30000,
          'items': [
            {
              'id': 'a',
              'text': '顶部',
              'timeMs': 1000,
              'color': '#FF0000',
              'mode': 5,
            },
            {'id': 'b', 'text': '旧格式', 'timeMs': 2000},
          ],
        },
        episodeId: 'test',
        startMs: 0,
        durationMs: 120000,
      );
      expect(page.items.first.color, 0xff0000);
      expect(page.items.first.mode, DanmakuMode.top);
      expect(page.items.last.color, 0xffffff);
      expect(page.items.last.mode, DanmakuMode.scroll);
    },
  );
  test(
    'external tracks retain color and fixed types and do not collapse distinct modes',
    () async {
      final api = ExternalDanmakuApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'comments': [
                {'p': '1,1,16777215,user', 'm': '同一文字'},
                {'p': '1,5,16711680,user', 'm': '同一文字'},
                {'p': '2,4,16777215,user', 'm': '底部'},
                {'p': '3,7,16777215,user', 'm': '高级模式'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(api.dispose);
      final track = await api.track('https://synthetic.invalid', 'episode');
      expect(track.items, hasLength(3));
      expect(
        track.items.map((item) => item.mode).toSet(),
        DanmakuMode.values.toSet(),
      );
      expect(
        track.items.where((item) => item.mode == DanmakuMode.top).single.color,
        0xff0000,
      );
    },
  );
  test('scroll top and bottom are planned in separate safe tracks', () {
    const items = [
      DanmakuItem(id: 'scroll', text: '滚动', timeMs: 0),
      DanmakuItem(id: 'top', text: '顶部', timeMs: 0, mode: DanmakuMode.top),
      DanmakuItem(
        id: 'bottom',
        text: '底部',
        timeMs: 0,
        mode: DanmakuMode.bottom,
      ),
    ];
    final plan = planDanmaku(
      items,
      width: 400,
      rows: 2,
      totalRows: 4,
      measure: (_) => 40,
    );
    expect(plan, hasLength(3));
    expect(plan.map((flight) => flight.lane).toSet(), hasLength(3));
    expect(plan.last.lane, 3);
    expect(
      plan
          .where((flight) => flight.item.mode != DanmakuMode.scroll)
          .every((flight) => flight.durationMs == 4000),
      isTrue,
    );
    final fast = planDanmaku(
      items,
      width: 400,
      rows: 2,
      totalRows: 4,
      measure: (_) => 40,
      style: const DanmakuStyle(speed: 2),
    );
    expect(fast.first.durationMs, closeTo(plan.first.durationMs / 2, 1));
    expect(fast.last.durationMs, 4000);
  });
  test(
    'density changes capacity and keywords remove comments before scheduling',
    () {
      final items = [
        for (var i = 0; i < 20; i++)
          DanmakuItem(id: '$i', text: '固定$i', timeMs: 0, mode: DanmakuMode.top),
      ];
      List<DanmakuFlight> plan(DanmakuStyle style) => planDanmaku(
        items,
        width: 400,
        rows: 16,
        measure: (_) => 20,
        style: style,
      );
      expect(
        plan(const DanmakuStyle(density: DanmakuDensity.low)),
        hasLength(12),
      );
      expect(
        plan(const DanmakuStyle(density: DanmakuDensity.high)),
        hasLength(16),
      );
      expect(plan(const DanmakuStyle(keywords: ['固定'])), isEmpty);
    },
  );
  test(
    'multiple APIs retain paths and automatic-match preferences across selection',
    () {
      final original = ExternalDanmakuSettings.fromJson({
        'baseUrl': 'https://one.invalid/token/api/v2',
      });
      final next = original.copyWith(
        baseUrl: 'https://two.invalid/prefix',
        autoMatch: false,
        sources: [
          ...original.endpoints,
          const DanmakuApiSource(
            name: '第二个',
            baseUrl: 'https://two.invalid/prefix',
          ),
        ],
      );
      final restored = ExternalDanmakuSettings.fromJson(
        jsonDecode(jsonEncode(next.toJson())) as Map<String, dynamic>,
      );
      expect(restored.endpoints, hasLength(2));
      expect(restored.baseUrl, 'https://two.invalid/prefix');
      expect(restored.autoMatch, isFalse);
      expect(restored.copyWith(mode: 'native').endpoints, hasLength(2));
    },
  );
  test(
    'disabling automatic matching makes no request until a manual binding exists',
    () async {
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setExternalDanmakuSettings(
        const ExternalDanmakuSettings(
          baseUrl: 'https://synthetic.invalid',
          autoMatch: false,
        ),
      );
      var requests = 0;
      final api = ExternalDanmakuApi(
        client: MockClient((request) async {
          requests++;
          return http.Response(
            jsonEncode(
              request.url.path.contains('/bangumi/')
                  ? {
                      'bangumi': {
                        'animeId': 1,
                        'animeTitle': '合成作品',
                        'episodes': [
                          {'episodeId': 11, 'episodeTitle': '第1集'},
                        ],
                      },
                    }
                  : {
                      'comments': [
                        {'p': '1,5,16777215,user', 'm': '手动顶部'},
                      ],
                    },
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final session = ExternalDanmakuSession(store, api: api)
        ..setMedia(
          const DanmakuMedia(workId: 'test', title: '合成作品', episode: 1),
        );
      addTearDown(session.dispose);
      expect((await session.page(0, 120000)).items, isEmpty);
      expect(requests, 0);
      await session.choose(
        const DanmakuCandidate(id: '1', title: '合成作品'),
        const DanmakuLibraryEpisode('11', '第1集'),
      );
      await session.setOffset(1000);
      final shifted = await session.page(0, 120000);
      expect(shifted.items.single.timeMs, 2000);
      expect(shifted.items.single.mode, DanmakuMode.top);
      expect(requests, 2);
    },
  );
  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    testWidgets('settings tabs and real style controls fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = const DanmakuStyle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('style-capture'),
              child: PlayerDanmakuSheetView(
                style: selected,
                onStyleChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('显示弹幕'), findsNothing);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('style-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('build/verification').createSync(recursive: true);
        File(
          'build/verification/danmaku-settings-${size.width.round()}-display.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      final opacity = find.byKey(const ValueKey('danmaku-opacity-0.4'));
      await tester.scrollUntilVisible(
        opacity,
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('danmaku-display-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(opacity);
      await tester.pumpAndSettle();
      expect(selected.opacity, .4);
      await tester.tap(find.text('高级'));
      await tester.pumpAndSettle();
      final keywords = find.byKey(const ValueKey('danmaku-keywords'));
      await tester.ensureVisible(keywords);
      await tester.pumpAndSettle();
      await tester.tap(keywords);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('danmaku-keywords-input')),
        '剧透\nSPOILER\n剧透',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(selected.keywords, ['剧透', 'SPOILER']);
      final colored = find.byKey(const ValueKey('danmaku-block-colored'));
      await tester.ensureVisible(colored);
      await tester.pumpAndSettle();
      await tester.tap(colored);
      await tester.pumpAndSettle();
      expect(selected.blockColored, isTrue);
      final reset = find.byKey(const ValueKey('danmaku-reset-style'));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(selected.blockColored, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'API manager adds names and URLs and saves the selected source $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = LocalStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        final session = ExternalDanmakuSession(store);
        addTearDown(session.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ExternalDanmakuControls(session: session, onChanged: () {}),
            ),
          ),
        );
        await tester.tap(find.byTooltip('配置通用弹幕 API'));
        await tester.pumpAndSettle();
        for (var i = 1; i <= 2; i++) {
          await tester.tap(find.byKey(const ValueKey('danmaku-api-add')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('danmaku-api-name')),
            '服务$i',
          );
          await tester.enterText(
            find.byKey(const ValueKey('danmaku-api-address')),
            'https://service$i.invalid/prefix',
          );
          await tester.tap(find.text('确定'));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('服务2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('服务2'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('danmaku-api-save')));
        await tester.pumpAndSettle();
        expect(store.externalDanmakuSettings.endpoints, hasLength(2));
        expect(
          store.externalDanmakuSettings.baseUrl,
          'https://service2.invalid/prefix',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
