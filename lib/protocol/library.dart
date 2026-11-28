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
  const BrowseRequest({
    this.home = false,
    this.category = LibraryCategory.all,
    this.query = '',
    this.parentId,
    this.season,
    this.page = 0,
    this.seed = 0,
    this.queue,
    this.episodesOf,
    this.unwatched = false,
  });

  final bool home;
  final LibraryCategory category;
  final String query;
  final String? parentId;
  final int? season;
  final int page;
  final int seed;

  /// A saved queue's videos in order, instead of a library listing.
  final String? queue;

  /// The episodes of the show [episodesOf] (an entry id) belongs to, in the order Previous and Next follow.
  final String? episodesOf;

  /// Every title not started yet, newest first, instead of a library listing (PCs that offer `unwatched`).
  final bool unwatched;

  BrowseRequest nextPage() => BrowseRequest(
    home: home,
    category: category,
    query: query,
    parentId: parentId,
    season: season,
    page: page + 1,
    seed: seed,
    queue: queue,
    episodesOf: episodesOf,
    unwatched: unwatched,
  );

  Map<String, dynamic> toJson() => {
    'home': home,
    'category': category.number,
    'query': query.length > 100 ? query.substring(0, 100) : query,
    'parentId': parentId,
    'season': season,
    'page': page,
    'seed': seed,
    'queue': ?queue,
    'episodesOf': ?episodesOf,
    if (unwatched) 'unwatched': true,
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
      other.seed == seed &&
      other.queue == queue &&
      other.episodesOf == episodesOf &&
      other.unwatched == unwatched;
  @override
  int get hashCode => Object.hash(home, category, query, parentId, season, page, seed, queue, episodesOf, unwatched);
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
    this.index,
  });

  /// In a queue's or a show's list (BrowseRequest.queue, episodesOf): its place, which watch and play take back.
  final int? index;

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

  /// `continue`, `suggestions`, `mystery` or `unwatched` on Home.
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
    index: index,
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
      index: number('index'),
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
    this.convertible = false,
    this.previous,
    this.next,
    this.first,
    this.tracks = TrackPreferences.none,
    this.queue,
    this.sourceAudio,
    this.audioTrack,
    this.sourceSubtitles,
    this.subtitleTrack,
  });

  final String id;
  final String title;
  final String? detail;

  /// A conversion's choice of sound: the file's audio tracks, of which it carries the one at [audioTrack] (null: none).
  /// Null from PCs before 0.3.143, whose conversions had no sound, and for the file itself, whose tracks the player
  /// lists.
  final List<SourceAudio>? sourceAudio;
  final int? audioTrack;

  /// A conversion's subtitles: the file's subtitle tracks, each sent as a file the player draws or drawn into the
  /// picture by the PC ([SourceSubtitle.burn]), and the one to show at [subtitleTrack] (null: none). Null from PCs
  /// before 0.3.169, whose conversions had no subtitles, and for the file itself, whose tracks the player lists.
  final List<SourceSubtitle>? sourceSubtitles;
  final int? subtitleTrack;

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

  /// The file itself, sent in place of the conversion asked for only because the file is already as small as the
  /// conversion would be ([note] says so): asked again with `convertAnyway`, the PC converts it. Older PCs never say.
  final bool convertible;

  /// For an episode: what the PC's Previous and Next would play, and the show's first episode, where Loop all starts
  /// again after the last one. Null for a film, at either end, and from PCs that don't say.
  final EpisodeStep? previous, next, first;

  /// The PC's audio and subtitle language priorities, to start with the tracks it would.
  final TrackPreferences tracks;

  /// The saved queue this video plays from, and its place there; Previous, Next and Loop all then follow the queue.
  final QueueRef? queue;

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
      convertible: !hls && json['convertible'] == true,
      previous: EpisodeStep.fromJson(json['previous']),
      next: EpisodeStep.fromJson(json['next']),
      first: EpisodeStep.fromJson(json['first']),
      tracks: TrackPreferences.fromJson(json['tracks']),
      queue: QueueRef.fromJson(json['queue']),
      sourceAudio: hls ? SourceAudio.listFromJson(json['audioTracks']) : null,
      audioTrack: hls && json['audioTrack'] is int ? json['audioTrack'] as int : null,
      sourceSubtitles: hls ? SourceSubtitle.listFromJson(json['subtitleTracks']) : null,
      subtitleTrack: hls && json['subtitleTrack'] is int && (json['subtitleTrack'] as int) >= 0 ? json['subtitleTrack'] as int : null,
    );
  }

  /// A conversion's subtitle track at [index] of the file, as the PC lists it.
  SourceSubtitle? sourceSubtitle(int? index) => index == null ? null : sourceSubtitles?.where((s) => s.index == index).firstOrNull;

  /// The subtitle track the PC drew into this conversion's picture, or null.
  int? get burnedSubtitle => sourceSubtitle(subtitleTrack)?.burn == true ? subtitleTrack : null;

  /// Where the phone reads a conversion's subtitle track sent as a file.
  String subtitleResource(int index) => 'subtitle/$streamId/$index';

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

