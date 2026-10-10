import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/lan_share/download_import_service.dart';
import 'package:kazumi/services/lan_share/lan_import_session.dart';
import 'package:kazumi/services/lan_share/lan_share_client.dart';
import 'package:kazumi/services/lan_share/lan_share_server.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as path;

import 'support/lan_share_fixtures.dart';

class _BaseDirManager extends DownloadManager {
  _BaseDirManager(this.base);

  final String base;

  @override
  Future<String> resolveDownloadBaseDir() async => base;
}

void main() {
  late Directory root;
  late String phoneBase;
  late String pcBase;
  late MemoryDownloadRepository phone;
  late LanShareServer server;
  late LanShareClient client;
  late DownloadImportService importer;
  final segment0 = bytesOf(5000, seed: 1);
  final segment1 = bytesOf(3000, seed: 2);
  final video = bytesOf(8000, seed: 3);

  setUpAll(() async {
    root = await setUpTestStorage('kazumi_lan_session_');
  });

  tearDownAll(() => tearDownTestStorage(root));

  setUp(() async {
    await GStorage.downloads.clear();
    final run = await Directory(root.path).createTemp('run_');
    phoneBase = path.join(run.path, 'phone');
    pcBase = path.join(run.path, 'pc');
    phone = MemoryDownloadRepository();
    final hls = await writeCompletedEpisode(
      base: phoneBase,
      episodeNumber: 1,
      files: {
        'playlist.m3u8': utf8.encode('#EXTM3U\nseg_00000.ts\nseg_00001.ts'),
        'seg_00000.ts': segment0,
        'seg_00001.ts': segment1,
      },
      danmakuData: '[{"t":1}]',
    );
    final mp4 = await writeCompletedEpisode(
      base: phoneBase,
      episodeNumber: 2,
      files: {'video.mp4': video},
      entry: 'video.mp4',
    );
    await phone.putRecord(testRecord({1: hls, 2: mp4}));
    server = LanShareServer(
      repository: phone,
      deviceName: 'phone',
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    await server.start();
    client = LanShareClient(
        host: '127.0.0.1', port: server.boundPort!, deviceName: 'pc');
    await client.pair(server.pairingCode);
    importer = DownloadImportService(DownloadRepository(), _BaseDirManager(pcBase));
  });

  tearDown(() async {
    client.close();
    await server.dispose();
  });

  Future<List<LanImportItem>> allItems() async => [
        for (final record in (await client.fetchManifest()).records)
          for (final episode in record.episodes) LanImportItem(record, episode),
      ];

  LanImportSession session(List<LanImportItem> items,
          {void Function()? onEpisodeImported}) =>
      LanImportSession(
        client: client,
        importer: importer,
        items: items,
        retryDelays: const [],
        reserveBytes: 0,
        onEpisodeImported: onEpisodeImported,
      );

  String pcEpisode(int number) => path.join(pcBase, '123_source', '$number');

  test('imports HLS and MP4 episodes end to end', () async {
    final items = await allItems();
    var imported = 0;
    await session(items, onEpisodeImported: () => imported++).run();

    expect(items.map((i) => i.status), everyElement(LanImportStatus.done));
    expect(imported, 2);
    expect(items.first.doneBytes, items.first.totalBytes);
    expect(await File(path.join(pcEpisode(1), 'seg_00000.ts')).readAsBytes(),
        segment0);
    expect(await File(path.join(pcEpisode(1), 'seg_00001.ts')).readAsBytes(),
        segment1);
    expect(await File(path.join(pcEpisode(2), 'video.mp4')).readAsBytes(), video);

    final record = GStorage.downloads.get('source_123')!;
    final manager = DownloadManager();
    expect(manager.getLocalVideoPath(record.episodes[1]),
        path.join(pcEpisode(1), 'playlist.m3u8'));
    expect(manager.getLocalVideoPath(record.episodes[2]),
        path.join(pcEpisode(2), 'video.mp4'));
    expect(record.episodes[1]!.danmakuData, '[{"t":1}]');
    expect(record.episodes[1]!.totalBytes, items.first.totalBytes);
    final leftovers = Directory(pcEpisode(1))
        .listSync()
        .where((e) => e.path.endsWith('.lstmp'));
    expect(leftovers, isEmpty);
  });

  test('skips episodes that are already complete locally', () async {
    final local = await writeCompletedEpisode(
        base: pcBase, episodeNumber: 1, files: {'playlist.m3u8': [1]});
    await GStorage.downloads.put('source_123', testRecord({1: local}));
    final items = await allItems();

    await session(items).run();

    expect(items.first.status, LanImportStatus.skipped);
    expect(items.first.error, '本地已存在');
    expect(items.last.status, LanImportStatus.done);
  });

  test('resumes a previously interrupted file', () async {
    await Directory(pcEpisode(1)).create(recursive: true);
    await File(path.join(pcEpisode(1), 'seg_00000.ts.lstmp'))
        .writeAsBytes(segment0.sublist(0, 2000));
    final items = (await allItems()).take(1).toList();

    await session(items).run();

    expect(items.single.status, LanImportStatus.done);
    expect(await File(path.join(pcEpisode(1), 'seg_00000.ts')).readAsBytes(),
        segment0);
    final playlistSize = utf8.encode('#EXTM3U\nseg_00000.ts\nseg_00001.ts').length;
    expect(server.bytesSent, playlistSize + 3000 + 3000);
  });

  test('replaces failed local leftovers and prunes stray files', () async {
    final failed = await writeCompletedEpisode(
        base: pcBase,
        episodeNumber: 1,
        files: {'seg_00099.ts': [9]},
        status: DownloadStatus.failed);
    await GStorage.downloads.put('source_123', testRecord({1: failed}));
    await Directory(pcEpisode(2)).create(recursive: true);
    await File(path.join(pcEpisode(2), 'stray.ts')).writeAsBytes([1]);

    final items = await allItems();
    await session(items).run();

    expect(items.map((i) => i.status), everyElement(LanImportStatus.done));
    expect(File(path.join(pcEpisode(1), 'seg_00099.ts')).existsSync(), isFalse);
    expect(File(path.join(pcEpisode(2), 'stray.ts')).existsSync(), isFalse);
    expect(GStorage.downloads.get('source_123')!.episodes[1]!.status,
        DownloadStatus.completed);
  });

  test('a vanished remote episode fails alone', () async {
    final items = await allItems();
    await File(phone.records['source_123']!.episodes[1]!.localM3u8Path).delete();

    await session(items).run();

    expect(items.first.status, LanImportStatus.failed);
    expect(items.first.error, '共享设备上该集已不存在');
    expect(items.last.status, LanImportStatus.done);
    expect(GStorage.downloads.get('source_123')!.episodes.keys, [2]);
  });

  test('losing the share device stops the remaining episodes', () async {
    final items = await allItems();
    await server.stop();

    await session(items).run();

    // The first failure may surface as a dropped keep-alive connection
    // (network) or a refused connection; either way nothing is imported.
    expect(items.map((i) => i.status), everyElement(LanImportStatus.failed));
    expect(GStorage.downloads.get('source_123'), isNull);
  });

  test('cancelling keeps finished episodes and stops the rest', () async {
    final items = await allItems();
    late LanImportSession running;
    running = session(items, onEpisodeImported: () => running.cancel());

    await running.run();

    expect(running.isCancelled, isTrue);
    expect(items.first.status, LanImportStatus.done);
    expect(items.last.status, LanImportStatus.waiting);
    expect(GStorage.downloads.get('source_123')!.episodes.keys, [1]);
  });

  test('insufficient storage stops before writing', () async {
    final items = await allItems();
    final tight = LanImportSession(
      client: client,
      importer: DownloadImportService(
          DownloadRepository(), _FullDiskManager(pcBase)),
      items: items,
      retryDelays: const [],
    );

    await tight.run();

    expect(items.first.status, LanImportStatus.failed);
    expect(items.first.error, '磁盘空间不足');
    expect(items.last.error, '已停止：磁盘空间不足');
    expect(File(path.join(pcEpisode(1), 'seg_00000.ts')).existsSync(), isFalse);
  });

  test('error descriptions are user friendly', () {
    expect(describeLanShareError(const LanShareInsufficientStorageException(2, 1)),
        '磁盘空间不足');
    expect(describeLanShareError(StateError('boom')), startsWith('导入失败'));
  });
}

class _FullDiskManager extends _BaseDirManager {
  _FullDiskManager(super.base);

  @override
  Future<int> getAvailableStorage(String path) async => 1024;
}
