import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';

class ExternalDanmakuTrack {
  const ExternalDanmakuTrack(this.items, this.durationMs);
  final List<DanmakuItem> items;
  final int durationMs;
}

class ExternalDanmakuApi {
  ExternalDanmakuApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  final _tracks = <String, Future<ExternalDanmakuTrack>>{};
  final _loadedAt = <String, DateTime>{};
  final _details = <String, Future<List<DanmakuLibraryEpisode>>>{};
  final _detailTitles = <String, String>{};
  final _searches = <String, Future<List<DanmakuCandidate>>>{};
  final _searchTimes = <String, DateTime>{};

  Future<Uint8List> _read(
    String base,
    String path, [
    Map<String, String> query = const {},
  ]) async {
    if (base.isEmpty) throw const FormatException('请先设置通用弹幕 API 地址');
    final uri = Uri.parse(
      '$base/api/v2/$path',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'application/json';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('弹幕 API 请求失败（HTTP ${response.statusCode}）');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (bytes.length + chunk.length > 12 * 1024 * 1024) {
        throw const FormatException('弹幕 API 响应超过限制');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<Map<String, dynamic>> _get(
    String base,
    String path, [
    Map<String, String> query = const {},
  ]) async => _decodeExternalResponse(await _read(base, path, query));

  Future<List<DanmakuCandidate>> search(String base, String keyword) async {
    final key = '$base|$keyword';
    if (_searchTimes[key] != null &&
        DateTime.now().difference(_searchTimes[key]!) >
            const Duration(minutes: 2)) {
      _searches.remove(key);
      _searchTimes.remove(key);
    }
    if (_searches.length >= 20 && !_searches.containsKey(key)) {
      final oldest = _searches.keys.first;
      _searches.remove(oldest);
      _searchTimes.remove(oldest);
    }
    return _searches.putIfAbsent(key, () async {
      try {
        final rows = await _search(base, keyword);
        _searchTimes[key] = DateTime.now();
        return rows;
      } catch (_) {
        _searches.remove(key);
        rethrow;
      }
    });
  }

  Future<List<DanmakuCandidate>> _search(String base, String keyword) async {
    final result = await _get(base, 'search/anime', {'keyword': keyword});
    final rows = result['animes'];
    if (rows is! List) throw const FormatException('弹幕搜索结果格式无效');
    return rows
        .whereType<Map>()
        .take(100)
        .map((row) => DanmakuCandidate.fromJson(Map<String, dynamic>.from(row)))
        .where((row) => row.id.isNotEmpty && row.title.isNotEmpty)
        .toList();
  }

  Future<List<DanmakuLibraryEpisode>> episodes(
    String base,
    String id, {
    String? expectedTitle,
  }) async {
    final key = '$base|$id';
    if (_details.length >= 20 && !_details.containsKey(key)) {
      final oldest = _details.keys.first;
      _details.remove(oldest);
      _detailTitles.remove(oldest);
    }
    final rows = await _details.putIfAbsent(key, () async {
      try {
        final data = await _get(base, 'bangumi/${Uri.encodeComponent(id)}');
        final bangumi = data['bangumi'];
        if (bangumi is! Map ||
            bangumi['animeId']?.toString() != id ||
            bangumi['animeTitle'] is! String ||
            bangumi['episodes'] is! List) {
          throw const FormatException('弹幕剧集信息不匹配');
        }
        _detailTitles[key] = bangumi['animeTitle'] as String;
        return (bangumi['episodes'] as List)
            .whereType<Map>()
            .take(10000)
            .map(
              (row) => DanmakuLibraryEpisode(
                row['episodeId']?.toString() ?? '',
                row['episodeTitle']?.toString() ?? '',
              ),
            )
            .where((row) => row.id.isNotEmpty)
            .toList();
      } catch (_) {
        _details.remove(key);
        rethrow;
      }
    });
    if (expectedTitle != null && _detailTitles[key] != expectedTitle) {
      _details.remove(key);
      _detailTitles.remove(key);
      throw const FormatException('弹幕库作品标识已变化，请重新匹配');
    }
    return rows;
  }

  Future<ExternalDanmakuTrack> track(
    String base,
    String id, {
    String identity = '',
  }) {
    final key = '$base|$id|$identity';
    if (_loadedAt[key] != null &&
        DateTime.now().difference(_loadedAt[key]!) > const Duration(hours: 2)) {
      _tracks.remove(key);
      _loadedAt.remove(key);
    }
    if (_tracks.length >= 3 && !_tracks.containsKey(key)) {
      final oldest = _tracks.keys.first;
      _tracks.remove(oldest);
      _loadedAt.remove(oldest);
    }
    return _tracks.putIfAbsent(key, () async {
      try {
        final raw = await _read(base, 'comment/${Uri.encodeComponent(id)}', {
          'format': 'json',
          'duration': 'true',
        });
        final track = await compute(_parseExternalTrack, <String, Object>{
          'id': id,
          'bytes': raw,
        });
        _loadedAt[key] = DateTime.now();
        return track;
      } catch (_) {
        _tracks.remove(key);
        _loadedAt.remove(key);
        rethrow;
      }
    });
  }

  void dispose() {
    _client.close();
    _tracks.clear();
    _details.clear();
    _detailTitles.clear();
    _loadedAt.clear();
    _searches.clear();
    _searchTimes.clear();
  }

  void clearMatchingCache() {
    _details.clear();
    _detailTitles.clear();
    _searches.clear();
    _searchTimes.clear();
  }
}

Map<String, dynamic> _decodeExternalResponse(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic> ||
      decoded['success'] == false ||
      decoded['errorCode'] is num && decoded['errorCode'] != 0) {
    throw const FormatException('弹幕 API 没有返回有效数据');
  }
  return decoded;
}

ExternalDanmakuTrack _parseExternalTrack(Map<String, Object> payload) {
  final id = payload['id'] as String;
  final data = _decodeExternalResponse(payload['bytes'] as Uint8List);
  final rows = data['comments'];
  if (rows is! List || rows.length > 200000) {
    throw const FormatException('弹幕列表格式无效或数量超过限制');
  }
  final items = <DanmakuItem>[], seen = <String>{};
  for (final row in rows.whereType<Map>()) {
    final parts = (row['p']?.toString() ?? '').split(',');
    final seconds = double.tryParse(parts.first);
    final content = row['m'];
    if (seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        seconds > 86400 ||
        content is! String ||
        parts.length > 1 && !{'1', '4', '5'}.contains(parts[1])) {
      continue;
    }
    final cleaned = content
        .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
        .trim();
    if (cleaned.isEmpty) continue;
    final time = (seconds * 1000).round();
    final color = parts.length > 2 ? parseDanmakuColor(parts[2]) : 0xffffff;
    final mode = parts.length > 1
        ? parseDanmakuMode(parts[1])
        : DanmakuMode.scroll;
    final identity = sha256
        .convert(utf8.encode('$id:$time:${mode.name}:$color:$cleaned'))
        .toString();
    if (seen.add(identity)) {
      items.add(
        DanmakuItem(
          id: 'external:$identity',
          text: String.fromCharCodes(cleaned.runes.take(181)),
          timeMs: time,
          color: color,
          mode: mode,
        ),
      );
    }
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final seconds = data['videoDuration'];
  final duration =
      seconds is num && seconds.isFinite && seconds > 0 && seconds <= 86400
      ? (seconds * 1000).round()
      : 0;
  return ExternalDanmakuTrack(List.unmodifiable(items), duration);
}
