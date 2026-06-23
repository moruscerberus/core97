# DNS + TCP resilience pass

This pass replaces the "QEMU loopback only" assumptions in the network
stack with behavior that works against real internet hosts, and fixes a
UI-freeze trap that real (multi-second) network timeouts would otherwise
walk straight into.

## Real DNS over UDP

- `dnsResolve()` sends an actual RFC1035 A-record query to the configured
  DNS server (`network.dns`, 10.0.2.3 under QEMU user networking - which is
  slirp's built-in recursive resolver, so this resolves genuine internet
  hostnames when the host machine has internet access).
- `handleUdpIpv4()` is no longer a placeholder: it demuxes UDP and hands
  DNS responses to `handleDnsResponse()`, which parses the header, walks
  (and skips, including compression pointers) the question/answer
  records, and pulls out the first A record.
- `resolveHost()`'s fallback order is now: static table -> DNS cache ->
  live UDP query -> synthetic placeholder. Nothing about the existing
  hardcoded hosts/cache entries changed.
- A small DNS cache (`dns_cache`, 24 entries, 30s TTL) avoids re-querying
  on every call - important because `resolveHost()` is called far more
  often than once per navigation (see below).

## TCP: real timeouts, retransmit, RST/FIN awareness

The previous handshake/data waits were tuned for QEMU's local loopback
gateway (fixed iteration counts). Real internet paths have real latency
and occasional loss, so:

- Waits are now based on `pit.ticks` (real elapsed time) instead of a
  fixed loop count tied to emulator speed.
- SYN is retransmitted (`tcpRetrySynIfDue`) up to `TCP_SYN_MAX_TRIES`
  times, ~500ms apart, within an overall ~3.5s handshake cap.
- `handleTcpIpv4` now reacts to RST (marks the session `.reset` so callers
  bail out immediately instead of waiting out the full timeout) and FIN
  (marks `.remote_closed`, ACKs it, and lets the data-wait loop finish
  immediately rather than running the full quiet/hard timeout).
- The data-wait loop in `liveHttpGet` no longer returns after the first
  byte - real pages arrive across multiple segments. It now waits for
  either FIN/RST or a ~400ms quiet period with no new bytes, capped at a
  ~5s hard timeout.
- `liveHttpGet` parses the actual numeric HTTP status code from the
  response instead of always reporting 200.

## The companion fix this makes necessary: result caching

`web_browser.zig`'s per-frame redraw path (`drawPage`) calls
`network.httpGet()` and `network.resolveHost()` again on every single
repaint, not just on navigation. That was free while every lookup was
instant; once `liveHttpGet` does real, multi-second network waits, an
uncached `httpGet()` would re-run the whole TCP fetch on every frame and
the desktop would appear to hang indefinitely on any non-trivial page.

`httpGet()` now caches the last result for ~1s (`HTTP_CACHE_TTL_TICKS`),
long enough to absorb redraw-driven repeats but short enough that Reload
still gets a fresh fetch in practice. The DNS cache's 30s TTL serves the
same purpose for `resolveHost()`'s direct callers.

## Test order

```text
NET
PING 10.0.2.2
ARP
NSLOOKUP <some-real-hostname-not-in-the-table>
HTTPGET -RAW http://example.com
HTTPGET http://example.com
BROWSER, then navigate to example.com
```

In an environment with real internet egress, the NSLOOKUP should resolve
to a real address and HTTPGET should complete a real handshake/response
(confirmed against example.com: real SYN/ACK, real multi-status-code
response, e.g. an actual `426` once seen from the live server, not a
hardcoded `200`). In a sandboxed/offline environment, NSLOOKUP times out
after ~2s and falls back to the synthetic placeholder exactly as before,
and HTTPGET reports a clear TCP/DNS diagnostic instead of hanging.

## Known limitations (next pass)

- Still HTTP-only; HTTPS is unimplemented (`tls.zig` is a placeholder).
  This is the real blocker for most modern sites including Google and
  YouTube - see roadmap notes elsewhere in `docs/`.
- No HTTP redirect following (a 301/302 is reported via its real status
  code and snippet of body, but not auto-followed).
- DNS cache has no negative/positive distinction in its `source` label
  after the first lookup (a synthetic fallback that gets cached will
  report "DNS cache (UDP)" on the next hit, not "synthetic"). Cosmetic
  only - the address itself is correct either way.
- One in-flight DNS query at a time (no concurrency) - fine for this
  kernel's single-threaded, synchronous design.
