/// Reports invalid profiles, incompatible pixel formats, or failed transforms.
final class IccException implements Exception {
  /// A human-readable description of the failure.
  final String message;

  /// Creates an ICC transform failure.
  const IccException(this.message);

  @override
  String toString() => 'IccException: $message';
}
