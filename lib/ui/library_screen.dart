import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import '../protocol/library.dart';
import '../protocol/remote_state.dart';
import 'artwork.dart';
import 'mini_remote_bar.dart';
import 'pebbles.dart';
import 'queue_widgets.dart';
import 'status_copy.dart';
import 'theme.dart';

/// What the library screens do with a title: play it here, or start it on the PC.
class LibraryActions {
  const LibraryActions({required this.watchHere, required this.playOnPc, this.markWatched, this.openRemote, this.prefersPc});

  /// Shows the Remote tab, from a page above the tabs; null where there is none to show.
  final VoidCallback? openRemote;

  /// Whether a video was last started on the PC rather than on the phone: where a list's play buttons start one.
  final bool Function()? prefersPc;

  /// Plays [entry] on the phone. [fromStart] ignores the resume point; [queue] plays it as part of a saved queue.
  final Future<void> Function(LibraryEntry entry, {bool fromStart, QueueRef? queue}) watchHere;

  /// Starts [entry] on the PC, as part of [queue] when given; returns why it couldn't, or null.
  final Future<String?> Function(LibraryEntry entry, {bool fromStart, QueueRef? queue}) playOnPc;

  /// Marks [entry] watched or unwatched on the PC: a film or an episode, or all of a show's or a season's episodes when
  /// [level] says so (`series` or `season`, with [season]). Returns why it couldn't, or null. Null where the lists can't
  /// show the change.
  final Future<String?> Function(LibraryEntry entry, bool watched, {String? level, int? season})? markWatched;

  /// The same actions, playing each listed video as part of [list] at the video's place.
  LibraryActions inQueue(QueueRef list) => LibraryActions(
    watchHere: (entry, {bool fromStart = false, QueueRef? queue}) => watchHere(entry, fromStart: fromStart, queue: queue ?? list.at(entry.index)),
    playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) => playOnPc(entry, fromStart: fromStart, queue: queue ?? list.at(entry.index)),
    markWatched: markWatched,
    openRemote: openRemote,
    prefersPc: prefersPc,
  );
}

/// Where a list's play button starts a video.
enum PlayTarget { phone, pc }

/// Where a play button on a list starts a video now: the place used last when the PC offers both, the one it offers
/// otherwise, or null when it offers neither.
PlayTarget? quickPlayTarget(RemoteLink link, LibraryActions actions) {
  final phone = link.features.contains('watch');
  final pc = link.status.isConnected && link.canStart;
  if (phone && pc) return (actions.prefersPc?.call() ?? false) ? PlayTarget.pc : PlayTarget.phone;
  return phone ? PlayTarget.phone : (pc ? PlayTarget.pc : null);
}

/// Plays [entry] at [quickPlayTarget] without opening its sheet, from its resume point. A refusal from the PC shows
/// in a snack bar.
Future<void> quickPlay(BuildContext context, {required RemoteLink link, required LibraryEntry entry, required LibraryActions actions}) async {
  final target = quickPlayTarget(link, actions);
  if (target == null) return;
  if (target == PlayTarget.phone) {
    await actions.watchHere(entry);
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  final error = await actions.playOnPc(entry);
  if (error != null) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error), duration: const Duration(seconds: 4)));
  }
}

/// Whether [entry]'s watched mark can be changed from the phone: a film or an episode (songs keep no marks), or a show
/// or season as a whole, on a PC that takes marks.
bool canMarkWatched(RemoteLink link, LibraryEntry entry, LibraryActions actions) =>
    actions.markWatched != null &&
    link.features.contains('mark-watched') &&
    entry.kind != 'Music' &&
    (entry.level == 'movie' || entry.level == 'episode' || entry.playable || entry.opensList);

/// What a long press on a title offers, without opening it: where to play it, and its watched mark.
Future<void> showQuickActions(BuildContext context, {required RemoteLink link, required LibraryEntry entry, required LibraryActions actions}) {
  final canWatch = entry.playable && link.features.contains('watch');
  final canStart = entry.playable && link.status.isConnected && link.canStart;
  final canMark = canMarkWatched(link, entry, actions) && link.status.isConnected;
  if (!canWatch && !canStart && !canMark) return Future.value();
  unawaited(HapticFeedback.mediumImpact());
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  final resume = !entry.watched && entry.positionMs >= 10000;
  // A show or a season has no mark of its own to flip: both ways are offered, for all its episodes.
  final whole = entry.opensList;
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheet) {
      Widget row(IconData icon, String label, Future<void> Function() act) => InkWell(
        onTap: () {
          Navigator.of(sheet).pop();
          unawaited(act());
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 22, color: Palette.muted),
                const SizedBox(width: 16),
                Expanded(child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
              ],
            ),
          ),
        ),
      );
      Future<void> mark(bool watched) async {
        final error = await actions.markWatched!(entry, watched);
        say(error ?? (whole ? 'Every episode is marked ${watched ? 'watched' : 'unwatched'}.' : 'Marked ${watched ? 'watched' : 'unwatched'}.'));
      }

      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 14, bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(19)),
              ),
              if (canWatch)
                row(Icons.phone_android_rounded, resume ? 'Resume on phone · ${formatClock(entry.positionMs)}' : 'Play on phone', () => actions.watchHere(entry)),
              if (canStart)
                row(Icons.desktop_windows_outlined, 'Play on ${link.pcName}', () async {
                  final error = await actions.playOnPc(entry);
                  if (error != null) say(error);
                }),
              if (canMark && (whole || !entry.watched)) row(Icons.check_rounded, whole ? 'Mark every episode as watched' : 'Mark as watched', () => mark(true)),
              if (canMark && (whole || entry.watched))
                row(Icons.remove_done_rounded, whole ? 'Mark every episode as unwatched' : 'Mark as unwatched', () => mark(false)),
            ],
          ),
        ),
      );
    },
  );
}

/// Pages of one library listing, loaded as the list scrolls.
class LibraryListing extends ChangeNotifier {
  LibraryListing(this.link, this.request);
  final RemoteLink link;
  final BrowseRequest request;

  final List<LibraryEntry> entries = [];
  int total = 0;
  String location = '';
  bool loading = false;
  String? error;
  BrowseRequest? _next;
  bool _started = false;
  bool _disposed = false;

  bool get hasMore => _next != null;

  /// Closed: it loads nothing more.
  bool get disposed => _disposed;

  /// The page [more] asks for next, if any.
  int? get nextPage => _next?.page;
  bool get started => _started;

