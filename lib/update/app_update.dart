import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../diagnostics/trail.dart';

/// A newer release of the app, from GitHub.
@immutable
class AppRelease {
  const AppRelease({required this.version, required this.apk, required this.size, this.sha256});
  final String version;
  final Uri apk;
  final int size;

  /// The SHA-256 GitHub records for the APK, in lowercase hex, when it gives one.
  final String? sha256;
}

/// The release APKs' names, as the release workflow uploads them: one per Android ABI. The 64-bit ARM one, which nearly
/// every phone runs, keeps the plain name `BlackPearl-v1.2.3.apk` that releases up to 0.10.0 used for their only APK, so
/// those find it; the others are named for their ABI, as in `BlackPearl-v1.2.3-armeabi-v7a.apk`.
final _apkName = RegExp(r'^BlackPearl-v\d+(?:\.\d+)*(?:-([a-z0-9_-]+))?\.apk$');

/// The ABI of the APK with the plain name.
const plainApkAbi = 'arm64-v8a';

/// Compares two versions such as "0.1.2" (a leading "v" and anything after "+" or "-" are ignored). Null when either
/// isn't a version.
int? compareVersions(String a, String b) {
  List<int>? parse(String text) {
    final core = text.trim().replaceFirst(RegExp('^v'), '').split(RegExp('[+-]')).first;
    final parts = core.split('.').map(int.tryParse).toList();
    if (parts.isEmpty || parts.any((p) => p == null)) return null;
    return parts.cast<int>();
  }

  final x = parse(a), y = parse(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// The version in GitHub's "latest release" answer when it is a published release newer than [current], whether or not
/// its APK is there yet. Null otherwise, including for an answer that isn't a release.
String? newerVersion(Object? json, String current) {
  if (json is! Map) return null;
  final tag = json['tag_name'];
  if (tag is! String || json['draft'] == true || json['prerelease'] == true) return null;
  final version = tag.replaceFirst(RegExp('^v'), '');
  return (compareVersions(version, current) ?? 0) > 0 ? version : null;
}

/// The release in GitHub's "latest release" answer, when it is newer than [current] and has an uploaded APK for one of
/// [abis], the phone's ABIs in Android's order of preference. Null otherwise; a newer release still being uploaded is
/// null here but not for [newerVersion].
AppRelease? newerRelease(Object? json, String current, {List<String> abis = const [plainApkAbi]}) {
  final version = newerVersion(json, current);
  if (version == null) return null;
  final assets = (json as Map)['assets'];
  if (assets is! List) return null;
  final byAbi = <String, AppRelease>{};
  for (final asset in assets) {
    final match = asset is Map && asset['name'] is String ? _apkName.firstMatch(asset['name'] as String) : null;
    if (match == null) continue;
    final url = Uri.tryParse((asset as Map)['browser_download_url'] as String? ?? '');
    final size = asset['size'];
    if (url == null || url.scheme != 'https' || size is! int || size <= 0) continue;
    if (asset['state'] != null && asset['state'] != 'uploaded') continue;
    final digest = asset['digest'];
    final sha = digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null;
    byAbi.putIfAbsent(match[1] ?? plainApkAbi, () => AppRelease(version: version, apk: url, size: size, sha256: sha));
  }
  for (final abi in abis) {
    if (byAbi[abi] case final release?) return release;
  }
  return null;
}

/// What the update check needs from the phone and the network. [AndroidUpdatePlatform] is the real one.
abstract class UpdatePlatform {
  /// GitHub's answer about the latest release, decoded from JSON.
  Future<Object?> latestRelease();

  /// Downloads [url] to [path], reporting the bytes received so far.
  Future<void> download(Uri url, String path, void Function(int received) progress);

  /// The folder downloads go in. Only files there can be handed to the installer.
  Future<String> updateFolder();

  /// Whether Android lets this app install updates. Android 8 and later ask once per app.
  Future<bool> canInstall();

  /// Opens the system setting that lets this app install updates.
  Future<void> allowInstalls();

  /// Hands the downloaded APK to Android's installer, which asks the user to confirm.
  Future<void> install(String path);
}

enum UpdatePhase {
  /// Nothing newer, or not checked yet.
  none,
  available,

  /// Waiting for the user to let this app install updates in the system settings.
  needsPermission,
  downloading,

  /// Downloaded and handed to the installer; tapping Install shows its prompt again.
  ready,
  failed,
}

/// Looks for a newer release on GitHub, and downloads and installs it when asked.
class AppUpdater extends ChangeNotifier {
  AppUpdater({required this.platform, required this.currentVersion, this.abis = const [plainApkAbi]});

  final UpdatePlatform platform;
  final String currentVersion;

  /// The phone's ABIs, most preferred first (Android's `Build.SUPPORTED_ABIS`), which pick the release's APK.
  final List<String> abis;

  /// How long an automatic check counts as fresh. Opening the app or coming back to it checks again after that.
  static const checkEvery = Duration(hours: 6);

  /// After a failed check (offline, or GitHub's limit of 60 requests an hour), the next automatic one waits this long.
  static const retryAfterFailure = Duration(minutes: 30);

  UpdatePhase _phase = UpdatePhase.none;
  UpdatePhase get phase => _phase;
  AppRelease? _release;
  AppRelease? get release => _release;

  /// The share of the download received, 0 to 1.
  double _progress = 0;
  double get progress => _progress;
  String? _error;
  String? get error => _error;

  /// The banner was closed. It comes back for a newer release, a manual check, or the next start of the app.
  bool _dismissed = false;
  bool get showBanner => _phase != UpdatePhase.none && !_dismissed;

  bool _checking = false;
  bool get checking => _checking;
  DateTime? _nextCheck;

  /// Set from the first moment of [update] to its end, so a second tap, or a return to the app, can't start another
  /// one, and a check that answers meanwhile leaves it alone.
  bool _updating = false;
  String? _downloaded;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Clears what earlier updates left behind, then checks.
  Future<void> start() async {
    try {
      final folder = Directory(await platform.updateFolder());
      if (await folder.exists()) {
        await for (final file in folder.list()) {
          try {
            await file.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    await check();
  }

  String get _downloadingMessage => 'Downloading BlackPearl Mobile ${_release?.version ?? ''}…';

  /// Checks GitHub for a newer release. An automatic check is skipped while the last one is fresh and fails quietly.
  /// A [manual] one always runs and returns what to tell the user.
  Future<String?> check({bool manual = false}) async {
    if (_updating || _phase == UpdatePhase.downloading) return manual ? _downloadingMessage : null;
    if (_checking) return null;
    if (!manual && _nextCheck != null && clock.now().isBefore(_nextCheck!)) return null;
    _checking = true;
    _changed();
    try {
      final json = await platform.latestRelease();
      _nextCheck = clock.now().add(checkEvery);
      // An update started while GitHub was answering; this answer mustn't change what it is installing.
      if (_updating) return manual ? _downloadingMessage : null;
      final found = newerRelease(json, currentVersion, abis: abis);
      if (found == null) {
        final publishing = newerVersion(json, currentVersion);
        // A release whose APK is still uploading: keep what the banner offers, say so, and look again soon.
        if (publishing != null) {
          _nextCheck = clock.now().add(retryAfterFailure);
          return 'BlackPearl Mobile $publishing is being published. Try again in a few minutes.';
        }
        if (_phase != UpdatePhase.ready) {
          _phase = UpdatePhase.none;
          _release = null;
        }
        return 'BlackPearl Mobile $currentVersion is the latest version.';
      }
      final newer = _release == null || (compareVersions(found.version, _release!.version) ?? 0) > 0;
      if (newer) {
        _release = found;
        _phase = UpdatePhase.available;
        _downloaded = null;
        _error = null;
        _dismissed = false;
      }
      if (manual) _dismissed = false;
      if (newer) Trail.note('update', 'found a newer version', {'version': found.version});
      return 'BlackPearl Mobile ${found.version} is available.';
    } catch (_) {
      Trail.note('update', 'check failed', {'manual': manual});
      _nextCheck = clock.now().add(retryAfterFailure);
      return "Couldn't check for updates. Check the connection and try again.";
    } finally {
      _checking = false;
      _changed();
    }
  }

  /// Downloads the new release and opens Android's installer. Asks for the permission to install first if needed.
  Future<void> update() async {
    final release = _release;
    if (release == null || _updating) return;
    _updating = true;
    try {
      await _update(release);
    } finally {
      _updating = false;
    }
  }

  Future<void> _update(AppRelease release) async {
    Trail.note('update', 'update', {'version': release.version});
    try {
      if (!await platform.canInstall()) {
        Trail.note('update', 'asking to allow installs');
        _phase = UpdatePhase.needsPermission;
        _changed();
        await platform.allowInstalls();
        return;
      }
    } catch (_) {
      _fail("Couldn't open Android's settings. Allow BlackPearl to install apps there, then try again.", why: 'settings');
      return;
    }
    if (_downloaded != null && await File(_downloaded!).exists()) return _install();
    Trail.note('update', 'downloading', {'bytes': release.size, 'checksum': release.sha256 != null});
    _phase = UpdatePhase.downloading;
    _progress = 0;
    _error = null;
    _changed();
    String? path;
    try {
      path = '${await platform.updateFolder()}${Platform.pathSeparator}BlackPearl-v${release.version}.apk';
      await platform.download(release.apk, path, (received) {
        final next = (received / release.size).clamp(0.0, 1.0);
        // Redraw in steps of a percent, not for every packet.
        if ((next * 100).floor() != (_progress * 100).floor()) {
          _progress = next;
          _changed();
        }
      });
      // Catches a damaged or cut-short download. A changed file would also have to be signed with the app's key, which
      // Android checks before it installs anything.
      final file = File(path);
      final length = await file.length();
      if (length != release.size ||
          (release.sha256 != null && (await sha256.bind(file.openRead()).first).toString() != release.sha256)) {
        await _deleteQuietly(path);
        _fail('The download was damaged. Try again.', why: length != release.size ? 'download-short' : 'download-checksum', data: {'bytes': length});
        return;
      }
    } catch (e) {
      if (path != null) await _deleteQuietly(path);
      final full = _outOfSpace(e);
      _fail(
        full
            ? 'This phone is out of storage space. The update needs about ${(release.size / 1e6).ceil()} MB.'
            : "The download didn't finish. Check the connection and try again.",
        // Only the kind of error: its text can hold the phone's folders.
        why: full ? 'out-of-space' : 'download-failed',
        data: {'error': e.runtimeType.toString(), 'progress': (_progress * 100).round()},
      );
      return;
    }
    _downloaded = path;
    _progress = 1;
    await _install();
  }

  /// ENOSPC, as Android reports a full disk.
  static bool _outOfSpace(Object error) => error is FileSystemException && error.osError?.errorCode == 28;

  Future<void> _install() async {
    _phase = UpdatePhase.ready;
    _changed();
    Trail.note('update', "opening Android's installer");
    try {
      await platform.install(_downloaded!);
    } catch (e) {
      _fail("Android's installer didn't open. Try again.", why: 'installer', data: {'error': e.runtimeType.toString()});
    }
  }

  /// The app is back in front. Coming back from the settings page with installs allowed carries on with the update;
  /// otherwise it checks again once the last check is stale.
  Future<void> resumed() async {
    if (_phase == UpdatePhase.needsPermission && !_dismissed && !_updating) {
      var allowed = false;
      try {
        allowed = await platform.canInstall();
      } catch (_) {}
      if (allowed) return update();
    }
    await check();
  }

  /// For debug previews: shows the banner in [phase] without GitHub or a download.
  void debugShow(UpdatePhase phase, {required AppRelease release, double progress = 0, String? error}) {
    _phase = phase;
    _release = release;
    _progress = progress;
    _error = error;
    _dismissed = false;
    _changed();
  }

  /// Closes the banner. An update waiting for the install permission goes back to being offered, so allowing installs
  /// later doesn't start one unasked.
  void dismiss() {
    _dismissed = true;
    if (_phase == UpdatePhase.needsPermission) _phase = UpdatePhase.available;
    _changed();
  }

  /// [why] is a fixed code for the app's log; a full phone isn't reported as a problem, as it says nothing about the app.
  void _fail(String message, {required String why, Map<String, Object>? data}) {
    Trail.note('update', 'failed', {'why': why, ...?data});
    if (why != 'out-of-space') Trail.problem('update', why, data);
    _phase = UpdatePhase.failed;
    _error = message;
    _changed();
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
