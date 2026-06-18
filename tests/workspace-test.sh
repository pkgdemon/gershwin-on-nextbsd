#!/bin/sh
# workspace-test.sh — capture the desktop (post-login) and write it to
# docs/desktop.png for the README. Runs from outside the guest via the QEMU
# monitor; the workflow commits the PNG on push to main.
#
# Rather than a blind sleep, poll the framebuffer and wait until the Workspace
# desktop has actually painted the "System Disk" volume icon (the / volume,
# made visible once `dscli init` has set up /Volumes) — that's the signal the
# session is up and logged in. OCR each frame with tesseract; capture as soon
# as it appears, or fall back to grabbing whatever is on screen at the deadline
# so we always produce an artifact.
set -u

SOCK=tests/mon.sock
DEADLINE_SECS=120          # max wait for the desktop to come up post-login
mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }

# Does this frame show the "System Disk" desktop icon label?
have_system_disk() {
    command -v tesseract >/dev/null 2>&1 || return 1
    convert "$1" "$1.png" 2>/dev/null || magick "$1" "$1.png" 2>/dev/null || return 1
    tesseract "$1.png" - 2>/dev/null | tr -d '\r' | grep -qiE 'System[[:space:]]*Disk'
}

echo "[workspace-test] waiting for 'System Disk' on the desktop (<= ${DEADLINE_SECS}s)"
END=$(( $(date +%s) + DEADLINE_SECS ))
i=0
found=0
while [ "$(date +%s)" -lt "$END" ]; do
    i=$((i + 1))
    f="tests/desktop-$(printf '%03d' "$i").ppm"
    mon "screendump $f"
    sleep 1
    if [ -f "$f" ] && have_system_disk "$f"; then
        echo "[workspace-test] PASS: 'System Disk' visible on frame $i — desktop is up"
        cp "$f" tests/desktop.ppm 2>/dev/null || true
        found=1
        break
    fi
    sleep 3
done

if [ "$found" -ne 1 ]; then
    echo "[workspace-test] WARN: 'System Disk' not detected within ${DEADLINE_SECS}s — capturing current screen"
    mon "screendump tests/desktop.ppm"
    sleep 2
fi

[ -f tests/desktop.ppm ] || { echo "[workspace-test] FAIL: no screendump produced"; exit 1; }

mkdir -p docs
convert tests/desktop.ppm docs/desktop.png 2>/dev/null || magick tests/desktop.ppm docs/desktop.png
echo "[workspace-test] wrote docs/desktop.png ($(identify -format '%wx%h, %k colors' docs/desktop.png 2>/dev/null))"