  Future<void> load() async {
    _started = true;
    entries.clear();
    _next = request;
    error = null;
    await more();
  }

  /// Loads every page shown so far again and swaps them in once all have arrived, so the list neither blanks nor
  /// shrinks back to its first page meanwhile; for progress that changed elsewhere.
  Future<void> reload() async {
    if (loading) return;
    loading = true;
    try {
      final shown = entries.length;
      final fresh = <LibraryEntry>[];
      final seen = <String>{};
      var next = request;
      LibraryPage page;
      do {
        page = LibraryPage.fromJson(await link.ask('browse', next.toJson()));
        if (_disposed) return;
        fresh.addAll(page.entries.where((entry) => seen.add(_key(entry))));
        next = next.nextPage();
      } while (page.hasMore && fresh.length < shown);
      entries
        ..clear()
        ..addAll(fresh);
      total = page.total;
      location = page.location;
      _next = page.hasMore ? next : null;
      error = null;
      _started = true;
    } on RemoteRequestException catch (e) {
      if (entries.isEmpty) error = e.message;
    } finally {
      loading = false;
      _notify();
    }
  }

  // A page can repeat a title the previous one ended with when the library changed in between.
  // A queue can hold a video twice: its place tells them apart.
  static String _key(LibraryEntry entry) => '${entry.id}/${entry.level}/${entry.homeSection}/${entry.index}';

  Future<void> more() async {
    final request = _next;
    if (request == null || loading) return;
    loading = true;
    // Try again shows the spinner, not the last error, while it asks.
    error = null;
    _notify();
    try {
      final page = LibraryPage.fromJson(await link.ask('browse', request.toJson()));
      if (_disposed) return;
      final seen = {for (final entry in entries) _key(entry)};
      entries.addAll(page.entries.where((entry) => seen.add(_key(entry))));
      total = page.total;
      location = page.location;
      _next = page.hasMore ? request.nextPage() : null;
      error = null;
    } on RemoteRequestException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      _notify();
    }
  }

  /// Marks the playback the phone just reported, so the list shows it without reloading.
  void updatePlayback(String id, {required int positionMs, required bool watched}) {
    var changed = false;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].id == id && entries[i].playable) {
        entries[i] = entries[i].withPlayback(positionMs: positionMs, watched: watched);
        changed = true;
      }
    }
    if (changed) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

enum _Mode { home, category, queues }

/// One of what the Library tab shows: Home, a category, or the queues.
class _Section {
  const _Section(this.mode, this.label, this.icon, [this.category]);
  final _Mode mode;
  final String label;
  final IconData icon;
  final LibraryCategory? category;

  bool matches(_Mode mode, LibraryCategory category) => this.mode == mode && (mode != _Mode.category || this.category == category);
}

const _homeSection = _Section(_Mode.home, 'Home', Icons.home_rounded);
const _queuesSection = _Section(_Mode.queues, 'Queues', Icons.queue_play_next_rounded);
const _categories = [
  _Section(_Mode.category, 'Films', Icons.movie_outlined, LibraryCategory.films),
  _Section(_Mode.category, 'Shows', Icons.tv_rounded, LibraryCategory.shows),
  _Section(_Mode.category, 'Anime', Icons.animation_rounded, LibraryCategory.anime),
];

/// The room the section button takes over the bottom of a list, so the list's last row can scroll clear of it.
const double sectionButtonClearance = 88;

/// What a Library page shows in place of its list when there is none to show: how the connection is going, with a way
/// to try again, or that the PC's BlackPearl is too old to browse. Null when the list can show; [hasEntries] keeps a
/// list loaded before the connection dropped.
Widget? libraryUnavailable(RemoteLink link, {bool hasEntries = false}) {
  final status = link.status;
  if (!status.isConnected && !hasEntries) {
    // How the connection is going, in the Remote's words.
    final copy = describe(status, link.pcName);
    final trying = status.phase == LinkPhase.connecting || status.phase == LinkPhase.linking || status.phase == LinkPhase.pairing;
    return LibraryMessage(
      icon: trying ? Icons.cloud_sync_outlined : Icons.cloud_off_rounded,
      title: status.phase == LinkPhase.idle ? 'Not connected' : copy.headline,
      text: status.needsPairing ? 'The Remote tab pairs this phone with ${link.pcName} again.' : 'The library shows once the phone reaches ${link.pcName}.',
      action: trying || status.needsPairing ? null : ('Try again', link.retryNow),
    );
  }
  if (status.isConnected && !link.features.contains('library')) {
    return LibraryMessage(
      icon: Icons.system_update_alt_rounded,
      title: 'Update BlackPearl on the PC',
      text: '${link.pcName} runs a BlackPearl from before the phone could browse it. Update it on the PC to see its library here.',
    );
  }
  return null;
}

