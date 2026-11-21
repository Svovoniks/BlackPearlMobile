import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app_model.dart';
import '../connection/remote_connection.dart';
import '../connection/remote_link.dart';
import '../connection/transport.dart';
import '../protocol/pair_link.dart';
import '../protocol/remote_state.dart';
import '../ui/app_prompts.dart';
import '../storage/paired_pcs.dart';
import '../ui/pairing_screen.dart';
import '../ui/pc_chooser.dart';
import '../ui/remote_screen.dart';
import '../ui/settings_screen.dart';
import '../ui/theme.dart';
import '../ui/update_banner.dart';
import '../update/app_update.dart';

/// A [RemoteLink] with a fixed status and state, for previews, screenshots and widget tests. It never touches the
/// network. Commands are recorded in [sent] and applied to the state the way the PC would, so controls can be tried.
class FakeRemoteLink extends RemoteLink {
  FakeRemoteLink({required this.pcName, required LinkStatus status, RemoteState? state})
    // ignore: prefer_initializing_formals
    : _status = status,
      _state = state,
      _at = state == null ? null : clock.now();

  @override
  final String pcName;
  LinkStatus _status;
  RemoteState? _state;
  DateTime? _at;
  final ValueNotifier<String?> _notice = ValueNotifier(null);
  final List<(String, Object?)> sent = [];

  @override
  LinkStatus get status => _status;
  @override
  RemoteState? get state => _state;
  @override
  DateTime? get stateReceivedAt => _at;
  @override
  ValueListenable<String?> get notice => _notice;

  set status(LinkStatus value) {
    _status = value;
    notifyListeners();
  }

  void setState(RemoteState? value) {
    _state = value;
    _at = clock.now();
    notifyListeners();
  }

  void showNotice(String text) => _notice.value = text;

  @override
  void command(String action, [Object? value]) {
    sent.add((action, value));
    final current = _state;
    if (current == null) return;
    final position = currentPositionMs();
    final next = switch (action) {
      'toggle' => current.copyWith(playing: !current.playing, positionMs: position),
      'seek-by' => current.copyWith(positionMs: (position + (value as int)).clamp(0, current.durationMs)),
      'seek-to' => current.copyWith(positionMs: value as int),
      'volume' => current.copyWith(volume: value as int, positionMs: position),
      'mute' => current.copyWith(muted: !current.muted, positionMs: position),
      _ => null,
    };
    if (next != null) setState(next);
  }

  @override
  void retryNow() {}

  /// What the stand-in PC offers; none by default, as a PC from before the library.
  Set<String> offered = const {};
  @override
  Set<String> get features => offered;

  /// Answers requests (`browse`, `watch`, `play`); unanswered ones fail as if the PC were offline.
  Future<Map<String, dynamic>> Function(String type, Map<String, dynamic> fields)? answer;
  final List<(String, Map<String, dynamic>)> asked = [];
  final List<(String, Map<String, dynamic>)> told = [];

  @override
  Future<Map<String, dynamic>> ask(String type, Map<String, dynamic> fields, {Duration timeout = const Duration(seconds: 20)}) {
    asked.add((type, fields));
    return answer?.call(type, fields) ?? super.ask(type, fields, timeout: timeout);
  }

  @override
  void tell(String type, Map<String, dynamic> fields) => told.add((type, fields));
}

const RemoteState sampleState = RemoteState(
  media: true,
  title: 'Night Signal',
  detail: 'Season 2 · Episode 3 · Low Tide',
  playing: true,
  positionMs: 1122000,
  durationMs: 2830000,
  volume: 64,
  loop: LoopMode.all,
  hasPrevious: true,
  hasNext: true,
);

/// Debug builds only, from `--preview=<screen>`: shows one screen with made-up data.
class PreviewApp extends StatelessWidget {
  const PreviewApp({super.key, required this.screen});
  final String screen;

  static const _pc = 'Living room PC';

