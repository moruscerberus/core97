// apps/command_prompt.zig - Core97-style Command Prompt.
// Kernel-backed shell for early OS introspection and RAM VFS work.

const fb = @import("../gui/framebuffer.zig");
const window = @import("../gui/window.zig");
const keymap = @import("keymap.zig");
const pci = @import("../drivers/pci.zig");
const memory = @import("../kernel/memory.zig");
const pit = @import("../drivers/pit.zig");
const power = @import("../kernel/power.zig");
const vfs = @import("../fs/vfs.zig");
const notepad = @import("notepad.zig");
const driver_registry = @import("../drivers/driver_registry.zig");
const guest = @import("../drivers/guest.zig");
const audio = @import("../drivers/audio.zig");
const network = @import("../drivers/network.zig");
const usb = @import("../drivers/usb.zig");
const usb_hid = @import("../drivers/usb_hid.zig");
const display = @import("../drivers/display.zig");
const input = @import("../drivers/input.zig");

const MAX_LINES: usize = 128;
const LINE_LEN: usize = 112;
const INPUT_MAX: usize = 96;

const CommandPrompt = struct {
    lines: [MAX_LINES][LINE_LEN]u8 = undefined,
    line_lens: [MAX_LINES]usize = [_]usize{0} ** MAX_LINES,
    line_count: usize = 0,
    input: [INPUT_MAX]u8 = undefined,
    input_len: usize = 0,
    cwd: vfs.NodeHandle = vfs.INVALID_HANDLE,
    initialized: bool = false,
    pending_launch: ?window.BuiltinApp = null,

    fn ensureInit(self: *CommandPrompt) void {
        if (self.initialized) return;
        self.initialized = true;
        self.line_count = 0;
        self.input_len = 0;
        self.cwd = vfs.resolvePath("/users/default") orelse vfs.root;
        self.println("Core97 [Version 0.04]");
        self.println("Core97 Kernel Shell");
        self.println("");
        self.println("Type HELP for a list of commands.");
        self.println("");
    }

    fn clear(self: *CommandPrompt) void {
        self.line_count = 0;
        self.input_len = 0;
    }

    fn pushLine(self: *CommandPrompt, text: []const u8) void {
        if (self.line_count >= MAX_LINES) {
            var i: usize = 1;
            while (i < MAX_LINES) : (i += 1) {
                self.line_lens[i - 1] = self.line_lens[i];
                var j: usize = 0;
                while (j < self.line_lens[i] and j < LINE_LEN) : (j += 1) self.lines[i - 1][j] = self.lines[i][j];
            }
            self.line_count = MAX_LINES - 1;
        }
        const idx = self.line_count;
        var n: usize = 0;
        while (n < text.len and n < LINE_LEN) : (n += 1) self.lines[idx][n] = text[n];
        self.line_lens[idx] = n;
        self.line_count += 1;
    }

    fn println(self: *CommandPrompt, text: []const u8) void { self.pushLine(text); }

    fn appendText(buf: []u8, pos: *usize, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len and pos.* < buf.len) : (i += 1) {
            buf[pos.*] = text[i];
            pos.* += 1;
        }
    }

    fn appendDec(buf: []u8, pos: *usize, value: usize) void {
        if (value == 0) {
            if (pos.* < buf.len) { buf[pos.*] = '0'; pos.* += 1; }
            return;
        }
        var tmp: [20]u8 = undefined;
        var n = value;
        var len: usize = 0;
        while (n > 0 and len < tmp.len) : (len += 1) {
            tmp[len] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        while (len > 0 and pos.* < buf.len) {
            len -= 1;
            buf[pos.*] = tmp[len];
            pos.* += 1;
        }
    }

    fn hexDigit(n: u8) u8 { return if (n < 10) '0' + n else 'A' + (n - 10); }

    fn appendHex16(buf: []u8, pos: *usize, value: u16) void {
        if (pos.* + 6 > buf.len) return;
        buf[pos.*] = '0'; pos.* += 1;
        buf[pos.*] = 'x'; pos.* += 1;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const shift: u4 = @intCast((3 - i) * 4);
            buf[pos.*] = hexDigit(@intCast((value >> shift) & 0xF));
            pos.* += 1;
        }
    }

    fn appendHexByte(buf: []u8, pos: *usize, value: u8) void {
        if (pos.* + 2 > buf.len) return;
        buf[pos.*] = hexDigit((value >> 4) & 0xF); pos.* += 1;
        buf[pos.*] = hexDigit(value & 0xF); pos.* += 1;
    }

    fn upper(c: u8) u8 { return if (c >= 'a' and c <= 'z') c - 32 else c; }

    fn streq(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var i: usize = 0;
        while (i < a.len) : (i += 1) { if (upper(a[i]) != upper(b[i])) return false; }
        return true;
    }

    fn trim(s: []const u8) []const u8 {
        var a: usize = 0;
        var b: usize = s.len;
        while (a < b and (s[a] == ' ' or s[a] == '\t')) : (a += 1) {}
        while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) : (b -= 1) {}
        return s[a..b];
    }

    fn firstToken(s: []const u8) []const u8 {
        const t = trim(s);
        var i: usize = 0;
        while (i < t.len and t[i] != ' ' and t[i] != '\t') : (i += 1) {}
        return t[0..i];
    }

    fn restAfterFirst(s: []const u8) []const u8 {
        const t = trim(s);
        var i: usize = 0;
        while (i < t.len and t[i] != ' ' and t[i] != '\t') : (i += 1) {}
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
        return t[i..];
    }

    fn isSep(c: u8) bool { return c == '/' or c == '\\'; }

    fn appendPath(self: *CommandPrompt, buf: []u8, pos: *usize) void {
        appendText(buf, pos, "C:");
        var stack: [16]vfs.NodeHandle = undefined;
        var count: usize = 0;
        var h = self.cwd;
        while (h != vfs.INVALID_HANDLE and h != vfs.root and count < stack.len) {
            stack[count] = h;
            count += 1;
            h = vfs.parentOf(h);
        }
        appendText(buf, pos, "\\");
        while (count > 0) {
            count -= 1;
            appendText(buf, pos, vfs.nameOf(stack[count]));
            if (count > 0) appendText(buf, pos, "\\");
        }
    }

    fn promptLine(self: *CommandPrompt) void {
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        self.appendPath(&buf, &p);
        appendText(&buf, &p, ">");
        appendText(&buf, &p, self.input[0..self.input_len]);
        self.pushLine(buf[0..p]);
    }

    fn resolveFrom(self: *CommandPrompt, path_raw: []const u8) ?vfs.NodeHandle {
        const path = trim(path_raw);
        if (path.len == 0) return self.cwd;
        var current = self.cwd;
        var i: usize = 0;
        if (path.len >= 2 and path[1] == ':') i = 2;
        if (i < path.len and isSep(path[i])) {
            current = vfs.root;
            while (i < path.len and isSep(path[i])) : (i += 1) {}
        }
        while (i <= path.len) {
            var j = i;
            while (j < path.len and !isSep(path[j])) : (j += 1) {}
            if (j > i) {
                const seg = path[i..j];
                if (streq(seg, ".")) {
                } else if (streq(seg, "..")) {
                    if (current != vfs.root) current = vfs.parentOf(current);
                } else {
                    current = vfs.findChild(current, seg) orelse return null;
                }
            }
            if (j >= path.len) break;
            i = j + 1;
        }
        return current;
    }

    fn splitParent(self: *CommandPrompt, path_raw: []const u8, name_out: *[]const u8) ?vfs.NodeHandle {
        const path = trim(path_raw);
        if (path.len == 0) return null;
        var last_sep: ?usize = null;
        var i: usize = 0;
        while (i < path.len) : (i += 1) { if (isSep(path[i])) last_sep = i; }
        if (last_sep) |s| {
            var start = s + 1;
            while (start < path.len and isSep(path[start])) : (start += 1) {}
            if (start >= path.len) return null;
            name_out.* = path[start..];
            if (s == 0) return vfs.root;
            return self.resolveFrom(path[0..s]);
        }
        name_out.* = path;
        return self.cwd;
    }

    fn printTextBlock(self: *CommandPrompt, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            var j = i;
            while (j < data.len and data[j] != '\n' and data[j] != '\r') : (j += 1) {}
            self.println(data[i..j]);
            while (j < data.len and (data[j] == '\n' or data[j] == '\r')) : (j += 1) {}
            i = j;
        }
        if (data.len == 0) self.println("");
    }

    fn printDir(self: *CommandPrompt, dir: vfs.NodeHandle) void {
        if (vfs.kindOf(dir) != .directory) { self.println("Not a directory"); return; }
        var pathbuf: [LINE_LEN]u8 = undefined;
        var pp: usize = 0;
        appendText(&pathbuf, &pp, " Directory of ");
        const old = self.cwd;
        self.cwd = dir;
        self.appendPath(&pathbuf, &pp);
        self.cwd = old;
        self.println(pathbuf[0..pp]);
        self.println("");
        var i: usize = 0;
        while (i < vfs.childCount(dir)) : (i += 1) {
            const child = vfs.childAt(dir, i);
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            if (vfs.kindOf(child) == .directory) {
                appendText(&buf, &p, "<DIR>        ");
            } else {
                appendDec(&buf, &p, vfs.fileSize(child));
                appendText(&buf, &p, " bytes     ");
            }
            appendText(&buf, &p, vfs.nameOf(child));
            self.println(buf[0..p]);
        }
    }

    fn printTree(self: *CommandPrompt, dir: vfs.NodeHandle, depth: usize) void {
        var i: usize = 0;
        while (i < vfs.childCount(dir)) : (i += 1) {
            const child = vfs.childAt(dir, i);
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            var d: usize = 0;
            while (d < depth and p + 2 < LINE_LEN) : (d += 1) appendText(&buf, &p, "  ");
            if (vfs.kindOf(child) == .directory) appendText(&buf, &p, "[+") else appendText(&buf, &p, "   ");
            if (vfs.kindOf(child) == .directory) appendText(&buf, &p, "] ");
            appendText(&buf, &p, vfs.nameOf(child));
            self.println(buf[0..p]);
            if (vfs.kindOf(child) == .directory) self.printTree(child, depth + 1);
        }
    }

    fn printMem(self: *CommandPrompt) void {
        const s = memory.stats();
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Total memory: "); appendDec(&buf, &p, @as(usize, @intCast(s.total_kib))); appendText(&buf, &p, " KB"); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Free memory : "); appendDec(&buf, &p, @as(usize, @intCast(s.free_kib))); appendText(&buf, &p, " KB"); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Pages       : "); appendDec(&buf, &p, @as(usize, @intCast(s.total_pages))); appendText(&buf, &p, " total, "); appendDec(&buf, &p, @as(usize, @intCast(s.free_pages))); appendText(&buf, &p, " free"); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Heap        : "); appendDec(&buf, &p, @as(usize, @intCast(s.heap_used))); appendText(&buf, &p, " / "); appendDec(&buf, &p, @as(usize, @intCast(s.heap_total))); appendText(&buf, &p, " bytes"); self.println(buf[0..p]);
    }

    fn printPci(self: *CommandPrompt) void {
        self.println("LOC   VENDOR DEVICE CLASS");
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            const d = pci.devices[i];
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            appendDec(&buf, &p, @as(usize, @intCast(d.bus))); appendText(&buf, &p, ":"); appendDec(&buf, &p, @as(usize, @intCast(d.device))); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, @intCast(d.function)));
            appendText(&buf, &p, "  "); appendHex16(&buf, &p, d.vendor_id); appendText(&buf, &p, " "); appendHex16(&buf, &p, d.device_id);
            appendText(&buf, &p, " "); appendText(&buf, &p, pci.className(d.class_code, d.subclass));
            self.println(buf[0..p]);
        }
    }

    fn printDevices(self: *CommandPrompt) void {
        self.println("Display adapters");
        if (display.firstAdapter()) |gpu| {
            var dbuf: [LINE_LEN]u8 = undefined;
            var dp: usize = 0;
            appendText(&dbuf, &dp, "  ");
            appendText(&dbuf, &dp, display.deviceName(gpu));
            self.println(dbuf[0..dp]);
        } else {
            self.println("  Basic Display Adapter");
        }
        self.println("Keyboards");
        self.println("  Standard PS/2 Keyboard");
        self.println("Mice and other pointing devices");
        self.println("  PS/2 Compatible Mouse");
        self.println("Network adapters");
        var found_net = false;
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            const d = pci.devices[i];
            if (network.isNetwork(d)) {
                found_net = true;
                var nbuf: [LINE_LEN]u8 = undefined;
                var np: usize = 0;
                appendText(&nbuf, &np, "  ");
                appendText(&nbuf, &np, network.deviceName(d));
                self.println(nbuf[0..np]);
            }
        }
        if (!found_net) self.println("  No network adapter detected");
        self.println("PCI system devices");
        self.println("  Run PCI for raw bus list");
    }

    fn printDrivers(self: *CommandPrompt) void {
        driver_registry.refresh();
        self.println("Driver registry:");
        var i: usize = 0;
        while (i < driver_registry.count) : (i += 1) {
            const d = driver_registry.drivers[i];
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            appendText(&buf, &p, "  ");
            appendText(&buf, &p, driver_registry.kindName(d.kind));
            appendText(&buf, &p, ": ");
            appendText(&buf, &p, d.name);
            appendText(&buf, &p, " - ");
            appendText(&buf, &p, driver_registry.stateName(d.state));
            self.println(buf[0..p]);
            var dbuf: [LINE_LEN]u8 = undefined;
            var q: usize = 0;
            appendText(&dbuf, &q, "      ");
            appendText(&dbuf, &q, d.detail);
            self.println(dbuf[0..q]);
        }
    }



    fn parseByte(text: []const u8) ?u8 {
        if (text.len == 0 or text.len > 3) return null;
        var v: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] < '0' or text[i] > '9') return null;
            v = v * 10 + @as(usize, text[i] - '0');
            if (v > 255) return null;
        }
        return @intCast(v);
    }

    fn parseIp(text: []const u8) ?[4]u8 { return network.parseIpv4(text); }

    fn printIpLine(self: *CommandPrompt, label: []const u8, ip: [4]u8) void {
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, label);
        appendDec(&buf, &p, @as(usize, ip[0])); appendText(&buf, &p, ".");
        appendDec(&buf, &p, @as(usize, ip[1])); appendText(&buf, &p, ".");
        appendDec(&buf, &p, @as(usize, ip[2])); appendText(&buf, &p, ".");
        appendDec(&buf, &p, @as(usize, ip[3]));
        self.println(buf[0..p]);
    }

    fn printNetConfig(self: *CommandPrompt) void {
        network.initAll();
        self.println("TCP/IP Configuration");
        self.printIpLine("  IP Address . . . . . . : ", if (network.activeAdapter()) |a| a.ip else .{0,0,0,0});
        self.printIpLine("  Subnet Mask . . . . . : ", network.subnet_mask);
        self.printIpLine("  Default Gateway . . . : ", network.gateway);
        self.printIpLine("  DNS Server . . . . . . : ", network.dns);
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "  Address Mode . . . . . : "); appendText(&buf, &p, network.modeName());
        self.println(buf[0..p]);
    }

    fn netConfigCommand(self: *CommandPrompt, args: []const u8) void {
        const mode = firstToken(args);
        const rest = restAfterFirst(args);
        if (mode.len == 0 or streq(mode, "SHOW")) { self.printNetConfig(); return; }
        if (streq(mode, "DHCP")) {
            network.setDhcp();
            self.println("DHCP enabled. Lease simulated as QEMU user-network default until DHCP packets land.");
            self.printNetConfig();
            return;
        }
        if (streq(mode, "STATIC")) {
            const ip_s = firstToken(rest);
            const r2 = restAfterFirst(rest);
            const mask_s = firstToken(r2);
            const r3 = restAfterFirst(r2);
            const gw_s = firstToken(r3);
            const dns_s = firstToken(restAfterFirst(r3));
            if (ip_s.len == 0 or mask_s.len == 0 or gw_s.len == 0 or dns_s.len == 0) {
                self.println("Usage: NETCFG STATIC <ip> <mask> <gateway> <dns>");
                return;
            }
            const ip = parseIp(ip_s) orelse { self.println("Invalid IP address"); return; };
            const mask = parseIp(mask_s) orelse { self.println("Invalid subnet mask"); return; };
            const gw = parseIp(gw_s) orelse { self.println("Invalid gateway"); return; };
            const dns_ip = parseIp(dns_s) orelse { self.println("Invalid DNS server"); return; };
            network.setStatic(ip, mask, gw, dns_ip);
            self.println("Static TCP/IP configuration applied.");
            self.printNetConfig();
            return;
        }
        self.println("Usage: NETCFG [SHOW|DHCP|STATIC <ip> <mask> <gateway> <dns>]");
    }

    fn pingCommand(self: *CommandPrompt, args: []const u8) void {
        network.initAll();
        const target_s = firstToken(args);
        if (target_s.len == 0) { self.println("Usage: PING <hostname-or-ip>"); return; }
        const rr = network.resolveHost(target_s);
        if (!rr.ok) { self.println("PING: could not resolve host name"); return; }
        var rbuf: [LINE_LEN]u8 = undefined;
        var rp: usize = 0;
        appendText(&rbuf, &rp, "Resolved "); appendText(&rbuf, &rp, target_s); appendText(&rbuf, &rp, " using "); appendText(&rbuf, &rp, rr.source);
        self.println(rbuf[0..rp]);
        self.printIpLine("Pinging ", rr.ip);
        var sent: usize = 0;
        var received: usize = 0;
        while (sent < 3) : (sent += 1) {
            const pr = network.ping(rr.ip);
            if (pr.reachable) {
                received += 1;
                var buf: [LINE_LEN]u8 = undefined;
                var p: usize = 0;
                appendText(&buf, &p, "Reply from ");
                appendDec(&buf, &p, @as(usize, rr.ip[0])); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, rr.ip[1])); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, rr.ip[2])); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, rr.ip[3]));
                appendText(&buf, &p, ": bytes=32 time="); appendDec(&buf, &p, pr.time_ms + sent); appendText(&buf, &p, "ms TTL=64");
                self.println(buf[0..p]);
            } else {
                var buf: [LINE_LEN]u8 = undefined;
                var p: usize = 0;
                appendText(&buf, &p, "Request timed out: "); appendText(&buf, &p, pr.note);
                self.println(buf[0..p]);
            }
        }
        var sbuf: [LINE_LEN]u8 = undefined;
        var sp: usize = 0;
        appendText(&sbuf, &sp, "Packets: Sent = 3, Received = "); appendDec(&sbuf, &sp, received); appendText(&sbuf, &sp, ", Lost = "); appendDec(&sbuf, &sp, 3 - received);
        self.println(sbuf[0..sp]);
    }

    fn arpCommand(self: *CommandPrompt) void {
        network.initAll();
        network.serviceNetwork();
        self.println("ARP cache:");
        var shown: usize = 0;
        var i: usize = 0;
        while (i < network.ARP_CACHE_MAX) : (i += 1) {
            const e = network.arp_cache[i];
            if (!e.valid) continue;
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            appendDec(&buf, &p, @as(usize, e.ip[0])); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, e.ip[1])); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, e.ip[2])); appendText(&buf, &p, "."); appendDec(&buf, &p, @as(usize, e.ip[3]));
            appendText(&buf, &p, " -> "); appendHexByte(&buf, &p, e.mac[0]); appendText(&buf, &p, ":"); appendHexByte(&buf, &p, e.mac[1]); appendText(&buf, &p, ":"); appendHexByte(&buf, &p, e.mac[2]); appendText(&buf, &p, ":"); appendHexByte(&buf, &p, e.mac[3]); appendText(&buf, &p, ":"); appendHexByte(&buf, &p, e.mac[4]); appendText(&buf, &p, ":"); appendHexByte(&buf, &p, e.mac[5]);
            self.println(buf[0..p]); shown += 1;
        }
        if (shown == 0) self.println("  empty - use PING or HTTPGET to resolve the gateway");
    }

    fn nslookupCommand(self: *CommandPrompt, args: []const u8) void {
        network.initAll();
        const target_s = firstToken(args);
        if (target_s.len == 0) { self.println("Usage: NSLOOKUP <hostname-or-url>"); return; }
        const rr = network.resolveHost(target_s);
        if (!rr.ok) { self.println("DNS lookup failed."); return; }
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Name: "); appendText(&buf, &p, target_s); appendText(&buf, &p, "  Source: "); appendText(&buf, &p, rr.source);
        self.println(buf[0..p]);
        self.printIpLine("Address: ", rr.ip);
    }

    fn httpGetCommand(self: *CommandPrompt, args: []const u8) void {
        network.initAll();
        const first = firstToken(args);
        const raw_mode = streq(first, "-RAW") or streq(first, "/RAW");
        const target_s = if (raw_mode) firstToken(restAfterFirst(args)) else first;
        if (target_s.len == 0) { self.println("Usage: HTTPGET [-RAW] <url>"); return; }

        // -RAW is a diagnostic flag, not the URL. Older builds accidentally
        // tried to connect to host "-RAW", which could drive the TCP path into
        // bad synthetic routes and crash the kernel. Keep commands compatible
        // while making the parser explicit and safe.
        const r = if (raw_mode) network.liveHttpGet(target_s) else network.httpGet(target_s);
        var head: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&head, &p, "HTTP status: "); appendDec(&head, &p, r.code); appendText(&head, &p, "  "); appendText(&head, &p, r.note);
        self.println(head[0..p]);
        self.printIpLine("Remote: ", r.remote_ip);
        if (raw_mode) self.println("Raw mode: showing live transport result or explicit TCP diagnostic.");
        self.println(r.title);
        self.println(r.body1);
        if (r.body2.len != 0) self.println(r.body2);
        if (r.body3.len != 0) self.println(r.body3);
    }

    fn printNetStatus(self: *CommandPrompt) void {
        network.initAll();
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Network adapters detected: ");
        appendDec(&buf, &p, network.adapter_count);
        self.println(buf[0..p]);
        if (network.adapter_count == 0) {
            self.println("No NIC found. Build script should run QEMU with -netdev user and -device e1000.");
            return;
        }
        var i: usize = 0;
        while (i < network.adapter_count) : (i += 1) {
            const a = network.adapters[i];
            var line: [LINE_LEN]u8 = undefined;
            var q: usize = 0;
            appendText(&line, &q, "  "); appendText(&line, &q, a.name); self.println(line[0..q]);
            q = 0; appendText(&line, &q, "      driver: "); appendText(&line, &q, network.driverName(a.driver)); appendText(&line, &q, " / state: "); appendText(&line, &q, network.stateName(a.state)); self.println(line[0..q]);
            q = 0; appendText(&line, &q, "      resources: "); appendText(&line, &q, pci.resourceText(a.dev)); self.println(line[0..q]);
            q = 0; appendText(&line, &q, "      MAC: "); appendHexByte(&line, &q, a.mac[0]); appendText(&line, &q, ":"); appendHexByte(&line, &q, a.mac[1]); appendText(&line, &q, ":"); appendHexByte(&line, &q, a.mac[2]); appendText(&line, &q, ":"); appendHexByte(&line, &q, a.mac[3]); appendText(&line, &q, ":"); appendHexByte(&line, &q, a.mac[4]); appendText(&line, &q, ":"); appendHexByte(&line, &q, a.mac[5]); appendText(&line, &q, if (a.has_real_mac) " (hardware)" else " (synthetic)"); self.println(line[0..q]);
            q = 0; appendText(&line, &q, "      Link: "); appendText(&line, &q, if (a.link_up) "up" else "unknown/down"); self.println(line[0..q]);
            q = 0; appendText(&line, &q, "      IPv4: "); if (network.hasIpv4(a)) { appendDec(&line, &q, @as(usize, a.ip[0])); appendText(&line, &q, "."); appendDec(&line, &q, @as(usize, a.ip[1])); appendText(&line, &q, "."); appendDec(&line, &q, @as(usize, a.ip[2])); appendText(&line, &q, "."); appendDec(&line, &q, @as(usize, a.ip[3])); appendText(&line, &q, " /24"); } else { appendText(&line, &q, "not configured"); } self.println(line[0..q]);
        }
        self.printNetConfig();
        p = 0; appendText(&buf, &p, "Packets: RX "); appendDec(&buf, &p, network.rx_packets); appendText(&buf, &p, " / TX "); appendDec(&buf, &p, network.tx_packets); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Protocol: ARP replies "); appendDec(&buf, &p, network.arp_replies); appendText(&buf, &p, ", IPv4 "); appendDec(&buf, &p, network.ipv4_packets); appendText(&buf, &p, ", TCP "); appendDec(&buf, &p, network.tcp_packets); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Status: "); appendText(&buf, &p, network.networkPipelineStatus()); self.println(buf[0..p]);
    }
    fn printUsbStatus(self: *CommandPrompt) void {
        usb.scan();
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "USB controllers detected: "); appendDec(&buf, &p, usb.controller_count); self.println(buf[0..p]);
        var i: usize = 0;
        while (i < usb.controller_count) : (i += 1) {
            const c = usb.controllers[i];
            p = 0; appendText(&buf, &p, "  "); appendText(&buf, &p, c.name); self.println(buf[0..p]);
            p = 0; appendText(&buf, &p, "      driver: "); appendText(&buf, &p, usb.driverName(c.kind)); appendText(&buf, &p, " / state: "); appendText(&buf, &p, usb.stateName(c.state)); self.println(buf[0..p]);
        }
        p = 0; appendText(&buf, &p, "UHCI/EHCI/xHCI: "); appendDec(&buf, &p, usb.uhci_count); appendText(&buf, &p, "/"); appendDec(&buf, &p, usb.ehci_count); appendText(&buf, &p, "/"); appendDec(&buf, &p, usb.xhci_count); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "USB HID devices: "); appendDec(&buf, &p, usb_hid.device_count); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "USB status: "); appendText(&buf, &p, usb.hidStatusText()); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Last HID enum step: "); appendDec(&buf, &p, usb_hid.last_failed_step); self.println(buf[0..p]);
        i = 0;
        while (i < usb_hid.device_count) : (i += 1) {
            const d = usb_hid.devices[i];
            p = 0; appendText(&buf, &p, "  "); appendText(&buf, &p, usb_hid.deviceTypeName(d.device_type)); appendText(&buf, &p, " port "); appendDec(&buf, &p, d.port); appendText(&buf, &p, " addr "); appendDec(&buf, &p, d.address); appendText(&buf, &p, " VID:PID "); appendHexByte(&buf, &p, @truncate(d.vendor_id >> 8)); appendHexByte(&buf, &p, @truncate(d.vendor_id)); appendText(&buf, &p, ":"); appendHexByte(&buf, &p, @truncate(d.product_id >> 8)); appendHexByte(&buf, &p, @truncate(d.product_id)); self.println(buf[0..p]);
        }
        p = 0; appendText(&buf, &p, "Hotplug rescans: "); appendDec(&buf, &p, usb.hid_rescan_count); self.println(buf[0..p]);
        self.println("Use USBSCAN to force root-hub rescan. USB is preferred; PS/2 remains fallback.");
    }


    fn printInputStatus(self: *CommandPrompt) void {
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Keyboard driver: "); appendText(&buf, &p, input.driverName(input.keyboard_active)); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "  "); appendText(&buf, &p, input.keyboardStatus()); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Mouse driver: "); appendText(&buf, &p, input.driverName(input.mouse_active)); self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "  "); appendText(&buf, &p, input.mouseStatus()); self.println(buf[0..p]);
        self.println("Policy: USB HID first. PS/2 is kept alive only as fallback.");
    }

    fn printDisplayStatus(self: *CommandPrompt) void {
        if (display.firstAdapter()) |gpu| {
            self.println(display.deviceName(gpu));
        } else {
            self.println("Basic Display Adapter");
        }
        self.println(display.modeText());
    }

    fn printGuest(self: *CommandPrompt) void {
        guest.detect();
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Guest additions: "); appendText(&buf, &p, guest.status());
        self.println(buf[0..p]);
        p = 0; appendText(&buf, &p, "Scale: "); appendDec(&buf, &p, @as(usize, @intCast(guest.scale_percent))); appendText(&buf, &p, "%"); self.println(buf[0..p]);
        self.println(if (guest.input_grabbed) "Input: grabbed" else "Input: normal");
        self.println(guest.timeStatus());
    }

    fn endsWithInsensitive(name: []const u8, suffix: []const u8) bool {
        if (suffix.len > name.len) return false;
        return streq(name[name.len - suffix.len ..], suffix);
    }

    fn secondToken(s: []const u8) []const u8 {
        return firstToken(restAfterFirst(s));
    }

    fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (streq(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn printCountLine(self: *CommandPrompt, label: []const u8, n: usize) void {
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, label);
        appendDec(&buf, &p, n);
        self.println(buf[0..p]);
    }

    fn printVfsStats(self: *CommandPrompt) void {
        self.printCountLine("VFS nodes used : ", vfs.usedNodes());
        self.printCountLine("VFS nodes total: ", vfs.maxNodes());
    }

    fn listApps(self: *CommandPrompt) void {
        self.println("Installed apps:");
        self.println("  notepad       Text editor");
        self.println("  explorer      File manager");
        self.println("  devmgr        Device Manager");
        self.println("  taskmgr       Task Manager");
        self.println("  control       Control Panel");
        self.println("  browser       Web Browser");
        self.println("  cmd           Command Prompt");
        self.println("  counter       Script demo");
        self.println("");
        self.println("Launch with: START <app>, RUN <app>, or OPEN <file>");
    }

    fn launchBuiltin(self: *CommandPrompt, kind: window.BuiltinApp, name: []const u8) void {
        self.pending_launch = kind;
        var buf: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Launching ");
        appendText(&buf, &p, name);
        appendText(&buf, &p, "...");
        self.println(buf[0..p]);
    }

    fn launchByName(self: *CommandPrompt, raw: []const u8) void {
        const name = trim(raw);
        if (name.len == 0) { self.println("Usage: START <app-or-file>"); return; }
        if (streq(name, "NOTEPAD") or streq(name, "EDIT") or streq(name, "NOTEPAD.APP")) {
            self.launchBuiltin(.notepad, "Notepad");
        } else if (streq(name, "EXPLORER") or streq(name, "EXPLORER.APP") or streq(name, "FILEMAN")) {
            self.launchBuiltin(.explorer, "File Explorer");
        } else if (streq(name, "DEVMGR") or streq(name, "DEVMGR.APP") or streq(name, "DEVICE") or streq(name, "DEVICES") or streq(name, "DEVICE_MANAGER") or streq(name, "DEVICE-MANAGER")) {
            self.launchBuiltin(.device_manager, "Device Manager");
        } else if (streq(name, "TASKMGR") or streq(name, "TASKMGR.APP") or streq(name, "TASKMAN") or streq(name, "TASK_MANAGER") or streq(name, "TASK-MANAGER")) {
            self.launchBuiltin(.task_manager, "Task Manager");
        } else if (streq(name, "CONTROL") or streq(name, "CONTROL.APP") or streq(name, "CONTROL_PANEL") or streq(name, "CONTROL-PANEL") or streq(name, "NETCPL")) {
            self.launchBuiltin(.control_panel, "Control Panel");
        } else if (streq(name, "BROWSER") or streq(name, "WEB") or streq(name, "IEXPLORE") or streq(name, "INTERNET") or streq(name, "BROWSER.APP")) {
            self.launchBuiltin(.web_browser, "Web Browser");
        } else if (streq(name, "CMD") or streq(name, "CMD.APP") or streq(name, "COMMAND") or streq(name, "COMMAND.COM")) {
            self.launchBuiltin(.command_prompt, "Command Prompt");
        } else if (streq(name, "COUNTER") or streq(name, "COUNTER.WS")) {
            self.launchBuiltin(.counter_demo, "Counter");
        } else if (endsWithInsensitive(name, ".TXT")) {
            const h = self.resolveFrom(name) orelse { self.println("File not found"); return; };
            if (vfs.kindOf(h) != .file) { self.println("Not a file"); return; }
            if (notepad.loadFromVfsFile(h)) self.launchBuiltin(.notepad, "Notepad") else self.println("Open failed");
        } else if (self.resolveFrom(name)) |h| {
            if (vfs.kindOf(h) == .directory) {
                self.cwd = h;
                self.launchBuiltin(.explorer, "File Explorer");
            } else if (endsWithInsensitive(vfs.nameOf(h), ".TXT")) {
                if (notepad.loadFromVfsFile(h)) self.launchBuiltin(.notepad, "Notepad") else self.println("Open failed");
            } else if (endsWithInsensitive(vfs.nameOf(h), ".APP")) {
                self.launchByName(vfs.nameOf(h));
            } else if (endsWithInsensitive(vfs.nameOf(h), ".WS")) {
                self.launchBuiltin(.counter_demo, "Script app");
            } else {
                self.println("No association for this file type");
            }
        } else {
            self.println("App or file not found");
        }
    }

    fn printEnv(self: *CommandPrompt) void {
        self.println("COMSPEC=C:\\SYSTEM\\COMMAND.COM");
        self.println("PATH=C:\\APPS;C:\\SYSTEM");
        self.println("TEMP=C:\\USERS\\DEFAULT");
        self.println("USER=default");
        self.println("OS=Core97");
    }

    fn printHeadTail(self: *CommandPrompt, path: []const u8, tail: bool) void {
        if (path.len == 0) { self.println("Usage: HEAD|TAIL <file>"); return; }
        const h = self.resolveFrom(path) orelse { self.println("File not found"); return; };
        if (vfs.kindOf(h) != .file) { self.println("Not a file"); return; }
        const data = vfs.readFile(h);
        var lines_seen: usize = 0;
        var start: usize = 0;
        if (tail) {
            var i = data.len;
            while (i > 0 and lines_seen < 10) {
                i -= 1;
                if (data[i] == '\n') {
                    lines_seen += 1;
                    if (lines_seen == 10) { start = i + 1; break; }
                }
            }
        }
        var i = start;
        lines_seen = 0;
        while (i < data.len and lines_seen < 10) {
            var j = i;
            while (j < data.len and data[j] != '\n' and data[j] != '\r') : (j += 1) {}
            self.println(data[i..j]);
            lines_seen += 1;
            while (j < data.len and (data[j] == '\n' or data[j] == '\r')) : (j += 1) {}
            i = j;
        }
    }

    fn printWc(self: *CommandPrompt, path: []const u8) void {
        if (path.len == 0) { self.println("Usage: WC <file>"); return; }
        const h = self.resolveFrom(path) orelse { self.println("File not found"); return; };
        if (vfs.kindOf(h) != .file) { self.println("Not a file"); return; }
        const data = vfs.readFile(h);
        var lines: usize = 0;
        var words: usize = 0;
        var in_word = false;
        for (data) |c| {
            if (c == '\n') lines += 1;
            const sep = c == ' ' or c == '\t' or c == '\r' or c == '\n';
            if (sep) in_word = false else if (!in_word) { words += 1; in_word = true; }
        }
        self.printCountLine("Lines: ", lines);
        self.printCountLine("Words: ", words);
        self.printCountLine("Bytes: ", data.len);
    }

    fn findInFile(self: *CommandPrompt, args: []const u8) void {
        const needle = firstToken(args);
        const path = secondToken(args);
        if (needle.len == 0 or path.len == 0) { self.println("Usage: FIND <text> <file>"); return; }
        const h = self.resolveFrom(path) orelse { self.println("File not found"); return; };
        if (vfs.kindOf(h) != .file) { self.println("Not a file"); return; }
        const data = vfs.readFile(h);
        var matched = false;
        var i: usize = 0;
        while (i < data.len) {
            var j = i;
            while (j < data.len and data[j] != '\n' and data[j] != '\r') : (j += 1) {}
            const line = data[i..j];
            if (containsInsensitive(line, needle)) { self.println(line); matched = true; }
            while (j < data.len and (data[j] == '\n' or data[j] == '\r')) : (j += 1) {}
            i = j;
        }
        if (!matched) self.println("No matches");
    }

    fn help(self: *CommandPrompt) void {
        self.println("File commands:");
        self.println("  DIR/LS [path]          List directory");
        self.println("  CD/CHDIR [path]        Change/show directory");
        self.println("  PWD                    Show current directory");
        self.println("  CAT/TYPE/MORE <file>   Show file contents");
        self.println("  HEAD/TAIL <file>       Show first/last lines");
        self.println("  TREE [path]            Show directory tree");
        self.println("  MKDIR/MD <name>        Create directory");
        self.println("  TOUCH <file>           Create empty file");
        self.println("  WRITE <file> text      Write text to file");
        self.println("  APPEND <file> text     Append text to file");
        self.println("  CP/COPY <src> <dst>    Copy file");
        self.println("  REN/RENAME <old> <new> Rename item in current dir");
        self.println("  DEL/RM/RMDIR <path>    Delete file or directory");
        self.println("  FIND <text> <file>     Search inside a file");
        self.println("  WC <file>              Count lines/words/bytes");
        self.println("App commands:");
        self.println("  APPS                   List apps");
        self.println("  START/RUN/OPEN <name>  Launch app or open file");
        self.println("System commands:");
        self.println("  CLS VER MEM HEAP VFS PCI DEVICES DRIVERS INPUT USB USBSCAN NET IPCONFIG NETCFG ARP NSLOOKUP PING HTTPGET BROWSER DISPLAY GUEST BEEP UPTIME DATE TIME ENV");
        self.println("  WHOAMI HOSTNAME PATH REBOOT SHUTDOWN");
    }

    fn execute(self: *CommandPrompt) void {
        self.promptLine();
        const line = trim(self.input[0..self.input_len]);
        if (line.len == 0) { self.input_len = 0; return; }
        const cmd = firstToken(line);
        const args = restAfterFirst(line);

        if (streq(cmd, "HELP") or streq(cmd, "?")) {
            self.help();
        } else if (streq(cmd, "VER")) {
            self.println("CORE97OS Kernel Shell 0.05");
        } else if (streq(cmd, "CLS") or streq(cmd, "CLEAR")) {
            self.clear();
        } else if (streq(cmd, "MEM") or streq(cmd, "HEAP")) {
            self.printMem();
        } else if (streq(cmd, "VFS")) {
            self.printVfsStats();
        } else if (streq(cmd, "PCI")) {
            self.printPci();
        } else if (streq(cmd, "DEVICES")) {
            self.printDevices();
        } else if (streq(cmd, "DRIVERS")) {
            self.printDrivers();
        } else if (streq(cmd, "NET") or streq(cmd, "IPCONFIG")) {
            self.printNetStatus();
        } else if (streq(cmd, "NETCFG") or streq(cmd, "NETWORK")) {
            self.netConfigCommand(args);
        } else if (streq(cmd, "ARP")) {
            self.arpCommand();
        } else if (streq(cmd, "NSLOOKUP") or streq(cmd, "RESOLVE")) {
            self.nslookupCommand(args);
        } else if (streq(cmd, "PING")) {
            self.pingCommand(args);
        } else if (streq(cmd, "HTTPGET") or streq(cmd, "GET") or streq(cmd, "WGET")) {
            self.httpGetCommand(args);
        } else if (streq(cmd, "BROWSER") or streq(cmd, "WEB")) {
            self.launchBuiltin(.web_browser, "Web Browser");
        } else if (streq(cmd, "INPUT")) {
            self.printInputStatus();
        } else if (streq(cmd, "USB")) {
            self.printUsbStatus();
        } else if (streq(cmd, "USBSCAN") or streq(cmd, "USBREFRESH")) {
            usb.rescanHid();
            self.println("USB root hub rescanned.");
            self.printUsbStatus();
        } else if (streq(cmd, "DISPLAY")) {
            self.printDisplayStatus();
        } else if (streq(cmd, "GUEST")) {
            self.printGuest();
        } else if (streq(cmd, "BEEP")) {
            audio.beep();
            self.println("PC speaker on. Use SILENCE to stop.");
        } else if (streq(cmd, "SILENCE")) {
            audio.silence();
            self.println("PC speaker off.");
        } else if (streq(cmd, "GRAB")) {
            guest.grabInput();
            self.println("Guest input grab flag enabled.");
        } else if (streq(cmd, "UNGRAB")) {
            guest.releaseInput();
            self.println("Guest input grab flag disabled.");
        } else if (streq(cmd, "UPTIME")) {
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            appendText(&buf, &p, "PIT ticks: "); appendDec(&buf, &p, @as(usize, @intCast(pit.ticks)));
            self.println(buf[0..p]);
        } else if (streq(cmd, "DATE")) {
            self.println("Current date is not available until RTC/guest tools are loaded.");
        } else if (streq(cmd, "TIME")) {
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            appendText(&buf, &p, "System ticks: "); appendDec(&buf, &p, @as(usize, @intCast(pit.ticks)));
            self.println(buf[0..p]);
        } else if (streq(cmd, "WHOAMI")) {
            self.println("default");
        } else if (streq(cmd, "HOSTNAME")) {
            self.println("CORE97-PC");
        } else if (streq(cmd, "PATH")) {
            self.println("C:\\APPS;C:\\SYSTEM");
        } else if (streq(cmd, "ENV") or streq(cmd, "SET")) {
            self.printEnv();
        } else if (streq(cmd, "APPS")) {
            self.listApps();
        } else if (streq(cmd, "START") or streq(cmd, "RUN") or streq(cmd, "OPEN")) {
            self.launchByName(args);
        } else if (streq(cmd, "EDIT")) {
            if (args.len == 0) self.launchBuiltin(.notepad, "Notepad") else self.launchByName(args);
        } else if (streq(cmd, "PWD")) {
            var buf: [LINE_LEN]u8 = undefined;
            var p: usize = 0;
            self.appendPath(&buf, &p);
            self.println(buf[0..p]);
        } else if (streq(cmd, "DIR") or streq(cmd, "LS")) {
            const h = self.resolveFrom(args) orelse { self.println("Path not found"); self.input_len = 0; return; };
            self.printDir(h);
        } else if (streq(cmd, "CD") or streq(cmd, "CHDIR")) {
            if (args.len == 0) {
                var buf: [LINE_LEN]u8 = undefined;
                var p: usize = 0;
                self.appendPath(&buf, &p);
                self.println(buf[0..p]);
            } else {
                const h = self.resolveFrom(args) orelse { self.println("Path not found"); self.input_len = 0; return; };
                if (vfs.kindOf(h) != .directory) self.println("Not a directory") else self.cwd = h;
            }
        } else if (streq(cmd, "CAT") or streq(cmd, "TYPE") or streq(cmd, "MORE")) {
            if (args.len == 0) self.println("Usage: CAT <file>") else {
                const h = self.resolveFrom(args) orelse { self.println("File not found"); self.input_len = 0; return; };
                if (vfs.kindOf(h) != .file) self.println("Not a file") else self.printTextBlock(vfs.readFile(h));
            }
        } else if (streq(cmd, "HEAD")) {
            self.printHeadTail(args, false);
        } else if (streq(cmd, "TAIL")) {
            self.printHeadTail(args, true);
        } else if (streq(cmd, "TREE")) {
            const h = self.resolveFrom(args) orelse { self.println("Path not found"); self.input_len = 0; return; };
            if (vfs.kindOf(h) != .directory) self.println("Not a directory") else self.printTree(h, 0);
        } else if (streq(cmd, "MKDIR") or streq(cmd, "MD")) {
            var name: []const u8 = undefined;
            const parent = self.splitParent(args, &name) orelse { self.println("Usage: MKDIR <name>"); self.input_len = 0; return; };
            if (vfs.findChild(parent, name) != null) self.println("Already exists") else if (vfs.createNode(parent, name, .directory) == null) self.println("Could not create directory");
        } else if (streq(cmd, "TOUCH")) {
            var name: []const u8 = undefined;
            const parent = self.splitParent(args, &name) orelse { self.println("Usage: TOUCH <file>"); self.input_len = 0; return; };
            if (vfs.findChild(parent, name) == null) {
                const h = vfs.createNode(parent, name, .file) orelse { self.println("Could not create file"); self.input_len = 0; return; };
                _ = vfs.writeFile(h, "");
            }
        } else if (streq(cmd, "WRITE")) {
            const path = firstToken(args);
            const text = restAfterFirst(args);
            if (path.len == 0) self.println("Usage: WRITE <file> text") else {
                var h = self.resolveFrom(path);
                if (h == null) {
                    var name: []const u8 = undefined;
                    const parent = self.splitParent(path, &name) orelse { self.println("Path not found"); self.input_len = 0; return; };
                    h = vfs.createNode(parent, name, .file);
                }
                if (h) |file| {
                    if (vfs.kindOf(file) != .file) self.println("Not a file") else if (!vfs.writeFile(file, text)) self.println("Write failed");
                } else self.println("Could not create file");
            }
        } else if (streq(cmd, "APPEND")) {
            const path = firstToken(args);
            const text = restAfterFirst(args);
            if (path.len == 0) self.println("Usage: APPEND <file> text") else {
                var h = self.resolveFrom(path);
                if (h == null) {
                    var name: []const u8 = undefined;
                    const parent = self.splitParent(path, &name) orelse { self.println("Path not found"); self.input_len = 0; return; };
                    h = vfs.createNode(parent, name, .file);
                }
                if (h) |file| {
                    if (vfs.kindOf(file) != .file) self.println("Not a file") else {
                        _ = vfs.appendFile(file, text);
                        _ = vfs.appendFile(file, "\n");
                    }
                } else self.println("Could not create file");
            }
        } else if (streq(cmd, "ECHO")) {
            self.println(args);
        } else if (streq(cmd, "CP") or streq(cmd, "COPY")) {
            const src_path = firstToken(args);
            const dst_path = secondToken(args);
            if (src_path.len == 0 or dst_path.len == 0) self.println("Usage: COPY <src> <dst>") else {
                const src = self.resolveFrom(src_path) orelse { self.println("Source not found"); self.input_len = 0; return; };
                if (vfs.kindOf(src) != .file) self.println("Source is not a file") else {
                    var dst = self.resolveFrom(dst_path);
                    if (dst == null) {
                        var name: []const u8 = undefined;
                        const parent = self.splitParent(dst_path, &name) orelse { self.println("Destination path not found"); self.input_len = 0; return; };
                        dst = vfs.createNode(parent, name, .file);
                    }
                    if (dst) |d| {
                        if (vfs.kindOf(d) != .file) self.println("Destination is not a file") else _ = vfs.writeFile(d, vfs.readFile(src));
                    } else self.println("Copy failed");
                }
            }
        } else if (streq(cmd, "REN") or streq(cmd, "RENAME")) {
            const old_name = firstToken(args);
            const new_name = secondToken(args);
            if (old_name.len == 0 or new_name.len == 0) self.println("Usage: REN <old> <new>") else if (!vfs.renameChild(self.cwd, old_name, new_name)) self.println("Rename failed");
        } else if (streq(cmd, "MOVE") or streq(cmd, "MV")) {
            const old_name = firstToken(args);
            const new_name = secondToken(args);
            if (old_name.len == 0 or new_name.len == 0) self.println("Usage: MOVE <old> <new>") else if (!vfs.renameChild(self.cwd, old_name, new_name)) self.println("Move failed");
        } else if (streq(cmd, "DEL") or streq(cmd, "RM") or streq(cmd, "RMDIR")) {
            var name: []const u8 = undefined;
            const parent = self.splitParent(args, &name) orelse { self.println("Usage: DEL <path>"); self.input_len = 0; return; };
            if (!vfs.deleteChild(parent, name)) self.println("Delete failed");
        } else if (streq(cmd, "FIND") or streq(cmd, "GREP")) {
            self.findInFile(args);
        } else if (streq(cmd, "WC")) {
            self.printWc(args);
        } else if (streq(cmd, "REBOOT")) {
            power.reboot();
        } else if (streq(cmd, "SHUTDOWN")) {
            power.shutdown();
        } else {
            self.println("Bad command or file name");
        }
        self.input_len = 0;
    }

    fn inputChar(self: *CommandPrompt, c: u8) void {
        if (c == 0) return;
        if (c == 8) {
            if (self.input_len > 0) self.input_len -= 1;
        } else if (c == 13 or c == 10) {
            self.execute();
        } else if (self.input_len < INPUT_MAX and c >= 32 and c < 127) {
            self.input[self.input_len] = c;
            self.input_len += 1;
        }
    }

    pub fn title(_: *CommandPrompt) []const u8 { return "Command Prompt"; }
    pub fn titleDetail(_: *CommandPrompt) []const u8 { return ""; }

    pub fn draw(self: *CommandPrompt, x: u32, y: u32, w: u32, h: u32) void {
        self.ensureInit();
        fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        fb.draw3DBorder(x + 4, y + 4, w - 8, h - 8, false);
        const cx = x + 6;
        const cy = y + 6;
        const cw = w - 12;
        const ch = h - 12;
        fb.fillRect(cx, cy, cw, ch, fb.CORE97_BLACK);

        const rows: usize = if (ch > 8) @intCast((ch - 8) / 14) else 1;
        const history_rows: usize = if (rows > 0) rows - 1 else 0;
        const start: usize = if (self.line_count > history_rows) self.line_count - history_rows else 0;
        var row: usize = 0;
        var i = start;
        while (i < self.line_count and row < history_rows) {
            fb.drawString(cx + 4, cy + 4 + @as(u32, @intCast(row)) * 14, self.lines[i][0..self.line_lens[i]], fb.CORE97_WHITE, fb.CORE97_BLACK);
            i += 1;
            row += 1;
        }

        var input_line: [LINE_LEN]u8 = undefined;
        var p: usize = 0;
        self.appendPath(&input_line, &p);
        appendText(&input_line, &p, ">");
        var k: usize = 0;
        while (k < self.input_len and p < LINE_LEN) : (k += 1) { input_line[p] = self.input[k]; p += 1; }
        const iy = cy + 4 + @as(u32, @intCast(history_rows)) * 14;
        fb.drawString(cx + 4, iy, input_line[0..p], fb.CORE97_WHITE, fb.CORE97_BLACK);
        const caret_x = cx + 4 + @as(u32, @intCast(p)) * 8;
        fb.fillRect(caret_x, iy + 10, 8, 2, fb.CORE97_WHITE);
    }

    pub fn onMouseDown(_: *CommandPrompt, _: i32, _: i32, _: window.MouseButton, _: u32, _: u32, _: u32, _: u32) window.AppAction { return .none; }
    pub fn onMouseDrag(_: *CommandPrompt, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *CommandPrompt) void {}
    pub fn onKeyAscii(self: *CommandPrompt, ascii: u8) void { self.inputChar(ascii); }
    pub fn onKeyUsb(self: *CommandPrompt, code: u8, modifiers: u8, _: u32) bool {
        if (code == 0x28) { self.inputChar(13); return true; }
        if (code == 0x2A) { self.inputChar(8); return true; }
        if (code == 0x2C) { self.inputChar(' '); return true; }
        const ascii = keymap.keycodeToAscii(code, modifiers, .us);
        if (ascii != 0) { self.inputChar(ascii); return true; }
        return false;
    }
    pub fn hasModalCapture(_: *CommandPrompt) bool { return false; }
};

var instances: [3]CommandPrompt = [_]CommandPrompt{.{}, .{}, .{}};

pub fn takeLaunchRequest() ?window.BuiltinApp {
    var i: usize = 0;
    while (i < instances.len) : (i += 1) {
        const req = instances[i].pending_launch;
        if (req != null) {
            instances[i].pending_launch = null;
            return req;
        }
    }
    return null;
}

pub fn asApp() window.App { return window.appFrom(CommandPrompt, &instances[0]); }
pub fn asAppAt(index: usize) window.App {
    const i = if (index >= instances.len) 0 else index;
    return window.appFrom(CommandPrompt, &instances[i]);
}
