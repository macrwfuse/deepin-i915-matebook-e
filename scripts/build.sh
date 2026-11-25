#!/bin/bash
# Build i915.ko for Deepin 25.3.0 (6.18.56-amd64-desktop-rolling) from upstream
# sources, using Deepin's own headers package as KDIR.
#
#   TARBALL=linux-6.18.56.tar.xz KDIR=/path/to/headers ./build.sh
#
# Environment:
#   TARBALL   upstream linux-6.18.56.tar.xz                 (required)
#   KDIR      extracted linux-headers-... deb               (required)
#   OUT       artifact directory           (default <repo>/out)
#   WORK      scratch dir for the sources  (default <repo>/work)
#   CC        compiler                     (default gcc; gcc-12 recommended)
#
# The build is an external module (M=) against the headers tree:
#   * vermagic and every undefined-symbol CRC come from Deepin's own
#     Module.symvers, so they cannot drift;
#   * exported-symbol CRCs are recomputed by Deepin's prebuilt gendwarfksyms
#     from the DWARF the compiler emits, then compared to abi/*.json;
#   * modpost gets -e, so MODULE_INFO(intree,"Y") is absent and the loader adds
#     TAINT_OOT_MODULE. Metadata only, no ABI impact.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=6.18.56-amd64-desktop-rolling
VERMAGIC="$KVER SMP preempt mod_unload modversions "

TARBALL=${TARBALL:?set TARBALL=/path/to/linux-6.18.56.tar.xz}
KDIR=${KDIR:?set KDIR=/path/to/extracted/linux-headers-$KVER}
OUT=${OUT:-$HERE/out}
WORK=${WORK:-$HERE/work}
CC=${CC:-gcc}

[ -f "$TARBALL" ] || { echo "no such tarball: $TARBALL" >&2; exit 1; }
[ -f "$KDIR/Module.symvers" ] || { echo "$KDIR is not a headers tree" >&2; exit 1; }
# kbuild re-enters make from the module directory, so every path handed to it
# has to be absolute.
TARBALL=$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")
KDIR=$(cd "$KDIR" && pwd)
for t in scripts/mod/modpost tools/objtool/objtool \
         scripts/gendwarfksyms/gendwarfksyms scripts/basic/fixdep; do
  [ -x "$KDIR/$t" ] || { echo "missing/not executable: $KDIR/$t" >&2; exit 1; }
done

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# ---- 1. sources -----------------------------------------------------------
# Only two paths are needed from the tarball. Keeping the drivers/ layout
# matters: gt/intel_rps.c includes "../../../platform/x86/intel_ips.h", which
# resolves via -I$(src) to drivers/platform/x86/intel_ips.h.
echo "== extracting i915 sources"
tar -xJf "$TARBALL" -C "$WORK" --strip-components=1 \
    "linux-6.18.56/drivers/gpu/drm/i915" \
    "linux-6.18.56/drivers/platform/x86/intel_ips.h"
[ -f "$WORK/drivers/platform/x86/intel_ips.h" ] || {
  echo "intel_ips.h missing after unpack" >&2; exit 1; }

I915DIR="$WORK/drivers/gpu/drm/i915"
for p in "$HERE"/patches/0*.patch; do
  echo "== $(basename "$p")"
  patch -p1 -d "$WORK" --dry-run -N < "$p" >/dev/null
  patch -p1 -d "$WORK" -N < "$p" >/dev/null
done
grep -q 'dsi_native_gpio_bypass' "$I915DIR/display/intel_dsi_vbt.c" || {
  echo "0001 did not apply" >&2; exit 1; }
grep -q 'DSB not used for DSI output' "$I915DIR/display/intel_dsb.c" || {
  echo "0002 did not apply" >&2; exit 1; }
grep -q 'pci_resize_resource(pdev, resno, bar_size);' "$I915DIR/gt/intel_region_lmem.c" || {
  echo "0003 did not apply" >&2; exit 1; }
