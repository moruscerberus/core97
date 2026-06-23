# Driver / USB / Network pass 3

This pass moves the OS from "device names in Device Manager" toward a real driver model.

## Driver architecture

- `drivers/driver_registry.zig` now represents a driver manager, not only a flat display list.
- Drivers now show `Detected`, `Bound`, `Loaded`, `Running`, `Missing`, `Failed`, or `Stub`.
- PCI class fallback remains active so unknown hardware still appears instead of disappearing.
- PCI devices now record BAR0-BAR5, IRQ line/pin, command, and status fields.

## USB

- New `drivers/usb.zig` service layer.
- Detects UHCI, OHCI, EHCI, xHCI, and generic USB controllers.
- UHCI remains the implemented controller path.
- OHCI/EHCI/xHCI are visible and bound to generic placeholders so real hardware is visible in Device Manager.
- Shell command added: `USB`.
- USB HID devices and native PS/2 devices are both surfaced.

## Networking

- `drivers/network.zig` now has an adapter table and binding states.
- Common NIC families are recognized: Intel E1000/e1000e/I21x/I22x, Realtek RTL8139/8168/8169/8125, VirtIO-net, VMware VMXNET3, Broadcom, Qualcomm/Atheros, AMD PCnet, NE2000-class fallback.
- PCI command bits are enabled for bound NICs.
- Shell `NET`/`IPCONFIG` now shows driver, state, resources, and a temporary deterministic MAC placeholder.

## Next low-level step

Implement real packet RX/TX for E1000 first:

1. map BAR0 MMIO
2. reset controller
3. read EEPROM/MAC
4. allocate RX/TX descriptor rings
5. receive raw Ethernet frames
6. transmit raw Ethernet frames
7. ARP, ICMP ping, DHCP
