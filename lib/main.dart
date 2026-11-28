import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileMode, Platform;

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_model.dart';
import 'background/background_link.dart';
import 'connection/lan_socket.dart';
import 'connection/local_network.dart';
import 'connection/remote_connection.dart';
import 'connection/webrtc_peer.dart';
import 'debug/loopback.dart';
import 'debug/preview.dart';
import 'diagnostics/crash_reports.dart';
import 'playback/phone_playback.dart';
import 'playback/phone_sound.dart';
import 'playback/picture_in_picture.dart';
import 'protocol/pair_link.dart';
import 'storage/app_settings.dart';
import 'storage/paired_pcs.dart';
import 'ui/app_prompts.dart';
import 'ui/home_shell.dart';
import 'ui/pairing_screen.dart';
import 'ui/pc_chooser.dart';
import 'ui/theme.dart';
import 'ui/update_banner.dart';
import 'update/android_update_platform.dart';
import 'update/app_update.dart';

Future<void> main(List<String> args) async {
  CrashReports.ensureBinding();
  // libmpv, for watching the PC's videos on the phone.
  MediaKit.ensureInitialized();
  PictureInPicture.instance.start();
  // Debug builds only: `--preview=<screen>` shows a screen with made-up state, for screenshots on a PC.
  if (kDebugMode) {
    final preview = args.where((a) => a.startsWith('--preview=')).map((a) => a.substring(10)).firstOrNull;
    if (preview == 'loopback') {
      await _runLoopback(args);
      return;
    }
    if (preview != null) {
      final video = args.where((a) => a.startsWith('--video=')).map((a) => a.substring(8)).firstOrNull;
      runApp(PreviewApp(screen: preview, video: video));
      return;
    }
  }
  final settings = AppSettings(PreferencesSettingsStore());
  await settings.load();
  // Read first, so a user who turned crash reports off sends nothing, not even about this start.
  await CrashReports.start(settings);
  final identity = await _identity();
  final store = PairedPcStore(SecureSecretStore());
  // Debug builds only: `--paired-pc=<JSON of a paired PC>` starts already paired, for trying the Windows build against a
  // real PC, which has no camera to scan the code with and keeps nothing between runs.
  if (kDebugMode) {
    // As JSON, or as base64 of it where commas can't pass (Android's `am start` splits on them).
    String decode(String value) => value.startsWith('{') ? value : utf8.decode(base64.decode(value));
    final paired = args.where((a) => a.startsWith('--paired-pc=')).map((a) => PairedPc.fromJson(jsonDecode(decode(a.substring(12))))).firstOrNull;
    if (paired != null) await store.save([paired]);
    PhoneSound.debugSoundDevice = args.where((a) => a.startsWith('--sound-device=')).map((a) => a.substring(15)).firstOrNull;
    final soundLog = args.where((a) => a.startsWith('--sound-log=')).map((a) => a.substring(12)).firstOrNull;
    if (soundLog != null) {
      PhoneSound.debugLog = (line) => File(soundLog).writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
    }
  }
  // The home network is tried on Wi-Fi or Ethernet only, and over it even while Android has made mobile data the default.
  final localNetwork = Platform.isAndroid ? AndroidLocalNetwork() : null;
  final model = AppModel(
    store: store,
    settings: settings,
    background: BackgroundLink.supported ? BackgroundLink() : null,
    createPlayback: (connection) => PhonePlayback(link: connection),
    createSound: (connection, settings, background) => PhoneSound(link: connection, settings: settings, keepAwake: background?.keepAwake),
    connect: (target, {onPaired, onPcName}) => RemoteConnection(
      target: target,
      identity: identity,
      connectSocket: WebSocketSignaling.connect,
      createPeer: WebRtcPeerLink.create,
      // The PC's own home-network socket, with a cap on what it may send (LanSignaling).
      connectLanSocket: LanSignaling.connect,
      localNetwork: localNetwork,
      onPaired: onPaired,
      onPcName: onPcName,
    ),
  );
  // Release builds on Android update themselves from GitHub. A debug build is signed with another key, so Android
  // wouldn't install a release over it.
  final updater = kReleaseMode && Platform.isAndroid
      ? AppUpdater(
          platform: AndroidUpdatePlatform(appVersion: identity.appVersion),
          currentVersion: identity.appVersion,
          abis: await _abis(),
        )
      : null;
  runApp(BlackPearlApp(model: model, updater: updater));
  unawaited(model.load());
  // Debug builds only: `--sound-on` turns Sound on the phone on once the PC offers it, for measuring it on a PC, whose
  // Windows build can't be clicked from a script.
  if (kDebugMode && args.contains('--sound-on')) {
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      final sound = model.sound;
      if (sound == null || !sound.available || !(model.connection?.status.isConnected ?? false)) return;
      timer.cancel();
      unawaited(sound.turnOn());
    });
  }
  if (updater != null) unawaited(updater.start());
}

