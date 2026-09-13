/// Identifies the process components stored in one pixel.
enum IccColorSpace {
  /// One luminance component.
  gray(channelCount: 1),

  /// Red, green, and blue components.
  rgb(channelCount: 3),

  /// Cyan, magenta, yellow, and black components.
  cmyk(channelCount: 4),

  /// CIE L*, a*, and b* components.
  lab(channelCount: 3),

  /// CIE XYZ components relative to D50.
  xyz(channelCount: 3);

  /// Number of colour components, excluding alpha.
  final int channelCount;

  /// Creates a colour-space description.
  const IccColorSpace({required this.channelCount});
}

/// Identifies the scalar representation of each component.
enum IccSampleType {
  /// Unsigned normalized 8-bit integers.
  uint8(bytesPerSample: 1),

  /// Unsigned normalized little-endian 16-bit integers.
  uint16(bytesPerSample: 2),

  /// IEEE-754 little-endian 32-bit floats.
  float32(bytesPerSample: 4),

  /// IEEE-754 little-endian 64-bit float storage.
  ///
  /// Little CMS evaluates floating colour pipelines at single precision. This
  /// representation avoids changing the caller's buffer layout, but does not
  /// increase the engine's calculation precision.
  float64(bytesPerSample: 8);

  /// Bytes occupied by one component.
  final int bytesPerSample;

  /// Creates a sample representation.
  const IccSampleType({required this.bytesPerSample});
}

/// Describes one interleaved pixel buffer passed to Little CMS.
final class IccPixelFormat {
  /// Premultiplied 8-bit RGBA pixels used by common display buffers.
  static const IccPixelFormat premultipliedRgba8 = IccPixelFormat(
    colorSpace: IccColorSpace.rgb,
    sampleType: IccSampleType.uint8,
    hasAlpha: true,
    premultipliedAlpha: true,
  );

  /// Straight 8-bit RGBA pixels.
  static const IccPixelFormat rgba8 = IccPixelFormat(
    colorSpace: IccColorSpace.rgb,
    sampleType: IccSampleType.uint8,
    hasAlpha: true,
  );

  /// Premultiplied 16-bit RGBA pixels.
  static const IccPixelFormat premultipliedRgba16 = IccPixelFormat(
    colorSpace: IccColorSpace.rgb,
    sampleType: IccSampleType.uint16,
    hasAlpha: true,
    premultipliedAlpha: true,
  );

  /// Premultiplied floating-point RGBA pixels.
  static const IccPixelFormat premultipliedRgbaFloat32 = IccPixelFormat(
    colorSpace: IccColorSpace.rgb,
    sampleType: IccSampleType.float32,
    hasAlpha: true,
    premultipliedAlpha: true,
  );

  /// Premultiplied 8-bit CMYKA pixels.
  static const IccPixelFormat premultipliedCmyka8 = IccPixelFormat(
    colorSpace: IccColorSpace.cmyk,
    sampleType: IccSampleType.uint8,
    hasAlpha: true,
    premultipliedAlpha: true,
  );

  /// Premultiplied 16-bit CMYKA pixels.
  static const IccPixelFormat premultipliedCmyka16 = IccPixelFormat(
    colorSpace: IccColorSpace.cmyk,
    sampleType: IccSampleType.uint16,
    hasAlpha: true,
    premultipliedAlpha: true,
  );

  /// Premultiplied floating-point CMYKA pixels.
  static const IccPixelFormat premultipliedCmykaFloat32 = IccPixelFormat(
    colorSpace: IccColorSpace.cmyk,
    sampleType: IccSampleType.float32,
    hasAlpha: true,
    premultipliedAlpha: true,
  );

  /// Three little-endian 64-bit RGB components without alpha.
  static const IccPixelFormat rgbFloat64 = IccPixelFormat(
    colorSpace: IccColorSpace.rgb,
    sampleType: IccSampleType.float64,
  );

  /// Four little-endian 64-bit CMYK components without alpha.
  static const IccPixelFormat cmykFloat64 = IccPixelFormat(
    colorSpace: IccColorSpace.cmyk,
    sampleType: IccSampleType.float64,
  );

  /// Three little-endian 64-bit D50 XYZ components without alpha.
  static const IccPixelFormat xyzFloat64 = IccPixelFormat(
    colorSpace: IccColorSpace.xyz,
    sampleType: IccSampleType.float64,
  );

  /// Colour components stored by each pixel.
  final IccColorSpace colorSpace;

  /// Scalar representation used by every component.
  final IccSampleType sampleType;

  /// Whether one trailing alpha component follows the colour components.
  final bool hasAlpha;

  /// Whether colour components have already been multiplied by alpha.
  final bool premultipliedAlpha;

  /// Creates an interleaved pixel format.
  const IccPixelFormat({
    required this.colorSpace,
    required this.sampleType,
    this.hasAlpha = false,
    this.premultipliedAlpha = false,
  }) : assert(hasAlpha || !premultipliedAlpha, 'Premultiplication requires an alpha component');

  /// Total components stored by one pixel.
  int get channelCount => colorSpace.channelCount + (hasAlpha ? 1 : 0);

  /// Number of bytes occupied by one pixel.
  int get bytesPerPixel => channelCount * sampleType.bytesPerSample;
}
