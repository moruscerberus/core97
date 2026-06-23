# Network/browser finish pass

This pass focuses on the real blocker shown by `HTTPGET -RAW`: TCP SYN was sent, but the stack did not transition to ESTABLISHED.

Changes:

- Updated `example.com` resolver cache to a current Akamai address instead of the old `93.184.216.34` address.
- Added TCP MSS option to SYN packets.
- Added TCP checksum diagnostics without hard-dropping packets during early emulator bring-up.
- Added fallback TCP session matching by local ephemeral port so NAT/emulator edge cases do not silently discard SYN-ACKs.
- Added TCP FIN/RST accounting and more complete ACK handling.
- Increased network polling during connect/HTTP receive.
- Added NET diagnostics for SYN-ACK, established sockets, HTTP bytes, checksum issues, unmatched TCP packets, and last TCP flags.
- Modernized Command Prompt rendering toward a contemporary terminal style while keeping the same commands.

Test order:

```text
NET
PING 10.0.2.2
ARP
HTTPGET -RAW http://example.com
HTTPGET http://example.com
```

Success means `HTTPGET -RAW` starts with real HTTP headers like:

```text
HTTP/1.1 200 OK
```

If it still fails, run `NET` immediately afterward and check the new TCP debug line.
