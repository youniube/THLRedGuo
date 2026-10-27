import 'dart:async';
import 'dart:collection';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/models/feed/feed_models.dart';

class FeedSourceMixer {
  FeedSourceMixer(this.repository, Iterable<String> sources, this.session)
    : _sources = sources.map(_FeedSource.new).toList();

  final AppRepository repository;
  final String session;
  final List<_FeedSource> _sources;
  Completer<void> _changed = Completer<void>();
  int _pending = 0;
  int _next = 0;
  int _page = 0;
  bool _closed = false;
  bool _waiting = false;

  bool get _hasBuffered => _sources.any((source) => source.items.isNotEmpty);
  bool get hasMore => _sources.any(
    (source) => source.items.isNotEmpty || source.loading || source.hasMore,
  );

  Future<FeedPage> load() async {
    _waiting = true;
    try {
      _pump();
      while (!_closed && !_hasBuffered && _pending > 0) {
        await _changed.future;
      }
      if (_closed) throw AppFailure('推荐请求已取消', code: 'CANCELLED');
      if (!_hasBuffered) {
        final failures = _sources.where((source) => source.error != null);
        if (failures.isNotEmpty) {
          final failure = failures.first.error!;
          throw failure is AppFailure
              ? failure
              : AppFailure(failure.toString());
        }
      }
      final items = <FeedItem>[];
      var misses = 0;
      while (items.length < 12 && misses < _sources.length) {
        final source = _sources[_next];
        _next = (_next + 1) % _sources.length;
        if (source.items.isEmpty) {
          misses++;
        } else {
          items.add(source.items.removeFirst());
          misses = 0;
        }
      }
      return FeedPage(items: items, page: ++_page, hasMore: hasMore);
    } finally {
      _waiting = false;
    }
  }

  void retryFailures() {
    for (final source in _sources) {
      if (source.error != null) {
        source.error = null;
        source.hasMore = true;
      }
    }
  }

  void _pump() {
    if (_closed || !_waiting) return;
    final candidates =
        _sources
            .where(
              (source) =>
                  !source.loading &&
                  source.hasMore &&
                  source.items.isEmpty &&
                  source.error == null,
            )
            .toList()
          ..sort((a, b) => a.page.compareTo(b.page));
    for (final source in candidates) {
      if (_pending >= 3) break;
      source.loading = true;
      _pending++;
      unawaited(_load(source));
    }
  }

  Future<void> _load(_FeedSource source) async {
    try {
      final result = await repository.videoFeed(
        source: source.id,
        page: source.page + 1,
        session: session,
      );
      if (_closed) return;
      source.page = result.page;
      source.hasMore = result.hasMore;
      for (final item in result.items) {
        if (item.drama.source == source.id &&
            item.drama.id.isNotEmpty &&
            source.seen.add(item.drama.id)) {
          source.items.add(item);
        }
      }
      source.emptyPages = source.items.isEmpty ? source.emptyPages + 1 : 0;
      if (source.emptyPages >= 3) source.hasMore = false;
    } catch (failure) {
      if (!_closed) {
        source.error = failure;
        source.hasMore = false;
      }
    } finally {
      source.loading = false;
      _pending--;
      _pump();
      if (!_changed.isCompleted) _changed.complete();
      _changed = Completer<void>();
    }
  }

  void dispose() {
    _closed = true;
    if (!_changed.isCompleted) _changed.complete();
  }
}

class _FeedSource {
  _FeedSource(this.id);
  final String id;
  final items = Queue<FeedItem>();
  final seen = <String>{};
  int page = 0;
  int emptyPages = 0;
  bool hasMore = true;
  bool loading = false;
  Object? error;
}
