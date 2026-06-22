#!/usr/bin/env bash
# build.sh - assemble + compile + link + ISO + boot Core97 in QEMU.
#
# Usage:
#   ./build.sh              build and boot in QEMU (windowed, 1:1 pixels)
#   ./build.sh build        build only (kernel.bin + ISO), don't launch QEMU
#   ./build.sh run          boot the most recently built ISO without rebuilding
#   ./build.sh fullscreen   same, but -full-screen - still 1:1, letterboxed
#   ./build.sh                 USB keyboard/mouse enabled by default; PS/2 fallback kept
#                           instead of stretched (see do_run's comment below)
#   ./build.sh clean        remove the build/ directory
#
# Requires: nasm, a Zig compiler, GNU ld (binutils), grub-mkrescue + xorriso,
# qemu-system-i386 (or qemu-system-x86_64). See the dependency check below
# for exact package names if something's missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
ISODIR="$BUILD/isodir"
ISO="$BUILD/core97.iso"
KERNEL_BIN="$BUILD/kernel.bin"

ARCH_DIR="$SRC/arch/x86"
TARGET="x86-freestanding-none"
# IMPORTANT: do not use "-mcpu=baseline" here. On this target it still
# permits SSE2 codegen (LLVM will lower plain struct/array copies to
# movdqa/movaps), but this kernel never enables SSE (no CR0/CR4 setup,
# no FXSAVE area) - the first such instruction raises #UD, which
# cascades GPF -> double fault -> triple fault -> CPU reset. From the
# outside that looks exactly like an infinite boot loop back to GRUB.
# pentium3 is the oldest model Zig/LLVM knows that has no SSE/SSE2/MMX
# vector codegen, which is what we actually want for a freestanding
# 32-bit kernel that never touches the FPU/SSE state.
OPT="ReleaseSmall"   # Debug build pulls in std.debug panic machinery that
                      # needs compiler-rt's stack-probe support, which isn't
                      # linked in this freestanding setup - ReleaseSmall
                      # avoids that and matches what's already in build/.

# --- Locate a Zig compiler ------------------------------------------------
# Prefers a real `zig` on PATH; falls back to the `ziglang` PyPI package
# (a redistributed prebuilt Zig binary), which is handy in containers/CI
# that can't reach ziglang.org directly: `pip install ziglang`.
find_zig() {
    if command -v zig >/dev/null 2>&1; then
        echo "zig"
        return
    fi
    if python3 -c "import ziglang" >/dev/null 2>&1; then
        echo "python3 -m ziglang"
        return
    fi
    return 1
}

check_deps() {
    local missing=()
    command -v nasm >/dev/null 2>&1 || missing+=("nasm")
    command -v ld >/dev/null 2>&1 || missing+=("binutils (ld)")
    command -v grub-mkrescue >/dev/null 2>&1 || missing+=("grub-pc-bin / grub-common (grub-mkrescue)")
    command -v xorriso >/dev/null 2>&1 || missing+=("xorriso")
    ZIG="$(find_zig)" || missing+=("a Zig compiler (install 'zig', or 'pip install ziglang --break-system-packages')")

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Missing dependencies:" >&2
        for m in "${missing[@]}"; do echo "  - $m" >&2; done
        echo "" >&2
        echo "On Debian/Ubuntu:" >&2
        echo "  sudo apt-get install -y nasm grub-pc-bin grub-common xorriso qemu-system-x86" >&2
        echo "  pip install ziglang --break-system-packages   # if you don't have zig on PATH" >&2
        exit 1
    fi
}

find_qemu() {
    if command -v qemu-system-i386 >/dev/null 2>&1; then
        echo "qemu-system-i386"
    elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo "qemu-system-x86_64"
    else
        echo "No qemu-system-i386 / qemu-system-x86_64 found. Install with:" >&2
        echo "  sudo apt-get install -y qemu-system-x86" >&2
        exit 1
    fi
}

# Picks the best available "don't stretch the framebuffer" display flag
# for whatever QEMU build is actually installed. GTK's zoom-to-fit=off
# is the real fix (default is "on", which scales the guest's 1024x768
# image to fill the window/screen - exactly the stretched look); SDL
# doesn't auto-stretch in a window so it's a fine fallback if GTK
# support wasn't compiled in. Headless (-display none) builds can't
# show a GUI at all - flagged separately rather than silently failing.
find_display_flag() {
    local qemu="$1"
    local available
    available="$("$qemu" -display help 2>/dev/null)"
    if echo "$available" | grep -qx "gtk"; then
        echo "-display gtk,zoom-to-fit=off"
    elif echo "$available" | grep -qx "sdl"; then
        echo "-display sdl"
    else
        echo "This QEMU build has no gtk/sdl display backend - it's headless." >&2
        echo "Install a build with GUI support, e.g.: sudo apt-get install -y qemu-system-gui" >&2
        exit 1
    fi
}

