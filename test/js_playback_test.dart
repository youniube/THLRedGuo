import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:THLRedLook/core/engine/dart_core_engine.dart';
import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';
import 'package:THLRedLook/core/player/js_playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('多线路按集号对齐，缺集时不会播放其他集', () {
    final chapters = jsPlaybackChapters(
      r'第1集$one/1#第2集$one/2#第3集$one/3$$$1$two/1#3$two/3',
      r'普通线路$$$高清线路',
    );
    expect(chapters, hasLength(3));
    expect(chapters[0]['routes'], [
      {'flag': '普通线路', 'raw': 'one/1'},
      {'flag': '高清线路', 'raw': 'two/1'},
    ]);
    expect(chapters[1]['routes'], hasLength(1));
    expect(chapters[2]['routes'][1]['raw'], 'two/3');
  });

  test('单线路及包含美元符号的播放编号保持兼容', () {
    final chapters = jsPlaybackChapters(r'正片$opaque/value$token', '');
    expect(chapters.single['raw'], r'opaque/value$token');
    expect(chapters.single['routes'].single['flag'], 'flag');
    expect(jsPlaybackChapters('', ''), isEmpty);
  });

  test('同名的重复条目按出现顺序保留，不合并为一集', () {
    final chapters = jsPlaybackChapters(
      r'播放$one/1#播放$one/2$$$播放$two/1#播放$two/2',
      r'A$$$B',
    );
    expect(chapters, hasLength(2));
    expect(chapters[1]['routes'][1]['raw'], 'two/2');
  });

  final client = MockClient((_) async => http.Response('', 404));
  final resolver = JsPlaybackResolver(client);
  const streams = [
    CatPawPlayResult(url: 'https://media.invalid/unknown.mp4', header: {}),
    CatPawPlayResult(
      url: 'https://media.invalid/720.mp4',
      header: {},
      quality: 720,
    ),
    CatPawPlayResult(
      url: 'https://media.invalid/2160.mp4',
      header: {},
      quality: 2160,
    ),
    CatPawPlayResult(
      url: 'https://media.invalid/1080.mp4',
      header: {},
      quality: 1080,
    ),
  ];

  test('自动模式跨线路优先选择最高已知画质', () async {
    final plans = await resolver.resolve(streams);
    expect(plans.map((row) => row['quality']), [2160, 1080, 720, 0]);
    expect(plans.first['qualities'], [2160, 1080, 720]);
  });

  test('手选清晰度精确匹配，缺少该档时优先较低档位', () async {
    final exact = await resolver.resolve(streams, requestedQuality: 720);
    expect(exact.first['quality'], 720);
    final lower = await resolver.resolve(streams, requestedQuality: 1440);
    expect(lower.first['quality'], 1080);
    final higher = await resolver.resolve(streams, requestedQuality: 360);
    expect(higher.first['quality'], 720);
  });

  test('过滤已失败地址、过期资源、网页解析地址和无效协议', () async {
    final plans = await resolver.resolve([
      ...streams,
      const CatPawPlayResult(
        url: 'https://media.invalid/expired.mp4',
        header: {},
        quality: 4320,
        expiresAt: 1,
      ),
      const CatPawPlayResult(
        url: 'https://media.invalid/web.html',
        header: {},
        parse: 1,
      ),
      const CatPawPlayResult(url: 'javascript:alert(1)', header: {}),
    ], avoidUrl: 'https://media.invalid/2160.mp4');
    expect(plans.map((row) => row['quality']), [1080, 720, 0]);
  });

  test('解析 HLS 主列表，保留请求头并按竖屏短边选择', () async {
    final hlsClient = MockClient((request) async {
      expect(request.headers['Referer'], 'https://site.invalid/');
      return http.Response('''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=720x1280
720/index.m3u8?token=test
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1080x1920
../1080/index.m3u8
''', 200);
    });
    final plans = await JsPlaybackResolver(hlsClient).resolve([
      const CatPawPlayResult(
        url: 'https://media.invalid/hls/master.m3u8',
        header: {'Referer': 'https://site.invalid/'},
      ),
    ], requestedQuality: 720);
    expect(
      plans.first['url'],
      'https://media.invalid/hls/720/index.m3u8?token=test',
    );
    expect(plans.first['quality'], 720);
    expect(plans.first['headers']['Referer'], 'https://site.invalid/');
    expect(plans.first['qualities'], [1080, 720]);
  });

  test('带独立音轨的 HLS 保留主列表，避免切子列表后丢声音', () async {
    final hlsClient = MockClient(
      (_) async => http.Response('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="audio"
video.m3u8
''', 200),
    );
    final plans = await JsPlaybackResolver(hlsClient).resolve([
      const CatPawPlayResult(
        url: 'https://media.invalid/master.m3u8',
        header: {},
      ),
    ]);
    expect(plans.single['url'], 'https://media.invalid/master.m3u8');
  });

  test('HLS 重定向后使用最终主列表地址解析相对路径', () async {
    final hlsClient = MockClient((request) async {
      if (request.url.host == 'media.invalid') {
        return http.Response(
          '',
          302,
          headers: {'location': 'https://cdn.invalid/hls/master.m3u8'},
        );
      }
      return http.Response(
        '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1920x1080\nvideo/index.m3u8',
        200,
      );
    });
    final plans = await JsPlaybackResolver(hlsClient).resolve([
      const CatPawPlayResult(
        url: 'https://media.invalid/master.m3u8',
        header: {},
      ),
    ]);
    expect(plans.first['url'], 'https://cdn.invalid/hls/video/index.m3u8');
  });

  test('根地址同时出现在 streams 时不重复探测 HLS', () async {
    var requests = 0;
    final hlsClient = MockClient((_) async {
      requests++;
      return http.Response(
        '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\n720.m3u8',
        200,
      );
    });
    final plans = await JsPlaybackResolver(hlsClient).resolve([
      const CatPawPlayResult(
        url: 'https://media.invalid/master.m3u8',
        header: {},
        streams: [
          CatPawPlayResult(
            url: 'https://media.invalid/master.m3u8',
            header: {},
          ),
        ],
      ),
    ]);
    expect(requests, 1);
    expect(plans, hasLength(2));
  });

  test('HLS 网络失败保留原地址，取消后不能交付新方案', () async {
    final failed = await resolver.resolve([
      const CatPawPlayResult(
        url: 'https://media.invalid/master.m3u8',
        header: {},
      ),
    ]);
    expect(failed.single['url'], 'https://media.invalid/master.m3u8');
    await expectLater(
      resolver.resolve(streams, cancelled: () => true),
      throwsA(
        isA<CatPawSourceFailure>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
  });

  test('多条 HLS 只探测当前首选，备用线路不占用启动时间', () async {
    final requests = <Uri>[];
    final hlsClient = MockClient((request) async {
      requests.add(request.url);
      return http.Response('#EXTM3U\n#EXTINF:10\nsegment.ts', 200);
    });
    final plans = await JsPlaybackResolver(hlsClient).resolve([
      for (var index = 0; index < 25; index++)
        CatPawPlayResult(
          url: 'https://media.invalid/$index.m3u8',
          header: const {},
          routeKey: 'route-$index',
        ),
    ]);
    expect(requests.map((uri) => uri.path), ['/0.m3u8']);
    expect(plans, hasLength(25));
    expect(plans.first['url'], 'https://media.invalid/0.m3u8');
  });

  test('优先线路的 HLS 清晰度先解析，自动线路不抢占探测预算', () async {
    final requests = <Uri>[];
    final hlsClient = MockClient((request) async {
      requests.add(request.url);
      return http.Response(
        '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\n720.m3u8',
        200,
      );
    });
    final plans = await JsPlaybackResolver(hlsClient).resolve(
      const [
        CatPawPlayResult(
          url: 'https://media.invalid/auto.m3u8',
          header: {},
          routeKey: 'auto',
        ),
        CatPawPlayResult(
          url: 'https://preferred.invalid/master.m3u8',
          header: {},
          routeKey: 'preferred',
        ),
      ],
      preferredRoute: 'id:preferred',
      requestedQuality: 720,
    );
    expect(requests.single.host, 'preferred.invalid');
    final session = JsPlaybackSession(
      'preferred-session',
      plans,
      preferredRoute: 'id:preferred',
    );
    expect(session.current['url'], 'https://preferred.invalid/720.m3u8');
    expect(session.current['quality'], 720);
    expect(plans, hasLength(3));
  });

  test('HLS 探测超时立即保留原流，不继续等待其他线路', () async {
    var requests = 0;
    final hlsClient = MockClient((_) {
      requests++;
      return Completer<http.Response>().future;
    });
    final plans = await JsPlaybackResolver(hlsClient).resolve(const [
      CatPawPlayResult(url: 'https://media.invalid/first.m3u8', header: {}),
      CatPawPlayResult(url: 'https://media.invalid/backup.m3u8', header: {}),
    ], probeBudget: const Duration(milliseconds: 20));
    expect(requests, 1);
    expect(plans, hasLength(2));
    expect(plans.first['url'], 'https://media.invalid/first.m3u8');
  });

  test('主列表重复出现时都使用实际子列表画质', () async {
    final hlsClient = MockClient(
      (_) async => http.Response(
        '#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1280x720\n720.m3u8',
        200,
      ),
    );
    final plans = await JsPlaybackResolver(hlsClient).resolve(const [
      CatPawPlayResult(
        url: 'https://media.invalid/master.m3u8',
        header: {'Referer': 'https://site.invalid/', 'X-Route': 'same'},
        quality: 1080,
        streams: [
          CatPawPlayResult(
            url: 'https://media.invalid/master.m3u8',
            header: {'X-Route': 'same', 'Referer': 'https://site.invalid/'},
            quality: 1080,
          ),
        ],
      ),
    ]);
    expect(plans, hasLength(2));
    expect(plans.first['quality'], 720);
    expect(plans.last['quality'], 0);
  });

  test('JS streams 正确保留每档元数据和公共请求头', () async {
    final runtime = CatPawJsRuntime(client);
    addTearDown(runtime.dispose);
    await runtime.init('''var spider = {
      play: function() { return {
        url: "https://media.invalid/main.mp4", quality: 1080, mediaBytes: 4096,
        header: { Referer: "https://site.invalid/" },
        streams: [
          { url: "https://media.invalid/720.mp4", quality: 720, header: { "X-Route": "B" } },
          { url: "https://media.invalid/unknown.mp4" },
          { quality: 4320 }
        ]
      }; }
    };''');
    final result = await runtime.play('flag', 'episode/1');
    expect(result.streams, hasLength(2));
    expect(result.streams[0].quality, 720);
    expect(result.streams[0].header, {
      'Referer': 'https://site.invalid/',
      'X-Route': 'B',
    });
    expect(result.streams[1].quality, 0);
    expect(result.streams[1].mediaBytes, 0);
  });

  test('核心贯通多线路、画质传参、自动择优、手动切换和备用流释放', () async {
    final engine = DartCoreEngine.instance;
    final installed = await engine.dispatch({
      'action': 'jsSource.load',
      'fileName': 'synthetic_quality.js',
      'script': r'''
var meta = { id: "synthetic_quality", name: "合成画质契约", version: "1.0.0" };
var spider = {
  detail: function() { return { list: [{
    vod_id: "work", vod_name: "合成测试",
    vod_play_from: "broken$$$low$$$high",
    vod_play_url: "第1集$broken/1$$$第1集$low/1$$$第1集$high/1"
  }] }; },
  play: function(flag, id, flags) {
    if (flag === "broken") throw new Error("合成线路故障");
    var q = flags[0].quality;
    return { url: "https://media.invalid/" + flag + ".mp4",
      quality: flag === "high" ? 1080 : 720,
      header: { "X-Flag": flag, "X-Requested-Quality": String(q) } };
  }
};''',
    });
    expect(installed['ok'], isTrue);
    final drama = {
      'id': 'synthetic_quality:work',
      'source': 'synthetic_quality',
      'sourceId': 'work',
    };
    final detail = await engine.dispatch({'action': 'detail', 'drama': drama});
    expect(detail['ok'], isTrue);
    final chapter = detail['data']['chapters'][0];
    final auto = await engine.dispatch({
      'action': 'resolve',
      'drama': drama,
      'chapter': chapter,
      'quality': 0,
    });
    expect(auto['ok'], isTrue);
    expect(auto['data']['quality'], 1080);
    expect(auto['data']['routeCount'], 2);
    expect(auto['data']['headers']['X-Flag'], 'high');
    final session = auto['data']['session'];
    final fallback = await engine.dispatch({
      'action': 'fallback',
      'session': session,
    });
    expect(fallback['ok'], isTrue);
    expect(fallback['data']['quality'], 720);
    await engine.dispatch({'action': 'release', 'session': session});
    expect(
      (await engine.dispatch({'action': 'fallback', 'session': session}))['ok'],
      isFalse,
    );
    final manual = await engine.dispatch({
      'action': 'resolve',
      'drama': drama,
      'chapter': chapter,
      'quality': 720,
    });
    expect(manual['ok'], isTrue);
    expect(manual['data']['quality'], 720);
    expect(manual['data']['headers']['X-Requested-Quality'], '720');
    await engine.dispatch({
      'action': 'release',
      'session': manual['data']['session'],
    });
    await engine.dispatch({
      'action': 'jsSource.remove',
      'source': 'synthetic_quality',
    });
  });
}