/// One of a file's audio tracks, as the PC lists them for a conversion: its place among the file's audio tracks, and
/// the language tag, title, codec and channel layout the file gives it.
class SourceAudio {
  const SourceAudio({required this.index, this.language, this.title, this.codec, this.layout});
  final int index;
  final String? language, title, codec, layout;

  static List<SourceAudio>? listFromJson(Object? json) {
    if (json is! List) return null;
    String? text(Map<String, dynamic> map, String name) => map[name] is String && (map[name] as String).isNotEmpty ? map[name] as String : null;
    return [
      for (final each in json)
        if (each is Map<String, dynamic> && each['index'] is int && (each['index'] as int) >= 0)
          SourceAudio(index: each['index'] as int, language: text(each, 'language'), title: text(each, 'title'), codec: text(each, 'codec'), layout: text(each, 'layout')),
    ];
  }
}

/// One of a file's subtitle tracks, as the PC lists them for a conversion: its place among the file's subtitle tracks,
/// the language tag, title and codec the file gives it, whether the file marks it as default or forced, and whether the
/// PC draws it into the picture ([burn]: pictures, and styled subtitles with fonts of their own) rather than sending it
/// as a file the player draws.
class SourceSubtitle {
  const SourceSubtitle({required this.index, this.language, this.title, this.codec, this.isDefault = false, this.forced = false, this.burn = false});
  final int index;
  final String? language, title, codec;
  final bool isDefault, forced, burn;

  static List<SourceSubtitle>? listFromJson(Object? json) {
    if (json is! List) return null;
    String? text(Map<String, dynamic> map, String name) => map[name] is String && (map[name] as String).isNotEmpty ? map[name] as String : null;
    return [
      for (final each in json)
        if (each is Map<String, dynamic> && each['index'] is int && (each['index'] as int) >= 0)
          SourceSubtitle(
            index: each['index'] as int,
            language: text(each, 'language'),
            title: text(each, 'title'),
            codec: text(each, 'codec'),
            isDefault: each['default'] == true,
            forced: each['forced'] == true,
            burn: each['burn'] == true,
          ),
    ];
  }
}

/// A video the player can step to: the next episode, or the next video of the queue it plays from.
class EpisodeStep {
  const EpisodeStep({required this.id, required this.title, this.detail, this.queueIndex});
  final String id;
  final String title;
  final String? detail;

  /// Its place in the queue the player plays from.
  final int? queueIndex;

