# Browser stage 2

The Web Browser is now usable as an in-OS application:

- editable Address and Search fields
- Enter/Go/Search navigation
- Back and Reload
- clickable blue page links
- hover highlighting on buttons, fields, and links
- built-in HTTP pages for `core97/home`, `example.com`, `neverssl.com`, router/gateway, and `core97/status`
- cached DNS resolution for the demo hosts
- honest errors for unsupported HTTPS, missing hosts, and offline link state

This is intentionally not claiming to be a full internet browser yet. Live external pages still need the packet stack milestone: ARP + IPv4 + TCP sockets + HTTP GET + receive buffers.
