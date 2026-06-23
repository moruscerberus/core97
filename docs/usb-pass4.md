# USB pass 4

Adds the next USB usability layer:

- UHCI root-hub rescan at boot.
- Port-aware USB HID device table.
- VID/PID, address, endpoint and port displayed by shell/Device Manager.
- Hotplug-style polling: connect/disconnect changes trigger a rescan.
- `USBSCAN` / `USBREFRESH` command to force a rescan from Command Prompt.
- PS/2 keyboard/mouse stay enabled as fallback so the shell remains usable while USB HID matures.

Expected QEMU behavior:

- Default `./build.sh` keeps stable PS/2 input and exposes USB controllers.
- `CORE97_PS2_ONLY=1 ./build.sh run` runs emergency PS/2-only input fallback.

Not yet included:

- USB mass storage.
- Full EHCI/xHCI transfer scheduling.
- Class drivers beyond basic HID enumeration/polling.
