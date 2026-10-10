import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path/path.dart' as path;

class LanSharePortUnavailableException implements Exception {
  @override
  String toString() => '无法开启共享：端口被占用';
}

/// Name shown to the other device, e.g. "Windows · DESKTOP-1".
String localDeviceName() {
  final os = Platform.isAndroid
      ? 'Android'
      : Platform.isWindows
          ? 'Windows'
          : Platform.isMacOS
              ? 'macOS'
              : Platform.isIOS
                  ? 'iOS'
                  : Platform.isLinux
                      ? 'Linux'
                      : Platform.operatingSystem;
  final host = Platform.localHostname;
  return host.isEmpty || host == 'localhost' ? os : '$os · $host';
}

class _RequestTooLarge implements Exception {}

typedef _SharedEpisode = ({
  DownloadRecord record,
  int episodeNumber,
  DownloadEpisode episode,
});

/// Serves completed downloads to other Kazumi devices on the LAN.
class LanShareServer {
  LanShareServer({
    required IDownloadRepository repository,
    String? deviceName,
    this.port = LanShareProtocol.defaultPort,
    InternetAddress? address,
    Random? random,
    this.pairCooldown = const Duration(seconds: 30),
    Duration Function()? elapsed,
  })  : _repository = repository,
        deviceName = deviceName ?? localDeviceName(),
        _address = address ?? InternetAddress.anyIPv4,
        _random = random ?? Random.secure(),
        _elapsed = elapsed ?? _monotonicClock();

  static Duration Function() _monotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final IDownloadRepository _repository;
  final String deviceName;

  /// First port to try; 0 lets the OS choose.
  final int port;
  final InternetAddress _address;
  final Random _random;

  /// Monotonic time since an arbitrary start, so the pairing cooldown is not
  /// affected by wall-clock changes. Injectable for tests.
  final Duration Function() _elapsed;

  /// How long pairing is refused after the first code rotation; doubles with
  /// every further rotation (capped at [_maxPairCooldown]) until the share is
  /// restarted. Rotating alone would not bound guesses.
  final Duration pairCooldown;
  static const _maxPairCooldown = Duration(minutes: 10);

  static final _rangePattern = RegExp(r'^bytes=(\d+)-$');

  /// Upper bound for the (unauthenticated) pairing request body.
  static const _maxJsonBodyBytes = 4 * 1024;

  HttpServer? _server;
  String _pairingCode = '';
  int _pairFailures = 0;
  Duration? _pairBlockedUntil;
  late Duration _nextPairCooldown = pairCooldown;
  final Set<String> _tokens = {};
  String? _connectedDevice;
  int _activeTransfers = 0;
  int _bytesSent = 0;
  final _changes = StreamController<void>.broadcast();

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  String get pairingCode => _pairingCode;
  String? get connectedDevice => _connectedDevice;
  int get activeTransfers => _activeTransfers;
  int get bytesSent => _bytesSent;

  /// Emits when the pairing code, connected device or transfers change.
  Stream<void> get changes => _changes.stream;

  Future<void> start() async {
    if (_server != null) return;
    final candidates = port == 0
        ? const [0]
        : [for (var i = 0; i < LanShareProtocol.portAttempts; i++) port + i];
    HttpServer? server;
    for (final candidate in candidates) {
      try {
        server = await HttpServer.bind(_address, candidate);
        break;
      } on SocketException catch (e) {
        KazumiLogger()
            .w('LanShareServer: port $candidate unavailable', error: e);
      }
    }
    if (server == null) throw LanSharePortUnavailableException();
    _server = server;
    _rotatePairingCode();
    _pairBlockedUntil = null;
    _nextPairCooldown = pairCooldown;
    _tokens.clear();
    _connectedDevice = null;
    _bytesSent = 0;
    server.listen(
      _handle,
      onError: (Object e) =>
          KazumiLogger().w('LanShareServer: listener failed', error: e),
    );
    _notify();
  }