do_build() {
    check_deps
    mkdir -p "$BUILD" "$ISODIR/boot/grub"

    echo "[1/4] Assembling boot.asm + interrupts.asm..."
    nasm -f elf32 "$ARCH_DIR/boot.asm" -o "$BUILD/boot.o"
    nasm -f elf32 "$ARCH_DIR/interrupts.asm" -o "$BUILD/interrupts.o"

    echo "[2/4] Compiling Zig kernel ($ZIG, -target $TARGET -O $OPT)..."
    $ZIG build-obj "$SRC/main.zig" \
        -target "$TARGET" -mcpu=pentium3 -O "$OPT" \
        -femit-bin="$BUILD/kernel_zig.o"

    echo "[3/4] Linking kernel.bin..."
    ld -m elf_i386 -T "$ARCH_DIR/linker.ld" -o "$KERNEL_BIN" \
        "$BUILD/boot.o" "$BUILD/interrupts.o" "$BUILD/kernel_zig.o"

    echo "[4/4] Building bootable ISO..."
    cp "$KERNEL_BIN" "$ISODIR/boot/kernel.bin"
    # set timeout=1/default=0 so it boots straight in without needing a
    # keypress - handy for quick `./build.sh run` iteration. Edit
    # src/arch/x86/grub.cfg directly if you'd rather have the GRUB menu
    # wait for you.
    {
        echo "set timeout=1"
        echo "set default=0"
        cat "$ARCH_DIR/grub.cfg"
    } > "$ISODIR/boot/grub/grub.cfg"
    grub-mkrescue -o "$ISO" "$ISODIR" >/dev/null 2>&1 || grub-mkrescue -o "$ISO" "$ISODIR"

    echo "Built $ISO"
}

qemu_hw_args() {
    # SAFE DEFAULT HARDWARE PROFILE
    #
    # The OS is still using PS/2 for real keyboard/mouse input. USB controller
    # detection stays enabled, but USB HID devices are NOT attached by default
    # because QEMU will route input to them and the unfinished USB HID path can
    # make the desktop feel dead.
    #
    # Normal dev loop:
    #   ./build.sh
    #
    # Experimental modes:
    #   CORE97_USB_INPUT=1 ./build.sh run   # attach USB keyboard/mouse/tablet
    #   CORE97_AUDIO=1 ./build.sh run       # attach AC97 audio
    local args="-machine pc -vga std -m 512 -rtc base=localtime,clock=host"

    # Keep QEMU's standard i8042/PS2 keyboard + mouse active. Do not add any USB
    # HID devices here by default.

    # USB controllers only: visible in Device Manager, no input stealing.
    args="$args -usb"
    args="$args -device usb-ehci,id=ehci"
    args="$args -device qemu-xhci,id=xhci"

    if [ "${CORE97_USB_INPUT:-0}" = "1" ]; then
        args="$args -device usb-kbd"
        args="$args -device usb-mouse"
        args="$args -device usb-tablet"
    fi

    # Networking: keep E1000 as the active target. Extra common NICs are present
    # for detection/binding, but NET/IPCONFIG should prefer E1000.
    args="$args -netdev user,id=net0,hostfwd=tcp::10097-:7 -device e1000,netdev=net0"
    args="$args -netdev user,id=net1 -device rtl8139,netdev=net1"
    args="$args -netdev user,id=net2 -device virtio-net-pci,netdev=net2"

    # AC97 can trigger noisy PipeWire warnings on some WSL/Linux hosts. Leave it
    # opt-in until the audio driver is being actively tested.
    if [ "${CORE97_AUDIO:-0}" = "1" ]; then
        args="$args -audiodev none,id=noaudio -device AC97,audiodev=noaudio"
    fi

    echo "$args"
}

do_run() {
    [ -f "$ISO" ] || { echo "No ISO at $ISO yet - run './build.sh build' first." >&2; exit 1; }
    QEMU="$(find_qemu)"
    DISPLAY_FLAG="$(find_display_flag "$QEMU")"
    echo "Booting $ISO with $QEMU (close the window, or Ctrl+C here, to stop)..."
    # shellcheck disable=SC2086
    "$QEMU" -cdrom "$ISO" $(qemu_hw_args) $DISPLAY_FLAG
}

do_run_fullscreen() {
    [ -f "$ISO" ] || { echo "No ISO at $ISO yet - run './build.sh build' first." >&2; exit 1; }
    QEMU="$(find_qemu)"
    DISPLAY_FLAG="$(find_display_flag "$QEMU")"
    # grab-on-hover matters here specifically: a fullscreen window has no
    # titlebar to click for focus, so without this the window can look
    # completely unresponsive to mouse/keyboard until you find some way
    # to click into it. Only meaningful for gtk; harmless to append to
    # the sdl fallback's flag string (gtk-only options are simply
    # ignored by other backends).
    if [ "$DISPLAY_FLAG" = "-display gtk,zoom-to-fit=off" ]; then
        DISPLAY_FLAG="-display gtk,zoom-to-fit=off,grab-on-hover=on"
    fi
    echo "Booting $ISO fullscreen with $QEMU..."
    echo "If input doesn't respond: click the window once, or Ctrl+Alt+G to grab/release the mouse."
    echo "Ctrl+Alt+F toggles fullscreen off; Ctrl+Alt+2 switches to the QEMU monitor if it's stuck."
    # shellcheck disable=SC2086
    "$QEMU" -cdrom "$ISO" $(qemu_hw_args) $DISPLAY_FLAG -full-screen
}

do_clean() {
    rm -rf "$BUILD"
    echo "Removed $BUILD"
}

case "${1:-all}" in
    build)      do_build ;;
    run)        do_run ;;
    fullscreen) do_run_fullscreen ;;
    clean)      do_clean ;;
    all)        do_build; do_run ;;
    *)
        echo "Usage: $0 [build|run|fullscreen|clean]" >&2
        exit 1
        ;;
esac
