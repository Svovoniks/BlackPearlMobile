import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import '../protocol/library.dart';
import '../protocol/remote_state.dart';
import 'artwork.dart';
import 'pebbles.dart';
import 'queue_widgets.dart';
import 'theme.dart';

/// What the library screens do with a title: play it here, or start it on the PC.
class LibraryActions {
  const LibraryActions({required this.watchHere, required this.playOnPc});

  /// Plays [entry] on the phone. [fromStart] ignores the resume point; [queue] plays it as part of a saved queue.
  final Future<void> Function(LibraryEntry entry, {bool fromStart, QueueRef? queue}) watchHere;

  /// Starts [entry] on the PC, as part of [queue] when given; returns why it couldn't, or null.
  final Future<String?> Function(LibraryEntry entry, {bool fromStart, QueueRef? queue}) playOnPc;

  /// The same actions, playing each listed video as part of [list] at the video's place.
  LibraryActions inQueue(QueueRef list) => LibraryActions(
    watchHere: (entry, {bool fromStart = false, QueueRef? queue}) => watchHere(entry, fromStart: fromStart, queue: queue ?? list.at(entry.index)),
    playOnPc: (entry, {bool fromStart = false, QueueRef? queue}) => playOnPc(entry, fromStart: fromStart, queue: queue ?? list.at(entry.index)),
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

enum _Mode { home, category, queues, search }

/// The Library tab: Home's rows, each category as a grid of posters, and search.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.link, required this.actions, this.changed});
  final RemoteLink link;
  final LibraryActions actions;

  /// Fires when playback elsewhere changed resume points or watched marks: the list loads again.
  final Listenable? changed;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  _Mode _mode = _Mode.home;
  LibraryCategory _category = LibraryCategory.films;
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  LibraryListing? _listing;
  bool _wasConnected = false;
  int _seed = DateTime.now().millisecondsSinceEpoch & 0xffff;

  RemoteLink get link => widget.link;
  bool get _available => link.features.contains('library');

  @override
  void initState() {
    super.initState();
    link.addListener(_linkChanged);
    widget.changed?.addListener(_playbackChanged);
    _wasConnected = link.status.isConnected;
    if (_wasConnected && _available) _open();
  }

  void _playbackChanged() {
    final listing = _listing;
    if (listing != null && listing.started) unawaited(listing.reload());
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link != link) {
      oldWidget.link.removeListener(_linkChanged);
      link.addListener(_linkChanged);
      _wasConnected = link.status.isConnected;
      _listing?.dispose();
      _listing = null;
      if (_wasConnected && _available) _open();
    }
  }

  @override
  void dispose() {
    link.removeListener(_linkChanged);
    widget.changed?.removeListener(_playbackChanged);
    _searchDebounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _listing?.dispose();
    super.dispose();
  }

  void _linkChanged() {
    final connected = link.status.isConnected;
    if (connected == _wasConnected) return;
    _wasConnected = connected;
    // Coming back after a drop: load again, unless what is shown loaded fine. An empty list loads again too: a PC that
    // has just started may have answered before it had read its library.
    if (connected && _available && (_listing == null || _listing!.error != null || !_listing!.started || _listing!.entries.isEmpty)) _open();
    if (mounted) setState(() {});
  }

  BrowseRequest get _request => switch (_mode) {
    _Mode.home => BrowseRequest(home: true, seed: _seed),
    _Mode.category => BrowseRequest(category: _category),
    _Mode.search => BrowseRequest(query: _search.text.trim()),
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
    if (_mode != _Mode.search || _search.text.trim().isNotEmpty) unawaited(listing.load());
    if (mounted) setState(() {});
  }

  void _select(_Mode mode, [LibraryCategory? category]) {
    if (mode == _mode && (category == null || category == _category)) return;
    // A search still waiting to start belongs to the search field, not to the listing chosen now.
    _searchDebounce?.cancel();
    setState(() {
      _mode = mode;
      if (category != null) _category = category;
    });
    if (mode == _Mode.search) {
      _searchFocus.requestFocus();
    } else {
      _searchFocus.unfocus();
    }
    _open();
    _revealPill(_pillKeys[mode == _Mode.category ? category ?? _category : mode]!);
  }

