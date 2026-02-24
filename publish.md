# How to publish new versions

The target audience for this doc are the maintainers.

Most of the work is automated by Github CI and build scripts.
They drop several artifacts for each release. To produce a new release,
tag a commit with `v*`, i.e. `v2.0.0+1000` following the `pubspec.yaml`
version format with a prefix `v`.

You should have these files:
- app-fdroid.aab
- app-fdroid.apk
- libzeos_caterpillar.so
- CLOAK-Wallet-x86_64.AppImage
- CLOAK-Wallet.dmg
- cloak-wallet.flatpak
- CLOAK-Wallet.msix
- cloak-wallet.zip
- zwallet.tgz

## Android
The android package `app-fdroid.aab` is auto-published as an Internal Release. Just test it and promote to Production.

`app-fdroid.apk` is a standalone installation package for users who don't have access to the Google Play Store.

## iOS
iOS build has to be made manually.

```
cd zwallet
./codegen.sh
flutter build ipa
```

Then use the `Transporter` app to upload the IPA to the store. Wait 5 mn for its processing and then test.
If OK, submit a new release.

## macOS
`CLOAK-Wallet.dmg` is a universal DMG that can be installed on Intel and Apple chip macs.

## Linux
`CLOAK-Wallet-x86_64.AppImage` is an appimage. Make it executable and then run.
`cloak-wallet.flatpak` is a flatpak. Install it `flatpak install cloak-wallet.flatpak` and then run.

To update the Flathub version:
- Edit `misc/app.cloak.wallet.yml` and change the path to `libzeos_caterpillar.so` and `zwallet.tgz`
- Edit the SHA256 checksum. It can be calculated using `shasum -a 256` (the files must be downloaded first)
- Edit the build version and date/time
- Create a branch
- Push and then open a PR
- Check that flathub bot builds correctly
- Then merge/squash
- Flathub should build and publish the new version automatically

## Windows
Upload `CLOAK-Wallet.msix` to the Microsoft Developer Portal. Submit an update to CLOAK Wallet.
- Remove the old msix
- Save
- Add the new msix
- Save
- Submit

`cloak-wallet.zip` is a portable version that doesn't require installation.
