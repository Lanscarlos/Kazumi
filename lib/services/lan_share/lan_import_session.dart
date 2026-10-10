import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:kazumi/services/lan_share/download_import_service.dart';
import 'package:kazumi/services/lan_share/lan_share_client.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:path/path.dart' as path;

class LanShareInsufficientStorageException implements Exception {
  const LanShareInsufficientStorageException(
      this.requiredBytes, this.availableBytes);

  final int requiredBytes;
  final int availableBytes;

  @override
  String toString() => '磁盘空间不足';
}

const lanShareConnectHint = '无法连接。请确认：两台设备连接的是同一个 Wi-Fi'
    '（不是访客网络，路由器未开启"AP 隔离"）；对方已打开"局域网共享"页面并开启共享；'
    '地址和端口填写正确；对方是 Windows 时，防火墙已允许 Kazumi 访问"专用网络"。';

/// User-facing text for any failure during connecting or importing.
String describeLanShareError(Object error) {
  if (error is LanShareInsufficientStorageException) return '磁盘空间不足';
  if (error is LanShareException) {
    switch (error.code) {
      case LanShareErrorCode.connectFailed:
        return lanShareConnectHint;
      case LanShareErrorCode.badCode:
        return '配对码错误';
      case LanShareErrorCode.codeRotated:
        return '错误次数过多，配对码已刷新，请稍后用共享设备上的新配对码重试';
      case LanShareErrorCode.unauthorized:
        return '共享已关闭或连接已失效，请重新输入配对码';
      case LanShareErrorCode.notFound:
        return '共享设备上该集已不存在';
      case LanShareErrorCode.network:
        return '网络中断';
      case LanShareErrorCode.sizeMismatch:
        return '文件校验失败';
      case LanShareErrorCode.cancelled:
        return '已取消';
      default:
        return error.message;
    }
  }
  if (error is FileSystemException) return '写入失败：${error.message}';
  return '导入失败：$error';
}

enum LanImportStatus { waiting, transferring, done, skipped, failed }

class LanImportItem {
  LanImportItem(this.record, this.episode) : totalBytes = episode.totalBytes;

  final LanShareRecord record;
  final LanShareEpisode episode;
  LanImportStatus status = LanImportStatus.waiting;
  String? error;
  int doneBytes = 0;

  /// Starts from the manifest estimate; replaced by the real file sizes.
  int totalBytes;
}

/// Imports [items] one episode at a time from a paired [LanShareClient].
class LanImportSession {
  LanImportSession({
    required LanShareClient client,
    required DownloadImportService importer,
    required this.items,
    this.parallelFiles = 4,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.reserveBytes = 100 * 1024 * 1024,
    this.onEpisodeImported,
  })  : _client = client,
        _importer = importer;

  final LanShareClient _client;
  final DownloadImportService _importer;
  final List<LanImportItem> items;
  final int parallelFiles;
  final List<Duration> retryDelays;
  final int reserveBytes;
  final void Function()? onEpisodeImported;

  final _changes = StreamController<void>.broadcast();
  bool _cancelled = false;
  bool _running = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<void> get changes => _changes.stream;
  bool get isCancelled => _cancelled;
  bool get isRunning => _running;
  int get doneBytes => items.fold(0, (sum, item) => sum + item.doneBytes);
  int get totalBytes => items.fold(0, (sum, item) => sum + item.totalBytes);

  Future<void> run() async {
    if (_running) throw StateError('LanImportSession is already running');
    _running = true;
    String? stopReason;
    for (final item in items) {
      if (_cancelled) break;
      if (stopReason != null) {
        item
          ..status = LanImportStatus.failed
          ..error = stopReason;
        continue;
      }
      final number = item.episode.episodeNumber;
      final state = _importer.localState(item.record, number);
      if (!state.importable) {
        item
          ..status = LanImportStatus.skipped
          ..error = state == LocalEpisodeState.completed ? '本地已存在' : '本地正在下载';
        _notify();
        continue;
      }
      item
        ..status = LanImportStatus.transferring
        ..error = null
        ..doneBytes = 0;
      _notify();
      try {
        await _importEpisode(item, state);
        item.status = LanImportStatus.done;
        _notify();
        onEpisodeImported?.call();
      } catch (e, stackTrace) {
        if (_cancelled) {
          item.status = LanImportStatus.waiting;
          break;
        }
        item
          ..status = LanImportStatus.failed
          ..error = describeLanShareError(e);
        if (e is LanShareInsufficientStorageException) {
          stopReason = '已停止：磁盘空间不足';
        } else if (e is LanShareException) {
          if (e.code == LanShareErrorCode.unauthorized) {
            stopReason = '已停止：共享已关闭，请重新连接';
          } else if (e.code == LanShareErrorCode.connectFailed) {
            stopReason = '已停止：连接已断开';
          }
        } else {
          KazumiLogger().w('LanImportSession: episode $number failed',
              error: e, stackTrace: stackTrace);
        }
        _notify();
      }
    }
    _running = false;
    _notify();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _client.cancelActive();
    _notify();
  }

