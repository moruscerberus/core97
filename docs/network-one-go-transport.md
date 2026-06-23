# Network one-go transport pass

This pass moves Core97 networking from browser placeholders toward a reusable transport stack.

## Added in this pass

- E1000 packet counters: RX/TX packets and bytes.
- RX packet service loop: `network.serviceNetwork()` drains received descriptors.
- Ethernet demux for ARP and IPv4.
- ARP reply parser and in-kernel ARP cache.
- ARP cache lookup/resolution API.
- IPv4 checksum validation and protocol counters.
- TCP SYN path now routes through the gateway, uses ARP cache, and computes TCP pseudo-header checksum.
- TCP socket state struct/API seed: `tcpConnect()`.
- Browser HTTP facade now calls the transport path instead of only rendering placeholders.
- Command Prompt `NET` shows packet/protocol counters.
- Command Prompt `ARP` shows the kernel ARP cache.

## Test flow

Run Core97 with an Intel E1000 device, then in Command Prompt:

```text
NET
PING 10.0.2.2
ARP
HTTPGET http://example.com
NET
```

Expected progress:

1. `NET` shows E1000 link and RX/TX counters.
2. `PING` or `HTTPGET` sends ARP for the gateway.
3. `ARP` should show the gateway MAC after an ARP reply arrives.
4. `NET` should show increasing TX/RX counts.

## Remaining transport work

The next narrow work item is completing TCP receive state: parse SYN-ACK, send ACK, then move HTTP GET over the established stream. After that, HTTP response bytes can be handed to the existing HTML renderer.
