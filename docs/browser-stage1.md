# Internet Browser stage 1

The browser is now an interactive app rather than a static placeholder:

- Opens to `http://google.com` by default.
- Address bar accepts hostnames, IPv4 addresses, and `http://` URLs.
- Search box submits to a Google-style search page.
- Renders built-in HTTP test pages for `google.com`, `example.com`, `neverssl.com`, router/gateway, and literal IP hosts.
- Shows honest errors for HTTPS/TLS and unknown DNS names.

Next real protocol work:

1. ARP cache and packet TX/RX completion.
2. TCP sockets.
3. HTTP GET parser.
4. DNS packet resolver instead of early cache.
5. TLS/HTTPS later.
