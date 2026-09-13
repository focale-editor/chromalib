import 'package:chromalib/src/backend/backend.dart' as backend;

/// Describes the colour-management backend bundled with this package.
abstract final class ChromaLib {
  /// Loads the native code asset or browser WebAssembly module.
  ///
  /// Native applications may omit this call because creating a transform loads
  /// the code asset lazily. Browser applications must await it before creating
  /// their first transform. [assetBaseUrl] overrides Flutter's package asset
  /// path for plain Dart Web applications or custom asset servers.
  static Future<void> initialize({String? assetBaseUrl}) => backend.initializeBackend(
    assetBaseUrl: assetBaseUrl,
  );

  /// Whether colour transforms are available on the current platform.
  static bool get isAvailable => backend.isBackendAvailable;

  /// Version reported by the loaded Little CMS engine.
  static String get backendVersion => backend.backendVersion;
}
