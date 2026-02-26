#!/usr/bin/env bash
# =============================================================================
# CLOAK Wallet Installer for Linux
# =============================================================================
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install.sh | bash
#
# Environment variables (optional):
#   CLOAK_VERSION      - Release tag to install (default: "latest")
#   CLOAK_INSTALL_DIR  - Installation directory (default: ~/.local/share/cloak-wallet)
#   CLOAK_SKIP_PARAMS  - Set to "1" to skip ZK parameter download
#   CLOAK_PARAMS_DIR   - ZK params directory (default: ~/.local/share/cloak-wallet/params)
#
# Requirements:
#   - x86_64 Linux
#   - curl or wget
#   - sha256sum (coreutils)
#   - ~500 MB disk space (AppImage + ZK params)
#   - FUSE (for AppImage execution)
#
# Compatible with: bash 4+, zsh 5+
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -t 2 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

info()    { printf "${BLUE}[INFO]${NC}    %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}      %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}    %s\n" "$*" >&2; }
error()   { printf "${RED}[ERROR]${NC}   %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}${CYAN}==> %s${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VERSION="${CLOAK_VERSION:-latest}"
INSTALL_DIR="${CLOAK_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cloak-wallet}"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
PARAMS_DIR="${CLOAK_PARAMS_DIR:-$INSTALL_DIR/params}"
SKIP_PARAMS="${CLOAK_SKIP_PARAMS:-0}"

REPO="fuck-bitcoin/CLOAK_WALLET"
APPIMAGE_NAME="CLOAK_Wallet-x86_64.AppImage"
PARAMS_VERSION="params-v1"
PARAMS_BASE_URL="https://github.com/${REPO}/releases/download/${PARAMS_VERSION}"

PARAM_FILES=("mint.params" "output.params" "spend.params" "spend-output.params")
PARAM_SIZES_MB=(15 3 182 183)
TOTAL_PARAMS_MB=383

# Temp directory for downloads (cleaned up on exit)
TMPDIR_INSTALL=""

# ---------------------------------------------------------------------------
# Cleanup handler
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "$TMPDIR_INSTALL" ] && [ -d "$TMPDIR_INSTALL" ]; then
        rm -rf "$TMPDIR_INSTALL"
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
    printf "\n"
    printf "${BOLD}"
    printf "  ██████╗██╗      ██████╗  █████╗ ██╗  ██╗\n"
    printf " ██╔════╝██║     ██╔═══██╗██╔══██╗██║ ██╔╝\n"
    printf " ██║     ██║     ██║   ██║███████║█████╔╝ \n"
    printf " ██║     ██║     ██║   ██║██╔══██║██╔═██╗ \n"
    printf " ╚██████╗███████╗╚██████╔╝██║  ██║██║  ██╗\n"
    printf "  ╚═════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝\n"
    printf "${NC}\n"
    printf "  ${BOLD}CLOAK Wallet Installer${NC}\n"
    printf "  ${DIM}Privacy wallet for Telos blockchain${NC}\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Utility: HTTP download
