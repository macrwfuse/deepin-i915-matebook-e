#!/bin/bash
# Install a rebuilt i915.ko on Deepin 25.3.0 (ostree / deepin-immutable-ctl).
#
#   sudo ./install-i915.sh [path/to/i915.ko[.zst]]
#
# Default input is i915.ko.zst next to this script.
# Everything that touches /usr or /lib runs through `deepin-immutable-ctl admin
# exec` so it lands in the modification layer instead of failing with EROFS.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KVER="6.18.56-amd64-desktop-rolling"
KO=${1:-$HERE/i915.ko.zst}
MODDIR="/lib/modules/$KVER/kernel/drivers/gpu/drm/i915"
BACKUP="i915.ko.zst.orig-25.3.0"

[ -f "$KO" ] || { echo "missing $KO"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo $0)"; exit 1; }
command -v deepin-immutable-ctl >/dev/null || {
  echo "deepin-immutable-ctl not found - is this Deepin 25.3?" >&2; exit 1; }

# An uncompressed input is accepted; compress here so the tree always ends up
# zstd, matching CONFIG_MODULE_COMPRESS_ZSTD=y + MODULE_COMPRESS_ALL=y.
case "$KO" in
  *.zst) ;;
  *.ko)  command -v zstd >/dev/null || { echo "zstd missing (apt install zstd)" >&2; exit 1; }
         zstd -19 -f -q "$KO" -o "$KO.zst"; KO="$KO.zst" ;;
  *)     echo "expected i915.ko or i915.ko.zst, got $KO" >&2; exit 1 ;;
esac

# Unsigned module under Secure Boot: LOCK_DOWN_IN_EFI_SECURE_BOOT=y refuses it.
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  cat <<'EOM'
Secure Boot is ENABLED. The Deepin kernel is built with LOCK_DOWN_IN_EFI_SECURE_BOOT=y
and MODULE_SIG_FORCE is NOT set, so an unsigned module is refused under lockdown
(not EKEYREJECTED). Either disable Secure Boot in firmware or sign the module with
your own MOK key (scripts/sign-file + mokutil --import).
EOM
  read -r -p "Continue anyway? [y/N] " a; [ "$a" = y ] || exit 1
fi

IMM() { deepin-immutable-ctl admin exec -- "$@"; }

IMM test -f "$MODDIR/i915.ko.zst" || {
  echo "$MODDIR/i915.ko.zst not found - unexpected module layout" >&2; exit 1; }
IMM bash -c "[ -f $MODDIR/$BACKUP ] || cp -a $MODDIR/i915.ko.zst $MODDIR/$BACKUP"
IMM install -m 0644 "$KO" "$MODDIR/i915.ko.zst"
IMM depmod -a "$KVER"
IMM update-initramfs -u -k "$KVER"

cat <<EOM

Installed into the immutable layer:
  $MODDIR/i915.ko.zst          (new)
  $MODDIR/$BACKUP  (original)

Reboot to take effect. Afterwards check, in this order:

1. Is this build actually the one running? The parameter below does not exist in
   Deepin's shipped module, so seeing it proves the new i915.ko is loaded:
     cat /sys/module/i915/parameters/dsi_native_gpio_bypass
   -1 = auto (DMI decides), 0 = force off, 1 = force on.

2. Both patches now announce themselves at info level (no drm.debug needed):
     dmesg | grep -i 'Not touching native DSI GPIOs'
     dmesg | grep -i 'DSB not used for DSI output'
   Expected:
     i915 ...: Not touching native DSI GPIOs (dsi_native_gpio_bypass=-1, -1 = auto/DMI), keeping firmware state
     i915 ...: [CRTC:..:dsi-1] DSB not used for DSI output, falling back to MMIO
   If the first line is absent, the DMI table did not match - see step 3.

3. Behaviour: the torn/split image should be gone. That alone is the result.

If the DMI table did not match (dmidecode -s system-product-name is neither
DRC-WXX nor "MateBook E*"), force the bypass on the kernel cmdline:
     i915.dsi_native_gpio_bypass=1
Cost: the panel state has to be inherited from firmware, so a cold boot that
starts before the firmware has powered the panel, or a resume from suspend,
is expected to leave the screen dark.

Rollback (tty or Live ISO):
  sudo deepin-immutable-ctl admin exec -- bash -c '
    d=/lib/modules/$KVER/kernel/drivers/gpu/drm/i915
    mv -f \$d/$BACKUP \$d/i915.ko.zst
    depmod -a $KVER; update-initramfs -u -k $KVER'
EOM