  static EpisodeStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], title = json['title'], detail = json['detail'], place = json['queueIndex'];
    if (id is! String || id.isEmpty) return null;
    return EpisodeStep(
      id: id,
      title: title is String && title.isNotEmpty ? title : 'Episode',
      detail: detail is String && detail.isNotEmpty ? detail : null,
      queueIndex: place is num && place >= 0 ? place.round() : null,
    );
  }

  /// The step to a listed video.
  static EpisodeStep ofEntry(LibraryEntry entry, {bool inQueue = false}) =>
      EpisodeStep(id: entry.id, title: entry.title, detail: entry.caption.isEmpty ? null : entry.caption, queueIndex: inQueue ? entry.index : null);
}

/// A saved queue on the PC and a place in it.
@immutable
class QueueRef {
  const QueueRef({required this.id, required this.name, this.index});
  final String id;
  final String name;
  final int? index;

  QueueRef at(int? place) => QueueRef(id: id, name: name, index: place);

  static QueueRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], index = json['index'];
    if (id is! String || id.isEmpty) return null;
    return QueueRef(id: id, name: name is String && name.isNotEmpty ? name : 'Queue', index: index is num && index >= 0 ? index.round() : null);
  }

  @override
  bool operator ==(Object other) => other is QueueRef && other.id == id && other.index == index;
  @override
  int get hashCode => Object.hash(id, index);
}

/// One of the PC's saved queues, as its Queues page shows it.
@immutable
class QueueSummary {
  const QueueSummary({required this.id, required this.name, this.count = 0, this.upNext, this.active = false, this.artwork});
  final String id;
  final String name;

  /// Its videos that the library has.
  final int count;

  /// The place Play continues from, or null when everything in it is watched.
  final int? upNext;

  /// The queue the PC's player uses.
  final bool active;
  final String? artwork;

  QueueRef get ref => QueueRef(id: id, name: name);

  static List<QueueSummary> listFromJson(Map<String, dynamic> json) {
    final queues = json['queues'];
    if (queues is! List) return const [];
    return [
      for (final queue in queues.whereType<Map>())
        if (queue['id'] is String && (queue['id'] as String).isNotEmpty)
          QueueSummary(
            id: queue['id'] as String,
            name: queue['name'] is String && (queue['name'] as String).isNotEmpty ? queue['name'] as String : 'Queue',
            count: queue['count'] is num ? (queue['count'] as num).round() : 0,
            upNext: queue['upNext'] is num ? (queue['upNext'] as num).round() : null,
            active: queue['active'] == true,
            artwork: queue['artwork'] is String && (queue['artwork'] as String).isNotEmpty ? queue['artwork'] as String : null,
          ),
    ];
  }
}

/// The PC's Settings › Playback languages, as two-letter codes in priority order. A rule's languages replace
/// [subtitles] while the audio is in its language; `off` means no subtitles.
class TrackPreferences {
  const TrackPreferences({this.audio = const [], this.subtitles = const [], this.rules = const []});
  static const none = TrackPreferences();
  final List<String> audio;
  final List<String> subtitles;
  final List<SubtitleRule> rules;

  bool get isEmpty => audio.isEmpty && subtitles.isEmpty && rules.isEmpty;

  static List<String> _codes(Object? value) =>
      value is List ? value.whereType<String>().map((v) => v.trim().toLowerCase()).where((v) => v.isNotEmpty).toList() : const [];

  static TrackPreferences fromJson(Object? json) {
    if (json is! Map) return none;
    final rules = json['rules'];
    return TrackPreferences(
      audio: _codes(json['audio']),
      subtitles: _codes(json['subtitles']),
      rules: rules is List
          ? [
              for (final rule in rules.whereType<Map>())
                if (rule['audio'] is String) SubtitleRule(audio: (rule['audio'] as String).toLowerCase(), languages: _codes(rule['languages'])),
            ]
          : const [],
    );
  }
}

class SubtitleRule {
  const SubtitleRule({required this.audio, required this.languages});
  final String audio;
  final List<String> languages;
}

/// A quality's name on screen.
String qualityLabel(String id) => switch (id) {
  'original' => 'Original file',
  'auto' => 'Automatic',
  _ => id,
};
