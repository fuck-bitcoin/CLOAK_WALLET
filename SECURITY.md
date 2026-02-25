# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

### How to Report

1. **Email**: Contact the maintainers directly (see repository)
2. **Private disclosure**: Use GitHub's private vulnerability reporting if available

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Initial response**: Within 48 hours
- **Status update**: Within 7 days
- **Resolution target**: Within 30 days for critical issues

### What to Expect

1. Acknowledgment of your report
2. Assessment of severity and impact
3. Development of a fix
4. Coordinated disclosure (if applicable)
5. Credit in the release notes (unless you prefer anonymity)

## Security Best Practices for Users

### Wallet Security

- **Backup your seed phrase** securely offline
- **Never share** your private keys or seed phrase
- **Verify downloads** using provided SHA256 checksums
- **Keep software updated** to the latest version

### Installation Security

- Download only from official sources (GitHub releases)
- Verify checksums before installation:
  ```bash
  sha256sum -c SHA256SUMS
  ```

### Privacy Considerations

- CLOAK uses shielded transactions for privacy
- Transaction details are encrypted on-chain
- Local database is encrypted with SQLCipher

## Known Security Measures

- **SQLCipher encryption** for local database
- **SHA256 verification** on all downloads
- **No private key transmission** over network
- **View-only mode** for monitoring without signing capability
- **mkcert SSL certificates** for secure local WebSocket connections

## Scope

This security policy covers:

- CLOAK Wallet application
- Official installers and release artifacts
- ZK parameter files

Out of scope:

- Third-party dependencies (report to respective projects)
- User's system security
- Network infrastructure
