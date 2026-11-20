import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// Keeps values in memory: nothing is written to disk on Windows development builds.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  static void registerWith() => FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();

  final Map<String, String> _values = {};

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => _values.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => _values.remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => _values.clear();
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => _values[key];
  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(_values);
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async => _values[key] = value;
}
