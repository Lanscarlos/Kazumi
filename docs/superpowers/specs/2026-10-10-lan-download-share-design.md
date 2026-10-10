# 局域网缓存共享（多设备共享离线缓存）设计

- 日期：2026-10-10
- 状态：已审阅

## 1. 背景与目标

用户白天在网络好的地方用手机（Android）缓存番剧，晚上回家在网络差的环境下用电脑（Windows）观看。家里的外网慢，但局域网（同一路由器下）快。

目标：让 Kazumi 在同一局域网内的两台设备之间**手动**传输已完成的离线缓存，传过去之后在接收端的下载列表中显示，可以直接离线播放（弹幕缓存一起带上）。

- 主要场景：手机 → 电脑。
- 反向场景：电脑 → 手机（例如出门前把电脑上的缓存拷到手机上）。
- 首要验证平台：Android ↔ Windows。代码不区分平台，macOS/Linux 上入口同样显示，但这次不做验证。

### 不在本次范围内

- 双向**同步**：一端删除的缓存不会传播到另一端，两端不会自动保持一致。
- 远程删除共享端的缓存。
- 局域网自动发现（mDNS/UDP 广播），以及后台全自动同步。
- "导出包 + 手动拷贝"方案。
- 文件哈希校验。
- 观看进度同步（现有的 WebDAV 同步已经覆盖）。
- Web 平台。

## 2. 交互模型

统一规则：**谁要接收，就在谁那里点"从其他设备导入"。**

- **共享方**：打开"局域网共享"页面并开启开关。页面显示本机 IP、端口和 6 位配对码。
- **导入方**：打开"从其他设备导入"页面，输入 `IP:端口` 和配对码，连接成功后勾选要导入的集，点击开始。

传输期间，共享方要停留在共享页面（Android 上有前台服务保活，锁屏不会中断）。

两个页面的入口都放在"下载管理"页（`lib/pages/download/download_page.dart`）AppBar 的菜单里。

## 3. 架构与模块

新增目录 `lib/services/lan_share/`：

| 模块 | 运行在哪端 | 职责 | 依赖 |
|---|---|---|---|
| `lan_share_protocol.dart` | 两端共用 | 协议常量（版本号、默认端口、接口路径）、清单/元数据/文件列表的数据结构与 JSON 序列化、文件名校验、配对码与令牌生成规则。纯 Dart，不碰 IO | 无 |
| `lan_share_server.dart` | 共享方 | 基于 `dart:io` 的 `HttpServer` 监听局域网端口；配对与令牌鉴权、错码锁定；读取下载记录生成清单；提供文件下载（支持 Range） | `IDownloadRepository`、文件系统 |
| `lan_share_client.dart` | 导入方 | 连接、配对、拉取清单与单集信息；把文件下载到临时文件，校验大小后改名；支持续传和中断进行中的请求；通过回调报告字节进度 | `dart:io` 的 `HttpClient`（强制直连，绕过用户配置的代理；续传时以追加方式写入） |
| `lan_import_session.dart` | 导入方 | 编排多集导入：逐集进行、集内并发、重试、空间检查、清理多余文件、取消，以及错误文案 | 客户端、导入服务 |
| `download_import_service.dart` | 导入方 | 处理导入前的冲突（清掉本地失败或暂停的残留），以及导入完成后写入或合并本地 `DownloadRecord`/`DownloadEpisode`（按本地规则重建路径） | `IDownloadRepository`、`IDownloadManager` |

### 3.1 相关的小重构

- **集目录规则提取成公共函数**：`<base>/<bangumiId>_<pluginName>/<episodeNumber>` 这条规则目前在 `DownloadManager._getEpisodeDir`（`lib/services/download/download_manager.dart`）和 `lib/services/download/download_path_migration.dart` 里各写了一份。把它提取成公共函数 `downloadEpisodeDirectory(base, bangumiId, pluginName, episodeNumber)`，放在 `lib/utils/file_system.dart`，这两处和导入服务都改为调用它。
- **公开下载根目录的解析**：把 `DownloadManager._downloadBaseDir`（会考虑 Windows/macOS 的自定义目录和 macOS 安全书签）通过 `IDownloadManager` 公开为 `Future<String> resolveDownloadBaseDir()`，导入服务用它来确定目标目录。
- **前台服务改为多方共用**：`BackgroundDownloadService` 目前只服务于下载。改成按"持有方"计数：`acquire(owner)` 和 `release(owner)`，持有方包括 `download` 和 `lanShare`。只要还有持有方，服务就继续运行；最后一个持有方释放后才停止。这样可以避免出现"下载结束后把前台服务停掉，结果正在进行的共享或导入被系统杀掉"的情况。现有的下载调用点改为使用 `download` 持有方，行为不变。

