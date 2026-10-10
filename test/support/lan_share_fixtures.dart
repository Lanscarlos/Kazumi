import 'dart:async';
import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Opens Kazumi's Hive boxes inside a throwaway directory.
Future<Directory> setUpTestStorage(String prefix) async {
  Logger.level = Level.off;
  final directory = await Directory.systemTemp.createTemp(prefix);
  PathProviderPlatform.instance =
      TestPaths(path.join(directory.path, 'support'));
  Hive.init(path.join(directory.path, 'hive'));
  await GStorage.init();
  return directory;
}

Future<void> tearDownTestStorage(Directory directory) async {
  await Hive.close();
  await directory.delete(recursive: true);
}

class TestPaths extends PathProviderPlatform {
  TestPaths(this.directory);

  final String directory;

  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

/// Download records of the "other" device, kept apart from the Hive box the
/// importing side uses.
class MemoryDownloadRepository implements IDownloadRepository {
  final Map<String, DownloadRecord> records = {};
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  List<DownloadRecord> getAllRecords() => records.values.toList();

  @override
  DownloadRecord? getRecord(String key) => records[key];

  @override
  Future<void> putRecord(DownloadRecord record) async {
    records[record.key] = record;
  }

  @override
  Future<void> deleteRecord(String key) async {
    records.remove(key);
  }

  @override
  Future<void> updateEpisode(
      String recordKey, int episodeNumber, DownloadEpisode episode) async {
    records[recordKey]?.episodes[episodeNumber] = episode;
  }

  @override
  Future<void> deleteEpisode(String recordKey, int episodeNumber) async {
    final record = records[recordKey];
    if (record == null) return;
    record.episodes.remove(episodeNumber);
    if (record.episodes.isEmpty) records.remove(recordKey);
  }

  @override
  bool getForceAdBlocker() => false;

  @override
  DownloadRecord? getRecordByBangumiId(int bangumiId, String pluginName) =>
      records['${pluginName}_$bangumiId'];

  @override
  DownloadEpisode? getEpisode(
          int bangumiId, String pluginName, int episodeNumber) =>
      getRecordByBangumiId(bangumiId, pluginName)?.episodes[episodeNumber];

  @override
  List<DownloadEpisode> getCompletedEpisodes(int bangumiId, String pluginName) =>
      [
        for (final episode in getRecordByBangumiId(bangumiId, pluginName)
                ?.episodes
                .values ??
            const <DownloadEpisode>[])
          if (episode.status == DownloadStatus.completed) episode,
      ];

  @override
  DownloadEpisode? getEpisodeByUrl(
      int bangumiId, String pluginName, String episodePageUrl) {
    for (final episode in getRecordByBangumiId(bangumiId, pluginName)
            ?.episodes
            .values ??
        const <DownloadEpisode>[]) {
      if (episode.episodePageUrl == episodePageUrl) return episode;
    }
    return null;
  }
}

/// Writes [files] under `<base>/<bangumiId>_<pluginName>/<episodeNumber>` and
/// returns an episode record whose entry file is [entry].
Future<DownloadEpisode> writeCompletedEpisode({
  required String base,
  int bangumiId = 123,
  String pluginName = 'source',
  required int episodeNumber,
  required Map<String, List<int>> files,
  String entry = 'playlist.m3u8',
  int status = DownloadStatus.completed,
  String danmakuData = '',
}) async {
  final directory =
      path.join(base, '${bangumiId}_$pluginName', '$episodeNumber');
  await Directory(directory).create(recursive: true);
  var totalBytes = 0;
  for (final file in files.entries) {
    await File(path.join(directory, file.key)).writeAsBytes(file.value);
    totalBytes += file.value.length;
  }
  return DownloadEpisode(
    episodeNumber,
    'Episode $episodeNumber',
    0,
    status,
    1.0,
    files.length,
    files.length,
    path.join(directory, entry),
    directory,
    'https://example.com/$episodeNumber.m3u8',
    DateTime(2026, 10, 1),
    '',
    totalBytes,
    'https://example.com/play/$episodeNumber',
    danmakuData: danmakuData,
    danDanBangumiID: 77,
  );
}

DownloadRecord testRecord(
  Map<int, DownloadEpisode> episodes, {
  int bangumiId = 123,
  String pluginName = 'source',
}) =>
    DownloadRecord(bangumiId, 'Test Anime', 'https://example.com/cover.jpg',
        pluginName, episodes, DateTime(2026, 9, 1));

List<int> bytesOf(int length, {int seed = 0}) =>
    List<int>.generate(length, (i) => (i * 31 + seed) % 256);
