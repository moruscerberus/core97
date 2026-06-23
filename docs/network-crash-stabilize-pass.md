# Network crash stabilization pass

This pass fixes the HTTPGET -RAW crash path and makes the network tests more honest:

- `httpGet()` no longer opens a duplicate TCP SYN before `liveHttpGet()`.
- Removed the risky internal TCP retry that could leave stale SYN_SENT sessions.
- Shortened HTTP wait loops so the shell stays responsive.
- `PING` now drives gateway ARP resolution instead of claiming full Internet ICMP.
- `HTTPGET -RAW` is now safe: if no TCP payload arrives, it reports the transport state instead of trapping.

Current expected flow:

1. `NET`
2. `PING 10.0.2.2`
3. `ARP`
4. `HTTPGET -RAW http://example.com`

If HTTP still says SYN sent/no SYN-ACK, the remaining bug is TCP receive/state-machine or QEMU NIC mode, not the browser UI.
