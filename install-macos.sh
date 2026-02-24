#!/usr/bin/env bash
set -euo pipefail

# CLOAK Wallet Installer for macOS
# Usage: curl -sSL https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install-macos.sh | bash
#
# Environment variables:
#   CLOAK_VERSION     - Release tag to install (default: "latest")
#   CLOAK_SKIP_PARAMS - Set to "1" to skip ZK parameter download

VERSION="${CLOAK_VERSION:-latest}"
SKIP_PARAMS="${CLOAK_SKIP_PARAMS:-0}"
REPO="fuck-bitcoin/CLOAK_WALLET"
APP_NAME="CLOAK Wallet"
PARAMS_DIR="$HOME/Library/Application Support/cloak-wallet/params"

PARAMS_VERSION="params-v1"
PARAMS_BASE_URL="https://github.com/${REPO}/releases/download/${PARAMS_VERSION}"

PARAM_FILES=(
    "mint.params"
    "output.params"
    "spend.params"
    "spend-output.params"
)

PARAM_SIZES_MB=(
    15    # mint.params
    3     # output.params
    182   # spend.params
    183   # spend-output.params
)

TOTAL_PARAMS_MB=383

# ── Helpers ───────────────────────────────────────────────────────────────────

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "  $*"
}

# macOS ships shasum, not sha256sum
sha256sum() {
    shasum -a 256 "$@"
}

# ── Banner ────────────────────────────────────────────────────────────────────

echo ""
echo "  ██████╗██╗      ██████╗  █████╗ ██╗  ██╗"
echo " ██╔════╝██║     ██╔═══██╗██╔══██╗██║ ██╔╝"
echo " ██║     ██║     ██║   ██║███████║█████╔╝ "
echo " ██║     ██║     ██║   ██║██╔══██║██╔═██╗ "
echo " ╚██████╗███████╗╚██████╔╝██║  ██║██║  ██╗"
echo "  ╚═════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝"
echo ""
echo "  CLOAK Wallet Installer for macOS"
echo ""

# ── macOS Version Check ──────────────────────────────────────────────────────

MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "0.0")
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)

# macOS 11+ (Big Sur) required
if [ "$MACOS_MAJOR" -lt 11 ] 2>/dev/null; then
    die "macOS 11 (Big Sur) or later is required. Detected: macOS $MACOS_VERSION"
fi

info "macOS $MACOS_VERSION detected."

# ── Architecture Detection ────────────────────────────────────────────────────

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)
        DMG_NAME="CLOAK_Wallet-macos-arm64.dmg"
        info "Architecture: Apple Silicon (arm64)"
        ;;
    x86_64)
        DMG_NAME="CLOAK_Wallet-macos-arm64.dmg"
        info "Architecture: Intel (x86_64) — using ARM64 build via Rosetta 2"
        if ! /usr/bin/pgrep -q oahd 2>/dev/null; then
            echo ""
            echo "  NOTE: CLOAK Wallet is built for Apple Silicon (arm64)."
            echo "  On Intel Macs, it runs via Rosetta 2."
            echo "  If Rosetta 2 is not installed, macOS will prompt you to install it"
            echo "  when you first launch the app."
            echo ""
        fi
        ;;
    *)
        die "Unsupported architecture: $ARCH. CLOAK Wallet supports arm64 and x86_64."
        ;;
esac

# ── Download URLs ─────────────────────────────────────────────────────────────

