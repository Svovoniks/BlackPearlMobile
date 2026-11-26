import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import '../protocol/library.dart';
import 'library_screen.dart';
import 'theme.dart';

/// The Search tab: the PC's library searched by title, as posters.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.link, required this.actions, this.changed, this.chosen, this.active = true});
  final RemoteLink link;
  final LibraryActions actions;

  /// Fires when playback elsewhere changed resume points or watched marks: the results load again.
  final Listenable? changed;

  /// Fires when the Search tab is tapped, before the tab shows. With nothing searched yet, or tapped while it already
  /// shows, the field takes the keyboard; coming back to earlier results leaves them in view.
  final Listenable? chosen;

  /// Whether this tab is the one showing. Leaving it puts the keyboard away.
  final bool active;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  LibraryListing? _listing;
  bool _wasConnected = false;
  LinkPhase? _phase;

  RemoteLink get link => widget.link;
  String get _text => _query.text.trim();

  @override
  void initState() {
    super.initState();
    link.addListener(_linkChanged);
    widget.changed?.addListener(_playbackChanged);
    widget.chosen?.addListener(_tabChosen);
    _wasConnected = link.status.isConnected;
    _phase = link.status.phase;
  }

  @override
  void didUpdateWidget(SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link != link) {
      oldWidget.link.removeListener(_linkChanged);
      link.addListener(_linkChanged);
      _wasConnected = link.status.isConnected;
      _phase = link.status.phase;
      _search();
    }
    if (oldWidget.changed != widget.changed) {
      oldWidget.changed?.removeListener(_playbackChanged);
      widget.changed?.addListener(_playbackChanged);
    }
    if (oldWidget.chosen != widget.chosen) {
      oldWidget.chosen?.removeListener(_tabChosen);
      widget.chosen?.addListener(_tabChosen);
    }
    if (oldWidget.active && !widget.active) _focus.unfocus();
  }

  @override
  void dispose() {
    link.removeListener(_linkChanged);
    widget.changed?.removeListener(_playbackChanged);
    widget.chosen?.removeListener(_tabChosen);
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    _listing?.dispose();
    super.dispose();
  }

  void _tabChosen() {
    // Heard before the tab shows: [widget.active] still says whether it was showing already.
    if (_text.isNotEmpty && !widget.active) return;
    // A tab out of sight takes no focus, so the field asks once it shows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _query.selection = TextSelection(baseOffset: 0, extentOffset: _query.text.length);
    });
  }

  void _linkChanged() {
    final connected = link.status.isConnected;
    if (connected == _wasConnected) {
      if (link.status.phase != _phase && mounted) setState(() => _phase = link.status.phase);
      return;
    }
    _phase = link.status.phase;
    _wasConnected = connected;
    // Back after a drop: a search that failed or never ran asks again.
    final listing = _listing;
    if (connected && (listing == null || listing.error != null || !listing.started)) _search();
    if (mounted) setState(() {});
  }

  void _playbackChanged() {
    final listing = _listing;
    if (listing != null && listing.started) unawaited(listing.reload());
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
    setState(() {});
  }

  void _search() {
    _debounce?.cancel();
    _listing?.dispose();
    _listing = null;
    if (_text.isNotEmpty && link.status.isConnected && link.features.contains('library')) {
      final listing = _listing = LibraryListing(link, BrowseRequest(query: _text));
      unawaited(listing.load());
    }
    if (mounted) setState(() {});
  }

  void _clear() {
    _query.clear();
    _search();
    _focus.requestFocus();
  }

  Future<void> _openEntry(LibraryEntry entry) => openLibraryEntry(context, link: link, entry: entry, actions: widget.actions, changed: widget.changed);

  void _holdEntry(LibraryEntry entry) => unawaited(showQuickActions(context, link: link, entry: entry, actions: widget.actions));

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(
              height: 48,
              child: Align(alignment: Alignment.centerLeft, child: Text('Search', style: display(28), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ),
          ),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _field()),
          const SizedBox(height: 8),
          Expanded(
            // Scrolling the results puts the keyboard away, so they show whole.
            child: NotificationListener<ScrollStartNotification>(
              onNotification: (notification) {
                if (notification.dragDetails != null && notification.metrics.axis == Axis.vertical) _focus.unfocus();
                return false;
              },
              child: _body(),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _field() => SizedBox(
    height: 48,
    child: TextField(
      controller: _query,
      focusNode: _focus,
      onChanged: _changed,
      onSubmitted: (_) => _search(),
      textInputAction: TextInputAction.search,
      style: const TextStyle(color: Palette.ink, fontSize: 16),
      decoration: InputDecoration(
        hintText: 'Search ${link.pcName}',
        hintStyle: const TextStyle(color: Palette.muted),
        prefixIcon: const Icon(Icons.search_rounded, color: Palette.muted),
        suffixIcon: _query.text.isEmpty
            ? null
            : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded, color: Palette.muted), onPressed: _clear),
        filled: true,
        fillColor: Palette.well,
        contentPadding: EdgeInsets.zero,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      ),
    ),
  );

  Widget _body() {
    final listing = _listing;
    final unavailable = libraryUnavailable(link, hasEntries: listing?.entries.isNotEmpty ?? false);
    if (unavailable != null) return unavailable;
    if (_text.isEmpty) {
      return const LibraryMessage(icon: Icons.search_rounded, title: 'Search the library', text: 'Titles, shows and episodes on the PC.');
    }
    // Typed, and the search is about to start.
    if (listing == null) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
    return ListenableBuilder(
      listenable: listing,
      builder: (context, _) {
        if (listing.entries.isEmpty) {
          if (listing.loading || !listing.started) return const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
          if (listing.error != null) {
            return LibraryMessage(icon: Icons.error_outline_rounded, title: "Couldn't search the library", text: listing.error!, action: ('Try again', _search));
          }
          return const LibraryMessage(icon: Icons.search_off_rounded, title: 'Nothing found', text: 'Try another word.');
        }
        return RefreshIndicator(
          color: Palette.accent,
          backgroundColor: Palette.elevated,
          onRefresh: listing.reload,
          child: PosterGrid(link: link, listing: listing, onOpen: _openEntry, onHold: _holdEntry),
        );
      },
    );
  }
}
