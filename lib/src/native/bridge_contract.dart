import 'package:chromalib/src/model/icc_pixel_format.dart';
import 'package:chromalib/src/model/icc_profile.dart';
import 'package:chromalib/src/model/icc_rendering_intent.dart';

/// ABI version expected from the native and WebAssembly bridge.
const int bridgeAbiVersion = 2;

/// Returns the stable bridge identifier for [colorSpace].
int colorSpaceBridgeValue(IccColorSpace colorSpace) => switch (colorSpace) {
  IccColorSpace.gray => 0,
  IccColorSpace.rgb => 1,
  IccColorSpace.cmyk => 2,
  IccColorSpace.lab => 3,
  IccColorSpace.xyz => 4,
};

/// Returns the stable bridge identifier for [sampleType].
int sampleTypeBridgeValue(IccSampleType sampleType) => switch (sampleType) {
  IccSampleType.uint8 => 0,
  IccSampleType.uint16 => 1,
  IccSampleType.float32 => 2,
  IccSampleType.float64 => 3,
};

/// Returns the stable bridge identifier for [profile].
int profileBridgeValue(IccProfile profile) => switch (profile.builtIn) {
  null => 0,
  IccBuiltInProfile.srgb => 1,
  IccBuiltInProfile.adobeRgb1998 => 2,
  IccBuiltInProfile.proPhotoRgb => 3,
  IccBuiltInProfile.xyzD50 => 4,
  IccBuiltInProfile.labD50 => 5,
  IccBuiltInProfile.grayGamma22 => 6,
};

/// Returns the stable bridge identifier for [intent].
int renderingIntentBridgeValue(IccRenderingIntent intent) => switch (intent) {
  IccRenderingIntent.perceptual => 0,
  IccRenderingIntent.relativeColorimetric => 1,
  IccRenderingIntent.saturation => 2,
  IccRenderingIntent.absoluteColorimetric => 3,
};
