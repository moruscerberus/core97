# Network/Web Browsing Pass

This pass keeps the Command Prompt UI consistent with the rest of the desktop and focuses the networking path on real plain-HTTP browsing.

Changes:

- Fixed the Command Prompt build issue by using the classic retro grey value directly.
- Restored `example.com` to the stable documentation address used by the HTTP tests.
- Zero-initialized generated Ethernet/IP/TCP frames before transmit.
- Added TCP last-packet diagnostics: flags, source/destination ports, source IP and retry count.
- Added a fallback TCP SYN without options if the first SYN does not establish.
- Improved HTTPGET failure messages so reset, pending handshake and pending body are distinct.

Suggested test order:

```
NET
ARP
PING 10.0.2.2
HTTPGET -RAW http://example.com
HTTPGET http://example.com
BROWSER
```

Plain HTTP is the target for this pass. HTTPS still requires the TLS crypto/certificate layer.
