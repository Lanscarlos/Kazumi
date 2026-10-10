# 局域网缓存共享 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让同一局域网内的两台 Kazumi（首要场景 Android ↔ Windows）可以手动、双向地互相导入已下载完成的离线缓存，导入后在接收端可以直接离线播放（弹幕一起带过来）。

**Architecture:** 共享方用 `dart:io` 的 `HttpServer` 提供一个带配对码鉴权的小型 HTTP 接口（清单、单集元数据、文件列表、支持 Range 的文件下载）。导入方用 `dart:io` 的 `HttpClient` 拉取文件，写入本地下载目录，最后写入 Hive 下载记录。共享和导入两端的代码都放在 `lib/services/lan_share/`，界面是下载管理页里的两个新页面。

**Tech Stack:** Flutter 3.47.6 / Dart 3.13、`dart:io`（HttpServer/HttpClient）、hive_ce（已有）、flutter_modular 7（已有路由）、flutter_foreground_task（已有，Android 保活）。不新增任何依赖。

**Spec:** `docs/superpowers/specs/2026-10-10-lan-download-share-design.md`

## Global Constraints

- 不新增 pub 依赖；不新增 Hive 类型（无需跑 build_runner）。
- 协议版本 `1`；默认端口 `38291`，被占用时依次尝试 `38292` 到 `38299`。
- 配对码为 6 位数字，用 `Random.secure()` 生成；令牌为 32 字节随机数的十六进制（64 个字符）；配对码累计错 5 次后作废并重新生成。
- 允许传输的文件名必须匹配 `^[A-Za-z0-9._-]+$`，且不能是 `.` 或 `..`；以 `.tmp` 或 `.lstmp` 结尾的临时文件永远不共享。
- 下载中的临时文件后缀为 `.lstmp`。单集内最多同时下载 4 个文件。单个文件最多重试 3 次，间隔 1 秒、2 秒、4 秒。磁盘需要预留 100MB。
- 只共享已完成（`status == completed` 且入口文件存在）的集。
- 只有一集的全部文件都就绪后，才写入下载记录。
- 集目录规则：`<base>/<bangumiId>_<pluginName>/<episodeNumber>`。
- 用户可见文案用中文；代码注释用英文，风格与周边代码一致。
- 测试命令：`flutter test <file>`；静态检查：`flutter analyze <files>`。Flutter SDK 在 `/tmp/claude-0/-home-user-Kazumi/a77e5de2-7908-5939-96f1-dceaee3d0f09/scratchpad/flutter/bin`，执行前先运行 `export PATH=<该目录>:$PATH`。

## File Structure

| 文件 | 职责 |
|---|---|
| `lib/utils/file_system.dart`（改） | 新增 `downloadEpisodeDirectory()`，集目录规则只在这里定义 |
| `lib/services/download/download_manager.dart`（改） | 调用公共的目录规则；公开 `resolveDownloadBaseDir()` 和 `getAvailableStorage()` |
| `lib/services/download/download_path_migration.dart`（改） | 调用公共的目录规则 |
| `lib/services/download/foreground_service_lease.dart`（新） | 纯 Dart 的"持有方计数"：所有持有方都释放后才停止平台服务 |
| `lib/services/download/background_download_service.dart`（改） | 改为通过 lease 启停；新增 `acquire`/`release`/`holds` |
| `lib/pages/download/download_controller.dart`（改） | 只在下载方持有前台服务时，才更新通知或停止服务 |
| `lib/services/lan_share/lan_share_protocol.dart`（新） | 协议常量、数据结构与 JSON、文件名和插件名校验、配对码和令牌生成 |
| `lib/services/lan_share/lan_share_server.dart`（新） | 共享方 HTTP 服务 |
| `lib/services/lan_share/download_import_service.dart`（新） | 导入方本地状态判定、残留清理、目标目录计算、写入记录 |
| `lib/services/lan_share/lan_share_client.dart`（新） | 导入方 HTTP 客户端：信息、配对、清单、元数据、文件续传下载 |
| `lib/services/lan_share/lan_import_session.dart`（新） | 编排多集导入：并发、重试、空间检查、清理多余文件、取消、错误文案 |
| `lib/services/storage/settings_keys.dart`（改） | 新增设置项 `lanShareLastAddress` |
| `lib/pages/download/lan_share_page.dart`（新） | 局域网共享页 |
| `lib/pages/download/lan_import_page.dart`（新） | 从其他设备导入页 |
| `lib/pages/download/download_page_module.dart`（改） | 注册两个路由 |
| `lib/pages/download/download_page.dart`（改） | AppBar 菜单入口 |
| `test/support/lan_share_fixtures.dart`（新） | 测试工具：临时 Hive、内存仓库、写入假的已完成集 |
| `test/download_episode_directory_test.dart`（新） | 目录规则测试 |
| `test/foreground_service_lease_test.dart`（新） | lease 测试 |
| `test/lan_share_protocol_test.dart`（新） | 协议测试 |
| `test/lan_share_server_test.dart`（新） | 服务端测试 |
| `test/download_import_service_test.dart`（新） | 导入服务测试 |
| `test/lan_share_client_test.dart`（新） | 客户端与服务端的集成测试 |
| `test/lan_import_session_test.dart`（新） | 端到端导入测试 |
| `docs/superpowers/lan-share-manual-checklist.md`（新） | 真机检查清单 |

---

### Task 1: 集目录规则公共化，公开下载根目录与可用空间

**Files:**
- Modify: `lib/utils/file_system.dart`
- Modify: `lib/services/download/download_manager.dart`（`IDownloadManager` 约在第 94-110 行，`_getAvailableStorage` 约在第 163 行，`_downloadBaseDir` 和 `_getEpisodeDir` 约在第 218-270 行）
- Modify: `lib/services/download/download_path_migration.dart`
- Test: `test/download_episode_directory_test.dart`

**Interfaces:**
- Produces:
  - `String downloadEpisodeDirectory(String downloadBase, int bangumiId, String pluginName, int episodeNumber)`（`lib/utils/file_system.dart`）
  - `IDownloadManager.resolveDownloadBaseDir() → Future<String>`
  - `IDownloadManager.getAvailableStorage(String path) → Future<int>`（无法判断时返回 -1）

- [ ] **Step 1: 写失败测试**

`test/download_episode_directory_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:path/path.dart' as path;

void main() {
  test('episode directory is <base>/<bangumiId>_<pluginName>/<episode>', () {
    final base = path.join('root', 'downloads');
    expect(
      downloadEpisodeDirectory(base, 123, 'source', 4),
      path.join(base, '123_source', '4'),
    );
  });
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/download_episode_directory_test.dart`
Expected: 编译失败，报错 `The method 'downloadEpisodeDirectory' isn't defined`

- [ ] **Step 3: 在 `lib/utils/file_system.dart` 的 `getDefaultDownloadDirectory` 之后加入函数**

```dart
/// Directory holding one downloaded episode. Downloads, path migration and
/// LAN imports must all agree on this layout.
String downloadEpisodeDirectory(
  String downloadBase,
  int bangumiId,
  String pluginName,
  int episodeNumber,
) =>
    path.join(downloadBase, '${bangumiId}_$pluginName', '$episodeNumber');
```

- [ ] **Step 4: 修改 `download_manager.dart`**

1）在 `abstract class IDownloadManager` 中 `double getSpeed(...)` 之后加入：

```dart
  /// Base directory new downloads are written to: the custom directory when
  /// set and usable, otherwise the default one.
  Future<String> resolveDownloadBaseDir();

  /// Available bytes on the volume holding [path], or -1 when unknown.
  Future<int> getAvailableStorage(String path);
```

2）把 `Future<int> _getAvailableStorage(String path) async {` 改为：

```dart
  @override
  Future<int> getAvailableStorage(String path) async {
```

并把 `_checkStorageSpace` 里的 `await _getAvailableStorage(downloadDir)` 改为 `await getAvailableStorage(downloadDir)`。

3）把 `Future<String> get _downloadBaseDir async {` 改为：

```dart
  @override
  Future<String> resolveDownloadBaseDir() async {
```

4）删除整个 `_getEpisodeDir` 方法，把 `_prepareEpisodeDir` 中的

```dart
        : _getEpisodeDir(
            await _downloadBaseDir, bangumiId, pluginName, episodeNumber);
```

改为

```dart
        : downloadEpisodeDirectory(
            await resolveDownloadBaseDir(), bangumiId, pluginName, episodeNumber);
```

把 `_episodeDirForDeletion` 中的

```dart
    return _getEpisodeDir(await getDefaultDownloadDirectory(), bangumiId,
        pluginName, episodeNumber);
```

改为

```dart
    return downloadEpisodeDirectory(await getDefaultDownloadDirectory(),
        bangumiId, pluginName, episodeNumber);
```

- [ ] **Step 5: 修改 `download_path_migration.dart` 的 `_rebaseDownloadPaths`**

把

```dart
      final directory = path.join(
        downloadBase,
        '${record.bangumiId}_${record.pluginName}',
        '${entry.key}',
      );
```

改为

```dart
      final directory = downloadEpisodeDirectory(
        downloadBase,
        record.bangumiId,
        record.pluginName,
        entry.key,
      );
```

（该文件已经 import 了 `package:kazumi/utils/file_system.dart`。）

- [ ] **Step 6: 运行测试与检查**

Run: `grep -rn "_getEpisodeDir\|_downloadBaseDir\|_getAvailableStorage" lib`
Expected: 无输出

