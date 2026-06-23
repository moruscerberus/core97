# HTTPGET crash fix

This pass fixes the crash where `HTTPGET -RAW http://example.com` could blue-screen while ping/ARP still worked.

Changes:

- `HTTPGET -RAW` is parsed as a flag. The URL is now the token after `-RAW`.
- Raw mode calls `network.liveHttpGet()` directly so it reports live TCP/HTTP state instead of falling through the friendly browser page fallback.
- Removed a duplicate `tcpConnect()` from the general `httpGet()` facade. The browser no longer opens an extra TCP session before the live path runs.
- Moved the large TCP frame and HTTP request buffers out of local stack frames into reusable network work buffers. This avoids kernel stack corruption / invalid-opcode traps during TCP send paths.

Test order:

```text
NET
PING 10.0.2.2
ARP
HTTPGET -RAW http://example.com
HTTPGET http://example.com
```
