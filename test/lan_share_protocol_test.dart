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
