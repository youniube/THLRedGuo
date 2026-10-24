import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';

List<Map<String, dynamic>> jsPlaybackChapters(String urls, String names) {
  final chapters = <String, Map<String, dynamic>>{};
  final groups = urls.split(r'$$$');
  final flags = names.split(r'$$$');
  for (var route = 0; route < groups.length; route++) {
    final occurrences = <String, int>{};
    final entries = groups[route].split('#');
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index].trim();
      if (entry.isEmpty) continue;
      final separator = entry.indexOf(r'$');
      final title = separator > 0
          ? entry.substring(0, separator).trim()
          : '第 ${index + 1} 集';
      final raw = (separator >= 0 ? entry.substring(separator + 1) : entry)
          .trim();
      if (raw.isEmpty) continue;
      final number = RegExp(
        r'^(?:第\s*)?(\d+)\s*(?:集|话|期|章)?$|^(?:ep|e)\s*(\d+)$',
        caseSensitive: false,
      ).firstMatch(title);
      final episode = int.tryParse(number?.group(1) ?? number?.group(2) ?? '');
      final baseKey = episode == null
          ? title.replaceAll(RegExp(r'\s+'), '').toLowerCase()
          : 'episode:$episode';
      final occurrence = occurrences.update(
        baseKey,
        (n) => n + 1,
        ifAbsent: () => 0,
      );
      final key = '$baseKey:$occurrence';
      final chapter = chapters.putIfAbsent(
        key,
        () => {
          'id': raw,
          'title': title,
          'index': chapters.length + 1,
          if (episode != null && episode > 0) 'currentEpisode': episode,
          'raw': raw,
          'routes': <Map<String, dynamic>>[],
        },
      );
      (chapter['routes'] as List).add({
        'flag': route < flags.length && flags[route].trim().isNotEmpty
            ? flags[route].trim()
            : 'flag',
        'raw': raw,
      });
    }
  }
  final result = chapters.values.toList();
  if (result.every((row) => row['currentEpisode'] is int)) {
    result.sort(
      (a, b) =>
          (a['currentEpisode'] as int).compareTo(b['currentEpisode'] as int),
    );
  }
  for (var index = 0; index < result.length; index++) {
    result[index]['index'] = index + 1;
  }
  return result;
}

class JsPlaybackResolver {
  JsPlaybackResolver(this.client);

  final http.Client client;

