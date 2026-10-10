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
  late final _importer = DownloadImportService(
    widget.repository,
    widget.downloadManager,
  );

  _Phase _phase = _Phase.connect;
  bool _disposed = false;
  bool _busy = false;
  bool _importing = false;
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
    // Set first: cancelling the session below makes the in-flight
    // _startImport run its `finally` after dispose().
    _disposed = true;
    _session?.cancel();
    _sessionChanges?.cancel();
    _speedTicker?.cancel();
    _client?.close();
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _alive => !_disposed && mounted;

  Future<void> _connect() async {
    if (_busy) return;
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
      host: address.host,
      port: address.port,
      deviceName: localDeviceName(),
    );
    try {
      await client.fetchInfo();
      await client.pair(_code.text);
      final manifest = await client.fetchManifest();
      await GStorage.putSetting(
        SettingsKeys.lanShareLastAddress,
        _address.text.trim(),
      );
      final base = await widget.downloadManager.resolveDownloadBaseDir();
      await Directory(base).create(recursive: true);
      final available = await widget.downloadManager.getAvailableStorage(base);
      if (!_alive) {
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
      if (_alive) {
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
    if (_importing) return;
    final client = _client;
    final manifest = _manifest;
    if (client == null || manifest == null) return;
    final items =
        retryItems ??
        [
          for (final record in manifest.records)
            for (final episode in record.episodes)
              if (_selected.contains(_id(record, episode)))
                LanImportItem(record, episode),
        ];
    if (items.isEmpty) return;
    _importing = true;
    final session = LanImportSession(
      client: client,
      importer: _importer,
      items: items,
      reserveBytes: _reserveBytes,
      onEpisodeImported: widget.controller.refreshRecords,
    );
    _session = session;
    _sessionChanges = session.changes.listen((_) {
      if (_alive) setState(() {});
    });
    _lastBytes = 0;
    _speed = 0;
    _speedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final done = session.doneBytes;
      _speed = max(0, done - _lastBytes).toDouble();
      _lastBytes = done;
      if (_alive) setState(() {});
    });
    setState(() => _phase = _Phase.transfer);
    try {
      try {
        if (await _background.acquire(
          BackgroundDownloadService.lanShareOwner,
        )) {
          await _background.updateNotification(
            title: '正在从其他设备导入',
            text: '共 ${items.length} 集',
          );
        }
      } catch (e) {
        KazumiLogger().w(
          'LanImportPage: failed to hold foreground service',
          error: e,
        );
      }
      await session.run();
    } finally {
      _speedTicker?.cancel();
      _speedTicker = null;
      unawaited(_sessionChanges?.cancel());
      _sessionChanges = null;
      try {
        await _background.release(BackgroundDownloadService.lanShareOwner);
      } catch (e) {
        KazumiLogger().w(
          'LanImportPage: failed to release foreground service',
          error: e,
        );
      }
      _importing = false;
      widget.controller.refreshRecords();
      if (_alive) {
        _refreshStates();
        setState(() => _phase = _Phase.finished);
      }
    }
  }

  void _retryUnfinished() {
    final session = _session;
    if (session == null || _importing) return;
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
              Text(
                '在另一台设备上打开"下载管理 → 局域网共享"并开启共享，'
                '然后填写它显示的地址和配对码。',
              ),
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
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
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
              Text(
                '来自：${manifest.deviceName}',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (final record in manifest.records) _buildRecordCard(record),
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
            title: Text(
              record.bangumiName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${record.pluginName} · ${record.episodes.length} 集',
            ),
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
      subtitle: Text([formatBytes(episode.totalBytes), ?label].join(' · ')),
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
                            : theme.colorScheme.onSurfaceVariant,
                      ),
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
    final hasUnfinished = session.items.any(
      (item) =>
          item.status == LanImportStatus.failed ||
          item.status == LanImportStatus.waiting,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Text(
                finished ? (session.isCancelled ? '已取消' : '导入完成') : '正在导入…',
                style: theme.textTheme.titleMedium,
              ),
              LinearProgressIndicator(
                value: total > 0 ? (transferred / total).clamp(0.0, 1.0) : null,
              ),
              Text(
                finished
                    ? '成功 ${count(LanImportStatus.done)} 集 · '
                          '跳过 ${count(LanImportStatus.skipped)} 集 · '
                          '失败 ${count(LanImportStatus.failed)} 集'
                    : '${formatBytes(transferred)} / ${formatBytes(total)} · '
                          '${formatSpeed(_speed)}',
              ),
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
                          child: const Text('重试未完成的集'),
                        ),
                      OutlinedButton(
                        onPressed: _backToSelect,
                        child: const Text('继续选择'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('完成'),
                      ),
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
      title: Text(
        '${item.record.bangumiName} · ${_episodeTitle(item.episode)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(text),
      trailing:
          item.status == LanImportStatus.transferring && item.totalBytes > 0
          ? SizedBox(
              width: 64,
              child: LinearProgressIndicator(
                value: (item.doneBytes / item.totalBytes).clamp(0.0, 1.0),
              ),
            )
          : null,
    );
  }
}
