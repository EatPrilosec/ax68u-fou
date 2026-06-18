#!/bin/bash
# collect-artifacts.sh — Gather compiled .ko files, strip debug symbols, and
# generate build metadata for the GitHub Release.
#
# Environment:
#   KERNEL_DIR      — Path to the kernel source tree with compiled modules
#   CROSS_COMPILE   — Cross-compiler prefix (default: aarch64-linux-)
#   UPSTREAM_TAG    — The upstream Merlin tag this build corresponds to
#   ARTIFACTS_DIR   — Output directory for collected artifacts (default: ./artifacts)

set -euo pipefail

readonly KERNEL_DIR="${KERNEL_DIR:?KERNEL_DIR must be set}"
readonly CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-}"
readonly UPSTREAM_TAG="${UPSTREAM_TAG:-unknown}"
readonly ARTIFACTS_DIR="${ARTIFACTS_DIR:-${GITHUB_WORKSPACE:-.}/artifacts}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "::notice::$*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; >&2 echo "ERROR: $*"; }

die() { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

# Strip debug symbols from a .ko file using the cross-toolchain strip
strip_module() {
    local ko_file="$1"
    local strip_cmd="${CROSS_COMPILE}strip"

    if command -v "$strip_cmd" &>/dev/null; then
        log "Stripping debug symbols: $(basename "$ko_file")"
        local before_size
        before_size=$(stat -c%s "$ko_file")

        "$strip_cmd" --strip-debug "$ko_file"

        local after_size
        after_size=$(stat -c%s "$ko_file")
        log "  ${before_size} → ${after_size} bytes ($(( (before_size - after_size) * 100 / before_size ))% reduction)"
    else
        warn "Cross-strip not found ($strip_cmd) — skipping debug symbol stripping"
    fi
}

# Extract vermagic string from a .ko file
get_vermagic() {
    local ko_file="$1"

    if command -v modinfo &>/dev/null; then
        modinfo -F vermagic "$ko_file" 2>/dev/null || echo "unknown"
    else
        # Fallback: extract from the binary
        strings "$ko_file" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+ .*' | head -1 || echo "unknown"
    fi
}

# Generate the build-info.txt metadata file
generate_build_info() {
    local output="$1"
    local fou_ko="$2"

    local compiler_version
    compiler_version=$("${CROSS_COMPILE}gcc" --version 2>&1 | head -1) || compiler_version="unknown"

    local kernel_version
    kernel_version=$(make -C "$KERNEL_DIR" -s kernelversion 2>/dev/null) || kernel_version="unknown"

    local vermagic
    vermagic=$(get_vermagic "$fou_ko")

    cat > "$output" <<EOF
=== FOU Kernel Module Build Info ===

Build Date:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Upstream Tag:      ${UPSTREAM_TAG}
Router Model:      ASUS RT-AX68U
SoC:               Broadcom BCM4906 (aarch64)
Platform:          HND (src-rt-5.02L.07p2axhnd)

Kernel Version:    ${kernel_version}
Vermagic:          ${vermagic}
Compiler:          ${compiler_version}

Modules Included:
EOF

    # List all .ko files in artifacts
    for ko in "$ARTIFACTS_DIR"/*.ko; do
        if [[ -f "$ko" ]]; then
            local size
            size=$(du -h "$ko" | cut -f1)
            echo "  - $(basename "$ko") (${size})" >> "$output"
        fi
    done

    cat >> "$output" <<'EOF'

=== Loading Instructions ===

1. Copy modules to your router:
   scp *.ko admin@<router_ip>:/jffs/modules/

2. Load modules (order matters):
   insmod /jffs/modules/udp_tunnel.ko
   insmod /jffs/modules/fou.ko

3. Verify:
   lsmod | grep -E 'fou|udp_tunnel'

NOTE: The vermagic string must match your running kernel exactly.
      If you get "invalid module format", your firmware version
      does not match this build.
EOF

    log "Generated build info: $output"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Collecting build artifacts..."

    # Create artifacts directory
    mkdir -p "$ARTIFACTS_DIR"

    # Define the modules we're looking for
    local -a module_paths=(
        "${KERNEL_DIR}/net/ipv4/fou.ko"
        "${KERNEL_DIR}/net/ipv4/udp_tunnel.ko"
        "${KERNEL_DIR}/net/ipv6/fou6.ko"
    )

    local found_any=false

    for mod_path in "${module_paths[@]}"; do
        if [[ -f "$mod_path" ]]; then
            local basename
            basename=$(basename "$mod_path")
            cp "$mod_path" "${ARTIFACTS_DIR}/${basename}"
            strip_module "${ARTIFACTS_DIR}/${basename}"
            found_any=true
            log "✓ Collected: ${basename}"
        fi
    done

    # Also search for any other .ko files in net/ipv4 that might be dependencies
    while IFS= read -r -d '' ko_file; do
        local basename
        basename=$(basename "$ko_file")
        # Skip if already collected
        if [[ ! -f "${ARTIFACTS_DIR}/${basename}" ]]; then
            # Only collect tunnel-related modules
            if [[ "$basename" =~ (tunnel|encap|gue) ]]; then
                cp "$ko_file" "${ARTIFACTS_DIR}/${basename}"
                strip_module "${ARTIFACTS_DIR}/${basename}"
                log "✓ Collected (additional): ${basename}"
            fi
        fi
    done < <(find "${KERNEL_DIR}/net" -name '*.ko' -print0 2>/dev/null)

    if [[ "$found_any" != "true" ]]; then
        die "No .ko files were found to collect"
    fi

    # Verify fou.ko specifically
    if [[ ! -f "${ARTIFACTS_DIR}/fou.ko" ]]; then
        die "fou.ko not found in artifacts — build may have failed"
    fi

    # Generate build info
    generate_build_info "${ARTIFACTS_DIR}/build-info.txt" "${ARTIFACTS_DIR}/fou.ko"

    # List final artifacts
    log "=== Final Artifacts ==="
    ls -lh "$ARTIFACTS_DIR"/
    log "======================"
}

main "$@"