/// The Library tab: Home's rows, each category as a grid of posters, and the queues, chosen with the button at the
/// bottom. Search is a tab of its own.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.link, required this.actions, this.changed, this.toTop});
  final RemoteLink link;
  final LibraryActions actions;

  /// Fires when the Library tab is tapped while it shows: the list goes to its top, and from there back to Home.
  final Listenable? toTop;

  /// Fires when playback elsewhere changed resume points or watched marks: the list loads again.
  final Listenable? changed;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  _Mode _mode = _Mode.home;
  LibraryCategory _category = LibraryCategory.films;
  LibraryListing? _listing;
  bool _wasConnected = false;
  int _seed = DateTime.now().millisecondsSinceEpoch & 0xffff;

  RemoteLink get link => widget.link;
  bool get _available => link.features.contains('library');

  List<_Section> get _sections => [_homeSection, ..._categories, if (link.features.contains('queues')) _queuesSection];
  // The section shown is named even while the PC offers no queues for now.
  _Section get _section => [_homeSection, ..._categories, _queuesSection].firstWhere((section) => section.matches(_mode, _category), orElse: () => _homeSection);

  @override
  void initState() {
    super.initState();
    link.addListener(_linkChanged);
    widget.changed?.addListener(_playbackChanged);
    widget.toTop?.addListener(_toTop);
    _wasConnected = link.status.isConnected;
    _phase = link.status.phase;
    if (_wasConnected && _available) _open();
  }

  // Home's list, to send it back to its top.
  final ScrollController _homeScroll = ScrollController();

  void _toTop() {
    if (_buttonHidden) setState(() => _buttonHidden = false);
    if (_mode == _Mode.home && _homeScroll.hasClients && _homeScroll.offset > 0) {
      unawaited(_homeScroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic));
    } else if (_mode != _Mode.home) {
      _select(_Mode.home);
    }
  }

  // Continue watching on Home: it goes back to its start once playback changed, where the title just watched now is.
  // Left where it was scrolled to, the row showed the titles after it, so it looked as if nothing had changed.
  final ScrollController _continueRow = ScrollController();

  void _playbackChanged() {
    final listing = _listing;
    if (listing == null || !listing.started) return;
    unawaited(listing.reload().then((_) {
      if (!mounted || !identical(_listing, listing) || !_continueRow.hasClients || _continueRow.offset <= 0) return;
      unawaited(_continueRow.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic));
    }));
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link != link) {
      oldWidget.link.removeListener(_linkChanged);
      link.addListener(_linkChanged);
      _wasConnected = link.status.isConnected;
      _phase = link.status.phase;
      _listing?.dispose();
      _listing = null;
      if (_wasConnected && _available) _open();
    }
    if (oldWidget.toTop != widget.toTop) {
      oldWidget.toTop?.removeListener(_toTop);
      widget.toTop?.addListener(_toTop);
    }
  }

  @override
  void dispose() {
    link.removeListener(_linkChanged);
    widget.changed?.removeListener(_playbackChanged);
    widget.toTop?.removeListener(_toTop);
    _continueRow.dispose();
    _homeScroll.dispose();
    _listing?.dispose();
    super.dispose();
  }

  // The connection's phase as last shown, for the words of "not connected".
  LinkPhase? _phase;

  void _linkChanged() {
    final connected = link.status.isConnected;
    if (connected == _wasConnected) {
      // Still not connected, but otherwise: the message says how it is going.
      if (link.status.phase != _phase && mounted) setState(() => _phase = link.status.phase);
      return;
    }
    _phase = link.status.phase;
    _wasConnected = connected;
    // Coming back after a drop: load again, unless what is shown loaded fine. An empty list loads again too: a PC that
    // has just started may have answered before it had read its library.
    if (connected && _available && (_listing == null || _listing!.error != null || !_listing!.started || _listing!.entries.isEmpty)) _open();
    if (mounted) setState(() {});
  }

  BrowseRequest get _request => switch (_mode) {
    _Mode.home => BrowseRequest(home: true, seed: _seed),
    _Mode.category => BrowseRequest(category: _category),
    _Mode.queues => const BrowseRequest(),
  };

  void _open() {
    _listing?.dispose();
    // Queues load their own list.
    if (_mode == _Mode.queues) {
      _listing = null;
      if (mounted) setState(() {});
      return;
    }
    final listing = _listing = LibraryListing(link, _request);
    unawaited(listing.load());
    if (mounted) setState(() {});
  }

  void _select(_Mode mode, [LibraryCategory? category]) {
    // A new section shows the button again, wherever the last one was scrolled to.
    _buttonHidden = false;
    if (mode == _Mode.queues && !link.features.contains('queues')) mode = _Mode.home;
    if (mode == _mode && (category == null || category == _category)) {
      setState(() {});
      return;
    }
    setState(() {
      _mode = mode;
      if (category != null) _category = category;
    });
    _open();
  }

  // The section button steps aside while the list scrolls down, and comes back when it scrolls up.
  bool _buttonHidden = false;
  final GlobalKey _buttonKey = GlobalKey();

  bool _scrolled(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    var hide = switch (notification) {
      UserScrollNotification(direction: ScrollDirection.reverse) => true,
      UserScrollNotification(direction: ScrollDirection.forward) => false,
      _ => _buttonHidden,
    };
    // On a list too short to scroll, or once a list is back at its top, it hides nothing: it shows, being the only way
    // to another section. (A scroll down starts while the list is still at its top: the moves after it decide.)
    if (metrics.maxScrollExtent <= metrics.minScrollExtent || (notification is! UserScrollNotification && metrics.pixels <= metrics.minScrollExtent)) hide = false;
    if (hide != _buttonHidden) setState(() => _buttonHidden = hide);
    return false;
  }

  Future<void> _chooseSection() async {
    final box = _buttonKey.currentContext?.findRenderObject();
    final navigator = Navigator.of(context);
    final overlay = navigator.overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox || !box.attached) return;
    final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final current = _section;
    final chosen = await navigator.push(_SectionMenu(anchor: anchor, sections: _sections, current: current));
    if (chosen == null || !mounted) return;
    _select(chosen.mode, chosen.category);
  }

  /// Pull to refresh: the list stays as it is until the new one has come, and the spinner stays until then too.
  Future<void> _refresh() async {
    final mode = _mode, category = _category, old = _listing;
    if (_mode == _Mode.home) _seed++;
    final fresh = LibraryListing(link, _request);
    await fresh.load();
    if (!mounted || _mode != mode || _category != category || !identical(_listing, old)) {
      fresh.dispose();
      return;
    }
    if (fresh.error != null && (old?.entries.isNotEmpty ?? false)) {
      fresh.dispose();
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(fresh.error!), duration: const Duration(seconds: 4)));
      return;
    }
    old?.dispose();
    setState(() => _listing = fresh);
  }

  Future<void> _openEntry(LibraryEntry entry) => openLibraryEntry(context, link: link, entry: entry, actions: widget.actions, changed: widget.changed);

  void _openUnwatched() => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => UnwatchedScreen(link: link, actions: widget.actions, changed: widget.changed),
  )));

  void _holdEntry(LibraryEntry entry) => unawaited(showQuickActions(context, link: link, entry: entry, actions: widget.actions));

  @override
  Widget build(BuildContext context) {
    final section = _section;
    final showButton = _available && (link.status.isConnected || (_listing?.entries.isNotEmpty ?? false));
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(
                    height: 48,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      // Home is the Library itself; any other section names itself, as its pill did when lit.
                      child: Text(section.mode == _Mode.home ? 'Library' : section.label, style: display(28), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: NotificationListener<ScrollNotification>(onNotification: _scrolled, child: _body()),
                ),
              ],
            ),
          ),
          // Over the list's bottom corner, where a thumb reaches it.
          if (showButton)
            Positioned(
              right: 16,
              bottom: 16,
              child: IgnorePointer(
                ignoring: _buttonHidden,
                child: AnimatedSlide(
                  offset: _buttonHidden ? const Offset(0, 1.6) : Offset.zero,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _buttonHidden ? 0 : 1,
                    duration: const Duration(milliseconds: 160),
                    child: SectionButton(key: _buttonKey, label: section.label, icon: section.icon, onTap: _chooseSection),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    final unavailable = libraryUnavailable(link, hasEntries: _listing?.entries.isNotEmpty ?? false);
    if (unavailable != null) return unavailable;
    if (_mode == _Mode.queues) return QueuesView(link: link, actions: widget.actions, changed: widget.changed);
    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: listing,
      builder: (context, _) {
        if (listing.entries.isEmpty) {
          if (listing.loading || !listing.started) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
          if (listing.error != null) {
            return LibraryMessage(icon: Icons.error_outline_rounded, title: "Couldn't load the library", text: listing.error!, action: ('Try again', _open));
          }
          return LibraryMessage(
            icon: Icons.video_library_outlined,
            title: 'Nothing here yet',
            text: 'Titles appear here once the PC has them in its library.',
            // A PC that has just started may not have read its library yet.
            action: ('Refresh', _open),
          );
        }
        return RefreshIndicator(
          color: Palette.accent,
          backgroundColor: Palette.elevated,
          onRefresh: _refresh,
          child: _mode == _Mode.home
              ? _home(listing)
              : PosterGrid(link: link, listing: listing, onOpen: _openEntry, onHold: _holdEntry, bottomPadding: sectionButtonClearance),
        );
      },
    );
  }

  Widget _home(LibraryListing listing) {
    // Home is one listing; it is short, so all of it loads. A page that failed waits for Try again: asking again on
    // every frame would never show why.
    if (listing.hasMore && !listing.loading && listing.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!listing.disposed && listing.hasMore && !listing.loading && listing.error == null) unawaited(listing.more());
      });
    }
    final continuing = listing.entries.where((e) => e.homeSection == 'continue').toList();
    final unwatched = listing.entries.where((e) => e.homeSection == 'unwatched').toList();
    final pick = listing.entries.where((e) => e.homeSection == 'mystery').firstOrNull;
    final suggestions = <String, List<LibraryEntry>>{};
    for (final entry in listing.entries.where((e) => e.homeSection == 'suggestions')) {
      suggestions.putIfAbsent(entry.kind, () => []).add(entry);
    }
    String rowName(String kind) => switch (kind) {
      'Movie' => 'Films to watch',
      'Show' => 'Shows to start',
      'Anime' => 'Anime to start',
      _ => kind,
    };
    return ListView(
      controller: _homeScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: sectionButtonClearance),
      children: [
        if (continuing.isNotEmpty) ...[
          const _RowTitle('Continue watching'),
          SizedBox(
            height: ContinueCard.heightOf(context),
            child: ListView.separated(
              controller: _continueRow,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: continuing.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => ContinueCard(link: link, entry: continuing[index], onOpen: _openEntry, onHold: _holdEntry),
            ),
          ),
        ],
        // Titles not started yet, the ones that came to the PC last first.
        if (unwatched.isNotEmpty) ...[
          _RowTitle('Unwatched', action: link.features.contains('unwatched') ? ('See all', _openUnwatched) : null),
          SizedBox(
            height: math.max(214, 112 * 3 / 2 + cardCaptionHeight(context)).ceilToDouble(),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: unwatched.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => SizedBox(width: 112, child: PosterCard(link: link, entry: unwatched[index], onOpen: _openEntry, onHold: _holdEntry)),
            ),
          ),
        ],
        for (final row in suggestions.entries) ...[
          _RowTitle(rowName(row.key)),
          SizedBox(
            height: math.max(214, 112 * 3 / 2 + cardCaptionHeight(context)).ceilToDouble(),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: row.value.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => SizedBox(width: 112, child: PosterCard(link: link, entry: row.value[index], onOpen: _openEntry, onHold: _holdEntry)),
            ),
          ),
        ],
        if (pick != null) ...[
          const _RowTitle("Can't decide?"),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _PickCard(link: link, entry: pick, onOpen: _openEntry)),
        ],
        if (listing.hasMore) ListingFooter(listing: listing),
      ],
    );
  }
}

