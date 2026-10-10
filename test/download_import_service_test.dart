import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/lan_share/download_import_service.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as path;

import 'support/lan_share_fixtures.dart';

class _BaseDirManager extends DownloadManager {
  _BaseDirManager(this.base);

  final String base;

  @override
  Future<String> resolveDownloadBaseDir() async => base;
}

LanShareRecord _remote({String pluginName = 'source'}) => LanShareRecord(
  bangumiId: 123,
  bangumiName: 'Test Anime',
  bangumiCover: 'https://example.com/cover.jpg',
  pluginName: pluginName,
  createdAt: DateTime(2026, 9, 1),
  episodes: const [],
);

LanShareEpisode _meta(int number, {String entry = 'playlist.m3u8'}) =>
    LanShareEpisode(
      episodeNumber: number,
      episodeName: 'Episode $number',
      road: 1,
      totalSegments: 2,
      totalBytes: 999,
      networkM3u8Url: 'https://example.com/$number.m3u8',
      episodePageUrl: 'https://example.com/play/$number',
      completedAt: DateTime(2026, 10, 1),
      entryFileName: entry,
      danmakuData: '[{"t":$number}]',
      danDanBangumiID: 77,
    );

void main() {
  late Directory root;
  late String base;
  late DownloadImportService service;

  setUpAll(() async {
    root = await setUpTestStorage('kazumi_import_service_');
    base = path.join(root.path, 'pc');
  });

  tearDownAll(() => tearDownTestStorage(root));

  setUp(() async {
    await GStorage.downloads.clear();
    service = DownloadImportService(
      DownloadRepository(),
      _BaseDirManager(base),
    );
  });

  Future<void> putLocal(Map<int, DownloadEpisode> episodes) =>
      GStorage.downloads.put('source_123', testRecord(episodes));

  group('localState', () {
    test('absent when nothing is downloaded', () {
      expect(service.localState(_remote(), 1), LocalEpisodeState.absent);
    });

    test('completed only when the entry file exists', () async {
      final done = await writeCompletedEpisode(
        base: base,
        episodeNumber: 1,
        files: {
          'playlist.m3u8': [1],
        },
      );
      final missing = await writeCompletedEpisode(
        base: base,
        episodeNumber: 2,
        files: {
          'seg_00000.ts': [1],
        },
      );
      await putLocal({1: done, 2: missing});

      expect(service.localState(_remote(), 1), LocalEpisodeState.completed);
      expect(service.localState(_remote(), 2), LocalEpisodeState.incomplete);
    });

    test(
      'queued episodes count as downloading, paused as incomplete',
      () async {
        final pending = await writeCompletedEpisode(
          base: base,
          episodeNumber: 1,
          files: const {},
          status: DownloadStatus.pending,
        );
        final paused = await writeCompletedEpisode(
          base: base,
          episodeNumber: 2,
          files: const {},
          status: DownloadStatus.paused,
        );
        final failed = await writeCompletedEpisode(
          base: base,
          episodeNumber: 3,
          files: const {},
          status: DownloadStatus.failed,
        );
        await putLocal({1: pending, 2: paused, 3: failed});

        expect(service.localState(_remote(), 1), LocalEpisodeState.downloading);
        expect(service.localState(_remote(), 2), LocalEpisodeState.incomplete);
        expect(service.localState(_remote(), 3), LocalEpisodeState.incomplete);
        expect(LocalEpisodeState.incomplete.importable, isTrue);
        expect(LocalEpisodeState.downloading.importable, isFalse);
      },
    );
  });

  test('episode directory uses the configured download base', () async {
    expect(
      await service.episodeDirectory(_remote(), 4),
      path.join(base, '123_source', '4'),
    );
  });

  test('unsafe plugin names cannot escape the download base', () async {
    for (final name in ['../evil', 'a/b', r'a\b', 'C:x']) {
      await expectLater(
        service.episodeDirectory(_remote(pluginName: name), 1),
        throwsA(
          isA<LanShareException>().having(
            (e) => e.code,
            'code',
            LanShareErrorCode.badRequest,
          ),
        ),
      );
    }
  });

  test('discardLocal removes leftovers but keeps other episodes', () async {
    final failed = await writeCompletedEpisode(
      base: base,
      episodeNumber: 1,
      files: {
        'seg_00099.ts': [9],
      },
      status: DownloadStatus.failed,
    );
    final other = await writeCompletedEpisode(
      base: base,
      episodeNumber: 2,
      files: {
        'playlist.m3u8': [1],
      },
    );
    await putLocal({1: failed, 2: other});

    await service.discardLocal(_remote(), 1);

    expect(Directory(failed.downloadDirectory).existsSync(), isFalse);
    final record = GStorage.downloads.get('source_123')!;
    expect(record.episodes.keys, [2]);
  });

  test('commit creates a playable record with rebuilt paths', () async {
    final directory = path.join(base, '123_source', '1');
    await Directory(directory).create(recursive: true);
    await File(path.join(directory, 'playlist.m3u8')).writeAsString('#EXTM3U');

    final episode = await service.commit(
      record: _remote(),
      meta: _meta(1),
      directory: directory,
      totalBytes: 7,
    );

    final stored = GStorage.downloads.get('source_123')!;
    expect(stored.bangumiName, 'Test Anime');
    expect(stored.bangumiCover, 'https://example.com/cover.jpg');
    final saved = stored.episodes[1]!;
    expect(saved.status, DownloadStatus.completed);
    expect(saved.progressPercent, 1.0);
    expect(saved.downloadedSegments, 2);
    expect(saved.downloadDirectory, directory);
    expect(saved.localM3u8Path, path.join(directory, 'playlist.m3u8'));
    expect(saved.totalBytes, 7);
    expect(saved.danmakuData, '[{"t":1}]');
    expect(saved.danDanBangumiID, 77);
    expect(saved.episodePageUrl, 'https://example.com/play/1');
    expect(saved.errorMessage, isEmpty);
    expect(
      DownloadManager().getLocalVideoPath(episode),
      path.join(directory, 'playlist.m3u8'),
    );
  });

  test('commit merges into an existing record', () async {
    final other = await writeCompletedEpisode(
      base: base,
      episodeNumber: 2,
      files: {
        'video.mp4': [1],
      },
      entry: 'video.mp4',
    );
    await putLocal({2: other});

    await service.commit(
      record: _remote(),
      meta: _meta(1, entry: 'video.mp4'),
      directory: path.join(base, '123_source', '1'),
      totalBytes: 1,
    );

    final stored = GStorage.downloads.get('source_123')!;
    expect(stored.episodes.keys.toSet(), {1, 2});
    expect(stored.createdAt, DateTime(2026, 9, 1));
    expect(
      stored.episodes[1]!.localM3u8Path,
      path.join(base, '123_source', '1', 'video.mp4'),
    );
  });

  test('commit refuses an entry file name that could leave the directory',
      () async {
    for (final entry in ['../evil.m3u8', 'a/b.m3u8', '', '..']) {
      await expectLater(
        service.commit(
          record: _remote(),
          meta: _meta(1, entry: entry),
          directory: path.join(base, '123_source', '1'),
          totalBytes: 1,
        ),
        throwsA(isA<LanShareException>()
            .having((e) => e.code, 'code', LanShareErrorCode.badRequest)),
        reason: entry,
      );
    }
    expect(GStorage.downloads.get('source_123'), isNull);
  });
}
