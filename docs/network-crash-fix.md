# Network crash fix pass

This pass focuses on stability before further browser work.

Changes:
- Hardened E1000 RX descriptor handling.
- Rejects zero-length, oversized, and errored RX descriptors before slicing packet buffers.
- Clears and recycles bad RX descriptors instead of letting Zig trap on out-of-bounds slices.
- Avoids polling hardware from repeated `initAll()` calls.
- Keeps QEMU gateway ARP usable for `10.0.2.2` diagnostics.
- Zero-initializes generated ARP/TCP frames before transmit.

Test order:

```text
NET
PING 10.0.2.2
ARP
HTTPGET -RAW http://example.com
```

If networking still does not fetch HTTP, the next work is TCP SYN/SYN-ACK state handling, but these commands should not bluescreen.
