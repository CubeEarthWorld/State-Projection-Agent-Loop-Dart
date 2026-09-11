/// Embedding backend abstraction (swappable).
///
/// The core never requires vectors: with no backend, discovery degrades to
/// lexical matching (BM25) and every capability stays reachable. The only
/// concrete implementation shipped here is [HashingEmbedding] —
/// dependency-free and deterministic, calls no external model or API. Any
/// real embedding model is the integrator's own adapter, implementing this
/// same two-method interface. The package intentionally does not bundle or
/// depend on any LLM/embedding provider SDK.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

typedef Vector = List<double>;

abstract interface class EmbeddingBackend {
  List<Vector> embedDocuments(List<String> texts);

  Vector embedQuery(String text);
}

double cosine(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty) return 0.0;
  var dot = 0.0;
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    dot += a[i] * b[i];
  }
  var na = 0.0;
  for (final x in a) {
    na += x * x;
  }
  var nb = 0.0;
  for (final x in b) {
    nb += x * x;
  }
  na = math.sqrt(na);
  nb = math.sqrt(nb);
  if (na == 0 || nb == 0) return 0.0;
  return dot / (na * nb);
}

/// Deterministic char-trigram hashing embedding. No dependencies, no
/// network calls, no model weights.
///
/// Not semantically smart, but stable, fast, and shares surface-form
/// overlap, which is enough for tests and lightweight deployments.
class HashingEmbedding implements EmbeddingBackend {
  HashingEmbedding({this.dim = 256});

  final int dim;

  Vector _embed(String text) {
    final vec = List<double>.filled(dim, 0.0);
    // Characters, not UTF-16 code units: slicing by code unit would split a
    // surrogate pair and hash a different byte sequence than the Python
    // backend does for the same text.
    final runes = text.toLowerCase().runes.toList();
    for (final n in [2, 3]) {
      for (var i = 0; i + n <= runes.length; i++) {
        final gram = String.fromCharCodes(runes.getRange(i, i + n));
        final digest = md5.convert(utf8.encode(gram)).bytes;
        // little-endian uint32 from the first 4 bytes, full 32 bits: masking
        // off the sign bit would change the bucket for any non-power-of-two
        // dim.
        final h = digest[0] |
            (digest[1] << 8) |
            (digest[2] << 16) |
            (digest[3] << 24);
        vec[h % dim] += 1.0;
      }
    }
    var norm = 0.0;
    for (final x in vec) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < vec.length; i++) {
        vec[i] = vec[i] / norm;
      }
    }
    return vec;
  }

  @override
  List<Vector> embedDocuments(List<String> texts) =>
      [for (final t in texts) _embed(t)];

  @override
  Vector embedQuery(String text) => _embed(text);
}
