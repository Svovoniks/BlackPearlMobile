import 'library.dart';

/// The PC's `state` message (PHONE-REMOTE.md, "PC → phone").
enum LoopMode {
  off,
  all,
  one;

  static LoopMode parse(Object? value) => switch (value) {
    'all' => LoopMode.all,
    'one' => LoopMode.one,
    _ => LoopMode.off,
  };

  String get label => switch (this) {
    LoopMode.off => 'Off',
    LoopMode.all => 'All',
    LoopMode.one => 'One',
  };
}

class RemoteRoom {
  const RemoteRoom({required this.name, required this.people});
  final String name;
  final int people;

  @override
  bool operator ==(Object other) => other is RemoteRoom && other.name == name && other.people == people;
  @override
  int get hashCode => Object.hash(name, people);
}

/// A choice in the PC player's Audio or Subtitles menu, as the menu shows it (PHONE-REMOTE.md, "Tracks"). Off is -1.
class RemoteTrack {
  const RemoteTrack({required this.id, required this.name, this.detail});
  final int id;
  final String name;
  final String? detail;

  static const int off = -1;

  /// The tracks of a `state` list, or null when the PC sent none (one from before tracks on the remote).
  static List<RemoteTrack>? listFromJson(Object? value) {
    if (value is! List) return null;
    return [
      for (final item in value)
        if (item is Map && item['id'] is num && (item['id'] as num).isFinite)
          RemoteTrack(
            id: (item['id'] as num).round(),
            name: item['name'] is String && (item['name'] as String).trim().isNotEmpty ? (item['name'] as String).trim() : 'Track',
            detail: item['detail'] is String && (item['detail'] as String).trim().isNotEmpty ? (item['detail'] as String).trim() : null,
          ),
    ];
  }

  @override
  bool operator ==(Object other) => other is RemoteTrack && other.id == id && other.name == name && other.detail == detail;
  @override
  int get hashCode => Object.hash(id, name, detail);
}

class RemoteState {
  const RemoteState({
    required this.media,
    this.title = '',
    this.detail = '',
    this.playing = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.volume,
    this.muted = false,
    this.loop = LoopMode.off,
    this.fullscreen = false,
    this.hasPrevious = false,
    this.hasNext = false,
    this.canControl = true,
    this.room,
    this.mediaId,
    this.queue,
    this.shuffle,
    this.phoneSound,
    this.audioTracks,
    this.audioTrack,
    this.subtitleTracks,
    this.subtitleTrack,
    this.canChangeTracks = true,
  });

  /// False when nothing is loaded in the player; the playback fields are then meaningless.
  final bool media;
  final String title;
  final String detail;
  final bool playing;
  final int positionMs;
  final int durationMs;

  /// 0–100, or null when the PC didn't send it.
  final int? volume;
  final bool muted;
  final LoopMode loop;
  final bool fullscreen;
  final bool hasPrevious;
  final bool hasNext;

  /// False in a room where only whoever plays the video may control it.
  final bool canControl;
  final RemoteRoom? room;

  /// The library video the PC plays on its own, which the phone can take over; null in a room or for music.
  final String? mediaId;

  /// The saved queue the PC plays from and the video's place in it, or null.
  final QueueRef? queue;

  /// The PC's Shuffle; null from a PC without it.
  final bool? shuffle;

  /// True while a phone plays the PC's sound, which leaves the PC quiet ([muted] is then the PC's own mute from
  /// before); null from PCs that can't send their sound.
  final bool? phoneSound;

  /// The PC player's Audio and Subtitles menus; null from a PC without tracks on the remote, empty until the video has
  /// opened. Subtitles start with Off.
  final List<RemoteTrack>? audioTracks;
  final List<RemoteTrack>? subtitleTracks;

  /// The ticked choices' ids, or null when the menu has none ticked.
  final int? audioTrack;
  final int? subtitleTrack;

  /// False where the PC's menus are greyed out: in a room where only whoever plays the video picks tracks.
  final bool canChangeTracks;

  /// Whether the PC puts its track menus in the state.
  bool get hasTracks => audioTracks != null && subtitleTracks != null;

  static const RemoteState nothing = RemoteState(media: false);

