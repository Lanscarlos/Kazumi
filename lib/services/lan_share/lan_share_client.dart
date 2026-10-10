import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:path/path.dart' as path;

/// Talks to a [LanShareProtocol] server on another device.
class LanShareClient {
  LanShareClient({
    required this.host,
    required this.port,
    required this.deviceName,
    Duration connectTimeout = const Duration(seconds: 5),
  }) : _http = HttpClient()
          ..connectionTimeout = connectTimeout
          // LAN peers must never go through the user's internet proxy.
          ..findProxy = ((_) => 'DIRECT');

  final String host;
  final int port;
  final String deviceName;
  final HttpClient _http;
  final Set<HttpClientRequest> _active = {};
  String? _token;

  /// Parses `host[:port]`, defaulting to [LanShareProtocol.defaultPort].
  static ({String host, int port})? parseAddress(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains(' ')) {
      return null;
    }
    final uri = Uri.tryParse('http://$trimmed');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return (
      host: uri.host,
      port: uri.hasPort ? uri.port : LanShareProtocol.defaultPort,
    );
  }

  Future<LanShareInfo> fetchInfo() async {
    const notKazumi =
        LanShareException(LanShareErrorCode.notKazumi, '对方不是 Kazumi 共享服务');
    final Object? json;
    try {
      json = await _requestJson('GET', LanShareProtocol.infoPath, auth: false);
    } on FormatException {
      throw notKazumi;
    } on LanShareException catch (e) {
      if (e.code == LanShareErrorCode.connectFailed ||
          e.code == LanShareErrorCode.network) {
        rethrow;
      }
      throw notKazumi;
    }
    if (json is! Map<String, Object?>) throw notKazumi;
    final info = LanShareInfo.fromJson(json);
    if (info.app != LanShareProtocol.appId) throw notKazumi;
    if (info.protocolVersion != LanShareProtocol.version) {
      throw const LanShareException(
          LanShareErrorCode.versionMismatch, '两端协议版本不一致，请把两端升级到同一版本');
    }
    return info;
  }

  Future<void> pair(String code) async {
    final json = _asMap(await _requestJson(
      'POST',
      LanShareProtocol.pairPath,
      auth: false,
      body: {'code': code.trim(), 'deviceName': deviceName},
    ));
    final token = json['token'];
    if (token is! String || token.isEmpty) throw _invalidResponse;
    _token = token;
  }

  Future<LanShareManifest> fetchManifest() async => LanShareManifest.fromJson(
      _asMap(await _requestJson('GET', LanShareProtocol.manifestPath)));

  Future<LanShareEpisode> fetchEpisodeMeta(
          String recordKey, int episodeNumber) async =>
      LanShareEpisode.fromJson(_asMap(await _requestJson(
        'GET',
        LanShareProtocol.episodeMetaPath,
        query: LanShareProtocol.episodeQuery(recordKey, episodeNumber),
      )));

  Future<List<LanShareFile>> fetchEpisodeFiles(
      String recordKey, int episodeNumber) async {
    final json = _asMap(await _requestJson(
      'GET',
      LanShareProtocol.episodeFilesPath,
      query: LanShareProtocol.episodeQuery(recordKey, episodeNumber),
    ));
    final files = json['files'];
    if (files is! List) throw _invalidResponse;
    return [for (final file in files) LanShareFile.fromJson(_asMap(file))];
  }

  /// Downloads [file] into [directory] through a `.lstmp` part file, resuming
  /// a previous attempt. [onBytes] receives byte deltas, including bytes that
  /// were already on disk.
  Future<void> downloadFile({
    required String recordKey,
    required int episodeNumber,
    required LanShareFile file,
    required String directory,
    void Function(int delta)? onBytes,
  }) async {
    if (!LanShareProtocol.isSafeFileName(file.name)) {
      throw LanShareException(
          LanShareErrorCode.badName, '文件名无效：${file.name}');
    }
    final target = File(path.join(directory, file.name));
    if (await target.exists() && await target.length() == file.size) {
      onBytes?.call(file.size);
      return;
    }
    final partial = File('${target.path}${LanShareProtocol.partialSuffix}');
    if (!await partial.exists()) await partial.create(recursive: true);
    var offset = await partial.length();
    if (offset > file.size) {
      await partial.writeAsBytes(const [], flush: true);
      offset = 0;
    }
    onBytes?.call(offset);

    if (offset < file.size) {
      await _exchange(
        'GET',
        LanShareProtocol.episodeFilePath,
        query: {
          ...LanShareProtocol.episodeQuery(recordKey, episodeNumber),
          'name': file.name,
        },
        headers: {if (offset > 0) HttpHeaders.rangeHeader: 'bytes=$offset-'},
        consume: (response) async {
          final status = response.statusCode;
          if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
            throw _errorFrom(status, await utf8.decodeStream(response));
          }
          final append = status == HttpStatus.partialContent;
          if (!append && offset > 0) onBytes?.call(-offset);
          final sink =
              partial.openWrite(mode: append ? FileMode.append : FileMode.write);
          try {
            await for (final chunk in response) {
              sink.add(chunk);
              onBytes?.call(chunk.length);
            }
          } finally {
            await sink.close();
          }
        },
      );
    }

    final size = await partial.length();
    if (size < file.size) {
      // Keep the part file so the next attempt resumes from here.
      throw LanShareException(
          LanShareErrorCode.network, '传输中断：${file.name}');
    }
    if (size > file.size) {
      await partial.delete();
      throw LanShareException(
          LanShareErrorCode.sizeMismatch, '文件校验失败：${file.name}');
    }
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  }

  /// Aborts the requests in flight; the client stays usable afterwards.
  void cancelActive() {
    for (final request in _active.toList()) {
      request.abort(
          const LanShareException(LanShareErrorCode.cancelled, '已取消'));
    }
    _active.clear();
  }

  void close() {
    cancelActive();
    _http.close(force: true);
  }

  static const _invalidResponse =
      LanShareException(LanShareErrorCode.badRequest, '对方返回的数据无效');

  Map<String, Object?> _asMap(Object? value) {
    if (value is Map<String, Object?>) return value;
    throw _invalidResponse;
  }

  Future<Object?> _requestJson(
    String method,
    String route, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
  }) =>
      _exchange(
        method,
        route,
        query: query,
        body: body,
        auth: auth,
        consume: (response) async {
          final text = await utf8.decodeStream(response);
          if (response.statusCode != HttpStatus.ok) {
            throw _errorFrom(response.statusCode, text);
          }
          return jsonDecode(text);
        },
      );

  Future<T> _exchange<T>(
    String method,
    String route, {
    required Future<T> Function(HttpClientResponse response) consume,
    Map<String, String>? query,
    Object? body,
    bool auth = true,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: route,
        queryParameters: query);
    final HttpClientRequest request;
    try {
      request = await _http.openUrl(method, uri);
    } on SocketException catch (e) {
      throw LanShareException(
          LanShareErrorCode.connectFailed, '无法连接到 $host:$port（${e.message}）');
    } on HttpException catch (e) {
      throw LanShareException(
          LanShareErrorCode.connectFailed, '无法连接到 $host:$port（${e.message}）');
    }
    _active.add(request);
    try {
      final token = _token;
      if (auth && token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      return await consume(await request.close());
    } on SocketException catch (e) {
      throw LanShareException(LanShareErrorCode.network, '网络中断（${e.message}）');
    } on HttpException catch (e) {
      throw LanShareException(LanShareErrorCode.network, '网络中断（${e.message}）');
    } finally {
      _active.remove(request);
    }
  }

  LanShareException _errorFrom(int status, String text) {
    var code = LanShareErrorCode.badRequest;
    var message = '请求失败（HTTP $status）';
    try {
      final json = jsonDecode(text);
      if (json is Map) {
        final error = json['error'];
        final detail = json['message'];
        if (error is String) code = error;
        if (detail is String) message = detail;
      }
    } catch (_) {
      // Not a protocol error body; keep the generic message.
    }
    return LanShareException(code, message, statusCode: status);
  }
}
