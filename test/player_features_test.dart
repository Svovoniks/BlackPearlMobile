import 'package:blackpearl_mobile/playback/phone_playback.dart';
import 'package:blackpearl_mobile/playback/track_languages.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

StreamInfo stream({EpisodeStep? next, EpisodeStep? first}) =>
    StreamInfo(id: 'e5', title: 'Show · S02E05', hls: false, resource: 'file/e5', length: 10, next: next, first: first);

void main() {
  group('track languages, as the PC reads them', () {
    test('any name or code of a language is its two-letter code', () {
      expect(TrackLanguages.normalize('eng'), 'en');
      expect(TrackLanguages.normalize('English'), 'en');
      expect(TrackLanguages.normalize('en-US'), 'en');
      expect(TrackLanguages.normalize('zho'), 'zh');
      expect(TrackLanguages.normalize('chi'), 'zh');
      expect(TrackLanguages.normalize('jpn'), 'ja');
      expect(TrackLanguages.normalize('nob'), 'no', reason: 'Bokmål and Norwegian are one');
      expect(TrackLanguages.normalize('und'), isNull);
      expect(TrackLanguages.normalize(''), isNull);
    });

    test('an untagged track takes the language its title names', () {
      expect(TrackLanguages.languageOf(null, 'Japanese [Commentary]'), 'ja');
      expect(TrackLanguages.languageOf('rus', 'English'), 'ru', reason: 'the tag wins');
    });

    test('the first preference a track has wins; off picks none', () {
      final tracks = ['zh', 'en', 'ja'];
      expect(TrackLanguages.select(tracks, ['ja', 'en'], (t) => t), 'ja');
      expect(TrackLanguages.select(tracks, ['fr', 'en'], (t) => t), 'en');
      expect(TrackLanguages.select(tracks, ['fr'], (t) => t), isNull);
      expect(TrackLanguages.select(tracks, ['off', 'en'], (t) => t, off: 'none'), 'none');
    });

    test('an untagged track matches any language its title names, as on the PC', () {
      const tracks = [(tag: null, title: 'Russian dub [English cut]'), (tag: 'eng', title: 'Commentary')];
      String? language(({String? tag, String? title}) t) => TrackLanguages.languageOf(t.tag, t.title);
      expect(TrackLanguages.select(tracks, ['en'], language, named: (t) => t), tracks[0]);
      expect(TrackLanguages.select(tracks, ['ru'], language, named: (t) => t), tracks[0]);
    });

    test("a rule for the audio's language replaces the general subtitle priorities", () {
      const preferences = TrackPreferences(subtitles: ['en'], rules: [SubtitleRule(audio: 'en', languages: ['off'])]);
      expect(TrackLanguages.subtitlePreferences('en', preferences), ['off']);
      expect(TrackLanguages.subtitlePreferences('ja', preferences), ['en']);
      expect(TrackLanguages.subtitlePreferences(null, preferences), ['en']);
    });

    test('labels name the language and tell repeated ones apart', () {
      final audio = audioLabels([
        const AudioTrack('1', null, 'eng', channelscount: 6, codec: 'ac3'),
        const AudioTrack('2', 'Commentary', 'eng', channelscount: 2, codec: 'aac'),
        const AudioTrack('3', null, 'jpn', channels: 'stereo'),
      ]);
      expect(audio.map((l) => l.toString()), ['English · 5.1 · AC3', 'English · Commentary · Stereo · AAC', 'Japanese · Stereo']);
      final subtitles = subtitleLabels([
        const SubtitleTrack('1', null, 'eng', codec: 'mov_text'),
        const SubtitleTrack('2', null, 'eng', codec: 'mov_text'),
        const SubtitleTrack('3', 'English', 'eng', codec: 'subrip'),
        const SubtitleTrack('4', 'Signs', null),
      ]);
      expect(subtitles.map((l) => l.toString()), ['English · 1', 'English · 2', 'English · SRT', 'Signs']);
    });
  });

  group('the stream answer', () {
    test('carries the episode steps and the PC track preferences', () {
      final info = StreamInfo.fromJson({
        'id': 'e5',
        'kind': 'file',
        'resource': 'file/e5',
        'length': 10,
        'previous': {'id': 'e4', 'title': 'Show · S02E04', 'detail': 'Season 2 · Episode 4'},
        'next': {'id': 'e6', 'title': 'Show · S02E06'},
        'first': null,
        'tracks': {
          'audio': ['ja', 'en'],
          'subtitles': ['en'],
          'rules': [
            {'audio': 'en', 'languages': ['off']},
          ],
        },
      })!;
      expect(info.previous?.id, 'e4');
      expect(info.previous?.detail, 'Season 2 · Episode 4');
      expect(info.next?.id, 'e6');
      expect(info.first, isNull);
      expect(info.tracks.audio, ['ja', 'en']);
      expect(info.tracks.rules.single.languages, ['off']);
    });

    test('from an older PC has none of them', () {
      final info = StreamInfo.fromJson({'id': 'f', 'kind': 'file', 'resource': 'file/f', 'length': 10})!;
      expect(info.next, isNull);
      expect(info.tracks.isEmpty, isTrue);
    });
  });

  group('the end of a video, as on the PC', () {
    const next = EpisodeStep(id: 'e6', title: 'S02E06');
    const first = EpisodeStep(id: 'e1', title: 'S01E01');

    test('offers the next episode', () {
      expect(PhonePlayback.afterEnd('off', next, null), (false, next));
      expect(PhonePlayback.afterEnd('all', next, first), (false, next));
    });

    test('Loop one replays', () => expect(PhonePlayback.afterEnd('one', next, null), (true, null)));

    test("Loop all starts the show again after its last episode, and replays what has nothing after it", () {
      expect(PhonePlayback.afterEnd('all', null, first), (false, first));
      expect(PhonePlayback.afterEnd('all', null, null), (true, null));
    });

    test('a film with Loop off just ends', () => expect(PhonePlayback.afterEnd('off', null, null), (false, null)));
  });

  test('what the player waits for reads as it should', () {
    expect(const PendingSwitch.quality('720p').label, 'Switching to 720p…');
    expect(const PendingSwitch.quality('original').label, 'Switching to Original file…');
    expect(const PendingSwitch.episode(EpisodeStep(id: 'e6', title: 'S02E06', detail: 'Season 2 · Episode 6')).label, 'Opening Season 2 · Episode 6…');
  });
}
