import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where a PC listens for phones on its home network (PHONE-REMOTE.md, "On the home network"): a port and the PC's
/// addresses, from its `welcome`. The phone tries them when the room server can't introduce it to the PC.
@immutable
class LanEndpoints {
  const LanEndpoints({required this.port, required this.addresses});

  final int port;
  final List<String> addresses;

  /// At most this many addresses are kept, as the PC sends.
  static const maxAddresses = 8;

  /// Reads the `lan` field of a `welcome`, or a stored copy. Null for anything malformed: a port out of range, no
  /// address, or addresses that aren't IP addresses.
  static LanEndpoints? fromJson(Object? json) {
    if (json is! Map) return null;
    final port = json['port'], addresses = json['addresses'];
    if (port is! int || port < 1 || port > 65535 || addresses is! List) return null;
    final valid = addresses.whereType<String>().where((a) => a.length <= 45 && InternetAddress.tryParse(a) != null).toSet().take(maxAddresses).toList();
    if (valid.isEmpty) return null;
    return LanEndpoints(port: port, addresses: List.unmodifiable(valid));
  }

  Map<String, dynamic> toJson() => {'port': port, 'addresses': addresses};

  @override
  bool operator ==(Object other) => other is LanEndpoints && other.port == port && listEquals(other.addresses, addresses);
  @override
  int get hashCode => Object.hash(port, Object.hashAll(addresses));
}

/// A PC this phone is paired with.
class PairedPc {
  const PairedPc({required this.pcId, required this.name, required this.server, required this.phoneId, required this.secret, this.lan});

  final String pcId;
  final String name;
  final String server;
  final String phoneId;
  final String secret;

  /// Where the PC listens on its home network, as it said the last time the phone connected. Null for a PC that never
  /// said (one from before it could, or one not seen since).
  final LanEndpoints? lan;

  Map<String, dynamic> toJson() => {
    'pcId': pcId,
    'name': name,
    'server': server,
    'phoneId': phoneId,
    'secret': secret,
    if (lan != null) 'lan': lan!.toJson(),
  };

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
      lan: LanEndpoints.fromJson(json['lan']),
    );
  }

  PairedPc withName(String name) => PairedPc(pcId: pcId, name: name, server: server, phoneId: phoneId, secret: secret, lan: lan);
  PairedPc withLan(LanEndpoints? lan) => PairedPc(pcId: pcId, name: name, server: server, phoneId: phoneId, secret: secret, lan: lan);
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
