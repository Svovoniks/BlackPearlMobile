import 'package:blackpearl_mobile/connection/remote_link.dart';
import 'package:blackpearl_mobile/debug/preview.dart';
import 'package:blackpearl_mobile/protocol/library.dart';
import 'package:blackpearl_mobile/protocol/remote_state.dart';
import 'package:blackpearl_mobile/ui/library_screen.dart';
import 'package:blackpearl_mobile/ui/remote_screen.dart';
import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Map<String, dynamic> homePage() => {
  'type': 'page',
  'total': 3,
  'page': 0,
  'pageSize': 40,
  'location': 'Home',
  'entries': [
    {'id': 'film', 'title': 'Asteroid City', 'caption': 'Movie · 2023', 'level': 'movie', 'kind': 'Movie', 'runtimeMinutes': 105, 'homeSection': 'continue', 'positionMs': 760000, 'playable': true, 'overview': 'A desert town.'},
    {'id': 'show', 'title': 'Night Signal', 'caption': 'Show · 2021', 'level': 'series', 'kind': 'Show', 'homeSection': 'suggestions', 'playable': false},
    {'id': 'pick', 'title': 'Low Tide', 'caption': 'Movie · 2019', 'level': 'movie', 'kind': 'Movie', 'homeSection': 'mystery', 'playable': true},
  ],
};

Future<(FakeRemoteLink, List<String>)> pumpLibrary(WidgetTester tester, {Set<String> features = const {'library', 'watch'}}) async {
  final link = FakeRemoteLink(pcName: 'Study', status: const LinkStatus(LinkPhase.connected));
  link.offered = features;
  link.answer = (type, fields) async => type == 'browse' ? homePage() : {'type': 'done'};
  final calls = <String>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(),
    home: LibraryScreen(
      link: link,
      actions: LibraryActions(
        watchHere: (entry, {bool fromStart = false, QueueRef? queue}) async => calls.add('here ${entry.id} fromStart=$fromStart'),
        playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) async {
          calls.add('pc ${entry.id}');
          return null;
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (link, calls);
}

void main() {
  testWidgets("Home lists the PC's rows, and a title's sheet plays it here or on the PC", (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final (link, calls) = await pumpLibrary(tester);
    expect(link.asked.first.$1, 'browse');
    expect(link.asked.first.$2['home'], isTrue);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Shows to start'), findsOneWidget);
    expect(find.text("Can't decide?"), findsOneWidget);
    expect(find.text('12:40'), findsOneWidget);
    await tester.tap(find.text('Asteroid City'));
    await tester.pumpAndSettle();
    expect(find.text('Resume on phone · 12:40'), findsOneWidget);
    expect(find.text('Stopped at 12:40 of 1:45:00'), findsOneWidget);
    await tester.tap(find.text('Play on PC'));
    await tester.pumpAndSettle();
    expect(calls, ['pc film']);
    await tester.tap(find.text('Asteroid City'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start over'));
    await tester.pumpAndSettle();
    expect(calls.last, 'here film fromStart=true');
  });

  testWidgets('a PC from before the library says to update it', (tester) async {
    await pumpLibrary(tester, features: const {});
    expect(find.text('Update BlackPearl on the PC'), findsOneWidget);
  });

  testWidgets('categories browse their own listing', (tester) async {
    final (link, _) = await pumpLibrary(tester);
    await tester.tap(find.text('Films'));
    await tester.pumpAndSettle();
    expect(link.asked.last.$2['category'], LibraryCategory.films.number);
    expect(link.asked.last.$2['home'], isFalse);
  });

  testWidgets("Watch here shows for the PC's own video when it offers watching", (tester) async {
    Future<FakeRemoteLink> pump(String? mediaId, Set<String> features) async {
      final link = FakeRemoteLink(
        pcName: 'Study',
        status: const LinkStatus(LinkPhase.connected),
        state: RemoteState(media: true, title: 'Asteroid City', durationMs: 6000000, positionMs: 1000, mediaId: mediaId),
      )..offered = features;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: RemoteScreen(link: link, onChoosePc: () {}, onPairAgain: () {}, onWatchHere: (id) => link.tell('watched', {'id': id})),
      ));
      await tester.pump();
      return link;
    }

    final link = await pump('film', const {'watch'});
    await tester.tap(find.text('Watch here'));
    expect(link.told.single.$2['id'], 'film');
    await pump(null, const {'watch'});
    expect(find.text('Watch here'), findsNothing);
    await pump('film', const {});
    expect(find.text('Watch here'), findsNothing);
  });
}
