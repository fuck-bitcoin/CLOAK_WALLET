class SemanticVersion implements Comparable<SemanticVersion> {
  final int major;
  final int minor;
  final int patch;
  final List<String> preRelease;

  const SemanticVersion(
    this.major,
    this.minor,
    this.patch, [
    this.preRelease = const [],
  ]);

  factory SemanticVersion.parse(String input) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(input.trim());
    if (match == null) {
      throw FormatException('Invalid semantic version: $input');
    }
    return SemanticVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4)?.split('.') ?? const [],
    );
  }

  bool get isStable => preRelease.isEmpty;

  @override
  int compareTo(SemanticVersion other) {
    for (final pair in <(int, int)>[
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final comparison = pair.$1.compareTo(pair.$2);
      if (comparison != 0) return comparison;
    }
    if (preRelease.isEmpty && other.preRelease.isNotEmpty) return 1;
    if (preRelease.isNotEmpty && other.preRelease.isEmpty) return -1;
    for (var index = 0;
        index < preRelease.length && index < other.preRelease.length;
        index++) {
      final left = preRelease[index];
      final right = other.preRelease[index];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      int comparison;
      if (leftNumber != null && rightNumber != null) {
        comparison = leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null) {
        comparison = -1;
      } else if (rightNumber != null) {
        comparison = 1;
      } else {
        comparison = left.compareTo(right);
      }
      if (comparison != 0) return comparison;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }

  @override
  String toString() {
    final suffix = preRelease.isEmpty ? '' : '-${preRelease.join('.')}';
    return '$major.$minor.$patch$suffix';
  }
}

class UpdateAsset {
  final String name;
  final String platform;
  final String architecture;
  final Uri url;
  final int size;
  final String sha256;

  const UpdateAsset({
    required this.name,
    required this.platform,
    required this.architecture,
    required this.url,
    required this.size,
    required this.sha256,
  });

  factory UpdateAsset.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Update asset must be an object');
    }
    final name = value['name'];
    final platform = value['platform'];
    final architecture = value['architecture'];
    final urlValue = value['url'];
    final size = value['size'];
    final hash = value['sha256'];
    if (name is! String ||
        name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        platform is! String ||
        !const {'windows', 'macos', 'android', 'linux'}.contains(platform) ||
        architecture is! String ||
        !const {'x64', 'arm64', 'universal'}.contains(architecture) ||
        urlValue is! String ||
        size is! int ||
        size <= 0 ||
        hash is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const FormatException('Malformed update asset');
    }
    final url = Uri.tryParse(urlValue);
    if (url == null || url.scheme != 'https' || url.host != 'github.com') {
      throw const FormatException('Update asset must use github.com HTTPS');
    }
    return UpdateAsset(
      name: name,
      platform: platform,
      architecture: architecture,
      url: url,
      size: size,
      sha256: hash.toLowerCase(),
    );
  }
}

class UpdateManifestV1 {
  final SemanticVersion version;
  final int build;
  final String tag;
  final String commit;
  final DateTime issuedAt;
  final SemanticVersion minimumUpdaterVersion;
  final String requiredParameterGeneration;
  final String notes;
  final Map<String, UpdateAsset> assets;

  const UpdateManifestV1({
    required this.version,
    required this.build,
    required this.tag,
    required this.commit,
    required this.issuedAt,
    required this.minimumUpdaterVersion,
    required this.requiredParameterGeneration,
    required this.notes,
    required this.assets,
  });

  factory UpdateManifestV1.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['schema'] != 1) {
      throw const FormatException('Unsupported update manifest schema');
    }
    final versionValue = value['version'];
    final build = value['build'];
    final tag = value['tag'];
    final commit = value['commit'];
    final issuedAtValue = value['issuedAt'];
    final minimumValue = value['minimumUpdaterVersion'];
    final parameterGeneration = value['requiredParameterGeneration'];
    final notes = value['notes'] ?? '';
    final assetsValue = value['assets'];
    if (versionValue is! String ||
        build is! int ||
        build <= 0 ||
        tag is! String ||
        commit is! String ||
        !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(commit) ||
        issuedAtValue is! String ||
        minimumValue is! String ||
        parameterGeneration is! String ||
        !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(parameterGeneration) ||
        notes is! String ||
        assetsValue is! Map<String, dynamic>) {
      throw const FormatException('Malformed update manifest');
    }

    final version = SemanticVersion.parse(versionValue);
    final minimum = SemanticVersion.parse(minimumValue);
    final issuedAt = DateTime.tryParse(issuedAtValue)?.toUtc();
    if (!version.isStable ||
        !minimum.isStable ||
        tag != 'v$version' ||
        issuedAt == null ||
        build !=
            version.major * 1000000 + version.minor * 1000 + version.patch) {
      throw const FormatException('Invalid stable release metadata');
    }

    final assets = <String, UpdateAsset>{};
    for (final entry in assetsValue.entries) {
      final asset = UpdateAsset.fromJson(entry.value);
      final expectedTarget = '${asset.platform}-${asset.architecture}';
      if (entry.key != expectedTarget) {
        throw const FormatException(
          'Asset platform and architecture do not match its target key',
        );
      }
      final expectedPath =
          '/fuck-bitcoin/CLOAK_WALLET/releases/download/$tag/${asset.name}';
      if (asset.url.path != expectedPath ||
          asset.url.hasQuery ||
          asset.url.hasFragment ||
          asset.url.hasPort ||
          asset.url.userInfo.isNotEmpty) {
        throw const FormatException(
            'Asset URL is not an immutable CLOAK release');
      }
      assets[entry.key] = asset;
    }
    if (assets.isEmpty) {
      throw const FormatException('Update manifest has no assets');
    }

    return UpdateManifestV1(
      version: version,
      build: build,
      tag: tag,
      commit: commit.toLowerCase(),
      issuedAt: issuedAt,
      minimumUpdaterVersion: minimum,
      requiredParameterGeneration: parameterGeneration,
      notes: notes,
      assets: Map.unmodifiable(assets),
    );
  }

  UpdateAsset? assetFor(String target) => assets[target];

  bool supportsParameterGeneration(String generation) =>
      requiredParameterGeneration == generation;
}
