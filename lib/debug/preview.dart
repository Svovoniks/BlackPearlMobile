import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import '../connection/transport.dart';
import '../protocol/pair_link.dart';
import '../protocol/remote_state.dart';
import '../ui/app_prompts.dart';
import '../ui/pairing_screen.dart';
import '../ui/remote_screen.dart';
import '../ui/theme.dart';

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
      _ => _remote(link(connected, sampleState)),
    };
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
