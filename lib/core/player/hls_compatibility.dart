import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class HlsCompatibilityProbe {
  HttpClient? _client;

  void cancel() {
    _client?.close(force: true);
    _client = null;
  }

  Future<bool> requiresMpv(
    Uri uri,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    cancel();
    final client = HttpClient()..connectionTimeout = timeout;
    _client = client;
    final timer = Timer(timeout, () => client.close(force: true));
    try {
      var current = uri;
      for (var depth = 0; depth < 3; depth++) {
        final response = await _read(client, current, headers, 64 * 1024);
        if (response == null) return false;
        final text = utf8.decode(response.bytes, allowMalformed: true);
        if (!text.trimLeft().startsWith('#EXTM3U')) return false;
        final lines = text.split(RegExp(r'\r?\n')).map((line) => line.trim());
        if (lines.any((line) => line.startsWith('#EXT-X-MAP:')) ||
            lines.any(
              (line) =>
                  line.startsWith('#EXT-X-KEY:') &&
                  !line.contains('METHOD=NONE'),
            )) {
          return false;
        }
        final target = lines.firstWhere(
          (line) => line.isNotEmpty && !line.startsWith('#'),
          orElse: () => '',
        );
        if (target.isEmpty) return false;
        final next = response.uri.resolve(target);
        if (!{'http', 'https'}.contains(next.scheme)) return false;
        if (lines.any((line) => line.startsWith('#EXT-X-STREAM-INF:'))) {
          current = next;
          continue;
        }
        final segment = await _read(client, next, headers, 64 * 1024);
        return segment != null && transportStreamHasHevc(segment.bytes);
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      timer.cancel();
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<({Uri uri, Uint8List bytes})?> _read(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    int limit,
  ) async {
    var current = uri;
    for (var redirect = 0; redirect <= 4; redirect++) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${limit - 1}');
      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (response.isRedirect && location != null) {
        await response.listen((_) {}).cancel();
        current = current.resolve(location);
        if (!{'http', 'https'}.contains(current.scheme)) return null;
        continue;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.listen((_) {}).cancel();
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        final remaining = limit - bytes.length;
        bytes.add(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
        if (bytes.length >= limit) break;
      }
      return (uri: current, bytes: bytes.takeBytes());
    }
    return null;
  }
}

bool transportStreamHasHevc(List<int> bytes) {
  final sections = <int, List<int>>{};
  final continuity = <int, int>{};
  for (var start = 0; start + 188 <= bytes.length; start += 188) {
    if (bytes[start] != 0x47) return false;
    if ((bytes[start + 1] & 0x80) != 0 || (bytes[start + 3] & 0xc0) != 0) {
      continue;
    }
    final pid = ((bytes[start + 1] & 0x1f) << 8) | bytes[start + 2];
    final control = (bytes[start + 3] >> 4) & 3;
    if (control == 0 || control == 2) continue;
    var offset = start + 4;
    if (control == 3) offset += 1 + bytes[offset];
    final end = start + 188;
    if (offset >= end) continue;
    final counter = bytes[start + 3] & 0x0f;
    if (continuity.containsKey(pid) &&
        counter != ((continuity[pid]! + 1) & 0x0f)) {
      sections.remove(pid);
    }
    continuity[pid] = counter;
    if ((bytes[start + 1] & 0x40) != 0) {
      offset += 1 + bytes[offset];
      sections.remove(pid);
      if (offset >= end || bytes[offset] != 0x02) continue;
      sections[pid] = [];
    }
    final section = sections[pid];
    if (section == null) continue;
    section.addAll(bytes.sublist(offset, end));
    if (section.length < 12) continue;
    final length = 3 + (((section[1] & 0x0f) << 8) | section[2]);
    if (length < 16 || length > 1024) {
      sections.remove(pid);
      continue;
    }
    if (section.length < length) continue;
    sections.remove(pid);
    if ((section[1] & 0x80) == 0 || (section[5] & 1) == 0) continue;
    var entry = 12 + (((section[10] & 0x0f) << 8) | section[11]);
    while (entry + 5 <= length - 4) {
      if (section[entry] == 0x24) return true;
      entry += 5 + (((section[entry + 3] & 0x0f) << 8) | section[entry + 4]);
    }
  }
  return false;
}
