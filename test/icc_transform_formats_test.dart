@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:chromalib/chromalib.dart';
import 'package:chromalib/src/native/bindings.dart';
import 'package:chromalib/src/native/bridge_contract.dart';
import 'package:test/test.dart';

/// Opaque 8-bit RGB pixels.
const IccPixelFormat _rgb8 = IccPixelFormat(
  colorSpace: IccColorSpace.rgb,
  sampleType: IccSampleType.uint8,
);

/// Premultiplied 8-bit grayscale and alpha pixels.
const IccPixelFormat _premultipliedGraya8 = IccPixelFormat(
  colorSpace: IccColorSpace.gray,
  sampleType: IccSampleType.uint8,
  hasAlpha: true,
  premultipliedAlpha: true,
);

/// Premultiplied normalized 8-bit Lab and alpha pixels.
const IccPixelFormat _premultipliedLaba8 = IccPixelFormat(
  colorSpace: IccColorSpace.lab,
  sampleType: IccSampleType.uint8,
  hasAlpha: true,
  premultipliedAlpha: true,
);

/// Straight 16-bit RGBA pixels.
const IccPixelFormat _rgba16 = IccPixelFormat(
  colorSpace: IccColorSpace.rgb,
  sampleType: IccSampleType.uint16,
  hasAlpha: true,
);

/// Straight 64-bit floating-point RGBA pixels.
const IccPixelFormat _rgbaFloat64 = IccPixelFormat(
  colorSpace: IccColorSpace.rgb,
  sampleType: IccSampleType.float64,
  hasAlpha: true,
);

