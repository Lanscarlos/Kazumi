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
  bool _disposed = false;

  bool get _sharing => _server?.isRunning ?? false;

  @override
  void dispose() {
    _disposed = true;
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
      try {
        await server.dispose();
      } catch (e) {
        KazumiLogger().w('LanSharePage: failed to dispose server', error: e);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is LanSharePortUnavailableException
              ? e.toString()
              : '无法开启共享，请检查网络后重试';
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
    // Sharing still works without the foreground service, so failures here
    // are logged and otherwise ignored.
    try {
      if (await _background.acquire(BackgroundDownloadService.lanShareOwner)) {
        await _background.updateNotification(
            title: '局域网共享中', text: '保持此页面打开，其他设备即可导入缓存');
      }
    } catch (e) {
      KazumiLogger().w('LanSharePage: failed to hold foreground service',
          error: e);
    }
  }

  Future<void> _stopSharing() async {
    final server = _server;
    _server = null;
    // Keep the switch disabled until the server is fully down, so a new start
    // cannot overlap with this stop.
    _busy = true;
    if (!_disposed && mounted) setState(() {});
    _ticker?.cancel();
    _ticker = null;
    await _serverChanges?.cancel();
    _serverChanges = null;
    try {
      // Release before awaiting dispose so a start that begins meanwhile
      // cannot have its hold undone by this stop.
      await _background.release(BackgroundDownloadService.lanShareOwner);
    } catch (e) {
      KazumiLogger().w('LanSharePage: failed to release foreground service',
          error: e);
    }
    try {
      await server?.dispose();
    } catch (e) {
      KazumiLogger().w('LanSharePage: failed to stop sharing', error: e);
    } finally {
      _busy = false;
      if (!_disposed && mounted) setState(() {});
    }
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
