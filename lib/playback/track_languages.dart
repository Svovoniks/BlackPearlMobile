import 'package:media_kit/media_kit.dart';

import '../protocol/library.dart';
import 'language_table.dart';

/// Track languages as the desktop app reads them (its TrackLanguages): any name or code of a language becomes its
/// two-letter code, and the starting audio and subtitles are picked by the PC's priority lists.
class TrackLanguages {
  TrackLanguages._();

  /// The two-letter code of a language name or code (`eng`, `English`, `en-US`), or null when it isn't one.
  static String? normalize(String? language) {
    final value = language?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    final code = languageCodes[value];
    if (code != null) return code;
    return languageCodes[value.split(RegExp('[-_]')).first];
  }

  static final RegExp _separators = RegExp(r'[\s\[\]():,;/]+');

  /// A track's language: its tag, or else a language named in its title.
  static String? languageOf(String? language, String? title) =>
      normalize(language) ?? (title ?? '').split(_separators).map(normalize).whereType<String>().firstOrNull;

  /// The subtitle priorities while the audio is in [audioLanguage]: its rule's, or the general ones.
  static List<String> subtitlePreferences(String? audioLanguage, TrackPreferences preferences) =>
      preferences.rules.where((rule) => rule.audio == audioLanguage).firstOrNull?.languages ?? preferences.subtitles;

  /// The first track in a preferred language, in priority order; for subtitles, `off` first means none (returns
  /// [off]). Null when no preference matches.
  static T? select<T>(List<T> tracks, List<String> preferences, String? Function(T) language, {T? off}) {
    for (final preference in preferences) {
      if (preference == 'off') {
        if (off != null) return off;
        continue;
      }
      for (final track in tracks) {
        if (language(track) == preference) return track;
      }
    }
    return null;
  }

  /// A language's name on screen: `English`, or the tag itself when it isn't a known language.
  static String? displayName(String? language) {
    final code = normalize(language);
    if (code != null) return languageNames[code] ?? language;
    return language == null || language.trim().isEmpty ? null : language.trim();
  }
}

/// How a track reads in the player's menu: the language first, then what tells it from the others.
class TrackLabel {
  const TrackLabel(this.name, this.detail);
  final String name;
  final String? detail;

  @override
  String toString() => detail == null ? name : '$name · $detail';
}

/// Labels for an audio list, numbered where two would read the same.
List<TrackLabel> audioLabels(List<AudioTrack> tracks) => _numbered([
  for (final track in tracks)
    _label(track.language, track.title, track.id, [
      ?_channels(track.channelscount, track.channels),
      ?_codec(track.codec),
    ]),
]);

/// Labels for a subtitle list, numbered where two would read the same.
List<TrackLabel> subtitleLabels(List<SubtitleTrack> tracks) => _numbered([
  for (final track in tracks)
    _label(track.language, track.title, track.id, [
      ?_codec(track.codec),
    ]),
]);

TrackLabel _label(String? language, String? title, String id, List<String> extras) {
  final name = TrackLanguages.displayName(language);
  final cleanTitle = title?.trim();
  // A title that only repeats the language ("English", "ENG") says nothing more.
  final hasTitle = cleanTitle != null && cleanTitle.isNotEmpty;
  if (name == null) {
    return TrackLabel(hasTitle ? cleanTitle : 'Track $id', extras.isEmpty ? null : extras.join(' · '));
  }
  final titleSaysMore = hasTitle && TrackLanguages.normalize(cleanTitle) != TrackLanguages.normalize(language);
  final detail = [if (titleSaysMore) cleanTitle, ...extras];
  return TrackLabel(name, detail.isEmpty ? null : detail.join(' · '));
}

List<TrackLabel> _numbered(List<TrackLabel> labels) {
  final counts = <String, int>{};
  for (final label in labels) {
    counts[label.toString()] = (counts[label.toString()] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return [
    for (final label in labels)
      if ((counts[label.toString()] ?? 0) > 1)
        TrackLabel(label.name, [if (label.detail != null) label.detail!, '${seen[label.toString()] = (seen[label.toString()] ?? 0) + 1}'].join(' · '))
      else
        label,
  ];
}

String? _channels(int? count, String? layout) {
  final value = layout?.trim().toLowerCase();
  if (value != null && value.isNotEmpty) {
    if (value == 'mono') return 'Mono';
    if (value == 'stereo') return 'Stereo';
    final surround = RegExp(r'^(\d+\.\d)').firstMatch(value);
    if (surround != null) return surround.group(1);
  }
  return switch (count) {
    null || 0 => null,
    1 => 'Mono',
    2 => 'Stereo',
    6 => '5.1',
    8 => '7.1',
    _ => '$count channels',
  };
}

String? _codec(String? codec) => switch (codec?.toLowerCase()) {
  null || '' => null,
  'subrip' || 'srt' => 'SRT',
  'ass' || 'ssa' => 'ASS',
  'hdmv_pgs_subtitle' || 'pgssub' => 'PGS',
  'dvd_subtitle' || 'dvdsub' => 'VobSub',
  'mov_text' => null,
  'webvtt' => 'WebVTT',
  'aac' => 'AAC',
  'ac3' => 'AC3',
  'eac3' => 'E-AC3',
  'dts' => 'DTS',
  'truehd' => 'TrueHD',
  'flac' => 'FLAC',
  'opus' => 'Opus',
  'vorbis' => 'Vorbis',
  'mp3' => 'MP3',
  final other => other.toUpperCase(),
};
