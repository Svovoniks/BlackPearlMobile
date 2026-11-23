import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../connection/media_channel.dart';
import '../connection/remote_link.dart';
import 'theme.dart';

/// Pictures from the PC's library, read over the media channel as `art/<token>/<width>` and kept in memory while the
/// app runs. The same picture asked for twice at once is read once.
class ArtworkCache {
  ArtworkCache._();
  static final ArtworkCache instance = ArtworkCache._();

  static const int _capacity = 160;
  final LinkedHashMap<String, Uint8List> _images = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _loading = {};

  Uint8List? peek(String token, int width) {
    final key = '$token/$width';
    final image = _images.remove(key);
    if (image != null) _images[key] = image;
    return image;
  }

  Future<Uint8List?> load(RemoteLink link, String token, int width) {
    final key = '$token/$width';
    final cached = peek(token, width);
    if (cached != null) return Future.value(cached);
    return _loading[key] ??= _fetch(link, 'art/$token/$width').then((bytes) {
      _loading.remove(key);
      if (bytes != null) {
        _images[key] = bytes;
        while (_images.length > _capacity) {
          _images.remove(_images.keys.first);
        }
      }
      return bytes;
    });
  }

  static Future<Uint8List?> _fetch(RemoteLink link, String resource) async {
    // The link can still be coming up when the library first shows.
    for (var wait = 0; wait < 20 && link.media == null; wait++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final reader = link.media;
    if (reader == null) return null;
    try {
      final first = await reader.read(resource, 0, MediaReader.maxRead).future;
      if (first.bytes.length >= first.resourceLength) return first.bytes;
      final whole = BytesBuilder(copy: false)..add(first.bytes);
      while (whole.length < first.resourceLength) {
        final next = await reader.read(resource, whole.length, MediaReader.maxRead).future;
        if (next.bytes.isEmpty) break;
        whole.add(next.bytes);
      }
      return whole.takeBytes();
    } on MediaReadException {
      return null;
    }
  }
}

/// A library picture, or a quiet well with an icon while it loads or when there is none.
class Artwork extends StatefulWidget {
  const Artwork({super.key, required this.link, required this.token, this.width = 342, this.icon = Icons.movie_outlined, this.radius = 14});

  final RemoteLink link;
  final String? token;

  /// The width to ask the PC for, in pixels.
  final int width;
  final IconData icon;
  final double radius;

  @override
  State<Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<Artwork> {
  Uint8List? _bytes;
  String? _for;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token || oldWidget.width != widget.width) _load();
  }

  // A picture that didn't come (the link was down, or the PC was busy or had just restarted) is asked for again a few
  // times, further apart each time.
  static const _retries = [Duration(seconds: 2), Duration(seconds: 6), Duration(seconds: 20)];
  Timer? _retry;

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _load() {
    _retry?.cancel();
    final token = widget.token;
    final key = '$token/${widget.width}';
    _for = key;
    if (token == null) {
      _bytes = null;
      return;
    }
    _bytes = ArtworkCache.instance.peek(token, widget.width);
    if (_bytes != null) return;
    _fetch(token, key, 0);
  }

  void _fetch(String token, String key, int tries) {
    unawaited(ArtworkCache.instance.load(widget.link, token, widget.width).then((bytes) {
      if (!mounted || _for != key) return;
      if (bytes != null) {
        setState(() => _bytes = bytes);
      } else if (tries < _retries.length) {
        _retry = Timer(_retries[tries], () {
          if (mounted && _for == key) _fetch(token, key, tries + 1);
        });
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: bytes == null
            ? Container(
                key: const ValueKey('empty'),
                color: Palette.well,
                alignment: Alignment.center,
                child: Icon(widget.icon, color: Palette.muted.withValues(alpha: 0.45), size: 28),
              )
            : Image.memory(
                bytes,
                key: ValueKey(_for),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Container(color: Palette.well),
              ),
      ),
    );
  }
}
