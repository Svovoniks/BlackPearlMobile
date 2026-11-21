import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../connection/remote_link.dart';
import '../protocol/library.dart';
import 'artwork.dart';
import 'library_screen.dart';
import 'pebbles.dart';
import 'theme.dart';

/// Loads a list's pages until it has them all, or [max] entries, and in any case until it has the video [mustHave], so
/// the steps from it are worked out from the list itself.
Future<void> loadWholeList(LibraryListing listing, {int max = 400, String? mustHave}) async {
  await listing.load();
  bool has() => mustHave == null || listing.entries.any((e) => e.id == mustHave);
  while (!listing.disposed && listing.hasMore && listing.error == null && (listing.entries.length < max || !has())) {
    // A listing that was closed, or is loading elsewhere, doesn't move on: stop rather than ask for the page again.
    final page = listing.nextPage;
    await listing.more();
    if (listing.nextPage == page && listing.error == null) break;
  }
}

/// Where Play continues in a queue's [entries]: the PC's up next [place], or, once the entries show that one watched, the
/// first unwatched video after it, then from the queue's start; the first one when all are watched. The same steps as
/// the PC's own.
LibraryEntry? queueUpNext(List<LibraryEntry> entries, int? place) {
  bool ready(LibraryEntry e) => e.playable && !e.watched;
  return entries.where((e) => (e.index ?? 0) >= (place ?? 0) && ready(e)).firstOrNull ??
      entries.where(ready).firstOrNull ??
      entries.where((e) => e.playable).firstOrNull;
}

/// The height of a [QueueEntryRow] at the phone's text size, so long lists build only the rows on screen and can open
/// at the playing one: the picture, or two lines of title and one of caption when the text is larger.
double queueRowExtentOf(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final text = scaler.scale(14.5) * 1.25 * 2 + 2 + scaler.scale(12.5) * 1.4;
  return (math.max(58.0, text) + 16 + 2).ceilToDouble();
}

/// Scrolls [controller]'s list of rows [extent] high so row [index] sits a quarter of the way down.
void showQueueRow(ScrollController controller, int index, double extent) {
  if (index < 0 || !controller.hasClients) return;
  final position = controller.position;
  final target = (index * extent - position.viewportDimension * 0.25).clamp(0.0, position.maxScrollExtent);
  unawaited(controller.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
}

/// The PC's saved queues, from its `queues` answer.
Future<List<QueueSummary>> loadQueues(RemoteLink link) async => QueueSummary.listFromJson(await link.ask('queues', const {}));

/// One video in a queue's or a show's list: its picture, what it is, and how far it got.
class QueueEntryRow extends StatelessWidget {
  const QueueEntryRow({super.key, required this.link, required this.entry, required this.onTap, this.current = false, this.light = false});
  final RemoteLink link;
  final LibraryEntry entry;
  final VoidCallback? onTap;

  /// The video playing now.
  final bool current;

  /// On a dark sheet over the video rather than the app's canvas.
  final bool light;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final dim = !entry.playable;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: onTap != null,
        selected: current,
        label: [
          entry.title,
          if (entry.caption.isNotEmpty) entry.caption,
          if (current) 'playing',
          if (entry.watched) 'watched',
          if (dim) 'unavailable',
        ].join(', '),
        excludeSemantics: true,
        child: Material(
          color: current ? Palette.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: dim ? null : onTap,
            child: Container(
              height: queueRowExtentOf(context) - 2,
              padding: const EdgeInsets.all(8),
              child: Opacity(
                opacity: dim ? 0.45 : 1,
                child: Row(
                  children: [
                    SizedBox(
                      width: 104,
                      height: 58,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Artwork(
                            link: link,
                            token: entry.artwork,
                            width: 240,
                            radius: 10,
                            icon: entry.level == 'episode' ? Icons.tv_rounded : Icons.movie_outlined,
                          ),
                          if (progress != null)
                            Positioned(
                              left: 6,
                              right: 6,
                              bottom: 5,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 3,
                                  color: Palette.accent,
                                  backgroundColor: const Color(0x55000000),
                                ),
                              ),
                            ),
                          if (current)
                            const Center(
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: Color(0xB3000000), shape: BoxShape.circle),
                                child: Padding(
                                  padding: EdgeInsets.all(5),
                                  child: Icon(Icons.equalizer_rounded, size: 18, color: Palette.accent),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: current ? FontWeight.w700 : FontWeight.w600,
                              color: Palette.ink,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [if (current) 'Playing', if (entry.caption.isNotEmpty) entry.caption, if (dim) 'Not available'].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: current ? Palette.accent : Palette.muted),
                          ),
                        ],
                      ),
                    ),
                    if (entry.watched) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check_circle_rounded, size: 18, color: Palette.accent, semanticLabel: 'Watched'),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which list Previous, Next and up next follow: the show's episodes, or one of the PC's queues.
class ListChooser extends StatelessWidget {
  const ListChooser({
    super.key,
    required this.queues,
    required this.selected,
    required this.onSelect,
    this.loading = false,
    this.episodes = true,
  });

  /// Null while the PC's queues are loading.
  final List<QueueSummary>? queues;

  /// A queue id, or null for the show's episodes.
  final String? selected;
  final void Function(QueueSummary? queue) onSelect;
  final bool loading;

  /// Whether "Episodes" is offered.
  final bool episodes;

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, bool on, VoidCallback onTap, {IconData? icon}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        button: true,
        selected: on,
        child: Material(
          color: on ? Palette.accent : Palette.elevated,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, size: 16, color: on ? Palette.accentInk : Palette.ink), const SizedBox(width: 6)],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? Palette.accentInk : Palette.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final list = queues;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (episodes) pill('Episodes', selected == null, () => onSelect(null), icon: Icons.tv_rounded),
          if (list == null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.accent)),
            )
          else
            for (final queue in list) pill(queue.name, selected == queue.id, () => onSelect(queue), icon: Icons.queue_play_next_rounded),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.accent)),
            ),
        ],
      ),
    );
  }
}

