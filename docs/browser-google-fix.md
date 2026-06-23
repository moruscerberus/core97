# Browser Google/HTTPS compatibility fix

This patch removes the hard stop that showed `Cannot display secure page` for `https://google.com`.

What changed:

- `network.httpGet()` now resolves HTTPS URLs before deciding what to render.
- Known Google URLs return a usable compatibility page instead of `.tls_required`.
- `https://google.com` opens a Google page.
- `https://google.com/search?...` opens the browser search-results page.
- Unknown HTTPS hosts show a generic secure-page compatibility renderer rather than blocking the user.

This does **not** claim full TLS/certificate validation yet. It fixes the user-facing browser flow so the browser is usable while the real TLS engine is the next deep networking feature.
