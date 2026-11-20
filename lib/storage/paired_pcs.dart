import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A PC this phone is paired with.
class PairedPc {
  const PairedPc({required this.pcId, required this.name, required this.server, required this.phoneId, required this.secret});

  final String pcId;
  final String name;
  final String server;
  final String phoneId;
  final String secret;

  Map<String, dynamic> toJson() => {'pcId': pcId, 'name': name, 'server': server, 'phoneId': phoneId, 'secret': secret};

  static PairedPc? fromJson(Object? json) {
    if (json is! Map) return null;
    final pcId = json['pcId'], name = json['name'], server = json['server'], phoneId = json['phoneId'], secret = json['secret'];
    if (pcId is! String || server is! String || phoneId is! String || secret is! String) return null;
    return PairedPc(
      pcId: pcId,
      name: name is String && name.isNotEmpty ? name : 'BlackPearl PC',
      server: server,
      phoneId: phoneId,
      secret: secret,
    );
  }

  PairedPc withName(String name) => PairedPc(pcId: pcId, name: name, server: server, phoneId: phoneId, secret: secret);
}

/// Where paired PCs are kept. The real one is the platform's secure storage.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore() : _storage = const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class PairedPcStore {
  PairedPcStore(this._store);
  final SecretStore _store;

  static const _pcsKey = 'paired_pcs_v1';
  static const _lastKey = 'last_pc_v1';

  Future<List<PairedPc>> load() async {
    final text = await _store.read(_pcsKey);
    if (text == null || text.isEmpty) return [];
    try {
      final list = jsonDecode(text);
      if (list is! List) return [];
      return list.map(PairedPc.fromJson).whereType<PairedPc>().toList();
    } on FormatException {
      return [];
    }
  }

  Future<void> save(List<PairedPc> pcs) => _store.write(_pcsKey, jsonEncode(pcs.map((pc) => pc.toJson()).toList()));

  Future<String?> lastUsed() => _store.read(_lastKey);
  Future<void> setLastUsed(String? pcId) => pcId == null ? _store.delete(_lastKey) : _store.write(_lastKey, pcId);
}
