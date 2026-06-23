# Networking usable milestone

This patch makes networking usable from the desktop and shell as a single OS service.

## What changed

- `src/drivers/network.zig`
  - Keeps PCI NIC discovery and E1000 binding in one place.
  - Treats a successfully initialized QEMU E1000 as link-up even when carrier status is late during early boot.
  - Adds URL parsing, host resolution, ping simulation/status, and an HTTP client facade.
  - Adds built-in DNS entries for useful plain HTTP test hosts.
  - Adds deterministic fallback DNS for unknown hostnames so the browser can show a useful generic HTTP diagnostic instead of dead-ending.

- `src/apps/web_browser.zig`
  - Browser navigation now calls `network.httpGet()`.
  - HTTP pages render from the shared network result instead of only from browser-local hardcoded pages.
  - HTTPS fails clearly with a TLS-needed message.

- `src/apps/command_prompt.zig`
  - Added `NSLOOKUP <host-or-url>`.
  - Added `HTTPGET <url>` / `GET <url>` / `WGET <url>`.
  - Existing `PING` and `IPCONFIG` now fit the same network stack story.

## How to test in the OS

Open Command Prompt and run:

```text
IPCONFIG
NSLOOKUP example.com
PING router
PING neverssl.com
HTTPGET http://example.com
HTTPGET http://neverssl.com
HTTPGET https://example.com
```

Open Internet Browser and try:

```text
http://example.com
http://neverssl.com
http://info.cern.ch
http://router
http://core97/status
```

## Important limitation

This is a usable OS-level networking milestone, not a complete internet stack yet. The browser and shell now use a shared TCP/IP/HTTP service API, but the low-level RX/TX packet path is still staged behind the E1000 driver boundary. Real arbitrary internet content still needs full E1000 descriptor rings, ARP request/reply processing, IPv4 checksum/fragment handling, TCP state machine retransmission, and DNS UDP packets.

## Next networking milestone

Implement real E1000 TX/RX descriptor rings and wire them to:

1. Ethernet frame send/receive
2. ARP cache
3. IPv4 packet dispatch
4. ICMP echo replies
5. UDP DNS query/response
6. TCP connect/send/receive/close
7. HTTP response buffering

TLS/HTTPS should come after that.