/// Opens [entry] from a list: a show's or a season's page, or a title's sheet.
Future<void> openLibraryEntry(BuildContext context, {required RemoteLink link, required LibraryEntry entry, required LibraryActions actions, Listenable? changed}) async {
  if (entry.opensList) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShowScreen(link: link, show: entry, actions: actions, changed: changed)));
    return;
  }
  await showTitleSheet(context, link: link, entry: entry, actions: actions);
}

/// The Library's floating button: the section shown, which opens the others to choose from.
class SectionButton extends StatelessWidget {
  const SectionButton({super.key, required this.label, required this.icon, required this.onTap, this.open = false});
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Drawn over the open menu, where it closes it.
  final bool open;

  @override
  Widget build(BuildContext context) => Pebble(
    lit: true,
    height: 52,
    onTap: onTap,
    semanticLabel: open ? 'Close sections' : 'Section: $label. Choose another',
    padding: const EdgeInsets.only(left: 16, right: 14),
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15))),
          const SizedBox(width: 6),
          AnimatedRotation(turns: open ? 0.5 : 0, duration: const Duration(milliseconds: 200), child: const Icon(Icons.expand_less_rounded, size: 20)),
        ],
      ),
    ),
  );
}

/// The sections, stacked above the section button over a dimmed Library. The one shown is lit.
class _SectionMenu extends PopupRoute<_Section> {
  _SectionMenu({required this.anchor, required this.sections, required this.current});

  /// Where the section button is, in the navigator's overlay.
  final Rect anchor;
  final List<_Section> sections;
  final _Section current;

  @override
  Color? get barrierColor => const Color(0xB3000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close sections';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => Material(
    // The text style a page has, which a route of its own lacks.
    type: MaterialType.transparency,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // The nearest the button first, each a moment after the one below it.
        Widget item(int index, _Section section) {
          final from = (sections.length - 1 - index) * 0.08;
          final shown = CurvedAnimation(parent: animation, curve: Interval(from, math.min(1, from + 0.6), curve: Curves.easeOutCubic));
          return FadeTransition(
            opacity: shown,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(shown),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Pebble(
                  height: 48,
                  lit: identical(section, current),
                  onTap: () => Navigator.of(context).pop(section),
                  semanticLabel: section.label,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(section.icon, size: 20),
                        const SizedBox(width: 10),
                        Flexible(child: Text(section.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            Positioned(
              right: size.width - anchor.right,
              bottom: size.height - anchor.top + 6,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: math.max(0, anchor.right - 16), maxHeight: math.max(0, anchor.top - MediaQuery.paddingOf(context).top - 6)),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [for (final (index, section) in sections.indexed) item(index, section)],
                  ),
                ),
              ),
            ),
            // The button stays where it was, above the dimming, and closes the menu.
            Positioned(
              right: size.width - anchor.right,
              top: anchor.top,
              height: anchor.height,
              child: SectionButton(label: current.label, icon: current.icon, open: true, onTap: () => Navigator.of(context).pop()),
            ),
          ],
        );
      },
    ),
  );
}

