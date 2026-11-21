import 'package:flutter/foundation.dart';

/// Library categories, as `browse` numbers them (PHONE-REMOTE.md).
enum LibraryCategory {
  all(0, 'All'),
  films(1, 'Films'),
  shows(2, 'Shows'),
  anime(3, 'Anime');

  const LibraryCategory(this.number, this.label);
  final int number;
  final String label;
}

/// What to list: Home, a category (searched or not), or inside a show.
@immutable
class BrowseRequest {
  const BrowseRequest({this.home = false, this.category = LibraryCategory.all, this.query = '', this.parentId, this.season, this.page = 0, this.seed = 0});

  final bool home;
  final LibraryCategory category;
  final String query;
  final String? parentId;
  final int? season;
  final int page;
  final int seed;

  BrowseRequest nextPage() => BrowseRequest(home: home, category: category, query: query, parentId: parentId, season: season, page: page + 1, seed: seed);

  Map<String, dynamic> toJson() => {
    'home': home,
    'category': category.number,
    'query': query.length > 100 ? query.substring(0, 100) : query,
    'parentId': parentId,
    'season': season,
    'page': page,
    'seed': seed,
  };

  @override
  bool operator ==(Object other) =>
      other is BrowseRequest &&
      other.home == home &&
      other.category == category &&
      other.query == query &&
      other.parentId == parentId &&
      other.season == season &&
      other.page == page &&
      other.seed == seed;
  @override
  int get hashCode => Object.hash(home, category, query, parentId, season, page, seed);
}

/// One card in a library page.
@immutable
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.title,
    this.caption = '',
    this.level = 'movie',
    this.season,
    this.episode,
    this.overview = '',
    this.kind = 'Movie',
    this.runtimeMinutes,
    this.year,
    this.episodes = 0,
    this.homeSection,
    this.positionMs = 0,
    this.watched = false,
    this.artwork,
    this.playable = false,
  });

  final String id;
  final String title;
  final String caption;

  /// `series`, `season`, `episode` or `movie`.
  final String level;
  final int? season;
  final int? episode;
  final String overview;
  final String kind;
  final int? runtimeMinutes;
  final int? year;
  final int episodes;

  /// `continue`, `suggestions` or `mystery` on Home.
  final String? homeSection;

  /// The PC's resume point for a playable entry.
  final int positionMs;
  final bool watched;

  /// The picture's token for `art/<token>/<width>`.
  final String? artwork;

  /// A file the phone can watch or the PC can play.
  final bool playable;

  /// Opens a list (a show's seasons, a season's episodes) rather than a video.
  bool get opensList => !playable && (level == 'series' || level == 'season');

  int get durationMs => (runtimeMinutes ?? 0) * 60000;

  /// How far along the PC's resume point is, from 0 to 1, or null when it hasn't started.
  double? get progress {
    if (watched || positionMs < 10000 || durationMs <= 0) return null;
    return (positionMs / durationMs).clamp(0.02, 1.0);
  }

  LibraryEntry withPlayback({required int positionMs, required bool watched}) => LibraryEntry(
    id: id,
    title: title,
    caption: caption,
    level: level,
    season: season,
    episode: episode,
    overview: overview,
    kind: kind,
    runtimeMinutes: runtimeMinutes,
    year: year,
    episodes: episodes,
    homeSection: homeSection,
    positionMs: positionMs,
    watched: watched,
    artwork: artwork,
    playable: playable,
  );

  static LibraryEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    String text(String name) => value[name] is String ? value[name] as String : '';
    String? optional(String name) => value[name] is String && (value[name] as String).isNotEmpty ? value[name] as String : null;
    int? number(String name) => value[name] is num && (value[name] as num).isFinite ? (value[name] as num).round() : null;
    final id = text('id');
    if (id.isEmpty) return null;
    return LibraryEntry(
      id: id,
      title: text('title').isEmpty ? 'Untitled' : text('title'),
      caption: text('caption'),
      level: text('level').isEmpty ? 'movie' : text('level'),
      season: number('season'),
      episode: number('episode'),
      overview: text('overview'),
      kind: text('kind').isEmpty ? 'Movie' : text('kind'),
      runtimeMinutes: number('runtimeMinutes'),
      year: number('year'),
      episodes: number('episodes') ?? 0,
      homeSection: optional('homeSection'),
      positionMs: (number('positionMs') ?? 0).clamp(0, 1 << 50),
      watched: value['watched'] == true,
      artwork: optional('artwork'),
      playable: value['playable'] == true,
    );
  }
}

