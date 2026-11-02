#!/bin/bash
#
# Rebuilds the TempoTec V1 kernel (Linux 4.4.94+, zram) from source with the
# vendored kit, and the Morpthis modules against that exact tree.
#
#   scripts/build_kernel.sh --sdk SDK_TARBALL --stock STOCK [--out DIR]
#
#   --sdk     Ingenic's ingenic-linux-kernel4.4.94-x1600-v6.0-20240606.tar.bz2
#             (kernel sources and the mips-gcc720 toolchain). It is not
#             redistributable, which is why it is not in this repository and
#             why the firmware ships the prebuilt, pinned image instead.
#   --stock   the official TempoTec V1 firmware (v1.upt) or its stock xImage:
#             the board's device tree is taken out of it, byte for byte.
#   --out     where the results go (default: out/ in this repository)
#
# Needs Docker (the kit's build environment, kit/docker/Dockerfile), Python 3,
# and 7z when --stock is a .upt.
#
# What it does: copies kit/ (hiby-custom-kernel at the commit v1/kernel.json
# names, its 18 patches checked against v1/kit-patches.sha256) into a work
# folder, adds the V1 as a board -- the device tree from --stock, the symbol
# lists in v1/board/, the configuration fragments in v1/configs/ -- applies
# v1/kit-kernel-only.patch to its build.sh, and runs it for the xImage alone,
# as the V1 kernel was built. The kernel tree it leaves in the Docker volume
# is then the KDIR scripts/build_modules.sh builds morpthis_led.ko against.
#
# The resulting .config is compared with v1/configs/tempotec_v1-final.config,
# the configuration of the shipped kernel. The xImage itself will not be
# byte-identical to the pinned one -- the build stamps a host and a date into
# it, and the published image was recompressed with zopfli -- so the firmware
# keeps shipping the pinned image; this is for working on the kernel.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK=""
STOCK=""
OUT="$ROOT/out"
IMAGE=${KERNEL_DOCKER_IMAGE:-morpthis-kernel-build}
VOLUME=${KERNEL_DOCKER_VOLUME:-morpthis-kbuild}

die() { echo "build_kernel: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--sdk) SDK=$(realpath "$2"); shift ;;
	--stock) STOCK=$(realpath "$2"); shift ;;
	--out) OUT=$(realpath -m "$2"); shift ;;
	*) die "unknown option $1" ;;
	esac
	shift
done
[ -f "$SDK" ] || die "--sdk ingenic-linux-kernel4.4.94-x1600-*.tar.bz2 is required"
case "$(basename "$SDK")" in
ingenic-linux-kernel4.4.94-x1600-*.tar.bz2) ;;
*) die "the kit looks for the SDK as ingenic-linux-kernel4.4.94-x1600-*.tar.bz2; rename or link it" ;;
esac
[ -f "$STOCK" ] || die "--stock v1.upt (or its stock xImage) is required"
command -v docker >/dev/null || die "docker is needed"

WORK="$ROOT/.build/kernel"
KIT="$WORK/hiby-custom-kernel"
BOARD="$KIT/boards/tempotec_v1"

echo "== work folder $WORK"
rm -rf "$KIT"
mkdir -p "$WORK"
cp -a "$ROOT/kit" "$KIT"
(cd "$KIT" && sha256sum --quiet -c "$ROOT/v1/kit-patches.sha256") ||
	die "kit/patches differ from the patches the V1 kernel was built with"
(cd "$KIT" && patch -p1 -s < "$ROOT/v1/kit-kernel-only.patch")

mkdir -p "$BOARD"
cp "$ROOT/v1/board/modules-need.txt" "$ROOT/v1/board/hiby-exports.txt" "$BOARD/"
for f in required parity stock-compat zram; do
	cp "$ROOT/v1/configs/tempotec_v1-$f.config" "$KIT/configs/"
done
python3 "$KIT/tools/extract-stock.py" tempotec_v1 "$STOCK"
[ -f "$BOARD/stock.dtb" ] || die "no device tree came out of $STOCK"
want_dtb=$(sed -n 's/.*"dtb_sha256": *"\([0-9a-f]*\)".*/\1/p' "$ROOT/v1/kernel.json")
have_dtb=$(sha256sum "$BOARD/stock.dtb" | awk '{print $1}')
[ "$want_dtb" = "$have_dtb" ] || die "the device tree in $STOCK is not the V1's (sha256 $have_dtb)"

ln -sf "$SDK" "$WORK/$(basename "$SDK")"

echo "== build environment"
docker build -q -t "$IMAGE" "$KIT/docker" >/dev/null

echo "== kernel"
docker run --platform linux/amd64 --rm \
	-v "$WORK":/work -v "$VOLUME":/build -v "$ROOT":/morpthis:ro \
	"$IMAGE" bash -c '
		set -e
		bash /work/hiby-custom-kernel/build.sh --model tempotec_v1 --name tempotec_v1 \
			--fragment tempotec_v1-parity.config \
			--fragment tempotec_v1-stock-compat.config \
			--fragment tempotec_v1-zram.config \
			--kernel-only
		sdk=$(ls -d /build/sdk/*/ | head -1)
		export PATH="${sdk%/}/prebuilts/toolchains/mips-gcc720-glibc229/bin:$PATH"
		echo "== modules against the same tree"
		KDIR=/build/src KERNEL_WORK=/build/morpthis CROSS_COMPILE=mips-linux-gnu- \
			bash /morpthis/scripts/build_modules.sh /work/hiby-custom-kernel/out/modules-tempotec_v1
	'

mkdir -p "$OUT"
cp "$KIT/out/xImage-tempotec_v1" "$KIT/out/config-tempotec_v1" "$KIT/out/System.map-tempotec_v1" "$OUT/"
cp "$KIT"/out/modules-tempotec_v1/*.ko "$OUT/"
[ -f "$KIT/out/report-tempotec_v1.txt" ] && cp "$KIT/out/report-tempotec_v1.txt" "$OUT/"

echo "== configuration against the shipped kernel's"
if diff -u "$ROOT/v1/configs/tempotec_v1-final.config" "$OUT/config-tempotec_v1" > "$OUT/config.diff"; then
	echo "   identical to v1/configs/tempotec_v1-final.config"
	rm -f "$OUT/config.diff"
else
	echo "   differs: see $OUT/config.diff"
fi
echo "== results in $OUT"
ls -l "$OUT"