Run: `flutter test test/download_episode_directory_test.dart test/download_path_migration_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze lib/utils/file_system.dart lib/services/download/`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/utils/file_system.dart lib/services/download/download_manager.dart lib/services/download/download_path_migration.dart test/download_episode_directory_test.dart
git commit -m "refactor(download): share episode directory layout and expose base dir"
```

---

### Task 2: 前台服务改为多方共用

**Files:**
- Create: `lib/services/download/foreground_service_lease.dart`
- Modify: `lib/services/download/background_download_service.dart`
- Modify: `lib/pages/download/download_controller.dart`（`_updateBackgroundNotification` 和 `_startBackgroundServiceIfNeeded`，约在第 175-208 行）
- Test: `test/foreground_service_lease_test.dart`

**Interfaces:**
- Produces:
  - `class ForegroundServiceLease({required Future<bool> Function() start, required Future<void> Function() stop})`，提供 `Future<bool> acquire(String owner)`、`Future<void> release(String owner)`、`bool holds(String owner)`、`bool get isRunning`
  - `BackgroundDownloadService.downloadOwner = 'download'`、`BackgroundDownloadService.lanShareOwner = 'lanShare'`
  - `BackgroundDownloadService.acquire(String owner) → Future<bool>`、`release(String owner) → Future<void>`、`holds(String owner) → bool`
  - `startService()` 和 `stopService()` 保留，分别等同于 `acquire(downloadOwner)` 和 `release(downloadOwner)`

- [ ] **Step 1: 写失败测试**

`test/foreground_service_lease_test.dart`：

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/foreground_service_lease.dart';

class _FakeService {
  int starts = 0;
  int stops = 0;
  bool startResult = true;
  Completer<bool>? pendingStart;

  Future<bool> start() {
    starts++;
    return pendingStart?.future ?? Future.value(startResult);
  }

  Future<void> stop() async => stops++;

  ForegroundServiceLease lease() =>
      ForegroundServiceLease(start: start, stop: stop);
}

void main() {
  test('starts once and stops after the last owner releases', () async {
    final service = _FakeService();
    final lease = service.lease();

    expect(await lease.acquire('download'), isTrue);
    expect(await lease.acquire('lanShare'), isTrue);
    expect(service.starts, 1);

    await lease.release('download');
    expect(service.stops, 0);
    expect(lease.isRunning, isTrue);

    await lease.release('lanShare');
    expect(service.stops, 1);
    expect(lease.isRunning, isFalse);
  });

  test('releasing an owner that never acquired does nothing', () async {
    final service = _FakeService();
    final lease = service.lease();
    await lease.acquire('download');

    await lease.release('lanShare');

    expect(service.stops, 0);
    expect(lease.holds('download'), isTrue);
  });

  test('a failed start drops the owner so a later acquire retries', () async {
    final service = _FakeService()..startResult = false;
    final lease = service.lease();

    expect(await lease.acquire('download'), isFalse);
    expect(lease.holds('download'), isFalse);

    service.startResult = true;
    expect(await lease.acquire('download'), isTrue);
    expect(service.starts, 2);
  });

  test('concurrent acquires share one platform start', () async {
    final service = _FakeService()..pendingStart = Completer<bool>();
    final lease = service.lease();

    final first = lease.acquire('download');
    final second = lease.acquire('lanShare');
    service.pendingStart!.complete(true);

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(service.starts, 1);
  });

  test('releasing during a pending start stops the service once up',
      () async {
    final service = _FakeService()..pendingStart = Completer<bool>();
    final lease = service.lease();

    final acquired = lease.acquire('lanShare');
    await lease.release('lanShare');
    service.pendingStart!.complete(true);

    expect(await acquired, isFalse);
    expect(service.stops, 1);
    expect(lease.isRunning, isFalse);
  });
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/foreground_service_lease_test.dart`
Expected: 编译失败，提示找不到 `foreground_service_lease.dart`

- [ ] **Step 3: 实现 `lib/services/download/foreground_service_lease.dart`**

```dart
/// Keeps one platform foreground service alive while any owner needs it.
///
/// Downloads and LAN sharing both rely on the same Android foreground
/// service, so neither may stop it while the other is still working.
class ForegroundServiceLease {
  ForegroundServiceLease({
    required Future<bool> Function() start,
    required Future<void> Function() stop,
  })  : _start = start,
        _stop = stop;

  final Future<bool> Function() _start;
  final Future<void> Function() _stop;
  final Set<String> _owners = {};
  Future<bool>? _starting;
  bool _running = false;

  bool get isRunning => _running;

  bool holds(String owner) => _owners.contains(owner);

  /// Registers [owner] and starts the service if needed. Returns whether the
  /// service is running for this owner.
  Future<bool> acquire(String owner) async {
    _owners.add(owner);
    if (_running) return true;
    final started = await (_starting ??= _startPlatform());
    if (!started) _owners.remove(owner);
    return started && _running;
  }

  /// Unregisters [owner]; the service stops when no owner remains.
  Future<void> release(String owner) async {
    if (!_owners.remove(owner)) return;
    if (_owners.isNotEmpty || !_running) return;
    _running = false;
    await _stop();
  }

  Future<bool> _startPlatform() async {
    try {
      final started = await _start();
      if (started && _owners.isEmpty) {
        // Every owner released while the platform was still starting.
        await _stop();
        return false;
      }
      _running = started;
      return started;
    } finally {
      _starting = null;
    }
  }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/foreground_service_lease_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: 把 `BackgroundDownloadService` 改为基于 lease 启停**

在 `lib/services/download/background_download_service.dart` 中：

1）加入 `import 'package:kazumi/services/download/foreground_service_lease.dart';`

2）删除字段 `bool _isRunning = false;` 和 getter `bool get isRunning => _isRunning;`，在 `bool get isSupported => Platform.isAndroid;` 之后加入：

```dart
  static const downloadOwner = 'download';
  static const lanShareOwner = 'lanShare';

  late final ForegroundServiceLease _lease = ForegroundServiceLease(
    start: _startPlatformService,
    stop: _stopPlatformService,
  );

  bool get isRunning => _lease.isRunning;

  bool holds(String owner) => _lease.holds(owner);

  /// Keeps the foreground service alive on behalf of [owner].
  Future<bool> acquire(String owner) async {
    if (!isSupported) return false;
    return _lease.acquire(owner);
  }

  /// Drops [owner]'s hold; the service stops once nobody holds it.
  Future<void> release(String owner) async {
    if (!isSupported) return;
    await _lease.release(owner);
  }

  Future<bool> startService() => acquire(downloadOwner);

  Future<void> stopService() => release(downloadOwner);
