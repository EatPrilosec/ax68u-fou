#!/bin/bash
# prepare-kernel.sh — Prepare the Asuswrt-Merlin kernel source tree for module
# compilation. Locates the correct source directory, injects FOU kernel config
# options, and runs the minimum make targets needed for out-of-tree module builds.
#
# Environment:
#   MERLIN_SRC  — Path to the cloned asuswrt-merlin.ng repo (default: ./asuswrt-merlin.ng)

set -euo pipefail

readonly MERLIN_SRC="${MERLIN_SRC:-${GITHUB_WORKSPACE:-.}/asuswrt-merlin.ng}"
readonly CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-}"
readonly ARCH="arm64"

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

# Locate the HND SDK source directory for the RT-AX68U
# Tries several known directory patterns in order of likelihood.
find_src_rt_dir() {
    local base="${MERLIN_SRC}/release"
    local candidates=(
        "src-rt-5.02L.07p2axhnd"
        "src-rt-5.02axhnd"
        "src-rt-5.04axhnd.675x"
        "src-rt-5.04axhnd"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "${base}/${candidate}" ]]; then
            echo "${base}/${candidate}"
            return 0
        fi
    done

    # Fallback: glob for any src-rt-5.0* directory
    local found
    found=$(find "$base" -maxdepth 1 -type d -name 'src-rt-5.0*' | sort | head -1)
    if [[ -n "$found" ]]; then
        warn "Using fallback source directory: $(basename "$found")"
        echo "$found"
        return 0
    fi

    die "Could not find HND SDK source directory under ${base}/"
}

# Locate the kernel source directory within the SDK
find_kernel_dir() {
    local src_rt="$1"
    local candidates=(
        "${src_rt}/kernel/linux-4.1"
        "${src_rt}/kernel/linux-4.19"
        "${src_rt}/linux/linux-4.1"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Fallback: glob
    local found
    found=$(find "$src_rt" -maxdepth 2 -type d -name 'linux-4.*' | sort | head -1)
    if [[ -n "$found" ]]; then
        warn "Using fallback kernel directory: $found"
        echo "$found"
        return 0
    fi

    die "Could not find kernel source directory under ${src_rt}/"
}

# Locate the RT-AX68U defconfig or .config
find_defconfig() {
    local kernel_dir="$1"
    local src_rt="$2"

    # Try common defconfig locations
    local candidates=(
        "${kernel_dir}/arch/${ARCH}/configs/bcm94906_defconfig"
        "${kernel_dir}/arch/${ARCH}/configs/bcm_94906_defconfig"
        "${kernel_dir}/arch/${ARCH}/configs/rt-ax68u_defconfig"
        "${src_rt}/targets/94906GW/94906GW"
        "${kernel_dir}/.config"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Fallback: look for any bcm4906* or 94906* config
    local found
    found=$(find "$kernel_dir/arch/${ARCH}/configs" "$src_rt/targets" \
        -maxdepth 3 -type f \( -name '*4906*' -o -name '*94906*' \) 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        warn "Using fallback defconfig: $found"
        echo "$found"
        return 0
    fi

    echo ""
}

# Inject FOU-related config options into the kernel .config
inject_config() {
    local config_file="$1"

    log "Injecting FOU kernel config options into $(basename "$config_file")"

    local configs=(
        "CONFIG_NET_FOU=m"
        "CONFIG_NET_UDP_TUNNEL=m"
        "CONFIG_INET_UDP_DIAG=m"
    )

    for cfg in "${configs[@]}"; do
        local key="${cfg%%=*}"
        # Remove any existing setting for this key (enabled, module, or disabled)
        sed -i "/^${key}[= ]/d" "$config_file"
        sed -i "/^# ${key} is not set/d" "$config_file"
        # Append the desired setting
        echo "$cfg" >> "$config_file"
        log "  Set ${cfg}"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Preparing kernel source tree for FOU module compilation..."

    # Verify Merlin source exists
    if [[ ! -d "$MERLIN_SRC" ]]; then
        die "Merlin source directory not found: $MERLIN_SRC"
    fi

    # Find directories
    local src_rt_dir
    src_rt_dir=$(find_src_rt_dir)
    log "SDK directory: $(basename "$src_rt_dir")"

    local kernel_dir
    kernel_dir=$(find_kernel_dir "$src_rt_dir")
    log "Kernel directory: ${kernel_dir#${MERLIN_SRC}/}"

    # Handle defconfig / .config
    local defconfig
    defconfig=$(find_defconfig "$kernel_dir" "$src_rt_dir")

    if [[ -n "$defconfig" && ! -f "${kernel_dir}/.config" ]]; then
        log "Copying defconfig to .config: $(basename "$defconfig")"
        cp "$defconfig" "${kernel_dir}/.config"
    elif [[ -f "${kernel_dir}/.config" ]]; then
        log "Using existing .config"
    else
        warn "No defconfig found — generating minimal config with make defconfig"
        make -C "$kernel_dir" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig
    fi

    # Inject FOU config
    inject_config "${kernel_dir}/.config"

    # Run kernel preparation targets
    log "Running: make olddefconfig"
    make -C "$kernel_dir" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

    log "Running: make scripts"
    make -C "$kernel_dir" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" scripts

    log "Running: make modules_prepare"
    make -C "$kernel_dir" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" modules_prepare

    # Verify FOU is configured as a module
    if grep -q "CONFIG_NET_FOU=m" "${kernel_dir}/.config"; then
        log "✓ CONFIG_NET_FOU=m confirmed in .config"
    else
        die "CONFIG_NET_FOU=m not found in .config after preparation"
    fi

    # Export the kernel directory for subsequent scripts
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "KERNEL_DIR=${kernel_dir}" >> "$GITHUB_ENV"
        echo "SRC_RT_DIR=${src_rt_dir}" >> "$GITHUB_ENV"
    fi

    log "Kernel preparation complete: ${kernel_dir}"
}

main "$@"
