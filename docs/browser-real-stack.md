# Core97 real browser stack patch

This patch stops adding site-specific placeholder Google screens and starts splitting the browser into a real pipeline.

Added modules:

- `src/browser/engine.zig` - shared render pipeline/status
- `src/browser/tls.zig` - TLS record/session skeleton
- `src/browser/codecs.zig` - content-encoding dispatch
- `src/browser/html.zig` - tokenizer helpers
- `src/browser/css.zig` - default layout/style hooks
- `src/browser/dom.zig` - DOM node model
- `src/browser/js.zig` - JavaScript entry point
- `src/browser/storage.zig` - cookies/storage hooks

What works now:

- Browser no longer claims that Google is rendered.
- `http://core97/webstack` shows stack diagnostics.
- HTTP-like pages still render through the existing network facade.
- Google now displays the real blocker and next code stage instead of a placeholder page.

Next implementation step:

1. Implement NIC TX/RX ring operations for e1000.
2. Add Ethernet frame dispatch.
3. Add ARP cache and IPv4 packet parsing.
4. Add TCP connect/send/receive.
5. Make `network.httpGet()` use TCP bytes rather than synthetic page data.
6. Add TLS ClientHello and record parsing.
7. Add certificate validation and symmetric crypto.
8. Feed response bodies through codecs -> HTML tokenizer -> DOM -> layout.
