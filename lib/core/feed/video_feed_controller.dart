import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/feed/feed_source_mixer.dart';
import 'package:THLRedLook/core/js/js_source_service.dart';
import 'package:THLRedLook/core/player/playback_lease.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/feed/feed_models.dart';
import 'package:THLRedLook/models/feed/feed_source_selection.dart';

class VideoFeedController extends ChangeNotifier {
  VideoFeedController(this.repository, this.store) {
    store.addListener(_sourcesChanged);
    _sourceService?.addListener(_sourcesChanged);
    _sourcesChanged();
  }
  final AppRepository repository;
  final LocalStore store;
  final playback = PlaybackLeaseQueue();
  List<FeedItem> items = [];
  int index = 0;
  bool active = false;
  bool loading = false;
  bool loadingMore = false;
  bool loadingDetail = false;
  bool hasMore = true;
  String? error;
  String? moreError;
  bool restartRequired = false;
  String? detailError;
  DramaDetail? detail;
  int _generation = 0;
  int _selection = 0;
  bool _disposed = false;
  int? _preparing;
  String _session = '';
  final _details = <String, DramaDetail>{};
  Timer? _selectionTimer;
  final _sourceService = JsSourceService.current;
  FeedSourceMixer? _mixer;
  List<String> _sourceIds = [];
  String _sourceKey = '';
  int _profileEpoch = -1;
  int _emptyPages = 0;
  final _savedScopes = <String, ({List<FeedItem> items, int index})>{};

  FeedSourceSelection get selection => store.feedSources;
  List<SourceSite> get selectableSources =>
      store.sources.where((site) => !store.isPrivateSource(site.id)).toList();
  bool get allowed => !store.locked && _sourceIds.isNotEmpty;
  int get revision => _generation;
  FeedItem? get current => index < items.length ? items[index] : null;

  void _sourcesChanged() {
    if (_disposed) return;
    final epochChanged = _profileEpoch != store.profileEpoch;
    final visible = store.sources;
    final discoveryGroup = SourceSite.byId(store.source).groupId;
    final selected = selection;
    final publicIds = selectableSources.map((site) => site.id).toSet();
    final ids = switch (selected.mode) {
      FeedSourceMode.discovery =>
        visible
            .where((site) => site.groupId == discoveryGroup)
            .map((site) => site.id)
            .toList(),
      FeedSourceMode.all => publicIds.toList(),
      FeedSourceMode.custom =>
        selected.sources.where(publicIds.contains).toList(),
    };
    final key = '${store.profileEpoch}:${selected.mode.name}:${ids.join(',')}';
    if (!epochChanged && key == _sourceKey) return;
    if (epochChanged || store.locked) {
      _savedScopes.clear();
    } else if (_sourceKey.isNotEmpty && items.isNotEmpty) {
      _savedScopes[_sourceKey] = (items: List.of(items), index: index);
      while (_savedScopes.length > 3) {
        _savedScopes.remove(_savedScopes.keys.first);
      }
    }
    _profileEpoch = store.profileEpoch;
    _sourceKey = key;
    _sourceIds = ids;
    _generation++;
    _selection++;
    _selectionTimer?.cancel();
    _mixer?.dispose();
    _mixer = null;
    _session = '';
    _details.clear();
    final saved = _savedScopes.remove(key);
    items = saved?.items ?? [];
    index = saved?.index ?? 0;
    _emptyPages = 0;
    detail = null;
    loading = loadingMore = loadingDetail = false;
    hasMore = true;
    error = moreError = detailError = null;
    restartRequired = false;
    notifyListeners();
    if (active && allowed) {
      unawaited(
        Future<void>.microtask(() async {
          if (_disposed || !active || !allowed) return;
          if (items.isEmpty) {
            await refresh();
          } else {
            await prepare();
          }
        }),
      );
    }
  }