void main() {
  test('loads a bridge with the expected ABI', () {
    check(nativeAbiVersion()).equals(bridgeAbiVersion);
  });

  test('8-bit matrix-shaper transforms match the floating reference', () {
    final Uint8List source = _randomBytes(4096 * 3, seed: 1);
    final Uint8List fast = transformPixels(
      source,
      sourceProfile: IccProfile.srgb,
      sourceFormat: _rgb8,
      destinationProfile: IccProfile.proPhotoRgb,
      destinationFormat: _rgb8,
    );
    final Float64List reference = Float64List.sublistView(
      transformPixels(
        source,
        sourceProfile: IccProfile.srgb,
        sourceFormat: _rgb8,
        destinationProfile: IccProfile.proPhotoRgb,
        destinationFormat: IccPixelFormat.rgbFloat64,
      ),
    );

    for (int index = 0; index < fast.length; index += 1) {
      final double expected = reference[index].clamp(0, 1) * 255;
      check((fast[index] - expected).abs()).isLessOrEqual(2);
    }
  });

  test('hybrid matrix and LUT profiles use the selected LUT pipeline', () {
    final IccProfile profile = IccProfile.fromBytes(
      File('test/fixtures/hybrid_matrix_lut.icc').readAsBytesSync(),
    );
    final Uint8List source = Uint8List.fromList([
      211,
      220,
      206,
      174,
      226,
      226,
      216,
      183,
      222,
      239,
      240,
      204,
    ]);
    final Uint8List converted = transformPixels(
      source,
      sourceProfile: profile,
      sourceFormat: _rgb8,
      destinationProfile: IccProfile.srgb,
      destinationFormat: _rgb8,
    );
    final ByteData floating = ByteData.sublistView(
      transformPixels(
        source,
        sourceProfile: profile,
        sourceFormat: _rgb8,
        destinationProfile: IccProfile.srgb,
        destinationFormat: const IccPixelFormat(
          colorSpace: IccColorSpace.rgb,
          sampleType: IccSampleType.float32,
        ),
      ),
    );
    final List<int> expected = [
      for (int index = 0; index < converted.length; index += 1) (floating.getFloat32(index * 4, Endian.little).clamp(0.0, 1.0) * 255).round(),
    ];

    check(converted).deepEquals(expected);
  });

  test('premultiplied integer output never exceeds alpha', () {
    // Saturated ProPhoto colours fall outside sRGB, which previously produced
    // components above alpha before clamping.
    final Uint8List premultiplied8 = Uint8List.fromList([
      188, 10, 83, 188, //
      0, 120, 0, 120,
      60, 0, 0, 60,
      3, 1, 2, 4,
    ]);
    final Uint8List straight16 = Uint8List(4 * 8);
    final ByteData straightData = ByteData.sublistView(straight16);
    for (int index = 0; index < 16; index += 1) {
      straightData.setUint16(index * 2, premultiplied8[index] * 257, Endian.little);
    }

    final Uint8List result8 = transformPixels(
      premultiplied8,
      sourceProfile: IccProfile.proPhotoRgb,
      sourceFormat: IccPixelFormat.premultipliedRgba8,
      destinationProfile: IccProfile.srgb,
      destinationFormat: IccPixelFormat.premultipliedRgba8,
    );
    final ByteData result16 = ByteData.sublistView(
      transformPixels(
        straight16,
        sourceProfile: IccProfile.proPhotoRgb,
        sourceFormat: _rgba16,
        destinationProfile: IccProfile.srgb,
        destinationFormat: IccPixelFormat.premultipliedRgba16,
      ),
    );

    for (int pixel = 0; pixel < 4; pixel += 1) {
      check(result8[pixel * 4 + 3]).equals(premultiplied8[pixel * 4 + 3]);
      final int alpha16 = result16.getUint16(pixel * 8 + 6, Endian.little);
      for (int channel = 0; channel < 3; channel += 1) {
        check(result8[pixel * 4 + channel]).isLessOrEqual(result8[pixel * 4 + 3]);
        check(result16.getUint16(pixel * 8 + channel * 2, Endian.little)).isLessOrEqual(alpha16);
      }
    }
  });

  test('converts premultiplied RGB through built-in gamma 2.2 gray', () {
    final Uint8List source = Uint8List.fromList([
      128,
      64,
      32,
      128,
      0,
      255,
      0,
      255,
    ]);

    final Uint8List gray = transformPixels(
      source,
      sourceProfile: IccProfile.srgb,
      sourceFormat: IccPixelFormat.premultipliedRgba8,
      destinationProfile: IccProfile.grayGamma22,
      destinationFormat: _premultipliedGraya8,
    );
    final Uint8List restored = transformPixels(
      gray,
      sourceProfile: IccProfile.grayGamma22,
      sourceFormat: _premultipliedGraya8,
      destinationProfile: IccProfile.srgb,
      destinationFormat: IccPixelFormat.premultipliedRgba8,
    );

    check(gray).length.equals(4);
    check(gray[1]).equals(128);
    check(gray[3]).equals(255);
    check(gray[0]).isLessOrEqual(gray[1]);
    check(restored[3]).equals(128);
    check(restored[7]).equals(255);
    check(restored[0]).equals(restored[1]);
    check(restored[1]).equals(restored[2]);
    check(restored[4]).equals(restored[5]);
    check(restored[5]).equals(restored[6]);
  });

  test('converts premultiplied RGB through normalized Lab samples', () {
    final Uint8List source = Uint8List.fromList([64, 32, 16, 128]);

    final Uint8List lab = transformPixels(
      source,
      sourceProfile: IccProfile.srgb,
      sourceFormat: IccPixelFormat.premultipliedRgba8,
      destinationProfile: IccProfile.labD50,
      destinationFormat: _premultipliedLaba8,
    );
    final Uint8List restored = transformPixels(
      lab,
      sourceProfile: IccProfile.labD50,
      sourceFormat: _premultipliedLaba8,
      destinationProfile: IccProfile.srgb,
      destinationFormat: IccPixelFormat.premultipliedRgba8,
    );

    check(lab).length.equals(4);
    check(lab[3]).equals(128);
    for (int channel = 0; channel < 3; channel++) {
      check(lab[channel]).isLessOrEqual(lab[3]);
      check((restored[channel] - source[channel]).abs()).isLessOrEqual(2);
    }
    check(restored[3]).equals(128);
  });

  test('8-bit built-in document transforms match 16-bit references', () {
    final List<
      ({
        IccProfile sourceProfile,
        IccPixelFormat sourceFormat,
        IccProfile destinationProfile,
        IccPixelFormat destinationFormat,
      })
    >
    cases = [
      (
        sourceProfile: IccProfile.srgb,
        sourceFormat: IccPixelFormat.premultipliedRgba8,
        destinationProfile: IccProfile.grayGamma22,
        destinationFormat: _premultipliedGraya8,
      ),
      (
        sourceProfile: IccProfile.grayGamma22,
        sourceFormat: _premultipliedGraya8,
        destinationProfile: IccProfile.srgb,
        destinationFormat: IccPixelFormat.premultipliedRgba8,
      ),
      (
        sourceProfile: IccProfile.srgb,
        sourceFormat: IccPixelFormat.premultipliedRgba8,
        destinationProfile: IccProfile.labD50,
        destinationFormat: _premultipliedLaba8,
      ),
      (
        sourceProfile: IccProfile.labD50,
        sourceFormat: _premultipliedLaba8,
        destinationProfile: IccProfile.srgb,
        destinationFormat: IccPixelFormat.premultipliedRgba8,
      ),
      (
        sourceProfile: IccProfile.grayGamma22,
        sourceFormat: _premultipliedGraya8,
        destinationProfile: IccProfile.labD50,
        destinationFormat: _premultipliedLaba8,
      ),
      (
        sourceProfile: IccProfile.labD50,
        sourceFormat: _premultipliedLaba8,
        destinationProfile: IccProfile.grayGamma22,
        destinationFormat: _premultipliedGraya8,
      ),
    ];

    for (int caseIndex = 0; caseIndex < cases.length; caseIndex++) {
      final ({
        IccProfile sourceProfile,
        IccPixelFormat sourceFormat,
        IccProfile destinationProfile,
        IccPixelFormat destinationFormat,
      })
      value = cases[caseIndex];
      final Uint8List source8 = _randomPremultiplied8(
        4096,
        colorChannels: value.sourceFormat.colorSpace.channelCount,
        seed: caseIndex + 20,
      );
      final Uint8List source16 = _expand8To16(source8);
      final IccPixelFormat sourceFormat16 = IccPixelFormat(
        colorSpace: value.sourceFormat.colorSpace,
        sampleType: IccSampleType.uint16,
        hasAlpha: true,
        premultipliedAlpha: true,
      );
      final IccPixelFormat destinationFormat16 = IccPixelFormat(
        colorSpace: value.destinationFormat.colorSpace,
        sampleType: IccSampleType.uint16,
        hasAlpha: true,
        premultipliedAlpha: true,
      );

      final Uint8List fast = transformPixels(
        source8,
        sourceProfile: value.sourceProfile,
        sourceFormat: value.sourceFormat,
        destinationProfile: value.destinationProfile,
        destinationFormat: value.destinationFormat,
      );
      final ByteData reference = ByteData.sublistView(
        transformPixels(
          source16,
          sourceProfile: value.sourceProfile,
          sourceFormat: sourceFormat16,
          destinationProfile: value.destinationProfile,
          destinationFormat: destinationFormat16,
        ),
      );

      for (int sample = 0; sample < fast.lengthInBytes; sample++) {
        final int expected =
            (reference.getUint16(
                      sample * Uint16List.bytesPerElement,
                      Endian.little,
                    ) /
                    257)
                .round();
        check((fast[sample] - expected).abs()).isLessOrEqual(2);
      }
    }
  });

  for (final (String name, IccPixelFormat format) in [
    ('8-bit fast path', IccPixelFormat.premultipliedRgba8),
    ('floating path', IccPixelFormat.premultipliedRgba16),
  ]) {
    test('converts across native call boundaries identically ($name)', () {
      const int pixelCount = 64 * 1024 * 2 + 17;
      final Uint8List source = _randomBytes(pixelCount * format.bytesPerPixel, seed: 2);
      final IccTransform transform = IccTransform(
        sourceProfile: IccProfile.adobeRgb1998,
        sourceFormat: format,
        destinationProfile: IccProfile.srgb,
        destinationFormat: format,
      );
      addTearDown(transform.close);

      final Uint8List whole = transform.convert(source);
      for (final int pixel in [0, 65535, 65536, 65537, pixelCount - 1]) {
        final int start = pixel * format.bytesPerPixel;
        final int end = start + format.bytesPerPixel;
        check(transform.convert(Uint8List.sublistView(source, start, end))).deepEquals(whole.sublist(start, end));
      }
    });
  }

  test('encodes Lab and XYZ integer samples', () {
    final Uint8List white = Uint8List.fromList([255, 255, 255]);

    final Uint8List lab8 = transformPixels(
      white,
      sourceProfile: IccProfile.srgb,
      sourceFormat: _rgb8,
      destinationProfile: IccProfile.labD50,
      destinationFormat: const IccPixelFormat(
        colorSpace: IccColorSpace.lab,
        sampleType: IccSampleType.uint8,
      ),
    );
    final ByteData lab16 = ByteData.sublistView(
      transformPixels(
        white,
        sourceProfile: IccProfile.srgb,
        sourceFormat: _rgb8,
        destinationProfile: IccProfile.labD50,
        destinationFormat: const IccPixelFormat(
          colorSpace: IccColorSpace.lab,
          sampleType: IccSampleType.uint16,
        ),
      ),
    );
    final ByteData xyz16 = ByteData.sublistView(
      transformPixels(
        white,
        sourceProfile: IccProfile.srgb,
        sourceFormat: _rgb8,
        destinationProfile: IccProfile.xyzD50,
        destinationFormat: const IccPixelFormat(
          colorSpace: IccColorSpace.xyz,
          sampleType: IccSampleType.uint16,
        ),
      ),
    );

    check(lab8).deepEquals([255, 128, 128]);
    check(lab16.getUint16(0, Endian.little)).equals(65535);
    check(lab16.getUint16(2, Endian.little)).equals(128 * 257);
    check(lab16.getUint16(4, Endian.little)).equals(128 * 257);
    check(xyz16.getUint16(0, Endian.little) / 32768).isCloseTo(0.9642, 0.001);
    check(xyz16.getUint16(2, Endian.little) / 32768).isCloseTo(1, 0.001);
    check(xyz16.getUint16(4, Endian.little) / 32768).isCloseTo(0.8249, 0.001);
  });

  test('round-trips 64-bit RGB through D50 XYZ', () {
    final Float64List rgb = Float64List.fromList([0.25, 0.5, 0.75, 1, 0, 0]);
    final Uint8List xyz = transformPixels(
      Uint8List.sublistView(rgb),
      sourceProfile: IccProfile.adobeRgb1998,
      sourceFormat: IccPixelFormat.rgbFloat64,
      destinationProfile: IccProfile.xyzD50,
      destinationFormat: IccPixelFormat.xyzFloat64,
    );
    final Float64List restored = Float64List.sublistView(
      transformPixels(
        xyz,
        sourceProfile: IccProfile.xyzD50,
        sourceFormat: IccPixelFormat.xyzFloat64,
        destinationProfile: IccProfile.adobeRgb1998,
        destinationFormat: IccPixelFormat.rgbFloat64,
      ),
    );

    for (int index = 0; index < rgb.length; index += 1) {
      check(restored[index]).isCloseTo(rgb[index], 0.001);
    }
  });

  test('preserves extended-range values in 64-bit buffers', () {
    final List<double> values = [
      0.123456789012345,
      0.987654321098765,
      -0.200000000000003,
      1.500000000000007,
      0.333333333333333,
      0.000000000000001,
    ];
    final Uint8List source = Uint8List(values.length * Float64List.bytesPerElement);
    final ByteData sourceData = ByteData.sublistView(source);
    for (int index = 0; index < values.length; index += 1) {
      sourceData.setFloat64(
        index * Float64List.bytesPerElement,
        values[index],
        Endian.little,
      );
    }

    final ByteData result = ByteData.sublistView(
      transformPixels(
        source,
        sourceProfile: IccProfile.srgb,
        sourceFormat: IccPixelFormat.rgbFloat64,
        destinationProfile: IccProfile.srgb,
        destinationFormat: IccPixelFormat.rgbFloat64,
      ),
    );

    for (int index = 0; index < values.length; index += 1) {
      check(
        result.getFloat64(
          index * Float64List.bytesPerElement,
          Endian.little,
        ),
      ).equals(values[index]);
    }
  });

  test('identical embedded profiles convert layouts without colour rounding', () {
    final Uint8List profileBytes = File(
      'test/fixtures/srgb.icc',
    ).readAsBytesSync();
    final IccProfile sourceProfile = IccProfile.fromBytes(profileBytes);
    final IccProfile destinationProfile = IccProfile.fromBytes(profileBytes);
    final Uint8List source = Uint8List(16);
    final ByteData sourceData = ByteData.sublistView(source);
    final List<int> samples = [
      32768,
      16384,
      32767,
      65535,
      16384,
      8192,
      0,
      32768,
    ];
    for (int index = 0; index < samples.length; index += 1) {
      sourceData.setUint16(index * 2, samples[index], Endian.little);
    }

    final Uint8List straight = transformPixels(
      source,
      sourceProfile: sourceProfile,
      sourceFormat: IccPixelFormat.premultipliedRgba16,
      destinationProfile: destinationProfile,
      destinationFormat: _rgbaFloat64,
    );
    final ByteData straightData = ByteData.sublistView(straight);
    check(straightData.getFloat64(0, Endian.little)).equals(32768 / 65535);
    check(straightData.getFloat64(32, Endian.little)).equals(0.5);
    check(straightData.getFloat64(56, Endian.little)).equals(32768 / 65535);

    final Uint8List restored = transformPixels(
      straight,
      sourceProfile: destinationProfile,
      sourceFormat: _rgbaFloat64,
      destinationProfile: sourceProfile,
      destinationFormat: IccPixelFormat.premultipliedRgba16,
    );

    check(restored).deepEquals(source);
  });

  test('converts embedded gray profiles', () {
    final IccProfile gray = IccProfile.fromBytes(_linearGrayProfile());
    const IccPixelFormat gray16 = IccPixelFormat(
      colorSpace: IccColorSpace.gray,
      sampleType: IccSampleType.uint16,
      hasAlpha: true,
    );
    final Uint8List source = Uint8List(4);
    ByteData.sublistView(source)
      ..setUint16(0, 65535, Endian.little)
      ..setUint16(2, 32768, Endian.little);

    final ByteData result = ByteData.sublistView(
      transformPixels(
        source,
        sourceProfile: gray,
        sourceFormat: gray16,
        destinationProfile: IccProfile.srgb,
        destinationFormat: _rgba16,
      ),
    );

    for (int channel = 0; channel < 3; channel += 1) {
      check(result.getUint16(channel * 2, Endian.little)).isGreaterOrEqual(65534);
    }
    check(result.getUint16(6, Endian.little)).equals(32768);
  });

  test('writes into a caller-owned buffer', () {
    final IccTransform transform = IccTransform(
      sourceProfile: IccProfile.srgb,
      sourceFormat: IccPixelFormat.rgba8,
      destinationProfile: IccProfile.adobeRgb1998,
      destinationFormat: _rgba16,
    );
    addTearDown(transform.close);
    final Uint8List source = _randomBytes(64 * 4, seed: 3);
    final Uint8List output = Uint8List(64 * 8);

    transform.convertInto(source, output);

    check(output).deepEquals(transform.convert(source));
    check(() => transform.convertInto(source, Uint8List(64 * 8 + 1))).throws<ArgumentError>();
    final Uint8List shared = Uint8List(64 * 12);
    check(
      () => transform.convertInto(
        Uint8List.sublistView(shared, 0, 64 * 4),
        Uint8List.sublistView(shared, 64 * 2, 64 * 10),
      ),
    ).throws<ArgumentError>();
    transform.convertInto(
      Uint8List.sublistView(shared, 0, 64 * 4),
      Uint8List.sublistView(shared, 64 * 4),
    );
    transform.convertInto(Uint8List(0), Uint8List(0));
  });

  test('reports invalid profiles with their cause', () {
    check(() => IccProfile.fromBytes(Uint8List(64))).throws<IccException>();
    final Uint8List wrongSignature = _linearGrayProfile()..[36] = 0;
    check(() => IccProfile.fromBytes(wrongSignature)).throws<IccException>();

    final Uint8List corrupted = _linearGrayProfile();
    // Little CMS rejects tag tables larger than it supports while opening.
    ByteData.sublistView(corrupted).setUint32(128, 0x7fffffff);
    final IccProfile profile = IccProfile.fromBytes(corrupted);
    check(
        () => IccTransform(
          sourceProfile: profile,
          sourceFormat: const IccPixelFormat(
            colorSpace: IccColorSpace.gray,
            sampleType: IccSampleType.uint8,
          ),
          destinationProfile: IccProfile.srgb,
          destinationFormat: _rgb8,
        ),
      ).throws<IccException>().has((error) => error.message, 'message')
      ..contains('source ICC profile')
      ..contains('Little CMS error');
  });
}

