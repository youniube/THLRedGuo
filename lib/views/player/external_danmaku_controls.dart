import 'package:flutter/material.dart';

import 'package:THLRedLook/core/danmaku/danmaku_controller.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';

Future<bool> editDanmakuApi(
  BuildContext context,
  ExternalDanmakuSession session,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _DanmakuApiManager(session: session),
    ) ==
    true;

class ExternalDanmakuControls extends StatelessWidget {
  const ExternalDanmakuControls({
    super.key,
    required this.session,
    required this.onChanged,
    this.controller,
    this.showOffset = true,
    this.showMatching = true,
  });
  final ExternalDanmakuSession session;
  final DanmakuController? controller;
  final VoidCallback onChanged;
  final bool showOffset;
  final bool showMatching;

  Future<void> _manage(BuildContext context) async {
    if (await editDanmakuApi(context, session)) onChanged();
  }

  Future<void> _search(BuildContext context) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _DanmakuSearchDialog(session: session),
    );
    if (changed == true) onChanged();
  }

  Widget _matchingStatus(BuildContext context) {
    final native = controller == null
        ? session.settings.mode == 'native'
        : !controller!.usesExternal;
    final binding = session.binding;
    final hasMatch = native
        ? controller?.supported == true
        : binding['episodeId'] is String;
    final title = native
        ? [
            session.media?.title ?? '',
            if (session.media?.episode != null) '第 ${session.media!.episode} 集',
          ].where((value) => value.isNotEmpty).join(' · ')
        : binding['title'] as String? ??
              [
                binding['animeTitle'],
                binding['episodeTitle'],
              ].whereType<String>().join(' · ');
    final status =
        controller?.status ??
        (session.status.isNotEmpty
            ? session.status
            : !session.settings.configured && !native
            ? '尚未配置弹幕 API，请先添加数据源'
            : !session.settings.autoMatch && !hasMatch && !native
            ? '自动匹配已关闭，可手动搜索作品和分集'
            : '等待视频就绪');
    final loading = controller?.loading == true;
    return Column(
      key: const ValueKey('danmaku-current-match'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              controller?.canRetry == true
                  ? Icons.error_outline_rounded
                  : hasMatch
                  ? Icons.check_circle_outline_rounded
                  : Icons.manage_search_rounded,
              size: 20,
              color: AppColors.hongguoRed,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '当前匹配',
                style: TextStyle(
                  color: AppColors.textSecondaryDark,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accentSubtle08,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                native ? '原站弹幕' : '通用 API',
                style: const TextStyle(
                  color: AppColors.hongguoRed,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        if (title.isNotEmpty && hasMatch) ...[
          const SizedBox(height: 10),
          Text(
            title,
            key: const ValueKey('danmaku-match-title'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          status,
          key: const ValueKey('danmaku-match-status'),
          style: TextStyle(
            color: controller?.canRetry == true
                ? AppColors.error
                : AppColors.textSecondaryDark,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('danmaku-manual-search'),
              style: _actionStyle(primary: true),
              onPressed: session.available && session.settings.mode != 'native'
                  ? () => _search(context)
                  : null,
              icon: const Icon(Icons.search_rounded),
              label: const Text('手动搜索'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('danmaku-rematch'),
              style: _actionStyle(),
              onPressed:
                  !session.available ||
                      loading ||
                      session.settings.mode == 'native'
                  ? null
                  : () async {
                      await session.reset();
                      onChanged();
                    },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新匹配'),
            ),
            if (controller?.canRetry == true)
              TextButton(
                key: const ValueKey('danmaku-retry-load'),
                onPressed: controller!.retry,
                child: const Text('重试加载'),
              ),
            if (showOffset)
              TextButton(
                onPressed: session.media == null
                    ? null
                    : () => _offset(context),
                child: Text('时间偏移 ${session.offsetMs / 1000}s'),
              ),
          ],
        ),
      ],
    );
  }

  ButtonStyle _actionStyle({bool primary = false}) => OutlinedButton.styleFrom(
    foregroundColor: primary ? AppColors.hongguoRed : AppColors.textPrimaryDark,
    backgroundColor: primary ? AppColors.accentSubtle12 : AppColors.darkCard,
    side: BorderSide(
      color: primary ? AppColors.accentBorder40 : AppColors.darkBorder,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  );

  Widget _apiSelector(BuildContext context) {
    final selected = session.settings.endpoints
        .where((source) => source.baseUrl == session.settings.baseUrl)
        .firstOrNull;
    return Material(
      key: const ValueKey('danmaku-current-api'),
      color: AppColors.darkCard,
      borderRadius: BorderRadius.circular(14),
      child: Tooltip(
        message: '配置通用弹幕 API',
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _manage(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(
                  Icons.dns_outlined,
                  size: 20,
                  color: AppColors.textSecondaryDark,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected?.name ?? '添加弹幕 API',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        selected == null
                            ? '填写服务地址，匹配其他播放源的弹幕'
                            : '通用 API · ${Uri.parse(selected.baseUrl).host}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondaryDark,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondaryDark,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _offset(BuildContext context) async {
    final mediaKey = session.media?.key;
    final epoch = session.store.profileEpoch;
    final field = TextEditingController(text: '${session.offsetMs / 1000}');
    String? error;
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('弹幕时间偏移'),
          content: TextField(
            controller: field,
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            decoration: InputDecoration(
              labelText: '秒，正数延后，负数提前',
              helperText: '范围 -1800 到 1800 秒',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final seconds = double.tryParse(field.text);
                if (seconds == null ||
                    !seconds.isFinite ||
                    seconds.abs() > 1800) {
                  setState(() => error = '请输入有效的偏移秒数');
                  return;
                }
                Navigator.pop(dialogContext, (seconds * 1000).round());
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    field.dispose();
    if (value != null &&
        session.media?.key == mediaKey &&
        session.store.profileEpoch == epoch) {
      await session.setOffset(value);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([session, controller]),
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '弹幕来源',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondaryDark,
                ),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('danmaku-api-management'),
              onPressed: () => _manage(context),
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: Text('API 管理 · ${session.settings.endpoints.length}'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          spacing: 8,
          children: [
            for (final entry in const {
              'automatic': '自动选择',
              'native': '仅原站',
              'external': '通用 API',
            }.entries)
              Expanded(
                child: OutlinedButton(
                  key: ValueKey('danmaku-mode-${entry.key}'),
                  style:
                      _actionStyle(
                        primary: session.settings.mode == entry.key,
                      ).copyWith(
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                  onPressed: () async {
                    if (entry.key == session.settings.mode) return;
                    await session.configure(
                      session.settings.copyWith(mode: entry.key),
                    );
                    onChanged();
                  },
                  child: Text(
                    entry.value,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          switch (session.settings.mode) {
            'native' => '使用当前播放源提供的弹幕',
            'external' => '通过下方 API 匹配作品和分集',
            _ => '优先使用原站弹幕，也可手动匹配通用 API',
          },
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textSecondaryDark,
          ),
        ),
        const SizedBox(height: 16),
        _apiSelector(context),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          key: const ValueKey('danmaku-auto-match'),
          contentPadding: EdgeInsets.zero,
          title: const Text('自动匹配'),
          subtitle: Text(
            session.settings.mode == 'native'
                ? '仅原站模式无需匹配外部弹幕'
                : '按作品与分集查找，多个候选时手动选择',
          ),
          value: session.settings.autoMatch,
          onChanged: session.settings.mode == 'native'
              ? null
              : (value) async {
                  await session.configure(
                    session.settings.copyWith(autoMatch: value),
                  );
                  onChanged();
                },
        ),
        if (showMatching) ...[
          const Divider(height: 28),
          _matchingStatus(context),
        ] else ...[
          const SizedBox(height: 12),
          const Text(
            '播放时可查看匹配结果、手动选择作品和分集。',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondaryDark),
          ),
        ],
      ],
    ),
  );
}

class _DanmakuSearchDialog extends StatefulWidget {
  const _DanmakuSearchDialog({required this.session});
  final ExternalDanmakuSession session;
  @override
  State<_DanmakuSearchDialog> createState() => _DanmakuSearchDialogState();
}

class _DanmakuSearchDialogState extends State<_DanmakuSearchDialog> {
  late final String? _mediaKey;
  late final TextEditingController _keyword;
  List<DanmakuCandidate> _candidates = [];
  List<DanmakuLibraryEpisode> _episodes = [];
  DanmakuCandidate? _selected;
  bool _loading = false;
  String _error = '';
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _mediaKey = widget.session.media?.key;
    _keyword = TextEditingController(text: widget.session.media?.title ?? '');
  }

  @override
  void dispose() {
    _request++;
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _load([DanmakuCandidate? candidate]) async {
    final ticket = ++_request;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final candidates = candidate == null
          ? await widget.session.search(_keyword.text)
          : <DanmakuCandidate>[];
      final episodes = candidate == null
          ? <DanmakuLibraryEpisode>[]
          : await widget.session.episodes(candidate.id);
      if (!mounted || ticket != _request) return;
      setState(() {
        _selected = candidate;
        _candidates = candidates;
        _episodes = episodes;
      });
    } catch (_) {
      if (mounted && ticket == _request) {
        setState(() => _error = '弹幕查询失败，请检查 API 地址后重试');
      }
    } finally {
      if (mounted && ticket == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_selected?.title ?? '搜索弹幕'),
    content: SizedBox(
      width: 600,
      height: 420,
      child: Column(
        children: [
          TextField(
            controller: _keyword,
            decoration: InputDecoration(
              labelText: '影视名称',
              suffixIcon: IconButton(
                onPressed: _loading ? null : () => _load(),
                icon: const Icon(Icons.search),
              ),
            ),
            onSubmitted: (_) => _load(),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error.isNotEmpty) Text(_error),
          Expanded(
            child: ListView(
              children: _selected == null
                  ? [
                      for (final candidate in _candidates)
                        ListTile(
                          title: Text(candidate.title),
                          subtitle: Text(
                            [
                              if (candidate.year > 0) '${candidate.year}',
                              candidate.kind,
                            ].where((text) => text.isNotEmpty).join(' · '),
                          ),
                          onTap: _loading ? null : () => _load(candidate),
                        ),
                      if (!_loading && _candidates.isEmpty)
                        const ListTile(title: Text('搜索后选择作品和对应分集')),
                    ]
                  : [
                      for (final episode in _episodes)
                        ListTile(
                          title: Text(episode.title),
                          onTap: _loading
                              ? null
                              : () async {
                                  if (widget.session.media?.key != _mediaKey) {
                                    setState(() => _error = '播放分集已变化，请关闭后重新匹配');
                                    return;
                                  }
                                  await widget.session.choose(
                                    _selected!,
                                    episode,
                                  );
                                  if (context.mounted) {
                                    Navigator.pop(context, true);
                                  }
                                },
                        ),
                    ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      if (_selected != null)
        TextButton(
          onPressed: () => setState(() {
            _selected = null;
            _episodes = [];
          }),
          child: const Text('返回作品列表'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class ExternalDanmakuTimingControls extends StatelessWidget {
  const ExternalDanmakuTimingControls({
    super.key,
    required this.session,
    required this.onChanged,
  });
  final ExternalDanmakuSession session;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('时间同步', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('偏移 ${(session.offsetMs / 1000).toStringAsFixed(1)} 秒'),
        const Text('正数延后，负数提前，只调整当前分集的弹幕。'),
        Wrap(
          spacing: 8,
          children: [
            for (final seconds in [-1, 0, 1])
              TextButton(
                onPressed: session.media == null
                    ? null
                    : () async {
                        await session.setOffset(
                          seconds == 0 ? 0 : session.offsetMs + seconds * 1000,
                        );
                        onChanged();
                      },
                child: Text(
                  seconds == 0
                      ? '归零'
                      : seconds > 0
                      ? '+1 秒'
                      : '−1 秒',
                ),
              ),
            TextButton(
              onPressed: session.media == null
                  ? null
                  : () => ExternalDanmakuControls(
                      session: session,
                      onChanged: onChanged,
                    )._offset(context),
              child: const Text('精确调整'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _DanmakuApiManager extends StatefulWidget {
  const _DanmakuApiManager({required this.session});
  final ExternalDanmakuSession session;
  @override
  State<_DanmakuApiManager> createState() => _DanmakuApiManagerState();
}

class _DanmakuApiManagerState extends State<_DanmakuApiManager> {
  late final _epoch = widget.session.store.profileEpoch;
  late final _sources = [...widget.session.settings.endpoints];
  late String _selected = widget.session.settings.baseUrl;
  final _messages = <String, String>{};
  String? _error;
  bool _saving = false;
  bool get _allowed => widget.session.store.profileEpoch == _epoch;
  Future<void> _edit([DanmakuApiSource? source]) async {
    final next = await showDialog<DanmakuApiSource>(
      context: context,
      builder: (_) => _DanmakuApiEditor(source: source),
    );
    if (next == null || !mounted || !_allowed) return;
    if (_sources.any(
      (value) => value != source && value.baseUrl == next.baseUrl,
    )) {
      setState(() => _error = '该 API 地址已存在，请直接选择。');
      return;
    }
    setState(() {
      final index = source == null ? -1 : _sources.indexOf(source);
      if (index < 0) {
        if (_sources.length < 16) _sources.add(next);
      } else {
        _sources[index] = next;
      }
      if (_selected.isEmpty || _selected == source?.baseUrl) {
        _selected = next.baseUrl;
      }
      _error = null;
    });
  }

  Future<void> _probe(DanmakuApiSource source) async {
    setState(() => _messages[source.baseUrl] = '正在检测…');
    try {
      await widget.session.api.search(source.baseUrl, '连接检测');
      if (mounted && _allowed) {
        setState(() => _messages[source.baseUrl] = '连接与搜索格式正常');
      }
    } catch (_) {
      if (mounted && _allowed) {
        setState(() => _messages[source.baseUrl] = '检测失败，请检查服务地址');
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('弹幕 API 管理'),
    content: SizedBox(
      width: 480,
      height:
          ((MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom) *
                  .45)
              .clamp(100.0, 360.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('兼容 danmu_api，最多保存 16 个 API。选择一个作为当前服务。'),
          if (!_allowed) const Text('当前用户已变更，请关闭后重新打开。'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: ListView(
              children: [
                for (final source in _sources)
                  ListTile(
                    leading: Icon(
                      source.baseUrl == _selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(source.name),
                    subtitle: Text(
                      _messages[source.baseUrl] ??
                          Uri.parse(source.baseUrl).host,
                    ),
                    onTap: !_allowed || _saving
                        ? null
                        : () => setState(() => _selected = source.baseUrl),
                    trailing: PopupMenuButton<String>(
                      enabled: _allowed && !_saving,
                      onSelected: (action) async {
                        if (action == 'edit') {
                          await _edit(source);
                        } else if (action == 'probe') {
                          await _probe(source);
                        } else {
                          setState(() {
                            _sources.remove(source);
                            if (_selected == source.baseUrl) {
                              _selected = _sources.firstOrNull?.baseUrl ?? '';
                            }
                          });
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'probe', child: Text('检测连接')),
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            key: const ValueKey('danmaku-api-add'),
            onPressed: !_allowed || _saving || _sources.length >= 16
                ? null
                : () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('添加 API'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('danmaku-api-save'),
        onPressed: !_allowed || _saving
            ? null
            : () async {
                if (!_allowed) {
                  setState(() => _error = '当前用户已变更，请重新打开设置');
                  return;
                }
                setState(() => _saving = true);
                try {
                  await widget.session.configure(
                    widget.session.settings.copyWith(
                      baseUrl: _selected,
                      sources: _sources,
                    ),
                  );
                  if (context.mounted && _allowed) Navigator.pop(context, true);
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      _saving = false;
                      _error = '保存失败，请重试';
                    });
                  }
                }
              },
        child: Text(_saving ? '保存中…' : '保存'),
      ),
    ],
  );
}

class _DanmakuApiEditor extends StatefulWidget {
  const _DanmakuApiEditor({this.source});
  final DanmakuApiSource? source;
  @override
  State<_DanmakuApiEditor> createState() => _DanmakuApiEditorState();
}

class _DanmakuApiEditorState extends State<_DanmakuApiEditor> {
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late final _address = TextEditingController(
    text: widget.source?.baseUrl ?? '',
  );
  String? _error;
  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.source == null ? '添加弹幕 API' : '编辑弹幕 API'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('danmaku-api-name'),
            controller: _name,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          TextField(
            key: const ValueKey('danmaku-api-address'),
            controller: _address,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'danmu_api 兼容服务地址',
              hintText: 'https://服务器地址/可选路径或令牌',
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          try {
            Navigator.pop(
              context,
              DanmakuApiSource.fromJson({
                'name': _name.text,
                'baseUrl': _address.text,
              }),
            );
          } catch (error) {
            setState(
              () => _error = error is FormatException
                  ? error.message.toString()
                  : '请检查名称和地址',
            );
          }
        },
        child: const Text('确定'),
      ),
    ],
  );
  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }
}