/// Under a list with more to load: a spinner while the next page comes, or why it didn't, with Try again.
class ListingFooter extends StatelessWidget {
  const ListingFooter({super.key, required this.listing});
  final LibraryListing listing;

  @override
  Widget build(BuildContext context) {
    final error = listing.error;
    if (error == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          Text("Couldn't load more: $error", textAlign: TextAlign.center, style: const TextStyle(color: Palette.muted, fontSize: 13.5, height: 1.35)),
          const SizedBox(height: 10),
          PebbleButton(label: 'Try again', onTap: () => unawaited(listing.more())),
        ],
      ),
    );
  }
}

class _RowTitle extends StatelessWidget {
  const _RowTitle(this.text, {this.action});
  final String text;

  /// A link at the end of the row's title, such as See all.
  final (String, VoidCallback)? action;
  @override
  Widget build(BuildContext context) {
    final title = Text(text, style: display(19));
    final action = this.action;
    if (action == null) return Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 10), child: title);
    // The title stays where the other rows have theirs (18 above it, 10 below). The link keeps a full finger's height
    // within that room, its label lowered to the title's middle; its own padding stands in for the row's on the right.
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Stack(
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(0, 18, 96, 10), child: title),
            Positioned(
              right: 0,
              bottom: 0,
              child: TextButton(
                onPressed: action.$2,
                style: TextButton.styleFrom(foregroundColor: Palette.accent, minimumSize: const Size(48, 48), alignment: const Alignment(0, 0.35)),
                // Read out with the row it belongs to: "See all, Unwatched".
                child: Text(action.$1, semanticsLabel: '${action.$1}, $text', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A message in place of a list: an icon, a title, why, and an action when there is one.
class LibraryMessage extends StatelessWidget {
  const LibraryMessage({super.key, required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title;
  final String text;
  final (String, VoidCallback)? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Palette.muted, size: 34),
          const SizedBox(height: 12),
          Text(title, style: display(20), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(text, style: const TextStyle(color: Palette.muted, fontSize: 14, height: 1.35), textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 16),
            PebbleButton(label: action!.$1, onTap: action!.$2),
          ],
        ],
      ),
    ),
  );
}

IconData _iconFor(LibraryEntry entry) => switch (entry.kind) {
  'Show' || 'Anime' => Icons.tv_rounded,
  'Music' => Icons.music_note_rounded,
  _ => Icons.movie_outlined,
};

/// A thin bar along the bottom of a picture, for how far the PC or phone got.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar(this.fraction);
  final double fraction;
  @override
  Widget build(BuildContext context) => Container(
    height: 4,
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(2)),
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: fraction,
      child: Container(decoration: BoxDecoration(color: Palette.accent, borderRadius: BorderRadius.circular(2))),
    ),
  );
}

class _WatchedMark extends StatelessWidget {
  const _WatchedMark();
  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: const BoxDecoration(color: Palette.accent, shape: BoxShape.circle),
    child: const Icon(Icons.check_rounded, size: 16, color: Palette.accentInk),
  );
}

/// A poster with its title and caption underneath.
class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.link, required this.entry, required this.onOpen, this.onHold});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;

  /// A long press, for the title's quick actions.
  final void Function(LibraryEntry entry)? onHold;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    return Semantics(
      button: true,
      label: entry.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onOpen(entry),
        onLongPress: onHold == null ? null : () => onHold!(entry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Artwork(link: link, token: entry.artwork, width: 342, icon: _iconFor(entry)),
                  if (entry.watched) const Positioned(top: 6, right: 6, child: _WatchedMark()),
                  if (progress != null) Positioned(left: 8, right: 8, bottom: 8, child: _ProgressBar(progress)),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            Text(
              entry.year?.toString() ?? entry.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The room a card's title and caption take under its picture at the phone's text size (with the gap above them).
double cardCaptionHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return 7 + (scaler.scale(13.5) + scaler.scale(12)) * 1.4 + 2;
}

/// A listing as a grid of posters that loads more as it scrolls.
class PosterGrid extends StatelessWidget {
  const PosterGrid({super.key, required this.link, required this.listing, required this.onOpen, this.onHold, this.bottomPadding = 16});
  final RemoteLink link;
  final LibraryListing listing;
  final void Function(LibraryEntry entry) onOpen;
  final void Function(LibraryEntry entry)? onHold;

  /// The room under the last row, which can scroll clear of a button over the list.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = (width / 130).floor().clamp(3, 8);
    // A poster and, under it, its title and year at the phone's text size, so larger text doesn't overflow the card.
    final tile = (width - 32 - 12 * (columns - 1)) / columns;
    final height = math.max(tile / 0.52, (tile * 3 / 2 + cardCaptionHeight(context)).ceilToDouble());
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 600 && listing.hasMore && listing.error == null) unawaited(listing.more());
        return false;
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, mainAxisSpacing: 16, crossAxisSpacing: 12, mainAxisExtent: height),
              itemCount: listing.entries.length,
              itemBuilder: (context, index) => PosterCard(link: link, entry: listing.entries[index], onOpen: onOpen, onHold: onHold),
            ),
          ),
          if (listing.hasMore) SliverToBoxAdapter(child: ListingFooter(listing: listing)),
          if (bottomPadding > 16) SliverToBoxAdapter(child: SizedBox(height: bottomPadding - 16)),
        ],
      ),
    );
  }
}

/// Continue watching: a wide card with the resume point.
class ContinueCard extends StatelessWidget {
  const ContinueCard({super.key, required this.link, required this.entry, required this.onOpen, this.onHold});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;
  final void Function(LibraryEntry entry)? onHold;

