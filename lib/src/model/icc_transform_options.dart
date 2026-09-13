import 'package:chromalib/src/model/icc_rendering_intent.dart';

/// Configures one compiled colour transform.
final class IccTransformOptions {
  /// Rendering intent selected for source-to-destination mapping.
  final IccRenderingIntent renderingIntent;

  /// Whether to compensate for different source and destination black points.
  final bool blackPointCompensation;

  /// Creates transform options.
  const IccTransformOptions({
    this.renderingIntent = IccRenderingIntent.relativeColorimetric,
    this.blackPointCompensation = false,
  });
}
