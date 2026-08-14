import 'dart:io';

const String cloakUpdateRepository = 'fuck-bitcoin/CLOAK_WALLET';

const String cloakUpdatePublicKey = String.fromEnvironment(
  'CLOAK_RELEASE_MANIFEST_PUBLIC_KEY',
);

const String cloakUpdateManifestUrl = String.fromEnvironment(
  'CLOAK_UPDATE_MANIFEST_URL',
  defaultValue:
      'https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest/download/update-v1.json',
);

const String cloakUpdateSignatureUrl = String.fromEnvironment(
  'CLOAK_UPDATE_SIGNATURE_URL',
  defaultValue:
      'https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/latest/download/update-v1.sig',
);

const Duration automaticUpdateCheckInterval = Duration(hours: 24);

String? currentUpdateTarget() {
  if (Platform.isWindows) return 'windows-x64';
  if (Platform.isMacOS) return 'macos-universal';
  if (Platform.isAndroid) return 'android-universal';
  if (Platform.isLinux) return 'linux-x64';
  return null;
}
