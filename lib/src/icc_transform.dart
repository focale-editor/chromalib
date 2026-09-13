import 'dart:typed_data';

import 'package:chromalib/src/backend/backend.dart' as backend;
import 'package:chromalib/src/backend/transform_backend.dart';
import 'package:chromalib/src/model/icc_pixel_format.dart';
import 'package:chromalib/src/model/icc_profile.dart';
import 'package:chromalib/src/model/icc_transform_options.dart';

/// A reusable conversion between two profiles and pixel layouts.
///
/// Identical profiles use an exact layout conversion; other pairs compile a
/// Little CMS colour pipeline. Call [close] when the transform is no longer
/// needed. Native platforms also retain a finalizer as a safety net for
/// abandoned instances.
final class IccTransform {
  /// Source profile interpreted by this transform.
  final IccProfile sourceProfile;

  /// Interleaved source pixel representation.
  final IccPixelFormat sourceFormat;

  /// Destination profile produced by this transform.
  final IccProfile destinationProfile;

  /// Interleaved destination pixel representation.
  final IccPixelFormat destinationFormat;

  /// Rendering options compiled into this transform.
  final IccTransformOptions options;

  /// Platform resource that owns the compiled transform.
  final TransformBackend _backend;

  /// Whether [close] has released the platform resource.
  bool _closed = false;

  /// Creates a reusable colour or exact layout transform.
  factory IccTransform({
    required IccProfile sourceProfile,
    required IccPixelFormat sourceFormat,
    required IccProfile destinationProfile,
    required IccPixelFormat destinationFormat,
    IccTransformOptions options = const IccTransformOptions(),
  }) {
    if (sourceProfile.colorSpace != sourceFormat.colorSpace) {
      throw ArgumentError.value(
        sourceFormat,
        'sourceFormat',
        'The pixel colour space must match the source profile.',
      );
    }
    if (destinationProfile.colorSpace != destinationFormat.colorSpace) {
      throw ArgumentError.value(
        destinationFormat,
        'destinationFormat',
        'The pixel colour space must match the destination profile.',
      );
    }
    if (sourceFormat.hasAlpha != destinationFormat.hasAlpha) {
      throw ArgumentError(
        'Source and destination formats must either both contain alpha or both omit it.',
      );
    }
    return IccTransform._(
      sourceProfile: sourceProfile,
      sourceFormat: sourceFormat,
      destinationProfile: destinationProfile,
      destinationFormat: destinationFormat,
      options: options,
      backend: backend.createTransformBackend(
        sourceProfile: sourceProfile,
        sourceFormat: sourceFormat,
        destinationProfile: destinationProfile,
        destinationFormat: destinationFormat,
        options: options,
      ),
    );
  }

  /// Stores one successfully compiled platform transform.
  IccTransform._({
    required this.sourceProfile,
    required this.sourceFormat,
    required this.destinationProfile,
    required this.destinationFormat,
    required this.options,
    required this._backend,
  });

  /// Converts every complete pixel from [input] into a new owned buffer.
  Uint8List convert(Uint8List input) {
    _checkInput(input);
    final Uint8List output = Uint8List(_outputLengthFor(input));
    if (output.isNotEmpty) {
      _backend.convertInto(input, output);
    }
    return output;
  }

  /// Converts every complete pixel from [input] into the caller-owned [output].
  ///
  /// [output] must hold exactly the destination bytes for the input pixels and
  /// must not share memory with [input]. Reusing one output buffer avoids an
  /// allocation for every converted frame, tile, or row.
  void convertInto(Uint8List input, Uint8List output) {
    _checkInput(input);
    final int outputLength = _outputLengthFor(input);
    if (output.lengthInBytes != outputLength) {
      throw ArgumentError.value(
        output.lengthInBytes,
        'output',
        'The output must contain exactly $outputLength bytes for the input pixels.',
      );
    }
    if (_overlaps(input, output)) {
      throw ArgumentError.value(
        output,
        'output',
        'The output buffer must not overlap the input buffer.',
      );
    }
    if (outputLength != 0) {
      _backend.convertInto(input, output);
    }
  }

  /// Releases the compiled transform.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _backend.close();
  }

  /// Rejects use after [close] and inputs with a partial trailing pixel.
  void _checkInput(Uint8List input) {
    if (_closed) {
      throw StateError('The ICC transform is closed.');
    }
    if (input.lengthInBytes % sourceFormat.bytesPerPixel != 0) {
      throw ArgumentError.value(
        input.lengthInBytes,
        'input',
        'The input does not contain complete source pixels.',
      );
    }
  }

  /// Destination bytes required by the complete pixels in [input].
  int _outputLengthFor(Uint8List input) => input.lengthInBytes ~/ sourceFormat.bytesPerPixel * destinationFormat.bytesPerPixel;

  /// Whether two views address overlapping bytes of the same buffer.
  static bool _overlaps(Uint8List first, Uint8List second) =>
      first.buffer == second.buffer && first.offsetInBytes < second.offsetInBytes + second.lengthInBytes && second.offsetInBytes < first.offsetInBytes + first.lengthInBytes;
}

/// Converts one buffer with a transform that is released before returning.
Uint8List transformPixels(
  Uint8List input, {
  required IccProfile sourceProfile,
  required IccPixelFormat sourceFormat,
  required IccProfile destinationProfile,
  required IccPixelFormat destinationFormat,
  IccTransformOptions options = const IccTransformOptions(),
}) {
  final IccTransform transform = IccTransform(
    sourceProfile: sourceProfile,
    sourceFormat: sourceFormat,
    destinationProfile: destinationProfile,
    destinationFormat: destinationFormat,
    options: options,
  );
  try {
    return transform.convert(input);
  } finally {
    transform.close();
  }
}
