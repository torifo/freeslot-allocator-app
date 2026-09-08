/// Hybrid logical clock value: `<physicalMillis>-<counter>-<deviceId>`.
///
/// Ordering is physical, then counter, then deviceId (lexicographic). The
/// deviceId makes the order total, so two devices never produce equal clocks.
class Hlc implements Comparable<Hlc> {
  const Hlc({
    required this.physical,
    required this.counter,
    required this.deviceId,
  });

  final int physical;
  final int counter;
  final String deviceId;

  /// Sentinel used for entities migrated from schema v1 (no clock recorded).
  static const Hlc migrated = Hlc(physical: 0, counter: 0, deviceId: 'migrated');

  bool get isMigrated => physical == 0 && counter == 0 && deviceId == 'migrated';

  static Hlc parse(String value) {
    final first = value.indexOf('-');
    final second = value.indexOf('-', first + 1);
    if (first <= 0 || second <= first) {
      throw FormatException('Invalid HLC: $value');
    }
    return Hlc(
      physical: int.parse(value.substring(0, first)),
      counter: int.parse(value.substring(first + 1, second)),
      deviceId: value.substring(second + 1),
    );
  }

  static Hlc? tryParse(String? value) {
    if (value == null) return null;
    try {
      return parse(value);
    } on FormatException {
      return null;
    }
  }

  @override
  int compareTo(Hlc other) {
    if (physical != other.physical) return physical.compareTo(other.physical);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return deviceId.compareTo(other.deviceId);
  }

  @override
  String toString() => '$physical-$counter-$deviceId';

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.physical == physical &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(physical, counter, deviceId);
}

/// Issues monotonically increasing [Hlc] values for one device.
class HlcClock {
  HlcClock({required this.deviceId, int Function()? now, Hlc? last})
      : _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _lastPhysical = last?.physical ?? 0,
        _lastCounter = last?.counter ?? 0;

  final String deviceId;
  final int Function() _now;
  int _lastPhysical;
  int _lastCounter;

  Hlc get last => Hlc(physical: _lastPhysical, counter: _lastCounter, deviceId: deviceId);

  Hlc next() {
    final wall = _now();
    if (wall > _lastPhysical) {
      _lastPhysical = wall;
      _lastCounter = 0;
    } else {
      _lastCounter += 1;
    }
    return last;
  }

  /// Folds a clock received from another device into this clock so that the
  /// next issued value is strictly greater than anything seen so far.
  void observe(Hlc remote) {
    if (remote.physical > _lastPhysical) {
      _lastPhysical = remote.physical;
      _lastCounter = remote.counter;
    } else if (remote.physical == _lastPhysical && remote.counter > _lastCounter) {
      _lastCounter = remote.counter;
    }
  }
}
