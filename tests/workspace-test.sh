#!/bin/sh
# workspace-test.sh — capture the desktop (post-login) and write it to
# docs/desktop.png for the README. Runs from outside the guest via the QEMU
# monitor; the workflow commits the PNG on push to main.
set -u

SOCK=tests/mon.sock
mon() { printf '%s\n' "$*" | socat -t2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true; }

sleep 5
mon "screendump tests/desktop.ppm"
sleep 2
[ -f tests/desktop.ppm ] || { echo "[workspace-test] FAIL: no screendump produced"; exit 1; }

mkdir -p docs
convert tests/desktop.ppm docs/desktop.png 2>/dev/null || magick tests/desktop.ppm docs/desktop.png
echo "[workspace-test] wrote docs/desktop.png ($(identify -format '%wx%h, %k colors' docs/desktop.png 2>/dev/null))"
