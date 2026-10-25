import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';
import 'package:THLRedLook/core/js/js_source_models.dart';
import 'package:THLRedLook/core/js/js_source_service.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/pages/home/home_page.dart';
import 'package:THLRedLook/views/browser/catalog_browser.dart';

const _metas = [
  JsSourceMeta(
    id: 'hongguo',
    name: '官方合成源',
    features: ['search'],
    sourceUrl: 'https://source.invalid/official.js',
  ),
  JsSourceMeta(id: 'synthetic_a', name: '合成源 A'),
  JsSourceMeta(id: 'synthetic_b', name: '合成源 B', features: ['search']),
  JsSourceMeta(id: 'no_search', name: '仅分类', features: ['categories']),
];

CatalogPage _page(String source, int page, {bool hasMore = false}) =>
    CatalogPage(
      [
        Drama(
          id: '$source:shared-$page',
          source: source,
          title: '合成搜索结果 $source $page',
        ),
      ],
      page: page,
      hasMore: hasMore,
    );

class _SearchRepository extends AppRepository {
  final requests =
      <({String source, int page, String query, String category})>[];
  Future<CatalogPage> Function(String source, int page, String query)? respond;

  @override
  Future<int> jsSourceScan() async => _metas.length;
  @override
  Future<List<JsSourceMeta>> jsSourceList() async => _metas;
  @override
  Future<bool> jsSourceSetActive(String sourceId) async => true;
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage(const [], hasMore: true);
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    requests.add((
      source: source,
      page: page,
      query: query,
      category: category,
    ));
    return respond == null
        ? _page(source, page)
        : respond!(source, page, query);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SearchRepository repository;
  late JsSourceService service;
  late LocalStore store;

  SourceGroup group() => SourceGroup(
    'search:all',
    '全部站源',
    store.sources.where((source) => source.onlineSearch).toList(),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'active_js_source_id': 'synthetic_a',
    });
    final preferences = await SharedPreferences.getInstance();
    repository = _SearchRepository();
    service = JsSourceService(repository, preferences);
    await service.initialize();
    store = LocalStore(preferences);
    await store.setCatalogSource('synthetic_a', allSources: false);
  });

  tearDown(() {
    store.dispose();
    service.dispose();
    JsSourceService.current = null;
  });

  test('导入源根据能力参与搜索，缺省能力兼容且不搜索仅分类源', () {
    expect(group().sources.map((source) => source.id), [
      'hongguo',
      'synthetic_a',
      'synthetic_b',
    ]);
    expect(SourceSite.byId('synthetic_a').pagedSearch, isTrue);
    expect(SourceSite.byId('no_search').onlineSearch, isFalse);
  });

  testWidgets('从非官方源发起全部站源搜索，来源标识和清空后的浏览源正确', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          repository: repository,
          store: store,
          initialSearchVisible: true,
          initialSearchQuery: '合成',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      repository.requests
          .where((request) => request.query == '合成')
          .map((r) => r.source)
          .toSet(),
      {'hongguo', 'synthetic_a', 'synthetic_b'},
    );
    expect(find.textContaining('合成源 A ·'), findsOneWidget);
    expect(find.textContaining('合成源 B ·'), findsOneWidget);
    expect(store.source, 'synthetic_a');
    expect(service.activeSourceId, 'synthetic_a');

    repository.requests.clear();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(repository.requests.map((r) => r.source).toSet(), {'synthetic_a'});
    expect(repository.requests.every((r) => r.query.isEmpty), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('各源分别续页，同名作品保留各自完整站源编号', () async {
    final browser = CatalogBrowser(repository);
    repository.respond = (source, page, query) async =>
        _page(source, page, hasMore: source == 'synthetic_a' && page == 1);
    final first = await browser.load(group(), query: '合成');
    expect(first.items.map((drama) => drama.id).toSet(), {
      'hongguo:shared-1',
      'synthetic_a:shared-1',
      'synthetic_b:shared-1',
    });
    repository.requests.clear();
    final next = await browser.load(group(), query: '合成', more: true);
    expect(repository.requests.map((r) => (r.source, r.page)), [
      ('synthetic_a', 2),
    ]);
    expect(next.items, hasLength(4));
    expect(next.hasMore, isFalse);
  });

  test('慢源完成前可以显示其他源结果，失败信息包含具体来源', () async {
    final browser = CatalogBrowser(repository);
    final pending = Completer<CatalogPage>();
    final partial = Completer<CatalogPage>();
    repository.respond = (source, page, query) async {
      if (source == 'synthetic_a') return pending.future;
      if (source == 'synthetic_b') throw AppFailure('合成网络失败');
      return _page(source, page);
    };
    final request = browser.load(
      group(),
      query: '合成',
      onPartial: (page) {
        if (!partial.isCompleted) partial.complete(page);
      },
    );
    expect((await partial.future).items.single.source, 'hongguo');
    pending.complete(_page('synthetic_a', 1));
    final result = await request;
    expect(result.items, hasLength(2));
    expect(result.warning, contains('合成源 B：合成网络失败'));
  });

  test('更换搜索词后迟到结果不会覆盖当前查询或继续投递部分结果', () async {
    final browser = CatalogBrowser(repository);
    final started = Completer<void>();
    final pending = Completer<CatalogPage>();
    var stalePartials = 0;
    repository.respond = (source, page, query) async {
      if (query == '旧词') {
        if (!started.isCompleted) started.complete();
        return pending.future;
      }
      return _page(source, page);
    };
    final old = browser.load(
      group(),
      query: '旧词',
      onPartial: (_) => stalePartials++,
    );
    await started.future;
    final current = await browser.load(group(), query: '新词');
    pending.complete(CatalogPage(const [], hasMore: false));
    await old;
    expect(current.items, hasLength(3));
    expect(stalePartials, 0);
  });

  test('JS 搜索支持字符串页号及明确的 hasMore 分页标记', () async {
    final client = MockClient((_) async => throw StateError('不应访问网络'));
    final runtime = CatPawJsRuntime(client);
    addTearDown(runtime.dispose);
    addTearDown(client.close);
    await runtime.init('''
var spider = {search: function(word, quick, page) {
  return {page: String(page), has_more: page === 1 ? '1' : '0', list: []};
}};
''');
    expect((await runtime.search('合成')).hasMore, isTrue);
    final second = await runtime.search('合成', page: 2);
    expect(second.page, 2);
    expect(second.hasMore, isFalse);
  });
}
