import 'dart:io';

import 'little_cms_downloader.dart';

/// Emscripten release used to produce ChromaLib's published Web assets.
const String emscriptenVersion = '4.0.15';

/// Browser artifacts shipped with the package.
const List<String> webLibraryFileNames = [
  'chromalib.mjs',
  'chromalib.wasm',
];

/// Builds bundled Little CMS as an ES module and WebAssembly binary.
Future<void> buildWebLibrary({
  required Directory packageRoot,
  String? compiler,
  void Function(String message)? log,
}) async {
  final Directory outputDirectory = Directory(
    '${packageRoot.path}${Platform.pathSeparator}assets${Platform.pathSeparator}web',
  );
  await outputDirectory.create(recursive: true);
  final Directory packageLittleCmsDirectory = Directory(
    '${packageRoot.path}${Platform.pathSeparator}native${Platform.pathSeparator}third_party${Platform.pathSeparator}lcms2',
  );
  final Directory littleCmsDirectory =
      hasLittleCmsSource(
        packageLittleCmsDirectory,
      )
      ? packageLittleCmsDirectory
      : await installLittleCms(
          Directory(
            '${packageRoot.path}${Platform.pathSeparator}build${Platform.pathSeparator}source-cache${Platform.pathSeparator}lcms2-$littleCmsVersion',
          ),
          log: log,
        );
  final Directory sourceDirectory = Directory(
    '${littleCmsDirectory.path}${Platform.pathSeparator}src',
  );
  final List<String> sources = sourceDirectory.listSync().whereType<File>().where((file) => file.path.endsWith('.c')).map((file) => file.absolute.path).toList()..sort();
  final String executable = compiler ?? Platform.environment['CHROMALIB_EMCC'] ?? (Platform.isWindows ? 'emcc.bat' : 'emcc');
  await _verifyEmscriptenVersion(executable);
  const String outputPath = 'assets/web/chromalib.mjs';
  final List<String> arguments = [
    '-O3',
    '-flto',
    '-msimd128',
    '-std=c11',
    '-DCMS_STATIC',
    '-DCMS_NO_HALF_SUPPORT',
    '-DNDEBUG',
    '-Inative/include',
    '-I${littleCmsDirectory.absolute.path}${Platform.pathSeparator}include',
    '-I${littleCmsDirectory.absolute.path}${Platform.pathSeparator}src',
    'native/src/chromalib.c',
    ...sources,
    '-sMODULARIZE=1',
    '-sEXPORT_ES6=1',
    '-sEXPORT_NAME=createChromaLibModule',
    '-sENVIRONMENT=web,worker',
    '-sFILESYSTEM=0',
    '-sALLOW_MEMORY_GROWTH=1',
    '-sINITIAL_MEMORY=16777216',
    '-sMAXIMUM_MEMORY=4294967296',
    '-sASSERTIONS=0',
    '-sEXPORTED_RUNTIME_METHODS=["UTF8ToString","HEAPU8"]',
    '-sEXPORTED_FUNCTIONS=["_malloc","_free","_chromalib_transform_create","_chromalib_transform_is_valid","_chromalib_transform_apply","_chromalib_transform_error","_chromalib_transform_destroy","_chromalib_abi_version","_chromalib_version"]',
    '-o',
    outputPath,
  ];
  log?.call(
    'Building Little CMS $littleCmsVersion for WebAssembly...',
  );
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: packageRoot.path,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  for (final String fileName in webLibraryFileNames) {
    if (!File('${outputDirectory.path}${Platform.pathSeparator}$fileName').existsSync()) {
      throw StateError('Emscripten did not produce $fileName.');
    }
  }
  log?.call('Built ChromaLib Web assets in ${outputDirectory.path}.');
}

/// Verifies the compiler used for reproducible published artifacts.
Future<void> _verifyEmscriptenVersion(String executable) async {
  final ProcessResult result = await Process.run(
    executable,
    const ['--version'],
  );
  final String output = '${result.stdout}\n${result.stderr}';
  if (result.exitCode != 0 || !output.contains('Emscripten') || !output.contains(' $emscriptenVersion ')) {
    throw StateError(
      'ChromaLib Web assets require Emscripten $emscriptenVersion. Compiler output: $output',
    );
  }
}

/// Builds Web assets when invoked by a package maintainer.
Future<void> main(List<String> arguments) async {
  if (arguments.length > 1 || (arguments.isNotEmpty && !arguments.single.startsWith('--compiler='))) {
    stderr.writeln(
      'Usage: dart run tool/web_library_builder.dart [--compiler=/path/to/emcc]',
    );
    exitCode = 64;
    return;
  }
  final String? compiler = arguments.isEmpty ? null : arguments.single.substring('--compiler='.length);
  try {
    final Directory packageRoot = File.fromUri(Platform.script).parent.parent;
    await buildWebLibrary(
      packageRoot: packageRoot,
      compiler: compiler,
      log: stdout.writeln,
    );
  } on Object catch (error) {
    stderr.writeln('Could not build ChromaLib Web assets: $error');
    exitCode = 1;
  }
}
