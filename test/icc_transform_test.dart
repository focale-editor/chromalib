@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:chromalib/chromalib.dart';
import 'package:test/test.dart';

void main() {
  test('reports the bundled Little CMS version', () async {
    await ChromaLib.initialize();

    check(ChromaLib.isAvailable).isTrue();
    check(ChromaLib.backendVersion).startsWith('Little CMS 2.19');
  });

  test('round-trips opaque sRGB through Adobe RGB', () {
    final Uint8List source = Uint8List.fromList([
      0,
      0,
      0,
      255,
      255,
      255,
      255,
      255,
      214,
      53,
      127,
      255,
      17,
      199,
      42,
      255,
    ]);

    final Uint8List adobe = transformPixels(
      source,
      sourceProfile: IccProfile.srgb,
      sourceFormat: IccPixelFormat.rgba8,
      destinationProfile: IccProfile.adobeRgb1998,
      destinationFormat: IccPixelFormat.rgba8,
    );
    final Uint8List restored = transformPixels(
      adobe,
      sourceProfile: IccProfile.adobeRgb1998,
      sourceFormat: IccPixelFormat.rgba8,
      destinationProfile: IccProfile.srgb,
      destinationFormat: IccPixelFormat.rgba8,
    );

    check(adobe).not((subject) => subject.deepEquals(source));
    for (int index = 0; index < source.length; index += 1) {
      check((restored[index] - source[index]).abs()).isLessOrEqual(3);
    }
  });

  test('preserves premultiplied alpha across a transform', () {
    final Uint8List source = Uint8List.fromList([
      128,
      64,
      32,
      128,
      0,
      0,
      0,
      0,
    ]);

    final Uint8List result = transformPixels(
      source,
      sourceProfile: IccProfile.srgb,
      sourceFormat: IccPixelFormat.premultipliedRgba8,
      destinationProfile: IccProfile.adobeRgb1998,
      destinationFormat: IccPixelFormat.premultipliedRgba8,
    );

    check(result[3]).equals(128);
    check(result[7]).equals(0);
    check(result.sublist(4, 7)).deepEquals([0, 0, 0]);
    for (final int component in result.take(3)) {
      check(component).isLessOrEqual(result[3]);
    }
  });

  test('preserves extended-range floating RGB when profiles permit it', () {
    final Uint8List source = Uint8List(4 * Float32List.bytesPerElement);
    final ByteData sourceData = ByteData.sublistView(source);
    sourceData
      ..setFloat32(0, 0, Endian.little)
      ..setFloat32(4, 1.1, Endian.little)
      ..setFloat32(8, 0, Endian.little)
      ..setFloat32(12, 1, Endian.little);

    final Uint8List result = transformPixels(
      source,
      sourceProfile: IccProfile.adobeRgb1998,
      sourceFormat: IccPixelFormat.premultipliedRgbaFloat32,
      destinationProfile: IccProfile.srgb,
      destinationFormat: IccPixelFormat.premultipliedRgbaFloat32,
    );
    final ByteData resultData = ByteData.sublistView(result);

    check(resultData.getFloat32(4, Endian.little)).isGreaterThan(1);
    check(resultData.getFloat32(12, Endian.little)).isCloseTo(1, 0.000001);
  });

  test('accepts an embedded ICC payload and owns its bytes', () {
    final Uint8List bytes = File('test/fixtures/srgb.icc').readAsBytesSync();
    final IccProfile profile = IccProfile.fromBytes(bytes);
    bytes.fillRange(0, bytes.lengthInBytes, 0);

    final Uint8List result = transformPixels(
      Uint8List.fromList([81, 144, 233]),
      sourceProfile: profile,
      sourceFormat: const IccPixelFormat(
        colorSpace: IccColorSpace.rgb,
        sampleType: IccSampleType.uint8,
      ),
      destinationProfile: IccProfile.srgb,
      destinationFormat: const IccPixelFormat(
        colorSpace: IccColorSpace.rgb,
        sampleType: IccSampleType.uint8,
      ),
    );

    check(result).deepEquals([81, 144, 233]);
    check(() => profile.bytes![0] = 0).throws<UnsupportedError>();
  });

  test('rejects incomplete pixels and use after close', () {
    final IccTransform transform = IccTransform(
      sourceProfile: IccProfile.srgb,
      sourceFormat: IccPixelFormat.rgba8,
      destinationProfile: IccProfile.srgb,
      destinationFormat: IccPixelFormat.rgba8,
    );

    check(() => transform.convert(Uint8List(3))).throws<ArgumentError>();
    transform.close();
    transform.close();
    check(() => transform.convert(Uint8List(4))).throws<StateError>();
  });
}
