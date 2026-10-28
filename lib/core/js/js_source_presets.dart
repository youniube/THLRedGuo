// 预置短剧与影视 CatPawOpen Spider 数据源插件定义。
// 适配标准 CatPawOpen / CatVodOpen JS 规范，可在端侧沙箱及第三方播放器（如猫爪等）中独立运行。

import 'dart:io';
import 'package:flutter/services.dart';

class PresetJsSource {
  final String id;
  final String fileName;
  final String name;
  final String description;
  final String assetPath;

  const PresetJsSource({
    required this.id,
    required this.fileName,
    required this.name,
    required this.description,
    required this.assetPath,
  });

  /// 异步读取内嵌 JS 脚本内容
  /// 优先使用 Flutter rootBundle 从 Asset 资源束中加载；
  /// 在单元测试或无 Binding 纯 Dart 环境中，自动回退到本地文件加载。
  Future<String> loadScript() async {
    try {
      return await rootBundle.loadString(assetPath);
    } catch (_) {
      final file = File(assetPath);
      if (await file.exists()) {
        return await file.readAsString();
      }
      rethrow;
    }
  }

  /// 同步读取脚本（主要用于脱机、测试或需要同步获取的极端场景）
  String loadScriptSync() {
    final file = File(assetPath);
    return file.readAsStringSync();
  }

  /// 向后兼容 getter（建议使用 loadScript）
  @Deprecated('Use loadScript() instead')
  String get script => loadScriptSync();
}

const List<PresetJsSource> kPresetJsSources = [
  PresetJsSource(
    id: 'hongguo',
    fileName: 'hongguo.js',
    name: '官方免费短剧',
    description: '官方首发短剧源，包含海量都市爽文、战神回归、现代甜宠短剧',
    assetPath: 'assets/sources/hongguo.js',
  ),
];