/// Debug builds only: the real app, paired through a room server and PC that run inside this process.
/// `--loopback-log=<file>` writes what each side saw, for checking without looking at the screen.
Future<void> _runLoopback(List<String> args) async {
  final logPath = args.where((a) => a.startsWith('--loopback-log=')).map((a) => a.substring(15)).firstOrNull;
  final harness = await LoopbackHarness.start();
  final identity = await _identity();
  final model = AppModel(
    store: PairedPcStore(MemorySecretStore()),
    // On Android the background service runs too, so its notification and media controls can be tried on the stand-in PC.
    background: BackgroundLink.supported ? BackgroundLink() : null,
    createPlayback: (connection) => PhonePlayback(link: connection),
    connect: (target, {onPaired, onPcName}) => RemoteConnection(
      target: target,
      identity: identity,
      connectSocket: WebSocketSignaling.connect,
      // As the app does: the PC's own home-network socket with its cap on what it may send.
      connectLanSocket: LanSignaling.connect,
      createPeer: WebRtcPeerLink.create,
      onPaired: onPaired,
      onPcName: onPcName,
    ),
  );
  void log(String line) {
    if (logPath != null) File(logPath).writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
  }

  String? last;
  RemoteConnection? watched;
  model.addListener(() {
    final connection = model.connection;
    if (connection == null || connection == watched) return;
    watched = connection;
    connection.addListener(() {
      final status = connection.status;
      final line =
          'phone: ${status.phase.name} path=${status.path.name} message=${status.message} paired=${model.pcs.length} '
          'title=${connection.state?.title} playing=${connection.state?.playing} volume=${connection.state?.volume} '
          'pc-commands=${harness.pc.commands.join(',')}';
      if (line != last) log(last = line);
    });
  });
  runApp(BlackPearlApp(model: model));
  await model.load();
  log('pairing with ${harness.serverUrl}');
  model.pair(PairLinkParser.parse(harness.pairingLink()));
}

Future<PhoneIdentity> _identity() async {
  var version = '0.0.0';
  var device = 'Phone';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      final maker = android.manufacturer.isEmpty ? '' : '${android.manufacturer[0].toUpperCase()}${android.manufacturer.substring(1)} ';
      device = android.model.toLowerCase().startsWith(android.manufacturer.toLowerCase()) ? android.model : '$maker${android.model}';
    } else if (Platform.isWindows) {
      device = (await info.windowsInfo).computerName;
    } else if (Platform.isIOS) {
      device = (await info.iosInfo).name;
    }
  } catch (_) {}
  device = device.trim();
  if (device.isEmpty) device = 'Phone';
  if (device.length > 60) device = device.substring(0, 60);
  return PhoneIdentity(appVersion: version, device: device);
}

/// The ABIs the phone runs, most preferred first, which pick the update's APK. When Android won't say, the plain APK's.
Future<List<String>> _abis() async {
  try {
    final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    if (abis.isNotEmpty) return abis;
  } catch (_) {}
  return const [plainApkAbi];
}

class BlackPearlApp extends StatelessWidget {
  const BlackPearlApp({super.key, required this.model, this.updater});
  final AppModel model;
  final AppUpdater? updater;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BlackPearl',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Root(model: model, updater: updater),
  );
}

class Root extends StatefulWidget {
  const Root({super.key, required this.model, this.updater, this.links, this.network});
  final AppModel model;

  /// Checks for and installs app updates; null where the app doesn't update itself.
  final AppUpdater? updater;

  /// Links that open the app from outside; by default the system's, through app_links. For tests.
  final Stream<Uri>? links;

  /// Network changes; by default connectivity_plus. For tests.
  final Stream<List<ConnectivityResult>>? network;
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links;
  StreamSubscription<List<ConnectivityResult>>? _network;
  List<ConnectivityResult>? _lastNetwork;
  Timer? _networkDebounce;
  bool _confirmingLink = false;

