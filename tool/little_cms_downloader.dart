import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:zcodec/zcodec.dart';

/// Little CMS release compiled by ChromaLib's native build hook.
const String littleCmsVersion = '2.19.1';

/// File name of the pinned upstream source archive.
const String _archiveName = 'lcms2-$littleCmsVersion.tar.gz';

/// Expected SHA-256 digest of the pinned upstream source archive.
const String _archiveSha256 = 'bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8';

/// Maximum permitted compressed archive size.
const int _maximumArchiveBytes = 32 * 1024 * 1024;

/// Maximum permitted TAR size and cumulative stored payload size.
const int _maximumExpandedArchiveBytes = 128 * 1024 * 1024;

/// Upstream location of the pinned source archive.
final Uri _archiveUri = Uri.parse('https://github.com/mm2/Little-CMS/releases/download/lcms2.19.1/$_archiveName');

/// Reports whether [directory] contains the Little CMS source layout ChromaLib needs.
bool hasLittleCmsSource(Directory directory) {
  final String separator = Platform.pathSeparator;
  return File('${directory.path}${separator}include${separator}lcms2.h').existsSync() && Directory('${directory.path}${separator}src').existsSync();
}

/// Downloads the pinned Little CMS archive into [destination] after SHA-256 verification.
///
/// A valid existing installation is reused unless [force] is true. [log]
/// receives concise progress messages suitable for a command-line tool or a
/// Dart build hook. Concurrent installations into the same directory, such as
/// build hooks running for several targets, are serialized by a lock file.
Future<Directory> installLittleCms(
  Directory destination, {
  bool force = false,
  void Function(String message)? log,
}) async {
  if (hasLittleCmsSource(destination) && !force) {
    log?.call('Using Little CMS $littleCmsVersion from ${destination.path}.');
    return destination;
  }

  final Directory parent = destination.parent;
  await parent.create(recursive: true);
  // Append mode never truncates, so waiting processes do not touch the file.
  final RandomAccessFile lock = await File(
    '${parent.path}${Platform.pathSeparator}.chromalib-lcms2-$littleCmsVersion.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    if (hasLittleCmsSource(destination) && !force) {
      log?.call('Using Little CMS $littleCmsVersion from ${destination.path}.');
      return destination;
    }
    return await _installLocked(destination, log: log);
  } finally {
    await lock.close();
  }
}

