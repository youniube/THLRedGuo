import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/danmaku/danmaku_controller.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_api.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';
import 'package:THLRedLook/pages/settings/playback_settings_page.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';
import 'package:THLRedLook/utils/theme/app_theme.dart';
import 'package:THLRedLook/views/player/external_danmaku_controls.dart';
import 'package:THLRedLook/views/player/player_danmaku_sheet_view.dart';

const _media = DanmakuMedia(
  workId: 'synthetic',
  title: '合成作品第二季',
  season: 2,
  episode: 5,
);
const _candidate = DanmakuCandidate(id: '7', title: '合成作品第二季', season: 2);
const _episodes = [
  DanmakuLibraryEpisode('705', '第5集'),
  DanmakuLibraryEpisode('706', '第6集'),
];
const _track = ExternalDanmakuTrack([
  DanmakuItem(id: 'first', text: '第一条', timeMs: 1000),
  DanmakuItem(id: 'later', text: '后续时段', timeMs: 31000),
], 120000);

class _Api extends ExternalDanmakuApi {
  List<DanmakuCandidate> candidates = [_candidate];
  Future<ExternalDanmakuTrack> Function(String)? read;
  @override
  Future<List<DanmakuCandidate>> search(String base, String keyword) async =>
      candidates;
  @override
  Future<List<DanmakuLibraryEpisode>> episodes(
    String base,
    String id, {
    String? expectedTitle,
  }) async => _episodes;
  @override
  Future<ExternalDanmakuTrack> track(
    String base,
    String id, {
    String identity = '',
  }) => read?.call(id) ?? Future.value(_track);
}

class _Repository extends AppRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
  @override
  Future<void> cancelDanmaku() async {}
  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required String source,
    required int startMs,
    required int durationMs,
  }) async => DanmakuPage(
    episodeId: plan.danmakuId,
    startMs: startMs,
    nextMs: startMs + 30000,
    items: [
      DanmakuItem(
        id: 'native:$startMs',
        text: '原站合成弹幕',
        timeMs: startMs + 1000,
      ),
    ],
  );
}

void _play(DanmakuController controller) => controller.update(
  position: Duration.zero,
  duration: const Duration(minutes: 2),
  speed: 1,
  playing: false,
  buffering: false,
  foreground: true,
  available: true,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pumpAndSettle();
}