  // The tab last shown. The pairing screen takes the tabs' place; cancelled, it gives back the tab it was opened from
  // (Settings, through "Pair another PC"). A new pairing starts on the Remote, which shows the new PC.
  int _homeTab = HomeShell.remoteTab;

  void _pair(PairLink link) {
    _homeTab = HomeShell.remoteTab;
    model.pair(link);
  }

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.notice.addListener(_showNotice);
    // A picture-in-picture window back on screen after the screen was off never gets "resumed" from Flutter.
    PictureInPicture.instance.onAppShown = model.resumed;
    PictureInPicture.instance.onAppHidden = model.paused;
    try {
      // Covers both the link the app was opened with and links that arrive while it runs.
      _links = (widget.links ?? AppLinks().uriLinkStream).listen(_openLink, onError: (_) {});
    } catch (_) {}
    try {
      _network = (widget.network ?? Connectivity().onConnectivityChanged).listen(_networkChanged, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    model.notice.removeListener(_showNotice);
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    _network?.cancel();
    _networkDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _claimBack();
      model.resumed();
      unawaited(widget.updater?.resumed());
    } else if (state == AppLifecycleState.paused) {
      model.paused();
    }
  }

  // Android gives the system's Back to the app only while the app has said it wants it, and Flutter says so only when
  // its pages change. The engine outlives the activity (LinkEngine), and a new activity starts out letting Back close
  // the app: opened again on a show's page or the Library, the first Back closed it while the back arrow worked. So
  // each time the app shows, it says again what it wants: the Navigator turns this into "yes" while a page is open
  // above the tabs, and the tabs' own PopScope says it for a tab other than the Remote.
  void _claimBack() {
    if (!mounted) return;
    NavigationNotification(canHandlePop: ModalRoute.popDispositionOf(context) == RoutePopDisposition.doNotPop).dispatch(context);
  }

  /// A link from outside the app: another app or a web page can send one too, so ask before it replaces the current PC.
  /// The in-app scanner and paste don't ask; the user is already pairing there.
  Future<void> _openLink(Uri uri) async {
    final PairLink link;
    try {
      link = PairLinkParser.parse(uri.toString());
    } on PairLinkException catch (e) {
      // What is wrong with it: a newer PC, a cut-off link, a server that isn't a web address.
      if (uri.scheme == 'blackpearl') model.requestPairing(error: e.message);
      return;
    }
    // One question at a time; a second link while it's open is dropped.
    if (_confirmingLink || !mounted) return;
    _confirmingLink = true;
    try {
      if (await confirmPairLink(context, link) && mounted) {
        // The phone's player, if open, goes first: the pairing replaces the link it plays through. It is off screen
        // before its player is let go.
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.popUntil((route) => route.isFirst);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          if (!mounted) return;
        }
        _pair(link);
      }
    } finally {
      _confirmingLink = false;
    }
  }

  void _showNotice() {
    final text = model.notice.value;
    if (text == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 8)));
  }

  void _networkChanged(List<ConnectivityResult> results) {
    final previous = _lastNetwork;
    _lastNetwork = results;
    // The first report is the current network, not a change.
    if (previous == null || setEquals(previous.toSet(), results.toSet())) return;
    _networkDebounce?.cancel();
    _networkDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (!results.contains(ConnectivityResult.none)) model.networkChanged();
    });
  }

  @override
  Widget build(BuildContext context) => UpdateFrame(updater: widget.updater, child: _screen());

  Widget _screen() => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      if (!model.loaded) {
        final error = model.loadError;
        if (error != null) return StorageProblem(message: error, busy: model.loading, onRetry: () => unawaited(model.load()));
        return const Scaffold();
      }
      final connection = model.connection;
      if (model.showPairing || connection == null) {
        return PairingScreen(
          key: ValueKey(model.pairingError),
          error: model.pairingError,
          onLink: _pair,
          onCancel: connection != null || model.pcs.isNotEmpty ? model.cancelPairing : null,
        );
      }
      return HomeShell(
        model: model,
        connection: connection,
        onChoosePc: () => showPcChooser(context, model),
        updater: widget.updater,
        onPairAgain: () => model.requestPairing(error: connection.status.message),
        initialTab: _homeTab,
        onTabChanged: (tab) => _homeTab = tab,
      );
    },
  );
}