if [ "$VERSION" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${DMG_NAME}"
    CHECKSUM_URL="https://github.com/${REPO}/releases/latest/download/SHA256SUMS-macos"
else
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${DMG_NAME}"
    CHECKSUM_URL="https://github.com/${REPO}/releases/download/${VERSION}/SHA256SUMS-macos"
fi

# ── Disk Space Check ─────────────────────────────────────────────────────────

# Need ~600 MB: ~50 MB for DMG + ~383 MB for ZK params + headroom
REQUIRED_MB=600
AVAILABLE_MB=$(df -m "$HOME" | tail -1 | awk '{print $4}')
if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
    die "Insufficient disk space. Need at least ${REQUIRED_MB} MB (app ~50 MB + ZK params ~${TOTAL_PARAMS_MB} MB). Available: ${AVAILABLE_MB} MB."
fi

info "Disk space: ${AVAILABLE_MB} MB available (need ~${REQUIRED_MB} MB)."
echo ""

# ── Download DMG ──────────────────────────────────────────────────────────────

TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT

DMG_PATH="$TMPDIR_DL/$DMG_NAME"

echo "Downloading CLOAK Wallet ($ARCH)..."
if ! curl -fL --progress-bar -C - "$DOWNLOAD_URL" -o "$DMG_PATH"; then
    die "Download failed. Check your internet connection and try again."
fi

# ── Verify Checksum ──────────────────────────────────────────────────────────

echo "Verifying integrity..."
CHECKSUMS=$(curl -fsSL "$CHECKSUM_URL") || die "Failed to download checksums."
EXPECTED=$(echo "$CHECKSUMS" | grep "$DMG_NAME" | awk '{print $1}')
ACTUAL=$(sha256sum "$DMG_PATH" | awk '{print $1}')

if [ -z "$EXPECTED" ]; then
    die "Could not find checksum for $DMG_NAME in SHA256SUMS."
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo ""
    echo "  Expected: $EXPECTED"
    echo "  Got:      $ACTUAL"
    echo ""
    die "Checksum mismatch! The download may be corrupted. Please try again."
fi
info "Checksum verified."
echo ""

# ── Mount DMG and Install ────────────────────────────────────────────────────

echo "Installing to /Applications..."

# Mount the DMG silently
MOUNT_OUTPUT=$(hdiutil attach "$DMG_PATH" -nobrowse -plist 2>/dev/null) \
    || die "Failed to mount DMG. The file may be corrupted."

# Extract mount point from plist output (handles spaces in volume names)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" \
    | grep -A1 '<key>mount-point</key>' \
    | tail -1 \
    | sed 's/.*<string>\(.*\)<\/string>.*/\1/')

if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    die "Failed to determine DMG mount point."
fi

# Remove previous installation if present
if [ -d "/Applications/${APP_NAME}.app" ]; then
    info "Removing previous installation..."
    rm -rf "/Applications/${APP_NAME}.app"
fi

# Copy .app to /Applications
if ! cp -R "$MOUNT_POINT/${APP_NAME}.app" "/Applications/" 2>/dev/null; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    die "Failed to copy app to /Applications/. You may need to run with sudo."
fi

# Unmount DMG
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true

# Strip quarantine attribute (bypass Gatekeeper for unsigned app)
xattr -cr "/Applications/${APP_NAME}.app" 2>/dev/null || true

info "App installed to /Applications/${APP_NAME}.app"
echo ""

# ── Download ZK Parameters ───────────────────────────────────────────────────

if [ "$SKIP_PARAMS" = "1" ]; then
    echo "Skipping ZK parameter download (CLOAK_SKIP_PARAMS=1)."
    echo ""
