# Core97 QEMU hardware profiles

Default:

```sh
./build.sh
```

The default run keeps keyboard/mouse on PS/2 so Command Prompt, Start menu, and normal typing remain reliable. It still exposes USB controllers, E1000 networking, host RTC, and standard VGA.

USB HID experiment:

```sh
CORE97_PS2_ONLY=1 ./build.sh run
```

This adds `usb-kbd` and `usb-tablet`. Use it only while testing the USB HID stack; if Command Prompt stops receiving keyboard input, go back to the default profile.

Networking test commands inside Core97:

```text
NET
IPCONFIG
USB
DRIVERS
```
