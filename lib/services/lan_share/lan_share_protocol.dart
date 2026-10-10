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

/// A protocol-level failure carrying a [LanShareErrorCode].
class LanShareException implements Exception {
  const LanShareException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
