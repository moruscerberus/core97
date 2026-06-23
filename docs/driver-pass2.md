# Driver pass 2

This pass makes the driver layer more universal without claiming to have full
vendor GPU/NIC drivers yet.

Added:

- `drivers/display.zig`
  - Names QEMU/Bochs VGA, VirtualBox, VMware SVGA, VirtIO GPU, AMD Radeon,
    NVIDIA GeForce and Intel graphics.
  - Reports the active framebuffer scaling mode.

- `drivers/network.zig`
  - Names common Intel, Realtek, VirtIO, VMware, Broadcom and Qualcomm/Atheros
    NICs.
  - Binds detected NICs to an intended driver family: e1000, rtl8139,
    realtek-gbe, intel-gbe, virtio-net, vmxnet3, etc.
  - `NET` / `IPCONFIG` shell command reports detected adapters and the planned
    driver.

- Guest detection
  - Detects QEMU/KVM, VirtIO, VirtualBox and VMware from PCI IDs.
  - Scaling status now covers 100%, 125%, 150% and 200% framebuffer modes.

- Device Manager / shell integration
  - Device Manager now uses shared display/network naming logic.
  - `DISPLAY` shell command reports the active graphics adapter/status.

This is still detection + driver binding. Real packet TX/RX should start with
E1000 or VirtIO-net next.
