import 'dart:ffi';
import 'dart:typed_data';

import 'package:chromalib/src/backend/transform_backend.dart';
import 'package:chromalib/src/model/icc_exception.dart';
import 'package:chromalib/src/model/icc_pixel_format.dart';
import 'package:chromalib/src/model/icc_profile.dart';
import 'package:chromalib/src/model/icc_transform_options.dart';
import 'package:chromalib/src/native/bindings.dart';
import 'package:chromalib/src/native/bridge_contract.dart';
import 'package:ffi/ffi.dart';

/// Maximum pixels transformed by one leaf FFI invocation.
const int _pixelsPerNativeCall = 64 * 1024;

/// Approximate native memory retained by one compiled Little CMS transform.
const int _transformBaseBytes = 64 * 1024;

/// Native finalizer callback signature.
typedef _NativeDestroy = Void Function(Pointer<NativeIccTransform>);

/// Releases abandoned native handles outside the Dart isolate.
final NativeFinalizer _transformFinalizer = NativeFinalizer(
  Native.addressOf<NativeFunction<_NativeDestroy>>(
    nativeTransformDestroy,
  ).cast<NativeFinalizerFunction>(),
);

/// Cached result of the first attempt to resolve the bundled code asset.
bool? _backendAvailable;

/// Loads the bundled code asset and validates its exported version symbol.
Future<void> initializeBackend({String? assetBaseUrl}) async {
  _validateBackend();
  _backendAvailable = true;
}

/// Whether this target provides a colour-management engine.
///
/// A missing or unloadable code asset reports `false` instead of throwing.
bool get isBackendAvailable => _backendAvailable ??= _probeBackend();

/// Version reported by the bundled engine.
String get backendVersion {
  _validateBackend();
  return nativeVersion().toDartString();
}

/// Resolves one exported symbol to confirm that the code asset loads.
bool _probeBackend() {
  try {
    _validateBackend();
    return true;
  } on Object {
    return false;
  }
}

/// Rejects a code asset built against another bridge contract.
void _validateBackend() {
  final int actualVersion = nativeAbiVersion();
  if (actualVersion != bridgeAbiVersion) {
    throw IccException(
      'Incompatible ChromaLib native bridge: expected ABI '
      '$bridgeAbiVersion, found $actualVersion.',
    );
  }
  nativeVersion();
}

/// Creates one native Little CMS transform.
TransformBackend createTransformBackend({
  required IccProfile sourceProfile,
  required IccPixelFormat sourceFormat,
  required IccProfile destinationProfile,
  required IccPixelFormat destinationFormat,
  required IccTransformOptions options,
}) {
  _validateBackend();
  return _NativeTransformBackend.create(
    sourceProfile: sourceProfile,
    sourceFormat: sourceFormat,
    destinationProfile: destinationProfile,
    destinationFormat: destinationFormat,
    options: options,
  );
}

/// Owns one compiled native transform.
final class _NativeTransformBackend implements TransformBackend, Finalizable {
  /// Native handle, cleared by [close].
  Pointer<NativeIccTransform> _handle;

  /// Source bytes occupied by one pixel.
  final int _sourceBytesPerPixel;

