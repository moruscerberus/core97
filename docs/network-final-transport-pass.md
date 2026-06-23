# Network final transport pass

This pass moves the browser from diagnostics-only networking toward a real packet/stream path.

Added in this pass:

- TCP session table
- SYN -> SYN/ACK -> ACK state transition handling
- TCP payload receive buffer
- TCP ACK generation for received payload
- HTTP/1.0 GET over the TCP session path
- live HTTP response capture and simple body text extraction
- improved pipeline status for NET/browser diagnostics

Browser behavior:

- Plain HTTP URLs now try the live TCP/HTTP path first.
- If hardware, ARP, TCP receive, or HTTP response bytes are not ready yet, the browser falls back to a clear diagnostic page instead of a blank page.
- HTTPS still requires the crypto/certificate layer before real modern sites can render.

Validation order:

1. `NET` should show E1000 rings and RX/TX counters.
2. `ARP` should populate after a route attempt.
3. `HTTPGET http://example.com` should send SYN, then HTTP GET once SYN/ACK arrives.
4. Browser should render live text from the response when bytes arrive.

Recommended QEMU line:

```sh
-device e1000,netdev=n0 -netdev user,id=n0
```

If SYN is sent but no SYN/ACK arrives, check that QEMU is actually exposing the E1000 device and that the PCI listing shows an Intel PRO/1000 adapter.
