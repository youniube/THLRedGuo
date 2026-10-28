import 'dart:convert';

import 'package:THLRedLook/core/js/js_source_models.dart';

class JsSubscriptionSource {
  const JsSubscriptionSource({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id, name, url;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};
}

class JsSourceSubscription {
  const JsSourceSubscription({
    required this.name,
    required this.url,
    required this.sources,
  });

  final String name, url;
  final List<JsSubscriptionSource> sources;

  factory JsSourceSubscription.parse(String text, String url) =>
      JsSourceSubscription.fromJson(jsonDecode(text), url);

  factory JsSourceSubscription.fromJson(dynamic json, String url) {
    if (json is! Map || json['sources'] is! List) {
      throw const FormatException('合集清单须为包含 sources 列表的 JSON 对象');
    }
    if (json['version'] != null && json['version'] != 1) {
      throw const FormatException('不支持此合集清单版本，请使用 version: 1');
    }
    final base = parseUrl(url);
    final items = json['sources'] as List;
    if (items.length > 128) {
      throw const FormatException('一个合集最多支持 128 个数据源');
    }
    final ids = <String>{};
    final sources = <JsSubscriptionSource>[];
    for (final item in items) {
      if (item is! Map || item['id'] is! String || item['url'] is! String) {
        throw const FormatException('合集中的每个源须填写 id 和 url');
      }
      final id = (item['id'] as String).trim();
      final link = (item['url'] as String).trim();
      if (id.isEmpty || link.isEmpty) {
        throw const FormatException('合集中的源 ID 和链接不能为空');
      }
      if (!ids.add(id)) throw FormatException('合集存在重复的源 ID：$id');
      final sourceUrl = parseUrl(base.resolve(link).toString()).toString();
      final name = item['name'] is String
          ? (item['name'] as String).trim()
          : '';
      sources.add(
        JsSubscriptionSource(
          id: id,
          name: name.isEmpty ? id : name,
          url: sourceUrl,
        ),
      );
    }
    final name = json['name'] is String ? (json['name'] as String).trim() : '';
    return JsSourceSubscription(
      name: name.isEmpty ? base.host : name,
      url: base.toString(),
      sources: List.unmodifiable(sources),
    );
  }

  static Uri parseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 脚本或合集清单直链');
    }
    return uri.removeFragment();
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'name': name,
    'url': url,
    'sources': sources.map((source) => source.toJson()).toList(),
  };
}

class JsSubscriptionImportResult {
  const JsSubscriptionImportResult({
    required this.subscription,
    required this.results,
  });

  final JsSourceSubscription subscription;
  final List<JsSourceUpdateResult> results;

  factory JsSubscriptionImportResult.fromJson(Map<String, dynamic> json) {
    final subscription = Map<String, dynamic>.from(json['subscription'] as Map);
    return JsSubscriptionImportResult(
      subscription: JsSourceSubscription.fromJson(
        subscription,
        subscription['url'] as String,
      ),
      results: (json['results'] as List)
          .map(
            (item) => JsSourceUpdateResult.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}