  /// The card's height at the phone's text size: its picture and the two lines under it.
  static double heightOf(BuildContext context) => math.max(182, 130 + cardCaptionHeight(context)).ceilToDouble();

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final next = entry.positionMs < 10000;
    final lines = continueLines(entry);
    return Semantics(
      button: true,
      label: '${entry.title}, ${next ? 'next episode' : 'resume at ${formatClock(entry.positionMs)}'}',
      child: GestureDetector(
        onTap: () => onOpen(entry),
        onLongPress: onHold == null ? null : () => onHold!(entry),
        child: SizedBox(
          width: 230,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 130,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Artwork(link: link, token: entry.artwork, width: 460, icon: _iconFor(entry)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(Radius.circular(14)),
                        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xAA000000)], stops: [0.45, 1]),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      bottom: progress == null ? 10 : 20,
                      child: Row(
                        children: [
                          const Icon(Icons.play_arrow_rounded, size: 18),
                          const SizedBox(width: 2),
                          Text(next ? 'Next episode' : formatClock(entry.positionMs), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    if (progress != null) Positioned(left: 10, right: 10, bottom: 9, child: _ProgressBar(progress)),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              Text(lines.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              Text(lines.caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Continue watching card's two lines. An episode's title from the PC names its show, as its caption does
/// ("Show · Episode 1 · Pilot" over "Show · S01 E01"): the show goes on the first line once, and the episode on the
/// second ("S01 E01 · Pilot"), so the episode's own title isn't the part cut off.
@visibleForTesting
({String title, String caption}) continueLines(LibraryEntry entry) {
  final caption = entry.caption.split(' · ');
  final show = caption.first;
  if (caption.length < 2 || show.isEmpty || !entry.title.startsWith('$show · ')) return (title: entry.title, caption: entry.caption);
  final rest = entry.title.substring(show.length + 3).split(' · ');
  // "Episode 1" says what the caption's S01 E01 says.
  final numbered = caption.skip(1).any((part) => RegExp(r'\bE\d+').hasMatch(part));
  final episode = rest.where((part) => !(numbered && RegExp(r'^Episode \d+$').hasMatch(part)));
  return (title: show, caption: [...caption.skip(1), ...episode].join(' · '));
}

/// Home's random pick.
class _PickCard extends StatelessWidget {
  const _PickCard({required this.link, required this.entry, required this.onOpen});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;

  @override
  Widget build(BuildContext context) => Slab(
    padding: EdgeInsets.zero,
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => onOpen(entry),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 84, child: AspectRatio(aspectRatio: 2 / 3, child: Artwork(link: link, token: entry.artwork, width: 240, icon: _iconFor(entry)))),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title, style: display(18), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(entry.caption, style: const TextStyle(color: Palette.muted, fontSize: 12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 8),
                  Text(entry.overview, style: const TextStyle(fontSize: 13, height: 1.35), maxLines: 4, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Home's Unwatched in full: every title not started yet, newest first.
class UnwatchedScreen extends StatefulWidget {
  const UnwatchedScreen({super.key, required this.link, required this.actions, this.changed});
  final RemoteLink link;
  final LibraryActions actions;
  final Listenable? changed;

  @override
  State<UnwatchedScreen> createState() => _UnwatchedScreenState();
}

class _UnwatchedScreenState extends State<UnwatchedScreen> {
  late final LibraryListing _listing = LibraryListing(widget.link, const BrowseRequest(unwatched: true));

  @override
  void initState() {
    super.initState();
    unawaited(_listing.load());
    widget.changed?.addListener(_reload);
  }

  void _reload() => unawaited(_listing.reload());

  @override
  void dispose() {
    widget.changed?.removeListener(_reload);
    _listing.dispose();
    super.dispose();
  }

  Future<void> _open(LibraryEntry entry) async {
    if (entry.opensList) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ShowScreen(link: widget.link, show: entry, actions: widget.actions, changed: widget.changed),
      ));
      return;
    }
    await showTitleSheet(context, link: widget.link, entry: entry, actions: widget.actions);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.link, builder: (context, _) => _page(context));

  Widget _page(BuildContext context) => Scaffold(
    // This page covers the tabs: what the PC plays keeps its buttons here.
    bottomNavigationBar: MiniRemoteBar.forPage(widget.link, widget.actions.openRemote),
    appBar: AppBar(
      backgroundColor: Palette.canvas,
      surfaceTintColor: Colors.transparent,
      title: ListenableBuilder(
        listenable: _listing,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Unwatched', style: display(20)),
            Text(
              _listing.entries.isNotEmpty
                  ? '${_listing.total == 1 ? '1 title' : '${_listing.total} titles'} not started · newest first'
                  : 'Newest first',
              style: const TextStyle(fontSize: 12.5, color: Palette.muted),
            ),
          ],
        ),
      ),
    ),
    body: ListenableBuilder(
      listenable: _listing,
      builder: (context, _) {
        if (_listing.entries.isEmpty) {
          if (_listing.loading || !_listing.started) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
          return LibraryMessage(
            icon: _listing.error == null ? Icons.done_all_rounded : Icons.error_outline_rounded,
            title: _listing.error == null ? 'Nothing left to start' : "Couldn't load the list",
            text: _listing.error ?? 'Every title on the PC has been started or watched.',
            action: (_listing.error == null ? 'Refresh' : 'Try again', () => unawaited(_listing.load())),
          );
        }
        return RefreshIndicator(
          color: Palette.accent,
          backgroundColor: Palette.elevated,
          onRefresh: _listing.reload,
          // Clear of the system's navigation buttons, which this page draws under.
          child: SafeArea(
            top: false,
            child: PosterGrid(
              link: widget.link,
              listing: _listing,
              onOpen: _open,
              onHold: (entry) => unawaited(showQuickActions(context, link: widget.link, entry: entry, actions: widget.actions)),
            ),
          ),
        );
      },
    ),
  );
}

/// A show's seasons, or one season's episodes.
class ShowScreen extends StatefulWidget {
  const ShowScreen({super.key, required this.link, required this.show, required this.actions, this.season, this.changed});
  final RemoteLink link;
  final LibraryEntry show;
  final LibraryActions actions;
  final Listenable? changed;

  /// The season's entry, when listing its episodes.
  final LibraryEntry? season;

  @override
  State<ShowScreen> createState() => _ShowScreenState();
}

class _ShowScreenState extends State<ShowScreen> {
  late final LibraryListing _listing;

  @override
  void initState() {
    super.initState();
    final parent = widget.show.level == 'season' ? widget.show : widget.season;
    _listing = LibraryListing(
      widget.link,
      BrowseRequest(category: LibraryCategory.all, parentId: widget.show.id, season: parent?.season),
    );
    unawaited(_listing.load());
    widget.changed?.addListener(_reload);
  }

  void _reload() => unawaited(_listing.reload());

  @override
  void dispose() {
    widget.changed?.removeListener(_reload);
    _listing.dispose();
    super.dispose();
  }

  Future<void> _open(LibraryEntry entry) async {
    if (entry.level == 'season' && !entry.playable) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ShowScreen(link: widget.link, show: widget.show, season: entry, actions: widget.actions, changed: widget.changed),
      ));
      if (mounted) unawaited(_listing.reload());
      return;
    }
    await showTitleSheet(context, link: widget.link, entry: entry, actions: widget.actions);
    // Playing it on either side moves its resume point.
    if (mounted) unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () => mounted ? _listing.reload() : null));
  }

