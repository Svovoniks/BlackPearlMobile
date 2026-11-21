import 'dart:io';

import 'package:blackpearl_mobile/ui/theme.dart';
import 'package:blackpearl_mobile/ui/update_banner.dart';
import 'package:blackpearl_mobile/update/app_update.dart';
import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final apkBytes = List<int>.generate(5000, (i) => i * 7 % 256);

Map<String, Object?> releaseJson(String tag, {List<int>? bytes, String? digest, String name = 'BlackPearl-v0.1.3.apk'}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'assets': [
    {'name': 'notes.txt', 'size': 10, 'browser_download_url': 'https://github.com/x/notes.txt', 'state': 'uploaded'},
    {
      'name': name,
      'size': (bytes ?? apkBytes).length,
      'browser_download_url': 'https://github.com/Svovoniks/BlackPearlMobile/releases/download/$tag/$name',
      'state': 'uploaded',
      'digest': digest ?? 'sha256:${sha256.convert(bytes ?? apkBytes)}',
    },
  ],
};

/// The phone and GitHub, in memory and a temporary folder.
class FakePlatform implements UpdatePlatform {
  FakePlatform(this.folder);
  final Directory folder;
  Object? latest = releaseJson('v0.1.3');
  bool failCheck = false;
  int checks = 0;
  List<int> served = apkBytes;
  bool failDownload = false;
  bool allowed = true;
  int settingsOpened = 0;
  final installed = <String>[];

  @override
  Future<Object?> latestRelease() async {
    checks++;
    if (failCheck) throw const SocketException('offline');
    return latest;
  }

  @override
  Future<void> download(Uri url, String path, void Function(int received) progress) async {
    if (failDownload) throw const SocketException('connection reset');
    await File(path).writeAsBytes(served);
    progress(served.length);
  }

  @override
  Future<String> updateFolder() async => folder.path;

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> allowInstalls() async => settingsOpened++;

  @override
  Future<void> install(String path) async => installed.add(path);
}

