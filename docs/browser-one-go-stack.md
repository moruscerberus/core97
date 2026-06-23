# Core97 browser one-go stack patch

This patch moves the browser from site-specific placeholder pages toward a single browser pipeline.

Implemented in this pass:

- `browser/http.zig`: HTTP/1.x request builder and response parser
- `browser/tls.zig`: TLS session state and ClientHello/SNI byte builder skeleton
- `browser/codecs.zig`: content-encoding detection and safe identity handling
- `browser/html.zig`: forgiving HTML-to-text renderer, entity handling, link extraction
- `browser/css.zig`: default display/style model
- `browser/dom.zig`: flat DOM document/node model
- `browser/js.zig`: safe tiny JavaScript entry point that ignores unsupported JS instead of crashing
- `browser/storage.zig`: in-memory cookie/local storage API shape
- `browser/engine.zig`: one shared render path instead of site-specific placeholder pages

What this fixes now:

- HTTPS no longer claims to be Google. It reaches the TLS stage and reports the true missing crypto/socket pieces.
- Plain HTTP pages go through the browser pipeline: fetch facade -> codec dispatch -> HTML text renderer.
- The architecture now has named modules for all modern browser pieces so each can be completed independently.

Still required for actual live modern sites:

1. Real NIC RX/TX rings for E1000/RTL8139/VirtIO.
2. ARP and IPv4 packet send/receive.
3. TCP state machine and stream buffers.
4. TLS crypto: SHA-256/HMAC, AES-GCM or ChaCha20-Poly1305, ECDHE, X.509 certificate validation.
5. gzip inflater.
6. Full HTML tokenizer/tree builder.
7. CSS cascade/layout.
8. Larger JavaScript engine and DOM bindings.

Next best milestone: make `HTTPGET http://example.com` print bytes received from a real TCP stream, not the facade.