```

3）把原来的 `Future<bool> startService() async {` 方法重命名为 `Future<bool> _startPlatformService() async {`，删除方法开头的这两行：

```dart
    if (!isSupported) return false;
    if (_isRunning) return true;
```

并把 try 块中的

```dart
      _isRunning = result is ServiceRequestSuccess;

      if (_isRunning) {
        KazumiLogger().i('BackgroundDownloadService: service started');
      } else {
        KazumiLogger().w(
            'BackgroundDownloadService: service start returned non-success: $result');
      }
      return _isRunning;
```

改为

```dart
      final started = result is ServiceRequestSuccess;

      if (started) {
        KazumiLogger().i('BackgroundDownloadService: service started');
      } else {
        KazumiLogger().w(
            'BackgroundDownloadService: service start returned non-success: $result');
      }
      return started;
```

4）把原来的 `Future<void> stopService() async {` 方法改为：

```dart
  Future<void> _stopPlatformService() async {
    try {
      await FlutterForegroundTask.stopService();
      KazumiLogger().i('BackgroundDownloadService: service stopped');
    } catch (e) {
      KazumiLogger()
          .e('BackgroundDownloadService: failed to stop service', error: e);
    }
  }
```

5）在 `updateNotification` 和 `updateProgress` 中，把 `if (!isSupported || !_isRunning) return;` 改为 `if (!isSupported || !isRunning) return;`。

- [ ] **Step 6: 下载控制器只管理下载方自己的持有**

在 `lib/pages/download/download_controller.dart` 中：

`_updateBackgroundNotification` 的第一行 `if (!_backgroundService.isRunning) return;` 改为：

```dart
    if (!_backgroundService.holds(BackgroundDownloadService.downloadOwner)) {
      return;
    }
```

`_startBackgroundServiceIfNeeded` 的第一行 `if (!_backgroundService.isSupported || _backgroundService.isRunning) return;` 改为：

```dart
    if (!_backgroundService.isSupported ||
        _backgroundService.holds(BackgroundDownloadService.downloadOwner)) {
      return;
    }
```

- [ ] **Step 7: 检查**

Run: `grep -n "_isRunning" lib/services/download/background_download_service.dart`
Expected: 无输出

Run: `flutter analyze lib/services/download/ lib/pages/download/download_controller.dart`
Expected: `No issues found!`

Run: `flutter test test/foreground_service_lease_test.dart test/download_path_migration_test.dart`
Expected: `All tests passed!`

- [ ] **Step 8: Commit**

```bash
git add lib/services/download/foreground_service_lease.dart lib/services/download/background_download_service.dart lib/pages/download/download_controller.dart test/foreground_service_lease_test.dart
git commit -m "feat(download): share the foreground service between owners"
```

---

### Task 3: 协议层

**Files:**
- Create: `lib/services/lan_share/lan_share_protocol.dart`
- Test: `test/lan_share_protocol_test.dart`

**Interfaces:**
- Consumes: `DownloadRecord`、`DownloadEpisode`（`lib/modules/download/download_module.dart`）
- Produces（后续任务都依赖这些名字）：
  - `LanShareProtocol`：`version`、`appId`、`defaultPort`、`portAttempts`、`maxPairFailures`、`infoPath`、`pairPath`、`manifestPath`、`episodeMetaPath`、`episodeFilesPath`、`episodeFilePath`、`partialSuffix`、`isSafeFileName(String)`、`isTransientFileName(String)`、`isSafePluginName(String)`、`episodeQuery(String recordKey, int episodeNumber) → Map<String, String>`、`generatePairingCode([Random?])`、`generateToken([Random?])`
  - `LanShareErrorCode`：`badCode`、`codeRotated`、`unauthorized`、`notFound`、`badName`、`badRequest`、`internal`、`connectFailed`、`notKazumi`、`versionMismatch`、`sizeMismatch`、`network`、`cancelled`
  - `LanShareInfo{app, protocolVersion, deviceName}`
  - `LanShareEpisode{episodeNumber, episodeName, road, totalSegments, totalBytes, networkM3u8Url, episodePageUrl, completedAt, entryFileName, danmakuData, danDanBangumiID}`，提供 `LanShareEpisode.fromDownload(int episodeNumber, DownloadEpisode e, {bool includeDanmaku = false})`
  - `LanShareRecord{bangumiId, bangumiName, bangumiCover, pluginName, createdAt, episodes}`，`key` 为 getter，值为 `'${pluginName}_$bangumiId'`；提供 `LanShareRecord.fromDownload(DownloadRecord, List<LanShareEpisode>)`
  - `LanShareManifest{protocolVersion, deviceName, records}`
  - `LanShareFile{name, size}`
  - 以上每个类都有 `toJson()` 和 `fromJson(Map<String, Object?>)`

- [ ] **Step 1: 写失败测试**

`test/lan_share_protocol_test.dart`：

```dart
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';

Map<String, Object?> _roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

DownloadEpisode _download() => DownloadEpisode(
      3,
      'Episode 3',
      1,
      DownloadStatus.completed,
      1.0,
      120,
      120,
      '/phone/downloads/123_source/3/playlist.m3u8',
      '/phone/downloads/123_source/3',
      'https://example.com/3.m3u8',
      DateTime.utc(2026, 10, 1, 8),
      '',
      4096,
      'https://example.com/play/3',
      danmakuData: '[{"t":1}]',
      danDanBangumiID: 77,
    );

void main() {
  group('fromDownload', () {
    test('copies fields and keeps danmaku only when asked', () {
      final summary = LanShareEpisode.fromDownload(3, _download());
      expect(summary.episodeNumber, 3);
      expect(summary.episodeName, 'Episode 3');
      expect(summary.road, 1);
      expect(summary.totalSegments, 120);
      expect(summary.totalBytes, 4096);
      expect(summary.entryFileName, 'playlist.m3u8');
      expect(summary.danDanBangumiID, 77);
      expect(summary.danmakuData, '');

      final meta =
          LanShareEpisode.fromDownload(3, _download(), includeDanmaku: true);
      expect(meta.danmakuData, '[{"t":1}]');
    });

    test('record key matches DownloadRecord.key', () {
      final download = DownloadRecord(
          123, 'Anime', 'https://c/1.jpg', 'source', {}, DateTime(2026));
      final record = LanShareRecord.fromDownload(download, const []);
      expect(record.key, download.key);
    });
  });

  test('manifest survives a JSON round trip', () {
    final manifest = LanShareManifest(
      protocolVersion: 1,
      deviceName: 'Android · phone',
      records: [
        LanShareRecord(
          bangumiId: 123,
          bangumiName: 'Anime',
          bangumiCover: 'https://c/1.jpg',
          pluginName: 'source',
          createdAt: DateTime.utc(2026, 9, 1),
          episodes: [
            LanShareEpisode.fromDownload(3, _download(), includeDanmaku: true),
          ],
        ),
      ],
    );

    final parsed = LanShareManifest.fromJson(_roundTrip(manifest.toJson()));

    expect(parsed.protocolVersion, 1);
    expect(parsed.deviceName, 'Android · phone');
    final record = parsed.records.single;
    expect(record.key, 'source_123');
    expect(record.bangumiCover, 'https://c/1.jpg');
    expect(record.createdAt.toUtc(), DateTime.utc(2026, 9, 1));
    final episode = record.episodes.single;
    expect(episode.completedAt!.toUtc(), DateTime.utc(2026, 10, 1, 8));
    expect(episode.networkM3u8Url, 'https://example.com/3.m3u8');
    expect(episode.episodePageUrl, 'https://example.com/play/3');
    expect(episode.danmakuData, '[{"t":1}]');
  });

  test('info and file survive a JSON round trip', () {
    final info = LanShareInfo.fromJson(_roundTrip(const LanShareInfo(
      app: 'kazumi',
      protocolVersion: 1,
      deviceName: 'pc',
    ).toJson()));
    expect(info.app, 'kazumi');
    expect(info.protocolVersion, 1);
    expect(info.deviceName, 'pc');

    final file = LanShareFile.fromJson(
        _roundTrip(const LanShareFile(name: 'seg_00001.ts', size: 9).toJson()));
    expect(file.name, 'seg_00001.ts');
    expect(file.size, 9);
  });

  test('missing JSON fields fall back to safe defaults', () {
    final episode = LanShareEpisode.fromJson(const {'episodeNumber': 2});
    expect(episode.episodeName, '');
    expect(episode.totalBytes, 0);
    expect(episode.completedAt, isNull);
    expect(LanShareManifest.fromJson(const {}).records, isEmpty);
  });

  group('file names', () {
    for (final name in [
      'playlist.m3u8',
      'video.mp4',
      'seg_00012.ts',
      'key_0.key',
    ]) {
      test('accepts $name', () {
        expect(LanShareProtocol.isSafeFileName(name), isTrue);
      });
    }
    for (final name in [
      '',
      '.',
      '..',
      '../a',
      'a/b',
      r'a\b',
      '/etc/passwd',
      r'C:\x',
      'seg 1.ts',
      '片段.ts',
    ]) {
      test('rejects "$name"', () {
        expect(LanShareProtocol.isSafeFileName(name), isFalse);
      });
    }

    test('temporary files are transient', () {
      expect(LanShareProtocol.isTransientFileName('video.mp4.tmp'), isTrue);
      expect(LanShareProtocol.isTransientFileName('seg_00001.ts.lstmp'),
          isTrue);
      expect(LanShareProtocol.isTransientFileName('seg_00001.ts'), isFalse);
    });
  });

  group('plugin names', () {
    for (final name in ['source', 'AGE动漫', 'my-plugin_2']) {
      test('accepts $name', () {
        expect(LanShareProtocol.isSafePluginName(name), isTrue);
      });
    }
    for (final name in ['', '.', '..', '../evil', 'a/b', r'a\b', 'C:x', 'a*b']) {
      test('rejects "$name"', () {
        expect(LanShareProtocol.isSafePluginName(name), isFalse);
      });
    }
  });

  test('pairing codes are six digits', () {
    final random = Random(1);
    for (var i = 0; i < 200; i++) {
      expect(LanShareProtocol.generatePairingCode(random),
          matches(RegExp(r'^\d{6}$')));
    }
  });

  test('tokens are 32 random bytes in hex', () {
    final token = LanShareProtocol.generateToken();
    expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(LanShareProtocol.generateToken(), isNot(token));
  });

  test('episode query carries record key and episode number', () {
    expect(LanShareProtocol.episodeQuery('source_123', 4),
        {'record': 'source_123', 'ep': '4'});
  });
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/lan_share_protocol_test.dart`
Expected: 编译失败，提示找不到 `lan_share_protocol.dart`

- [ ] **Step 3: 实现 `lib/services/lan_share/lan_share_protocol.dart`**

```dart
import 'dart:math';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:path/path.dart' as path;

/// Wire contract shared by the LAN share server and client (protocol v1).
class LanShareProtocol {
  LanShareProtocol._();

  static const int version = 1;
  static const String appId = 'kazumi';
  static const int defaultPort = 38291;

  /// Ports tried in order starting at [defaultPort] (38291-38299).
  static const int portAttempts = 9;

  /// Wrong pairing codes accepted before the code is replaced.
  static const int maxPairFailures = 5;

  static const String infoPath = '/api/v1/info';
  static const String pairPath = '/api/v1/pair';
  static const String manifestPath = '/api/v1/manifest';
  static const String episodeMetaPath = '/api/v1/episode/meta';
  static const String episodeFilesPath = '/api/v1/episode/files';
  static const String episodeFilePath = '/api/v1/episode/file';

  /// Suffix of files an import is still writing.
  static const String partialSuffix = '.lstmp';

  static final RegExp _safeFileName = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _unsafePluginChars = RegExp(r'[/\\:*?"<>|\x00-\x1f]');

  /// Names the server may serve and the client may write: a bare file name
  /// that cannot escape the episode directory.
  static bool isSafeFileName(String name) =>
      name != '.' && name != '..' && _safeFileName.hasMatch(name);

  /// Files still being written by a download or an import.
  static bool isTransientFileName(String name) =>
      name.endsWith('.tmp') || name.endsWith(partialSuffix);

  /// Plugin names become a directory name on the importing device, so they
  /// must not contain separators or characters Windows rejects.
  static bool isSafePluginName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !_unsafePluginChars.hasMatch(name);

  static Map<String, String> episodeQuery(String recordKey, int episodeNumber) =>
      {'record': recordKey, 'ep': '$episodeNumber'};

  static String generatePairingCode([Random? random]) =>
      (random ?? Random.secure()).nextInt(1000000).toString().padLeft(6, '0');

  static String generateToken([Random? random]) {
    final generator = random ?? Random.secure();
    return List.generate(
      32,
      (_) => generator.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

class LanShareErrorCode {
  LanShareErrorCode._();

  // Sent by the server.
  static const badCode = 'bad_code';
  static const codeRotated = 'code_rotated';
  static const unauthorized = 'unauthorized';
  static const notFound = 'not_found';
  static const badName = 'bad_name';
  static const badRequest = 'bad_request';
  static const internal = 'internal';

  // Raised by the client.
  static const connectFailed = 'connect_failed';
  static const notKazumi = 'not_kazumi';
  static const versionMismatch = 'version_mismatch';
  static const sizeMismatch = 'size_mismatch';
  static const network = 'network';
  static const cancelled = 'cancelled';
}

int _int(Object? value) => value is num ? value.toInt() : 0;

String _string(Object? value) => value is String ? value : '';

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

String? _dateJson(DateTime? value) => value?.toUtc().toIso8601String();

List<Map<String, Object?>> _maps(Object? value) => [
      if (value is List)
        for (final item in value)
          if (item is Map<String, Object?>) item,
    ];

class LanShareInfo {
  const LanShareInfo({
    required this.app,
    required this.protocolVersion,
    required this.deviceName,
  });

  final String app;
  final int protocolVersion;
  final String deviceName;

  factory LanShareInfo.fromJson(Map<String, Object?> json) => LanShareInfo(
        app: _string(json['app']),
        protocolVersion: _int(json['protocolVersion']),
        deviceName: _string(json['deviceName']),
      );

  Map<String, Object?> toJson() => {
        'app': app,
        'protocolVersion': protocolVersion,
        'deviceName': deviceName,
      };
}

class LanShareEpisode {
  const LanShareEpisode({
    required this.episodeNumber,
    required this.episodeName,
    required this.road,
    required this.totalSegments,
    required this.totalBytes,
    required this.networkM3u8Url,
    required this.episodePageUrl,
    required this.completedAt,
    required this.entryFileName,
    this.danmakuData = '',
    this.danDanBangumiID = 0,
  });

  final int episodeNumber;
  final String episodeName;
  final int road;
  final int totalSegments;
  final int totalBytes;
  final String networkM3u8Url;
  final String episodePageUrl;
  final DateTime? completedAt;

  /// `playlist.m3u8` or `video.mp4`.
  final String entryFileName;

  /// Cached danmaku JSON; only sent by the episode meta endpoint.
  final String danmakuData;
  final int danDanBangumiID;

  /// [episodeNumber] is the key in [DownloadRecord.episodes], which also
  /// names the episode directory.
  factory LanShareEpisode.fromDownload(
    int episodeNumber,
    DownloadEpisode episode, {
    bool includeDanmaku = false,
  }) =>
      LanShareEpisode(
        episodeNumber: episodeNumber,
        episodeName: episode.episodeName,
        road: episode.road,
        totalSegments: episode.totalSegments,
        totalBytes: episode.totalBytes,
        networkM3u8Url: episode.networkM3u8Url,
        episodePageUrl: episode.episodePageUrl,
        completedAt: episode.completedAt,
        entryFileName: path.basename(episode.localM3u8Path),
        danmakuData: includeDanmaku ? episode.danmakuData : '',
        danDanBangumiID: episode.danDanBangumiID,
      );

  factory LanShareEpisode.fromJson(Map<String, Object?> json) =>
      LanShareEpisode(
        episodeNumber: _int(json['episodeNumber']),
        episodeName: _string(json['episodeName']),
        road: _int(json['road']),
        totalSegments: _int(json['totalSegments']),
        totalBytes: _int(json['totalBytes']),
        networkM3u8Url: _string(json['networkM3u8Url']),
        episodePageUrl: _string(json['episodePageUrl']),
        completedAt: _date(json['completedAt']),
        entryFileName: _string(json['entryFileName']),
        danmakuData: _string(json['danmakuData']),
        danDanBangumiID: _int(json['danDanBangumiID']),
      );

  Map<String, Object?> toJson() => {
        'episodeNumber': episodeNumber,
        'episodeName': episodeName,
        'road': road,
        'totalSegments': totalSegments,
        'totalBytes': totalBytes,
        'networkM3u8Url': networkM3u8Url,
        'episodePageUrl': episodePageUrl,
        'completedAt': _dateJson(completedAt),
        'entryFileName': entryFileName,
        'danmakuData': danmakuData,
        'danDanBangumiID': danDanBangumiID,
      };
}

class LanShareRecord {
  const LanShareRecord({
    required this.bangumiId,
    required this.bangumiName,
    required this.bangumiCover,
    required this.pluginName,
    required this.createdAt,
    required this.episodes,
  });

  final int bangumiId;
  final String bangumiName;
  final String bangumiCover;
  final String pluginName;
  final DateTime createdAt;
  final List<LanShareEpisode> episodes;

  /// Same format as [DownloadRecord.key].
  String get key => '${pluginName}_$bangumiId';

  factory LanShareRecord.fromDownload(
    DownloadRecord record,
    List<LanShareEpisode> episodes,
  ) =>
      LanShareRecord(
        bangumiId: record.bangumiId,
        bangumiName: record.bangumiName,
        bangumiCover: record.bangumiCover,
        pluginName: record.pluginName,
        createdAt: record.createdAt,
        episodes: episodes,
      );

  factory LanShareRecord.fromJson(Map<String, Object?> json) => LanShareRecord(
        bangumiId: _int(json['bangumiId']),
        bangumiName: _string(json['bangumiName']),
        bangumiCover: _string(json['bangumiCover']),
        pluginName: _string(json['pluginName']),
        createdAt: _date(json['createdAt']) ?? DateTime.now(),
        episodes: [
          for (final episode in _maps(json['episodes']))
            LanShareEpisode.fromJson(episode),
        ],
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'bangumiId': bangumiId,
        'bangumiName': bangumiName,
        'bangumiCover': bangumiCover,
        'pluginName': pluginName,
        'createdAt': _dateJson(createdAt),
        'episodes': [for (final episode in episodes) episode.toJson()],
      };
}

class LanShareManifest {
  const LanShareManifest({
    required this.protocolVersion,
    required this.deviceName,
    required this.records,
  });

  final int protocolVersion;
  final String deviceName;
  final List<LanShareRecord> records;

  factory LanShareManifest.fromJson(Map<String, Object?> json) =>
      LanShareManifest(
        protocolVersion: _int(json['protocolVersion']),
        deviceName: _string(json['deviceName']),
        records: [
          for (final record in _maps(json['records']))
            LanShareRecord.fromJson(record),
        ],
      );

  Map<String, Object?> toJson() => {
        'protocolVersion': protocolVersion,
        'deviceName': deviceName,
        'records': [for (final record in records) record.toJson()],
      };
}

class LanShareFile {
  const LanShareFile({required this.name, required this.size});

  final String name;
  final int size;

  factory LanShareFile.fromJson(Map<String, Object?> json) =>
      LanShareFile(name: _string(json['name']), size: _int(json['size']));

  Map<String, Object?> toJson() => {'name': name, 'size': size};
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/lan_share_protocol_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze lib/services/lan_share/ test/lan_share_protocol_test.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/services/lan_share/lan_share_protocol.dart test/lan_share_protocol_test.dart
git commit -m "feat(lan-share): add wire protocol models and validation"
```

---

### Task 4: 共享方 HTTP 服务

**Files:**
- Create: `lib/services/lan_share/lan_share_server.dart`
- Create: `test/support/lan_share_fixtures.dart`
- Test: `test/lan_share_server_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `LanShareProtocol`、`LanShareErrorCode`、`LanShareInfo`、`LanShareEpisode`、`LanShareRecord`、`LanShareManifest`、`LanShareFile`；`IDownloadRepository.getAllRecords()` 和 `getRecord(String)`
- Produces:
  - `class LanSharePortUnavailableException implements Exception`
  - `String localDeviceName()`
  - `class LanShareServer({required IDownloadRepository repository, String? deviceName, int port = LanShareProtocol.defaultPort, InternetAddress? address, Random? random})`，提供 `start()`、`stop()`、`dispose()`、`isRunning`、`boundPort`、`pairingCode`、`connectedDevice`、`activeTransfers`、`bytesSent`、`Stream<void> changes`，以及 `static Future<List<String>> localAddresses()`。`port: 0` 表示由系统分配端口（测试用）
  - 文件列表接口返回 `{"files": [{"name", "size"}]}`
  - 测试工具（`test/support/lan_share_fixtures.dart`）：`setUpTestStorage(String prefix) → Future<Directory>`、`tearDownTestStorage(Directory)`、`class TestPaths`、`class MemoryDownloadRepository implements IDownloadRepository`（含 `records` map）、`writeCompletedEpisode({...}) → Future<DownloadEpisode>`、`testRecord(Map<int, DownloadEpisode>, {int bangumiId = 123, String pluginName = 'source'})`、`bytesOf(int length, {int seed = 0}) → List<int>`

- [ ] **Step 1: 写测试工具 `test/support/lan_share_fixtures.dart`**

```dart
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
```

- [ ] **Step 2: 写失败测试 `test/lan_share_server_test.dart`**

```dart
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
        if (name != null) 'name': name,
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

  test('five wrong codes replace the pairing code', () async {
    final original = server.pairingCode;
    final wrong = original == '000000' ? '111111' : '000000';
    for (var i = 1; i < LanShareProtocol.maxPairFailures; i++) {
      final (status, body, _) =
          await send('POST', LanShareProtocol.pairPath, body: {'code': wrong});
      expect(status, HttpStatus.unauthorized);
      expect((body as Map)['error'], LanShareErrorCode.badCode);
    }
    final (status, body, _) =
        await send('POST', LanShareProtocol.pairPath, body: {'code': wrong});
    expect(status, HttpStatus.tooManyRequests);
    expect((body as Map)['error'], LanShareErrorCode.codeRotated);
    expect(server.pairingCode, isNot(original));

    final (retryStatus, _, _) =
        await send('POST', LanShareProtocol.pairPath, body: {'code': original});
    expect(retryStatus, HttpStatus.unauthorized);
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
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `flutter test test/lan_share_server_test.dart`
Expected: 编译失败，提示找不到 `lan_share_server.dart`

- [ ] **Step 4: 实现 `lib/services/lan_share/lan_share_server.dart`**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  })  : _repository = repository,
        deviceName = deviceName ?? localDeviceName(),
        _address = address ?? InternetAddress.anyIPv4,
        _random = random ?? Random.secure();

  final IDownloadRepository _repository;
  final String deviceName;

  /// First port to try; 0 lets the OS choose.
  final int port;
  final InternetAddress _address;
  final Random _random;

  static final _rangePattern = RegExp(r'^bytes=(\d+)-$');

  HttpServer? _server;
  String _pairingCode = '';
  int _pairFailures = 0;
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
    final body = await _readJson(request);
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
      _notify();
      await _sendError(request.response, HttpStatus.tooManyRequests,
          LanShareErrorCode.codeRotated, '错误次数过多，配对码已刷新');
      return;
    }
    await _sendError(request.response, HttpStatus.unauthorized,
        LanShareErrorCode.badCode, '配对码错误');
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    try {
      final decoded = jsonDecode(await utf8.decodeStream(request));
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
    final listed = LanShareProtocol.isSafeFileName(name) &&
        !LanShareProtocol.isTransientFileName(name) &&
        (await _listFiles(directory)).any((file) => file.name == name);
    final file = File(path.join(directory, name));
    if (!listed || !path.isWithin(directory, file.path)) {
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
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `flutter test test/lan_share_server_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze lib/services/lan_share/ test/lan_share_server_test.dart test/support/`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/services/lan_share/lan_share_server.dart test/support/lan_share_fixtures.dart test/lan_share_server_test.dart
git commit -m "feat(lan-share): serve completed downloads over the LAN"
```

---

### Task 5: 导入服务（本地状态、残留清理、写入记录）

**Files:**
- Create: `lib/services/lan_share/download_import_service.dart`
- Test: `test/download_import_service_test.dart`

**Interfaces:**
- Consumes:
  - Task 1 的 `downloadEpisodeDirectory`、`IDownloadManager.resolveDownloadBaseDir()`、`getAvailableStorage()`
  - Task 3 的 `LanShareRecord`、`LanShareEpisode`、`LanShareProtocol.isSafePluginName`、`LanShareErrorCode.badRequest`
  - `IDownloadManager.isDownloading`、`getLocalVideoPath`、`deleteEpisodeFiles`，以及 `IDownloadRepository.getRecord`、`putRecord`、`deleteEpisode`
- Produces:
  - `enum LocalEpisodeState { absent, completed, downloading, incomplete }`，以及 `bool get importable`
  - `class LanShareException(String code, String message, {int? statusCode})`，追加在 `lan_share_protocol.dart` 末尾，导入服务和客户端共用
  - `class DownloadImportService(IDownloadRepository, IDownloadManager)`，提供：
    - `localState(LanShareRecord, int) → LocalEpisodeState`
    - `episodeDirectory(LanShareRecord, int) → Future<String>`（插件名非法时抛 `LanShareException(badRequest)`）
    - `availableStorage(String) → Future<int>`
    - `discardLocal(LanShareRecord, int) → Future<void>`
    - `commit({required LanShareRecord record, required LanShareEpisode meta, required String directory, required int totalBytes}) → Future<DownloadEpisode>`

- [ ] **Step 1: 在 `lib/services/lan_share/lan_share_protocol.dart` 末尾追加异常类型**

```dart
/// A protocol-level failure carrying a [LanShareErrorCode].
class LanShareException implements Exception {
  const LanShareException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
```

- [ ] **Step 2: 写失败测试 `test/download_import_service_test.dart`**

```dart
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
    service = DownloadImportService(DownloadRepository(), _BaseDirManager(base));
  });

  Future<void> putLocal(Map<int, DownloadEpisode> episodes) =>
      GStorage.downloads.put('source_123', testRecord(episodes));

  group('localState', () {
    test('absent when nothing is downloaded', () {
      expect(service.localState(_remote(), 1), LocalEpisodeState.absent);
    });

    test('completed only when the entry file exists', () async {
      final done = await writeCompletedEpisode(
          base: base, episodeNumber: 1, files: {'playlist.m3u8': [1]});
      final missing = await writeCompletedEpisode(
          base: base, episodeNumber: 2, files: {'seg_00000.ts': [1]});
      await putLocal({1: done, 2: missing});

      expect(service.localState(_remote(), 1), LocalEpisodeState.completed);
      expect(service.localState(_remote(), 2), LocalEpisodeState.incomplete);
    });

    test('queued episodes count as downloading, paused as incomplete',
        () async {
      final pending = await writeCompletedEpisode(
          base: base,
          episodeNumber: 1,
          files: const {},
          status: DownloadStatus.pending);
      final paused = await writeCompletedEpisode(
          base: base,
          episodeNumber: 2,
          files: const {},
          status: DownloadStatus.paused);
      final failed = await writeCompletedEpisode(
          base: base,
          episodeNumber: 3,
          files: const {},
          status: DownloadStatus.failed);
      await putLocal({1: pending, 2: paused, 3: failed});

      expect(service.localState(_remote(), 1), LocalEpisodeState.downloading);
      expect(service.localState(_remote(), 2), LocalEpisodeState.incomplete);
      expect(service.localState(_remote(), 3), LocalEpisodeState.incomplete);
      expect(LocalEpisodeState.incomplete.importable, isTrue);
      expect(LocalEpisodeState.downloading.importable, isFalse);
    });
  });

  test('episode directory uses the configured download base', () async {
    expect(await service.episodeDirectory(_remote(), 4),
        path.join(base, '123_source', '4'));
  });

  test('unsafe plugin names cannot escape the download base', () async {
    for (final name in ['../evil', 'a/b', r'a\b', 'C:x']) {
      await expectLater(
        service.episodeDirectory(_remote(pluginName: name), 1),
        throwsA(isA<LanShareException>()
            .having((e) => e.code, 'code', LanShareErrorCode.badRequest)),
      );
    }
  });

  test('discardLocal removes leftovers but keeps other episodes', () async {
    final failed = await writeCompletedEpisode(
        base: base,
        episodeNumber: 1,
        files: {'seg_00099.ts': [9]},
        status: DownloadStatus.failed);
    final other = await writeCompletedEpisode(
        base: base, episodeNumber: 2, files: {'playlist.m3u8': [1]});
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
        record: _remote(), meta: _meta(1), directory: directory, totalBytes: 7);

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
    expect(DownloadManager().getLocalVideoPath(episode),
        path.join(directory, 'playlist.m3u8'));
  });

  test('commit merges into an existing record', () async {
    final other = await writeCompletedEpisode(
        base: base, episodeNumber: 2, files: {'video.mp4': [1]}, entry: 'video.mp4');
    await putLocal({2: other});

    await service.commit(
        record: _remote(),
        meta: _meta(1, entry: 'video.mp4'),
        directory: path.join(base, '123_source', '1'),
        totalBytes: 1);

    final stored = GStorage.downloads.get('source_123')!;
    expect(stored.episodes.keys.toSet(), {1, 2});
    expect(stored.createdAt, DateTime(2026, 9, 1));
    expect(stored.episodes[1]!.localM3u8Path,
        path.join(base, '123_source', '1', 'video.mp4'));
  });
}
```

- [ ] **Step 3: 运行测试，确认失败**

Run: `flutter test test/download_import_service_test.dart`
Expected: 编译失败，提示找不到 `download_import_service.dart`

- [ ] **Step 4: 实现 `lib/services/lan_share/download_import_service.dart`**

```dart
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
      LanShareRecord record, int episodeNumber) async {
    final base = await _downloadManager.resolveDownloadBaseDir();
    final directory = downloadEpisodeDirectory(
        base, record.bangumiId, record.pluginName, episodeNumber);
    if (!LanShareProtocol.isSafePluginName(record.pluginName) ||
        !path.isWithin(base, directory)) {
      throw const LanShareException(
          LanShareErrorCode.badRequest, '番剧来源名称包含本机不支持的字符');
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
        record.bangumiId, record.pluginName, episodeNumber,
        episode: local);
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
    final target = _repository.getRecord(record.key) ??
        DownloadRecord(record.bangumiId, record.bangumiName,
            record.bangumiCover, record.pluginName, {}, DateTime.now());
    target.episodes[meta.episodeNumber] = episode;
    await _repository.putRecord(target);
    return episode;
  }
}
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `flutter test test/download_import_service_test.dart test/lan_share_protocol_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze lib/services/lan_share/ test/download_import_service_test.dart`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/services/lan_share/lan_share_protocol.dart lib/services/lan_share/download_import_service.dart test/download_import_service_test.dart
git commit -m "feat(lan-share): import received episodes into local downloads"
```

---

### Task 6: 导入方 HTTP 客户端

**Files:**
- Create: `lib/services/lan_share/lan_share_client.dart`
- Test: `test/lan_share_client_test.dart`

**Interfaces:**
- Consumes: Task 3 的协议类、Task 5 的 `LanShareException`（在 `lan_share_protocol.dart` 中）、Task 4 的 `LanShareServer`（仅测试使用）
- Produces:
  - `class LanShareClient({required String host, required int port, required String deviceName, Duration connectTimeout = const Duration(seconds: 5)})`
  - `static ({String host, int port})? parseAddress(String input)`
  - `fetchInfo() → Future<LanShareInfo>`，会校验 app 和协议版本
  - `pair(String code) → Future<void>`
  - `fetchManifest() → Future<LanShareManifest>`
  - `fetchEpisodeMeta(String recordKey, int episodeNumber) → Future<LanShareEpisode>`
  - `fetchEpisodeFiles(String recordKey, int episodeNumber) → Future<List<LanShareFile>>`
  - `downloadFile({required String recordKey, required int episodeNumber, required LanShareFile file, required String directory, void Function(int delta)? onBytes}) → Future<void>`
  - `cancelActive()`：中断进行中的请求，之后客户端仍可继续使用
  - `close()`

- [ ] **Step 1: 写失败测试 `test/lan_share_client_test.dart`**

```dart
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
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/lan_share_client_test.dart`
Expected: 编译失败，提示找不到 `lan_share_client.dart`

- [ ] **Step 3: 实现 `lib/services/lan_share/lan_share_client.dart`**

```dart
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
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/lan_share_client_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze lib/services/lan_share/ test/lan_share_client_test.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/services/lan_share/lan_share_client.dart test/lan_share_client_test.dart
git commit -m "feat(lan-share): add resumable client for importing from another device"
```

---

### Task 7: 导入会话（多集编排）

**Files:**
- Create: `lib/services/lan_share/lan_import_session.dart`
- Test: `test/lan_import_session_test.dart`

**Interfaces:**
- Consumes: Task 6 的 `LanShareClient`；Task 5 的 `DownloadImportService` 和 `LocalEpisodeState`；Task 3 的协议类；`ensureDirectoryWritable`（`lib/utils/file_system.dart`）
- Produces:
  - `class LanShareInsufficientStorageException(int requiredBytes, int availableBytes)`
  - `enum LanImportStatus { waiting, transferring, done, skipped, failed }`
  - `class LanImportItem(LanShareRecord record, LanShareEpisode episode)`，含 `status`、`error`、`doneBytes`、`totalBytes`
  - `String describeLanShareError(Object error)`
  - `class LanImportSession({required LanShareClient client, required DownloadImportService importer, required List<LanImportItem> items, int parallelFiles = 4, List<Duration> retryDelays = const [1s, 2s, 4s], int reserveBytes = 100MB, void Function()? onEpisodeImported})`，提供 `run()`、`cancel()`、`isCancelled`、`isRunning`、`doneBytes`、`totalBytes`、`Stream<void> changes`

- [ ] **Step 1: 写失败测试 `test/lan_import_session_test.dart`**

```dart
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
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/lan_import_session_test.dart`
Expected: 编译失败，提示找不到 `lan_import_session.dart`

- [ ] **Step 3: 实现 `lib/services/lan_share/lan_import_session.dart`**

```dart
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
        return '错误次数过多，配对码已刷新，请查看共享设备上的新配对码';
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
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `flutter test test/lan_import_session_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: 运行全部 lan_share 相关测试与静态检查**

Run: `flutter test test/lan_share_protocol_test.dart test/lan_share_server_test.dart test/download_import_service_test.dart test/lan_share_client_test.dart test/lan_import_session_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze lib/services/lan_share/ test/`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/services/lan_share/lan_import_session.dart test/lan_import_session_test.dart
git commit -m "feat(lan-share): orchestrate multi-episode imports with resume and retry"
```

---

### Task 8: 局域网共享页

**Files:**
- Create: `lib/pages/download/lan_share_page.dart`
- Modify: `lib/pages/download/download_page_module.dart`

**Interfaces:**
- Consumes: Task 4 的 `LanShareServer` 和 `LanSharePortUnavailableException`；Task 2 的 `BackgroundDownloadService.acquire/release/lanShareOwner/updateNotification`；`formatBytes`（`lib/utils/format.dart`）；`SysAppBar`
- Produces: 路由 `/settings/download/lan-share`，以及 `LanSharePage({required IDownloadRepository repository})`

- [ ] **Step 1: 实现 `lib/pages/download/lan_share_page.dart`**

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/lan_share/lan_share_server.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/format.dart';

class LanSharePage extends StatefulWidget {
  const LanSharePage({super.key, required this.repository});

  final IDownloadRepository repository;

  @override
  State<LanSharePage> createState() => _LanSharePageState();
}

class _LanSharePageState extends State<LanSharePage> {
  final _background = BackgroundDownloadService();
  LanShareServer? _server;
  StreamSubscription<void>? _serverChanges;
  Timer? _ticker;
  List<String> _addresses = const [];
  bool _busy = false;
  String? _error;

  bool get _sharing => _server?.isRunning ?? false;

  @override
  void dispose() {
    unawaited(_stopSharing());
    super.dispose();
  }

  Future<void> _startSharing() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final server = LanShareServer(repository: widget.repository);
    try {
      await server.start();
    } catch (e) {
      KazumiLogger().w('LanSharePage: failed to start sharing', error: e);
      await server.dispose();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is LanSharePortUnavailableException
              ? e.toString()
              : '无法开启共享：$e';
        });
      }
      return;
    }
    final addresses = await LanShareServer.localAddresses();
    if (!mounted) {
      await server.dispose();
      return;
    }
    _server = server;
    _serverChanges = server.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // Byte counters change too often for change events; poll them instead.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && server.activeTransfers > 0) setState(() {});
    });
    setState(() {
      _addresses = addresses;
      _busy = false;
    });
    if (await _background.acquire(BackgroundDownloadService.lanShareOwner)) {
      await _background.updateNotification(
          title: '局域网共享中', text: '保持此页面打开，其他设备即可导入缓存');
    }
  }

  Future<void> _stopSharing() async {
    final server = _server;
    _server = null;
    _ticker?.cancel();
    _ticker = null;
    await _serverChanges?.cancel();
    _serverChanges = null;
    await server?.dispose();
    await _background.release(BackgroundDownloadService.lanShareOwner);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = _server;
    return Scaffold(
      appBar: const SysAppBar(title: Text('局域网共享')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  Card(
                    child: SwitchListTile(
                      title: const Text('开启共享'),
                      subtitle: const Text('同一局域网内的设备可以导入本机已下载完成的缓存'),
                      value: _sharing,
                      onChanged: _busy
                          ? null
                          : (value) =>
                              value ? _startSharing() : _stopSharing(),
                    ),
                  ),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  if (server != null && server.isRunning)
                    _buildSharingCard(theme, server),
                  _buildTips(theme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSharingCard(ThemeData theme, LanShareServer server) {
    final port = server.boundPort;
    final device = server.connectedDevice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text('在另一台设备的"从其他设备导入"中填写：',
                style: theme.textTheme.titleSmall),
            Text('地址', style: theme.textTheme.labelMedium),
            if (_addresses.isEmpty)
              Text('未检测到局域网地址，请确认已连接 Wi-Fi',
                  style: TextStyle(color: theme.colorScheme.error))
            else
              for (final address in _addresses)
                SelectableText('$address:$port',
                    style: theme.textTheme.titleLarge),
            Text('配对码', style: theme.textTheme.labelMedium),
            SelectableText(
              server.pairingCode,
              style: theme.textTheme.displaySmall?.copyWith(letterSpacing: 8),
            ),
            Text(device == null ? '等待连接…' : '已连接：$device'),
            if (server.activeTransfers > 0 || server.bytesSent > 0)
              Text('正在传输 ${server.activeTransfers} 个文件 · '
                  '已发送 ${formatBytes(server.bytesSent)}'),
          ],
        ),
      ),
    );
  }

  Widget _buildTips(ThemeData theme) {
    final tips = [
      '传输期间请保持此页面打开；离开页面会关闭共享，配对码随之失效。',
      '只会共享已经下载完成的集。',
      if (Platform.isWindows)
        '首次开启时，请在 Windows 防火墙弹窗中允许 Kazumi 访问"专用网络"。'
            '如果系统把当前网络识别为"公用网络"，其他设备将无法连接。',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        for (final tip in tips)
          Text('• $tip',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
```

- [ ] **Step 2: 注册路由**

把 `lib/pages/download/download_page_module.dart` 整体替换为：

```dart
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_page.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/lan_share_page.dart';
import 'package:kazumi/repositories/download_repository.dart';

final downloadModule = createModule(
  path: '/download',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => DownloadPage(
          controller: inject<DownloadController>(),
        ),
      )
      ..route(
        '/lan-share',
        child: (context, state) => LanSharePage(
          repository: inject<IDownloadRepository>(),
        ),
      );
  },
);
```

- [ ] **Step 3: 静态检查**

Run: `flutter analyze lib/pages/download/`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add lib/pages/download/lan_share_page.dart lib/pages/download/download_page_module.dart
git commit -m "feat(lan-share): add LAN share page"
```

---

### Task 9: 从其他设备导入页

**Files:**
- Create: `lib/pages/download/lan_import_page.dart`
- Modify: `lib/pages/download/download_page_module.dart`
- Modify: `lib/services/storage/settings_keys.dart`（`downloadDirectoryBookmark` 定义约在第 495 行；`all` 列表约在第 651 行）

**Interfaces:**
- Consumes:
  - Task 6 的 `LanShareClient`
  - Task 7 的 `LanImportSession`、`LanImportItem`、`LanImportStatus`、`describeLanShareError`
  - Task 5 的 `DownloadImportService` 和 `LocalEpisodeState`
  - Task 4 的 `localDeviceName()`
  - Task 1 的 `IDownloadManager.resolveDownloadBaseDir/getAvailableStorage`
  - `DownloadController.refreshRecords()`、`BackgroundDownloadService`、`formatBytes`、`formatSpeed`、`GeneralEmptyState`
- Produces: 设置项 `SettingsKeys.lanShareLastAddress`、路由 `/settings/download/lan-import`，以及 `LanImportPage({required IDownloadRepository repository, required IDownloadManager downloadManager, required DownloadController controller})`

- [ ] **Step 1: 新增设置项**

在 `lib/services/storage/settings_keys.dart` 中，`downloadDirectoryBookmark` 定义之后加入：

```dart
  /// `host:port` of the device last imported from over the LAN.
  static const lanShareLastAddress = SettingKey<String>(
    'lanShareLastAddress',
    '',
    group: SettingGroup.download,
  );
```

并在 `all` 列表中 `downloadDirectoryBookmark,` 之后加入 `lanShareLastAddress,`。

- [ ] **Step 2: 实现 `lib/pages/download/lan_import_page.dart`**

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/background_download_service.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/lan_share/download_import_service.dart';
import 'package:kazumi/services/lan_share/lan_import_session.dart';
import 'package:kazumi/services/lan_share/lan_share_client.dart';
import 'package:kazumi/services/lan_share/lan_share_protocol.dart';
import 'package:kazumi/services/lan_share/lan_share_server.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/format.dart';

class LanImportPage extends StatefulWidget {
  const LanImportPage({
    super.key,
    required this.repository,
    required this.downloadManager,
    required this.controller,
  });

  final IDownloadRepository repository;
  final IDownloadManager downloadManager;
  final DownloadController controller;

  @override
  State<LanImportPage> createState() => _LanImportPageState();
}

enum _Phase { connect, select, transfer, finished }

class _LanImportPageState extends State<LanImportPage> {
  static const _reserveBytes = 100 * 1024 * 1024;

  final _address = TextEditingController();
  final _code = TextEditingController();
  final _background = BackgroundDownloadService();
  late final _importer =
      DownloadImportService(widget.repository, widget.downloadManager);

  _Phase _phase = _Phase.connect;
  bool _busy = false;
  String? _error;
  LanShareClient? _client;
  LanShareManifest? _manifest;
  final Map<String, LocalEpisodeState> _states = {};
  final Set<String> _selected = {};
  int _availableBytes = -1;
  LanImportSession? _session;
  StreamSubscription<void>? _sessionChanges;
  Timer? _speedTicker;
  int _lastBytes = 0;
  double _speed = 0;

  static String _id(LanShareRecord record, LanShareEpisode episode) =>
      '${record.key}#${episode.episodeNumber}';

  static String _episodeTitle(LanShareEpisode episode) =>
      episode.episodeName.isNotEmpty
          ? episode.episodeName
          : '第${episode.episodeNumber}集';

  @override
  void initState() {
    super.initState();
    _address.text = GStorage.getSetting(SettingsKeys.lanShareLastAddress);
  }

  @override
  void dispose() {
    _session?.cancel();
    _sessionChanges?.cancel();
    _speedTicker?.cancel();
    _client?.close();
    unawaited(_background.release(BackgroundDownloadService.lanShareOwner));
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final address = LanShareClient.parseAddress(_address.text);
    if (address == null) {
      setState(() => _error = '请输入对方页面上显示的地址，例如 192.168.1.5:38291');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      setState(() => _error = '请输入 6 位配对码');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    _client?.close();
    _client = null;
    final client = LanShareClient(
        host: address.host, port: address.port, deviceName: localDeviceName());
    try {
      await client.fetchInfo();
      await client.pair(_code.text);
      final manifest = await client.fetchManifest();
      await GStorage.putSetting(
          SettingsKeys.lanShareLastAddress, _address.text.trim());
      final base = await widget.downloadManager.resolveDownloadBaseDir();
      await Directory(base).create(recursive: true);
      final available = await widget.downloadManager.getAvailableStorage(base);
      if (!mounted) {
        client.close();
        return;
      }
      _client = client;
      _manifest = manifest;
      _availableBytes = available;
      _selected.clear();
      _refreshStates(selectDefaults: true);
      setState(() {
        _phase = _Phase.select;
        _busy = false;
      });
    } catch (e) {
      client.close();
      if (e is! LanShareException) {
        KazumiLogger().w('LanImportPage: connect failed', error: e);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeLanShareError(e);
        });
      }
    }
  }

  void _disconnect() {
    _client?.close();
    _client = null;
    _manifest = null;
    _selected.clear();
    _states.clear();
    setState(() => _phase = _Phase.connect);
  }

  void _refreshStates({bool selectDefaults = false}) {
    _states.clear();
    for (final record in _manifest?.records ?? const <LanShareRecord>[]) {
      for (final episode in record.episodes) {
        final id = _id(record, episode);
        final state = _importer.localState(record, episode.episodeNumber);
        _states[id] = state;
        if (!state.importable) {
          _selected.remove(id);
        } else if (selectDefaults) {
          _selected.add(id);
        }
      }
    }
  }

  int get _selectedBytes {
    var total = 0;
    for (final record in _manifest?.records ?? const <LanShareRecord>[]) {
      for (final episode in record.episodes) {
        if (_selected.contains(_id(record, episode))) {
          total += episode.totalBytes;
        }
      }
    }
    return total;
  }

  Future<void> _startImport([List<LanImportItem>? retryItems]) async {
    final client = _client;
    final manifest = _manifest;
    if (client == null || manifest == null) return;
    final items = retryItems ??
        [
          for (final record in manifest.records)
            for (final episode in record.episodes)
              if (_selected.contains(_id(record, episode)))
                LanImportItem(record, episode),
        ];
    if (items.isEmpty) return;
    final session = LanImportSession(
      client: client,
      importer: _importer,
      items: items,
      reserveBytes: _reserveBytes,
      onEpisodeImported: widget.controller.refreshRecords,
    );
    _session = session;
    _sessionChanges = session.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _lastBytes = 0;
    _speed = 0;
    _speedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final done = session.doneBytes;
      _speed = max(0, done - _lastBytes).toDouble();
      _lastBytes = done;
      if (mounted) setState(() {});
    });
    setState(() => _phase = _Phase.transfer);
    if (await _background.acquire(BackgroundDownloadService.lanShareOwner)) {
      await _background.updateNotification(
          title: '正在从其他设备导入', text: '共 ${items.length} 集');
    }
    try {
      await session.run();
    } finally {
      _speedTicker?.cancel();
      _speedTicker = null;
      await _sessionChanges?.cancel();
      _sessionChanges = null;
      await _background.release(BackgroundDownloadService.lanShareOwner);
      widget.controller.refreshRecords();
      if (mounted) {
        _refreshStates();
        setState(() => _phase = _Phase.finished);
      }
    }
  }

  void _retryUnfinished() {
    final session = _session;
    if (session == null) return;
    _startImport([
      for (final item in session.items)
        if (item.status == LanImportStatus.failed ||
            item.status == LanImportStatus.waiting)
          LanImportItem(item.record, item.episode),
    ]);
  }

  void _backToSelect() {
    setState(() {
      _refreshStates();
      _session = null;
      _phase = _Phase.select;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: _phase != _Phase.transfer,
      child: Scaffold(
        appBar: const SysAppBar(title: Text('从其他设备导入')),
        body: switch (_phase) {
          _Phase.connect => _buildConnect(theme),
          _Phase.select => _buildSelect(theme),
          _Phase.transfer || _Phase.finished => _buildTransfer(theme),
        },
      ),
    );
  }

  Widget _buildConnect(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  Text('在另一台设备上打开"下载管理 → 局域网共享"并开启共享，'
                      '然后填写它显示的地址和配对码。'),
                  TextField(
                    controller: _address,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '地址',
                      hintText: '192.168.1.5:38291',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    onSubmitted: (_) => _connect(),
                    decoration: const InputDecoration(
                      labelText: '配对码',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  FilledButton.icon(
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.link_rounded),
                    label: Text(_busy ? '正在连接…' : '连接'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _buildSelect(ThemeData theme) {
    final manifest = _manifest!;
    if (manifest.records.isEmpty) {
      return GeneralEmptyState(
        icon: Icons.inbox_outlined,
        title: '对方没有已下载完成的缓存',
        actions: [
          FilledButton(onPressed: _disconnect, child: const Text('返回')),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('来自：${manifest.deviceName}',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final record in manifest.records)
                _buildRecordCard(record),
            ],
          ),
        ),
        _buildSelectBar(theme),
      ],
    );
  }

  Widget _buildRecordCard(LanShareRecord record) {
    final ids = [
      for (final episode in record.episodes)
        if (_states[_id(record, episode)]?.importable ?? false)
          _id(record, episode),
    ];
    final selectedCount = ids.where(_selected.contains).length;
    final bool? value = selectedCount == 0
        ? false
        : selectedCount == ids.length
            ? true
            : null;
    return Card(
      child: Column(
        children: [
          CheckboxListTile(
            tristate: true,
            value: value,
            onChanged: ids.isEmpty
                ? null
                : (_) => setState(() {
                      if (value == true) {
                        _selected.removeAll(ids);
                      } else {
                        _selected.addAll(ids);
                      }
                    }),
            title: Text(record.bangumiName,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${record.pluginName} · ${record.episodes.length} 集'),
          ),
          const Divider(height: 1),
          for (final episode in record.episodes)
            _buildEpisodeTile(record, episode),
        ],
      ),
    );
  }

  Widget _buildEpisodeTile(LanShareRecord record, LanShareEpisode episode) {
    final id = _id(record, episode);
    final state = _states[id] ?? LocalEpisodeState.absent;
    final label = switch (state) {
      LocalEpisodeState.absent => null,
      LocalEpisodeState.completed => '已存在',
      LocalEpisodeState.downloading => '本地正在下载，请先暂停或删除',
      LocalEpisodeState.incomplete => '将覆盖本地未完成的下载',
    };
    return CheckboxListTile(
      dense: true,
      value: _selected.contains(id),
      onChanged: state.importable
          ? (checked) => setState(() {
                if (checked == true) {
                  _selected.add(id);
                } else {
                  _selected.remove(id);
                }
              })
          : null,
      title: Text(_episodeTitle(episode)),
      subtitle: Text(
          [formatBytes(episode.totalBytes), if (label != null) label].join(' · ')),
    );
  }

  Widget _buildSelectBar(ThemeData theme) {
    final total = _selectedBytes;
    final notEnough =
        _availableBytes >= 0 && total + _reserveBytes > _availableBytes;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          spacing: 8,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('已选 ${_selected.length} 集 · ${formatBytes(total)}'),
                  if (_availableBytes >= 0)
                    Text(
                      notEnough
                          ? '本机剩余空间不足（剩余 ${formatBytes(_availableBytes)}）'
                          : '本机剩余 ${formatBytes(_availableBytes)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: notEnough
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            TextButton(onPressed: _disconnect, child: const Text('断开')),
            FilledButton(
              onPressed: _selected.isEmpty || notEnough ? null : _startImport,
              child: const Text('开始导入'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransfer(ThemeData theme) {
    final session = _session!;
    final finished = _phase == _Phase.finished;
    final total = session.totalBytes;
    final transferred = session.doneBytes;
    int count(LanImportStatus status) =>
        session.items.where((item) => item.status == status).length;
    final hasUnfinished = session.items.any((item) =>
        item.status == LanImportStatus.failed ||
        item.status == LanImportStatus.waiting);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Text(
                finished
                    ? (session.isCancelled ? '已取消' : '导入完成')
                    : '正在导入…',
                style: theme.textTheme.titleMedium,
              ),
              LinearProgressIndicator(
                value: total > 0 ? (transferred / total).clamp(0.0, 1.0) : null,
              ),
              Text(finished
                  ? '成功 ${count(LanImportStatus.done)} 集 · '
                      '跳过 ${count(LanImportStatus.skipped)} 集 · '
                      '失败 ${count(LanImportStatus.failed)} 集'
                  : '${formatBytes(transferred)} / ${formatBytes(total)} · '
                      '${formatSpeed(_speed)}'),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final item in session.items) _buildItemTile(theme, item),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: finished
                  ? [
                      if (hasUnfinished)
                        OutlinedButton(
                            onPressed: _retryUnfinished,
                            child: const Text('重试未完成的集')),
                      OutlinedButton(
                          onPressed: _backToSelect,
                          child: const Text('继续选择')),
                      FilledButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Text('完成')),
                    ]
                  : [
                      OutlinedButton(
                        onPressed: session.isCancelled ? null : session.cancel,
                        child: const Text('取消'),
                      ),
                    ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItemTile(ThemeData theme, LanImportItem item) {
    final colors = theme.colorScheme;
    final (IconData icon, Color color, String text) = switch (item.status) {
      LanImportStatus.waiting => (
          Icons.schedule_rounded,
          colors.outline,
          (_session?.isCancelled ?? false) ? '已取消' : '等待中',
        ),
      LanImportStatus.transferring => (
          Icons.downloading_rounded,
          colors.primary,
          '${formatBytes(item.doneBytes)} / ${formatBytes(item.totalBytes)}',
        ),
      LanImportStatus.done => (
          Icons.check_circle_rounded,
          colors.primary,
          '已导入',
        ),
      LanImportStatus.skipped => (
          Icons.remove_circle_outline_rounded,
          colors.outline,
          item.error ?? '已跳过',
        ),
      LanImportStatus.failed => (
          Icons.error_outline_rounded,
          colors.error,
          item.error ?? '失败',
        ),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text('${item.record.bangumiName} · ${_episodeTitle(item.episode)}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(text),
      trailing: item.status == LanImportStatus.transferring &&
              item.totalBytes > 0
          ? SizedBox(
              width: 64,
              child: LinearProgressIndicator(
                  value: (item.doneBytes / item.totalBytes).clamp(0.0, 1.0)),
            )
          : null,
    );
  }
}
```

- [ ] **Step 3: 注册路由**

在 `lib/pages/download/download_page_module.dart` 中加入 import：

```dart
import 'package:kazumi/pages/download/lan_import_page.dart';
import 'package:kazumi/services/download/download_manager.dart';
```

并在 `'/lan-share'` 路由之后追加：

```dart
      ..route(
        '/lan-import',
        child: (context, state) => LanImportPage(
          repository: inject<IDownloadRepository>(),
          downloadManager: inject<IDownloadManager>(),
          controller: inject<DownloadController>(),
        ),
      );
```

（同时删掉 `'/lan-share'` 路由末尾的分号。）

- [ ] **Step 4: 静态检查**

Run: `flutter analyze lib/pages/download/ lib/services/storage/settings_keys.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/pages/download/lan_import_page.dart lib/pages/download/download_page_module.dart lib/services/storage/settings_keys.dart
git commit -m "feat(lan-share): add import-from-device page"
```

---

### Task 10: 下载管理页入口、真机检查清单、全量验证

**Files:**
- Modify: `lib/pages/download/download_page.dart`（`build` 中 `appBar: const SysAppBar(title: Text('下载管理')),` 约在第 49 行）
- Create: `docs/superpowers/lan-share-manual-checklist.md`

**Interfaces:**
- Consumes: 路由 `/settings/download/lan-share` 和 `/settings/download/lan-import`

- [ ] **Step 1: 加入菜单入口**

把 `lib/pages/download/download_page.dart` 中的

```dart
      appBar: const SysAppBar(title: Text('下载管理')),
```

替换为

```dart
      appBar: SysAppBar(
        title: const Text('下载管理'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (route) => context.pushNamed(route),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: '/settings/download/lan-share',
                child: ListTile(
                  leading: Icon(Icons.wifi_tethering_rounded),
                  title: Text('局域网共享'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: '/settings/download/lan-import',
                child: ListTile(
                  leading: Icon(Icons.move_to_inbox_rounded),
                  title: Text('从其他设备导入'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
```

（`download_page.dart` 已经 import 了 `package:flutter_modular/flutter_modular.dart`，`context.pushNamed` 可以直接使用。）

- [ ] **Step 2: 写真机检查清单 `docs/superpowers/lan-share-manual-checklist.md`**

```markdown
# 局域网缓存共享：真机检查清单

准备：Android 手机和 Windows 电脑都装上同一版本的 Kazumi，并连接同一个 Wi-Fi（不要用访客网络）。手机上先下载好至少 2 集（最好一集是 m3u8 来源、一集是 mp4 来源），其中一集要带弹幕。

## 手机 → 电脑
- [ ] 手机：下载管理 → 右上角菜单 → 局域网共享 → 开启。页面显示 `IP:38291` 和 6 位配对码；通知栏出现"局域网共享中"。
- [ ] 电脑：下载管理 → 右上角菜单 → 从其他设备导入。输入地址和配对码后连接，列表按番剧分组显示手机上已完成的集。
- [ ] 电脑：故意输错配对码 5 次。第 5 次提示配对码已刷新，手机上显示的码随之变化。
- [ ] 电脑：勾选 2 集，开始导入。进度和速度正常显示；导入期间手机上显示"正在传输"。
- [ ] 导入中途把手机锁屏 1 分钟，传输不中断（或者恢复后能继续）。
- [ ] 导入中途关闭手机 Wi-Fi 10 秒再打开：当前这一集失败或继续；结束后点"重试未完成的集"，已下载的部分不会重新传。
- [ ] 完成后回到电脑的下载管理，两集显示为已完成；断开电脑外网后能离线播放，弹幕正常。
- [ ] 再次导入同一集时显示"已存在"，不能勾选。

## 电脑 → 手机
- [ ] 电脑：局域网共享 → 开启。首次开启时出现 Windows 防火墙弹窗，勾选"专用网络"并允许。
- [ ] 手机：从其他设备导入 → 输入电脑的地址和配对码 → 连接成功。
- [ ] 手机：导入 1 集，期间切到后台或锁屏，导入继续；完成后离线播放正常。
- [ ] 手机存储空间不足时（可以选一个很大的集测试），"开始导入"按钮被禁用，并提示剩余空间不足。

## 收尾
- [ ] 离开共享页面后，导入方再发请求会提示"共享已关闭或连接已失效"。
- [ ] 共享和下载同时进行时，结束其中一个不会让另一个被系统杀掉（Android 通知栏的服务仍然存在）。
```

- [ ] **Step 3: 全量验证**

Run: `flutter analyze`
Expected: 不出现由本次改动引入的新问题。如果存在历史遗留问题，与改动前 `git stash` 状态下的输出对比确认。

Run: `flutter test`
Expected: `All tests passed!`

- [ ] **Step 4: Commit**

```bash
git add lib/pages/download/download_page.dart docs/superpowers/lan-share-manual-checklist.md
git commit -m "feat(lan-share): add menu entries and manual test checklist"
```

---

## Self-Review Notes

- **规格覆盖**：
  - §2 交互：Task 8/9/10
  - §3.1 重构：Task 1/2
  - §3.2 界面：Task 8/9
  - §4 协议与鉴权：Task 3/4
  - §4.4 安全：Task 3/4/5/6
  - §5.1 连接：Task 6/9
  - §5.2 单集流程：Task 7
  - §5.3 状态与可选性：Task 5/9
  - §5.4 取消：Task 6/7
  - §6 错误处理：Task 6/7（`describeLanShareError`）、Task 8（端口被占用）
  - §7 测试：Task 1-7 的测试加 Task 10 的清单
- **与规格的细微差异（已同步修改规格）**：
  - 客户端用 `dart:io` 的 `HttpClient` 而不是 dio。原因：要强制直连、绕过用户配置的代理，还要以追加方式写入续传的流。
  - 文件列表接口的响应外面包了一层 `{"files": [...]}`。
  - 新增模块 `lan_import_session.dart`，负责编排多集导入。
  - 导入方额外校验插件名，防止用插件名做路径穿越。
- **空间检查**：`getAvailableStorage` 依赖平台通道。在不支持的平台上返回 -1，这时跳过检查，和现有下载功能的行为一致。
