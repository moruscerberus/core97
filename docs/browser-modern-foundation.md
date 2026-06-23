# Browser modern-foundation pass

This pass does not claim Core97 has Chrome-level rendering. It makes the browser behave like a useful professional web client while laying out the next modern layers.

Implemented in this pass:

- Google now renders as a usable simplified search page instead of a generic TLS error/text placeholder.
- Search results are clickable and use the browser's existing navigation/history path.
- The top Search box acts like the page form: type text, press Search/Enter, get results.
- Existing DNS/HTTP facade remains centralized in `drivers/network.zig`.

Next real protocol work:

1. Replace DNS cache with UDP DNS packets.
2. Replace HTTP facade pages with real TCP receive buffers.
3. Add HTTP/1.1 response parsing, redirects, headers, chunked transfer, and gzip optional fallback.
4. Add TLS only after TCP receive/send paths are stable.
5. Add a tiny DOM and JavaScript interpreter after HTML text rendering works from real downloaded bytes.

Google in 2026 requires HTTPS, JS, CSS, DOM APIs, compression, cookies, and a modern layout engine. For Core97, the practical target is a simplified renderer first.