else
    # Check if params already exist and are complete
    PARAMS_COMPLETE=true
    for FILE in "${PARAM_FILES[@]}"; do
        if [ ! -f "$PARAMS_DIR/$FILE" ]; then
            PARAMS_COMPLETE=false
            break
        fi
    done

    if [ "$PARAMS_COMPLETE" = true ]; then
        info "ZK parameters already present at:"
        info "  $PARAMS_DIR"
        echo ""
    else
        echo "Downloading ZK proving parameters (~${TOTAL_PARAMS_MB} MB)..."
        echo "These are required for generating zero-knowledge proofs."
        echo ""

        mkdir -p "$PARAMS_DIR"

        # Download checksums for params
        PARAMS_CHECKSUMS=""
        if curl -fsSL "${PARAMS_BASE_URL}/SHA256SUMS" -o "$PARAMS_DIR/SHA256SUMS" 2>/dev/null; then
            PARAMS_CHECKSUMS=$(cat "$PARAMS_DIR/SHA256SUMS")
        fi

        DOWNLOADED=0
        for i in "${!PARAM_FILES[@]}"; do
            FILE="${PARAM_FILES[$i]}"
            SIZE_MB="${PARAM_SIZES_MB[$i]}"
            FILEPATH="$PARAMS_DIR/$FILE"
            DOWNLOADED=$((DOWNLOADED + 1))

            # Skip if already downloaded and verified
            if [ -f "$FILEPATH" ] && [ -n "$PARAMS_CHECKSUMS" ]; then
                FILE_EXPECTED=$(echo "$PARAMS_CHECKSUMS" | grep "$FILE" | awk '{print $1}')
                FILE_ACTUAL=$(sha256sum "$FILEPATH" | awk '{print $1}')
                if [ "$FILE_EXPECTED" = "$FILE_ACTUAL" ]; then
                    info "[$DOWNLOADED/${#PARAM_FILES[@]}] $FILE (~${SIZE_MB} MB) -- already verified, skipping."
                    continue
                fi
            fi

            echo "  [$DOWNLOADED/${#PARAM_FILES[@]}] Downloading $FILE (~${SIZE_MB} MB)..."

            # Download with resume support (-C -)
            if ! curl -fL --progress-bar -C - "${PARAMS_BASE_URL}/${FILE}" -o "$FILEPATH"; then
                echo ""
                echo "  WARNING: Failed to download $FILE."
                echo "  The wallet will attempt to download it on first launch."
                continue
            fi
        done

        # Verify all param checksums
        if [ -n "$PARAMS_CHECKSUMS" ]; then
            echo ""
            echo "Verifying ZK parameters..."
            PARAMS_OK=true
            for FILE in "${PARAM_FILES[@]}"; do
                FILEPATH="$PARAMS_DIR/$FILE"
                if [ ! -f "$FILEPATH" ]; then
                    continue
                fi
                FILE_EXPECTED=$(echo "$PARAMS_CHECKSUMS" | grep "$FILE" | awk '{print $1}')
                FILE_ACTUAL=$(sha256sum "$FILEPATH" | awk '{print $1}')
                if [ -n "$FILE_EXPECTED" ] && [ "$FILE_EXPECTED" != "$FILE_ACTUAL" ]; then
                    echo "  WARNING: Checksum mismatch for $FILE. Removing."
                    rm -f "$FILEPATH"
                    PARAMS_OK=false
                fi
            done

            if [ "$PARAMS_OK" = true ]; then
                info "All ZK parameters verified."
            else
                echo ""
                echo "  Some parameters failed verification and were removed."
                echo "  The wallet will re-download them on first launch."
            fi
        fi

        echo ""
    fi
fi

# ── Success ───────────────────────────────────────────────────────────────────

echo "============================================="
echo "  Installation complete!"
echo "============================================="
echo ""
echo "  App:    /Applications/${APP_NAME}.app"
echo "  Params: $PARAMS_DIR"
echo ""
echo "  To launch: open '/Applications/${APP_NAME}.app'"
echo "             or find CLOAK Wallet in Launchpad."
echo ""

# Check if Gatekeeper might still block
if spctl --assess --type execute "/Applications/${APP_NAME}.app" 2>&1 | grep -q "rejected"; then
    echo "  NOTE: Gatekeeper may block the app on first launch."
    echo "  If this happens:"
    echo "    1. Right-click the app and select 'Open'"
    echo "    2. Or go to System Settings > Privacy & Security"
    echo "       and click 'Open Anyway'"
    echo ""
fi

echo "  To uninstall:"
echo "    rm -rf '/Applications/${APP_NAME}.app'"
echo "    rm -rf '$PARAMS_DIR'"
echo ""
