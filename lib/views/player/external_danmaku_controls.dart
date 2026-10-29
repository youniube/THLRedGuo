import 'package:flutter/material.dart';

import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/models/danmaku/external_danmaku_models.dart';

Future<bool> editDanmakuApi(
  BuildContext context,
  ExternalDanmakuSession session,
) async {
  final controller = TextEditingController(text: session.settings.baseUrl);
  String? error;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('通用弹幕 API'),
        content: SizedBox(
          width: 480,
          child: TextField(
            key: const ValueKey('danmaku-api-address'),
            controller: controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'danmu_api 兼容服务地址',
              hintText: 'https://服务器地址/可选路径或令牌',
              errorText: error,
              helperText: '填写你自己的服务地址，留空停用通用弹幕。',
              helperMaxLines: 2,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                final value = ExternalDanmakuSettings.fromJson({
                  'baseUrl': controller.text,
                  'mode': session.settings.mode,
                });
                await session.configure(value);
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              } catch (exception) {
                setState(
                  () => error = exception is FormatException
                      ? exception.message.toString()
                      : '设置保存失败',
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result == true;
}

class ExternalDanmakuControls extends StatelessWidget {
  const ExternalDanmakuControls({
    super.key,
    required this.session,
    required this.onChanged,
  });
  final ExternalDanmakuSession session;
  final VoidCallback onChanged;

  Future<void> _offset(BuildContext context) async {
    final mediaKey = session.media?.key;
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
    if (value != null && session.media?.key == mediaKey) {
      await session.setOffset(value);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('弹幕来源')),
            IconButton(
              tooltip: '配置通用弹幕 API',
              onPressed: () async {
                if (await editDanmakuApi(context, session)) onChanged();
              },
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        DropdownButtonFormField<String>(
          isExpanded: true,
          key: ValueKey('danmaku-mode-${session.settings.mode}'),
          initialValue: session.settings.mode,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: 'automatic',
              child: Text(
                '自动：优先原站，否则通用 API',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(value: 'native', child: Text('仅使用原站弹幕')),
            DropdownMenuItem(value: 'external', child: Text('使用通用弹幕 API')),
          ],
          onChanged: (mode) async {
            if (mode == null) return;
            await session.configure(
              ExternalDanmakuSettings(
                baseUrl: session.settings.baseUrl,
                mode: mode,
              ),
            );
            onChanged();
          },
        ),
        const SizedBox(height: 8),
        Text(
          session.status.isNotEmpty
              ? session.status
              : session.available
              ? '通用 API 已配置，按作品和分集匹配'
              : '通用 API 尚未配置',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: !session.available
                  ? null
                  : () async {
                      final changed = await showDialog<bool>(
                        context: context,
                        builder: (_) => _DanmakuSearchDialog(session: session),
                      );
                      if (changed == true) onChanged();
                    },
              child: const Text('手动搜索 / 选择弹幕'),
            ),
            TextButton(
              onPressed: session.media == null
                  ? null
                  : () async {
                      await session.reset();
                      onChanged();
                    },
              child: const Text('重新匹配'),
            ),
            TextButton(
              onPressed: session.media == null ? null : () => _offset(context),
              child: Text('时间偏移 ${session.offsetMs / 1000}s'),
            ),
          ],
        ),
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
