#!/bin/bash
#
# Builds the Morpthis kernel modules for the TempoTec V1 kernel that the
# firmware packer installs (v1-zram-xImage, Linux 4.4.94+, see
# v1/kernel.json). Today that is one module:
#
#   morpthis_led.ko   the status light's engine (modules/morpthis_led/)
#
# Usage:
#   scripts/build_modules.sh OUT_DIR
#
# The tree the modules are built against, in order of preference:
#
#   KDIR=/path/to/tree       a kernel tree already configured and prepared for
#                            the V1 -- the Ingenic SDK's kernel-4.4.94 with the
#                            kit's patches and the pinned config, which is what
#                            scripts/build_kernel.sh leaves behind. The exact
#                            tree the xImage came from; use it when you have it.
#   KERNEL_TARBALL=file      a linux-4.4.94 tarball to prepare here.
#   (neither)                linux-4.4.94 from kernel.org, prepared here.
#
# The Ingenic SDK is not redistributable, so the default is mainline 4.4.94
# with the V1's own configuration (v1/configs/tempotec_v1-final.config, the
# config_sha256 recorded in the pin). The V1's machine (MACH_XBURST/X1600) is
# not in mainline, so the closest mainline little-endian MIPS32r2 machine
# stands in for it; the options a module's ABI depends on -- the release
# string, PREEMPT, no SMP, MODULE_UNLOAD, no MODVERSIONS, MIPS32r2, 32-bit,
# 4 KB pages, HZ -- are checked after the configuration and the build stops if
# any of them moved. The module itself only uses stable core interfaces (a
# platform device, sysfs, delayed work, raw I2C transfers), and the player
# treats it as optional: it loads it, and if the load fails or the module
# misbehaves it falls back to its own I2C path (see led_i2c.c).
#
# CROSS_COMPILE defaults to the first of mipsel-linux-gnu-,
# mipsel-rockbox-linux-gnu- and mips-linux-gnu- found on PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(realpath -m "${1:?usage: $0 OUT_DIR}")"
WORK="${KERNEL_WORK:-$ROOT/.build}"
VERSION=4.4.94
CONFIG="$ROOT/v1/configs/tempotec_v1-final.config"
PIN="$ROOT/v1/kernel.json"
EXPECT_VERMAGIC="4.4.94+ preempt mod_unload MIPS32_R2 32BIT"

die() { echo "build_modules: $*" >&2; exit 1; }

if [ -z "${CROSS_COMPILE:-}" ]; then
	for prefix in mipsel-linux-gnu- mipsel-rockbox-linux-gnu- mips-linux-gnu-; do
		if command -v "${prefix}gcc" >/dev/null 2>&1; then
			CROSS_COMPILE=$prefix
			break
		fi
		# Debian/Ubuntu install the cross gcc versioned only (gcc-10 etc).
		versioned=$(compgen -c "${prefix}gcc-" 2>/dev/null | grep -E "^${prefix}gcc-[0-9]+$" | sort -V | head -1 || true)
		if [ -n "$versioned" ]; then
			mkdir -p "$WORK/bin"
			ln -sf "$(command -v "$versioned")" "$WORK/bin/${prefix}gcc"
			export PATH="$WORK/bin:$PATH"
			CROSS_COMPILE=$prefix
			break
		fi
	done
fi
[ -n "${CROSS_COMPILE:-}" ] || die "no MIPS cross compiler found; set CROSS_COMPILE"
command -v "${CROSS_COMPILE}gcc" >/dev/null || die "${CROSS_COMPILE}gcc is not on PATH"
command -v "${CROSS_COMPILE}ld" >/dev/null || die "${CROSS_COMPILE}ld is not on PATH"

[ -f "$CONFIG" ] || die "missing $CONFIG"
want_config=$(sed -n 's/.*"config_sha256": *"\([0-9a-f]*\)".*/\1/p' "$PIN")
have_config=$(sha256sum "$CONFIG" | awk '{print $1}')
[ "$want_config" = "$have_config" ] || die "v1/configs/tempotec_v1-final.config does not match config_sha256 in v1/kernel.json"

# GCC newer than the 4.4 kernel knows about warns about a great deal in the
# kernel's own headers. None of it is in this code; keep the log readable.
KCFLAGS_EXTRA="-Wno-attribute-alias -Wno-missing-attributes -Wno-address-of-packed-member -Wno-stringop-truncation -Wno-array-bounds -Wno-zero-length-bounds -Wno-format-truncation -fno-pie"
MK=(make ARCH=mips "CROSS_COMPILE=$CROSS_COMPILE" "HOSTCC=gcc -fcommon" -j"$(nproc)")

check_option() { # check_option TREE OPTION WANTED ("" = off)
	local have
	have=$(grep -E "^$2=" "$1/.config" || true)
	if [ -n "$3" ]; then
		[ "$have" = "$2=$3" ] || die "$2 is '${have:-off}' after configuring, the V1 kernel has $3"
	else
		[ -z "$have" ] || die "$2 is '$have' after configuring, the V1 kernel has it off"
	fi
}