  // Marks every episode of the show, or of the season this page lists, as the PC's own check mark on its card does.
  bool _marking = false;
  Future<void> _markAll(bool watched) async {
    final mark = widget.actions.markWatched;
    if (mark == null || _marking) return;
    final season = widget.show.level == 'season' ? widget.show : widget.season;
    setState(() => _marking = true);
    final error = await mark(season ?? widget.show, watched, level: season == null ? 'series' : 'season', season: season?.season);
    if (!mounted) return;
    setState(() => _marking = false);
    final what = season == null ? 'Every episode' : 'This season';
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error ?? '$what is marked ${watched ? 'watched' : 'unwatched'}.'), duration: const Duration(seconds: 3)));
    // The pages that listen for changes load again on their own.
    if (error == null && widget.changed == null) unawaited(_listing.reload());
  }

  // The episode a row's play button is starting on the PC, which can take a while: its button shows it.
  String? _starting;

  Future<void> _play(LibraryEntry entry) async {
    if (_starting != null) return;
    setState(() => _starting = entry.id);
    await quickPlay(context, link: widget.link, entry: entry, actions: widget.actions);
    if (!mounted) return;
    setState(() => _starting = null);
    // Playing it on either side moves its resume point.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () => mounted ? _listing.reload() : null));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.link, builder: (context, _) => _page(context));

  Widget _page(BuildContext context) {
    final season = widget.season;
    final title = season == null ? widget.show.title : season.title;
    final link = widget.link;
    final canMark = widget.actions.markWatched != null && link.features.contains('mark-watched');
    final whole = season == null && widget.show.level != 'season' ? 'show' : 'season';
    final target = quickPlayTarget(link, widget.actions);
    return Scaffold(
      // This page covers the tabs: what the PC plays keeps its buttons here.
      bottomNavigationBar: MiniRemoteBar.forPage(link, widget.actions.openRemote),
      appBar: AppBar(
        backgroundColor: Palette.canvas,
        surfaceTintColor: Colors.transparent,
        title: Text(title, style: display(20), overflow: TextOverflow.ellipsis),
        actions: [
          if (canMark)
            ListenableBuilder(
              listenable: link,
              builder: (context, _) => PopupMenuButton<bool>(
                tooltip: 'Mark the $whole',
                icon: const Icon(Icons.done_all_rounded),
                enabled: link.status.isConnected && !_marking,
                color: Palette.elevated,
                onSelected: (watched) => unawaited(_markAll(watched)),
                itemBuilder: (context) => [
                  PopupMenuItem(value: true, child: Text('Mark $whole as watched')),
                  PopupMenuItem(value: false, child: Text('Mark $whole as unwatched')),
                ],
              ),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _listing,
        builder: (context, _) {
          if (_listing.entries.isEmpty) {
            if (_listing.loading || !_listing.started) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
            return LibraryMessage(
              icon: Icons.error_outline_rounded,
              title: _listing.error == null ? 'No episodes' : "Couldn't load this show",
              text: _listing.error ?? 'The PC has no episodes of this show.',
              action: ('Try again', () => unawaited(_listing.load())),
            );
          }
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.extentAfter < 400 && _listing.hasMore && _listing.error == null) unawaited(_listing.more());
              return false;
            },
            child: RefreshIndicator(
              color: Palette.accent,
              backgroundColor: Palette.elevated,
              onRefresh: _listing.reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                // Clear of the system's navigation buttons, which this page draws under.
                padding: EdgeInsets.fromLTRB(16, 4, 8, 24 + MediaQuery.paddingOf(context).bottom),
                children: [
                  if (season == null && widget.show.overview.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(widget.show.overview, style: const TextStyle(fontSize: 14, height: 1.4, color: Palette.muted), maxLines: 6, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(height: 16),
                  ],
                  for (final entry in _listing.entries)
                    _EpisodeRow(
                      link: widget.link,
                      entry: entry,
                      onOpen: _open,
                      onHold: (entry) => unawaited(showQuickActions(context, link: widget.link, entry: entry, actions: widget.actions)),
                      target: target,
                      starting: _starting == entry.id,
                      onPlay: _starting == null ? _play : null,
                    ),
                  if (_listing.hasMore) ListingFooter(listing: _listing),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.link, required this.entry, required this.onOpen, this.onHold, this.target, this.starting = false, this.onPlay});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;
  final void Function(LibraryEntry entry)? onHold;

  /// Where the row's play button starts the episode; null leaves the button out.
  final PlayTarget? target;

  /// This row's episode is starting on the PC.
  final bool starting;

  /// Null while another row's episode starts.
  final void Function(LibraryEntry entry)? onPlay;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final isSeason = entry.level == 'season';
    return Semantics(
      button: true,
      label: entry.title,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onOpen(entry),
        onLongPress: onHold == null ? null : () => onHold!(entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: isSeason ? 64 : 128,
                height: isSeason ? 96 : 72,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Artwork(link: link, token: entry.artwork, width: 256, icon: Icons.tv_rounded, radius: 10),
                    if (progress != null) Positioned(left: 6, right: 6, bottom: 6, child: _ProgressBar(progress)),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                      // A season's card stands on its first episode, whose number and length aren't the season's.
                      isSeason
                          ? entry.caption
                          : [
                              if (entry.episode != null && !entry.title.startsWith('Episode ${entry.episode}')) 'Episode ${entry.episode}',
                              if (entry.runtimeMinutes != null && entry.runtimeMinutes! > 0) '${entry.runtimeMinutes} min',
                              if (entry.watched) 'Watched' else if (entry.positionMs >= 10000) 'Stopped at ${formatClock(entry.positionMs)}',
                            ].join(' · '),
                      // Beside the play button there is less width: a second line keeps where it stopped in view.
                      maxLines: isSeason ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                    ),
                  ],
                ),
              ),
              if (entry.watched) const Padding(padding: EdgeInsets.only(left: 8), child: _WatchedMark()),
              if (isSeason) const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.chevron_right_rounded, color: Palette.muted)),
              // One tap plays the episode where videos were last played, without its sheet.
              if (entry.playable && target != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Pebble(
                    width: 48,
                    height: 40,
                    tapArea: Pebble.fingertip,
                    enabled: onPlay != null || starting,
                    onTap: onPlay == null ? null : () => onPlay!(entry),
                    semanticLabel: target == PlayTarget.pc ? 'Play ${entry.title} on ${link.pcName}' : 'Play ${entry.title} on this phone',
                    child: starting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.ink))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.play_arrow_rounded, size: 20),
                              Icon(target == PlayTarget.pc ? Icons.desktop_windows_outlined : Icons.phone_android_rounded, size: 13, color: Palette.muted),
                            ],
                          ),
                  ),
                )
              else if (!isSeason)
                const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A title's sheet: its picture, what it is, and where to play it.
