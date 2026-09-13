@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

import '../tool/little_cms_downloader.dart';

void main() {
  test('recognizes the source files required by the build hook', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'chromalib-source-layout-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    await Directory('${temporary.path}/include').create();
    await Directory('${temporary.path}/src').create();
    await File('${temporary.path}/include/lcms2.h').writeAsString('header');

    check(hasLittleCmsSource(temporary)).isTrue();
  });

  test('rejects an escaping archive path before writing files', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'chromalib-unsafe-archive-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final Directory destination = Directory('${temporary.path}/output');
    final TarArchive archive = TarArchive(
      entries: [
        TarEntry(name: 'safe.txt', data: const [1]),
        TarEntry(name: '../outside.txt', data: const [2]),
      ],
    );

    await check(
      extractArchiveToDisk(archive, destination),
    ).throws<StateError>();
    check(destination.existsSync()).isFalse();
    check(File('${temporary.path}/outside.txt').existsSync()).isFalse();
  });
}
