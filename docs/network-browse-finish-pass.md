# Network browse finish pass

This pass removes the remaining fake external page path from the browser/HTTP command flow.

## What changed

- `network.initAll()` is now idempotent once E1000 rings are live. This prevents browser refreshes and command calls from resetting packet rings and TCP session state.
- Plain external `http://` URLs now call the live TCP/HTTP path and return its real transport result. They no longer fall through to canned Example/Google/Yahoo/etc pages.
- `HTTPGET -RAW <url>` now parses `-RAW` correctly instead of treating it as the URL.
- Raw HTTP response bytes are stored and printable from Command Prompt.
- Browser rendering uses the same live HTTP result path as the shell.

## Tests

Run these in order:

```text
NET
ARP
HTTPGET -RAW http://example.com
HTTPGET http://example.com
```

Expected for a real fetch:

```text
HTTP/1.1 200 OK
...
<!doctype html>
```

If `-RAW` says no raw bytes were received, the next target is TCP receive/ACK handling, not browser UI.

## HTTPS

Plain HTTP browsing is the target of this pass. HTTPS still requires real TLS crypto, certificate parsing, and encrypted record I/O.
