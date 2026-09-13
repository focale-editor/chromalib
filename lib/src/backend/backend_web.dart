import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:chromalib/src/backend/transform_backend.dart';
import 'package:chromalib/src/model/icc_exception.dart';
import 'package:chromalib/src/model/icc_pixel_format.dart';
import 'package:chromalib/src/model/icc_profile.dart';
import 'package:chromalib/src/model/icc_transform_options.dart';
import 'package:chromalib/src/native/bridge_contract.dart';
import 'package:web/web.dart' as web;

/// Default URL used by Flutter's package asset bundler.
String _assetBaseUrl = 'assets/packages/chromalib/assets/web/';

/// Emscripten ES module that exports the WebAssembly module factory.
const String _moduleFileName = 'chromalib.mjs';

/// Shared initialization attempt, cleared after a failure so callers can retry.
Future<void>? _initialization;

/// Loaded browser module used by synchronous transform objects.
_ChromaModule? _module;

/// Maximum pixels transformed by one WebAssembly invocation.
const int _pixelsPerModuleCall = 64 * 1024;

/// Loads the packaged WebAssembly module.
Future<void> initializeBackend({String? assetBaseUrl}) {
  if (assetBaseUrl != null) {
    final String trimmed = assetBaseUrl.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        assetBaseUrl,
        'assetBaseUrl',
        'A Web asset URL is required.',
      );
    }
    final String normalized = trimmed.endsWith('/') ? trimmed : '$trimmed/';
    if (_initialization != null && normalized != _assetBaseUrl) {
      throw StateError(
        'The Web asset URL cannot change after initialization starts.',
      );
    }
    _assetBaseUrl = normalized;
  }
  final Future<void>? existing = _initialization;
  if (existing != null) {
    return existing;
  }
  final Future<void> attempt = _loadModule();
  _initialization = attempt;
  // Future callbacks run asynchronously, so a failure is always observed after
  // the attempt has been stored, even when it fails before its first await.
  unawaited(
    attempt.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_initialization, attempt)) {
          _initialization = null;
        }
      },
    ),
  );
  return attempt;
}

/// Imports the Emscripten ES module and awaits WebAssembly instantiation.
///
/// A dynamic `import()` needs neither inline scripts nor evaluation
/// permissions, and also works inside Web workers.
Future<void> _loadModule() async {
  String url = '$_assetBaseUrl$_moduleFileName';
  try {
    url = _resolveAssetUrl(url);
    final _ChromaModuleExports exports = _ChromaModuleExports._(
      await importModule(url.toJS).toDart.timeout(const Duration(seconds: 30)),
    );
    final _ChromaModule module = await exports.createModule().toDart.timeout(const Duration(seconds: 60));
    final int actualVersion = module.abiVersion();
    if (actualVersion != bridgeAbiVersion) {
      throw IccException(
        'Incompatible ChromaLib WebAssembly bridge: expected ABI '
        '$bridgeAbiVersion, found $actualVersion.',
      );
    }
    _module = module;
  } on IccException {
    rethrow;
  } on Object catch (error) {
    throw IccException(
      'Could not initialize ChromaLib WebAssembly from $url: $error',
    );
  }
}

/// Resolves [url] like a document-relative asset, honouring `<base href>`.
String _resolveAssetUrl(String url) {
  final String base = globalContext.has('document') ? web.document.baseURI : globalContext.getProperty<web.WorkerLocation>('location'.toJS).href;
  return web.URL(url, base).href;
}

/// Whether the browser module has completed initialization.
bool get isBackendAvailable => _module != null;

/// Version reported by the loaded browser module.
String get backendVersion {
  final _ChromaModule module = _readyModule;
  return module.readString(module.version());
}

