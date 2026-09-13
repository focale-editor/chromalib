import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import '../tool/little_cms_downloader.dart';

/// Builds the bundled Little CMS engine as a Dart code asset.
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final String packageRoot = input.packageRoot.toFilePath();
    final Directory packageLittleCmsDirectory = Directory(
      '${packageRoot}native/third_party/lcms2',
    );
    final Directory littleCmsDirectory =
        hasLittleCmsSource(
          packageLittleCmsDirectory,
        )
        ? packageLittleCmsDirectory
        : await installLittleCms(
            Directory.fromUri(
              input.outputDirectoryShared.resolve(
                'lcms2-$littleCmsVersion/',
              ),
            ),
            log: stdout.writeln,
          );
    final Directory sourceDirectory = Directory(
      '${littleCmsDirectory.path}${Platform.pathSeparator}src',
    );
    output.dependencies.add(littleCmsDirectory.uri);
    final List<String> sources = sourceDirectory.listSync().whereType<File>().where((file) => file.path.endsWith('.c')).map((file) => file.path).toList()..sort();
    final bool windows = input.config.code.targetOS == OS.windows;
    final List<String> allSources = [
      '${packageRoot}native/src/chromalib.c',
      ...sources,
    ];
    final List<String> includes = [
      '${packageRoot}native/include',
      '${littleCmsDirectory.path}${Platform.pathSeparator}include',
      '${littleCmsDirectory.path}${Platform.pathSeparator}src',
    ];
    final bool buildHostLinuxDirectly = Platform.isLinux && input.config.code.targetOS == OS.linux && input.config.code.targetArchitecture == Architecture.current;
    if (buildHostLinuxDirectly) {
      await _buildHostLinux(
        input: input,
        output: output,
        sources: allSources,
        includes: includes,
      );
    } else {
      await CBuilder.library(
        name: 'chromalib',
        assetName: 'src/native/bindings.dart',
        sources: allSources,
        includes: includes,
        defines: const {
          'CMS_STATIC': null,
          'CMS_NO_HALF_SUPPORT': null,
          'NDEBUG': null,
        },
        flags: windows ? const [] : const ['-fvisibility=hidden'],
        language: Language.c,
        std: 'c11',
      ).run(input: input, output: output);
    }
    output.dependencies.addAll(
      Directory('${packageRoot}native').listSync(recursive: true).whereType<File>().map((file) => file.uri),
    );
  });
}

/// Builds a host Linux asset without losing the compiler name behind ccache.
Future<void> _buildHostLinux({
  required BuildInput input,
  required BuildOutputBuilder output,
  required List<String> sources,
  required List<String> includes,
}) async {
  final String compiler = _findRealLinuxCompiler();
  final Uri library = input.outputDirectory.resolve('libchromalib.so');
  await Directory.fromUri(input.outputDirectory).create(recursive: true);
  final List<String> arguments = [
    '-fPIC',
    '-std=c11',
    '-O3',
    '-fvisibility=hidden',
    '-DCMS_STATIC',
    '-DCMS_NO_HALF_SUPPORT',
    '-DNDEBUG',
    ...includes.map((directory) => '-I$directory'),
    ...sources,
    '-shared',
    '-o',
    library.toFilePath(),
    '-lm',
    r'-Wl,-rpath,$ORIGIN',
  ];
  final ProcessResult result = await Process.run(compiler, arguments);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw ProcessException(
      compiler,
      arguments,
      'Native ChromaLib compilation failed.',
      result.exitCode,
    );
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/native/bindings.dart',
      file: library,
      linkMode: DynamicLoadingBundled(),
    ),
  );
}

/// Finds a C compiler whose executable name identifies the real compiler.
String _findRealLinuxCompiler() {
  const List<String> candidates = [
    '/usr/bin/clang',
    '/usr/bin/gcc',
    '/bin/clang',
    '/bin/gcc',
  ];
  for (final String candidate in candidates) {
    final File file = File(candidate);
    if (file.existsSync() && !file.resolveSymbolicLinksSync().endsWith('/ccache')) {
      return candidate;
    }
  }
  throw StateError(
    'The configured compiler resolves to ccache without a compiler name, and '
    'no real clang or gcc executable was found.',
  );
}