  // The pills' row scrolls to show the chosen one whole.
  late final Map<Object, GlobalKey> _pillKeys = {
    for (final key in [..._Mode.values, LibraryCategory.films, LibraryCategory.shows, LibraryCategory.anime]) key: GlobalKey(),
  };

  void _revealPill(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = key.currentContext;
      final box = context?.findRenderObject();
      if (context == null || box is! RenderBox || !box.attached) return;
      final viewport = RenderAbstractViewport.maybeOf(box);
      final position = Scrollable.maybeOf(context)?.position;
      if (viewport == null || position == null) return;
      // The row's own padding stays beside the pill: 16 before it; after it, the pill's 8 and the row's 8.
      final start = viewport.getOffsetToReveal(box, 0).offset - 16;
      final end = viewport.getOffsetToReveal(box, 1).offset + 8;
      final target = position.pixels > start ? start : position.pixels < end ? end : null;
      if (target == null) return;
      unawaited(position.animateTo(target.clamp(position.minScrollExtent, position.maxScrollExtent), duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic));
    });
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

  void _searchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _open);
    setState(() {});
  }

  Future<void> _openEntry(LibraryEntry entry) async {
    if (entry.opensList) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShowScreen(link: link, show: entry, actions: widget.actions, changed: widget.changed)));
      return;
    }
    await showTitleSheet(context, link: link, entry: entry, actions: widget.actions);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _mode == _Mode.search ? _searchField() : Text('Library', style: display(28)),
            ),
            const SizedBox(height: 12),
            _modes(),
            const SizedBox(height: 6),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _searchField() => SizedBox(
    height: 44,
    child: TextField(
      controller: _search,
      focusNode: _searchFocus,
      onChanged: _searchChanged,
      textInputAction: TextInputAction.search,
      style: const TextStyle(color: Palette.ink, fontSize: 16),
      decoration: InputDecoration(
        hintText: 'Search ${link.pcName}',
        hintStyle: const TextStyle(color: Palette.muted),
        prefixIcon: const Icon(Icons.search_rounded, color: Palette.muted),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded, color: Palette.muted),
                onPressed: () {
                  _search.clear();
                  _open();
                },
              ),
        filled: true,
        fillColor: Palette.well,
        contentPadding: EdgeInsets.zero,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
      ),
    ),
  );

  Widget _modes() {
    Widget pill(Object key, String label, bool selected, VoidCallback onTap, {IconData? icon}) => Padding(
      key: _pillKeys[key],
      padding: const EdgeInsets.only(right: 8),
      child: Pebble(
        height: 38,
        lit: selected,
        onTap: onTap,
        semanticLabel: label,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
        children: [
          pill(_Mode.home, 'Home', _mode == _Mode.home, () => _select(_Mode.home)),
          for (final category in [LibraryCategory.films, LibraryCategory.shows, LibraryCategory.anime])
            pill(category, category.label, _mode == _Mode.category && _category == category, () => _select(_Mode.category, category)),
          if (link.features.contains('queues'))
            pill(_Mode.queues, 'Queues', _mode == _Mode.queues, () => _select(_Mode.queues), icon: Icons.queue_play_next_rounded),
          pill(_Mode.search, 'Search', _mode == _Mode.search, () => _select(_Mode.search), icon: Icons.search_rounded),
        ],
      ),
    );
  }

  Widget _body() {
    if (!link.status.isConnected && (_listing == null || _listing!.entries.isEmpty)) {
      return _Message(icon: Icons.cloud_off_rounded, title: 'Not connected', text: "The library shows once the phone reaches ${link.pcName}. The Remote tab says how it's going.");
    }
    if (link.status.isConnected && !_available) {
      return _Message(
        icon: Icons.system_update_alt_rounded,
        title: 'Update BlackPearl on the PC',
        text: '${link.pcName} runs a BlackPearl from before the phone could browse it. Update it on the PC to see its library here.',
      );
    }
    if (_mode == _Mode.queues) return QueuesView(link: link, actions: widget.actions, changed: widget.changed);
    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    if (_mode == _Mode.search && _search.text.trim().isEmpty) {
      return const _Message(icon: Icons.search_rounded, title: 'Search the library', text: 'Titles, shows and episodes on the PC.');
    }
    return ListenableBuilder(
      listenable: listing,
      builder: (context, _) {
        if (listing.entries.isEmpty) {
          if (listing.loading || !listing.started) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
          if (listing.error != null) {
            return _Message(icon: Icons.error_outline_rounded, title: "Couldn't load the library", text: listing.error!, action: ('Try again', _open));
          }
          return _Message(
            icon: Icons.video_library_outlined,
            title: _mode == _Mode.search ? 'Nothing found' : 'Nothing here yet',
            text: _mode == _Mode.search ? 'Try another word.' : 'Titles appear here once the PC has them in its library.',
            // A PC that has just started may not have read its library yet.
            action: _mode == _Mode.search ? null : ('Refresh', _open),
          );
        }
        return RefreshIndicator(
          color: Palette.accent,
          backgroundColor: Palette.elevated,
          onRefresh: _refresh,
          child: _mode == _Mode.home ? _home(listing) : PosterGrid(link: link, listing: listing, onOpen: _openEntry),
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
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (continuing.isNotEmpty) ...[
          const _RowTitle('Continue watching'),
          SizedBox(
            height: math.max(182, 130 + cardCaptionHeight(context)).ceilToDouble(),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: continuing.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => _ContinueCard(link: link, entry: continuing[index], onOpen: _openEntry),
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
              itemBuilder: (context, index) => SizedBox(width: 112, child: PosterCard(link: link, entry: row.value[index], onOpen: _openEntry)),
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
  const _RowTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
    child: Text(text, style: display(19)),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.text, this.action});
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
  const PosterCard({super.key, required this.link, required this.entry, required this.onOpen});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    return Semantics(
      button: true,
      label: entry.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onOpen(entry),
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
  const PosterGrid({super.key, required this.link, required this.listing, required this.onOpen});
  final RemoteLink link;
  final LibraryListing listing;
  final void Function(LibraryEntry entry) onOpen;

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
              itemBuilder: (context, index) => PosterCard(link: link, entry: listing.entries[index], onOpen: onOpen),
            ),
          ),
          if (listing.hasMore) SliverToBoxAdapter(child: ListingFooter(listing: listing)),
        ],
      ),
    );
  }
}

