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
    this.idleTimeout = const Duration(seconds: 30),
  }) : _http = HttpClient()
          ..connectionTimeout = connectTimeout
          ..idleTimeout = idleTimeout
          // LAN peers must never go through the user's internet proxy.
          ..findProxy = ((_) => 'DIRECT');

  final String host;
  final int port;
  final String deviceName;

  /// How long a peer may stay silent (no response headers, no body bytes)
  /// before the request is aborted. [connectTimeout] only covers connecting.
  final Duration idleTimeout;

  /// Upper bound for JSON (and error) response bodies read into memory.
  static const maxJsonBodyBytes = 32 * 1024 * 1024;
  final HttpClient _http;
  final Set<HttpClientRequest> _active = {};
  // Requests cut short by [cancelActive]. Aborting only ends the response
  // stream once headers arrived, so [_exchange] needs this to tell a
  // cancellation from a truncated body.
  final Set<HttpClientRequest> _aborted = {};
  // Bumped by [cancelActive]; lets a body loop stop even when abort() does not
  // interrupt data that was already buffered.
  int _cancelCount = 0;
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
    } on LanShareException catch (e) {
      if (e.code == LanShareErrorCode.connectFailed ||
          e.code == LanShareErrorCode.network ||
          e.code == LanShareErrorCode.cancelled) {
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
  /// were already on disk. The delta is negative (`-offset`) when the server
  /// ignores `Range` and resends the file from the start, so the running
  /// total stays equal to the bytes actually on disk.
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
        consume: (response, body, isCancelled) async {
          final status = response.statusCode;
          if (status == HttpStatus.requestedRangeNotSatisfiable && offset > 0) {
            // The part file no longer fits the source; drop it so the next
            // attempt restarts from zero instead of failing the same way.
            await body.drain<void>();
            await partial.delete();
            throw LanShareException(
                LanShareErrorCode.sizeMismatch, '文件校验失败：${file.name}');
          }
          if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
            throw _errorFrom(status, await _readText(response, body));
          }
          final append = status == HttpStatus.partialContent;
          if (!append && offset > 0) onBytes?.call(-offset);
          // A peer must not be able to fill the disk with more than it
          // declared, so stop before the first byte past the expected size.
          final expected = file.size - (append ? offset : 0);
          var received = 0;
          var oversize = false;
          final sink =
              partial.openWrite(mode: append ? FileMode.append : FileMode.write);
          try {
            await for (final chunk in body) {
              if (isCancelled()) break;
              if (received + chunk.length > expected) {
                oversize = true;
                break;
              }
              received += chunk.length;
              sink.add(chunk);
              onBytes?.call(chunk.length);
            }
          } finally {
            await sink.close();
          }
          if (oversize) {
            await partial.delete();
            throw LanShareException(
                LanShareErrorCode.sizeMismatch, '文件校验失败：${file.name}');
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
    _cancelCount++;
    for (final request in _active.toList()) {
      _aborted.add(request);
      request.abort(_cancelled);
    }
    _active.clear();
  }

  void close() {
    cancelActive();
    _http.close(force: true);
  }

  static const _cancelled =
      LanShareException(LanShareErrorCode.cancelled, '已取消');

  static const _stalled =
      LanShareException(LanShareErrorCode.network, '网络中断（对方长时间无响应）');

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
        consume: (response, body, isCancelled) async {
          try {
            final text = await _readText(response, body);
            if (response.statusCode != HttpStatus.ok) {
              throw _errorFrom(response.statusCode, text);
            }
            return jsonDecode(text);
          } on FormatException {
            throw _invalidResponse;
          }
        },
      );

  /// Reads a small text body, refusing peers that send more than
  /// [maxJsonBodyBytes].
  Future<String> _readText(
      HttpClientResponse response, Stream<List<int>> body) async {
    const tooLarge =
        LanShareException(LanShareErrorCode.badRequest, '对方返回的数据过大');
    if (response.contentLength > maxJsonBodyBytes) throw tooLarge;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body) {
      bytes.add(chunk);
      if (bytes.length > maxJsonBodyBytes) throw tooLarge;
    }
    return utf8.decode(bytes.takeBytes());
  }

  /// Runs one request. [consume] reads the response through [body], which
  /// fails with a [TimeoutException] once the peer is silent for
  /// [idleTimeout]; its `isCancelled` reports whether [cancelActive] ran since
  /// this call started.
  Future<T> _exchange<T>(
    String method,
    String route, {
    required Future<T> Function(HttpClientResponse response,
            Stream<List<int>> body, bool Function() isCancelled)
        consume,
    Map<String, String>? query,
    Object? body,
    bool auth = true,
    Map<String, String> headers = const {},
  }) async {
    final cancelCount = _cancelCount;
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
      // cancelActive() may have run while the connection was opening, when
      // this request was not registered yet.
      if (_cancelCount != cancelCount) {
        request.abort(_cancelled);
        throw _cancelled;
      }
      // A peer must not be able to redirect our bearer token elsewhere.
      request.followRedirects = false;
      final token = _token;
      if (auth && token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(idleTimeout);
      final result = await consume(
        response,
        response.timeout(idleTimeout),
        () => _cancelCount != cancelCount,
      );
      // An aborted body just ends early, so consume may "succeed" on partial
      // data; the cancellation wins regardless.
      if (_aborted.contains(request)) throw _cancelled;
      return result;
    } on Object catch (e) {
      if (_aborted.contains(request)) throw _cancelled;
      if (e is TimeoutException) {
        request.abort(_stalled);
        throw _stalled;
      }
      if (e is LanShareException) {
        // Stop reading a response we gave up on (oversized, bad status).
        request.abort(e);
        rethrow;
      }
      if (e is SocketException) {
        throw LanShareException(
            LanShareErrorCode.network, '网络中断（${e.message}）');
      }
      if (e is HttpException) {
        throw LanShareException(
            LanShareErrorCode.network, '网络中断（${e.message}）');
      }
      rethrow;
    } finally {
      _active.remove(request);
      _aborted.remove(request);
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
