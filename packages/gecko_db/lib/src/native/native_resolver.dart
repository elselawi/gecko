/// Pure-Dart native artifact resolver (Phase 1 foundation).
///
/// The resolver chooses a checksum-verified native artifact without requiring a
/// consumer compiler toolchain. Actual `DynamicLibrary.open` is intentionally
/// outside this class so search, verification, caching, and download behavior
/// remain deterministic and unit-testable.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../errors/errors.dart';

/// A pinned native artifact descriptor.
class NativeArtifact {
  const NativeArtifact({
    required this.version,
    required this.sha256,
    this.bundledPath,
    this.downloadUri,
  });

  final String version;
  final String sha256;
  final String? bundledPath;
  final Uri? downloadUri;

  String get cacheKey => '$version-$sha256';
}

/// Filesystem seam for deterministic resolver tests.
abstract interface class ResolverStorage {
  bool exists(String path);
  List<int> read(String path);
  void write(String path, List<int> bytes);
  void createDirectory(String path);
}

/// HTTP seam for deterministic resolver tests.
abstract interface class ResolverDownloader {
  Future<List<int>> download(Uri uri);
}

/// Real local filesystem implementation.
class LocalResolverStorage implements ResolverStorage {
  const LocalResolverStorage();

  @override
  bool exists(String path) => File(path).existsSync();

  @override
  List<int> read(String path) => File(path).readAsBytesSync();

  @override
  void write(String path, List<int> bytes) =>
      File(path).writeAsBytesSync(bytes);

  @override
  void createDirectory(String path) =>
      Directory(path).createSync(recursive: true);
}

/// Default HTTP implementation using `dart:io`.
class IoResolverDownloader implements ResolverDownloader {
  const IoResolverDownloader();

  @override
  Future<List<int>> download(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw GeckoError(
          GeckoErrorType.invalidOperation,
          'Native artifact download failed with HTTP ${response.statusCode}',
          details: <String, Object?>{'uri': uri.toString()},
        );
      }
      return response.fold<List<int>>(
        <int>[],
        (out, chunk) => out..addAll(chunk),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// Resolves a pinned native artifact path.
class NativeResolver {
  NativeResolver({
    ResolverStorage? storage,
    ResolverDownloader? downloader,
    String? cacheDirectory,
    String? overridePaths,
  }) : _storage = storage ?? const LocalResolverStorage(),
       _downloader = downloader ?? const IoResolverDownloader(),
       cacheDirectory =
           cacheDirectory ??
           '${Directory.systemTemp.path}${Platform.pathSeparator}gecko_db_native',
       overridePaths =
           overridePaths ?? Platform.environment['GECKO_DB_RESOLVER_PATHS'];

  final ResolverStorage _storage;
  final ResolverDownloader _downloader;
  final String cacheDirectory;
  final String? overridePaths;

  /// Resolves in override/local paths, then bundled artifact, then pinned URL.
  Future<String> resolve(
    NativeArtifact artifact, {
    List<String> localPaths = const [],
  }) async {
    final candidates = <String>[..._splitPaths(overridePaths), ...localPaths];
    for (final path in candidates) {
      if (_isValid(path, artifact)) return path;
    }

    final cached = _cachePath(artifact);
    if (_isValid(cached, artifact)) return cached;

    if (artifact.bundledPath != null &&
        _isValid(artifact.bundledPath!, artifact)) {
      return artifact.bundledPath!;
    }

    final uri = artifact.downloadUri;
    if (uri == null) {
      throw GeckoError(
        GeckoErrorType.invalidOperation,
        'No valid native artifact found and no pinned download URL exists',
        details: <String, Object?>{'version': artifact.version},
      );
    }
    final bytes = await _downloader.download(uri);
    _verify(bytes, artifact);
    _storage.createDirectory(cacheDirectory);
    _storage.write(cached, bytes);
    return cached;
  }

  bool _isValid(String path, NativeArtifact artifact) {
    if (!_storage.exists(path)) return false;
    try {
      _verify(_storage.read(path), artifact);
      return true;
    } on GeckoError {
      return false;
    }
  }

  void _verify(List<int> bytes, NativeArtifact artifact) {
    final actual = sha256.convert(bytes).toString().toLowerCase();
    if (actual != artifact.sha256.toLowerCase()) {
      throw GeckoError(
        GeckoErrorType.checksumMismatch,
        'Native artifact checksum mismatch',
        details: <String, Object?>{
          'expected': artifact.sha256,
          'actual': actual,
          'version': artifact.version,
        },
      );
    }
  }

  String _cachePath(NativeArtifact artifact) =>
      '$cacheDirectory${Platform.pathSeparator}${artifact.cacheKey}';

  static List<String> _splitPaths(String? value) =>
      value == null || value.isEmpty
      ? const []
      : value
            .split(Platform.isWindows ? ';' : ':')
            .where((p) => p.isNotEmpty)
            .toList();
}

/// Computes the pinned SHA-256 string for fixtures/manifests.
String nativeArtifactSha256(List<int> bytes) =>
    sha256.convert(bytes).toString();

/// Stable JSON representation useful for release manifests.
String nativeArtifactManifest(NativeArtifact artifact) =>
    jsonEncode(<String, Object?>{
      'version': artifact.version,
      'sha256': artifact.sha256,
      if (artifact.bundledPath != null) 'bundledPath': artifact.bundledPath,
      if (artifact.downloadUri != null)
        'downloadUri': artifact.downloadUri.toString(),
    });
