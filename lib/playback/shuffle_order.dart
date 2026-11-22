import 'dart:math';

/// Shuffle, as on the PC (BlackPearl's ShuffleOrder): every video in a list (a show's episodes or a queue) plays once,
/// in a random order, before any plays again. Previous walks back through what actually played, and Next then
/// retraces the same path. The pick for Next is kept until it plays or stops being possible, so the up-next card and
/// the Next button agree on it.
class ShuffleOrder {
  ShuffleOrder([Random? random]) : _random = random ?? Random();

  static const _maxHistory = 4000;
  final Random _random;
  // What played, in order, and where the playing video is in it.
  final List<String> _history = [];
  int _position = -1;
  // Where this round began: from here on, the history holds what this round has played.
  int _roundStart = 0;
  String? _scope;
  String? _upcoming;
  // The pick starts a new round (Loop all after every video played).
  bool _upcomingStartsRound = false;
  // The video the player is going back to with Previous: playing it is a step back, not a new pick of a video that
  // already played. Only [goingBack] sets it; asking [previous], as the player does to enable its button, doesn't.
  String? _goingBack;

  /// The list the order belongs to: a show or a queue.
  String? get scope => _scope;

  void reset() {
    _history.clear();
    _position = -1;
    _roundStart = 0;
    _scope = null;
    _upcoming = null;
    _upcomingStartsRound = false;
    _goingBack = null;
  }

  /// Records that [id] plays now, in the list [scope]. Another list starts a new order.
  void played(String scope, String id) {
    if (_scope != scope) {
      reset();
      _scope = scope;
    }
    if (_position >= 0 && _history[_position] == id) return;
    final back = _goingBack == id && _position > 0 && _history[_position - 1] == id;
    _goingBack = null;
    if (back) {
      _position--;
    } else if (_position + 1 < _history.length && _history[_position + 1] == id) {
      _position++;
    } else {
      // A video chosen any other way starts a new path from here.
      _history.removeRange(_position + 1, _history.length);
      _history.add(id);
      _position = _history.length - 1;
      if (_upcomingStartsRound && _upcoming == id) _roundStart = _position;
    }
    if (_upcoming == id) {
      _upcoming = null;
      _upcomingStartsRound = false;
    }
    if (_history.length > _maxHistory) {
      final drop = _history.length - _maxHistory;
      _history.removeRange(0, drop);
      _position -= drop;
      _roundStart = max(0, _roundStart - drop);
    }
  }

  /// The video to play after [current], from [pool]: one this round hasn't played, or, once every video has played,
  /// null; with [loop] a new round starts instead.
  String? next(String scope, String current, List<String> pool, {required bool loop, bool Function(String id)? canPlay}) {
    final can = canPlay ?? (_) => true;
    played(scope, current);
    final members = pool.toSet();
    // After Previous, Next goes forward along the path that played.
    while (_position + 1 < _history.length) {
      final ahead = _history[_position + 1];
      if (members.contains(ahead) && can(ahead)) return ahead;
      _history.removeAt(_position + 1);
    }
    final kept = _upcoming;
    if (kept != null && kept != current && members.contains(kept) && (loop || !_upcomingStartsRound) && can(kept)) return kept;
    _upcoming = null;
    _upcomingStartsRound = false;
    final playedThisRound = _history.skip(_roundStart).toSet();
    final pick = _pick(members.where((id) => !playedThisRound.contains(id)).toList(), can);
    if (pick != null) return _upcoming = pick;
    if (!loop) return null;
    // Every video has played: a new round, which doesn't start with the video that just ended.
    _upcoming = _pick(members.where((id) => id != current).toList(), can);
    _upcomingStartsRound = _upcoming != null;
    return _upcoming;
  }

  /// The video that played before [current], skipping any that can't play now.
  String? previous(String scope, String current, List<String> pool, {bool Function(String id)? canPlay}) {
    final can = canPlay ?? (_) => true;
    played(scope, current);
    final members = pool.toSet();
    // Videos that can't play now leave the path, so the one returned is the step back that [played] recognises.
    while (_position > 0) {
      final behind = _history[_position - 1];
      if (members.contains(behind) && can(behind)) return behind;
      _history.removeAt(_position - 1);
      _position--;
      if (_roundStart > _position) _roundStart = _position;
    }
    return null;
  }

  /// The player is about to play [id], which [previous] offered: it plays as a step back. Null: it didn't, after all.
  void goingBack(String? id) => _goingBack = id;

  String? _pick(List<String> candidates, bool Function(String id) canPlay) {
    // Shuffled in full, then checked in that order.
    candidates.shuffle(_random);
    for (final id in candidates) {
      if (canPlay(id)) return id;
    }
    return null;
  }
}