/// Creates one transform in WebAssembly memory.
TransformBackend createTransformBackend({
  required IccProfile sourceProfile,
  required IccPixelFormat sourceFormat,
  required IccProfile destinationProfile,
  required IccPixelFormat destinationFormat,
  required IccTransformOptions options,
}) => _WebTransformBackend.create(
  module: _readyModule,
  sourceProfile: sourceProfile,
  sourceFormat: sourceFormat,
  destinationProfile: destinationProfile,
  destinationFormat: destinationFormat,
  options: options,
);

/// Returns the initialized module or explains the required startup call.
_ChromaModule get _readyModule => _module ?? (throw StateError('Await ChromaLib.initialize() before creating browser transforms.'));

/// Owns one transform allocated by the shared WebAssembly module.
final class _WebTransformBackend implements TransformBackend {
  /// Module that owns [_handle].
  final _ChromaModule _module;

  /// WebAssembly pointer, cleared by [close].
  int _handle;

  /// Source bytes occupied by one pixel.
  final int _sourceBytesPerPixel;

  /// Destination bytes occupied by one pixel.
  final int _destinationBytesPerPixel;

  /// Creates a WebAssembly transform after copying profile payloads.
  factory _WebTransformBackend.create({
    required _ChromaModule module,
    required IccProfile sourceProfile,
    required IccPixelFormat sourceFormat,
    required IccProfile destinationProfile,
    required IccPixelFormat destinationFormat,
    required IccTransformOptions options,
  }) {
    final Uint8List? sourceBytes = sourceProfile.bytes;
    final Uint8List? destinationBytes = destinationProfile.bytes;
    int nativeSource = 0;
    int nativeDestination = 0;
    try {
      nativeSource = _copyToModule(module, sourceBytes);
      nativeDestination = _copyToModule(module, destinationBytes);
      int handle = module.createTransform(
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
      if (handle == 0) {
        throw const IccException(
          'The WebAssembly engine could not allocate a transform.',
        );
      }
      if (module.isValid(handle) == 0) {
        final String message = module.readString(module.error(handle));
        module.destroy(handle);
        handle = 0;
        throw IccException(
          message.isEmpty ? 'Little CMS could not compile the transform.' : message,
        );
      }
      return _WebTransformBackend._(
        module,
        handle,
        sourceBytesPerPixel: sourceFormat.bytesPerPixel,
        destinationBytesPerPixel: destinationFormat.bytesPerPixel,
      );
    } finally {
      module
        ..release(nativeSource)
        ..release(nativeDestination);
    }
  }

  /// Retains one valid WebAssembly handle.
  _WebTransformBackend._(
    this._module,
    this._handle, {
    required this._sourceBytesPerPixel,
    required this._destinationBytesPerPixel,
  });

  @override
  void convertInto(Uint8List input, Uint8List output) {
    final int handle = _handle;
    if (handle == 0) {
      throw StateError('The WebAssembly ICC transform is closed.');
    }
    final int pixelCount = input.lengthInBytes ~/ _sourceBytesPerPixel;
    final int bufferPixels = pixelCount.clamp(0, _pixelsPerModuleCall);
    int nativeInput = 0;
    int nativeOutput = 0;
    try {
      nativeInput = _allocate(
        _module,
        bufferPixels * _sourceBytesPerPixel,
        'source pixel buffer',
      );
      nativeOutput = _allocate(
        _module,
        bufferPixels * _destinationBytesPerPixel,
        'destination pixel buffer',
      );
      for (int offset = 0; offset < pixelCount; offset += _pixelsPerModuleCall) {
        final int count = (pixelCount - offset).clamp(0, _pixelsPerModuleCall);
        final int sourceStart = offset * _sourceBytesPerPixel;
        final int sourceLength = count * _sourceBytesPerPixel;
        final int destinationStart = offset * _destinationBytesPerPixel;
        final int destinationLength = count * _destinationBytesPerPixel;
        // Each bulk operation crosses the JavaScript boundary once. Keeping
        // the views bounded also caps temporary WebAssembly memory.
        _module.heap.set(
          Uint8List.sublistView(
            input,
            sourceStart,
            sourceStart + sourceLength,
          ).toJS,
          nativeInput,
        );
        if (_module.apply(
              handle,
              nativeInput,
              sourceLength,
              nativeOutput,
              destinationLength,
              0,
              count,
            ) ==
            0) {
          final String message = _module.readString(_module.error(handle));
          throw IccException(
            message.isEmpty ? 'Little CMS could not apply the transform.' : message,
          );
        }
        // Read the heap again: applying a transform may grow linear memory.
        output.setRange(
          destinationStart,
          destinationStart + destinationLength,
          _module.heap
              .subarray(
                nativeOutput,
                nativeOutput + destinationLength,
              )
              .toDart,
        );
      }
    } finally {
      _module
        ..release(nativeInput)
        ..release(nativeOutput);
    }
  }

  @override
  void close() {
    final int handle = _handle;
    if (handle == 0) {
      return;
    }
    _handle = 0;
    _module.destroy(handle);
  }
}

/// Allocates [length] bytes of module memory or reports which [purpose] failed.
int _allocate(_ChromaModule module, int length, String purpose) {
  final int pointer = module.allocate(length);
  if (pointer == 0) {
    throw IccException(
      'The WebAssembly engine could not allocate $purpose.',
    );
  }
  return pointer;
}

/// Copies optional profile bytes to the module and returns zero when absent.
int _copyToModule(_ChromaModule module, Uint8List? bytes) {
  if (bytes == null) {
    return 0;
  }
  final int pointer = _allocate(module, bytes.lengthInBytes, 'profile memory');
  module.heap.set(bytes.toJS, pointer);
  return pointer;
}

/// Bulk typed-array operations missing from `dart:js_interop`.
extension on JSUint8Array {
  /// Copies [source] into this array starting at [offset].
  external void set(JSUint8Array source, int offset);

