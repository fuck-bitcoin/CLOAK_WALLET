# Codegen
flutter pub get
flutter pub run build_runner build -d
pushd packages/cloak_api_ffi
flutter pub get
flutter pub run build_runner build -d
popd

# Build flutter
flutter build windows
cp runtime/* build/windows/x64/runner/release
cp target/release/zeos_caterpillar.dll build/windows/x64/runner/release

flutter pub run msix:create
mv build/windows/x64/runner/Release/CLOAK-Wallet.msix .

flutter build windows
cp runtime/* build/windows/x64/runner/Release
pushd build/windows/x64/runner
mv Release cloak-wallet
7z a ../../../../cloak-wallet.zip cloak-wallet
popd
