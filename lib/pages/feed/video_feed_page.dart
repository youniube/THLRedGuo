import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:THLRedLook/core/feed/video_feed_controller.dart';
import 'package:THLRedLook/core/feed/feed_playback_policy.dart';
import 'package:THLRedLook/core/player/playback_surface.dart';
import 'package:THLRedLook/core/store/follow_state.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/feed/feed_source_selection.dart';
import 'package:THLRedLook/pages/player/player_page.dart';
import 'package:THLRedLook/utils/navigation/app_route_observer.dart';
import 'package:THLRedLook/utils/screen/app_layout.dart';
import 'package:THLRedLook/views/common/widgets.dart';
import 'package:THLRedLook/views/feed/feed_source_sheet.dart';

class VideoFeedScreen extends StatefulWidget {
  const VideoFeedScreen({
    super.key,
    required this.controller,
    required this.active,
    this.onFullscreenChanged,
  });
  final VideoFeedController controller;
  final bool active;
  final ValueChanged<bool>? onFullscreenChanged;

  @override
  State<VideoFeedScreen> createState() => _VideoFeedScreenState();
}

class _VideoFeedScreenState extends State<VideoFeedScreen>
    with RouteAware, WidgetsBindingObserver {
  final _pages = PageController(keepPage: false);
  final _playbackSurface = PlaybackSurface();
  PageRoute<dynamic>? _route;
  bool _covered = false;
  bool _opening = false;
  bool _foreground = true;
  int _revision = -1;
  bool _fullscreen = false;
  bool _moving = false;
  VideoFeedController get feed => widget.controller;

  void _feedChanged() {
    if (_revision == feed.revision) return;
    _revision = feed.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pages.hasClients && feed.items.isNotEmpty) {
        _pages.jumpToPage(feed.index);
      }
    });
  }

  void _syncActive() =>
      feed.setActive(widget.active && !_covered && !_opening && _foreground);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    feed.addListener(_feedChanged);
    _feedChanged();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncActive();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncActive();
  }

  @override
  void didUpdateWidget(covariant VideoFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != feed) {
      oldWidget.controller.removeListener(_feedChanged);
      feed.addListener(_feedChanged);
      _revision = -1;
      _feedChanged();
    }
    _syncActive();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      appRouteObserver.unsubscribe(this);
      _route = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _covered = true;
    _syncActive();
  }

  @override
  void didPopNext() {
    _covered = false;
    _syncActive();
  }

  Future<void> _openFull(DramaDetail detail) async {
    if (_opening || feed.current?.drama.id != detail.drama.id) return;
    final epoch = feed.store.profileEpoch;
    final revision = feed.revision;
    _opening = true;
    _syncActive();
    try {
      await feed.playback.idle;
      if (!mounted ||
          feed.store.profileEpoch != epoch ||
          feed.store.locked ||
          feed.revision != revision ||
          feed.current?.drama.id != detail.drama.id) {
        return;
      }
      final watched = feed.store.watched(detail.drama.id);
      final index = resumeEpisodeIndex(detail.episodes, watched);
      final position =
          watched != null &&
              !watched.finished &&
              watched.episode == detail.episodes[index].number
          ? watched.position
          : 0.0;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            detail: detail,
            initialIndex: index,
            initialPosition: position,
            repository: feed.repository,
            store: feed.store,
          ),
        ),
      );
    } finally {
      if (mounted) {
        _opening = false;
        _syncActive();
      }
    }
  }

  void _fullscreenChanged(bool value) {
    if (!mounted || _fullscreen == value) return;
    setState(() => _fullscreen = value);
    widget.onFullscreenChanged?.call(value);
  }

  Future<bool> _move(
    int direction, {
    FeedPlaybackPlan? preview,
    bool Function()? stillAllowed,
  }) async {
    if (_moving || _opening || !feed.active) return false;
    final origin = feed.index;
    final revision = feed.revision;
    final dramaId = feed.current?.drama.id;
    final target = origin + direction;
    _moving = true;
    try {
      if (target >= feed.items.length) {
        if (feed.hasMore) {
          await feed.loadMore();
        } else {
          await feed.nextBatch();
        }
      }
      if (!mounted ||
          !feed.active ||
          _opening ||
          feed.index != origin ||
          feed.revision != revision ||
          feed.current?.drama.id != dramaId ||
          stillAllowed != null && !stillAllowed() ||
          preview != null && !preview.finished ||
          !_pages.hasClients ||
          target < 0 ||
          target >= feed.items.length) {
        return false;
      }
      await _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
      return true;
    } finally {
      _moving = false;
    }
  }

  Future<void> _chooseSources() async {
    if (_opening) return;
    _opening = true;
    _syncActive();
    try {
      var refreshRequested = false;
      final selection = await showFeedSourceSheet(
        context,
        feed,
        onRefresh: () => refreshRequested = true,
      );
      if (!mounted) return;
      if (refreshRequested) {
        _refresh();
        return;
      }
      if (selection == null) return;
      await saveUserChange(context, () => feed.store.setFeedSources(selection));
    } finally {
      if (mounted) {
        _opening = false;
        _syncActive();
      }
    }
  }

  void _refresh() {
    if (_pages.hasClients) _pages.jumpToPage(0);
    unawaited(feed.refresh());
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    feed.removeListener(_feedChanged);
    feed.setActive(false);
    _pages.dispose();
    final playback = feed.playback;
    unawaited(
      Future<void>.microtask(() async {
        await playback.idle;
        await _playbackSurface.close();
      }),
    );
    super.dispose();
  }

  Widget _page(int index) {
    final current = index == feed.index;
    final detail = current ? feed.detail : null;
    if (current && feed.active && detail != null && !feed.loadingDetail) {
      final plan = feed.playbackFor(detail);
      return PlayerScreen(
        key: ValueKey((detail.drama.id, plan)),
        detail: detail,
        initialIndex: plan.initialIndex,
        initialPosition: plan.initialPosition,
        repository: feed.repository,
        store: feed.store,
        feed: true,
        playbackQueue: feed.playback,
        playbackSurface: _playbackSurface,
        feedPlayback: plan,
        onOpenFull: () => unawaited(_openFull(detail)),
        onPreviewFinished: (stillAllowed) =>
            _move(1, preview: plan, stillAllowed: stillAllowed),
        onFullscreenChanged: _fullscreenChanged,
        onBackgroundWorkAllowed: (allowed) =>
            feed.setBackgroundWorkAllowed(detail.drama.id, allowed),
        onSeasonChanged: feed.switchSeason,
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: !current || !feed.active
            ? Text(
                feed.items[index].drama.title,
                style: const TextStyle(color: Colors.white54),
              )
            : feed.detailError != null
            ? StatusPanel(
                title: '这部暂时无法播放',
                message: feed.detailError!,
                onRetry: () => unawaited(feed.prepare()),
              )
            : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: feed,
    builder: (context, _) => Theme(
      data: ThemeData.dark(),
      child: ColoredBox(
        key: const ValueKey('video-feed'),
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: !feed.allowed
                  ? StatusPanel(
                      title: feed.store.locked ? '请先解锁当前用户' : '当前推荐范围没有可用站源',
                      message: '点击左上角“推荐源”调整推荐范围，或到发现页选择站源。',
                    )
                  : feed.items.isEmpty
                  ? feed.loading
                        ? const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                  color: Colors.white70,
                                ),
                                SizedBox(height: 16),
                                Text(
                                  '正在加载推荐视频...',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : StatusPanel(
                            title: feed.error == null ? '暂无推荐' : '推荐暂时无法加载',
                            message: feed.error ?? '刷新后获取新的推荐',
                            onRetry: _refresh,
                          )
                  : CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.pageDown,
                        ): () =>
                            unawaited(_move(1)),
                        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                            unawaited(_move(-1)),
                      },
                      child: PageView.builder(
                        key: const ValueKey('feed-pager'),
                        controller: _pages,
                        physics: _fullscreen
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        scrollDirection: Axis.vertical,
                        itemCount: feed.items.length,
                        onPageChanged: feed.select,
                        itemBuilder: (context, index) => _page(index),
                      ),
                    ),
            ),
            if (!_fullscreen)
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          TextButton(
                            key: const ValueKey('feed-source-selector'),
                            onPressed: () => unawaited(_chooseSources()),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 48),
                              textStyle: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('推荐源'),
                                SizedBox(width: 4),
                                Icon(Icons.keyboard_arrow_down, size: 20),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              '上滑换剧',
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (AppLayout.isTelevision(context) ||
                              defaultTargetPlatform == TargetPlatform.windows ||
                              defaultTargetPlatform == TargetPlatform.macOS ||
                              defaultTargetPlatform ==
                                  TargetPlatform.linux) ...[
                            IconButton(
                              key: const ValueKey('feed-refresh'),
                              tooltip: '刷新推荐',
                              onPressed: feed.loading || !feed.allowed
                                  ? null
                                  : _refresh,
                              color: Colors.white,
                              icon: const Icon(Icons.refresh),
                            ),
                            IconButton(
                              key: const ValueKey('feed-previous'),
                              tooltip: '上一部',
                              onPressed: feed.index > 0
                                  ? () => unawaited(_move(-1))
                                  : null,
                              color: Colors.white,
                              icon: const Icon(Icons.keyboard_arrow_up),
                            ),
                            IconButton(
                              key: const ValueKey('feed-next'),
                              tooltip: '下一部',
                              onPressed: feed.items.isEmpty
                                  ? null
                                  : () => unawaited(_move(1)),
                              color: Colors.white,
                              icon: const Icon(Icons.keyboard_arrow_down),
                            ),
                          ],
                        ],
                      ),
                      if (feed.selection.mode != FeedSourceMode.discovery &&
                          feed.current != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '来源：${SourceSite.byId(feed.current!.drama.source).name}',
                            key: const ValueKey('feed-current-source'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (feed.loadingMore)
                        const LinearProgressIndicator(minHeight: 2),
                      if (feed.moreError != null)
                        Material(
                          color: const Color(0xD9222222),
                          borderRadius: BorderRadius.circular(8),
                          child: Row(
                            children: [
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  '更多推荐暂时加载失败',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton(
                                key: const ValueKey('feed-retry-more'),
                                onPressed: () => unawaited(feed.retryMore()),
                                child: Text(feed.restartRequired ? '刷新' : '重试'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
