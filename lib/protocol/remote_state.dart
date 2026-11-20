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
    );
  }

  /// The position [elapsedMs] after the state arrived: advancing while playing, never past the end.
  int positionAfter(int elapsedMs) {
    if (!media) return 0;
    var position = positionMs + (playing && elapsedMs > 0 ? elapsedMs : 0);
    if (durationMs > 0 && position > durationMs) position = durationMs;
    return position;
  }

  RemoteState copyWith({int? positionMs, int? volume, bool? muted, bool? playing}) => RemoteState(
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
