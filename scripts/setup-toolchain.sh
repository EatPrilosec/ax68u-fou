#!/bin/bash
# setup-toolchain.sh — Configure the Broadcom HND cross-compilation toolchain
# for the RT-AX68U (BCM4906 / aarch64).
#
# Expects am-toolchains to be cloned at $TOOLCHAINS_DIR (default: ./am-toolchains).
# Exports PATH and LD_LIBRARY_PATH to $GITHUB_ENV for subsequent steps.

set -euo pipefail

readonly TOOLCHAINS_DIR="${TOOLCHAINS_DIR:-${GITHUB_WORKSPACE:-.}/am-toolchains}"
readonly HND_DIR="${TOOLCHAINS_DIR}/brcm-arm-hnd"
readonly TOOLCHAINS_INSTALL="/opt/toolchains"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "::notice::$*"  >&2; }
warn() { echo "::warning::$*" >&2; }
err()  { echo "::error::$*"   >&2; }

die() { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

# Find the aarch64 cross-compiler toolchain directory
find_aarch64_toolchain() {
    local pattern="crosstools-aarch64-gcc-*"
    local candidates

    candidates=$(find "$HND_DIR" -maxdepth 1 -type d -name "$pattern" | sort -V)

    if [[ -z "$candidates" ]]; then
        die "No aarch64 toolchain found matching '$pattern' in $HND_DIR"
    fi

    # Prefer the gcc-5.5 toolchain (matches kernel 4.1), fall back to whatever is available
    local preferred
    preferred=$(echo "$candidates" | grep 'gcc-5\.5' | head -1) || true

    if [[ -n "$preferred" ]]; then
        echo "$preferred"
    else
        warn "gcc-5.5 toolchain not found, using latest available"
        echo "$candidates" | tail -1
    fi
}

# Find the arm (32-bit) cross-compiler toolchain directory (needed for LD_LIBRARY_PATH)
find_arm_toolchain() {
    local pattern="crosstools-arm-gcc-*"
    local candidates

    candidates=$(find "$HND_DIR" -maxdepth 1 -type d -name "$pattern" | sort -V)

    if [[ -z "$candidates" ]]; then
        warn "No 32-bit ARM toolchain found matching '$pattern' — LD_LIBRARY_PATH may be incomplete"
        echo ""
        return 0
    fi

    # Prefer matching version to the aarch64 toolchain
    local preferred
    preferred=$(echo "$candidates" | grep 'gcc-5\.5' | head -1) || true

    if [[ -n "$preferred" ]]; then
        echo "$preferred"
    else
        echo "$candidates" | tail -1
    fi
}

# Validate that the cross-compiler is functional
validate_compiler() {
    local compiler="$1"

    if ! command -v "$compiler" &>/dev/null; then
        die "Cross-compiler '$compiler' not found in PATH"
    fi

    local version
    version=$("$compiler" --version 2>&1 | head -1) || die "Failed to get compiler version"
    log "Cross-compiler: $version"

    # Quick sanity check: try to compile a trivial program
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    cat > "$tmpdir/test.c" <<'EOF'
int main(void) { return 0; }
EOF

    if "$compiler" -o "$tmpdir/test" "$tmpdir/test.c" 2>/dev/null; then
        local arch
        arch=$(file "$tmpdir/test" | grep -oE 'ARM aarch64|aarch64|ARM' | head -1)
        log "Test compile successful (target: ${arch:-unknown})"
    else
        warn "Test compilation failed — this may cause issues during kernel build"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Setting up Broadcom HND toolchain for RT-AX68U..."

    # Verify am-toolchains exists
    if [[ ! -d "$HND_DIR" ]]; then
        die "Toolchains directory not found: $HND_DIR"
    fi

    # Find toolchains
    local aarch64_dir
    aarch64_dir=$(find_aarch64_toolchain)
    log "aarch64 toolchain: $(basename "$aarch64_dir")"

    local arm_dir
    arm_dir=$(find_arm_toolchain)
    if [[ -n "$arm_dir" ]]; then
        log "ARM toolchain: $(basename "$arm_dir")"
    fi

    # Create /opt/toolchains symlink (needs sudo on GitHub Actions runners)
    if [[ ! -e "$TOOLCHAINS_INSTALL" ]]; then
        log "Creating symlink: $TOOLCHAINS_INSTALL → $HND_DIR"
        sudo ln -sf "$HND_DIR" "$TOOLCHAINS_INSTALL"
    fi

    # Build PATH additions
    local new_path="${aarch64_dir}/usr/bin"
    if [[ -n "$arm_dir" ]]; then
        new_path="${new_path}:${arm_dir}/usr/bin"
    fi

    # Build LD_LIBRARY_PATH additions
    local new_ld_path=""
    if [[ -n "$arm_dir" ]]; then
        new_ld_path="${arm_dir}/usr/lib"
    fi

    # Export to GITHUB_ENV for subsequent steps
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "PATH=${new_path}:${PATH}" >> "$GITHUB_ENV"
        if [[ -n "$new_ld_path" ]]; then
            echo "LD_LIBRARY_PATH=${new_ld_path}:${LD_LIBRARY_PATH:-}" >> "$GITHUB_ENV"
        fi
    fi

    # Also export for the current script (for validation)
    export PATH="${new_path}:${PATH}"
    if [[ -n "$new_ld_path" ]]; then
        export LD_LIBRARY_PATH="${new_ld_path}:${LD_LIBRARY_PATH:-}"
    fi

    # Validate
    validate_compiler "aarch64-linux-gcc"

    log "Toolchain setup complete"
}

main "$@"
