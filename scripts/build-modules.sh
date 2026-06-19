#!/bin/bash
# build-modules.sh — Cross-compile the FOU kernel module and its dependencies.
#
# Environment:
#   KERNEL_DIR      — Path to the prepared kernel source tree
#   CROSS_COMPILE   — Cross-compiler prefix (default: aarch64-linux-)

set -euo pipefail

readonly KERNEL_DIR="${KERNEL_DIR:?KERNEL_DIR must be set — run prepare-kernel.sh first}"
readonly CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-}"
readonly ARCH="arm64"
readonly NPROC=$(nproc 2>/dev/null || echo 2)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "::notice::$*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; >&2 echo "ERROR: $*"; }

die() { err "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Building FOU kernel modules..."
    log "  Kernel dir:     ${KERNEL_DIR}"
    log "  Cross-compile:  ${CROSS_COMPILE}"
    log "  Architecture:   ${ARCH}"
    log "  Parallel jobs:  ${NPROC}"

    # Verify kernel directory
    if [[ ! -f "${KERNEL_DIR}/.config" ]]; then
        die "No .config found in ${KERNEL_DIR} — run prepare-kernel.sh first"
    fi

    if [[ ! -f "${KERNEL_DIR}/Module.symvers" ]] && [[ ! -f "${KERNEL_DIR}/scripts/basic/fixdep" ]]; then
        warn "Module.symvers and/or fixdep not found — modules_prepare may not have completed"
    fi

    # Build the net/ipv4 modules (includes fou.ko and udp_tunnel.ko)
    log "Building net/ipv4 modules (includes fou.ko, udp_tunnel.ko)..."
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        KCONFIG_NOTIMESTAMP=1 \
        -j"$NPROC" \
        M=net/ipv4 \
        modules

    # Also attempt to build net/ipv6 fou6 if the config supports it
    log "Attempting to build net/ipv6 modules (fou6.ko, optional)..."
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        -j"$NPROC" \
        M=net/ipv6 \
        modules 2>/dev/null || warn "IPv6 module build skipped (not configured or not needed)"

    # Verify that fou.ko was actually built
    local fou_ko="${KERNEL_DIR}/net/ipv4/fou.ko"
    if [[ -f "$fou_ko" ]]; then
        log "✓ Successfully built: $(basename "$fou_ko") ($(du -h "$fou_ko" | cut -f1))"
    else
        die "Build completed but fou.ko was not produced at ${fou_ko}"
    fi

    # Check for udp_tunnel.ko
    local udp_tunnel_ko="${KERNEL_DIR}/net/ipv4/udp_tunnel.ko"
    if [[ -f "$udp_tunnel_ko" ]]; then
        log "✓ Successfully built: $(basename "$udp_tunnel_ko") ($(du -h "$udp_tunnel_ko" | cut -f1))"
    else
        warn "udp_tunnel.ko was not produced — it may be built-in or located elsewhere"
    fi

    log "Module build complete"
}

main "$@"
