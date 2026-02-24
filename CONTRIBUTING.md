# Contributing to CLOAK Wallet

## Getting Started

1. Fork the repository
2. Follow the [build from source](README.md#build-from-source) instructions in the README
3. Create a feature branch from `main`
4. Make your changes and test locally
5. Submit a pull request

## Development Setup

### Requirements

- **Flutter:** 3.22.2 (exact version -- other versions may not work)
- **Rust:** Stable toolchain, MSRV 1.80
- **Linux deps:** `clang cmake ninja-build libgtk-3-dev libssl-dev libsecret-1-dev libjsoncpp-dev libunwind-dev libudev-dev pkg-config`

### After Rust Changes

Every time you modify Rust code and rebuild:

1. Copy the `.so` / `.dylib` / `.dll` to the Flutter project:
   - Linux: `zwallet/linux/lib/` **and** `zwallet/build/linux/x64/debug/bundle/lib/`
2. Delete `zwallet/data/cloak.wallet` (the wallet file must be regenerated after native lib changes)

### Running Locally

```bash
cd zeos-caterpillar && cargo build --release && cd ..
cd zwallet
cp ../zeos-caterpillar/target/release/libzeos_caterpillar.so linux/lib/
flutter pub get && dart run build_runner build -d
(cd packages/cloak_api_ffi && flutter pub get)
flutter build linux --debug
```

## Code Style

- **Dart:** Follow existing patterns -- MobX observables, GoRouter navigation, dark theme
- **Rust:** Standard `rustfmt` formatting

## Pull Request Process

1. Keep PRs focused on a single change
2. Include a clear description of what the PR does and why
3. Test on at least one platform before submitting
4. Reference any related issues

## Security Vulnerabilities

If you discover a security vulnerability, **do NOT open a public issue**.

Report it privately via the process described in [SECURITY.md](SECURITY.md).

## What Not to Commit

- Wallet files (`.wallet`, `.db`)
- ZK parameters (`.params`)
- Keystores (`.jks`, `.keystore`)
- Environment files (`.env`)
- Native library binaries (`.so`, `.dylib`, `.dll`)
