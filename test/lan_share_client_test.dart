import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/lan_share/lan_share_client.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/services/lan_share/lan_share_server.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

import 'support/lan_share_fixtures.dart';

Matcher _code(String code) =>
    isA<LanShareException>().having((e) => e.code, 'code', code);

void main() {
  late Directory root;
  late String target;
  late LanShareServer server;
  late LanShareClient client;
  final segment = bytesOf(1000, seed: 3);

  setUp(() async {
    Logger.level = Level.off;
    root = await Directory.systemTemp.createTemp('kazumi_lan_client_');
    target = path.join(root.path, 'pc', 'episode');
    await Directory(target).create(recursive: true);
    final phone = MemoryDownloadRepository();
    final episode = await writeCompletedEpisode(
      base: path.join(root.path, 'phone'),
      episodeNumber: 1,
      files: {'playlist.m3u8': utf8.encode('#EXTM3U'), 'seg_00000.ts': segment},
    );
    await phone.putRecord(testRecord({1: episode}));
    server = LanShareServer(
      repository: phone,
      deviceName: 'phone',
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    await server.start();
    client = LanShareClient(
        host: '127.0.0.1', port: server.boundPort!, deviceName: 'pc');
  });

  tearDown(() async {
    client.close();
    await server.dispose();
    await root.delete(recursive: true);
  });

  const segmentFile = LanShareFile(name: 'seg_00000.ts', size: 1000);

  Future<int> download({LanShareFile file = segmentFile}) async {
    var reported = 0;
    await client.downloadFile(
      recordKey: 'source_123',
      episodeNumber: 1,
      file: file,
      directory: target,
      onBytes: (delta) => reported += delta,
    );
    return reported;
  }

  group('parseAddress', () {
    test('accepts host with or without port', () {
      expect(LanShareClient.parseAddress(' 192.168.1.5:40000 '),
          (host: '192.168.1.5', port: 40000));
      expect(LanShareClient.parseAddress('192.168.1.5'),
          (host: '192.168.1.5', port: LanShareProtocol.defaultPort));
    });

    test('rejects garbage', () {
      for (final input in ['', 'http://x/y', '1.2.3.4/path', 'a b']) {
        expect(LanShareClient.parseAddress(input), isNull, reason: input);
      }
    });
  });

  test('connects, pairs and reads the manifest', () async {
    final info = await client.fetchInfo();
    expect(info.deviceName, 'phone');
    await client.pair(server.pairingCode);
    expect(server.connectedDevice, 'pc');
    final manifest = await client.fetchManifest();
    expect(manifest.records.single.episodes.single.episodeNumber, 1);
    final files = await client.fetchEpisodeFiles('source_123', 1);
    expect(files.map((f) => f.name), ['playlist.m3u8', 'seg_00000.ts']);
    final meta = await client.fetchEpisodeMeta('source_123', 1);
    expect(meta.entryFileName, 'playlist.m3u8');
  });

  test('a wrong code is reported as bad_code', () async {
    final wrong = server.pairingCode == '000000' ? '111111' : '000000';
    await expectLater(client.pair(wrong), throwsA(_code(LanShareErrorCode.badCode)));
  });

  test('requests without pairing are unauthorized', () async {
    await expectLater(
        client.fetchManifest(), throwsA(_code(LanShareErrorCode.unauthorized)));
  });

  test('a closed port is reported as connect_failed', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final offline =
        LanShareClient(host: '127.0.0.1', port: port, deviceName: 'pc');
    addTearDown(offline.close);
    await expectLater(
        offline.fetchInfo(), throwsA(_code(LanShareErrorCode.connectFailed)));
  });

  test('a non-Kazumi server is rejected', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    other.listen((request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write('<html></html>')
        ..close();
    });
    addTearDown(() => other.close(force: true));
    final stranger =
        LanShareClient(host: '127.0.0.1', port: other.port, deviceName: 'pc');
    addTearDown(stranger.close);
    await expectLater(
        stranger.fetchInfo(), throwsA(_code(LanShareErrorCode.notKazumi)));
  });

  test('downloads a file and reports every byte', () async {
    await client.pair(server.pairingCode);
    expect(await download(), 1000);
    expect(await File(path.join(target, 'seg_00000.ts')).readAsBytes(), segment);
    expect(File(path.join(target, 'seg_00000.ts.lstmp')).existsSync(), isFalse);
  });

  test('resumes from a partial file', () async {
    await client.pair(server.pairingCode);
    await File(path.join(target, 'seg_00000.ts.lstmp'))
        .writeAsBytes(segment.sublist(0, 300));

    expect(await download(), 1000);

    expect(await File(path.join(target, 'seg_00000.ts')).readAsBytes(), segment);
    expect(server.bytesSent, 700);
  });

  test('skips a file that is already complete', () async {
    await client.pair(server.pairingCode);
    await File(path.join(target, 'seg_00000.ts')).writeAsBytes(segment);

    expect(await download(), 1000);
    expect(server.bytesSent, 0);
  });

  test('restarts when the partial file is larger than the source', () async {
    await client.pair(server.pairingCode);
    await File(path.join(target, 'seg_00000.ts.lstmp'))
        .writeAsBytes(bytesOf(1500));

    expect(await download(), 1000);
    expect(await File(path.join(target, 'seg_00000.ts')).readAsBytes(), segment);
  });

  test('refuses unsafe file names before touching the disk', () async {
    await client.pair(server.pairingCode);
    await expectLater(
      download(file: const LanShareFile(name: '../evil', size: 1)),
      throwsA(_code(LanShareErrorCode.badName)),
    );
  });
}
