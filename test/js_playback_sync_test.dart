import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:THLRedLook/core/engine/dart_core_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DartCoreEngine engine;
  final previousOverrides = HttpOverrides.current;

  setUpAll(() {
    HttpOverrides.global = null;
    engine = DartCoreEngine.instance;
  });
  tearDownAll(() {
    HttpOverrides.global = previousOverrides;
  });

  Future<void> install(String source, String methods) async {
    final result = await engine.dispatch({
      'action': 'jsSource.load',
      'fileName': '$source.js',
      'script':
          'var meta = {id: "$source", name: "合成同步契约", version: "1.0.0"}; var spider = {$methods};',
    });
    expect(result['ok'], isTrue, reason: result.toString());
    addTearDown(() async {
      await engine.dispatch({'action': 'jsSource.remove', 'source': source});
    });
  }

  Map<String, dynamic> drama(String source) => {
    'id': '$source:work',
    'source': source,
    'sourceId': 'work',
  };

  for (final throwsMissing in [false, true]) {
    final source = 'sync_missing_${throwsMissing ? 'throw' : 'empty'}';
    final methods =
        r'''
detail: function() { return {list: [{
  vod_play_from: "low$$$high",
  vod_play_url: "第1集$low/1#第3集$low/3$$$第1集$high/1#第3集$high/3"
}]}; },
play: function(flag, id, flags) {
  if (id.indexOf('/3') < 0 || (flag !== 'low' && flag !== 'high')) {
    MISSING_RESULT
  }
  var header = {"X-Requested": String(flags[0].quality), "X-Avoid": flags[0].avoidUrl || "", "X-Episode": id};
  if (flag === 'low') return {url: "https://media.invalid/low.mp4", quality: 720, header: header};
  return {header: header, streams: [
    {url: "https://media.invalid/high.mp4", quality: 1080}
  ]};
}
'''
            .replaceFirst(
              'MISSING_RESULT',
              throwsMissing
                  ? 'throw Object.assign(new Error("合成缺集"), {code: "MISSING_EPISODE"});'
                  : 'return {url: "", error: "MISSING_EPISODE"};',
            );

    test('刷新缺失分集后仍保留多线路、streams、画质和刷新参数：$source', () async {
      await install(source, methods);
      for (final quality in [0, 720]) {
        final result = await engine.dispatch({
          'action': 'resolve',
          'drama': drama(source),
          'chapter': {'raw': 'stale/3'},
          'index': 3,
          'quality': quality,
          'avoidUrl': 'https://media.invalid/expired.mp4',
        });
        expect(result['ok'], isTrue, reason: result.toString());
        final data = result['data'] as Map;
        expect(data['quality'], quality == 0 ? 1080 : 720);
        expect(data['qualities'], [1080, 720]);
        expect(data['headers']['X-Requested'], '$quality');
        expect(data['headers']['X-Avoid'], 'https://media.invalid/expired.mp4');
        expect(data['headers']['X-Episode'], endsWith('/3'));
        final fallback = await engine.dispatch({
          'action': 'fallback',
          'session': data['session'],
        });
        expect(fallback['ok'], isTrue);
        expect(fallback['data']['quality'], quality == 0 ? 720 : 1080);
        await engine.dispatch({
          'action': 'release',
          'session': data['session'],
        });
      }
    });

    test('刷新后的缺集列表不能按位置串到其他集：$source', () async {
      await install(source, methods);
      final result = await engine.dispatch({
        'action': 'resolve',
        'drama': drama(source),
        'chapter': {'raw': 'stale/2'},
        'index': 2,
      });
      expect(result['ok'], isFalse);
      expect(result['code'], 'MISSING_EPISODE');
    });
  }

  Future<({String url, Future<void> started, void Function() finish})>
  heldManifest() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    final ready = Completer<void>();
    server.listen((request) async {
      if (!started.isCompleted) started.complete();
      await ready.future;
      request.response
        ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
        ..write(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=1280x720\n720.m3u8\n',
        );
      await request.response.close();
    });
    void finish() {
      if (!ready.isCompleted) ready.complete();
    }

    addTearDown(() async {
      finish();
      await server.close(force: true);
    });
    return (
      url: 'http://127.0.0.1:${server.port}/master.m3u8',
      started: started.future.timeout(const Duration(seconds: 3)),
      finish: finish,
    );
  }

  test('取消播放不取消正在探测 HLS 的预加载', () async {
    final manifest = await heldManifest();
    const source = 'sync_preload_isolation';
    await install(
      source,
      'play: function() { return {url: "${manifest.url}"}; }',
    );
    final pending = engine.dispatch({
      'action': 'preload',
      'session': 'sync-preload',
      'sequence': 1,
      'drama': drama(source),
      'chapter': {'raw': 'episode/1'},
    });
    await manifest.started;
    await engine.dispatch({'action': 'cancelPlayback'});
    manifest.finish();
    final result = await pending;
    expect(result['ok'], isTrue, reason: result.toString());
    expect(result['data']['quality'], 720);
    await engine.dispatch({
      'action': 'release',
      'session': result['data']['session'],
    });
  });

  test('预加载 JS 已结束时 cancelRead 仍取消 HLS 探测结果', () async {
    final manifest = await heldManifest();
    const source = 'sync_cancel_preload';
    await install(
      source,
      'play: function() { return {url: "${manifest.url}"}; }',
    );
    final pending = engine.dispatch({
      'action': 'preload',
      'session': 'sync-cancel-preload',
      'sequence': 2,
      'drama': drama(source),
      'chapter': {'raw': 'episode/1'},
    });
    await manifest.started;
    await engine.dispatch({
      'action': 'cancelRead',
      'session': 'sync-cancel-preload',
      'sequence': 2,
    });
    manifest.finish();
    final result = await pending;
    expect(result['ok'], isFalse);
    expect(result['code'], 'cancelled');
  });

  test('换集后不接受上一集迟到的 HLS 结果', () async {
    final manifest = await heldManifest();
    const source = 'sync_replace_playback';
    await install(source, '''play: function(flag, id) {
      return {url: id === 'episode/1' ? "${manifest.url}" : "https://media.invalid/new.mp4"};
    }''');
    final pending = engine.dispatch({
      'action': 'resolve',
      'drama': drama(source),
      'chapter': {'raw': 'episode/1'},
    });
    await manifest.started;
    final current = await engine.dispatch({
      'action': 'resolve',
      'drama': drama(source),
      'chapter': {'raw': 'episode/2'},
    });
    expect(current['ok'], isTrue, reason: current.toString());
    manifest.finish();
    final previous = await pending;
    expect(previous['ok'], isFalse);
    expect(previous['code'], 'cancelled');
    await engine.dispatch({
      'action': 'release',
      'session': current['data']['session'],
    });
  });
}