  Future<FeedPage> _loadPage() {
    if (_mixer == null) {
      if (_session.isEmpty) {
        _session =
            '${DateTime.now().microsecondsSinceEpoch}_${store.stepFeedOffset()}';
      }
      _mixer = FeedSourceMixer(repository, _sourceIds, _session);
    }
    return _mixer!.load();
  }

  void setActive(bool value) {
    if (_disposed || active == value) return;
    active = value;
    if (!active) {
      detail = null;
      loadingDetail = false;
    }
    _selection++;
    _selectionTimer?.cancel();
    notifyListeners();
    if (active && allowed) {
      if (items.isEmpty && !loading) {
        unawaited(refresh());
      } else {
        unawaited(prepare());
      }
    }
  }

  Future<void> refresh({bool preserveCurrent = false}) async {
    if (_disposed || !allowed) return;
    final generation = ++_generation;
    _selection++;
    final retainId = preserveCurrent ? current?.drama.id : null;
    final offset = _session.isEmpty && store.feedSeenIds.isEmpty
        ? 0
        : store.stepFeedOffset();
    _session = '${DateTime.now().microsecondsSinceEpoch}_$offset';
    _mixer?.dispose();
    _mixer = null;
    _selectionTimer?.cancel();
    items = [];
    detail = null;
    index = 0;
    _emptyPages = 0;
    _details.clear();
    loading = true;
    loadingMore = false;
    hasMore = true;
    error = moreError = detailError = null;
    restartRequired = false;
    notifyListeners();
    try {
      await repository.cancelVideoFeed();
      if (_disposed || generation != _generation) return;
      final result = await _loadPage();
      if (_disposed || generation != _generation || !allowed) return;
      final filtered = _filterSeen(result.items, retainId: retainId);
      items = (filtered.isEmpty && !result.hasMore)
          ? _unique(result.items)
          : filtered;
      hasMore = result.hasMore;
    } catch (failure) {
      if (!_disposed && generation == _generation) error = failure.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
        if (active) unawaited(prepare());
        if (active && hasMore && items.length < 3) {
          unawaited(loadMore(retainId: retainId));
        }
      }
    }
  }

  List<FeedItem> _filterSeen(Iterable<FeedItem> values, {String? retainId}) {
    final list = <FeedItem>[];
    final seen = <String>{};
    for (final value in values) {
      final id = value.drama.id;
      if (_sourceIds.contains(value.drama.source) &&
          id.isNotEmpty &&
          !seen.contains(id) &&
          (!store.isFeedSeen(id) || id == retainId)) {
        seen.add(id);
        list.add(value);
      }
    }
    return list;
  }

  List<FeedItem> _unique(Iterable<FeedItem> values) => <String, FeedItem>{
    for (final value in values)
      if (_sourceIds.contains(value.drama.source) && value.drama.id.isNotEmpty)
        value.drama.id: value,
  }.values.toList();

  Future<void> loadMore({String? retainId}) async {
    if (_disposed ||
        !active ||
        !allowed ||
        loading ||
        loadingMore ||
        !hasMore ||
        moreError != null) {
      return;
    }
    final generation = _generation;
    loadingMore = true;
    notifyListeners();
    try {
      final result = await _loadPage();
      if (_disposed || generation != _generation || !allowed) return;
      final existingIds = items.map((e) => e.drama.id).toSet();
      final fresh = _filterSeen(
        result.items,
        retainId: retainId,
      ).where((e) => !existingIds.contains(e.drama.id)).toList();
      items = [...items, ...fresh];
      _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
      hasMore = result.hasMore;
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        moreError = failure.toString();
        restartRequired =
            failure is AppFailure &&
            {'CURSOR_EXPIRED', 'MISSING_CURSOR'}.contains(failure.code);
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loadingMore = false;
        notifyListeners();
        if (active &&
            hasMore &&
            moreError == null &&
            _emptyPages < 3 &&
            items.length - index < 3) {
          unawaited(loadMore(retainId: retainId));
        }
      }
    }
  }

  Future<void> retryMore() async {
    if (restartRequired) {
      await refresh(preserveCurrent: true);
      return;
    }
    moreError = null;
    _mixer?.retryFailures();
    await loadMore();
  }

  void select(int value) {
    if (_disposed || value == index || value < 0 || value >= items.length) {
      return;
    }
    index = value;
    _selection++;
    detail = null;
    detailError = null;
    loadingDetail = true;
    _selectionTimer?.cancel();
    notifyListeners();
    _selectionTimer = Timer(
      const Duration(milliseconds: 160),
      () => unawaited(prepare()),
    );
    if (index >= items.length - 2) {
      if (hasMore) {
        unawaited(loadMore());
      } else {
        unawaited(nextBatch());
      }
    }
  }

  Future<void> nextBatch({String? retainId}) async {
    if (_disposed ||
        !active ||
        !allowed ||
        loading ||
        loadingMore ||
        moreError != null) {
      return;
    }
    final generation = _generation;
    loadingMore = true;
    notifyListeners();
    try {
      final offset = store.stepFeedOffset();
      final newSession = '${DateTime.now().microsecondsSinceEpoch}_$offset';
      _mixer?.dispose();
      _mixer = null;
      _session = newSession;
      final result = await _loadPage();
      if (_disposed || generation != _generation || !allowed) return;
      final existingIds = items.map((e) => e.drama.id).toSet();
      var fresh = _filterSeen(
        result.items,
        retainId: retainId,
      ).where((e) => !existingIds.contains(e.drama.id)).toList();
      if (fresh.isEmpty && result.items.isNotEmpty) {
        fresh = _unique(result.items)
            .where((e) => !existingIds.contains(e.drama.id))
            .map((e) => FeedItem(drama: e.drama))
            .toList();
      }
      if (fresh.isNotEmpty) {
        items = [...items, ...fresh];
      }
      hasMore = result.hasMore;
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        moreError = failure.toString();
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> prepare() async {
    if (_preparing == _generation ||
        _disposed ||
        !active ||
        !allowed ||
        current == null) {
      return;
    }
    final generation = _generation;
    _preparing = generation;
    try {
      while (!_disposed &&
          active &&
          allowed &&
          current != null &&
          generation == _generation) {
        final ticket = _selection;
        final target = current!;
        final epoch = store.profileEpoch;
        loadingDetail = true;
        detail = null;
        detailError = null;
        notifyListeners();
        await playback.idle;
        if (_disposed || !active || ticket != _selection) continue;
        try {
          final loaded =
              _details[target.drama.id] ??
              await repository.detail(target.drama);
          if (_disposed ||
              !active ||
              ticket != _selection ||
              store.profileEpoch != epoch) {
            continue;
          }
          if (loaded.episodes.isEmpty) {
            throw AppFailure('这部短剧暂未返回可播放集数，请重试或上滑换一部');
          }
          _details[target.drama.id] = loaded;
          while (_details.length > 3) {
            _details.remove(_details.keys.first);
          }
          detail = loaded;
          loadingDetail = false;
          notifyListeners();
          unawaited(store.markFeedSeen(target.drama.id));
          break;
        } catch (failure) {
          if (_disposed || !active || ticket != _selection) continue;
          detailError = failure.toString();
          loadingDetail = false;
          notifyListeners();
          break;
        }
      }
    } finally {
      if (_preparing == generation) _preparing = null;
    }
  }

  void switchSeason(DramaDetail next) {
    if (_disposed || current == null) return;
    items = [...items]..[index] = FeedItem(drama: next.drama);
    detail = next;
    _details[next.drama.id] = next;
    _selection++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_sourcesChanged);
    _sourceService?.removeListener(_sourcesChanged);
    _mixer?.dispose();
    _savedScopes.clear();
    _generation++;
    _selection++;
    _selectionTimer?.cancel();
    super.dispose();
  }
}