  /// Stops serving; every issued token and the pairing code become invalid.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _tokens.clear();
    _pairingCode = '';
    _connectedDevice = null;
    await server?.close(force: true);
    _notify();
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  /// IPv4 addresses other devices on the LAN can reach.
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.isLoopback && !address.isLinkLocal) address.address,
      ];
    } catch (e) {
      KazumiLogger().w('LanShareServer: failed to list addresses', error: e);
      return const [];
    }
  }

  void _rotatePairingCode() {
    _pairingCode = LanShareProtocol.generatePairingCode(_random);
    _pairFailures = 0;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final route = request.uri.path;
      if (request.method == 'GET' && route == LanShareProtocol.infoPath) {
        await _sendJson(
          response,
          HttpStatus.ok,
          LanShareInfo(
            app: LanShareProtocol.appId,
            protocolVersion: LanShareProtocol.version,
            deviceName: deviceName,
          ).toJson(),
        );
        return;
      }
      if (request.method == 'POST' && route == LanShareProtocol.pairPath) {
        await _pair(request);
        return;
      }
      if (!_isAuthorized(request)) {
        await _sendError(response, HttpStatus.unauthorized,
            LanShareErrorCode.unauthorized, '未授权，请重新输入配对码');
        return;
      }
      if (request.method == 'GET') {
        switch (route) {
          case LanShareProtocol.manifestPath:
            await _sendManifest(response);
            return;
          case LanShareProtocol.episodeMetaPath:
            await _sendEpisodeMeta(request);
            return;
          case LanShareProtocol.episodeFilesPath:
            await _sendEpisodeFiles(request);
            return;
          case LanShareProtocol.episodeFilePath:
            await _sendFile(request);
            return;
        }
      }
      await _sendError(response, HttpStatus.notFound,
          LanShareErrorCode.notFound, '接口不存在');
    } catch (e, stackTrace) {
      KazumiLogger().w('LanShareServer: request ${request.uri.path} failed',
          error: e, stackTrace: stackTrace);
      try {
        await _sendError(response, HttpStatus.internalServerError,
            LanShareErrorCode.internal, '共享设备内部错误');
      } catch (_) {
        // Headers were already sent (e.g. the client dropped mid-file).
        try {
          await response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _pair(HttpRequest request) async {
    final Map<String, Object?> body;
    try {
      body = await _readJson(request);
    } on _RequestTooLarge {
      // Not a pairing attempt, so it does not count towards the failure limit.
      await _sendError(request.response, HttpStatus.requestEntityTooLarge,
          LanShareErrorCode.badRequest, '请求过大');
      return;
    }
    final blockedUntil = _pairBlockedUntil;
    if (blockedUntil != null && _elapsed() < blockedUntil) {
      // Refused without looking at the code, so guesses cannot be paced by
      // rotating the code.
      await _sendError(request.response, HttpStatus.tooManyRequests,
          LanShareErrorCode.codeRotated, '错误次数过多，请稍后再试');
      return;
    }
    final code = body['code'];
    if (_pairingCode.isNotEmpty && code is String && code == _pairingCode) {
      final token = LanShareProtocol.generateToken(_random);
      _tokens.add(token);
      final name = body['deviceName'];
      _connectedDevice = name is String && name.isNotEmpty
          ? name
          : request.connectionInfo?.remoteAddress.address;
      _notify();
      await _sendJson(request.response, HttpStatus.ok, {'token': token});
      return;
    }
    _pairFailures++;
    if (_pairFailures >= LanShareProtocol.maxPairFailures) {
      _rotatePairingCode();
      _pairBlockedUntil = _elapsed() + _nextPairCooldown;
      _nextPairCooldown = _nextPairCooldown * 2 > _maxPairCooldown
          ? _maxPairCooldown
          : _nextPairCooldown * 2;
      _notify();
      await _sendError(request.response, HttpStatus.tooManyRequests,
          LanShareErrorCode.codeRotated, '错误次数过多，配对码已刷新');
      return;
    }
    await _sendError(request.response, HttpStatus.unauthorized,
        LanShareErrorCode.badCode, '配对码错误');
  }

  /// Reads a small JSON object body; throws [_RequestTooLarge] past the cap.
  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    if (request.contentLength > _maxJsonBodyBytes) throw _RequestTooLarge();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      // Also covers chunked bodies that do not declare a length up front.
      if (bytes.length > _maxJsonBodyBytes) throw _RequestTooLarge();
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    return _tokens.contains(header.substring('Bearer '.length));
  }

  bool _isShareable(DownloadEpisode episode) =>
      episode.status == DownloadStatus.completed &&
      episode.localM3u8Path.isNotEmpty &&
      File(episode.localM3u8Path).existsSync();

  _SharedEpisode? _findEpisode(Uri uri) {
    final key = uri.queryParameters['record'];
    final episodeNumber = int.tryParse(uri.queryParameters['ep'] ?? '');
    if (key == null || episodeNumber == null) return null;
    final record = _repository.getRecord(key);
    final episode = record?.episodes[episodeNumber];
    if (record == null || episode == null || !_isShareable(episode)) {
      return null;
    }
    return (record: record, episodeNumber: episodeNumber, episode: episode);
  }

  Future<void> _sendManifest(HttpResponse response) async {
    final records = <LanShareRecord>[];
    for (final record in _repository.getAllRecords()) {
      final episodes = [
        for (final entry in record.episodes.entries)
          if (_isShareable(entry.value))
            LanShareEpisode.fromDownload(entry.key, entry.value),
      ]..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
      if (episodes.isNotEmpty) {
        records.add(LanShareRecord.fromDownload(record, episodes));
      }
    }
    records.sort((a, b) => a.bangumiName.compareTo(b.bangumiName));
    await _sendJson(
      response,
      HttpStatus.ok,
      LanShareManifest(
        protocolVersion: LanShareProtocol.version,
        deviceName: deviceName,
        records: records,
      ).toJson(),
    );
  }

  Future<void> _sendEpisodeMeta(HttpRequest request) async {
    final found = _findEpisode(request.uri);
    if (found == null) {
      await _sendNotFound(request.response);
      return;
    }
    await _sendJson(
      request.response,
      HttpStatus.ok,
      LanShareEpisode.fromDownload(found.episodeNumber, found.episode,
              includeDanmaku: true)
          .toJson(),
    );
  }

  Future<void> _sendEpisodeFiles(HttpRequest request) async {
    final found = _findEpisode(request.uri);
    if (found == null) {
      await _sendNotFound(request.response);
      return;
    }
    final files = await _listFiles(path.dirname(found.episode.localM3u8Path));
    await _sendJson(request.response, HttpStatus.ok, {
      'files': [for (final file in files) file.toJson()],
    });
  }

  Future<void> _sendFile(HttpRequest request) async {
    final response = request.response;
    final found = _findEpisode(request.uri);
    if (found == null) {
      await _sendNotFound(response);
      return;
    }
    final name = request.uri.queryParameters['name'] ?? '';
    final directory = path.dirname(found.episode.localM3u8Path);
    final file = File(path.join(directory, name));
    // Checked per file (no directory scan): HLS episodes have thousands of
    // segments. Symlinks are never served, only regular files directly in
    // the episode directory.
    final servable = LanShareProtocol.isSafeFileName(name) &&
        !LanShareProtocol.isTransientFileName(name) &&
        path.isWithin(directory, file.path) &&
        await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file;
    if (!servable) {
      await _sendError(response, HttpStatus.badRequest,
          LanShareErrorCode.badName, '文件名无效');
      return;
    }

    final length = await file.length();
    var start = 0;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final parsed =
          int.tryParse(_rangePattern.firstMatch(range.trim())?.group(1) ?? '');
      if (parsed == null || parsed >= length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      start = parsed;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $start-${length - 1}/$length');
    } else {
      response.statusCode = HttpStatus.ok;
    }
    response.headers.contentType = ContentType.binary;
    response.headers.contentLength = length - start;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    _activeTransfers++;
    _notify();
    try {
      await response.addStream(file.openRead(start).map((chunk) {
        _bytesSent += chunk.length;
        return chunk;
      }));
      await response.close();
    } finally {
      _activeTransfers--;
      _notify();
    }
  }

  Future<List<LanShareFile>> _listFiles(String directory) async {
    final files = <LanShareFile>[];
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (!LanShareProtocol.isSafeFileName(name) ||
          LanShareProtocol.isTransientFileName(name)) {
        continue;
      }
      files.add(LanShareFile(name: name, size: await entity.length()));
    }
    files.sort((a, b) => a.name.compareTo(b.name));
    return files;
  }

  Future<void> _sendNotFound(HttpResponse response) => _sendError(response,
      HttpStatus.notFound, LanShareErrorCode.notFound, '该集不存在或尚未下载完成');

  Future<void> _sendError(
          HttpResponse response, int status, String code, String message) =>
      _sendJson(response, status, {'error': code, 'message': message});

  Future<void> _sendJson(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