prepare_mainline() {
	local tree="$WORK/linux-$VERSION"
	if [ ! -f "$tree/.morpthis-prepared" ] || ! cmp -s "$CONFIG" "$tree/.morpthis-config"; then
		rm -rf "$tree"
		mkdir -p "$WORK"
		local tarball="${KERNEL_TARBALL:-$WORK/linux-$VERSION.tar.xz}"
		if [ ! -f "$tarball" ]; then
			echo "== fetching linux-$VERSION"
			curl -fsSL --retry 4 -o "$tarball.part" \
				"https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$VERSION.tar.xz"
			mv "$tarball.part" "$tarball"
		fi
		echo "== unpacking linux-$VERSION"
		tar -xf "$tarball" -C "$WORK"
		[ -d "$tree" ] || die "the tarball did not unpack to linux-$VERSION"

		# "4.4.94+" like the V1 kernel, or the vermagic does not match.
		printf '+\n' > "$tree/.scmversion"

		# The V1's configuration, with a mainline machine in place of the
		# XBurst one mainline does not have. Everything else is the V1's.
		{
			cat "$CONFIG"
			echo "CONFIG_MIPS_MALTA=y"
			echo "CONFIG_CPU_MIPS32_R2=y"
			echo "CONFIG_CPU_LITTLE_ENDIAN=y"
			echo "CONFIG_32BIT=y"
		} > "$tree/.config"
		"${MK[@]}" -C "$tree" olddefconfig >/dev/null
		cp "$CONFIG" "$tree/.morpthis-config"
	fi

	for opt in CONFIG_LOCALVERSION_AUTO CONFIG_SMP CONFIG_MODVERSIONS CONFIG_MODULE_SIG CONFIG_64BIT \
		CONFIG_DEBUG_LOCK_ALLOC CONFIG_DEBUG_MUTEXES CONFIG_DEBUG_SPINLOCK CONFIG_TIMER_STATS; do
		check_option "$tree" "$opt" ""
	done
	check_option "$tree" CONFIG_PREEMPT y
	check_option "$tree" CONFIG_MODULES y
	check_option "$tree" CONFIG_MODULE_UNLOAD y
	check_option "$tree" CONFIG_CPU_MIPS32_R2 y
	check_option "$tree" CONFIG_CPU_LITTLE_ENDIAN y
	check_option "$tree" CONFIG_32BIT y
	check_option "$tree" CONFIG_PAGE_SIZE_4KB y
	check_option "$tree" CONFIG_HZ 100
	check_option "$tree" CONFIG_I2C y
	check_option "$tree" CONFIG_PM_SLEEP y

	if [ ! -f "$tree/.morpthis-prepared" ]; then
		echo "== modules_prepare"
		"${MK[@]}" -C "$tree" KCFLAGS="$KCFLAGS_EXTRA" modules_prepare >/dev/null
		touch "$tree/.morpthis-prepared"
	fi
	KDIR="$tree"
}

if [ -n "${KDIR:-}" ]; then
	[ -f "$KDIR/.config" ] || die "KDIR=$KDIR has no .config"
	[ -f "$KDIR/include/generated/utsrelease.h" ] || die "KDIR=$KDIR is not prepared (make modules_prepare)"
	echo "== building against $KDIR"
else
	prepare_mainline
	echo "== building against mainline linux-$VERSION with the V1 configuration"
fi

grep -q "\"$VERSION+\"" "$KDIR/include/generated/utsrelease.h" ||
	die "$KDIR builds for $(cat "$KDIR/include/generated/utsrelease.h"), not $VERSION+"

mkdir -p "$OUT"
for mod in morpthis_led; do
	src="$WORK/src-$mod"
	rm -rf "$src"
	mkdir -p "$src"
	cp "$ROOT/modules/$mod"/*.c "$ROOT/modules/$mod/Kbuild" "$src/"
	"${MK[@]}" -C "$KDIR" M="$src" KCFLAGS="$KCFLAGS_EXTRA" modules
	ko="$src/$mod.ko"
	[ -f "$ko" ] || die "$mod.ko was not built"
	"${CROSS_COMPILE}strip" --strip-debug "$ko"

	vermagic=$(strings -a "$ko" | sed -n 's/^vermagic=//p' | head -1)
	# The kernel compares the whole string, trailing space included.
	[ "$(echo "$vermagic" | sed 's/ *$//')" = "$EXPECT_VERMAGIC" ] ||
		die "$mod.ko has vermagic '$vermagic', the V1 kernel wants '$EXPECT_VERMAGIC'"
	head=$(od -An -tx1 -N20 "$ko" | tr -d ' \n')
	[ "${head:0:12}" = "7f454c460101" ] && [ "${head:32:8}" = "01000800" ] ||
		die "$mod.ko is not a 32-bit little-endian MIPS relocatable object"

	install -m 0644 "$ko" "$OUT/$mod.ko"
	echo "== $OUT/$mod.ko ($(stat -c%s "$OUT/$mod.ko") bytes, vermagic '$vermagic')"
done
