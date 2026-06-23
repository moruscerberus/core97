# Core97 input mode

Default `./build.sh` uses PS/2 keyboard and mouse for active input.

USB controllers are still exposed by QEMU so Device Manager can detect UHCI/EHCI/xHCI while the OS remains usable.

Experimental USB HID input can be enabled with:

```bash
CORE97_USB_INPUT=1 ./build.sh run
```

If keyboard/mouse stop responding, rerun normal `./build.sh`. The PipeWire `client.conf` messages from QEMU are audio-backend warnings and are not the cause of keyboard/mouse failure.