  Future<void> _importEpisode(
      LanImportItem item, LocalEpisodeState state) async {
    final record = item.record;
    final number = item.episode.episodeNumber;
    final directory = await _importer.episodeDirectory(record, number);
    if (state == LocalEpisodeState.incomplete) {
      await _importer.discardLocal(record, number);
    }
    final meta = await _client.fetchEpisodeMeta(record.key, number);
    final files = await _client.fetchEpisodeFiles(record.key, number);
    if (files.any((file) =>
        !LanShareProtocol.isSafeFileName(file.name) ||
        LanShareProtocol.isTransientFileName(file.name))) {
      throw const LanShareException(
          LanShareErrorCode.badName, '对方返回的文件名无效');
    }
    if (!files.any((file) => file.name == meta.entryFileName)) {
      throw const LanShareException(
          LanShareErrorCode.notFound, '共享设备上该集文件不完整');
    }
    item.totalBytes = files.fold(0, (sum, file) => sum + file.size);
    _throwIfCancelled();

    await ensureDirectoryWritable(directory);
    await _checkStorage(directory, files);

    final progress = <String, int>{};
    await _forEachLimited(files, (file) => _withRetry(() {
          progress[file.name] = 0;
          return _client.downloadFile(
            recordKey: record.key,
            episodeNumber: number,
            file: file,
            directory: directory,
            onBytes: (delta) {
              progress[file.name] = progress[file.name]! + delta;
              item.doneBytes = progress.values.fold(0, (sum, v) => sum + v);
              _notifyThrottled();
            },
          );
        }));
    _throwIfCancelled();

    await _prune(directory, files);
    await _importer.commit(
        record: record,
        meta: meta,
        directory: directory,
        totalBytes: item.totalBytes);
  }

  Future<void> _checkStorage(
      String directory, List<LanShareFile> files) async {
    var remaining = 0;
    for (final file in files) {
      final target = File(path.join(directory, file.name));
      final partial = File('${target.path}${LanShareProtocol.partialSuffix}');
      var have = 0;
      if (await target.exists() && await target.length() == file.size) {
        have = file.size;
      } else if (await partial.exists()) {
        have = min(await partial.length(), file.size);
      }
      remaining += file.size - have;
    }
    final available = await _importer.availableStorage(directory);
    final required = remaining + reserveBytes;
    if (available >= 0 && available < required) {
      throw LanShareInsufficientStorageException(required, available);
    }
  }

  /// Runs [action] for every file with at most [parallelFiles] at once and
  /// stops handing out files after the first failure.
  Future<void> _forEachLimited(List<LanShareFile> files,
      Future<void> Function(LanShareFile file) action) async {
    var next = 0;
    Object? firstError;
    StackTrace? firstStack;
    Future<void> worker() async {
      while (firstError == null && !_cancelled && next < files.length) {
        final file = files[next++];
        try {
          await action(file);
        } catch (e, stackTrace) {
          firstError ??= e;
          firstStack ??= stackTrace;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < min(parallelFiles, files.length); i++) worker(),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }

  Future<void> _withRetry(Future<void> Function() action) async {
    for (var attempt = 0;; attempt++) {
      _throwIfCancelled();
      try {
        await action();
        return;
      } catch (e) {
        if (_cancelled || attempt >= retryDelays.length || !_isRetryable(e)) {
          rethrow;
        }
        await Future.delayed(retryDelays[attempt]);
      }
    }
  }

  bool _isRetryable(Object error) =>
      error is LanShareException &&
      const {
        LanShareErrorCode.network,
        LanShareErrorCode.connectFailed,
        LanShareErrorCode.sizeMismatch,
        LanShareErrorCode.internal,
      }.contains(error.code);

  /// Removes files the share device does not list, such as leftovers of an
  /// older attempt, so the episode directory matches the source exactly.
  Future<void> _prune(String directory, List<LanShareFile> files) async {
    final keep = {for (final file in files) file.name};
    await for (final entity in Directory(directory).list(followLinks: false)) {
      if (entity is File && !keep.contains(path.basename(entity.path))) {
        await entity.delete();
      }
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw const LanShareException(LanShareErrorCode.cancelled, '已取消');
    }
  }

  void _notify() {
    _lastNotify = DateTime.now();
    if (!_changes.isClosed) _changes.add(null);
  }

  void _notifyThrottled() {
    if (DateTime.now().difference(_lastNotify) >=
        const Duration(milliseconds: 200)) {
      _notify();
    }
  }
}