### 3.2 界面

- **局域网共享页**（`lib/pages/download/lan_share_page.dart`）：
  - 一个开关。开启后启动服务，显示本机所有可用的 IPv4 局域网地址加端口，以及 6 位配对码。
  - 显示状态：未连接、已连接（对方设备名），以及正在传输的文件数和累计字节数。
  - 在 Android 上开启期间持有 `lanShare` 前台服务。
  - 关闭开关或离开页面时：停止服务，作废配对码和所有令牌，释放前台服务。
  - 在 Windows 上显示提示："首次开启时请在 Windows 防火墙弹窗中允许'专用网络'；如果系统把当前网络识别为'公用网络'，其他设备将无法连接。"
- **从其他设备导入页**（`lib/pages/download/lan_import_page.dart`）：
  - **连接区**：输入 `IP:端口`（上次成功连接的地址存进设置项 `lanShareLastAddress`，下次自动填入），以及配对码。
  - **列表区**：按番剧分组列出可导入的集，每集显示名称和大小。番剧和单集都可以勾选；底部显示已选总大小和本地剩余空间。各集的状态标记见 §5.3。
  - **传输区**：显示整体进度、当前集进度和速度，提供取消按钮。结束后显示汇总，例如"成功 N / 跳过 N / 失败 N（原因）"，失败的集可以一键重试。
  - 在 Android 上导入期间持有 `lanShare` 前台服务。

## 4. 通信协议（v1）

- 传输方式：HTTP/1.1 明文，仅限局域网使用。Android 的 `usesCleartextTraffic="true"` 已经开启。
- 端口：默认 `38291`，被占用时依次尝试 `38292` 到 `38299`，都失败就报错。页面上显示实际使用的端口。
- 监听地址：`0.0.0.0`（IPv4）。
- 所有响应都是 JSON（文件下载接口除外）。错误响应格式为 `{"error": "<code>", "message": "<说明>"}`。

### 4.1 鉴权

- 配对码：开启共享时用 `Random.secure()` 生成 6 位数字。
- `POST /api/v1/pair`，请求体 `{"code": "123456", "deviceName": "..."}`：
  - 配对码正确：返回 `{"token": "<32 字节随机数的十六进制>"}`。
  - 配对码错误：返回 401 `bad_code`。累计错 5 次后作废当前配对码，重新生成一个（共享页上显示的码随之更新），这次请求返回 429 `code_rotated`。
- 除 `/api/v1/info` 和 `/api/v1/pair` 外，所有接口都要带 `Authorization: Bearer <token>`，否则返回 401 `unauthorized`。
- 关闭共享后，所有令牌立即失效。

### 4.2 接口

| 方法与路径 | 是否需要鉴权 | 说明 |
|---|---|---|
| `GET /api/v1/info` | 否 | 返回 `{"app": "kazumi", "protocolVersion": 1, "deviceName": "..."}` |
| `POST /api/v1/pair` | 否 | 见 §4.1 |
| `GET /api/v1/manifest` | 是 | 按番剧列出**已完成**（`status == completed` 且入口文件存在）的集，详见 §4.3 |
| `GET /api/v1/episode/meta?record=<key>&ep=<n>` | 是 | 单集的完整元数据，包含 `danmakuData` 和 `danDanBangumiID` |
| `GET /api/v1/episode/files?record=<key>&ep=<n>` | 是 | 集目录下的文件列表 `{"files": [{"name", "size"}]}`，只列普通文件，排除 `.tmp`、`.lstmp`、子目录，以及不满足 §4.4 文件名规则的文件 |
| `GET /api/v1/episode/file?record=<key>&ep=<n>&name=<文件名>` | 是 | 下载单个文件，支持 `Range: bytes=<start>-`，返回 200 或 206 |

`record` 就是 `DownloadRecord.key`（`<pluginName>_<bangumiId>`），一律放在查询参数里，由 HTTP 层负责编码。

对应的集不存在或未完成时返回 404 `not_found`。

### 4.3 清单结构