# ---------------------------------------------------------------------------
# Uses curl if available, falls back to wget. Supports resume (-C -).
_download() {
    local url="$1"
    local output="$2"
    local show_progress="${3:-0}"

    if command -v curl &>/dev/null; then
        if [ "$show_progress" = "1" ]; then
            curl -fL --progress-bar -C - "$url" -o "$output"
        else
            curl -fsSL -C - "$url" -o "$output"
        fi
    elif command -v wget &>/dev/null; then
        if [ "$show_progress" = "1" ]; then
            wget -c --show-progress -q "$url" -O "$output"
        else
            wget -c -q "$url" -O "$output"
        fi
    else
        error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Utility: compute SHA256
# ---------------------------------------------------------------------------
_sha256() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        error "No SHA256 tool found. Install coreutils."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Utility: available disk space in MB
# ---------------------------------------------------------------------------
_available_mb() {
    local path="$1"
    # Ensure the directory or its parent exists for df
    local check_path="$path"
    while [ ! -d "$check_path" ]; do
        check_path="$(dirname "$check_path")"
    done
    df -m "$check_path" 2>/dev/null | tail -1 | awk '{print $4}'
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    step "Running preflight checks"

    # Architecture
    local arch
    arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        error "CLOAK Wallet currently only supports x86_64 (amd64)."
        error "Detected architecture: $arch"
        exit 1
    fi
    success "Architecture: x86_64"

    # OS
    if [ "$(uname -s)" != "Linux" ]; then
        error "This installer is for Linux only."
        error "Detected OS: $(uname -s)"
        exit 1
    fi
    success "Operating system: Linux"

    # curl or wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        error "Neither curl nor wget found."
        error "Install one of them:"
        error "  Ubuntu/Debian: sudo apt install curl"
        error "  Fedora:        sudo dnf install curl"
        exit 1
    fi
    if command -v curl &>/dev/null; then
        success "Downloader: curl"
    else
        success "Downloader: wget"
    fi

    # sha256sum
    if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
        error "No SHA256 tool found. Install coreutils."
        exit 1
    fi
    success "SHA256 verification: available"

    # FUSE check (warning only -- user may install later)
    if ! command -v fusermount &>/dev/null && ! command -v fusermount3 &>/dev/null && ! [ -e /dev/fuse ]; then
        warn "FUSE not detected. AppImage requires FUSE to run."
        warn "Install it with:"
        warn "  Ubuntu/Debian: sudo apt install libfuse2"
        warn "  Fedora:        sudo dnf install fuse-libs"
        warn "  Arch:          sudo pacman -S fuse2"
        printf "\n"
    else
        success "FUSE: available"
    fi

    # Disk space -- need ~500MB for AppImage + params
    local required_mb=500
    local available
    available="$(_available_mb "$HOME")"
    if [ -n "$available" ] && [ "$available" -lt "$required_mb" ] 2>/dev/null; then
        error "Insufficient disk space."
        error "Required: ~${required_mb} MB (AppImage + ZK parameters)"
        error "Available: ${available} MB in $HOME"
        exit 1
    fi
    if [ -n "$available" ]; then
        success "Disk space: ${available} MB available"
    fi
}

# ---------------------------------------------------------------------------
# Detect existing installation
# ---------------------------------------------------------------------------
check_existing() {
    if [ -f "$INSTALL_DIR/$APPIMAGE_NAME" ]; then
        step "Existing installation detected"
        info "Location: $INSTALL_DIR/$APPIMAGE_NAME"

        # Try to get version from filename or just note it exists
        printf "\n"
        printf "  ${BOLD}An existing CLOAK Wallet installation was found.${NC}\n"
        printf "  This will upgrade/reinstall the application.\n"
        printf "  Your wallet data and ZK parameters will be preserved.\n"
        printf "\n"

        # When piped from curl, stdin is the script itself, so we can't
        # prompt interactively. Just proceed with the upgrade.
        info "Proceeding with upgrade..."
        printf "\n"
    fi
}

# ---------------------------------------------------------------------------
# Download and verify AppImage
# ---------------------------------------------------------------------------
install_appimage() {
    step "Downloading CLOAK Wallet"

    # Create temp directory
    TMPDIR_INSTALL="$(mktemp -d)"

    # Determine download URL
    local download_url checksum_url
    if [ "$VERSION" = "latest" ]; then
        download_url="https://github.com/${REPO}/releases/latest/download/${APPIMAGE_NAME}"
        checksum_url="https://github.com/${REPO}/releases/latest/download/SHA256SUMS-linux"
    else
        download_url="https://github.com/${REPO}/releases/download/${VERSION}/${APPIMAGE_NAME}"
        checksum_url="https://github.com/${REPO}/releases/download/${VERSION}/SHA256SUMS-linux"
    fi

    info "Version: $VERSION"
    info "Source:  github.com/${REPO}"
    printf "\n"

    # Download AppImage to temp
    info "Downloading AppImage..."
    _download "$download_url" "$TMPDIR_INSTALL/$APPIMAGE_NAME" 1

    # Download checksums
    info "Downloading checksums..."
    _download "$checksum_url" "$TMPDIR_INSTALL/SHA256SUMS" 0

    # Verify checksum
    step "Verifying integrity"
    local expected actual
    expected="$(grep "$APPIMAGE_NAME" "$TMPDIR_INSTALL/SHA256SUMS" | awk '{print $1}')"
    actual="$(_sha256 "$TMPDIR_INSTALL/$APPIMAGE_NAME")"

    if [ -z "$expected" ]; then
        error "Could not find checksum for $APPIMAGE_NAME in SHA256SUMS."
        error "The release may be misconfigured."
        exit 1
    fi

    if [ "$expected" != "$actual" ]; then
        error "Checksum verification FAILED!"
        error "  Expected: $expected"
        error "  Got:      $actual"
        error ""
        error "The download may be corrupted or tampered with."
        error "Please try again. If the problem persists, report it at:"
        error "  https://github.com/${REPO}/issues"
        exit 1
    fi
    success "SHA256 checksum verified"

    # Move to install directory
    mkdir -p "$INSTALL_DIR"
    mv "$TMPDIR_INSTALL/$APPIMAGE_NAME" "$INSTALL_DIR/$APPIMAGE_NAME"
    chmod +x "$INSTALL_DIR/$APPIMAGE_NAME"
    success "Installed to $INSTALL_DIR/$APPIMAGE_NAME"
}

# ---------------------------------------------------------------------------
# Create symlink in PATH
# ---------------------------------------------------------------------------
install_symlink() {
    step "Creating command-line launcher"

    mkdir -p "$BIN_DIR"

    # Write a wrapper script (not a symlink) so GDK_BACKEND=x11 is set
    # before the AppImage runs. This prevents black-screen on Wayland.
    cat > "$BIN_DIR/cloak-wallet" << WRAPPER_EOF
#!/bin/bash
export GDK_BACKEND=x11
exec "$INSTALL_DIR/$APPIMAGE_NAME" "\$@"
WRAPPER_EOF
    chmod +x "$BIN_DIR/cloak-wallet"
    success "Launcher: $BIN_DIR/cloak-wallet"

    # Check if BIN_DIR is in PATH
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            warn "$BIN_DIR is not in your PATH."
            warn "Add it to your shell profile:"
            warn "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
            warn "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Install desktop entry and icon
# ---------------------------------------------------------------------------
install_desktop_entry() {
    step "Installing desktop integration"

    mkdir -p "$DESKTOP_DIR" "$ICON_DIR"

    # Extract icon from AppImage
    local icon_installed=0
    local extract_dir
    extract_dir="$(mktemp -d)"

    if "$INSTALL_DIR/$APPIMAGE_NAME" --appimage-extract usr/share/icons 2>/dev/null; then
        if [ -f "squashfs-root/usr/share/icons/hicolor/256x256/apps/app.cloak.wallet.png" ]; then
            cp "squashfs-root/usr/share/icons/hicolor/256x256/apps/app.cloak.wallet.png" \
                "$ICON_DIR/cloak-wallet.png"
            icon_installed=1
        fi
        rm -rf squashfs-root
    fi

    # Fallback: download icon directly
    if [ "$icon_installed" = "0" ]; then
        info "Downloading icon..."
        _download "https://github.com/${REPO}/raw/main/assets/icon.png" \
            "$ICON_DIR/cloak-wallet.png" 0 2>/dev/null || true
    fi

    if [ -f "$ICON_DIR/cloak-wallet.png" ]; then
        success "Icon installed"
    else
        warn "Could not install icon (non-fatal)"
    fi

    # Refresh icon cache. Remove any auto-generated local index.theme that
    # shadows the system hicolor index.theme (only lists local dirs, which
    # hides all system app icons).
    local hicolor_base="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
    rm -f "$hicolor_base/index.theme" "$hicolor_base/icon-theme.cache" 2>/dev/null || true
    if command -v gtk4-update-icon-cache &>/dev/null; then
        gtk4-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true
    elif command -v gtk-update-icon-cache &>/dev/null; then
        gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true
    fi

    # Detect Wayland for GDK_BACKEND hint
    local exec_line="$INSTALL_DIR/$APPIMAGE_NAME %U"
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        # On Wayland, set GDK_BACKEND=x11 for always-on-top support via XWayland
        exec_line="env GDK_BACKEND=x11 $INSTALL_DIR/$APPIMAGE_NAME %U"
        info "Wayland detected: desktop entry will use GDK_BACKEND=x11 (XWayland)"
    fi

    # Write desktop entry
    cat > "$DESKTOP_DIR/app.cloak.wallet.desktop" << DESKTOP_EOF
[Desktop Entry]
Name=CLOAK Wallet
GenericName=Privacy Wallet
Comment=Privacy wallet for CLOAK on Telos blockchain using zk-SNARKs
Exec=$exec_line
Terminal=false
Type=Application
Icon=cloak-wallet
Categories=Office;Finance;
MimeType=x-scheme-handler/cloak;
StartupWMClass=cloak-wallet
DESKTOP_EOF

    # Validate and update desktop database
    if command -v desktop-file-validate &>/dev/null; then
        desktop-file-validate "$DESKTOP_DIR/app.cloak.wallet.desktop" 2>/dev/null || true
    fi
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi

    success "Desktop entry installed"
}

# ---------------------------------------------------------------------------
# Install mkcert for web authentication
# ---------------------------------------------------------------------------
install_mkcert() {
    step "Setting up web authentication certificates"

    local mkcert_path="$HOME/.local/bin/mkcert"

    # Check if mkcert already installed
    if command -v mkcert &>/dev/null; then
        success "mkcert already installed (system)"
        mkcert -install 2>/dev/null || true
        return 0
    fi

    if [ -f "$mkcert_path" ]; then
        success "mkcert already installed at $mkcert_path"
        "$mkcert_path" -install 2>/dev/null || true
        return 0
    fi

    # Determine architecture
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)
            local mkcert_bin="mkcert-v1.4.4-linux-amd64"
            ;;
        aarch64|arm64)
            local mkcert_bin="mkcert-v1.4.4-linux-arm64"
            ;;
        armv7l|armhf)
            local mkcert_bin="mkcert-v1.4.4-linux-arm"
            ;;
        *)
            warn "Unsupported architecture for mkcert: $arch"
            warn "Web authentication may require manual browser setup."
            return 0
            ;;
    esac

    local mkcert_url="https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/${mkcert_bin}"

    info "Downloading mkcert..."
    mkdir -p "$HOME/.local/bin"

    if _download "$mkcert_url" "$mkcert_path" 0 2>/dev/null; then
        chmod +x "$mkcert_path"
        success "mkcert installed to $mkcert_path"

        # Install the CA
        info "Installing local CA for secure browser connections..."
        if "$mkcert_path" -install 2>/dev/null; then
            success "Local CA installed"
            info "Web authentication with app.cloak.today will work automatically."
        else
            warn "CA installation may require libnss3-tools."
            warn "Install with: sudo apt install libnss3-tools"
            warn "Then run: $mkcert_path -install"
        fi

        # Generate SSL certificates for the wallet
        # AppImage apps may not be able to run external binaries
        generate_ssl_certs "$mkcert_path"
    else
        warn "Could not download mkcert."
        warn "Web authentication may require manual browser setup."
        warn "See README for browser-specific instructions."
    fi
}

