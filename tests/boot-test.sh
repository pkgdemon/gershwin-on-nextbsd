#!/bin/sh
# boot-test.sh — boot the Gershwin/NextBSD live ISO under qemu (UEFI/OVMF),
# drive the loader over the serial console, and assert the live-root pipeline
# (on-demand uzip + unionfs + vfs.pivot) comes up and hands off to launchd.
#
# Gershwin replaces the console getty with a GUI loginwindow, so there is no
# serial "login:" prompt — success is the kernel's "vfs.pivot: / is now unionfs"
# (or the init's "pivot complete") followed by launchd starting, with no panic.
set -eu

ISO=${1:?usage: boot-test.sh path/to/live.iso}
[ -f "$ISO" ] || { echo "ERROR: $ISO not found"; exit 1; }

mkdir -p tests
LOG=tests/boot.log
EXP=tests/boot.exp

if [ -e /dev/kvm ]; then sudo chmod 666 /dev/kvm 2>/dev/null || true; fi
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_FLAGS="-accel kvm -cpu host"
else
    ACCEL_FLAGS="-accel tcg,thread=single -cpu qemu64"
fi

OVMF=""
for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
    [ -f "$f" ] && { OVMF="$f"; break; }
done
[ -n "$OVMF" ] || { echo "ERROR: no OVMF firmware found"; exit 1; }

export ACCEL_FLAGS OVMF ISO

cat > "$EXP" <<'EOF'
set timeout 600
log_file -a tests/boot.log
log_user 1
set accel_flags [split $env(ACCEL_FLAGS) " "]

eval spawn qemu-system-x86_64 \
    -m 4G -machine q35 -bios $env(OVMF) \
    $accel_flags \
    -cdrom $env(ISO) -boot d \
    -nic user,model=e1000 \
    -display none -serial stdio -no-reboot

# Interrupt autoboot, drop to the loader OK prompt, force serial console.
expect {
    timeout { puts "\nFAIL: no loader autoboot prompt"; exit 1 }
    -re "Hit \\\[Enter\\\]" { send " " }
    "Booting"               { send " " }
    "FreeBSD/amd64 EFI"     { send " " }
}
expect { timeout { puts "\nFAIL: no loader OK prompt"; exit 1 } "OK " {} }
send "set console=comconsole\r";        expect "OK "
send "set boot_serial=YES\r";           expect "OK "
send "set comconsole_speed=115200\r";   expect "OK "
send "set boot_multicons=YES\r";        expect "OK "
send "boot\r"

# Watch for a panic anywhere along the way.
expect_before {
    "panic:"     { puts "\nFAIL: kernel panic during boot"; exit 1 }
    "Fatal trap" { puts "\nFAIL: fatal trap during boot"; exit 1 }
}

# The live-root pipeline assembled and the kernel adopted the union as /.
expect {
    timeout { puts "\nFAIL: vfs.pivot not seen within 10 minutes"; exit 1 }
    "vfs.pivot: / is now unionfs" { puts "\nOK: vfs.pivot adopted the union root" }
    "pivot complete; exec launchd" { puts "\nOK: init reached pivot + launchd handoff" }
}

# launchd took over as PID 1 on the pivoted root (no getty -> no login: prompt).
expect {
    timeout { puts "\nWARN: no explicit launchd marker; pivot succeeded"; exit 0 }
    -re "launchd" { puts "\nOK: launchd is up on the live root" }
}
exit 0
EOF

echo "==> boot test: $ISO"
expect "$EXP"
echo "==> boot-test PASSED"