  /// Returns a view of this array's elements from [start] until [end].
  external JSUint8Array subarray(int start, int end);
}

/// Namespace object of the imported Emscripten ES module.
extension type _ChromaModuleExports._(JSObject _) implements JSObject {
  /// Instantiates the WebAssembly module.
  @JS('default')
  external JSPromise<_ChromaModule> createModule();
}

/// Typed view over Emscripten's exported functions and current linear memory.
extension type _ChromaModule._(JSObject _) implements JSObject {
  /// Current linear memory, refreshed after operations that may grow it.
  @JS('HEAPU8')
  external JSUint8Array get heap;

  /// Allocates module memory.
  @JS('_malloc')
  external int allocate(int size);

  /// Releases module memory; zero is accepted.
  @JS('_free')
  external void release(int pointer);

  /// Compiles one colour transform.
  @JS('_chromalib_transform_create')
  external int createTransform(
    int sourceProfileKind,
    int sourceProfileBytes,
    int sourceProfileLength,
    int sourceColorSpace,
    int sourceSampleType,
    int sourceHasAlpha,
    int sourcePremultipliedAlpha,
    int destinationProfileKind,
    int destinationProfileBytes,
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
  @JS('_chromalib_abi_version')
  external int abiVersion();

  /// Reports whether one transform compiled successfully.
  @JS('_chromalib_transform_is_valid')
  external int isValid(int transform);

  /// Applies one bounded portion of a pixel buffer.
  @JS('_chromalib_transform_apply')
  external int apply(
    int transform,
    int input,
    int inputLength,
    int output,
    int outputLength,
    int pixelOffset,
    int pixelCount,
  );

  /// Returns the latest transform diagnostic.
  @JS('_chromalib_transform_error')
  external int error(int transform);

  /// Releases a transform.
  @JS('_chromalib_transform_destroy')
  external void destroy(int transform);

  /// Returns the bundled engine version string.
  @JS('_chromalib_version')
  external int version();

  /// Copies a null-terminated native UTF-8 string.
  @JS('UTF8ToString')
  external String readString(int pointer);
}