# Generate SSL certificates using mkcert
generate_ssl_certs() {
    local mkcert_cmd="$1"
    local ssl_dir="$HOME/.local/share/cloak-wallet/ssl"

    mkdir -p "$ssl_dir"

    local cert_file="$ssl_dir/localhost+2.pem"
    local key_file="$ssl_dir/localhost+2-key.pem"
    local chain_file="$ssl_dir/localhost+2-chain.pem"

    info "Generating SSL certificates for web authentication..."
    if "$mkcert_cmd" -cert-file "$cert_file" -key-file "$key_file" localhost 127.0.0.1 ::1 2>/dev/null; then
        # Create chain file (cert + CA)
        local ca_root
        ca_root=$("$mkcert_cmd" -CAROOT 2>/dev/null)
        if [ -n "$ca_root" ] && [ -f "$ca_root/rootCA.pem" ]; then
            cat "$cert_file" "$ca_root/rootCA.pem" > "$chain_file"
        else
            cp "$cert_file" "$chain_file"
        fi
        success "SSL certificates generated"
    else
        warn "Could not generate SSL certificates."
        warn "The wallet will generate self-signed certificates on first run."
    fi
}

# ---------------------------------------------------------------------------
# Download ZK parameters
# ---------------------------------------------------------------------------
download_params() {
    if [ "$SKIP_PARAMS" = "1" ]; then
        info "Skipping ZK parameter download (CLOAK_SKIP_PARAMS=1)"
        return 0
    fi

    step "Downloading ZK proving parameters"
    info "These are required for generating zero-knowledge proofs."
    info "Total download: ~${TOTAL_PARAMS_MB} MB (4 files)"
    info "Target: $PARAMS_DIR"
    printf "\n"

    # Check disk space for params
    local available
    available="$(_available_mb "$PARAMS_DIR")"
    if [ -n "$available" ] && [ "$available" -lt "$TOTAL_PARAMS_MB" ] 2>/dev/null; then
        error "Insufficient disk space for ZK parameters."
        error "Required: ~${TOTAL_PARAMS_MB} MB"
        error "Available: ${available} MB"
        warn "You can download them later by running the installer again,"
        warn "or CLOAK Wallet will download them on first launch."
        return 0
    fi

    mkdir -p "$PARAMS_DIR"

    # Download param checksums
    info "Downloading param checksums..."
    _download "${PARAMS_BASE_URL}/SHA256SUMS" "$PARAMS_DIR/SHA256SUMS" 0

    # Download each param file
    local i file filepath expected actual downloaded=0
    for i in "${!PARAM_FILES[@]}"; do
        file="${PARAM_FILES[$i]}"
        filepath="$PARAMS_DIR/$file"

        # Check if file already exists and is valid
        if [ -f "$filepath" ]; then
            info "Verifying existing $file..."
            expected="$(grep -F "  $file" "$PARAMS_DIR/SHA256SUMS" | awk '{print $1}')"
            actual="$(_sha256 "$filepath")"
            if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
                success "$file already exists and is valid. Skipping."
                continue
            else
                warn "$file exists but checksum mismatch. Re-downloading."
                rm -f "$filepath"
            fi
        fi

        printf "\n"
        info "Downloading $file (~${PARAM_SIZES_MB[$i]} MB)..."
        if ! _download "${PARAMS_BASE_URL}/${file}" "$filepath" 1; then
            error "Failed to download $file."
            warn "You can retry later or let CLOAK Wallet download on first launch."
            rm -f "$filepath"
            return 0
        fi
        downloaded=$((downloaded + 1))
    done

    # Final verification
    printf "\n"
    info "Verifying all parameters..."

    local all_ok=1
    for file in "${PARAM_FILES[@]}"; do
        filepath="$PARAMS_DIR/$file"
        if [ ! -f "$filepath" ]; then
            # File was skipped (already valid) or download was partial
            continue
        fi
        expected="$(grep -F "  $file" "$PARAMS_DIR/SHA256SUMS" | awk '{print $1}')"
        actual="$(_sha256 "$filepath")"
        if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
            success "$file verified"
        else
            error "$file checksum FAILED"
            all_ok=0
        fi
    done

    if [ "$all_ok" = "1" ]; then
        success "All ZK parameters downloaded and verified"
    else
        error "Some parameters failed verification."
        error "Delete $PARAMS_DIR and run the installer again."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Create uninstall script
# ---------------------------------------------------------------------------
create_uninstall_script() {
    step "Creating uninstall script"

    # Uninstall script at the install directory (not in PATH to avoid accidents)
    local uninstall_path="$INSTALL_DIR/uninstall.sh"

    cat > "$uninstall_path" << 'UNINSTALL_HEADER'
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

printf "\n${BOLD}CLOAK Wallet Uninstaller${NC}\n\n"
UNINSTALL_HEADER

    # Write paths with actual values (expanded at install time)
    cat >> "$uninstall_path" << UNINSTALL_PATHS
INSTALL_DIR="$INSTALL_DIR"
BIN_DIR="$BIN_DIR"
DESKTOP_DIR="$DESKTOP_DIR"
ICON_DIR="$ICON_DIR"
PARAMS_DIR="$PARAMS_DIR"
UNINSTALL_PATHS

    cat >> "$uninstall_path" << 'UNINSTALL_BODY'

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cloak-wallet"

printf "This will completely remove CLOAK Wallet including:\n"
printf "  - AppImage and launcher\n"
printf "  - Desktop entry and icon\n"
printf "  - SSL certificates and mkcert CA\n"
printf "  - ZK parameters\n"
printf "  - Wallet data (wallet file, database)\n"
printf "\n"

# Confirm before nuking everything
if [ -t 0 ]; then
    printf "${RED}${BOLD}This will permanently delete your wallet. Continue? (y/N)${NC} "
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        printf "Cancelled.\n"
        exit 0
    fi
fi

printf "\nRemoving CLOAK Wallet...\n\n"

# Remove launcher script and uninstall command
rm -f "$BIN_DIR/cloak-wallet"
rm -f "$BIN_DIR/cloak-wallet-uninstall"
printf "  ${GREEN}✓${NC} Launcher removed\n"

# Remove desktop entry
rm -f "$DESKTOP_DIR/app.cloak.wallet.desktop"
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
fi
printf "  ${GREEN}✓${NC} Desktop entry removed\n"

# Remove icon and refresh cache
rm -f "$ICON_DIR/cloak-wallet.png"
rm -f "$ICON_DIR/app.cloak.wallet.png"
if command -v gtk-update-icon-cache &>/dev/null; then
    gtk-update-icon-cache -f -q "$(dirname "$(dirname "$(dirname "$ICON_DIR")")")" 2>/dev/null || true
fi
printf "  ${GREEN}✓${NC} Icon removed\n"

# Remove mkcert and CA
if [ -f "$BIN_DIR/mkcert" ]; then
    "$BIN_DIR/mkcert" -uninstall 2>/dev/null || true
    rm -f "$BIN_DIR/mkcert"
fi
MKCERT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mkcert"
rm -rf "$MKCERT_DIR" 2>/dev/null || true
printf "  ${GREEN}✓${NC} mkcert and CA removed\n"

# Remove SSL certificates
rm -rf "$DATA_DIR/ssl" 2>/dev/null || true
printf "  ${GREEN}✓${NC} SSL certificates removed\n"

# Remove ZK parameters
rm -rf "$PARAMS_DIR" 2>/dev/null || true
printf "  ${GREEN}✓${NC} ZK parameters removed\n"

# Remove wallet data
rm -f "$DATA_DIR/cloak.wallet" "$DATA_DIR/cloak.db" 2>/dev/null || true
printf "  ${GREEN}✓${NC} Wallet data removed\n"

# Remove AppImage and uninstall script
find "$INSTALL_DIR" -maxdepth 1 -name "*.AppImage" -delete 2>/dev/null || true
rm -f "$INSTALL_DIR/uninstall.sh"

# Clean up install directory
rm -rf "$INSTALL_DIR" 2>/dev/null || true
rm -rf "$DATA_DIR" 2>/dev/null || true
printf "  ${GREEN}✓${NC} Install directory removed\n"

printf "\n${GREEN}${BOLD}CLOAK Wallet completely removed.${NC}\n\n"
UNINSTALL_BODY

    chmod +x "$uninstall_path"

    # Also create a convenience symlink in BIN_DIR
    ln -sf "$uninstall_path" "$BIN_DIR/cloak-wallet-uninstall"

    success "Uninstall script: $uninstall_path"
    success "Uninstall command: cloak-wallet-uninstall"
}

# ---------------------------------------------------------------------------
# Print completion summary
# ---------------------------------------------------------------------------
print_summary() {
    printf "\n"
    printf "${GREEN}${BOLD}=============================================${NC}\n"
    printf "${GREEN}${BOLD}  Installation complete!${NC}\n"
    printf "${GREEN}${BOLD}=============================================${NC}\n"
    printf "\n"
    printf "  ${BOLD}AppImage:${NC}    $INSTALL_DIR/$APPIMAGE_NAME\n"
    printf "  ${BOLD}Command:${NC}     cloak-wallet\n"
    printf "  ${BOLD}Desktop:${NC}     Search for 'CLOAK Wallet' in your app launcher\n"

    if [ -d "$PARAMS_DIR" ] && [ -f "$PARAMS_DIR/spend.params" ]; then
        printf "  ${BOLD}ZK Params:${NC}   $PARAMS_DIR (verified)\n"
    else
        printf "  ${BOLD}ZK Params:${NC}   Will be downloaded on first launch (~383 MB)\n"
    fi

    printf "  ${BOLD}Uninstall:${NC}   cloak-wallet-uninstall\n"
    printf "\n"

    # PATH reminder
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            printf "  ${YELLOW}NOTE:${NC} Add ~/.local/bin to your PATH to use the 'cloak-wallet' command:\n"
            printf "    export PATH=\"\$HOME/.local/bin:\$PATH\"\n"
            printf "\n"
            ;;
    esac

    printf "  ${DIM}To inspect this script before running:${NC}\n"
    printf "  ${DIM}curl -sSL https://raw.githubusercontent.com/${REPO}/main/install.sh | less${NC}\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner
    preflight_checks
    check_existing
    install_appimage
    install_symlink
    install_desktop_entry
    install_mkcert
    download_params
    create_uninstall_script
    print_summary
}

main "$@"