```json
{
  "protocolVersion": 1,
  "deviceName": "...",
  "records": [
    {
      "key": "plugin_123",
      "bangumiId": 123,
      "bangumiName": "...",
      "bangumiCover": "https://...",
      "pluginName": "plugin",
      "createdAt": "2026-10-10T08:00:00.000Z",
      "episodes": [
        {
          "episodeNumber": 1,
          "episodeName": "...",
          "road": 0,
          "totalSegments": 300,
          "totalBytes": 412345678,
          "networkM3u8Url": "...",
          "episodePageUrl": "...",
          "completedAt": "2026-10-10T09:00:00.000Z",
          "entryFileName": "playlist.m3u8"
        }
      ]
    }
  ]
}
```

`entryFileName` 取自 `basename(localM3u8Path)`，值为 `playlist.m3u8` 或 `video.mp4`。

### 4.4 安全约束

- `name` 必须匹配 `^[A-Za-z0-9._-]+$`，不能是 `.` 或 `..`，并且必须出现在该集当前的文件列表里；否则返回 400 `bad_name`。
- 服务端只拼接"集目录 + 文件名"来读取文件，然后再确认解析后的路径仍然在集目录内。
- 只提供已完成的集的文件，不暴露其他任何路径。
- 导入方同样会校验：对方返回的文件名必须满足上述规则；插件名不能包含路径分隔符或 Windows 不允许的字符（`/ \ : * ? " < > |` 和控制字符），并且拼出来的集目录必须位于本地下载根目录之内。否则这一集失败，不写入任何文件。

## 5. 导入流程（导入方）

### 5.1 连接

1. 调用 `GET /info`：确认 `app == "kazumi"` 且 `protocolVersion` 与本端一致，不一致就提示"请把两端升级到同一版本"并停止。
2. 调用 `POST /pair` 获取令牌。
3. 调用 `GET /manifest`，结合本地数据算出每一集的状态（见 §5.3），然后渲染列表。

### 5.2 单集导入（多集依次进行，一集内最多同时下载 4 个文件）

1. 冲突预处理（导入服务负责）：如果本地有这一集，且状态是失败或已暂停，就通过 `IDownloadManager.deleteEpisodeFiles` 删除本地文件，再删除这一集的记录。
2. 调用 `GET /episode/meta` 和 `GET /episode/files`。
3. 确定目标目录：`downloadEpisodeDirectory(await resolveDownloadBaseDir(), bangumiId, pluginName, episodeNumber)`，并调用 `ensureDirectoryWritable`。
4. 检查磁盘空间：剩余空间 ≥（该集剩余要下载的字节数 + 100MB），否则这一集失败，原因是"磁盘空间不足"，同时停止后面的集。
5. 逐个处理文件：
   - 正式文件已存在且大小一致：跳过。
   - 否则下载到 `<name>.lstmp`。如果 `.lstmp` 已经存在，就从它当前的长度开始，用 `Range` 续传；如果它比远端文件还大，就删掉重新下载。
   - 下载完校验大小。大小一致就原子改名为正式文件名；不一致就删掉临时文件，算作一次失败。
   - 单个文件最多重试 3 次，间隔为 1 秒、2 秒、4 秒。
6. 所有文件就绪后，删除目录里不在远端列表中的多余文件（包括残留的 `.lstmp`）。
7. 写入记录（导入服务负责）：
   - 如果本地还没有 `DownloadRecord`（key 相同），就用清单里的番剧信息新建一条，`createdAt` 取当前时间。
   - 写入 `DownloadEpisode`：
     - 状态设为已完成，`progressPercent = 100`，`downloadedSegments = totalSegments`。
     - `downloadDirectory` 设为目标目录，`localM3u8Path` 设为"目标目录 / entryFileName"。
     - `totalBytes` 取远端文件大小之和。
     - `completedAt` 取当前时间，`errorMessage` 置空。
     - 其余字段（集名、线路、`networkM3u8Url`、`episodePageUrl`、`danmakuData`、`danDanBangumiID`）从远端元数据复制过来。
   - 只在这一步写入记录，所以没传完的集不会出现在下载列表里。

### 5.3 本地状态与可选性

| 本地这一集的状态 | 列表中的标记 | 默认是否勾选 | 能否勾选 |
|---|---|---|---|
| 不存在 | — | 是 | 能 |
| 已完成 | 已存在 | 否 | 不能（跳过） |
| 待下载、解析中、下载中（按记录状态判断，或 `IDownloadManager.isDownloading` 为 true） | 本地正在下载 | 否 | 不能，提示"请先暂停或删除" |
| 失败、已暂停 | 将覆盖本地未完成的下载 | 是 | 能 |

### 5.4 取消与中断

