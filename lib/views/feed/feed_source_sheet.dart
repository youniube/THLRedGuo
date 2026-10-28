import 'package:flutter/material.dart';

import 'package:THLRedLook/core/feed/video_feed_controller.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/feed/feed_source_selection.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';

Future<FeedSourceSelection?> showFeedSourceSheet(
  BuildContext context,
  VideoFeedController controller,
) => showModalBottomSheet<FeedSourceSelection>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (_) => _FeedSourceSheet(controller: controller),
);

class _FeedSourceSheet extends StatefulWidget {
  const _FeedSourceSheet({required this.controller});
  final VideoFeedController controller;

  @override
  State<_FeedSourceSheet> createState() => _FeedSourceSheetState();
}

class _FeedSourceSheetState extends State<_FeedSourceSheet> {
  bool _custom = false;
  late final _selected = widget.controller.selection.sources.toSet();

  Widget _option(
    BuildContext context,
    FeedSourceMode mode,
    String title,
    String subtitle,
  ) {
    final selected = widget.controller.selection.mode == mode;
    return ListTile(
      key: ValueKey('feed-mode-${mode.name}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(subtitle),
      ),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? AppColors.hongguoRed : Theme.of(context).hintColor,
      ),
      selected: selected,
      selectedColor: Theme.of(context).colorScheme.onSurface,
      onTap: () {
        if (mode == FeedSourceMode.custom) {
          setState(() => _custom = true);
        } else {
          Navigator.pop(
            context,
            FeedSourceSelection(
              mode: mode,
              sources: widget.controller.selection.sources,
            ),
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller.store,
    builder: (context, _) {
      final feed = widget.controller;
      final sources = feed.selectableSources;
      final availableIds = sources.map((source) => source.id).toSet();
      final chosen = _selected.where(availableIds.contains).toList();
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (_custom)
                      IconButton(
                        tooltip: '返回推荐源',
                        onPressed: () => setState(() => _custom = false),
                        icon: const Icon(Icons.arrow_back),
                      ),
                    Expanded(
                      child: Text(
                        _custom ? '自选站源' : '推荐源',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Flexible(
                  child: _custom
                      ? sources.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 32),
                                child: Text('暂无可参与混合推荐的站源'),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: sources.length,
                                itemBuilder: (context, index) {
                                  final source = sources[index];
                                  return CheckboxListTile(
                                    key: ValueKey('feed-source-${source.id}'),
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(source.name),
                                    value: _selected.contains(source.id),
                                    activeColor: AppColors.hongguoRed,
                                    onChanged: (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(source.id);
                                      } else {
                                        _selected.remove(source.id);
                                      }
                                    }),
                                  );
                                },
                              )
                      : SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _option(
                                context,
                                FeedSourceMode.discovery,
                                '跟随发现',
                                feed.store.sources.isEmpty
                                    ? '发现页暂无可用站源'
                                    : '当前：${SourceSite.byId(feed.store.source).name}',
                              ),
                              const Divider(height: 1),
                              _option(
                                context,
                                FeedSourceMode.all,
                                '全部站源',
                                '混合当前可用的 ${sources.length} 个站源',
                              ),
                              const Divider(height: 1),
                              _option(
                                context,
                                FeedSourceMode.custom,
                                '自选站源',
                                chosen.isEmpty
                                    ? '只推荐你勾选的站源'
                                    : '已选择 ${chosen.length} 个站源，点击调整',
                              ),
                            ],
                          ),
                        ),
                ),
                if (feed.store.privateSources.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '隐私站源仅通过发现页解锁后，在“跟随发现”中使用',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_custom) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('feed-apply-sources'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.hongguoRed,
                      ),
                      onPressed: chosen.isEmpty
                          ? null
                          : () => Navigator.pop(
                              context,
                              FeedSourceSelection(
                                mode: FeedSourceMode.custom,
                                sources: chosen,
                              ),
                            ),
                      child: Text('使用选中的 ${chosen.length} 个站源'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
