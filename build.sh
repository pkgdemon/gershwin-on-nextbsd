#!/bin/sh
# build.sh — build a Gershwin live ISO on top of NextBSD.
#
# Runs inside a FreeBSD VM (vmactions). It downloads NextBSD's latest
# continuous disk image, builds the Gershwin desktop into a copy of its rootfs
# via chroot, drops getty in favour of Gershwin's loginwindow, and repackages
# the result into a live ISO that boots exactly like NextBSD's own — a tiny
# mfsroot assembles an on-demand uzip-compressed root + tmpfs/unionfs overlay,
# then `sysctl vfs.pivot` adopts the union as / and execs launchd.
#
# The ISO-building half (steps 5-7) is lifted from nextbsd-redux/nextbsd
# build.sh step 7 so the boot pipeline is identical.
set -eu

ARCH=${TARGET_ARCH:-amd64}
FREEBSD_VERSION=${FREEBSD_VERSION:-15.0}
LABEL=GERSHWIN
CWD=$(cd "$(dirname "$0")" && pwd)
WORK=/usr/local/gon-build
ROOTFS=$WORK/rootfs
OUT=$WORK/iso
GERSHWIN_REPO=${GERSHWIN_REPO:-https://github.com/gershwin-desktop/gershwin-developer.git}
GERSHWIN_REF=${GERSHWIN_REF:-main}
IMG_DATE=$(date +%Y%m%d-%H%M%S)
ISO_NAME="Gershwin-NextBSD-${ARCH}-${IMG_DATE}.iso"

rm -rf "$WORK"
mkdir -p "$WORK" "$ROOTFS" "$OUT"

# ---------------------------------------------------------------------------
# 1. Download the latest NextBSD continuous .img.zip (public repo, no auth).
# ---------------------------------------------------------------------------
echo "==> resolving latest NextBSD .img.zip"
URL=$(fetch -qo - https://api.github.com/repos/nextbsd-redux/nextbsd/releases/tags/continuous \
      | jq -r '.assets[] | select(.name | test("'"$ARCH"'.*\\.img\\.zip$")) | .browser_download_url' \
      | head -1)
[ -n "$URL" ] || { echo "ERROR: could not resolve NextBSD .img.zip URL" >&2; exit 1; }
echo "    $URL"
fetch -o "$WORK/nextbsd.img.zip"        "$URL"
fetch -o "$WORK/nextbsd.img.zip.sha256" "$URL.sha256"

echo "==> verifying sha256"
EXPECT=$(grep -Eo '[0-9a-f]{64}' "$WORK/nextbsd.img.zip.sha256" | head -1)
ACTUAL=$(sha256 -q "$WORK/nextbsd.img.zip")
[ "$EXPECT" = "$ACTUAL" ] || { echo "ERROR: sha256 mismatch ($ACTUAL != $EXPECT)" >&2; exit 1; }
unzip -p "$WORK/nextbsd.img.zip" '*.img' > "$WORK/nextbsd.img"

# ---------------------------------------------------------------------------
# 2. Extract the rootfs from the freebsd-ufs/ROOTFS partition (GPT p3).
# ---------------------------------------------------------------------------
echo "==> extracting NextBSD rootfs"
md=$(mdconfig -a -t vnode -f "$WORK/nextbsd.img")
gpart show "$md" || true
mount "/dev/${md}p3" /mnt
tar -C /mnt -cf - . | tar -C "$ROOTFS" -xpf -
umount /mnt
mdconfig -d -u "${md#md}"

# ---------------------------------------------------------------------------
# 3. Build Gershwin into the rootfs via chroot (network for pkg + git clone).
#    Same flow as the other Gershwin targets; detect_platform() takes the
#    NextBSD path because /usr/lib/system exists in the rootfs.
# ---------------------------------------------------------------------------
echo "==> chroot build: Gershwin -> /System"
mount -t devfs devfs "$ROOTFS/dev"
mkdir -p "$ROOTFS/private/etc"
cp /etc/resolv.conf "$ROOTFS/private/etc/resolv.conf"
chroot "$ROOTFS" /bin/sh -eu -c '
    pkg install -y git
    git clone --depth 1 -b '"$GERSHWIN_REF"' '"$GERSHWIN_REPO"' /build
    cd /build
    sh Library/Scripts/Bootstrap.sh
    sh Library/Scripts/Checkout.sh
    make install
'
[ -d "$ROOTFS/System/Library" ] || { echo "ERROR: /System was not produced" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 4. Gershwin launchd overlay: add loginwindow/dshelper/gdomap, drop getty.
# ---------------------------------------------------------------------------
echo "==> applying Gershwin launchd overlay (getty -> loginwindow)"
cp -aR "$CWD/overlays/." "$ROOTFS/"
rm -f "$ROOTFS/System/Library/LaunchDaemons/com.apple.getty.plist"
chroot "$ROOTFS" /bin/sh -c 'command -v dscli >/dev/null 2>&1 && dscli init || true'

# strip build scratch; normalise ownership before makefs bakes the tree in
rm -rf "$ROOTFS/build" "$ROOTFS/private/etc/resolv.conf"
umount "$ROOTFS/dev" || true
chown -R 0:0 "$ROOTFS/System/Library/LaunchDaemons"

# ---------------------------------------------------------------------------
# 5-7. Repackage as a live ISO (nextbsd build.sh step 7, verbatim model).
# ---------------------------------------------------------------------------
echo "==> live ISO: compact UFS + mkuzip"
makefs -t ffs -B little -o version=2,label=NBROOT "$WORK/rootfs.iso.ufs" "$ROOTFS"
mkuzip -o "$WORK/rootfs.uzip" "$WORK/rootfs.iso.ufs"
ls -lh "$WORK/rootfs.uzip"

echo "==> staging mfsroot (rootfs tools + lib closure)"
MFS="$WORK/mfsroot"
RF="$ROOTFS"
rm -rf "$MFS"
mkdir -p "$MFS/dev" "$MFS/media" "$MFS/rofs" "$MFS/cow" \
         "$MFS/bin" "$MFS/sbin" "$MFS/lib" "$MFS/libexec"
cp -p "$RF/libexec/ld-elf.so.1" "$MFS/libexec/"
MFS_TOOLS="bin/sh bin/sleep bin/ls sbin/mount sbin/umount sbin/mount_cd9660 sbin/mount_unionfs sbin/mdconfig sbin/sysctl"
for t in $MFS_TOOLS; do
    if [ -f "$RF/$t" ]; then cp -p "$RF/$t" "$MFS/$t"
    else echo "    WARN: mfsroot tool missing in rootfs: $t"; fi
done
needed() { readelf -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'; }
seen=" "
work=$(for t in $MFS_TOOLS; do [ -f "$MFS/$t" ] && needed "$MFS/$t"; done | sort -u)
while [ -n "$work" ]; do
    nextwork=""
    for so in $work; do
        case "$seen" in *" $so "*) continue ;; esac
        seen="$seen$so "
        src=$(find "$RF/lib" "$RF/usr/lib" /lib /usr/lib -name "$so" 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            cp -p "$src" "$MFS/lib/$so"
            nextwork="$nextwork $(needed "$src")"
        else
            echo "    WARN: mfsroot lib not found: $so"
        fi
    done
    work=$(printf '%s\n' $nextwork | sort -u)
done

cat > "$MFS/init" <<'INITEOF'
#!/bin/sh
# Gershwin/NextBSD live-ISO init. Runs as PID 1 from the preloaded mfsroot,
# assembles an on-demand uzip root + tmpfs/unionfs overlay, then vfs.pivot
# adopts the union as / and execs launchd.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/libexec
LD_LIBRARY_PATH=/lib
export PATH LD_LIBRARY_PATH

mount -t devfs devfs /dev 2>/dev/null
exec >/dev/console 2>&1
echo "[init] Gershwin/NextBSD live root: assembling overlay"

n=0
while [ ! -e /dev/iso9660/GERSHWIN ] && [ ! -e /dev/cd0 ] && [ "$n" -lt 10 ]; do n=$((n + 1)); sleep 1; done
for dev in /dev/iso9660/GERSHWIN /dev/cd0 /dev/cd1; do
	[ -e "$dev" ] || continue
	if mount -t cd9660 -o ro "$dev" /media 2>&1; then
		echo "[init] media mounted from $dev"; break
	fi
done
echo "[init] media: $(ls /media/rootfs.uzip 2>/dev/null || echo rootfs.uzip-MISSING)"

mdconfig -a -t vnode -f /media/rootfs.uzip -u 1
n=0
while [ ! -c /dev/md1.uzip ] && [ "$n" -lt 20 ]; do n=$((n + 1)); sleep 1; done
mount -o ro /dev/md1.uzip /rofs
echo "[init] rofs lower: $(ls -d /rofs/sbin 2>/dev/null || echo /rofs-EMPTY)"

case " $* " in
*" -s "*)
	echo "[init] ==== single-user (miniroot) ===="
	/bin/sh </dev/console >/dev/console 2>&1
	echo "[init] resuming boot to multi-user"
	;;
esac

mount -t tmpfs tmpfs /cow
mount_unionfs /cow /rofs
echo "[init] union assembled; launchd: $(ls /rofs/sbin/launchd 2>/dev/null || echo launchd-MISSING)"
mount -t devfs devfs /rofs/dev

sysctl vfs.pivot=/rofs
echo "[init] pivot complete; exec launchd"
unset LD_LIBRARY_PATH
exec /sbin/launchd
echo "[init] FATAL: exec /sbin/launchd failed ($?)"
while : ; do sleep 60; done
INITEOF
chmod 0755 "$MFS/init"
chown -R 0:0 "$MFS"
makefs -t ffs -B little -o version=2,label=MFSROOT -b 3m "$WORK/mfsroot.img" "$MFS"

echo "==> assembling ISO staging tree"
ISOROOT="$WORK/isoroot"
rm -rf "$ISOROOT"
mkdir -p "$ISOROOT/boot/loader.conf.d" "$ISOROOT/etc"
cp -R "$ROOTFS/boot/." "$ISOROOT/boot/"
for f in cdboot loader.efi; do
    [ -f "$ISOROOT/boot/$f" ] || { echo "ERROR: live ISO needs rootfs/boot/$f" >&2; exit 1; }
done
cp "$WORK/mfsroot.img" "$ISOROOT/boot/mfsroot.img"
for f in passwd group master.passwd; do
    [ -f "$ROOTFS/etc/$f" ] && cp "$ROOTFS/etc/$f" "$ISOROOT/etc/$f"
done
cat > "$ISOROOT/boot/loader.conf.d/zz-live.conf" <<'LIVEEOF'
# Gershwin/NextBSD live ISO: tiny mfsroot assembles an on-demand compressed root + overlay.
mfsroot_load="YES"
mfsroot_type="md_image"
mfsroot_name="/boot/mfsroot.img"
init_path="/init"
vfs.root.mountfrom="ufs:/dev/md0"
LIVEEOF
cp "$WORK/rootfs.uzip" "$ISOROOT/rootfs.uzip"

# Use FreeBSD's stock release scripts from src.txz (matching the base version),
# exactly as nextbsd-redux/nextbsd does — the full tree resolves mkisoimages.sh's
# relative sources (scripts/tools.subr, tools/boot/install-boot.sh).
echo "==> fetching FreeBSD ${FREEBSD_VERSION} src.txz for release scripts"
SRC="$WORK/freebsd-src"
mkdir -p "$SRC"
fetch -o "$WORK/src.txz" "https://download.freebsd.org/ftp/releases/${ARCH}/${FREEBSD_VERSION}-RELEASE/src.txz"
tar -xJf "$WORK/src.txz" -C "$SRC"
MKISO=$(find "$SRC" -path "*/release/${ARCH}/mkisoimages.sh" 2>/dev/null | head -1)
[ -n "$MKISO" ] || { echo "ERROR: mkisoimages.sh not found in src.txz" >&2; exit 1; }

echo "==> mkisoimages.sh: bootable cd9660 (BIOS + UEFI)"
sh "$MKISO" -b "$LABEL" "$OUT/$ISO_NAME" "$ISOROOT"
( cd "$OUT" && sha256 -q "$ISO_NAME" > "$ISO_NAME.sha256" 2>/dev/null || sha256sum "$ISO_NAME" | awk '{print $1}' > "$ISO_NAME.sha256" )
ls -lh "$OUT/$ISO_NAME" "$OUT/$ISO_NAME.sha256"
echo "==> DONE: $ISO_NAME"
