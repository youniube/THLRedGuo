import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/danmaku/external_danmaku_api.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';

const _media = DanmakuMedia(
  workId: 'synthetic:work',
  title: '合成作品第二季',
  year: 2024,
  kind: 'tv',
  season: 2,
  episode: 5,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    await store.setExternalDanmakuSettings(
      const ExternalDanmakuSettings(
        baseUrl: 'https://synthetic.invalid/custom/token',
      ),
    );
  });
  tearDown(() => store.dispose());

  test('preserves service prefix and normalizes only the API suffix', () {
    final config = ExternalDanmakuSettings.fromJson({
      'baseUrl': 'https://synthetic.invalid/custom/token/api/v2/',
    });
    expect(config.baseUrl, 'https://synthetic.invalid/custom/token');
    expect(
      () => ExternalDanmakuSettings.fromJson({'baseUrl': 'file:///tmp/data'}),
      throwsFormatException,
    );
    expect(
      () => ExternalDanmakuSettings.fromJson({
        'baseUrl': 'https://user:password@synthetic.invalid/',
      }),
      throwsFormatException,
    );
  });

  test(
    'matches title year type season and actual episode, never list position',
    () {
      final candidate = DanmakuCandidate.fromJson({
        'animeId': 1,
        'animeTitle': '合成作品 第二季 (2024)【腾讯】',
        'type': 'tvseries',
      });
      expect(candidate.matches(_media), isTrue);
      expect(
        DanmakuCandidate.fromJson({
          'animeId': 2,
          'animeTitle': '合成作品第一季(2024)',
          'type': 'tvseries',
        }).matches(_media),
        isFalse,
      );
      expect(
        DanmakuCandidate.fromJson({
          'animeId': 3,
          'animeTitle': '合成作品第二季(2023)',
          'type': 'movie',
        }).matches(_media),
        isFalse,
      );
      expect(danmakuEpisode('预告'), isNull);
      final media = DanmakuMedia.from(
        const Drama(id: 'test:1', source: 'test', title: '合成作品', year: 2024),
        Episode({'id': 'a', 'title': '第2季第5集'}, 99),
      );
      expect(media.season, 2);
      expect(media.episode, 5);
    },
  );

  test(
    'downloads an episode once, caches windows and applies persisted offsets',
    () async {
      final calls = <String>[];
      final api = ExternalDanmakuApi(
        client: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.url.path, startsWith('/custom/token/api/v2/'));
          final value = request.url.path.endsWith('/search/anime')
              ? {
                  'animes': [
                    {
                      'animeId': 7,
                      'animeTitle': '合成作品第二季(2024)',
                      'type': 'tvseries',
                    },
                  ],
                }
              : request.url.path.endsWith('/bangumi/7')
              ? {
                  'bangumi': {
                    'animeId': 7,
                    'animeTitle': '合成作品第二季(2024)',
                    'episodes': [
                      {'episodeId': 701, 'episodeTitle': '第1集'},
                      {'episodeId': 705, 'episodeTitle': '第5集'},
                    ],
                  },
                }
              : {
                  'comments': [
                    {'p': '1,1,16777215,user', 'm': '第一条'},
                    {'p': '1,1,16777215,user', 'm': '第一条'},
                    {'p': '31,1,16777215,user', 'm': '第二条'},
                    {'p': 'NaN,1,0,user', 'm': '无效'},
                  ],
                  'videoDuration': 120,
                };
          return http.Response(
            jsonEncode(value),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final session = ExternalDanmakuSession(store, api: api)..setMedia(_media);
      addTearDown(session.dispose);
      final first = await session.page(0, 120000);
      final second = await session.page(30000, 120000);
      expect(first.items.single.text, '第一条');
      expect(second.items.single.text, '第二条');
      expect(calls.where((path) => path.contains('/comment/')), hasLength(1));
      await session.setOffset(-2000);
      final shifted = await session.page(0, 120000);
      expect(shifted.items.single.timeMs, 29000);
      expect(calls.where((path) => path.contains('/comment/')), hasLength(1));
      expect(
        store.danmakuBinding(
          '${session.settings.baseUrl}|${_media.key}',
        )['episodeId'],
        '705',
      );
    },
  );

  test(
    'ambiguous matches stay empty and negative searches are cached',
    () async {
      var calls = 0;
      final api = ExternalDanmakuApi(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'animes': [
                for (var id = 1; id <= 2; id++)
                  {
                    'animeId': id,
                    'animeTitle': '合成作品第二季(2024)',
                    'type': 'tvseries',
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final session = ExternalDanmakuSession(store, api: api)..setMedia(_media);
      addTearDown(session.dispose);
      expect((await session.page(0, 120000)).items, isEmpty);
      expect((await session.page(30000, 120000)).items, isEmpty);
      expect(session.status, contains('多个'));
      expect(calls, 1);
    },
  );

  test(
    'failed whole-episode request can retry and concurrent reads coalesce',
    () async {
      var requests = 0;
      final gate = Completer<http.Response>();
      final api = ExternalDanmakuApi(
        client: MockClient((_) async {
          requests++;
          if (requests == 1) return http.Response('unavailable', 503);
          return gate.future;
        }),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.track('https://synthetic.invalid', '1'),
        throwsFormatException,
      );
      final first = api.track('https://synthetic.invalid', '1');
      final second = api.track('https://synthetic.invalid', '1');
      gate.complete(http.Response('{"comments":[]}', 200));
      await Future.wait([first, second]);
      expect(requests, 2);
    },
  );
}