- 用户取消：中止所有进行中的请求，保留已经下载的正式文件和 `.lstmp`，不写入记录。下次导入同一集时按 §5.2 第 5 步续传。
- App 被关闭或进程被杀：效果同上。
- 注意：§5.2 第 1 步清理本地失败或暂停的残留后，即使取消导入，这些残留也不会恢复（它们本来就是未完成的下载）。导入页对这类集显示的"将覆盖本地未完成的下载"标记已经提前告知用户。

## 6. 错误处理

| 场景 | 导入方提示与处理 |
|---|---|
| 连接超时 | 提示检查：两台设备是否在同一个 Wi-Fi（不是访客网络，路由器没有开启"AP 隔离"）；共享页是否开着；IP 和端口是否正确；共享方是 Windows 时，防火墙是否放行了"专用网络" |
| `/info` 返回的不是 Kazumi，或协议版本不一致 | 提示"对方不是 Kazumi"或"请把两端升级到同一版本" |
| 401 `bad_code` | 提示"配对码错误" |
| 429 `code_rotated` | 提示"错误次数过多，配对码已刷新，请查看共享设备上的新配对码" |
| 传输中返回 401 `unauthorized`（共享方已关闭） | 停止传输，回到连接区，提示重新输入配对码；已下载的部分保留 |
| 404 `not_found` | 这一集失败，原因是"共享设备上该集已不存在"，继续传下一集 |
| 网络中断或重试用尽 | 这一集失败，原因是"网络中断"，继续传下一集；部分文件保留 |
| 磁盘空间不足 | 这一集失败，并停止后面的集 |
| 写入记录失败 | 这一集失败，记录日志（`KazumiLogger`） |

共享方的异常（端口全被占用、读取文件出错）都要记录日志。端口全被占用时，在共享页上提示"无法开启共享：端口被占用"。

## 7. 测试

### 7.1 单元测试

- `lan_share_protocol`：清单、元数据、文件列表的序列化往返；文件名校验，必须拒绝 `../a`、`..`、`.`、`a/b`、`a\b`、绝对路径、空字符串和非法字符。
- `downloadEpisodeDirectory`：生成的路径符合规则；现有的 `test/download_path_migration_test.dart` 继续通过。
- `download_import_service`（用临时目录里的 Hive 盒子，或一个假的仓库实现）：
  - 新建番剧记录
  - 合并到已有番剧，且不影响其他集
  - 已完成的集被跳过
  - 失败或已暂停的集先被清理再覆盖
  - 自定义下载根目录下的路径重建
  - 弹幕数据被带过来
- `BackgroundDownloadService` 的持有方计数：两个持有方都释放后服务才停止（把平台调用抽象出来，以便测试）。

### 7.2 集成测试（`flutter test`，本机 `127.0.0.1`）

在临时目录中准备好假的已完成下载（一集 m3u8 分片、一集 mp4），启动真实的 `LanShareServer`，再用真实的 `LanShareClient` 加导入服务去连接。覆盖：

- 完整导入两种格式，导入后记录和文件都正确，`getLocalVideoPath` 能返回入口文件路径
- 先预置一个只写了一半的 `.lstmp`，验证续传后内容完整
- 错码 5 次后返回 429，且配对码已更换
- 不带令牌或带错误令牌访问返回 401
- 路径穿越的文件名返回 400
- 未完成的集不出现在清单里

### 7.3 真机检查（由用户完成）

实现完成后提供一份检查清单，覆盖 Android → Windows 和 Windows → Android 两个方向，包括：首次连接、导入后离线播放（含弹幕）、锁屏时的传输、中途断网后续传、Windows 防火墙提示。

## 8. 涉及的文件（预估）

- 新增：
  - `lib/services/lan_share/lan_share_protocol.dart`
  - `lib/services/lan_share/lan_share_server.dart`
  - `lib/services/lan_share/lan_share_client.dart`
  - `lib/services/lan_share/download_import_service.dart`
  - `lib/pages/download/lan_share_page.dart`
  - `lib/pages/download/lan_import_page.dart`
  - 相应的测试文件
- 修改：
  - `lib/utils/file_system.dart`（集目录规则函数）
  - `lib/services/download/download_manager.dart`（调用公共函数，公开 `resolveDownloadBaseDir`）
  - `lib/services/download/download_path_migration.dart`（调用公共函数）
  - `lib/services/download/background_download_service.dart`（持有方计数）
  - `lib/pages/download/download_page.dart`（菜单入口）
  - `lib/pages/download/download_page_module.dart`（路由）
  - `lib/services/storage/settings_keys.dart`（设置项 `lanShareLastAddress`）
