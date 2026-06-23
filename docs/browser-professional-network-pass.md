# Browser professional network pass

This pass removes the temporary retro/1995 wording from the visible browser UI and replaces it with professional networking/browser status text.

Changes:

- Removed visible 1995/retro placeholder copy from browser pages and network status strings.
- Kept the honest HTTPS status: the browser reaches DNS and TLS setup, but true encrypted page download still needs the packet/TCP layer finished.
- Fixed generated Zig syntax in `browser/html.zig` and browser/engine helpers that could fail builds on stricter Zig versions.
- Browser home, diagnostics, HTTP pages, and Google/HTTPS blocker now use neutral product wording.

Current hard blocker:

- The browser pipeline exists above the network API, but live HTTPS requires real E1000 RX/TX packet rings, ARP/IPv4/TCP stream buffers, cryptography, certificate validation, and decompression.

Next implementation target:

1. E1000 descriptor rings and interrupt/poll receive path.
2. Ethernet frame send/receive API.
3. ARP cache and IPv4 packet dispatcher.
4. TCP connect/send/receive state machine.
5. Feed received HTTP bytes into `browser/http.zig` and `browser/html.zig`.
