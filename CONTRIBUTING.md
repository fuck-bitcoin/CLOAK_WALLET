# Contributing to CLOAK Wallet

Thank you for your interest in contributing to CLOAK Wallet! This document provides guidelines and information for contributors.

## Getting Started

1. **Fork the repository** and clone your fork locally
2. **Set up the development environment** following the README
3. **Create a feature branch** from `main`

## Development Setup

### Prerequisites

- Flutter SDK 3.0+
- Rust toolchain (for cloak_api native library)
- Platform-specific tools (Xcode for macOS/iOS, Android Studio for Android)

### Building

```bash
# Get dependencies
flutter pub get

# Run in debug mode
flutter run

# Build release
flutter build linux --release
flutter build macos --release
flutter build windows --release
flutter build apk --release
```

## Code Style

- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart) guidelines
- Use `dart format` before committing
- Keep functions focused and small
- Add comments for complex logic

## Pull Request Process

1. **Create an issue first** for significant changes
2. **Keep PRs focused** - one feature or fix per PR
3. **Write descriptive commit messages**
4. **Test your changes** on relevant platforms
5. **Update documentation** if needed

### PR Checklist

- [ ] Code compiles without warnings
- [ ] Follows existing code style
- [ ] Tested on target platform(s)
- [ ] Documentation updated (if applicable)
- [ ] No secrets or credentials committed

## Reporting Issues

When reporting bugs:

- Use the issue template
- Include platform and version info
- Provide steps to reproduce
- Include relevant logs (sanitized of private data)

## Security

For security vulnerabilities, please see [SECURITY.md](SECURITY.md) for responsible disclosure guidelines.

## Code of Conduct

This project follows our [Code of Conduct](CODE_OF_CONDUCT.md). Please read it before participating.

## License

By contributing, you agree that your contributions will be licensed under the project's license.

## Questions?

Open a discussion or issue if you have questions about contributing.