/// Library › Queues: the PC's saved queues, each opening its videos.
class QueuesView extends StatefulWidget {
  const QueuesView({super.key, required this.link, required this.actions, required this.changed});
  final RemoteLink link;
  final LibraryActions actions;

  /// Bumped when playback elsewhere may have moved a queue on.
  final Listenable? changed;

  @override
  State<QueuesView> createState() => _QueuesViewState();
}

class _QueuesViewState extends State<QueuesView> {
  List<QueueSummary>? _queues;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changed?.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.changed?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final queues = await loadQueues(widget.link);
      if (mounted) {
        setState(() {
          _queues = queues;
          _error = null;
        });
      }
    } on RemoteRequestException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final queues = _queues;
    if (queues == null) {
      return _error != null
          ? _Empty(icon: Icons.error_outline_rounded, title: "Couldn't load the queues", text: _error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5));
    }
    if (queues.isEmpty) {
      return const _Empty(
        icon: Icons.queue_play_next_rounded,
        title: 'No queues yet',
        text: 'Make a queue on the PC, on its Queues page or from the player, and it shows here.',
      );
    }
    return RefreshIndicator(
      color: Palette.accent,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: queues.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _QueueCard(
          link: widget.link,
          queue: queues[index],
          onOpen: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => QueueScreen(link: widget.link, queue: queues[index], actions: widget.actions, changed: widget.changed),
              ),
            );
            unawaited(_load());
          },
        ),
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.link, required this.queue, required this.onOpen});
  final RemoteLink link;
  final QueueSummary queue;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${queue.name}, ${_count(queue.count)}${queue.active ? ', the PC\'s queue' : ''}',
    excludeSemantics: true,
    child: Slab(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              SizedBox(
                width: 128,
                height: 72,
                child: Artwork(link: link, token: queue.artwork, width: 300, radius: 12, icon: Icons.queue_play_next_rounded),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(queue.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(18)),
                    const SizedBox(height: 4),
                    Text(
                      [
                        _count(queue.count),
                        if (queue.active) 'Playing on the PC',
                        if (queue.upNext == null && queue.count > 0) 'All watched',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: queue.active ? Palette.accent : Palette.muted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Palette.muted),
            ],
          ),
        ),
      ),
    ),
  );
}

