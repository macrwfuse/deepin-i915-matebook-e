#!/bin/bash
# Collect the facts needed to diagnose display / audio / video-decode problems
# on Deepin 25.3.0 (6.18.56-amd64-desktop-rolling) on a Huawei MateBook E.
#
#   sudo ./collect-diag.sh > diag.txt 2>&1
#
# Read-only: nothing is changed. Paste diag.txt (or upload it) when reporting.
set -uo pipefail

sec() { printf '\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || echo "[exit $?]"; }

sec machine
run cat /sys/devices/virtual/dmi/id/sys_vendor
run cat /sys/devices/virtual/dmi/id/product_name
run cat /sys/devices/virtual/dmi/id/product_sku
run cat /sys/devices/virtual/dmi/id/board_name
run uname -a
run cat /etc/deepin-version 2>/dev/null
run cat /proc/cmdline

sec module-identity
# dsi_native_gpio_bypass only exists in the rebuilt module: if it is here, the
# new i915.ko is what is running.
run ls -l /sys/module/i915/parameters/
run cat /sys/module/i915/parameters/dsi_native_gpio_bypass
run cat /sys/module/i915/parameters/enable_dsb
run modinfo -F vermagic i915
run modinfo -F srcversion i915
run ls -l /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/i915/

sec gpu
run lspci -nn
run ls -l /sys/class/drm/ 2>/dev/null
run cat /sys/class/drm/card*-*/status 2>/dev/null
run cat /sys/class/drm/card*-*/modes 2>/dev/null

sec display-kernel-log
run dmesg --level=err,warn
run dmesg
# The two lines that prove the patches are active (info level, always on).
printf '\n$ grep patch markers\n'
dmesg | grep -iE 'Not touching native DSI GPIOs|DSB not used for DSI output' \
      || echo '(neither marker present - the patches did not run)'

sec display-state
run cat /sys/kernel/debug/dri/0/i915_vbt
run cat /sys/kernel/debug/dri/0/i915_display_info
run cat /sys/kernel/debug/dri/0/i915_fbc_status
run cat /sys/kernel/debug/dri/0/i915_psr_status

sec session
run echo "type=$XDG_SESSION_TYPE desktop=$XDG_CURRENT_DESKTOP"
run xrandr --verbose 2>/dev/null
run cat /sys/class/drm/card*-*/edid 2>/dev/null | od -An -tx1 | head -20

sec audio-stack
run aplay -l
run pactl info
run pactl list sinks short
run pactl list sources short
run pactl list cards
run pactl list sinks

sec audio-mixer
run amixer -c0 info
run amixer -c0 controls
run amixer -c0 contents
run cat /proc/asound/cards
run cat /proc/asound/card0/codec#0 2>/dev/null
run ls -R /usr/share/alsa/ucm2/conf.d/ 2>/dev/null

sec audio-kernel-log
printf '\n$ dmesg audio\n'
dmesg | grep -iE 'snd|sof|hda|es83|alc|rt5|tas|i2c_hid|firmware' || true

sec video-decode
run vainfo
run ls -l /usr/lib/x86_64-linux-gnu/dri/
run dpkg -l | grep -iE 'va-driver|libva|intel-media|libva-utils|mesa-va'
run dmesg | grep -iE 'i915|guc|huc|firmware'
run ls -l /lib/firmware/i915/ 2>/dev/null
run lsmod
