import 'package:http/http.dart' as http;

class SourceHttpClient extends http.BaseClient {
  SourceHttpClient({http.Client Function()? createClient})
    : _createClient = createClient ?? http.Client.new {
    _current = _createClient();
  }

  final http.Client Function() _createClient;
  late http.Client _current;
  final _active = <http.Client, int>{};
  bool _closed = false;

  void refresh() {
    if (_closed) return;
    final previous = _current;
    _current = _createClient();
    if (!_active.containsKey(previous)) previous.close();
  }

  void _release(http.Client client) {
    final count = _active[client];
    if (count == null) return;
    if (count > 1) {
      _active[client] = count - 1;
    } else {
      _active.remove(client);
      if (!identical(client, _current)) client.close();
    }
  }

  Stream<List<int>> _readResponse(
    http.Client client,
    Stream<List<int>> stream,
  ) async* {
    try {
      yield* stream;
    } finally {
      _release(client);
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('站源网络客户端已关闭', request.url);
    final client = _current;
    _active[client] = (_active[client] ?? 0) + 1;
    try {
      final response = await client.send(request);
      return http.StreamedResponse(
        _readResponse(client, response.stream),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      _release(client);
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final clients = {..._active.keys, _current};
    _active.clear();
    for (final client in clients) {
      client.close();
    }
  }
}