/// Deterministic pseudo-random bytes.
Uint8List _randomBytes(int length, {required int seed}) {
  final Random random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Builds valid premultiplied bytes with one trailing alpha component.
Uint8List _randomPremultiplied8(
  int pixelCount, {
  required int colorChannels,
  required int seed,
}) {
  final Random random = Random(seed);
  final int stride = colorChannels + 1;
  final Uint8List pixels = Uint8List(pixelCount * stride);
  for (int pixel = 0; pixel < pixelCount; pixel++) {
    final int offset = pixel * stride;
    final int alpha = random.nextInt(256);
    for (int channel = 0; channel < colorChannels; channel++) {
      final int straight = random.nextInt(256);
      pixels[offset + channel] = (straight * alpha + 127) ~/ 255;
    }
    pixels[offset + colorChannels] = alpha;
  }
  return pixels;
}

/// Expands exact normalized 8-bit samples into little-endian 16-bit samples.
Uint8List _expand8To16(Uint8List source) {
  final Uint8List result = Uint8List(
    source.lengthInBytes * Uint16List.bytesPerElement,
  );
  final ByteData data = ByteData.sublistView(result);
  for (int sample = 0; sample < source.lengthInBytes; sample++) {
    data.setUint16(
      sample * Uint16List.bytesPerElement,
      source[sample] * 257,
      Endian.little,
    );
  }
  return result;
}

/// Builds a minimal ICC v2 display profile with a linear gray tone curve.
Uint8List _linearGrayProfile() {
  const int tagTableOffset = 128;
  const int tagCount = 2;
  const int curveOffset = tagTableOffset + 4 + tagCount * 12;
  const int curveLength = 12;
  const int whitePointOffset = curveOffset + curveLength;
  const int whitePointLength = 20;
  const int length = whitePointOffset + whitePointLength;
  final Uint8List bytes = Uint8List(length);
  final ByteData data = ByteData.sublistView(bytes);

  void signature(int offset, String value) => bytes.setAll(offset, value.codeUnits);

  data
    ..setUint32(0, length)
    ..setUint32(8, 0x02100000);
  signature(12, 'mntr');
  signature(16, 'GRAY');
  signature(20, 'XYZ ');
  signature(36, 'acsp');
  // D50 profile connection-space illuminant in s15Fixed16Number form.
  data
    ..setInt32(68, 0x0000F6D6)
    ..setInt32(72, 0x00010000)
    ..setInt32(76, 0x0000D32D)
    ..setUint32(tagTableOffset, tagCount);

  signature(132, 'kTRC');
  data
    ..setUint32(136, curveOffset)
    ..setUint32(140, curveLength);
  signature(144, 'wtpt');
  data
    ..setUint32(148, whitePointOffset)
    ..setUint32(152, whitePointLength);

  // A curve with no entries is the identity.
  signature(curveOffset, 'curv');
  data.setUint32(curveOffset + 8, 0);
  signature(whitePointOffset, 'XYZ ');
  data
    ..setInt32(whitePointOffset + 8, 0x0000F6D6)
    ..setInt32(whitePointOffset + 12, 0x00010000)
    ..setInt32(whitePointOffset + 16, 0x0000D32D);
  return bytes;
}