void main() {
  late Directory folder;
  late FakePlatform platform;
  late AppUpdater updater;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('bp-update-');
    platform = FakePlatform(folder);
    updater = AppUpdater(platform: platform, currentVersion: '0.1.2');
  });
  tearDown(() {
    updater.dispose();
    folder.deleteSync(recursive: true);
  });

  test('versions compare by number, not by text', () {
    expect(compareVersions('0.1.10', '0.1.9'), 1);
    expect(compareVersions('v0.2', '0.2.0'), 0);
    expect(compareVersions('0.1.2+3', '0.1.3'), -1);
    expect(compareVersions('1.0.0', 'x'), isNull);
  });

  test("a release counts only when it's newer and has the signed APK", () {
    final found = newerRelease(releaseJson('v0.1.3'), '0.1.2')!;
    expect(found.version, '0.1.3');
    expect(found.apk.path, endsWith('/BlackPearl-v0.1.3.apk'));
    expect(found.size, apkBytes.length);
    expect(found.sha256, sha256.convert(apkBytes).toString());
    expect(newerRelease(releaseJson('v0.1.2'), '0.1.2'), isNull, reason: 'same version');
    expect(newerRelease(releaseJson('v0.1.1'), '0.1.2'), isNull, reason: 'older');
    expect(newerRelease({...releaseJson('v0.1.3'), 'prerelease': true}, '0.1.2'), isNull);
    expect(newerRelease(releaseJson('v0.1.3', name: 'other.apk'), '0.1.2'), isNull, reason: 'not the release APK');
    expect(newerRelease({'message': 'Not Found'}, '0.1.2'), isNull);
    expect(newerRelease('nonsense', '0.1.2'), isNull);
    final plain = releaseJson('v0.1.3');
    ((plain['assets'] as List)[1] as Map)['browser_download_url'] = 'http://github.com/a.apk';
    expect(newerRelease(plain, '0.1.2'), isNull, reason: 'not https');
  });

  test('finds a newer release, and checks again on its own only after six hours', () async {
    final start = DateTime(2026, 11, 21, 9);
    await withClock(Clock.fixed(start), () => updater.check());
    expect(updater.phase, UpdatePhase.available);
    expect(updater.showBanner, isTrue);
    expect(updater.release!.version, '0.1.3');
    await withClock(Clock.fixed(start.add(const Duration(hours: 5))), () => updater.check());
    expect(platform.checks, 1);
    expect(await withClock(Clock.fixed(start.add(const Duration(hours: 5))), () => updater.check(manual: true)),
        'BlackPearl Mobile 0.1.3 is available.');
    expect(platform.checks, 2);
    await withClock(Clock.fixed(start.add(const Duration(hours: 12))), () => updater.check());
    expect(platform.checks, 3);
  });

  test('a manual check says when the app is up to date or GitHub is out of reach', () async {
    platform.latest = releaseJson('v0.1.2');
    expect(await updater.check(manual: true), 'BlackPearl Mobile 0.1.2 is the latest version.');
    expect(updater.showBanner, isFalse);
    platform.failCheck = true;
    expect(await updater.check(manual: true), contains("Couldn't check"));
    expect(updater.phase, UpdatePhase.none);
  });

  test('closing the banner hides it until a newer release or a manual check', () async {
    await updater.check();
    updater.dismiss();
    expect(updater.showBanner, isFalse);
    await updater.check(manual: true);
    expect(updater.showBanner, isTrue);
    updater.dismiss();
    platform.latest = releaseJson('v0.1.4', name: 'BlackPearl-v0.1.4.apk');
    await withClock(Clock.fixed(DateTime(2030)), () => updater.check());
    expect(updater.release!.version, '0.1.4');
    expect(updater.showBanner, isTrue);
  });

  test('downloads, checks the file and opens the installer', () async {
    await updater.check();
    await updater.update();
    expect(updater.phase, UpdatePhase.ready);
    expect(platform.installed, [File('${folder.path}${Platform.pathSeparator}BlackPearl-v0.1.3.apk').path]);
    expect(File(platform.installed.single).readAsBytesSync(), apkBytes);
    // Install again after closing Android's prompt: no second download.
    platform.served = [];
    await updater.update();
    expect(platform.installed, hasLength(2));
  });

  test('asks for the install permission first, and carries on when the user comes back with it', () async {
    platform.allowed = false;
    await updater.check();
    await updater.update();
    expect(updater.phase, UpdatePhase.needsPermission);
    expect(platform.settingsOpened, 1);
    await updater.resumed();
    expect(updater.phase, UpdatePhase.needsPermission, reason: 'came back without allowing it');
    expect(platform.installed, isEmpty);
    platform.allowed = true;
    await updater.resumed();
    expect(updater.phase, UpdatePhase.ready);
    expect(platform.installed, hasLength(1));
  });

  test("a damaged download isn't installed, and Retry downloads it again", () async {
    await updater.check();
    platform.served = [...apkBytes]..[100] ^= 1;
    await updater.update();
    expect(updater.phase, UpdatePhase.failed);
    expect(updater.error, contains('damaged'));
    expect(platform.installed, isEmpty);
    expect(folder.listSync(), isEmpty, reason: 'the damaged file is deleted');
    platform.served = apkBytes;
    await updater.update();
    expect(updater.phase, UpdatePhase.ready);
    expect(platform.installed, hasLength(1));
  });

  test('a short download is damaged too, even without a digest from GitHub', () async {
    platform.latest = releaseJson('v0.1.3')..['assets'] = [
      {...((releaseJson('v0.1.3')['assets'] as List)[1] as Map)}..remove('digest'),
    ];
    await updater.check();
    expect(updater.release!.sha256, isNull);
    platform.served = apkBytes.sublist(10);
    await updater.update();
    expect(updater.phase, UpdatePhase.failed);
    expect(platform.installed, isEmpty);
  });

  test("a download that doesn't finish says so", () async {
    await updater.check();
    platform.failDownload = true;
    await updater.update();
    expect(updater.phase, UpdatePhase.failed);
    expect(updater.error, contains("didn't finish"));
  });

  test('starting clears files an earlier update left behind', () async {
    File('${folder.path}/BlackPearl-v0.1.2.apk').writeAsBytesSync([1, 2, 3]);
    File('${folder.path}/BlackPearl-v0.1.3.apk.part').writeAsBytesSync([1]);
    await updater.start();
    expect(folder.listSync(), isEmpty);
    expect(updater.phase, UpdatePhase.available);
  });

  testWidgets('the banner sits above the screen without resetting it, and Update starts the download', (tester) async {
    await tester.runAsync(() => updater.check());
    updater.dismiss();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: UpdateFrame(updater: updater, child: const Scaffold(body: SafeArea(child: _Counter()))),
      ),
    );
    await tester.tap(find.text('Count 0'));
    await tester.pump();
    expect(find.text('Count 1'), findsOneWidget);
    expect(find.text('Update available'), findsNothing);
    await tester.runAsync(() => updater.check(manual: true));
    await tester.pump();
    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('BlackPearl Mobile 0.1.3'), findsOneWidget);
    expect(find.text('Count 1'), findsOneWidget, reason: 'the screen kept its state');
    await tester.runAsync(() async {
      await tester.tap(find.text('Update'));
      while (updater.phase != UpdatePhase.ready) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(find.text('Install 0.1.3'), findsOneWidget);
    expect(platform.installed, hasLength(1));
    await tester.tap(find.byTooltip('Not now'));
    await tester.pump();
    expect(find.text('Install 0.1.3'), findsNothing);
    expect(find.text('Count 1'), findsOneWidget);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => setState(() => count++), child: Text('Count $count'));
}
