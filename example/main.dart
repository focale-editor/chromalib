import 'dart:typed_data';

import 'package:chromalib/chromalib.dart';

/// Converts premultiplied display pixels with one reusable ICC transform.
Future<void> main() async {
  await ChromaLib.initialize();
  final Uint8List source = Uint8List.fromList([
    255,
    96,
    32,
    255,
    64,
    32,
    16,
    128,
  ]);
  final IccTransform transform = IccTransform(
    sourceProfile: IccProfile.srgb,
    sourceFormat: IccPixelFormat.premultipliedRgba8,
    destinationProfile: IccProfile.adobeRgb1998,
    destinationFormat: IccPixelFormat.premultipliedRgba8,
  );
  try {
    final Uint8List converted = transform.convert(source);
    print(ChromaLib.backendVersion);
    print('Adobe RGB pixels: $converted');
  } finally {
    transform.close();
  }
}
