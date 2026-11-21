import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_update.dart';

/// Releases come from the public GitHub repository; MainActivity hands the APK to Android's installer. Android installs
/// it only if it is signed with the same key as this app, so a changed file can't replace the app.
class AndroidUpdatePlatform implements UpdatePlatform {
  AndroidUpdatePlatform({required this.appVersion});
  final String appVersion;

  static const _channel = MethodChannel('blackpearl/updates');
  static final _latest = Uri.parse('https://api.github.com/repos/Svovoniks/BlackPearlMobile/releases/latest');

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'BlackPearlMobile/$appVersion';

  @override
  Future<Object?> latestRelease() async {
    final client = _client();
    try {
      final request = await client.getUrl(_latest).timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw HttpException('GitHub answered ${response.statusCode}', uri: _latest);
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> download(Uri url, String path, void Function(int received) progress) async {
    final client = _client();
    final part = File('$path.part');
    IOSink? sink;
    try {
      // GitHub redirects the download to its file storage; HttpClient follows that.
      final request = await client.getUrl(url).timeout(const Duration(seconds: 30));
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw HttpException('The download answered ${response.statusCode}', uri: url);
      sink = part.openWrite();
      var received = 0;
      // A stalled download fails instead of hanging.
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        progress(received);
      }
      await sink.close();
      sink = null;
      await part.rename(path);
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String> updateFolder() async => (await _channel.invokeMethod<String>('updateFolder'))!;

  @override
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<void> allowInstalls() => _channel.invokeMethod<void>('allowInstalls');

  @override
  Future<void> install(String path) => _channel.invokeMethod<void>('install', {'path': path});
}