/// Continue watching: a wide card with the resume point.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.link, required this.entry, required this.onOpen});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final next = entry.positionMs < 10000;
    return Semantics(
      button: true,
      label: '${entry.title}, ${next ? 'next episode' : 'resume at ${formatClock(entry.positionMs)}'}',
      child: GestureDetector(
        onTap: () => onOpen(entry),
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
              Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              Text(entry.caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ],
          ),
        ),
      ),
    );
  }
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

  @override
  Widget build(BuildContext context) {
    final season = widget.season;
    final title = season == null ? widget.show.title : season.title;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Palette.canvas,
        surfaceTintColor: Colors.transparent,
        title: Text(title, style: display(20), overflow: TextOverflow.ellipsis),
      ),
      body: ListenableBuilder(
        listenable: _listing,
        builder: (context, _) {
          if (_listing.entries.isEmpty) {
            if (_listing.loading || !_listing.started) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
            return _Message(
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
            child: ListView(
              // Clear of the system's navigation buttons, which this page draws under.
              padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                if (season == null && widget.show.overview.isNotEmpty) ...[
                  Text(widget.show.overview, style: const TextStyle(fontSize: 14, height: 1.4, color: Palette.muted), maxLines: 6, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 16),
                ],
                for (final entry in _listing.entries) _EpisodeRow(link: widget.link, entry: entry, onOpen: _open),
                if (_listing.hasMore) ListingFooter(listing: _listing),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.link, required this.entry, required this.onOpen});
  final RemoteLink link;
  final LibraryEntry entry;
  final void Function(LibraryEntry entry) onOpen;

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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Palette.muted),
                    ),
                  ],
                ),
              ),
              if (entry.watched) const Padding(padding: EdgeInsets.only(left: 8), child: _WatchedMark()),
              if (isSeason) const Icon(Icons.chevron_right_rounded, color: Palette.muted),
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
    final error = await widget.actions.playOnPc(entry);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final canWatch = link.features.contains('watch') && entry.playable;
    final resume = entry.playable && !entry.watched && entry.positionMs >= 10000;
    final progress = entry.progress;
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
                      if (entry.watched) ...[
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
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: Palette.danger, fontSize: 13)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