  /// Parses a decoded `state` message. Missing, null or mistyped fields fall back to defaults,
  /// so a PC that leaves fields out (or sends them as null) still produces a usable state.
  static RemoteState fromJson(Map<String, dynamic> json) {
    bool flag(String name, bool fallback) => json[name] is bool ? json[name] as bool : fallback;
    int? number(String name) {
      final value = json[name];
      return value is num && value.isFinite ? value.round() : null;
    }

    String text(String name) => json[name] is String ? json[name] as String : '';
    final media = flag('media', false);
    final duration = number('durationMs');
    final position = number('positionMs');
    final volume = number('volume');
    RemoteRoom? room;
    final roomValue = json['room'];
    if (roomValue is Map) {
      final name = roomValue['name'];
      final people = roomValue['people'];
      room = RemoteRoom(name: name is String ? name : 'Room', people: people is num ? people.round() : 0);
    }
    return RemoteState(
      media: media,
      title: text('title'),
      detail: text('detail'),
      playing: media && flag('playing', false),
      positionMs: position == null || position < 0 ? 0 : position,
      durationMs: duration == null || duration < 0 ? 0 : duration,
      volume: volume?.clamp(0, 100),
      muted: flag('muted', false),
      loop: LoopMode.parse(json['loop']),
      fullscreen: flag('fullscreen', false),
      hasPrevious: flag('hasPrevious', false),
      hasNext: flag('hasNext', false),
      canControl: flag('canControl', true),
      room: room,
      mediaId: media && json['mediaId'] is String && (json['mediaId'] as String).isNotEmpty ? json['mediaId'] as String : null,
      queue: media ? QueueRef.fromJson(json['queue']) : null,
      shuffle: json['shuffle'] is bool ? json['shuffle'] as bool : null,
      phoneSound: json['phoneSound'] is bool ? json['phoneSound'] as bool : null,
      audioTracks: media ? RemoteTrack.listFromJson(json['audioTracks']) : null,
      audioTrack: media ? number('audioTrack') : null,
      subtitleTracks: media ? RemoteTrack.listFromJson(json['subtitleTracks']) : null,
      subtitleTrack: media ? number('subtitleTrack') : null,
      canChangeTracks: flag('canChangeTracks', true),
    );
  }

  /// The position [elapsedMs] after the state arrived: advancing while playing, never past the end.
  int positionAfter(int elapsedMs) {
    if (!media) return 0;
    var position = positionMs + (playing && elapsedMs > 0 ? elapsedMs : 0);
    if (durationMs > 0 && position > durationMs) position = durationMs;
    return position;
  }

  RemoteState copyWith({int? positionMs, int? volume, bool? muted, bool? playing, int? audioTrack, int? subtitleTrack}) => RemoteState(
    media: media,
    title: title,
    detail: detail,
    playing: playing ?? this.playing,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    loop: loop,
    fullscreen: fullscreen,
    hasPrevious: hasPrevious,
    hasNext: hasNext,
    canControl: canControl,
    room: room,
    mediaId: mediaId,
    queue: queue,
    shuffle: shuffle,
    phoneSound: phoneSound,
    audioTracks: audioTracks,
    audioTrack: audioTrack ?? this.audioTrack,
    subtitleTracks: subtitleTracks,
    subtitleTrack: subtitleTrack ?? this.subtitleTrack,
    canChangeTracks: canChangeTracks,
  );
}

extension RemoteStateTracks on RemoteState {
  /// This state with other track menus, a room, or the menus greyed out; for previews and tests.
  RemoteState withTracks({List<RemoteTrack>? audio, List<RemoteTrack>? subtitles, bool? canChange, RemoteRoom? room}) => RemoteState(
    media: media,
    title: title,
    detail: detail,
    playing: playing,
    positionMs: positionMs,
    durationMs: durationMs,
    volume: volume,
    muted: muted,
    loop: loop,
    fullscreen: fullscreen,
    hasPrevious: hasPrevious,
    hasNext: hasNext,
    canControl: canControl,
    room: room ?? this.room,
    mediaId: mediaId,
    queue: queue,
    shuffle: shuffle,
    audioTracks: audio ?? audioTracks,
    audioTrack: audio != null && audio.isEmpty ? null : audioTrack,
    subtitleTracks: subtitles ?? subtitleTracks,
    subtitleTrack: subtitles != null && subtitles.isEmpty ? null : subtitleTrack,
    canChangeTracks: canChange ?? canChangeTracks,
    phoneSound: phoneSound,
  );
}

/// Formats milliseconds as `m:ss` or `h:mm:ss`.
String formatClock(int ms) {
  final totalSeconds = (ms < 0 ? 0 : ms) ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  return '$minutes:$ss';
}