Future<void> showTitleSheet(BuildContext context, {required RemoteLink link, required LibraryEntry entry, required LibraryActions actions}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _TitleSheet(link: link, entry: entry, actions: actions),
    );

class _TitleSheet extends StatefulWidget {
  const _TitleSheet({required this.link, required this.entry, required this.actions});
  final RemoteLink link;
  final LibraryEntry entry;
  final LibraryActions actions;
  @override
  State<_TitleSheet> createState() => _TitleSheetState();
}

class _TitleSheetState extends State<_TitleSheet> {
  bool _busy = false;
  String? _error;

  // The watched mark as last saved from here; the lists under the sheet load it again.
  late bool _watched = widget.entry.watched;
  bool _marking = false;

  LibraryEntry get entry => widget.entry;

  // The buttons follow the link: Play on PC greys out while it is down, and comes back with it.
  @override
  void initState() {
    super.initState();
    widget.link.addListener(_linkChanged);
  }

  @override
  void dispose() {
    widget.link.removeListener(_linkChanged);
    super.dispose();
  }

  void _linkChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _here({bool fromStart = false}) async {
    Navigator.of(context).pop();
    await widget.actions.watchHere(entry, fromStart: fromStart);
  }

  Future<void> _pc() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // With the mark as saved from this sheet: the PC starts a title just marked watched from its start, and keeps the
    // resume point of one just marked unwatched.
    final error = await widget.actions.playOnPc(entry.withPlayback(positionMs: entry.positionMs, watched: _watched));
    if (!mounted) return;
    if (error == null) {
      // Closed already, when the pages under it closed for the Remote: once more would close those under them.
      if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _mark() async {
    final mark = widget.actions.markWatched;
    if (mark == null) return;
    final watched = !_watched;
    setState(() {
      _marking = true;
      _error = null;
    });
    final error = await mark(entry, watched);
    if (!mounted) return;
    setState(() {
      _marking = false;
      if (error == null) {
        _watched = watched;
      } else {
        _error = error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final canWatch = link.features.contains('watch') && entry.playable;
    final resume = entry.playable && !_watched && entry.positionMs >= 10000;
    final progress = _watched ? null : entry.withPlayback(positionMs: entry.positionMs, watched: false).progress;
    // A film or an episode (songs keep no marks); a PC from before phones could mark them doesn't offer it.
    final canMark = widget.actions.markWatched != null && link.features.contains('mark-watched') && entry.kind != 'Music' &&
        (entry.level == 'movie' || entry.level == 'episode' || entry.playable);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(width: 38, height: 4, decoration: BoxDecoration(color: Palette.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 96, child: AspectRatio(aspectRatio: 2 / 3, child: Artwork(link: link, token: entry.artwork, width: 342, icon: _iconFor(entry)))),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title, style: display(22), maxLines: 3, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        [entry.caption, if (entry.runtimeMinutes != null && entry.runtimeMinutes! > 0) '${entry.runtimeMinutes} min'].where((s) => s.isNotEmpty).join(' · '),
                        style: const TextStyle(color: Palette.muted, fontSize: 13),
                      ),
                      if (_watched) ...[
                        const SizedBox(height: 8),
                        const Row(children: [Icon(Icons.check_circle_rounded, size: 16, color: Palette.accent), SizedBox(width: 6), Text('Watched', style: TextStyle(fontSize: 13))]),
                        // A title without a known length has no bar, but its resume point still shows.
                      ] else if (resume) ...[
                        if (progress != null) ...[const SizedBox(height: 10), _ProgressBar(progress)],
                        const SizedBox(height: 5),
                        Text(
                          'Stopped at ${formatClock(entry.positionMs)}${entry.durationMs > 0 ? ' of ${formatClock(entry.durationMs)}' : ''}',
                          style: const TextStyle(color: Palette.muted, fontSize: 12.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (entry.overview.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(entry.overview, style: const TextStyle(fontSize: 14, height: 1.4)),
            ],
            const SizedBox(height: 20),
            if (!entry.playable)
              const Text('This title has no file to play.', style: TextStyle(color: Palette.muted))
            else ...[
              if (!canWatch)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text('Update BlackPearl on the PC to watch its videos on this phone.', style: TextStyle(color: Palette.muted, fontSize: 13)),
                ),
              Pebble(
                lit: true,
                height: 50,
                enabled: canWatch,
                onTap: _here,
                semanticLabel: resume ? 'Resume on this phone' : 'Play on this phone',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.phone_android_rounded, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        resume ? 'Resume on phone · ${formatClock(entry.positionMs)}' : 'Play on phone',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (resume) ...[
                    Expanded(
                      child: Pebble(
                        height: 46,
                        enabled: canWatch,
                        onTap: () => _here(fromStart: true),
                        semanticLabel: 'Start over on this phone',
                        child: const Text('Start over', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Pebble(
                      height: 46,
                      enabled: link.status.isConnected && link.canStart && !_busy,
                      onTap: _pc,
                      semanticLabel: 'Play on ${link.pcName}',
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.desktop_windows_outlined, size: 18),
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(_busy ? 'Starting…' : 'Play on PC', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (!link.canStart)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text("The PC doesn't let phones start videos. It's a setting in BlackPearl's Settings › Profile.", style: TextStyle(color: Palette.muted, fontSize: 12.5)),
                ),
            ],
            if (canMark) ...[
              const SizedBox(height: 10),
              Pebble(
                height: 46,
                enabled: link.status.isConnected && !_marking,
                onTap: _mark,
                semanticLabel: _marking ? 'Saving the watched mark' : _watched ? 'Mark as unwatched' : 'Mark as watched',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_watched ? Icons.remove_done_rounded : Icons.check_rounded, size: 18),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        _marking ? 'Saving…' : _watched ? 'Mark as unwatched' : 'Mark as watched',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Palette.danger, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}
