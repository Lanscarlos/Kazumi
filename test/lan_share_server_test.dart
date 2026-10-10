import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/services/lan_share/lan_share_server.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

import 'support/lan_share_fixtures.dart';

void main() {
  late Directory root;
  late MemoryDownloadRepository phone;
  late LanShareServer server;
  late HttpClient http;
  final segment = bytesOf(1000);

  setUp(() async {
    Logger.level = Level.off;
    root = await Directory.systemTemp.createTemp('kazumi_lan_server_');
    final base = path.join(root.path, 'phone');
    phone = MemoryDownloadRepository();
    final done = await writeCompletedEpisode(
      base: base,
      episodeNumber: 1,
      files: {
        'playlist.m3u8': utf8.encode('#EXTM3U'),
        'seg_00000.ts': segment,
        'seg_00001.ts.tmp': [1],
        'key_0.key': bytesOf(16),
      },
      danmakuData: '[{"t":1}]',
    );
    final paused = await writeCompletedEpisode(
      base: base,
      episodeNumber: 2,
      files: {'seg_00000.ts': bytesOf(10)},
      status: DownloadStatus.paused,
    );
    await phone.putRecord(testRecord({1: done, 2: paused}));
    server = LanShareServer(
      repository: phone,
      deviceName: 'phone',
      port: 0,
      address: InternetAddress.loopbackIPv4,
      pairCooldown: const Duration(milliseconds: 200),
    );
    await server.start();
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.dispose();
    await root.delete(recursive: true);
  });

  Future<(int, Object?, HttpHeaders)> send(
    String method,
    String route, {
    Map<String, String>? query,
    Object? body,
    String? token,
    String? range,
  }) async {
    final request = await http.openUrl(
      method,
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.boundPort,
        path: route,
        queryParameters: query,
      ),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final bytes =
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    final isJson = response.headers.contentType?.mimeType == 'application/json';
    return (
      response.statusCode,
      isJson ? jsonDecode(utf8.decode(bytes)) : bytes,
      response.headers,
    );
  }

  Future<String> pair() async {
    final (status, body, _) = await send('POST', LanShareProtocol.pairPath,
        body: {'code': server.pairingCode, 'deviceName': 'pc'});
    expect(status, HttpStatus.ok);
    return (body as Map)['token'] as String;
  }

  Map<String, String> episode(int number, [String? name]) => {
        ...LanShareProtocol.episodeQuery('source_123', number),
        'name': ?name,
      };

  test('info needs no token and identifies Kazumi', () async {
    final (status, body, _) = await send('GET', LanShareProtocol.infoPath);
    expect(status, HttpStatus.ok);
    expect(body, {'app': 'kazumi', 'protocolVersion': 1, 'deviceName': 'phone'});
  });

  test('data endpoints reject missing or unknown tokens', () async {
    for (final token in [null, 'nope']) {
      final (status, body, _) =
          await send('GET', LanShareProtocol.manifestPath, token: token);
      expect(status, HttpStatus.unauthorized);
      expect((body as Map)['error'], LanShareErrorCode.unauthorized);
    }
  });

  test('pairing records the device name', () async {
    await pair();
    expect(server.connectedDevice, 'pc');
  });

  Future<(int, Object?, HttpHeaders)> tryCode(String code) =>
      send('POST', LanShareProtocol.pairPath, body: {'code': code});

  /// Sends wrong codes until the server rotates its pairing code.
  Future<void> exhaustAttempts() async {
    final wrong = server.pairingCode == '000000' ? '111111' : '000000';
    for (var i = 1; i < LanShareProtocol.maxPairFailures; i++) {
      final (status, body, _) = await tryCode(wrong);
      expect(status, HttpStatus.unauthorized);
      expect((body as Map)['error'], LanShareErrorCode.badCode);
    }
    final (status, body, _) = await tryCode(wrong);
    expect(status, HttpStatus.tooManyRequests);
    expect((body as Map)['error'], LanShareErrorCode.codeRotated);
  }

  test('five wrong codes replace the pairing code', () async {
    final original = server.pairingCode;
    await exhaustAttempts();
    expect(server.pairingCode, isNot(original));

    // The old code is dead (and attempts are refused during the cooldown).
    final (retryStatus, _, _) = await tryCode(original);
    expect(retryStatus, isNot(HttpStatus.ok));
  });

  test('pairing is refused during the cooldown, even with the right code',
      () async {
    await exhaustAttempts();

    final (status, body, _) = await tryCode(server.pairingCode);
    expect(status, HttpStatus.tooManyRequests);
    expect((body as Map)['error'], LanShareErrorCode.codeRotated);
    expect(body['message'], '错误次数过多，请稍后再试');
    expect(server.connectedDevice, isNull);

    await Future<void>.delayed(const Duration(milliseconds: 250));
    final (okStatus, okBody, _) = await tryCode(server.pairingCode);
    expect(okStatus, HttpStatus.ok);
    expect((okBody as Map)['token'], isNotEmpty);
  });

  test('the cooldown doubles with every rotation', () async {
    await exhaustAttempts();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await exhaustAttempts();

    // 250 ms is past the first cooldown (200 ms) but not the second (400 ms).
    await Future<void>.delayed(const Duration(milliseconds: 250));
    var (status, _, _) = await tryCode(server.pairingCode);
    expect(status, HttpStatus.tooManyRequests);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    (status, _, _) = await tryCode(server.pairingCode);
    expect(status, HttpStatus.ok);
  });

  test('restarting the share resets the cooldown', () async {
    await exhaustAttempts();
    await server.stop();
    await server.start();

    final (status, _, _) = await tryCode(server.pairingCode);
    expect(status, HttpStatus.ok);
  });

  test('manifest lists only completed episodes without danmaku', () async {
    final token = await pair();
    final (status, body, _) =
        await send('GET', LanShareProtocol.manifestPath, token: token);
    expect(status, HttpStatus.ok);
    final manifest = LanShareManifest.fromJson(body as Map<String, Object?>);
    expect(manifest.deviceName, 'phone');
    final record = manifest.records.single;
    expect(record.key, 'source_123');
    expect(record.episodes.map((e) => e.episodeNumber), [1]);
    expect(record.episodes.single.entryFileName, 'playlist.m3u8');
    expect(record.episodes.single.danmakuData, '');
  });

  test('episode meta carries danmaku', () async {
    final token = await pair();
    final (status, body, _) = await send(
        'GET', LanShareProtocol.episodeMetaPath,
        query: episode(1), token: token);
    expect(status, HttpStatus.ok);
    expect(LanShareEpisode.fromJson(body as Map<String, Object?>).danmakuData,
        '[{"t":1}]');
  });

  test('file list skips temporary files', () async {
    final token = await pair();
    final (status, body, _) = await send(
        'GET', LanShareProtocol.episodeFilesPath,
        query: episode(1), token: token);
    expect(status, HttpStatus.ok);
    final files = [
      for (final file in (body as Map)['files'] as List)
        LanShareFile.fromJson(file as Map<String, Object?>),
    ];
    expect(files.map((f) => f.name),
        ['key_0.key', 'playlist.m3u8', 'seg_00000.ts']);
    expect(files.last.size, 1000);
  });

  test('files download whole or from a byte offset', () async {
    final token = await pair();
    final (fullStatus, full, _) = await send(
        'GET', LanShareProtocol.episodeFilePath,
        query: episode(1, 'seg_00000.ts'), token: token);
    expect(fullStatus, HttpStatus.ok);
    expect(full, segment);

    final (partStatus, part, headers) = await send(
        'GET', LanShareProtocol.episodeFilePath,
        query: episode(1, 'seg_00000.ts'), token: token, range: 'bytes=400-');
    expect(partStatus, HttpStatus.partialContent);
    expect(part, segment.sublist(400));
    expect(headers.value(HttpHeaders.contentRangeHeader), 'bytes 400-999/1000');
    expect(server.bytesSent, 1000 + 600);

    final (badStatus, _, _) = await send(
        'GET', LanShareProtocol.episodeFilePath,
        query: episode(1, 'seg_00000.ts'), token: token, range: 'bytes=1000-');
    expect(badStatus, HttpStatus.requestedRangeNotSatisfiable);
  });

  test('unsafe or unlisted file names are rejected', () async {
    final token = await pair();
    for (final name in [
      '../../../etc/passwd',
      '..',
      'a/b',
      'seg_00001.ts.tmp',
      'missing.ts',
    ]) {
      final (status, body, _) = await send(
          'GET', LanShareProtocol.episodeFilePath,
          query: episode(1, name), token: token);
      expect(status, HttpStatus.badRequest, reason: name);
      expect((body as Map)['error'], LanShareErrorCode.badName);
    }
  });

  test('symlinks inside the episode directory are never served', () async {
    final token = await pair();
    final outside = File(path.join(root.path, 'secret.ts'));
    await outside.writeAsBytes(bytesOf(32));
    final directory = path.join(root.path, 'phone', '123_source', '1');
    await Link(path.join(directory, 'link.ts')).create(outside.path);

    final (status, body, _) = await send(
        'GET', LanShareProtocol.episodeFilePath,
        query: episode(1, 'link.ts'), token: token);
    expect(status, HttpStatus.badRequest);
    expect((body as Map)['error'], LanShareErrorCode.badName);
  });

  test('oversized pairing bodies are refused without counting as failures',
      () async {
    final original = server.pairingCode;
    final request = await http.openUrl(
      'POST',
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.boundPort,
        path: LanShareProtocol.pairPath,
      ),
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'code': original, 'padding': 'x' * 10000}));
    final response = await request.close();
    final body = jsonDecode(await utf8.decodeStream(response)) as Map;
    expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    expect(body['error'], LanShareErrorCode.badRequest);
    expect(server.pairingCode, original);

    // Not counted as a failure: the full failure budget is still available.
    final wrong = original == '000000' ? '111111' : '000000';
    for (var i = 1; i < LanShareProtocol.maxPairFailures; i++) {
      final (status, _, _) =
          await send('POST', LanShareProtocol.pairPath, body: {'code': wrong});
      expect(status, HttpStatus.unauthorized);
    }
    expect(server.pairingCode, original);
  });

  test('unfinished or unknown episodes are not found', () async {
    final token = await pair();
    for (final query in [
      episode(2),
      LanShareProtocol.episodeQuery('nope_1', 1),
      {'record': 'source_123'},
    ]) {
      final (status, body, _) = await send(
          'GET', LanShareProtocol.episodeMetaPath,
          query: query, token: token);
      expect(status, HttpStatus.notFound);
      expect((body as Map)['error'], LanShareErrorCode.notFound);
    }
  });

  test('restarting the share invalidates old tokens', () async {
    final token = await pair();
    await server.stop();
    await server.start();
    final (status, _, _) =
        await send('GET', LanShareProtocol.manifestPath, token: token);
    expect(status, HttpStatus.unauthorized);
  });
}
