import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:path/path.dart' as path;

/// How a remote episode relates to this device's downloads.
enum LocalEpisodeState {
  /// Not downloaded on this device.
  absent,

  /// Already completed and playable here.
  completed,

  /// Queued or downloading here; it has to be paused or deleted first.
  downloading,

  /// Failed, paused or missing files; an import replaces the leftovers.
  incomplete;

  bool get importable => this == absent || this == incomplete;
}

/// Writes episodes received from another device into local downloads.
class DownloadImportService {
  DownloadImportService(this._repository, this._downloadManager);

  final IDownloadRepository _repository;
  final IDownloadManager _downloadManager;

  LocalEpisodeState localState(LanShareRecord record, int episodeNumber) {
    final local = _repository.getRecord(record.key)?.episodes[episodeNumber];
    if (local == null) return LocalEpisodeState.absent;
    if (_downloadManager.isDownloading(record.key, episodeNumber)) {
      return LocalEpisodeState.downloading;
    }
    switch (local.status) {
      case DownloadStatus.completed:
        return _downloadManager.getLocalVideoPath(local) != null
            ? LocalEpisodeState.completed
            : LocalEpisodeState.incomplete;
      case DownloadStatus.pending:
      case DownloadStatus.resolving:
      case DownloadStatus.downloading:
        return LocalEpisodeState.downloading;
      default:
        return LocalEpisodeState.incomplete;
    }
  }

  /// Where the imported episode is stored, following the local layout.
  Future<String> episodeDirectory(
    LanShareRecord record,
    int episodeNumber,
  ) async {
    final base = await _downloadManager.resolveDownloadBaseDir();
    final directory = downloadEpisodeDirectory(
      base,
      record.bangumiId,
      record.pluginName,
      episodeNumber,
    );
    if (!LanShareProtocol.isSafePluginName(record.pluginName) ||
        !path.isWithin(base, directory)) {
      throw const LanShareException(
        LanShareErrorCode.badRequest,
        '番剧来源名称包含本机不支持的字符',
      );
    }
    return directory;
  }

  Future<int> availableStorage(String directory) =>
      _downloadManager.getAvailableStorage(directory);

  /// Drops a failed or paused local download so its segments cannot mix with
  /// the imported ones.
  Future<void> discardLocal(LanShareRecord record, int episodeNumber) async {
    final local = _repository.getRecord(record.key)?.episodes[episodeNumber];
    if (local == null) return;
    await _downloadManager.deleteEpisodeFiles(
      record.bangumiId,
      record.pluginName,
      episodeNumber,
      episode: local,
    );
    await _repository.deleteEpisode(record.key, episodeNumber);
  }

  /// Records a fully transferred episode as a completed local download.
  Future<DownloadEpisode> commit({
    required LanShareRecord record,
    required LanShareEpisode meta,
    required String directory,
    required int totalBytes,
  }) async {
    final episode = DownloadEpisode(
      meta.episodeNumber,
      meta.episodeName,
      meta.road,
      DownloadStatus.completed,
      1.0,
      meta.totalSegments,
      meta.totalSegments,
      path.join(directory, meta.entryFileName),
      directory,
      meta.networkM3u8Url,
      DateTime.now(),
      '',
      totalBytes,
      meta.episodePageUrl,
      danmakuData: meta.danmakuData,
      danDanBangumiID: meta.danDanBangumiID,
    );
    final target =
        _repository.getRecord(record.key) ??
        DownloadRecord(
          record.bangumiId,
          record.bangumiName,
          record.bangumiCover,
          record.pluginName,
          {},
          DateTime.now(),
        );
    target.episodes[meta.episodeNumber] = episode;
    await _repository.putRecord(target);
    return episode;
  }
}
