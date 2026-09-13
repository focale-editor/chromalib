/// Prepares ChromaLib's pinned Little CMS source for offline native builds.
library;

import 'dart:io';
import 'dart:isolate';

import '../tool/little_cms_downloader.dart';

/// Downloads and verifies the source archive used by native build hooks.
Future<void> main(List<String> arguments) async {
  if (arguments.any((argument) => argument != '--force')) {
    stderr.writeln(
      'Usage: dart run chromalib:prepare_library [--force]',
    );
    exitCode = 64;
    return;
  }
  try {
    final Directory packageRoot = await _packageRoot();
    final Directory destination = Directory(
      '${packageRoot.path}${Platform.pathSeparator}native'
      '${Platform.pathSeparator}third_party${Platform.pathSeparator}lcms2',
    );
    await installLittleCms(
      destination,
      force: arguments.contains('--force'),
      log: stdout.writeln,
    );
  } on Object catch (error) {
    stderr.writeln('Could not prepare ChromaLib sources: $error');
    exitCode = 1;
  }
}

/// Locates this package for both path and Pub dependencies.
Future<Directory> _packageRoot() async {
  final Uri? libraryUri = await Isolate.resolvePackageUri(
    Uri.parse('package:chromalib/chromalib.dart'),
  );
  if (libraryUri == null || libraryUri.scheme != 'file') {
    throw StateError('Could not locate the installed ChromaLib package.');
  }
  return File.fromUri(libraryUri).parent.parent;
}
