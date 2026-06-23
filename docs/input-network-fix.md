# Input/network fix

Default `./build.sh` now keeps QEMU PS/2 keyboard and mouse as the working input path.
USB controllers are still exposed for Device Manager, but USB HID devices are opt-in:

```bash
CORE97_USB_INPUT=1 ./build.sh run
```

AC97 is also opt-in to avoid PipeWire warnings on WSL/Linux hosts:

```bash
CORE97_AUDIO=1 ./build.sh run
```

Command Prompt includes `PING`:

```cmd
PING 10.0.2.2
```