  Future<List<Map<String, dynamic>>> resolve(
    List<CatPawPlayResult> results, {
    int requestedQuality = 0,
    String avoidUrl = '',
    bool Function()? cancelled,
    Duration probeBudget = const Duration(seconds: 8),
  }) async {
    final clock = Stopwatch()..start();
    final budget = probeBudget < const Duration(seconds: 8)
        ? probeBudget
        : const Duration(seconds: 8);
    final candidates = <Map<String, dynamic>>[];
    final manifests = <String, Future<List<Map<String, dynamic>>>>{};
    final declared = <int>{};
    for (final result in results) {
      for (final stream in [result, ...result.streams]) {
        if (cancelled?.call() == true) {
          throw CatPawSourceFailure.playback('cancelled');
        }
        final uri = Uri.tryParse(stream.url);
        if (uri == null ||
            !{'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            stream.url == avoidUrl ||
            stream.parse != 0 ||
            (stream.expiresAt > 0 &&
                stream.expiresAt <= DateTime.now().millisecondsSinceEpoch)) {
          continue;
        }
        declared.addAll(result.qualities.where((q) => q > 0));
        final detected = RegExp(
          r'(?:^|[/_.-])(4320|2160|1440|1080|720|576|540|480|360|240)p(?=[/_.?&#-]|$)',
          caseSensitive: false,
        ).firstMatch(uri.toString());
        final quality = stream.quality > 0
            ? stream.quality
            : int.tryParse(detected?.group(1) ?? '') ?? 0;
        final plan = <String, dynamic>{
          'url': stream.url,
          'headers': stream.header,
          'decryptionKey': stream.decryptionKey,
          'mediaBytes': stream.mediaBytes,
          'expiresAt': stream.expiresAt,
          'quality': quality,
          'danmakuId': stream.danmakuId,
          'local': false,
          'mimeType': uri.path.toLowerCase().endsWith('.m3u8')
              ? 'application/x-mpegURL'
              : 'video/mp4',
        };
        candidates.add(plan);
        final manifestKey = jsonEncode([stream.url, stream.header]);
        if (uri.path.toLowerCase().endsWith('.m3u8') &&
            stream.decryptionKey.isEmpty &&
            (manifests.containsKey(manifestKey) || clock.elapsed < budget)) {
          final remaining = budget - clock.elapsed;
          final variants = await manifests.putIfAbsent(
            manifestKey,
            () => _hlsVariants(
              uri,
              stream.header,
              remaining < const Duration(seconds: 4)
                  ? remaining
                  : const Duration(seconds: 4),
            ),
          );
          if (variants.isNotEmpty) {
            plan['quality'] = 0;
            for (final variant in variants) {
              if (variant['url'] != avoidUrl) {
                candidates.add({...plan, ...variant});
              }
            }
          }
        }
      }
    }
    if (cancelled?.call() == true) {
      throw CatPawSourceFailure.playback('cancelled');
    }
    final unique = <String, Map<String, dynamic>>{};
    for (final plan in candidates) {
      final headers = (plan['headers'] as Map).entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      final key = jsonEncode([
        plan['url'],
        Map.fromEntries(headers),
        plan['decryptionKey'],
      ]);
      if (!unique.containsKey(key) ||
          (plan['quality'] as int) > (unique[key]!['quality'] as int)) {
        unique[key] = plan;
      }
    }
    final ordered = unique.values.toList();
    final positions = {for (var i = 0; i < ordered.length; i++) ordered[i]: i};
    int rank(int q) {
      if (requestedQuality <= 0) return q > 0 ? -q : 100000;
      if (q <= 0) return 100000;
      if (q <= requestedQuality) return requestedQuality - q;
      return 10000 + q;
    }

    ordered.sort((a, b) {
      final comparison = rank(
        a['quality'] as int,
      ).compareTo(rank(b['quality'] as int));
      return comparison != 0
          ? comparison
          : positions[a]!.compareTo(positions[b]!);
    });
    declared.addAll(
      ordered.map((row) => row['quality'] as int).where((q) => q > 0),
    );
    final qualities = declared.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final plan in ordered) {...plan, 'qualities': qualities},
    ];
  }

  Future<List<Map<String, dynamic>>> _hlsVariants(
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      var currentUri = uri;
      late http.StreamedResponse response;
      for (var redirect = 0; ; redirect++) {
        final request =
            http.AbortableRequest('GET', currentUri, abortTrigger: abort.future)
              ..headers.addAll(headers)
              ..followRedirects = false;
        response = await client.send(request).timeout(timeout);
        final location = response.headers['location'];
        if (response.statusCode < 300 ||
            response.statusCode >= 400 ||
            location == null) {
          break;
        }
        await response.stream.listen((_) {}).cancel();
        if (redirect >= 4) return [];
        currentUri = currentUri.resolve(location);
        if (!{'http', 'https'}.contains(currentUri.scheme) ||
            currentUri.host.isEmpty) {
          return [];
        }
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        if (bytes.length + chunk.length > 512 * 1024) return [];
        bytes.add(chunk);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) return [];
      final lines = utf8
          .decode(bytes.takeBytes(), allowMalformed: true)
          .split(RegExp(r'\r?\n'));
      if (!lines.any((line) => line.trim() == '#EXTM3U')) return [];
      final variants = <Map<String, dynamic>>[];
      String? attributes;
      for (final line in lines.map((line) => line.trim())) {
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          attributes = line;
        } else if (attributes != null &&
            line.isNotEmpty &&
            !line.startsWith('#')) {
          if (RegExp(
            r'\b(?:AUDIO|VIDEO)="',
            caseSensitive: false,
          ).hasMatch(attributes)) {
            attributes = null;
            continue;
          }
          final dimensions = RegExp(
            r'\bRESOLUTION=(\d+)x(\d+)',
            caseSensitive: false,
          ).firstMatch(attributes);
          final width = int.tryParse(dimensions?.group(1) ?? '') ?? 0;
          final height = int.tryParse(dimensions?.group(2) ?? '') ?? 0;
          final target = currentUri.resolve(line);
          if ({'http', 'https'}.contains(target.scheme) &&
              target.host.isNotEmpty) {
            variants.add({
              'url': target.toString(),
              'quality': width > 0 && height > 0
                  ? (width < height ? width : height)
                  : 0,
              'mimeType': 'application/x-mpegURL',
            });
          }
          attributes = null;
        }
      }
      return variants;
    } catch (_) {
      return [];
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }
}