@immutable
class LibraryPage {
  const LibraryPage({required this.entries, required this.total, required this.page, required this.pageSize, required this.location});
  final List<LibraryEntry> entries;
  final int total;
  final int page;
  final int pageSize;
  final String location;

  bool get hasMore => (page + 1) * pageSize < total;

  static LibraryPage fromJson(Map<String, dynamic> json) {
    final entries = json['entries'];
    int number(String name, int fallback) => json[name] is num ? (json[name] as num).round() : fallback;
    return LibraryPage(
      entries: entries is List ? entries.map(LibraryEntry.fromJson).whereType<LibraryEntry>().toList() : const [],
      total: number('total', 0),
      page: number('page', 0),
      pageSize: number('pageSize', 40).clamp(1, 1000),
      location: json['location'] is String ? json['location'] as String : '',
    );
  }
}

/// How the phone reads the video it asked to watch.
@immutable
class StreamInfo {
  const StreamInfo({
    required this.id,
    required this.title,
    this.detail,
    this.positionMs = 0,
    this.durationMs = 0,
    required this.hls,
    this.resource,
    this.length = 0,
    this.extension = '',
    this.streamId,
    this.segments = 0,
    this.segmentMs = 4000,
    this.quality = 'original',
    this.qualities = const ['original'],
    this.note,
  });

  final String id;
  final String title;
  final String? detail;

  /// Where to start.
  final int positionMs;
  final int durationMs;

  /// A conversion in pieces (true), or the file itself.
  final bool hls;
  final String? resource;
  final int length;
  final String extension;
  final String? streamId;
  final int segments;
  final int segmentMs;
  final String quality;
  final List<String> qualities;
  final String? note;

  static StreamInfo? fromJson(Map<String, dynamic> json) {
    String? text(String name) => json[name] is String && (json[name] as String).isNotEmpty ? json[name] as String : null;
    int number(String name) => json[name] is num && (json[name] as num).isFinite ? (json[name] as num).round() : 0;
    final id = text('id');
    final hls = json['kind'] == 'hls';
    if (id == null) return null;
    if (hls ? text('streamId') == null || number('segments') <= 0 : text('resource') == null || number('length') <= 0) return null;
    final qualities = json['qualities'];
    return StreamInfo(
      id: id,
      title: text('title') ?? 'Video',
      detail: text('detail'),
      positionMs: number('positionMs').clamp(0, 1 << 50),
      durationMs: number('durationMs').clamp(0, 1 << 50),
      hls: hls,
      resource: text('resource'),
      length: number('length'),
      extension: text('extension') ?? '',
      streamId: text('streamId'),
      segments: number('segments'),
      segmentMs: number('segmentMs') <= 0 ? 4000 : number('segmentMs'),
      quality: text('quality') ?? 'original',
      qualities: qualities is List ? qualities.whereType<String>().toList() : const ['original'],
      note: text('note'),
    );
  }

  /// The pieces as an HLS playlist, as the desktop app's viewers play a room's conversion. [piece] gives each
  /// piece's address.
  String playlist(String Function(int index) piece) {
    final seconds = segmentMs / 1000.0;
    final buffer = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:${seconds.ceil()}\n#EXT-X-MEDIA-SEQUENCE:0\n');
    for (var index = 0; index < segments; index++) {
      var length = seconds;
      if (durationMs > 0) length = (durationMs / 1000.0 - index * seconds).clamp(0.001, seconds);
      buffer
        ..write('#EXTINF:${length.toStringAsFixed(3)},\n')
        ..write(piece(index))
        ..write('\n');
    }
    buffer.write('#EXT-X-ENDLIST\n');
    return buffer.toString();
  }
}

/// A quality's name on screen.
String qualityLabel(String id) => switch (id) {
  'original' => 'Original file',
  'auto' => 'Automatic',
  _ => id,
};