String _count(int count) => count == 1 ? '1 video' : '$count videos';

/// A queue's videos in order, with Play (on the phone or the PC) from where it continues.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, required this.link, required this.queue, required this.actions, required this.changed});
  final RemoteLink link;
  final QueueSummary queue;
  final LibraryActions actions;
  final Listenable? changed;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  late final LibraryListing _listing = LibraryListing(widget.link, BrowseRequest(queue: widget.queue.id))..addListener(_changed);
  late final LibraryActions _actions = widget.actions.inQueue(widget.queue.ref);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changed?.addListener(_reload);
    unawaited(_listing.load());
  }

  @override
  void dispose() {
    widget.changed?.removeListener(_reload);
    _listing.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _reload() => unawaited(_listing.reload());

  LibraryEntry? get _upNext => queueUpNext(_listing.entries, widget.queue.upNext);

  Future<void> _playHere(LibraryEntry entry) => _actions.watchHere(entry);

  Future<void> _playOnPc(LibraryEntry entry) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await _actions.playOnPc(entry);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final entries = _listing.entries;
    final next = _upNext;
    final canWatch = link.features.contains('watch');
    return Scaffold(
      backgroundColor: Palette.canvas,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(tooltip: 'Back', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back_rounded)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(widget.queue.name, style: display(26), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      [
                        _count(_listing.total > 0 ? _listing.total : widget.queue.count),
                        if (widget.queue.active) 'Playing on the PC',
                      ].join(' · '),
                      style: TextStyle(color: widget.queue.active ? Palette.accent : Palette.muted, fontSize: 13.5),
                    ),
                    if (next != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        'Up next: ${next.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, color: Palette.muted),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (canWatch) ...[
                            Expanded(
                              child: PebbleButton(
                                label: 'Play on phone',
                                icon: Icons.phone_android_rounded,
                                lit: true,
                                onTap: _busy ? null : () => _playHere(next),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: PebbleButton(
                              label: _busy ? 'Starting…' : 'Play on PC',
                              icon: Icons.desktop_windows_outlined,
                              onTap: _busy ? null : () => _playOnPc(next),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(_error!, style: const TextStyle(color: Palette.danger, fontSize: 13.5)),
                    ],
                  ],
                ),
              ),
            ),
            if (entries.isEmpty && _listing.loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5)),
              )
            else if (entries.isEmpty && _listing.error != null)
              SliverFillRemaining(
                child: _Empty(
                  icon: Icons.error_outline_rounded,
                  title: "Couldn't load the queue",
                  text: _listing.error!,
                  onRetry: () => _listing.load(),
                ),
              )
            else if (entries.isEmpty)
              const SliverFillRemaining(
                child: _Empty(icon: Icons.queue_play_next_rounded, title: 'This queue is empty', text: 'Add videos to it on the PC.'),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
                sliver: SliverList.builder(
                  itemCount: entries.length + (_listing.hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= entries.length) {
                      unawaited(_listing.more());
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5)),
                      );
                    }
                    final entry = entries[index];
                    return QueueEntryRow(
                      link: link,
                      entry: entry,
                      onTap: () => unawaited(showTitleSheet(context, link: link, entry: entry, actions: _actions)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The Remote tab's list of what the PC plays through: its queue, or the playing show's episodes. Choosing a video
/// plays it on the PC as part of that list.
Future<void> showRemoteUpNext(BuildContext context, {required RemoteLink link, required String? mediaId, required QueueRef? queue}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      builder: (context) => _RemoteUpNext(link: link, mediaId: mediaId, queue: queue),
    );

class _RemoteUpNext extends StatefulWidget {
  const _RemoteUpNext({required this.link, required this.mediaId, required this.queue});
  final RemoteLink link;
  final String? mediaId;
  final QueueRef? queue;

  @override
  State<_RemoteUpNext> createState() => _RemoteUpNextState();
}

class _RemoteUpNextState extends State<_RemoteUpNext> {
  List<QueueSummary>? _queues;
  late String? _selected = widget.queue?.id;
  LibraryListing? _listing;
  String? _error;
  bool _busy = false;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(
      loadQueues(widget.link).then(
        (queues) {
          if (mounted) setState(() => _queues = queues);
        },
        onError: (Object _) {
          if (mounted) setState(() => _queues = const []);
        },
      ),
    );
    _open();
  }

  @override
  void dispose() {
    _listing?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open() {
    _listing?.dispose();
    final selected = _selected;
    final listing = selected != null
        ? LibraryListing(widget.link, BrowseRequest(queue: selected))
        : widget.mediaId != null
        ? LibraryListing(widget.link, BrowseRequest(episodesOf: widget.mediaId))
        : null;
    _listing = listing
      ?..addListener(() {
        if (mounted) setState(() {});
      });
    if (listing != null) {
      unawaited(
        loadWholeList(listing, mustHave: widget.mediaId).then((_) {
          // The playing video's row comes into view once the list is there.
          if (!mounted || !identical(listing, _listing)) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) showQueueRow(_scroll, listing.entries.indexWhere(_current), queueRowExtentOf(context));
          });
        }),
      );
    }
  }

  Future<void> _play(LibraryEntry entry) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final selected = _selected;
    try {
      await widget.link.ask('play', {
        'id': entry.id,
        'positionMs': entry.watched ? 0 : entry.positionMs,
        if (selected != null) ...{'queue': selected, 'queueIndex': ?entry.index},
      }, timeout: const Duration(seconds: 30));
      if (mounted) Navigator.of(context).pop();
    } on RemoteRequestException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  bool _current(LibraryEntry entry) =>
      entry.id == widget.mediaId &&
      (_selected == null || _selected != widget.queue?.id || widget.queue?.index == null || entry.index == widget.queue?.index);

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final entries = listing?.entries ?? const <LibraryEntry>[];
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
            child: Row(
              children: [
                Expanded(child: Text('Up next on the PC', style: display(20))),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Palette.muted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: ListChooser(
              queues: _queues,
              selected: _selected,
              episodes: widget.mediaId != null,
              loading: listing?.loading ?? false,
              onSelect: (queue) {
                if (queue?.id == _selected) return;
                setState(() => _selected = queue?.id);
                _open();
              },
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text(_error!, style: const TextStyle(color: Palette.danger, fontSize: 13.5)),
            ),
          Flexible(
            child: listing == null
                ? const _Empty(
                    icon: Icons.queue_play_next_rounded,
                    title: 'Choose a queue',
                    text: 'The PC plays a video from it, then goes on through it.',
                  )
                : entries.isEmpty && listing.loading
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator(color: Palette.accent, strokeWidth: 2.5)),
                  )
                : entries.isEmpty
                ? _Empty(
                    icon: Icons.queue_play_next_rounded,
                    title: listing.error != null ? "Couldn't load the list" : (_selected == null ? 'No episodes' : 'This queue is empty'),
                    text: listing.error ?? (_selected == null ? 'This video has no episodes around it.' : 'Add videos to it on the PC.'),
                  )
                : Builder(
                    builder: (context) {
                      // One row is the playing one, also when the video is in the list twice. Rows are built as they
                      // scroll into view, so pictures load a screen at a time.
                      final at = entries.indexWhere(_current);
                      return ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                        itemExtent: queueRowExtentOf(context),
                        itemCount: entries.length,
                        itemBuilder: (context, i) => QueueEntryRow(
                          link: widget.link,
                          entry: entries[i],
                          current: i == at,
                          onTap: _busy ? null : () => unawaited(_play(entries[i])),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.text, this.onRetry});
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: Palette.muted),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: display(19)),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Palette.muted, fontSize: 14, height: 1.35),
          ),
          if (onRetry != null) ...[const SizedBox(height: 14), PebbleButton(label: 'Try again', onTap: onRetry)],
        ],
      ),
    ),
  );
}
