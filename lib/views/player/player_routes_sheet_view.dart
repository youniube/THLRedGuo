import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/utils/theme/app_theme.dart';

class PlayerRoutesSheetView extends StatelessWidget {
  const PlayerRoutesSheetView({
    super.key,
    required this.plan,
    required this.preferredRoute,
    required this.onSelected,
  });

  final PlaybackPlan plan;
  final String preferredRoute;
  final ValueChanged<int> onSelected;

  static Future<int?> show({
    required BuildContext context,
    required PlaybackPlan plan,
    required String preferredRoute,
    required bool mobile,
  }) {
    Widget content(BuildContext sheetContext) => Theme(
      data: AppTheme.dark,
      child: PlayerRoutesSheetView(
        plan: plan,
        preferredRoute: preferredRoute,
        onSelected: (index) => Navigator.pop(sheetContext, index),
      ),
    );
    if (mobile) {
      return showModalBottomSheet<int>(
        context: context,
        backgroundColor: AppTheme.dark.colorScheme.surface,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .75,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: content,
      );
    }
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: AppTheme.dark.colorScheme.surface,
        child: SizedBox(
          width: 480,
          height: math.min(600, MediaQuery.sizeOf(context).height * .75),
          child: content(dialogContext),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '播放线路',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '关闭线路列表',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '按源记住优先线路，后续各集沿用；缺集或播放失败时自动尝试备用线路。',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                ListTile(
                  key: const ValueKey('player-route-auto'),
                  title: const Text('自动选择'),
                  subtitle: const Text('按现有画质偏好和源返回顺序选择'),
                  selected: preferredRoute.isEmpty,
                  autofocus: preferredRoute.isEmpty,
                  leading: const Icon(Icons.auto_awesome_rounded),
                  trailing: preferredRoute.isEmpty
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => onSelected(-1),
                ),
                const Divider(height: 1),
                for (final route in plan.routes)
                  ListTile(
                    key: ValueKey('player-route-${route.index}'),
                    enabled: !route.expired,
                    autofocus:
                        preferredRoute.isNotEmpty &&
                        route.index == plan.routeIndex,
                    selected:
                        preferredRoute.isNotEmpty &&
                        route.key == preferredRoute,
                    leading: const Icon(Icons.alt_route_rounded),
                    title: Text(route.title),
                    subtitle: Text(
                      [
                        if (route.title != '线路 ${route.index + 1}')
                          '线路 ${route.index + 1}',
                        if (route.quality > 0) '${route.quality}P',
                        if (route.host.isNotEmpty) route.host,
                        if (preferredRoute.isNotEmpty &&
                            route.key == preferredRoute)
                          '已设为优先线路',
                        if (route.expired) '地址已过期',
                      ].join(' · '),
                    ),
                    trailing: route.index == plan.routeIndex
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow_rounded, size: 20),
                              Text('当前'),
                            ],
                          )
                        : null,
                    onTap: () => onSelected(route.index),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
