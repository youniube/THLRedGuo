import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:THLRedLook/core/player/hls_compatibility.dart';

Uint8List transportStream(int codec, {int descriptors = 0}) {
  final body = <int>[
    0,
    1,
    0xc1,
    0,
    0,
    0xe1,
    0,
    0xf0 | (descriptors >> 8),
    descriptors & 0xff,
    ...List.filled(descriptors, 0),
    codec,
    0xe1,
    0,
    0xf0,
    0,
    0x0f,
    0xe1,
    1,
    0xf0,
    0,
    0,
    0,
    0,
    0,
  ];
  final section = [
    0x02,
    0xb0 | (body.length >> 8),
    body.length & 0xff,
    ...body,
  ];
  final output = BytesBuilder();
  var offset = 0;
  var counter = 0;
  while (offset < section.length) {
    final packet = Uint8List(188)..fillRange(0, 188, 0xff);
    packet.setRange(0, 4, [
      0x47,
      offset == 0 ? 0x41 : 0x01,
      0x00,
      0x10 | counter,
    ]);
    var payload = 4;
    if (offset == 0) packet[payload++] = 0;
    final count = (188 - payload).clamp(0, section.length - offset);
    packet.setRange(payload, payload + count, section, offset);
    output.add(packet);
    offset += count;
    counter++;
  }
  return output.takeBytes();
}

void main() {
  final previousOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = previousOverrides);

  test('HEVC TS 切换兼容内核，H.264 和纯音频保留系统内核', () {
    expect(transportStreamHasHevc(transportStream(0x24)), isTrue);
    expect(transportStreamHasHevc(transportStream(0x1b)), isFalse);
    expect(transportStreamHasHevc(transportStream(0x0f)), isFalse);
  });

  test('跨 TS 包的 PMT 仍能识别 HEVC，丢包时不误判', () {
    final bytes = transportStream(0x24, descriptors: 200);
    expect(transportStreamHasHevc(bytes), isTrue);
    bytes[188 + 3] = 0x12;
    expect(transportStreamHasHevc(bytes), isFalse);
  });

  test('截断、损坏和非 TS 数据不会触发切换', () {
    final bytes = transportStream(0x24);
    expect(transportStreamHasHevc(bytes.sublist(0, 100)), isFalse);
    expect(transportStreamHasHevc('<html>error</html>'.codeUnits), isFalse);
    bytes[0] = 0;
    expect(transportStreamHasHevc(bytes), isFalse);
  });

  Future<Uri> serve(Future<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await handler(request);
      await request.response.close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}/');
  }

  test('读取播放清单和首个分片，保留请求头并限制探测字节', () async {
    final paths = <String>[];
    final base = await serve((request) async {
      paths.add(request.uri.path);
      expect(request.headers.value('Referer'), 'https://synthetic.invalid/');
      expect(request.headers.value('Range'), 'bytes=0-65535');
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write('#EXTM3U\n#EXTINF:5,\nmedia/first.ts\n');
      } else {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.add(transportStream(0x24));
      }
    });
    final probe = HlsCompatibilityProbe();
    addTearDown(probe.cancel);
    expect(
      await probe.requiresMpv(base.resolve('index.m3u8'), {
        'Referer': 'https://synthetic.invalid/',
      }),
      isTrue,
    );
    expect(paths, ['/index.m3u8', '/media/first.ts']);
  });

  test('重定向和主列表按最终地址解析相对分片', () async {
    final paths = <String>[];
    final base = await serve((request) async {
      paths.add(request.uri.path);
      switch (request.uri.path) {
        case '/entry.m3u8':
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set('Location', '/cdn/master.m3u8');
        case '/cdn/master.m3u8':
          request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=700000\n576/video.m3u8\n',
          );
        case '/cdn/576/video.m3u8':
          request.response.write('#EXTM3U\n#EXTINF:5,\nfirst.ts\n');
        default:
          request.response.add(transportStream(0x24));
      }
    });
    final probe = HlsCompatibilityProbe();
    addTearDown(probe.cancel);
    expect(await probe.requiresMpv(base.resolve('entry.m3u8'), {}), isTrue);
    expect(paths.last, '/cdn/576/first.ts');
  });

  for (final entry in {
    'fMP4': '#EXT-X-MAP:URI="init.mp4"',
    'AES': '#EXT-X-KEY:METHOD=AES-128,URI="key"',
  }.entries) {
    test('${entry.key} 清单保留系统内核，不请求加密数据或初始化片段', () async {
      var requests = 0;
      final base = await serve((request) async {
        requests++;
        request.response.write(
          '#EXTM3U\n${entry.value}\n#EXTINF:5,\nfirst.ts\n',
        );
      });
      final probe = HlsCompatibilityProbe();
      addTearDown(probe.cancel);
      expect(await probe.requiresMpv(base.resolve('video.m3u8'), {}), isFalse);
      expect(requests, 1);
    });
  }

  test('网络失败保留系统播放，超时和取消不会继续阻塞切集', () async {
    final started = Completer<void>();
    final base = await serve((request) async {
      if (request.uri.path == '/failed.m3u8') {
        request.response.statusCode = HttpStatus.forbidden;
      } else {
        if (request.uri.path == '/cancel.m3u8' && !started.isCompleted) {
          started.complete();
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    });
    final probe = HlsCompatibilityProbe();
    addTearDown(probe.cancel);
    expect(await probe.requiresMpv(base.resolve('failed.m3u8'), {}), isFalse);
    expect(
      await probe.requiresMpv(
        base.resolve('timeout.m3u8'),
        {},
        timeout: const Duration(milliseconds: 30),
      ),
      isFalse,
    );
    final pending = probe.requiresMpv(base.resolve('cancel.m3u8'), {});
    await started.future;
    probe.cancel();
    expect(await pending.timeout(const Duration(seconds: 1)), isFalse);
  });
}
