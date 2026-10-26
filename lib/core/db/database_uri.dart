/// A database address must have a hierarchical URI path on every platform.
/// Without the leading slash a Windows drive becomes an opaque URI in Go.
String databaseUriPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return RegExp('^[A-Za-z]:/').hasMatch(normalized) ? '/$normalized' : normalized;
}