Widget _panel(ExternalDanmakuSession session, DanmakuController controller) =>
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('source-status-capture'),
          child: PlayerDanmakuSheetView(
            initialTab: DanmakuSettingsTab.sources,
            style: const DanmakuStyle(),
            onStyleChanged: (_) {},
            sourceControls: ExternalDanmakuControls(
              session: session,
              controller: controller,
              onChanged: controller.reload,
              showOffset: false,
            ),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late _Api api;
  late ExternalDanmakuSession session;
  late DanmakuController controller;

  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('Hiragino Sans GB')
        ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    await store.setExternalDanmakuSettings(
      const ExternalDanmakuSettings(
        baseUrl: 'https://one.invalid/private-token',
        sources: [
          DanmakuApiSource(
            name: '合成服务一',
            baseUrl: 'https://one.invalid/private-token',
          ),
          DanmakuApiSource(name: '合成服务二', baseUrl: 'https://two.invalid'),
        ],
      ),
    );
    api = _Api();
    session = ExternalDanmakuSession(store, api: api)..setMedia(_media);
    controller = DanmakuController(
      _Repository(),
      source: 'synthetic',
      external: session,
    )..setPlan(const PlaybackPlan(url: 'synthetic', session: 'test'));
  });
  tearDown(() {
    controller.dispose();
    session.dispose();
    store.dispose();
  });

  test(
    'whole episode count survives windows and clears for API and episode changes',
    () async {
      await session.page(0, 120000);
      expect(session.loadedCount, 2);
      await session.page(30000, 120000);
      expect(session.loadedCount, 2);
      await session.reset();
      expect(session.loadedCount, isNull);
      expect(session.binding['episodeId'], isNull);
      await session.page(0, 120000);
      expect(session.loadedCount, 2);
      await session.configure(
        session.settings.copyWith(baseUrl: 'https://two.invalid'),
      );
      expect(session.loadedCount, isNull);
      expect(session.status, isEmpty);
      expect(session.binding['episodeId'], isNull);
      await session.page(0, 120000);
      expect(session.loadedCount, 2);
      session.setMedia(
        const DanmakuMedia(
          workId: 'synthetic',
          title: '合成作品第二季',
          season: 2,
          episode: 6,
        ),
      );
      expect(session.loadedCount, isNull);
      expect(session.binding['episodeId'], isNull);
    },
  );

  test(
    'late comments cannot restore an obsolete match after manual correction',
    () async {
      final gate = Completer<ExternalDanmakuTrack>();
      final requested = Completer<void>();
      api.read = (_) {
        if (!requested.isCompleted) requested.complete();
        return gate.future;
      };
      final previous = session.page(0, 120000);
      await requested.future;
      await session.choose(_candidate, _episodes.last);
      gate.complete(_track);
      expect((await previous).items, isEmpty);
      expect(session.loadedCount, isNull);
      expect(session.binding['episodeId'], '706');
      expect(session.status, contains('等待加载'));
      api.read = (_) async => _track;
      await session.page(0, 120000);
      expect(session.loadedCount, 2);
      expect(session.binding['episodeTitle'], '第6集');
    },
  );

  testWidgets(
    'panel follows real loading, matched title and whole episode count',
    (tester) async {
      final gate = Completer<ExternalDanmakuTrack>();
      api.read = (_) => gate.future;
      await tester.pumpWidget(_panel(session, controller));
      _play(controller);
      await tester.pump();
      expect(find.text('正在加载弹幕'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      gate.complete(_track);
      await _settle(tester);
      expect(controller.items, hasLength(1));
      expect(find.text('合成作品第二季 · 第5集'), findsOneWidget);
      expect(find.text('已载入 2 条弹幕'), findsOneWidget);
      expect(find.text('合成服务一'), findsOneWidget);
      expect(find.text('API 管理 · 2'), findsOneWidget);
      expect(find.textContaining('one.invalid'), findsOneWidget);
      expect(find.textContaining('private-token'), findsNothing);
      expect(find.text('通用 API 已配置，按作品和分集匹配'), findsNothing);
      controller.setEnabled(false);
      await _settle(tester);
      expect(find.text('弹幕已关闭'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'native status stays accurate when external session has no status',
    (tester) async {
      controller.setPlan(
        const PlaybackPlan(
          url: 'synthetic',
          session: 'native',
          danmakuId: 'native:test',
        ),
      );
      _play(controller);
      await tester.pumpWidget(_panel(session, controller));
      await _settle(tester);
      expect(session.status, isEmpty);
      expect(find.text('原站弹幕'), findsOneWidget);
      expect(find.text('合成作品第二季 · 第 5 集'), findsOneWidget);
      expect(find.text('当前缓存 1 条原站弹幕'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed API is visible and can be retried from the panel', (
    tester,
  ) async {
    api.read = (_) async => throw const FormatException('synthetic failure');
    _play(controller);
    await tester.pumpWidget(_panel(session, controller));
    await _settle(tester);
    expect(find.text('弹幕暂不可用，可重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('danmaku-retry-load')), findsOneWidget);
    api.read = (_) async => _track;
    await tester.ensureVisible(
      find.byKey(const ValueKey('danmaku-retry-load')),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('danmaku-retry-load')));
    await _settle(tester);
    expect(find.text('已载入 2 条弹幕'), findsOneWidget);
    expect(find.byKey(const ValueKey('danmaku-retry-load')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unmatched content reports no result without inventing a title', (
    tester,
  ) async {
    api.candidates = [];
    _play(controller);
    await tester.pumpWidget(_panel(session, controller));
    await _settle(tester);
    expect(find.text('没有确认到对应作品，请手动搜索弹幕'), findsOneWidget);
    expect(find.byKey(const ValueKey('danmaku-match-title')), findsNothing);
    expect(session.loadedCount, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native-only mode disables external matching and manager remains available',
    (tester) async {
      _play(controller);
      await tester.pumpWidget(_panel(session, controller));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('danmaku-mode-native')));
      await _settle(tester);
      expect(store.externalDanmakuSettings.mode, 'native');
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('danmaku-auto-match')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('danmaku-manual-search')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('danmaku-api-management')));
      await _settle(tester);
      expect(find.text('弹幕 API 管理'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('danmaku-mode-external')));
      await _settle(tester);
      expect(store.externalDanmakuSettings.mode, 'external');
      expect(find.text('已载入 2 条弹幕'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('source layout uses THL theme and fits $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      _play(controller);
      await tester.pumpWidget(_panel(session, controller));
      await _settle(tester);
      final match = find.byKey(const ValueKey('danmaku-current-match'));
      final sourceTheme = Theme.of(tester.element(match));
      expect(sourceTheme.colorScheme.primary, AppColors.hongguoRed);
      expect(find.byType(Card), findsNothing);
      expect(find.text('显示弹幕'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('danmaku-rematch')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('source-status-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('build/verification').createSync(recursive: true);
        File(
          'build/verification/danmaku-source-${size.width.round()}.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('显示'));
      await _settle(tester);
      await tester.tap(find.text('数据源'));
      await _settle(tester);
      expect(find.text('已载入 2 条弹幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'global display and advanced entries save the shared player preferences',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: PlaybackSettingsPage(store: store),
        ),
      );
      await _settle(tester);
      final entry = find.byKey(const ValueKey('settings-danmaku-display'));
      await tester.ensureVisible(entry);
      await _settle(tester);
      await tester.tap(entry);
      await _settle(tester);
      expect(find.text('显示弹幕'), findsNothing);
      final opacity = find.byKey(const ValueKey('danmaku-opacity-0.4'));
      await tester.ensureVisible(opacity);
      await _settle(tester);
      await tester.tap(opacity);
      await _settle(tester);
      expect(store.playbackPreferences.danmakuStyle.opacity, .4);
      await tester.tap(find.byTooltip('关闭'));
      await _settle(tester);
      expect(find.textContaining('不透明度 40%'), findsOneWidget);
      final advanced = find.byKey(const ValueKey('settings-danmaku-advanced'));
      await tester.ensureVisible(advanced);
      await _settle(tester);
      await tester.tap(advanced);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('danmaku-block-colored')),
        findsOneWidget,
      );
      expect(find.text('时间同步'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('danmaku-block-colored')));
      await _settle(tester);
      await tester.tap(find.byTooltip('关闭'));
      await _settle(tester);
      expect(find.textContaining('屏蔽彩色弹幕'), findsOneWidget);
      final restored = LocalStore(await SharedPreferences.getInstance());
      expect(restored.playbackPreferences.danmakuStyle.opacity, .4);
      expect(restored.playbackPreferences.danmakuStyle.blockColored, isTrue);
      restored.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'global sources share mode and named APIs without an invented current match',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: PlaybackSettingsPage(store: store),
        ),
      );
      await _settle(tester);
      final entry = find.byKey(const ValueKey('settings-external-danmaku'));
      await tester.ensureVisible(entry);
      await _settle(tester);
      await tester.tap(entry);
      await _settle(tester);
      expect(find.text('当前匹配'), findsNothing);
      expect(find.byKey(const ValueKey('danmaku-manual-search')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('danmaku-mode-external')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('danmaku-auto-match')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('danmaku-api-management')));
      await _settle(tester);
      await tester.tap(find.text('合成服务二'));
      await tester.tap(find.byKey(const ValueKey('danmaku-api-save')));
      await _settle(tester);
      expect(find.text('合成服务二'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await _settle(tester);
      expect(store.externalDanmakuSettings.baseUrl, 'https://two.invalid');
      expect(store.externalDanmakuSettings.mode, 'external');
      expect(store.externalDanmakuSettings.autoMatch, isFalse);
      expect(find.text('通用 API · 合成服务二 · 2 个 API'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'global settings retain THL layout and independent master switch',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: RepaintBoundary(
            key: const ValueKey('global-settings-capture'),
            child: PlaybackSettingsPage(store: store),
          ),
        ),
      );
      await _settle(tester);
      final toggle = find.byKey(const ValueKey('settings-danmaku-enabled'));
      await tester.ensureVisible(toggle);
      await _settle(tester);
      await tester.tap(toggle);
      await _settle(tester);
      expect(store.playbackPreferences.danmaku, isFalse);
      expect(store.externalDanmakuSettings.endpoints, hasLength(2));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('global-settings-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('build/verification').createSync(recursive: true);
        File(
          'build/verification/danmaku-global-settings.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
