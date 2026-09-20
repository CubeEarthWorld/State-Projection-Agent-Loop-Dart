/// Identifiers: dependency-free ULIDs with typed, human-readable prefixes.
///
/// Every entity that appears in the Event Ledger carries a prefixed ULID
/// (`ses_`, `run_`, `evt_`, `cmd_`, `apr_`, `art_`). ULIDs are
/// lexicographically sortable by creation time, which keeps ledger files and
/// directory listings naturally ordered without a separate index.
///
/// Event *order within a run* is never inferred from the ID's timestamp —
/// that's what [EventLedger] sequence numbers are for. IDs only need to be
/// unique and roughly time-ordered.
library;

import 'dart:math';

const String _crockford32 = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final Random _random = Random.secure();

final BigInt _mask80 = (BigInt.one << 80) - BigInt.one;

int _lastMs = 0;
BigInt _lastRandom = BigInt.zero;

String _encode(BigInt value, int length) {
  final chars = List<String>.filled(length, '0');
  var v = value;
  final mask = BigInt.from(0x1F);
  for (var i = length - 1; i >= 0; i--) {
    chars[i] = _crockford32[(v & mask).toInt()];
    v = v >> 5;
  }
  return chars.join();
}

/// Bits drawn per `nextInt` call.
///
/// Deliberately not 32: `1 << 32` is 2^32 on the VM but truncates to 0 when
/// compiled to JavaScript, where `int` is a double and shifts are 32-bit,
/// and `nextInt(0)` throws. 24 keeps the bound well inside the range every
/// platform computes exactly.
const int _chunkBits = 24;

BigInt _randomBits(int bits) {
  var value = BigInt.zero;
  var remaining = bits;
  while (remaining > 0) {
    final take = remaining >= _chunkBits ? _chunkBits : remaining;
    final chunk = _random.nextInt(1 << take); // exact everywhere for take <= _chunkBits
    value = (value << take) | BigInt.from(chunk);
    remaining -= take;
  }
  return value;
}

/// A 26-char Crockford-base32 ULID: 48-bit ms timestamp + 80-bit random.
///
/// Monotonic within a process: if called twice in the same millisecond the
/// random part is incremented instead of redrawn, so IDs generated back to
/// back still sort in call order.
String newUlid() {
  var ms = DateTime.now().millisecondsSinceEpoch;
  if (ms <= _lastMs) {
    ms = _lastMs;
    _lastRandom += BigInt.one;
  } else {
    _lastRandom = _randomBits(80);
  }
  _lastMs = ms;
  return _encode(BigInt.from(ms), 10) + _encode(_lastRandom & _mask80, 16);
}

const Map<String, String> _prefixes = {
  'session': 'ses',
  'run': 'run',
  'event': 'evt',
  'command': 'cmd',
  'approval': 'apr',
  'artifact': 'art',
  'question': 'qst',
  'call': 'call',
  'note': 'note',
};

/// A prefixed ULID for the given entity kind, e.g. `newId("run")`.
String newId(String kind) {
  final prefix = _prefixes[kind];
  if (prefix == null) {
    final known = (_prefixes.keys.toList()..sort()).join(', ');
    throw ArgumentError('Unknown id kind "$kind"; expected one of $known');
  }
  return '${prefix}_${newUlid()}';
}