  Widget _screen() {
    FakeRemoteLink link(LinkStatus status, RemoteState? state) => FakeRemoteLink(pcName: _pc, status: status, state: state);
    const connected = LinkStatus(LinkPhase.connected, path: NetworkPath.home);
    return switch (screen) {
      'pairing' => PairingScreen(onLink: (_) {}, onCancel: () {}),
      'pairing-error' => PairingScreen(onLink: (_) {}, error: 'That code has expired'),
      'away' => _remote(link(const LinkStatus(LinkPhase.connected, path: NetworkPath.away), sampleState)),
      'relay' => _remote(link(const LinkStatus(LinkPhase.connected, path: NetworkPath.relayed), sampleState.copyWith(playing: false))),
      'cant-control' => _remote(
        link(
          connected,
          const RemoteState(
            media: true,
            title: 'The Long Coast',
            detail: '2019 · Drama',
            playing: true,
            positionMs: 3720000,
            durationMs: 8040000,
            volume: 40,
            hasNext: false,
            hasPrevious: false,
            canControl: false,
            room: RemoteRoom(name: 'Movie club', people: 3),
          ),
        ),
      ),
      'nothing' => _remote(link(connected, RemoteState.nothing)),
      'waiting' => _remote(link(const LinkStatus(LinkPhase.waitingForPc, message: "Your PC isn't online"), null)),
      'connecting' => _remote(link(const LinkStatus(LinkPhase.linking), null)),
      'failed' => _remote(
        link(
          LinkStatus(
            LinkPhase.failed,
            message: "Can't reach the room server. Check your internet connection.",
            retryAt: DateTime.now().add(const Duration(seconds: 28)),
          ),
          null,
        ),
      ),
      'storage-problem' => StorageProblem(
        message: "This phone's secure storage didn't open, so the paired PCs can't be read.",
        busy: false,
        onRetry: () {},
      ),
      'pair-link' => _PairLinkPreview(child: _remote(link(connected, sampleState))),
      'pair-timeout' => _remote(
        link(const LinkStatus(LinkPhase.failed, message: "The PC didn't finish pairing this phone", needsPairing: true), null),
      ),
      'removed' => _remote(
        link(const LinkStatus(LinkPhase.failed, message: 'This phone was removed from the PC. Pair it again.', needsPairing: true), null),
      ),
      'reconnecting' => _remote(
        link(
          LinkStatus(LinkPhase.failed, message: 'Lost the connection to the PC.', retryAt: DateTime.now().add(const Duration(seconds: 4))),
          sampleState.copyWith(playing: false),
        ),
      ),
      'long' => _remote(
        link(
          const LinkStatus(LinkPhase.connected, path: NetworkPath.relayed),
          const RemoteState(
            media: true,
            title: 'A Remarkably Long Film Title That Keeps Going Well Past One Line',
            detail: 'Season 12 · Episode 104 · The Episode Whose Name Is Also Far Too Long For One Line',
            playing: false,
            positionMs: 5025000,
            durationMs: 10812000,
            volume: 100,
            muted: true,
            loop: LoopMode.one,
            fullscreen: true,
            hasPrevious: true,
            hasNext: true,
            room: RemoteRoom(name: 'A room with a long name', people: 12),
          ),
        ),
      ),
      'chooser' => const _ChooserPreview(),
      'settings' => SettingsScreen(
        model: AppModel(store: PairedPcStore(MemorySecretStore()), connect: (_, {onPaired, onPcName}) => throw UnsupportedError('preview')),
        link: link(connected, sampleState),
        onChoosePc: () {},
        updater: _updater(),
      ),
      _ when screen.startsWith('update-') => _updatePreview(_remote(link(connected, sampleState))),
      _ => _remote(link(connected, sampleState)),
    };
  }

  static AppUpdater _updater() => AppUpdater(platform: _UpToDate(), currentVersion: '0.1.2');

  /// `update-available`, `update-permission`, `update-downloading`, `update-ready` or `update-failed`.
  Widget _updatePreview(Widget child) {
    final release = AppRelease(version: '0.1.3', apk: Uri.parse('https://example.com/BlackPearl-v0.1.3.apk'), size: 1);
    final updater = _updater();
    switch (screen) {
      case 'update-permission':
        updater.debugShow(UpdatePhase.needsPermission, release: release);
      case 'update-downloading':
        updater.debugShow(UpdatePhase.downloading, release: release, progress: 0.42);
      case 'update-ready':
        updater.debugShow(UpdatePhase.ready, release: release);
      case 'update-failed':
        updater.debugShow(UpdatePhase.failed, release: release, error: "The download didn't finish. Check the connection and try again.");
      default:
        updater.debugShow(UpdatePhase.available, release: release);
    }
    return UpdateFrame(updater: updater, child: child);
  }

  Widget _remote(RemoteLink link) => RemoteScreen(link: link, onChoosePc: () {}, onPairAgain: () {});

  @override
  Widget build(BuildContext context) =>
      MaterialApp(title: 'BlackPearl preview', debugShowCheckedModeBanner: false, theme: buildTheme(), home: _screen());
}

/// The question a pairing link from outside the app asks, over the Remote screen.
class _PairLinkPreview extends StatefulWidget {
  const _PairLinkPreview({required this.child});
  final Widget child;
  @override
  State<_PairLinkPreview> createState() => _PairLinkPreviewState();
}

class _PairLinkPreviewState extends State<_PairLinkPreview> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      confirmPairLink(
        context,
        const PairLink(pcId: '0123456789ABCDEF0123456789ABCDEF', code: '', server: 'https://rooms.example.com', name: 'Study PC'),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// GitHub with nothing newer, for previews.
class _UpToDate implements UpdatePlatform {
  @override
  Future<Object?> latestRelease() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return {'tag_name': 'v0.1.2', 'assets': const []};
  }

  @override
  Future<void> download(Uri url, String path, void Function(int received) progress) async {}
  @override
  Future<String> updateFolder() async => '';
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> install(String path) async {}
}

/// The PC sheet over the Remote screen, with two paired PCs.
class _ChooserPreview extends StatefulWidget {
  const _ChooserPreview();
  @override
  State<_ChooserPreview> createState() => _ChooserPreviewState();
}

class _ChooserPreviewState extends State<_ChooserPreview> {
  late final AppModel _model;

  @override
  void initState() {
    super.initState();
    final store = PairedPcStore(MemorySecretStore());
    _model = AppModel(
      store: store,
      connect: (target, {onPaired, onPcName}) => RemoteConnection(
        target: target,
        identity: const PhoneIdentity(appVersion: '0.1.2', device: 'Preview'),
        connectSocket: (_) => Completer<SignalingSocket>().future,
        createPeer: (_, _) => Completer<PeerLink>().future,
      ),
    );
    unawaited(() async {
      await store.save([
        PairedPc(pcId: 'A' * 32, name: PreviewApp._pc, server: 'https://rooms.example.com', phoneId: 'a' * 32, secret: 'b' * 64),
        PairedPc(pcId: 'B' * 32, name: 'Study', server: 'https://rooms.example.com', phoneId: 'c' * 32, secret: 'd' * 64),
      ]);
      await _model.load();
      if (mounted) unawaited(showPcChooser(context, _model));
    }());
  }

  @override
  Widget build(BuildContext context) => RemoteScreen(
    link: FakeRemoteLink(pcName: PreviewApp._pc, status: const LinkStatus(LinkPhase.connected, path: NetworkPath.home), state: sampleState),
    onChoosePc: () {},
    onPairAgain: () {},
  );
}
