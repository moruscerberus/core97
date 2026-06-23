# Core97 Networking Step: E1000 -> ARP/IP/TCP -> HTTPS

This patch moves the networking work from UI diagnostics into the hardware-facing path.

## Added

- E1000 RX/TX descriptor rings.
- Static DMA packet buffers.
- Receiver/transmitter MMIO register setup.
- Polling `sendPacket()` and `pollPacket()` API.
- ARP request packet builder.
- IPv4 header checksum helper.
- TCP SYN packet builder for ports 80/443.
- Browser status now reports the real transport stage instead of retro/demo wording.

## Still required before live HTTPS pages render

- ARP cache and gateway MAC resolution.
- TCP state machine: SYN/SYN-ACK/ACK, sequence numbers, retransmit, receive windows.
- TCP stream buffers connected to `browser/http.zig`.
- TLS crypto: SHA-256/HMAC, AES-GCM or ChaCha20-Poly1305, ECDHE, certificate chain validation.
- HTTP response body decoding and renderer feed.

## Test order

1. Boot with QEMU e1000 enabled.
2. Open Device Manager and confirm the Intel PRO/1000 adapter is link-up.
3. Open `http://core97/webstack`.
4. Use Command Prompt `PING 10.0.2.2`, then `HTTPGET http://example.com`.

The important milestone in this patch is that the OS now owns RX/TX rings and can place real Ethernet frames on the adapter path.
