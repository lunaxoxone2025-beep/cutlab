/// Small typed accessors over decoded JSON that fail with a precise path,
/// so a damaged or hand-edited .cutlab file reports *where* it is broken.
library;

class ProjectFormatException implements Exception {
  final String message;
  final String path;

  const ProjectFormatException(this.message, [this.path = r'$']);

  @override
  String toString() => 'ProjectFormatException at $path: $message';
}

class JsonReader {
  final Map<String, Object?> map;
  final String path;

  JsonReader(Object? json, this.path) : map = _asMap(json, path);

  static Map<String, Object?> _asMap(Object? json, String path) {
    if (json is Map<String, Object?>) return json;
    throw ProjectFormatException('expected an object', path);
  }

  String _p(String key) => '$path.$key';

  Object? raw(String key) => map[key];

  bool has(String key) => map.containsKey(key) && map[key] != null;

  String string(String key, {String? fallback}) {
    final v = map[key];
    if (v is String) return v;
    if (v == null && fallback != null) return fallback;
    throw ProjectFormatException('expected a string', _p(key));
  }

  String? optString(String key) {
    final v = map[key];
    if (v == null || v is String) return v as String?;
    throw ProjectFormatException('expected a string', _p(key));
  }

  int integer(String key, {int? fallback, int? min}) {
    final v = map[key];
    final int result;
    if (v is int) {
      result = v;
    } else if (v is double && v == v.roundToDouble() && v.abs() < 9.0e15) {
      result = v.toInt();
    } else if (v == null && fallback != null) {
      result = fallback;
    } else {
      throw ProjectFormatException('expected an integer', _p(key));
    }
    if (min != null && result < min) {
      throw ProjectFormatException('must be >= $min (got $result)', _p(key));
    }
    return result;
  }

  int? optInteger(String key) => has(key) ? integer(key) : null;

  double number(String key, {double? fallback}) {
    final v = map[key];
    if (v is num) return v.toDouble();
    if (v == null && fallback != null) return fallback;
    throw ProjectFormatException('expected a number', _p(key));
  }

  bool boolean(String key, {bool? fallback}) {
    final v = map[key];
    if (v is bool) return v;
    if (v == null && fallback != null) return fallback;
    throw ProjectFormatException('expected true/false', _p(key));
  }

  JsonReader object(String key) => JsonReader(map[key], _p(key));

  JsonReader? optObject(String key) => has(key) ? object(key) : null;

  List<T> list<T>(String key, T Function(JsonReader item) read, {bool optional = true}) {
    final v = map[key];
    if (v == null && optional) return <T>[];
    if (v is! List<Object?>) throw ProjectFormatException('expected a list', _p(key));
    return [for (var i = 0; i < v.length; i++) read(JsonReader(v[i], '${_p(key)}[$i]'))];
  }

  Map<String, Object?> plainMap(String key) {
    final v = map[key];
    if (v == null) return <String, Object?>{};
    if (v is Map<String, Object?>) return Map<String, Object?>.of(v);
    throw ProjectFormatException('expected an object', _p(key));
  }

  T enumValue<T extends Enum>(String key, List<T> values, {T? fallback}) {
    final v = map[key];
    if (v == null && fallback != null) return fallback;
    for (final e in values) {
      if (e.name == v) return e;
    }
    throw ProjectFormatException('unknown value "$v" (allowed: ${values.map((e) => e.name).join(', ')})', _p(key));
  }
}
