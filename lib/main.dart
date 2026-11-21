import 'dart:async';
import 'dart:io' show File, FileMode, Platform;

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_model.dart';
import 'connection/remote_connection.dart';
import 'connection/webrtc_peer.dart';
import 'debug/loopback.dart';
import 'debug/preview.dart';
import 'protocol/pair_link.dart';
import 'storage/paired_pcs.dart';
import 'ui/app_prompts.dart';
import 'ui/pairing_screen.dart';
import 'ui/pc_chooser.dart';
import 'ui/remote_screen.dart';
import 'ui/theme.dart';
import 'ui/update_banner.dart';
import 'update/android_update_platform.dart';
import 'update/app_update.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Debug builds only: `--preview=<screen>` shows a screen with made-up state, for screenshots on a PC.
  if (kDebugMode) {
    final preview = args.where((a) => a.startsWith('--preview=')).map((a) => a.substring(10)).firstOrNull;
    if (preview == 'loopback') {
      await _runLoopback(args);
      return;
    }
    if (preview != null) {
      runApp(PreviewApp(screen: preview));
      return;
    }
  }
  final identity = await _identity();
  final model = AppModel(
    store: PairedPcStore(SecureSecretStore()),
    connect: (target, {onPaired, onPcName}) => RemoteConnection(
      target: target,
      identity: identity,
      connectSocket: WebSocketSignaling.connect,
      createPeer: WebRtcPeerLink.create,
      onPaired: onPaired,
      onPcName: onPcName,
    ),
  );
  // Release builds on Android update themselves from GitHub. A debug build is signed with another key, so Android
  // wouldn't install a release over it.
  final updater = kReleaseMode && Platform.isAndroid
      ? AppUpdater(platform: AndroidUpdatePlatform(appVersion: identity.appVersion), currentVersion: identity.appVersion)
      : null;
  runApp(BlackPearlApp(model: model, updater: updater));
  unawaited(model.load());
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
    connect: (target, {onPaired, onPcName}) => RemoteConnection(
      target: target,
      identity: identity,
      connectSocket: WebSocketSignaling.connect,
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

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.notice.addListener(_showNotice);
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
      model.resumed();
      unawaited(widget.updater?.resumed());
    } else if (state == AppLifecycleState.paused) {
      model.paused();
    }
  }

  /// A link from outside the app: another app or a web page can send one too, so ask before it replaces the current PC.
  /// The in-app scanner and paste don't ask; the user is already pairing there.
  Future<void> _openLink(Uri uri) async {
    final link = PairLinkParser.tryParse(uri.toString());
    if (link == null) {
      if (uri.scheme == 'blackpearl') {
        model.requestPairing(error: "That link didn't contain a pairing code. Show the code on the PC again.");
      }
      return;
    }
    // One question at a time; a second link while it's open is dropped.
    if (_confirmingLink || !mounted) return;
    _confirmingLink = true;
    try {
      if (await confirmPairLink(context, link) && mounted) model.pair(link);
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
          onLink: model.pair,
          onCancel: connection != null || model.pcs.isNotEmpty ? model.cancelPairing : null,
        );
      }
      return RemoteScreen(
        link: connection,
        onChoosePc: () => showPcChooser(context, model, updater: widget.updater),
        onPairAgain: () => model.requestPairing(error: connection.status.message),
      );
    },
  );
}
