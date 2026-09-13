// Hand-written bindings for ChromaLib's deliberately small C bridge.
@DefaultAsset('package:chromalib/src/native/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opaque native colour transform.
final class NativeIccTransform extends Opaque {}

/// Creates a transform and retains any creation diagnostic on its handle.
@Native<
  Pointer<NativeIccTransform> Function(
    Int,
    Pointer<Uint8>,
    Size,
    Int,
    Int,
    Int,
    Int,
    Int,
    Pointer<Uint8>,
    Size,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
  )
>(symbol: 'chromalib_transform_create')
external Pointer<NativeIccTransform> nativeTransformCreate(
  int sourceProfileKind,
  Pointer<Uint8> sourceProfileBytes,
  int sourceProfileLength,
  int sourceColorSpace,
  int sourceSampleType,
  int sourceHasAlpha,
  int sourcePremultipliedAlpha,
  int destinationProfileKind,
  Pointer<Uint8> destinationProfileBytes,
  int destinationProfileLength,
  int destinationColorSpace,
  int destinationSampleType,
  int destinationHasAlpha,
  int destinationPremultipliedAlpha,
  int renderingIntent,
  int blackPointCompensation,
  int reserved,
);

/// Returns the version of the exported C bridge contract.
@Native<Uint32 Function()>(
  symbol: 'chromalib_abi_version',
  isLeaf: true,
)
external int nativeAbiVersion();

/// Reports whether a native transform was compiled successfully.
@Native<Int Function(Pointer<NativeIccTransform>)>(
  symbol: 'chromalib_transform_is_valid',
  isLeaf: true,
)
external int nativeTransformIsValid(Pointer<NativeIccTransform> transform);

/// Applies a bounded pixel range without copying Dart typed-data buffers.
@Native<
  Int Function(
    Pointer<NativeIccTransform>,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Size,
    Size,
  )
>(symbol: 'chromalib_transform_apply', isLeaf: true)
external int nativeTransformApply(
  Pointer<NativeIccTransform> transform,
  Pointer<Uint8> input,
  int inputLength,
  Pointer<Uint8> output,
  int outputLength,
  int pixelOffset,
  int pixelCount,
);

/// Returns the latest diagnostic retained by a transform.
@Native<Pointer<Utf8> Function(Pointer<NativeIccTransform>)>(
  symbol: 'chromalib_transform_error',
  isLeaf: true,
)
external Pointer<Utf8> nativeTransformError(
  Pointer<NativeIccTransform> transform,
);

/// Releases a native transform and its Little CMS context.
@Native<Void Function(Pointer<NativeIccTransform>)>(
  symbol: 'chromalib_transform_destroy',
  isLeaf: true,
)
external void nativeTransformDestroy(Pointer<NativeIccTransform> transform);

/// Returns the bundled Little CMS version.
@Native<Pointer<Utf8> Function()>(
  symbol: 'chromalib_version',
  isLeaf: true,
)
external Pointer<Utf8> nativeVersion();