/// Downloads, verifies, and atomically moves Little CMS into [destination].
///
/// The caller must hold the installation lock.
Future<Directory> _installLocked(
  Directory destination, {
  void Function(String message)? log,
}) async {
  final Directory temporaryDirectory = await destination.parent.createTemp(
    '.chromalib-lcms-',
  );
  try {
    final File archive = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}$_archiveName',
    );
    log?.call('Downloading Little CMS $littleCmsVersion...');
    final String checksum = await _download(archive);
    if (checksum != _archiveSha256) {
      throw StateError(
        'Little CMS checksum mismatch. Expected $_archiveSha256, got $checksum.',
      );
    }

    final Uint8List tarBytes = const GzipCodec(maxOutputBytes: _maximumExpandedArchiveBytes).decode(await archive.readAsBytes());
    final TarArchive extracted = const TarDecoder(
      limits: TarLimits(
        maxEntryBytes: _maximumExpandedArchiveBytes,
        maxTotalBytes: _maximumExpandedArchiveBytes,
      ),
    ).convert(tarBytes);
    await extractArchiveToDisk(extracted, temporaryDirectory);
    final Directory source = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}lcms2-$littleCmsVersion',
    );
    if (!hasLittleCmsSource(source)) {
      throw StateError('The downloaded archive has an unexpected layout.');
    }

    if (destination.existsSync()) {
      await destination.delete(recursive: true);
    }
    await source.rename(destination.path);
    log?.call('Installed Little CMS $littleCmsVersion in ${destination.path}.');
    return destination;
  } finally {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

/// Materializes [archive] below [destination] without following archive links.
///
/// Every entry is validated before the first write. Special device and FIFO
/// entries are rejected, hard links are copied as regular files, and only the
/// ordinary permission bits are restored on POSIX hosts.
Future<void> extractArchiveToDisk(TarArchive archive, Directory destination) => _TarArchiveExtractor(destination: destination).extract(archive);

/// Describes one hard link awaiting its regular-file target.
final class _PendingHardLink {
  /// Archive metadata that supplies permissions and the target name.
  final TarEntry entry;

  /// Absolute destination path of the copied hard link.
  final String path;

  /// Absolute path of the regular-file target.
  final String targetPath;

  /// Creates a deferred hard-link extraction operation.
  const _PendingHardLink({
    required this.entry,
    required this.path,
    required this.targetPath,
  });
}

/// Safely materializes TAR entries within one destination directory.
final class _TarArchiveExtractor {
  /// Destination root as an absolute path.
  final String _rootPath;

  /// Normalized archive paths used to reject duplicate entries.
  final Set<String> _entryPaths = <String>{};

  /// Extracted paths grouped by their ordinary POSIX permission bits.
  final Map<int, List<String>> _permissionPaths = <int, List<String>>{};

  /// Hard links waiting for their target files to be extracted.
  final List<_PendingHardLink> _pendingHardLinks = <_PendingHardLink>[];

  /// Creates an extractor rooted at [destination].
  _TarArchiveExtractor({required Directory destination}) : _rootPath = destination.absolute.path;

  /// Validates and extracts every entry in [archive].
  Future<void> extract(TarArchive archive) async {
    _prevalidate(archive);
    await _ensureDestinationRoot();
    for (final TarEntry entry in archive.entries) {
      await _extractEntry(entry);
    }
    await _extractHardLinks();
    await _applyPermissions();
  }

  /// Creates the destination root or rejects a pre-existing non-directory.
  Future<void> _ensureDestinationRoot() async {
    final FileSystemEntityType type = await FileSystemEntity.type(
      _rootPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await Directory(_rootPath).create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw StateError('The TAR extraction root is not a real directory.');
    }
  }

  /// Validates all entry paths and types before the first filesystem write.
  void _prevalidate(TarArchive archive) {
    for (final TarEntry entry in archive.entries) {
      final List<String> segments = _entrySegments(entry.name);
      final String key = _entryKey(segments);
      if (!_entryPaths.add(key)) {
        throw StateError(
          'The TAR archive contains duplicate path "${entry.name}".',
        );
      }
      switch (entry.type) {
        case TarEntryType.regular:
        case TarEntryType.hardLink:
        case TarEntryType.symbolicLink:
        case TarEntryType.directory:
        case TarEntryType.contiguous:
          break;
        case TarEntryType.characterDevice:
        case TarEntryType.blockDevice:
        case TarEntryType.fifo:
        case TarEntryType.unknown:
          throw StateError(
            'Unsupported TAR entry type ${entry.type.name} for "${entry.name}".',
          );
      }
      if (entry.type == TarEntryType.symbolicLink) {
        _resolveSymbolicLinkTarget(segments, entry.linkName);
      } else if (entry.type == TarEntryType.hardLink) {
        _entrySegments(entry.linkName);
      }
    }
  }

  /// Extracts one already validated [entry].
  Future<void> _extractEntry(TarEntry entry) async {
    final List<String> segments = _entrySegments(entry.name);
    final String path = _pathFor(segments);
    await _ensureParentDirectories(segments);
    switch (entry.type) {
      case TarEntryType.regular:
      case TarEntryType.contiguous:
        await _requireMissing(path, entry.name);
        await File(path).writeAsBytes(entry.data, flush: true);
        _recordPermissions(path, entry.mode);
      case TarEntryType.directory:
        final FileSystemEntityType existingType = await FileSystemEntity.type(
          path,
          followLinks: false,
        );
        if (existingType == FileSystemEntityType.notFound) {
          await Directory(path).create();
        } else if (existingType != FileSystemEntityType.directory) {
          throw StateError(
            'TAR directory "${entry.name}" conflicts with an existing path.',
          );
        }
        _recordPermissions(path, entry.mode);
      case TarEntryType.symbolicLink:
        await _requireMissing(path, entry.name);
        final String target = _normalizedSymbolicLinkTarget(
          segments,
          entry.linkName,
        );
        await Link(path).create(target);
      case TarEntryType.hardLink:
        await _requireMissing(path, entry.name);
        _pendingHardLinks.add(
          _PendingHardLink(
            entry: entry,
            path: path,
            targetPath: _pathFor(_entrySegments(entry.linkName)),
          ),
        );
      case TarEntryType.characterDevice:
      case TarEntryType.blockDevice:
      case TarEntryType.fifo:
      case TarEntryType.unknown:
        throw StateError('Unsupported TAR entry type ${entry.type.name}.');
    }
  }

  /// Creates safe parent directories for an entry described by [segments].
  Future<void> _ensureParentDirectories(List<String> segments) async {
    final List<String> parents = <String>[];
    for (final String segment in segments.take(segments.length - 1)) {
      parents.add(segment);
      final String path = _pathFor(parents);
      final FileSystemEntityType type = await FileSystemEntity.type(
        path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await Directory(path).create();
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('A TAR parent path is not a real directory: $path');
      }
    }
  }

  /// Copies deferred hard links once their targets are available.
  Future<void> _extractHardLinks() async {
    final List<_PendingHardLink> remaining = List<_PendingHardLink>.from(
      _pendingHardLinks,
    );
    while (remaining.isNotEmpty) {
      bool progressed = false;
      for (final _PendingHardLink link in List<_PendingHardLink>.from(
        remaining,
      )) {
        final FileSystemEntityType targetType = await FileSystemEntity.type(
          link.targetPath,
          followLinks: false,
        );
        if (targetType == FileSystemEntityType.notFound) {
          continue;
        }
        if (targetType != FileSystemEntityType.file) {
          throw StateError(
            'TAR hard-link target is not a regular file: ${link.entry.linkName}',
          );
        }
        await File(link.targetPath).copy(link.path);
        _recordPermissions(link.path, link.entry.mode);
        remaining.remove(link);
        progressed = true;
      }
      if (!progressed) {
        throw StateError(
          'TAR hard-link target is missing: ${remaining.first.entry.linkName}',
        );
      }
    }
  }

  /// Applies grouped ordinary permission bits on POSIX hosts.
  Future<void> _applyPermissions() async {
    if (Platform.isWindows) {
      return;
    }
    for (final MapEntry<int, List<String>> permission in _permissionPaths.entries) {
      final String mode = permission.key.toRadixString(8).padLeft(3, '0');
      final ProcessResult result = await Process.run('chmod', <String>[
        mode,
        ...permission.value,
      ]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'chmod',
          <String>[mode, ...permission.value],
          '${result.stdout}\n${result.stderr}',
          result.exitCode,
        );
      }
    }
  }

  /// Records the ordinary permission bits from [mode] for [path].
  void _recordPermissions(String path, int mode) {
    final int ordinaryMode = mode & 0x1ff;
    _permissionPaths.putIfAbsent(ordinaryMode, () => <String>[]).add(path);
  }

  /// Rejects an existing filesystem object at [path].
  Future<void> _requireMissing(String path, String archiveName) async {
    final FileSystemEntityType type = await FileSystemEntity.type(
      path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound) {
      throw StateError(
        'TAR entry "$archiveName" conflicts with an existing path.',
      );
    }
  }

  /// Converts an archive [name] into validated path segments.
  List<String> _entrySegments(String name) {
    if (name.startsWith('/') || name.startsWith(r'\')) {
      throw StateError('TAR path must be relative: $name');
    }
    final List<String> segments = <String>[];
    for (final String segment in name.replaceAll(r'\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..' || (segments.isEmpty && segment.contains(':'))) {
        throw StateError('Unsafe TAR path: $name');
      }
      segments.add(segment);
    }
    if (segments.isEmpty) {
      throw StateError('TAR path resolves to the extraction root: $name');
    }
    return segments;
  }

  /// Verifies that symbolic [target] resolves within the extraction root.
  void _resolveSymbolicLinkTarget(List<String> entrySegments, String target) {
    _normalizedSymbolicLinkTarget(entrySegments, target);
  }

  /// Normalizes symbolic [target] relative to [entrySegments].
  String _normalizedSymbolicLinkTarget(
    List<String> entrySegments,
    String target,
  ) {
    if (target.startsWith('/') || target.startsWith(r'\')) {
      throw StateError('TAR symbolic link target must be relative: $target');
    }
    final List<String> resolved = List<String>.from(entrySegments)..removeLast();
    final List<String> normalizedTarget = <String>[];
    for (final String segment in target.replaceAll(r'\', '/').split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (normalizedTarget.isEmpty && segment.contains(':')) {
        throw StateError(
          'TAR symbolic link target contains a drive prefix: $target',
        );
      }
      if (segment == '..') {
        if (resolved.isEmpty) {
          throw StateError(
            'TAR symbolic link escapes the extraction root: $target',
          );
        }
        resolved.removeLast();
        normalizedTarget.add(segment);
      } else {
        resolved.add(segment);
        normalizedTarget.add(segment);
      }
    }
    if (normalizedTarget.isEmpty) {
      throw StateError('TAR symbolic link target is empty.');
    }
    return normalizedTarget.join(Platform.pathSeparator);
  }

  /// Returns the absolute filesystem path for [segments].
  String _pathFor(List<String> segments) => <String>[_rootPath, ...segments].join(Platform.pathSeparator);

  /// Returns a platform-aware duplicate-detection key for [segments].
  String _entryKey(List<String> segments) {
    final String key = segments.join('/');
    return Platform.isWindows ? key.toLowerCase() : key;
  }
}

/// Downloads the pinned archive into [destination] and returns its SHA-256.
Future<String> _download(File destination) async {
  final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final HttpClientRequest request = await client.getUrl(_archiveUri);
    request.followRedirects = true;
    request.maxRedirects = 8;
    request.headers.set(HttpHeaders.userAgentHeader, 'ChromaLib/0.1.0');
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'The Little CMS server returned HTTP ${response.statusCode}.',
        uri: _archiveUri,
      );
    }
    if (response.redirects.any(
      (redirect) => redirect.location.scheme != 'https',
    )) {
      await response.drain<void>();
      throw HttpException(
        'The Little CMS download redirected outside HTTPS.',
        uri: _archiveUri,
      );
    }

    final IOSink output = destination.openWrite();
    final _DigestCollector digests = _DigestCollector();
    final ByteConversionSink checksum = sha256.startChunkedConversion(digests);
    int receivedBytes = 0;
    try {
      await for (final List<int> chunk in response) {
        receivedBytes += chunk.length;
        if (receivedBytes > _maximumArchiveBytes) {
          throw StateError(
            'The Little CMS archive exceeds the $_maximumArchiveBytes-byte limit.',
          );
        }
        output.add(chunk);
        checksum.add(chunk);
      }
      checksum.close();
      await output.close();
      final Digest? digest = digests.value;
      if (digest == null) {
        throw StateError('The Little CMS checksum was not produced.');
      }
      return digest.toString();
    } on Object {
      await output.close();
      rethrow;
    }
  } finally {
    client.close(force: true);
  }
}

/// Receives the single digest emitted by the streaming SHA-256 converter.
final class _DigestCollector implements Sink<Digest> {
  /// The digest received from the converter.
  Digest? value;

  @override
  void add(Digest data) {
    if (value != null) {
      throw StateError('The Little CMS checksum was emitted more than once.');
    }
    value = data;
  }

  @override
  void close() {}
}
