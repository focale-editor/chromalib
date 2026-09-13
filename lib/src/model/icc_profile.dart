import 'dart:typed_data';

import 'package:chromalib/src/model/icc_exception.dart';
import 'package:chromalib/src/model/icc_pixel_format.dart';

/// Identifies profiles that Little CMS can construct without external bytes.
enum IccBuiltInProfile {
  /// IEC 61966-2-1 sRGB.
  srgb(colorSpace: IccColorSpace.rgb),

  /// Adobe RGB (1998).
  adobeRgb1998(colorSpace: IccColorSpace.rgb),

  /// ROMM RGB, commonly called ProPhoto RGB.
  proPhotoRgb(colorSpace: IccColorSpace.rgb),

  /// CIE XYZ relative to the D50 profile connection-space illuminant.
  xyzD50(colorSpace: IccColorSpace.xyz),

  /// CIE L*a*b* relative to the D50 profile connection-space illuminant.
  labD50(colorSpace: IccColorSpace.lab),

  /// D50 grayscale encoded with a 2.2 power-law transfer curve.
  grayGamma22(colorSpace: IccColorSpace.gray);

  /// Process colour space represented by this profile.
  final IccColorSpace colorSpace;

  /// Creates a built-in profile description.
  const IccBuiltInProfile({required this.colorSpace});
}

/// Immutable source or destination profile used by a colour transform.
final class IccProfile {
  /// Largest embedded profile accepted by the public API.
  static const int maximumBytes = 16 * 1024 * 1024;

  /// Standard IEC 61966-2-1 display profile.
  static const IccProfile srgb = IccProfile._builtIn(
    IccBuiltInProfile.srgb,
    IccColorSpace.rgb,
  );

  /// Standard Adobe RGB (1998) working profile.
  static const IccProfile adobeRgb1998 = IccProfile._builtIn(
    IccBuiltInProfile.adobeRgb1998,
    IccColorSpace.rgb,
  );

  /// Standard ROMM RGB working profile.
  static const IccProfile proPhotoRgb = IccProfile._builtIn(
    IccBuiltInProfile.proPhotoRgb,
    IccColorSpace.rgb,
  );

  /// D50 XYZ profile connection space.
  static const IccProfile xyzD50 = IccProfile._builtIn(
    IccBuiltInProfile.xyzD50,
    IccColorSpace.xyz,
  );

  /// D50 Lab profile connection space.
  static const IccProfile labD50 = IccProfile._builtIn(
    IccBuiltInProfile.labD50,
    IccColorSpace.lab,
  );

  /// D50 grayscale profile encoded with a 2.2 power-law transfer curve.
  static const IccProfile grayGamma22 = IccProfile._builtIn(
    IccBuiltInProfile.grayGamma22,
    IccColorSpace.gray,
  );

  /// Built-in profile kind, or `null` for an embedded payload.
  final IccBuiltInProfile? builtIn;

  /// Owned ICC payload, or `null` for a built-in profile.
  final Uint8List? bytes;

  /// Process colour space declared by the profile.
  final IccColorSpace colorSpace;

  /// Creates one built-in profile.
  const IccProfile._builtIn(this.builtIn, this.colorSpace) : bytes = null;

  /// Creates an immutable profile from one complete ICC payload.
  factory IccProfile.fromBytes(Uint8List bytes) {
    if (bytes.lengthInBytes < 128) {
      throw const IccException('An ICC profile must contain a 128-byte header.');
    }
    if (bytes.lengthInBytes > maximumBytes) {
      throw const IccException(
        'The ICC profile exceeds the $maximumBytes-byte limit.',
      );
    }
    final ByteData header = ByteData.sublistView(bytes, 0, 128);
    final int declaredLength = header.getUint32(0, Endian.big);
    if (declaredLength < 128 || declaredLength > bytes.lengthInBytes) {
      throw const IccException('The ICC profile declares an invalid byte length.');
    }
    if (_signature(bytes, 36) != 'acsp') {
      throw const IccException('The ICC profile signature is missing.');
    }
    final IccColorSpace colorSpace = switch (_signature(bytes, 16)) {
      'GRAY' => IccColorSpace.gray,
      'RGB ' => IccColorSpace.rgb,
      'CMYK' => IccColorSpace.cmyk,
      'Lab ' => IccColorSpace.lab,
      'XYZ ' => IccColorSpace.xyz,
      final String signature => throw IccException('Unsupported ICC colour space "$signature".'),
    };
    // `sublist` always copies, so the profile owns its payload.
    return IccProfile._embedded(
      bytes.sublist(0, declaredLength).asUnmodifiableView(),
      colorSpace,
    );
  }

  /// Stores one validated payload.
  IccProfile._embedded(this.bytes, this.colorSpace) : builtIn = null;

  /// Whether this profile owns serialized ICC bytes.
  bool get isEmbedded => builtIn == null;

  /// Reads one four-byte ICC signature.
  static String _signature(Uint8List bytes, int offset) => String.fromCharCodes(
    bytes,
    offset,
    offset + 4,
  );
}