# Both diagnostics must be drm_info_once(), never drm_dbg_kms(): Deepin's
# kernel has no CONFIG_DRM_DEBUG_KMS, and drm_dbg_kms() is additionally gated
# on drm.debug at runtime, so a debug-level line is invisible on a stock boot
# and the user cannot tell whether the patches took effect.
grep -q 'drm_info_once' "$I915DIR/display/intel_dsi_vbt.c" || {
  echo "0001 lost its unconditional diagnostic" >&2; exit 1; }
grep -q 'drm_info_once' "$I915DIR/display/intel_dsb.c" || {
  echo "0002 lost its unconditional diagnostic" >&2; exit 1; }

# ---- 1b. make the in-tree trace headers reachable -------------------------
# i915's four trace headers pin their include path to the in-tree location:
#   #define TRACE_INCLUDE_PATH ../../drivers/gpu/drm/i915[/display|/gvt]
# include/trace/define_trace.h resolves that relative to <KDIR>/include/trace,
# i.e. it wants <KDIR>/drivers/gpu/drm/i915/*.h. Headers packages do not ship
# drivers/, so an out-of-tree build dies with
#   fatal error: ../../drivers/gpu/drm/i915/intel_uncore_trace.h: No such file
# -I cannot help (the path is parent-relative, not -I-relative). Point that
# exact path at the extracted sources; nothing else in the build resolves
# through it, and the header the compiler then reads is byte-identical to the
# one Deepin compiled in-tree, so DWARF -- and every gendwarfksyms CRC -- is
# unaffected. KDIR needs to be writable (it is, when it is an extracted deb
# under the repo or a copy anywhere outside /usr).
echo "== wiring <KDIR>/drivers/gpu/drm/i915 -> $I915DIR"
[ -w "$KDIR" ] || { echo "$KDIR is not writable (needed for the trace-header link)" >&2; exit 1; }
mkdir -p "$KDIR/drivers/gpu/drm"
ln -sfn "$I915DIR" "$KDIR/drivers/gpu/drm/i915"
for h in i915_trace.h intel_uncore_trace.h display/intel_display_trace.h gvt/trace.h; do
  [ -f "$KDIR/drivers/gpu/drm/i915/$h" ] || {
    echo "trace header still unreachable: $KDIR/drivers/gpu/drm/i915/$h" >&2; exit 1; }
done

# ---- 2. build -------------------------------------------------------------
# KERNELRELEASE comes from include/config/kernel.release in the headers tree,
# so vermagic is fixed. LOCALVERSION is cleared anyway: should any sub-make
# take the in-tree branch, setlocalversion would append "+" for a source tree
# that is not a clean git tag.
echo "== building with $("$CC" --version | head -1)"
export LOCALVERSION=
make -C "$KDIR" M="$I915DIR" \
     CONFIG_DRM_I915_GVT_KVMGT= \
     CC="$CC" -j"$(nproc)" modules

KO="$I915DIR/i915.ko"
[ -f "$KO" ] || { echo "i915.ko not produced" >&2; exit 1; }

# ---- 3. strip debug info --------------------------------------------------
# CONFIG_DEBUG_INFO=y means the freshly linked module carries full DWARF.
# Deepin ships it stripped (no .debug_* sections in their i915.ko), so do the
# same: --strip-debug keeps .symtab, .modinfo, __ksymtab* and __versions*,
# which is all the loader and the verifier look at. gendwarfksyms already ran
# on the .o files during compilation, so CRCs are unaffected.
echo "== stripping debug info ($(stat -c%s "$KO") bytes before)"
"${CROSS_COMPILE:-}strip" --strip-debug "$KO"
echo "   $(stat -c%s "$KO") bytes after"

# ---- 4. verify ------------------------------------------------------------
python3 "$HERE/tools/verify-module.py" "$KO" \
        "$HERE/abi/i915-$KVER.json" "$KDIR/Module.symvers" "$VERMAGIC" \
        | tee "$OUT/verify.txt"

# ---- 5. stage -------------------------------------------------------------
cp -f "$KO" "$OUT/i915.ko"
printf '%s\n' "$VERMAGIC" > "$OUT/i915.vermagic"
zstd -19 -f -q "$OUT/i915.ko" -o "$OUT/i915.ko.zst"
( cd "$OUT" && sha256sum i915.ko i915.ko.zst > SHA256SUMS )
ls -l "$OUT"
