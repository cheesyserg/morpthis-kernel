#!/bin/bash
#
# Builds the Morpthis kernel modules for the TempoTec V1 kernel that the
# firmware packer installs (v1-zram-xImage, Linux 4.4.94+, see
# v1/kernel.json):
#
#   morpthis_led.ko   the status light's engine (modules/morpthis_led/)
#   axp2101.ko        the PMIC driver, open, with VBUS insert as a wake
#                     source (modules/axp2101/); a drop-in for the vendor
#                     module of the same name, which it imports utils.ko from
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
# not in mainline, so a mainline little-endian MIPS32r2 machine stands in for
# it: MACH_XILFPGA, because like the V1's it requires GPIOLIB -- with Malta,
# GPIOLIB was dropped, the gpiolib calls compiled to their stubs, and the
# PMIC driver came up without its interrupt. The options a module's ABI or
# its headers' stubs depend on -- the release string, PREEMPT, no SMP,
# MODULE_UNLOAD, no MODVERSIONS, MIPS32r2, 32-bit, 4 KB pages, HZ, and the
# subsystems the modules call into (GPIOLIB, OF, I2C, PM, regulators, power
# supplies, LEDs) -- are checked after the configuration and the build stops
# if any of them is not what the V1 kernel has. The module itself only uses stable core interfaces (a
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
# Bumped whenever the way the mainline tree is configured changes, so a tree
# prepared the old way is prepared again rather than reused. 2: XILFPGA as
# the stand-in machine, and every V1 option mainline has forced on.
PREPARE_RECIPE=2

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
	if [ ! -f "$tree/.morpthis-prepared" ] || ! cmp -s "$CONFIG" "$tree/.morpthis-config" ||
		[ "$(cat "$tree/.morpthis-recipe" 2>/dev/null)" != "$PREPARE_RECIPE" ]; then
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
			echo "CONFIG_MACH_XILFPGA=y"
			echo "CONFIG_CPU_MIPS32_R2=y"
			echo "CONFIG_CPU_LITTLE_ENDIAN=y"
			echo "CONFIG_32BIT=y"
		} > "$tree/.config"
		"${MK[@]}" -C "$tree" olddefconfig >/dev/null

		# Kconfig drops whatever nothing selects on the stand-in machine:
		# PINCTRL among others, and PINCTRL alone moves every field after
		# the middle of struct device -- client->irq included. Every option
		# the V1 has on and the tree dropped, and that mainline defines at
		# all, is selected by one synthetic symbol, and the tree configured
		# again. What is left over afterwards is printed: the Ingenic
		# drivers mainline does not have.
		local dropped selects=""
		dropped=$(comm -23 <(grep -E "^CONFIG_[A-Za-z0-9_]+=y" "$CONFIG" | sed 's/=y$//' | sort) \
			<(grep -E "^CONFIG_[A-Za-z0-9_]+=y" "$tree/.config" | sed 's/=y$//' | sort))
		for opt in $dropped; do
			sym=${opt#CONFIG_}
			if grep -rqsE "^(menu)?config $sym\$" --include='Kconfig*' "$tree/arch/mips" "$tree/drivers" \
				"$tree/kernel" "$tree/mm" "$tree/lib" "$tree/init" "$tree/fs" "$tree/net" "$tree/sound" \
				"$tree/block" "$tree/crypto" "$tree/security" "$tree/usr"; then
				selects="$selects	select $sym
"
			fi
		done
		printf 'config MORPTHIS_V1_ABI\n\tdef_bool y\n%s' "$selects" > "$tree/arch/mips/Kconfig.morpthis"
		grep -q 'Kconfig.morpthis' "$tree/arch/mips/Kconfig" ||
			printf '\nsource "arch/mips/Kconfig.morpthis"\n' >> "$tree/arch/mips/Kconfig"
		"${MK[@]}" -C "$tree" olddefconfig >/dev/null 2>&1
		"${MK[@]}" -C "$tree" olddefconfig >/dev/null 2>&1
		echo "== options the V1 has that mainline cannot give (its own drivers):"
		comm -23 <(grep -E "^CONFIG_[A-Za-z0-9_]+=y" "$CONFIG" | sort) \
			<(grep -E "^CONFIG_[A-Za-z0-9_]+=y" "$tree/.config" | sort) | sed 's/^/   /'
		cp "$CONFIG" "$tree/.morpthis-config"
		echo "$PREPARE_RECIPE" > "$tree/.morpthis-recipe"
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
	# The subsystems whose headers turn into stubs when they are off: a
	# module built against a tree without one of them calls nothing.
	for opt in CONFIG_GPIOLIB CONFIG_OF CONFIG_OF_GPIO CONFIG_REGULATOR CONFIG_POWER_SUPPLY CONFIG_LEDS_CLASS \
		CONFIG_PM CONFIG_SYSFS CONFIG_PRINTK CONFIG_PINCTRL CONFIG_MFD_CORE CONFIG_REGMAP_IRQ CONFIG_HIGHMEM \
		CONFIG_GENERIC_MSI_IRQ_DOMAIN CONFIG_DMA_CMA CONFIG_CMA CONFIG_NUMA CONFIG_MMU_NOTIFIER; do
		want=$(sed -n "s/^$opt=//p" "$CONFIG")
		check_option "$tree" "$opt" "$want"
	done

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

# The structure layout against what the V1's own modules were compiled with.
echo "== structure offsets against the V1 vendor modules"
abi="$WORK/abi-probe"
rm -rf "$abi"
mkdir -p "$abi"
cp "$ROOT/scripts/abi/probe.c" "$ROOT/scripts/abi/Kbuild" "$abi/"
"${MK[@]}" -C "$KDIR" M="$abi" KCFLAGS="$KCFLAGS_EXTRA" probe.s >/dev/null
while read -r name want; do
	case "$name" in ''|\#*) continue ;; esac
	have=$(sed -n "s/.*->$name \([0-9]*\).*/\1/p" "$abi/probe.s" | head -1)
	[ "$have" = "$want" ] || die "$name is at $have in this tree, the V1 kernel has it at $want (v1/abi-offsets.txt)"
	echo "   $name $have"
done < "$ROOT/v1/abi-offsets.txt"

mkdir -p "$OUT"
for mod in ${MODULES:-morpthis_led axp2101}; do
	src="$WORK/src-$mod"
	rm -rf "$src"
	mkdir -p "$src"
	# Sources, Kbuild and the symbol lists of the vendor modules a module
	# calls (hiby.symvers); the Makefile is for building by hand.
	find "$ROOT/modules/$mod" -maxdepth 1 -type f ! -name Makefile -exec cp {} "$src/" \;
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
