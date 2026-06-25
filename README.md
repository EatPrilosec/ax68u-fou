# RT-AX68U FOU Kernel Module (Automated Build)

Automated CI/CD pipeline that cross-compiles the **`fou.ko`** (Foo over UDP) kernel module for the [Asuswrt-Merlin](https://github.com/RMerl/asuswrt-merlin.ng) firmware, targeting the **ASUS RT-AX68U** router (Broadcom BCM4906 / HND / aarch64).

## What Is FOU?

**Foo over UDP** (FOU) is a lightweight UDP encapsulation protocol in the Linux kernel (`net/ipv4/fou.c`). It allows tunneling of IP-in-UDP and GUE (Generic UDP Encapsulation) packets with minimal overhead. This is useful for:

- WireGuard/IPsec offloading through NAT
- Lightweight IP tunneling without full GRE overhead
- UDP-based encapsulation for transit networks

The stock Asuswrt-Merlin firmware does **not** include `fou.ko` — this project compiles it from the same kernel source used by the firmware so it can be loaded at runtime.

## How It Works

A GitHub Actions workflow runs weekly (and on manual trigger) to:

1. **Check** the [RMerl/asuswrt-merlin.ng](https://github.com/RMerl/asuswrt-merlin.ng) repo for the latest `3004.388.x` release tag
2. **Skip** the build if we already have a release for that tag
3. **Clone** the Merlin source tree and the [am-toolchains](https://github.com/RMerl/am-toolchains) repo
4. **Configure** the kernel with `CONFIG_NET_FOU=m` and `CONFIG_NET_UDP_TUNNEL=m`
5. **Cross-compile** the kernel modules using the Broadcom aarch64 toolchain
6. **Publish** a GitHub Release with the compiled `.ko` files

## Using the Module on Your Router

### Prerequisites

- ASUS RT-AX68U running Asuswrt-Merlin firmware (388.x branch)
- SSH access to the router
- A USB drive formatted with ext4 (for persistent storage)

### Automated Installation & Updates (Recommended)

Run this single command over SSH on your router to install the autoupdater. It will automatically download the correct modules for your firmware, configure auto-loading on boot, schedule a job (`cru`) to check for updates every 3 hours, prepare modules for your next firmware upgrade, and keep one backup version:

```bash
curl -sL https://raw.githubusercontent.com/EatPrilosec/ax68u-fou/main/scripts/fou-autoupdate.sh -o /jffs/scripts/fou-autoupdate.sh && chmod +x /jffs/scripts/fou-autoupdate.sh && /jffs/scripts/fou-autoupdate.sh install
```

To verify they loaded successfully:
```bash
lsmod | grep -E 'fou|udp_tunnel'
```

### Manual Installation

1. Download the `.ko` files from the [Releases](../../releases) page matching your firmware version.

2. Copy the modules to your router via SCP:
   ```bash
   scp *.ko admin@192.168.1.1:/jffs/modules/
   ```

3. Load the modules (order matters):
   ```bash
   ssh admin@192.168.1.1
   insmod /jffs/modules/udp_tunnel.ko
   insmod /jffs/modules/fou.ko
   ```

4. Verify they loaded:
   ```bash
   lsmod | grep -E 'fou|udp_tunnel'
   ```

### Auto-Load on Boot

Add to `/jffs/scripts/services-start` (create if it doesn't exist):
```bash
#!/bin/sh
insmod /jffs/modules/udp_tunnel.ko
insmod /jffs/modules/fou.ko
```

Make it executable:
```bash
chmod +x /jffs/scripts/services-start
```

## Manual Trigger

You can trigger a build manually from the **Actions** tab → **Build FOU Module** → **Run workflow**.

## Architecture Details

| Property          | Value                                            |
|-------------------|--------------------------------------------------|
| Router Model      | ASUS RT-AX68U                                    |
| SoC               | Broadcom BCM4906 (aarch64)                       |
| Platform          | HND (High-speed Network Device)                  |
| Source Directory   | `release/src-rt-5.02L.07p2axhnd`                 |
| Kernel Version    | Linux 4.1.x                                      |
| Toolchain         | `crosstools-aarch64-gcc-5.5-linux-4.1-glibc-2.26`|
| Firmware Branch   | 3004.388.x                                       |

## License

MIT — see [LICENSE](LICENSE).

The Asuswrt-Merlin firmware source and toolchains are subject to their own licenses.
