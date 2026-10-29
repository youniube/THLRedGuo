import 'package:flutter/foundation.dart';

import 'package:THLRedLook/core/danmaku/external_danmaku_api.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';

class ExternalDanmakuSession extends ChangeNotifier {
  ExternalDanmakuSession(this.store, {ExternalDanmakuApi? api})
    : api = api ?? ExternalDanmakuApi();
  final LocalStore store;
  final ExternalDanmakuApi api;
  DanmakuMedia? media;
  String status = '';
  bool _disposed = false;
  ExternalDanmakuSettings get settings => store.externalDanmakuSettings;
  String get identity => 'external:${media?.key ?? ''}';
  String get _bindingKey => '${settings.baseUrl}|${media?.key}';
  String get _seriesKey => '${settings.baseUrl}|series:${media?.seriesKey}';
  Map<String, dynamic> get binding => store.danmakuBinding(_bindingKey);
  int get offsetMs => (binding['offsetMs'] as num?)?.toInt() ?? 0;
  bool get available => settings.configured && media != null;

  void setMedia(DanmakuMedia value) {
    if (media?.key == value.key) return;
    media = value;
    status = '';
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(DanmakuMedia query, String base, int epoch) =>
      !_disposed &&
      store.profileEpoch == epoch &&
      media?.key == query.key &&
      settings.baseUrl == base;

  Future<void> configure(ExternalDanmakuSettings value) async {
    await store.setExternalDanmakuSettings(value);
    status = '';
    _notify();
  }

  Future<List<DanmakuCandidate>> search(String keyword) =>
      api.search(settings.baseUrl, keyword.trim());
  Future<List<DanmakuLibraryEpisode>> episodes(String id) =>
      api.episodes(settings.baseUrl, id);

  Future<void> choose(
    DanmakuCandidate candidate,
    DanmakuLibraryEpisode episode,
  ) async {
    final selectedMedia = media, base = settings.baseUrl;
    final epoch = store.profileEpoch;
    if (selectedMedia == null) return;
    final record = {
      'animeId': candidate.id,
      'animeTitle': candidate.title,
      'episodeTitle': episode.title,
      'episodeId': episode.id,
      'title': '${candidate.title} · ${episode.title}',
      'manual': true,
      'offsetMs': offsetMs,
    };
    await store.setDanmakuBinding('$base|${selectedMedia.key}', record);
    if (_disposed || store.profileEpoch != epoch) return;
    await store.setDanmakuBinding('$base|series:${selectedMedia.seriesKey}', {
      'animeId': candidate.id,
      'title': candidate.title,
    });
    status = '已手动匹配 ${record['title']}';
    _notify();
  }

  Future<void> reset() async {
    api.clearMatchingCache();
    await store.setDanmakuBinding(
      _bindingKey,
      offsetMs == 0 ? null : {'offsetMs': offsetMs},
    );
    await store.setDanmakuBinding(_seriesKey, null);
    status = '';
    _notify();
  }

  Future<void> setOffset(int value) async {
    await store.setDanmakuBinding(_bindingKey, {
      ...binding,
      'offsetMs': value.clamp(-1800000, 1800000),
    });
    _notify();
  }

  Future<Map<String, dynamic>?> _match(DanmakuMedia query, String base) async {
    final epoch = store.profileEpoch;
    final key = '$base|${query.key}', saved = store.danmakuBinding(key);
    if (saved['episodeId'] is String) {
      final rows = await api.episodes(
        base,
        saved['animeId'] as String,
        expectedTitle: saved['animeTitle'] as String,
      );
      if (!rows.any(
        (row) =>
            row.id == saved['episodeId'] && row.title == saved['episodeTitle'],
      )) {
        throw const FormatException('弹幕库分集标识已变化，请重新匹配');
      }
      return saved;
    }
    final series = store.danmakuBinding('$base|series:${query.seriesKey}');
    DanmakuCandidate? candidate;
    if (series['animeId'] is String) {
      candidate = DanmakuCandidate(
        id: series['animeId'] as String,
        title: series['title'] as String? ?? query.title,
      );
    } else {
      final candidates = (await api.search(
        base,
        query.title,
      )).where((candidate) => candidate.matches(query)).toList();
      if (!_current(query, base, epoch)) return null;
      if (candidates.length != 1) {
        status = candidates.isEmpty ? '没有确认到对应作品，请手动搜索弹幕' : '有多个同名版本，请手动选择弹幕';
        return null;
      }
      candidate = candidates.single;
    }
    final episodes = await api.episodes(
      base,
      candidate.id,
      expectedTitle: candidate.title,
    );
    if (!_current(query, base, epoch)) return null;
    final matching = episodes
        .where(
          (episode) =>
              query.episode != null &&
                  danmakuEpisode(episode.title) == query.episode ||
              query.kind == 'movie' &&
                  episodes.length == 1 &&
                  {'正片', '电影', '剧场版'}.contains(danmakuTitle(episode.title)),
        )
        .toList();
    if (matching.length != 1) {
      status = '集数信息不足或有多个版本，请手动选择弹幕';
      return null;
    }
    final result = {
      ...saved,
      'animeId': candidate.id,
      'animeTitle': candidate.title,
      'episodeTitle': matching.single.title,
      'episodeId': matching.single.id,
      'title': '${candidate.title} · ${matching.single.title}',
      'manual': false,
    };
    if (_current(query, base, epoch)) {
      await store.setDanmakuBinding(key, result);
    }
    return result;
  }

  Future<DanmakuPage> page(int startMs, int durationMs) async {
    final epoch = store.profileEpoch;
    final query = media!;
    final base = settings.baseUrl;
    final requestIdentity = 'external:${query.key}';
    final next = (startMs + danmakuWindowMs).clamp(0, durationMs);
    final selected = await _match(query, base);
    if (selected == null) {
      _notify();
      return DanmakuPage(
        episodeId: requestIdentity,
        startMs: startMs,
        nextMs: next,
        items: const [],
      );
    }
    final track = await api.track(
      base,
      selected['episodeId'] as String,
      identity: '${selected['animeTitle']}|${selected['episodeTitle']}',
    );
    if (!_current(query, base, epoch)) {
      return DanmakuPage(
        episodeId: requestIdentity,
        startMs: startMs,
        nextMs: next,
        items: const [],
      );
    }
    if (track.durationMs > 0 &&
        selected['manual'] != true &&
        (track.durationMs - durationMs).abs() >
            (durationMs * .15).clamp(15000, 300000)) {
      status = '弹幕版本与视频时长不符，请手动确认';
      _notify();
      return DanmakuPage(
        episodeId: requestIdentity,
        startMs: startMs,
        nextMs: next,
        items: const [],
      );
    }
    final offset = (selected['offsetMs'] as num?)?.toInt() ?? 0;
    final rows = track.items
        .where(
          (item) =>
              item.timeMs + offset >= startMs && item.timeMs + offset < next,
        )
        .toList();
    final items = rows.length <= 90
        ? rows
        : [for (var i = 0; i < 90; i++) rows[(i * rows.length / 90).floor()]];
    status = track.items.isEmpty ? '已匹配，本集暂无弹幕' : '已匹配 ${selected['title']}';
    _notify();
    return DanmakuPage(
      episodeId: requestIdentity,
      startMs: startMs,
      nextMs: next,
      items: [
        for (final item in items)
          DanmakuItem(
            id: item.id,
            text: item.text,
            timeMs: item.timeMs + offset,
          ),
      ],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    api.dispose();
    super.dispose();
  }
}