  /// Creates a native transform after copying short-lived profile payloads.
  factory _NativeTransformBackend.create({
    required IccProfile sourceProfile,
    required IccPixelFormat sourceFormat,
    required IccProfile destinationProfile,
    required IccPixelFormat destinationFormat,
    required IccTransformOptions options,
  }) {
    final Uint8List? sourceBytes = sourceProfile.bytes;
    final Uint8List? destinationBytes = destinationProfile.bytes;
    Pointer<Uint8> nativeSource = nullptr;
    Pointer<Uint8> nativeDestination = nullptr;
    try {
      nativeSource = _copyToNative(sourceBytes);
      nativeDestination = _copyToNative(destinationBytes);
      Pointer<NativeIccTransform> handle = nativeTransformCreate(
        profileBridgeValue(sourceProfile),
        nativeSource,
        sourceBytes?.lengthInBytes ?? 0,
        colorSpaceBridgeValue(sourceFormat.colorSpace),
        sampleTypeBridgeValue(sourceFormat.sampleType),
        sourceFormat.hasAlpha ? 1 : 0,
        sourceFormat.premultipliedAlpha ? 1 : 0,
        profileBridgeValue(destinationProfile),
        nativeDestination,
        destinationBytes?.lengthInBytes ?? 0,
        colorSpaceBridgeValue(destinationFormat.colorSpace),
        sampleTypeBridgeValue(destinationFormat.sampleType),
        destinationFormat.hasAlpha ? 1 : 0,
        destinationFormat.premultipliedAlpha ? 1 : 0,
        renderingIntentBridgeValue(options.renderingIntent),
        options.blackPointCompensation ? 1 : 0,
        0,
      );
      if (handle == nullptr) {
        throw const IccException('The native engine could not allocate a transform.');
      }
      if (nativeTransformIsValid(handle) == 0) {
        final String message = nativeTransformError(handle).toDartString();
        nativeTransformDestroy(handle);
        handle = nullptr;
        throw IccException(
          message.isEmpty ? 'Little CMS could not compile the transform.' : message,
        );
      }
      return _NativeTransformBackend._(
        handle,
        sourceBytesPerPixel: sourceFormat.bytesPerPixel,
        externalSize: _estimatedExternalSize(sourceFormat, destinationFormat),
      );
    } finally {
      malloc
        ..free(nativeSource)
        ..free(nativeDestination);
    }
  }

  /// Retains one valid native handle.
  _NativeTransformBackend._(
    this._handle, {
    required this._sourceBytesPerPixel,
    required int externalSize,
  }) {
    _transformFinalizer.attach(
      this,
      _handle.cast<Void>(),
      detach: this,
      externalSize: externalSize,
    );
  }

  @override
  void convertInto(Uint8List input, Uint8List output) {
    final Pointer<NativeIccTransform> handle = _handle;
    if (handle == nullptr) {
      throw StateError('The native ICC transform is closed.');
    }
    final int pixelCount = input.lengthInBytes ~/ _sourceBytesPerPixel;
    for (int offset = 0; offset < pixelCount; offset += _pixelsPerNativeCall) {
      final int count = (pixelCount - offset).clamp(0, _pixelsPerNativeCall);
      final int succeeded = nativeTransformApply(
        handle,
        input.address,
        input.lengthInBytes,
        output.address,
        output.lengthInBytes,
        offset,
        count,
      );
      if (succeeded == 0) {
        final String message = nativeTransformError(handle).toDartString();
        throw IccException(
          message.isEmpty ? 'Little CMS could not apply the transform.' : message,
        );
      }
    }
  }

  @override
  void close() {
    final Pointer<NativeIccTransform> handle = _handle;
    if (handle == nullptr) {
      return;
    }
    _transformFinalizer.detach(this);
    _handle = nullptr;
    nativeTransformDestroy(handle);
  }

  /// Copies optional profile bytes to native memory, or returns `nullptr`.
  static Pointer<Uint8> _copyToNative(Uint8List? bytes) {
    if (bytes == null) {
      return nullptr;
    }
    final Pointer<Uint8> pointer = malloc<Uint8>(bytes.lengthInBytes);
    pointer.asTypedList(bytes.lengthInBytes).setAll(0, bytes);
    return pointer;
  }

  /// Upper bound of the native memory retained by a transform, reported to the
  /// garbage collector so abandoned instances are finalized promptly.
  ///
  /// Floating scratch buffers hold every colour component of one bounded call;
  /// the 8-bit fast path needs at most a straight-alpha copy of the input.
  static int _estimatedExternalSize(
    IccPixelFormat sourceFormat,
    IccPixelFormat destinationFormat,
  ) =>
      _transformBaseBytes +
      _pixelsPerNativeCall *
          (sourceFormat.colorSpace.channelCount * _scratchSampleBytes(sourceFormat.sampleType) + destinationFormat.colorSpace.channelCount * _scratchSampleBytes(destinationFormat.sampleType));

  /// Bytes used by one internal floating scratch sample.
  static int _scratchSampleBytes(IccSampleType sampleType) => sampleType == IccSampleType.float64 ? Float64List.bytesPerElement : Float32List.bytesPerElement;
}
