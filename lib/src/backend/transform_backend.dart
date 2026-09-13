import 'dart:typed_data';

/// Platform implementation retained by one public transform.
abstract interface class TransformBackend {
  /// Converts every pixel from [input] into [output].
  ///
  /// The caller has already validated that [input] holds complete, non-empty
  /// source pixels, that [output] has exactly the matching destination size,
  /// and that both buffers are distinct.
  void convertInto(Uint8List input, Uint8List output);

  /// Releases native resources retained by this transform.
  void close();
}
