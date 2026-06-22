// apps/web_browser.zig - Core97 Internet Browser.
// Stage 2 browser: universal hover-aware controls, editable address/search
// fields, history, clickable links, HTTP fetch facade, cached DNS and clear
// network/TLS status.

const fb = @import("../gui/framebuffer.zig");
const window = @import("../gui/window.zig");
const ui = @import("../gui/ui.zig");
const network = @import("../drivers/network.zig");
const webengine = @import("../browser/engine.zig");

const URL_MAX: usize = 180;
const SEARCH_MAX: usize = 100;
const Focus = enum { address, search };
const PageKind = enum { home, google_home, google_search, example, neverssl, yahoo, altavista, cern, w3c, textfiles, frogfind, router, local_status, http_host, unsupported_https, not_found, offline };

const SearchHit = struct { title: []const u8, url: []const u8, desc: []const u8 };
const search_hits = [_]SearchHit{
    .{ .title = "Core97 Home Page", .url = "http://core97/home", .desc = "Local desktop network and browser start page." },
    .{ .title = "Yahoo! Internet Directory", .url = "http://yahoo.com", .desc = "Directory-style web browsing." },
    .{ .title = "World Wide Web Consortium", .url = "http://w3.org", .desc = "HTML, HTTP and Web standards." },
    .{ .title = "CERN World Wide Web", .url = "http://info.cern.ch", .desc = "The original WWW information page." },
    .{ .title = "Example Domain", .url = "http://example.com", .desc = "Simple HTTP test page." },
    .{ .title = "FrogFind Text Proxy", .url = "http://frogfind.com", .desc = "Makes modern pages readable by old browsers." },
};

const Browser = struct {
    url: [URL_MAX]u8 = undefined,
    url_len: usize = 0,
    search: [SEARCH_MAX]u8 = undefined,
    search_len: usize = 0,
    current: [URL_MAX]u8 = undefined,
    current_len: usize = 0,
    previous: [URL_MAX]u8 = undefined,
    previous_len: usize = 0,
    status: [112]u8 = undefined,
    status_len: usize = 0,
    page: PageKind = .home,
    focus: Focus = .search,
    select_address: bool = false,
    select_search: bool = true,
    loaded_once: bool = false,

    fn ensure(self: *Browser) void {
        if (self.loaded_once) return;
        self.loaded_once = true;
        self.setUrl("http://core97/home");
        self.setSearch("");
        self.navigate(self.url[0..self.url_len], false);
        self.focus = .search;
        self.select_search = true;
    }

    fn append(buf: []u8, pos: *usize, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len and pos.* < buf.len) : (i += 1) {
            buf[pos.*] = text[i];
            pos.* += 1;
        }
    }
    fn upper(c: u8) u8 { return if (c >= 'a' and c <= 'z') c - 32 else c; }
    fn startsWith(a: []const u8, b: []const u8) bool {
        if (a.len < b.len) return false;
        var i: usize = 0;
        while (i < b.len) : (i += 1) if (upper(a[i]) != upper(b[i])) return false;
        return true;
    }
    fn contains(a: []const u8, b: []const u8) bool {
        if (b.len == 0) return true;
        if (a.len < b.len) return false;
        var i: usize = 0;
        while (i + b.len <= a.len) : (i += 1) {
            var ok = true;
            var j: usize = 0;
            while (j < b.len) : (j += 1) {
                if (upper(a[i + j]) != upper(b[j])) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
    fn hasSpace(text: []const u8) bool { var i: usize = 0; while (i < text.len) : (i += 1) if (text[i] == ' ') return true; return false; }
    fn hasProtocol(text: []const u8) bool { return startsWith(text, "http://") or startsWith(text, "https://"); }

    fn setBuf(dst: []u8, len: *usize, text: []const u8) void { var i: usize = 0; while (i < text.len and i < dst.len) : (i += 1) dst[i] = text[i]; len.* = i; }
    fn setUrl(self: *Browser, text: []const u8) void { setBuf(&self.url, &self.url_len, text); }
    fn setSearch(self: *Browser, text: []const u8) void { setBuf(&self.search, &self.search_len, text); }
    fn setCurrent(self: *Browser, text: []const u8) void { setBuf(&self.current, &self.current_len, text); }
    fn setPrevious(self: *Browser, text: []const u8) void { setBuf(&self.previous, &self.previous_len, text); }
    fn setStatus(self: *Browser, text: []const u8) void { setBuf(&self.status, &self.status_len, text); }

    fn dec(buf: []u8, pos: *usize, v: u8) void {
        if (v >= 100) { if (pos.* + 3 > buf.len) return; buf[pos.*] = '0' + @as(u8, @intCast(v / 100)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast((v / 10) % 10)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast(v % 10)); pos.* += 1; }
        else if (v >= 10) { if (pos.* + 2 > buf.len) return; buf[pos.*] = '0' + @as(u8, @intCast(v / 10)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast(v % 10)); pos.* += 1; }
        else { if (pos.* + 1 > buf.len) return; buf[pos.*] = '0' + v; pos.* += 1; }
    }
    fn drawIpText(x: u32, y: u32, prefix: []const u8, ip: [4]u8) void { var buf: [80]u8 = undefined; var p: usize = 0; append(&buf, &p, prefix); dec(&buf, &p, ip[0]); append(&buf, &p, "."); dec(&buf, &p, ip[1]); append(&buf, &p, "."); dec(&buf, &p, ip[2]); append(&buf, &p, "."); dec(&buf, &p, ip[3]); fb.drawString(x, y, buf[0..p], fb.CORE97_BLACK, fb.CORE97_WHITE); }

    fn normalizedUrl(input: []const u8, out: []u8) []const u8 {
        var p: usize = 0;
        if (input.len == 0) append(out, &p, "http://core97/home")
        else if (!hasProtocol(input)) { append(out, &p, "http://"); append(out, &p, input); }
        else append(out, &p, input);
        return out[0..p];
    }
    fn makeSearchUrl(query: []const u8, out: []u8) []const u8 {
        var p: usize = 0;
        append(out, &p, "http://google.com/search?q=");
        var i: usize = 0;
        while (i < query.len and p < out.len) : (i += 1) { out[p] = if (query[i] == ' ') '+' else query[i]; p += 1; }
        if (query.len == 0) append(out, &p, "core97");
        return out[0..p];
    }

    fn navigate(self: *Browser, raw: []const u8, keep_previous: bool) void {
        network.initAll();
        if (keep_previous and self.current_len != 0) self.setPrevious(self.current[0..self.current_len]);
        var norm: [URL_MAX]u8 = undefined;
        const url = normalizedUrl(raw, &norm);
        self.setUrl(url);
        self.setCurrent(url);
        const hr = network.httpGet(url);
        if (hr.status == .offline) { self.page = .offline; self.setStatus(hr.note); return; }
        if (hr.status == .tls_required or hr.status == .http_redirect_https) { self.page = .unsupported_https; self.setStatus(hr.note); return; }
        if (hr.status == .dns_error) { self.page = .not_found; self.setStatus(hr.note); return; }
        if (contains(url, "google.com/search")) self.page = .google_search
        else if (contains(url, "core97/home")) self.page = .home
        else if (contains(url, "google.com")) self.page = .google_home
        else if (contains(url, "example.com")) self.page = .example
        else if (contains(url, "neverssl.com")) self.page = .neverssl
        else if (contains(url, "yahoo.com")) self.page = .yahoo
        else if (contains(url, "altavista")) self.page = .altavista
        else if (contains(url, "info.cern.ch")) self.page = .cern
        else if (contains(url, "w3.org")) self.page = .w3c
        else if (contains(url, "textfiles.com")) self.page = .textfiles
        else if (contains(url, "frogfind.com")) self.page = .frogfind
        else if (startsWith(url, "about:webstack") or contains(url, "core97/webstack")) self.page = .http_host
        else if (contains(url, "core97/status")) self.page = .local_status
        else if (contains(url, "10.0.2.2") or contains(url, "10.0.0.1") or contains(url, "router") or contains(url, "gateway")) self.page = .router
        else self.page = .http_host;
        self.setStatus(network.browserStatusFor(url));
    }
    fn goBack(self: *Browser) void { if (self.previous_len == 0) { self.setStatus("No previous page"); return; } self.navigate(self.previous[0..self.previous_len], false); }
    fn reload(self: *Browser) void { if (self.current_len == 0) self.navigate(self.url[0..self.url_len], false) else self.navigate(self.current[0..self.current_len], false); self.setStatus("Reloaded"); }
    fn submitSearch(self: *Browser) void { var buf: [URL_MAX]u8 = undefined; const url = makeSearchUrl(self.search[0..self.search_len], &buf); self.navigate(url, true); }
    fn go(self: *Browser) void {
        const text = if (self.focus == .search) self.search[0..self.search_len] else self.url[0..self.url_len];
        if (self.focus == .search or hasSpace(text)) { var buf: [URL_MAX]u8 = undefined; const url = makeSearchUrl(text, &buf); self.navigate(url, true); }
        else self.navigate(text, true);
    }

    fn drawButton(x: u32, y: u32, w: u32, label: []const u8) void { ui.drawButton(x, y, w, 22, label, true); }
    fn drawField(x: u32, y: u32, w: u32, text: []const u8, active: bool) void {
        const hovered = ui.hit(x, y, w, 20);
        const bg: u32 = if (hovered and !active) 0xEEF5FF else fb.CORE97_WHITE;
        fb.fillRect(x, y, w, 20, bg); fb.draw3DBorder(x, y, w, 20, false);
        const max_chars: usize = if (w > 12) @intCast((w - 12) / 6) else 0;
        const start: usize = if (text.len > max_chars) text.len - max_chars else 0;
        const shown = text[start..text.len];
        fb.drawString(x + 6, y + 6, shown, fb.CORE97_BLACK, bg);
        if (active) fb.fillRect(x + 7 + @as(u32, @intCast(shown.len)) * 6, y + 4, 2, 12, fb.CORE97_BLACK);
    }
    fn drawLink(_: *Browser, x: u32, y: u32, label: []const u8, detail: []const u8) void {
        const hovered = ui.hit(x, y - 2, 390, 20);
        const bg: u32 = if (hovered) 0xD8E8FF else fb.CORE97_WHITE;
        if (hovered) fb.fillRect(x, y - 2, 390, 20, bg);
        fb.drawString(x, y, label, fb.CORE97_BLUE, bg);
        if (detail.len != 0) fb.drawString(x + 18, y + 18, detail, fb.CORE97_BLACK, fb.CORE97_WHITE);
    }
    fn drawSearchQuery(self: *Browser, x: u32, y: u32) void {
        fb.drawString(x, y, "Search:", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 54, y, self.queryText(), fb.CORE97_BLACK, fb.CORE97_WHITE);
    }

    fn drawCenteredText(x: u32, y: u32, w: u32, text: []const u8, color: u32) void {
        const tw: u32 = @as(u32, @intCast(text.len)) * 6;
        const dx = if (w > tw) x + (w - tw) / 2 else x;
        fb.drawString(dx, y, text, color, fb.CORE97_WHITE);
    }
    fn drawMiniField(x: u32, y: u32, w: u32, text: []const u8) void {
        fb.fillRect(x, y, w, 20, fb.CORE97_WHITE);
        fb.draw3DBorder(x, y, w, 20, false);
        if (text.len != 0) fb.drawString(x + 6, y + 6, text, fb.CORE97_BLACK, fb.CORE97_WHITE);
    }
    fn drawSmallButton(x: u32, y: u32, w: u32, label: []const u8) void {
        ui.drawButton(x, y, w, 22, label, true);
    }
    fn queryText(self: *Browser) []const u8 {
        return if (self.search_len != 0) self.search[0..self.search_len] else "core97";
    }

    fn drawPage(self: *Browser, x: u32, y: u32) void {
        const url = self.current[0..self.current_len];
        const rr = network.resolveHost(url);
        fb.drawString(x, y, "Page:", fb.CORE97_BLACK, fb.CORE97_WHITE); fb.drawString(x + 42, y, url, fb.CORE97_BLACK, fb.CORE97_WHITE);
        if (rr.ok) drawIpText(x, y + 18, "Resolved IP: ", rr.ip) else fb.drawString(x, y + 18, "DNS: unresolved", fb.CORE97_BLACK, fb.CORE97_WHITE);
        switch (self.page) {
            .home => {
                fb.drawString(x, y + 46, "Core97 Internet Browser", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "Browse the Internet with DNS, HTTP, links and search.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 104, "Yahoo! Internet Directory", "http://yahoo.com - web directory");
                self.drawLink(x, y + 148, "CERN World Wide Web", "http://info.cern.ch - web information page");
                self.drawLink(x, y + 192, "FrogFind / Text Proxy", "http://frogfind.com - simplified HTML pages");
            },
            .google_home, .google_search => {
                const page = webengine.render(url);
                fb.drawString(x, y + 46, page.title, fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, page.line1, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 98, page.line2, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 126, page.line3, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 154, page.line4, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 182, page.line5, fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 222, "Browser stack diagnostics", "http://core97/webstack");
                self.drawLink(x, y + 266, "Plain HTTP test page", "http://example.com");
            },

            .yahoo => {
                fb.drawString(x, y + 46, "Yahoo! Internet Directory", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "Browse curated categories and search providers.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 98, "Computers and Internet", "http://w3.org");
                self.drawLink(x, y + 142, "Search the Web", "http://altavista.digital.com");
                self.drawLink(x, y + 186, "Text Archives", "http://textfiles.com");
            },
            .altavista => {
                fb.drawString(x, y + 46, "AltaVista Search", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "Keyword search for the early web.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 98, "World Wide Web Consortium", "http://w3.org");
                self.drawLink(x, y + 142, "CERN World Wide Web", "http://info.cern.ch");
                self.drawLink(x, y + 186, "Example Domain", "http://example.com");
            },
            .cern => {
                fb.drawString(x, y + 46, "CERN World Wide Web", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "World Wide Web information, hypertext, browsers and servers.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 98, "W3C", "http://w3.org");
                self.drawLink(x, y + 142, "Example Domain", "http://example.com");
            },
            .w3c => {
                fb.drawString(x, y + 46, "World Wide Web Consortium", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "HTML, HTTP and Web standards in simple browser mode.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 98, "CERN WWW", "http://info.cern.ch");
                self.drawLink(x, y + 142, "Yahoo Directory", "http://yahoo.com");
            },
            .textfiles => {
                fb.drawString(x, y + 46, "TEXTFILES.COM", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "Plain text archives render perfectly in Core97.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 98, "Yahoo Directory", "http://yahoo.com");
                self.drawLink(x, y + 142, "FrogFind", "http://frogfind.com");
            },
            .frogfind => {
                fb.drawString(x, y + 46, "FrogFind Text Proxy", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "Use this bridge for pages that need simplified HTML output.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 98, "Yahoo Directory", "http://yahoo.com");
                self.drawLink(x, y + 142, "NeverSSL", "http://neverssl.com");
            },
            .example => {
                fb.drawString(x, y + 46, "Example Domain", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "This domain is for use in illustrative examples.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 98, "The browser resolved the host and rendered an HTTP-style page.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 126, "Back to browser home", "http://core97/home");
            },
            .neverssl => {
                fb.drawString(x, y + 46, "NeverSSL", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "This is a plain HTTP connectivity test site.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 98, "Use it to test plain HTTP before HTTPS/TLS exists.", fb.CORE97_BLACK, fb.CORE97_WHITE);
                self.drawLink(x, y + 126, "Network Status", "http://core97/status");
            },
            .router => {
                fb.drawString(x, y + 46, "Router / Gateway", fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, "Local gateway reached.", fb.CORE97_BLACK, fb.CORE97_WHITE); drawIpText(x, y + 90, "Gateway: ", network.gateway);
                fb.drawString(x, y + 118, "Network settings are available in Control Panel.", fb.CORE97_BLACK, fb.CORE97_WHITE);
            },
            .local_status => {
                fb.drawString(x, y + 46, "CORE97OS Network Status", fb.CORE97_BLUE, fb.CORE97_WHITE);
                if (network.activeAdapter()) |a| { fb.drawString(x, y + 70, a.name, fb.CORE97_BLACK, fb.CORE97_WHITE); drawIpText(x, y + 90, "IP Address: ", a.ip); drawIpText(x, y + 108, "Gateway: ", network.gateway); drawIpText(x, y + 126, "DNS: ", network.dns); }
                else fb.drawString(x, y + 70, "No active network adapter.", fb.CORE97_RED, fb.CORE97_WHITE);
                self.drawLink(x, y + 154, "Open Router", "http://router");
            },
            .http_host => {
                const hr = network.httpGet(url);
                fb.drawString(x, y + 46, hr.title, fb.CORE97_BLUE, fb.CORE97_WHITE);
                fb.drawString(x, y + 70, hr.body1, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 98, hr.body2, fb.CORE97_BLACK, fb.CORE97_WHITE);
                if (hr.body3.len != 0) fb.drawString(x, y + 126, hr.body3, fb.CORE97_BLACK, fb.CORE97_WHITE);
            },
            .unsupported_https => {
                fb.drawString(x, y + 46, "Cannot display secure page", fb.CORE97_RED, fb.CORE97_WHITE);
                const hr = network.httpGet(url);
                fb.drawString(x, y + 70, hr.body1, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 98, hr.body2, fb.CORE97_BLACK, fb.CORE97_WHITE);
                if (hr.body3.len != 0) fb.drawString(x, y + 126, hr.body3, fb.CORE97_BLACK, fb.CORE97_WHITE);
            },
            .not_found => {
                fb.drawString(x, y + 46, "Page cannot be displayed", fb.CORE97_RED, fb.CORE97_WHITE);
                const hr = network.httpGet(url);
                fb.drawString(x, y + 70, hr.body1, fb.CORE97_BLACK, fb.CORE97_WHITE);
                fb.drawString(x, y + 98, hr.body2, fb.CORE97_BLACK, fb.CORE97_WHITE);
            },
            .offline => { fb.drawString(x, y + 46, "Offline", fb.CORE97_RED, fb.CORE97_WHITE); fb.drawString(x, y + 70, "Network link is down. Check IPCONFIG and Device Manager.", fb.CORE97_BLACK, fb.CORE97_WHITE); },
        }
    }

    fn pageLink(self: *Browser, uy: u32, y: u32) ?[]const u8 {
        const py = y + 72;
        switch (self.page) {
            .home => {
                if (uy >= py + 102 and uy < py + 122) return "http://yahoo.com";
                if (uy >= py + 146 and uy < py + 166) return "http://info.cern.ch";
                if (uy >= py + 190 and uy < py + 210) return "http://frogfind.com";
            },
            .google_home => {
                if (uy >= py + 188 and uy < py + 208) return "http://google.com/search?q=core97";
                if (uy >= py + 232 and uy < py + 252) return "http://yahoo.com";
            },
            .google_search => {
                if (uy >= py + 92 and uy < py + 112) return search_hits[0].url;
                if (uy >= py + 146 and uy < py + 166) return search_hits[1].url;
                if (uy >= py + 200 and uy < py + 220) return search_hits[2].url;
                if (uy >= py + 254 and uy < py + 274) return search_hits[3].url;
            },
            .yahoo => { if (uy >= py + 96 and uy < py + 116) return "http://w3.org"; if (uy >= py + 140 and uy < py + 160) return "http://altavista.digital.com"; if (uy >= py + 184 and uy < py + 204) return "http://textfiles.com"; },
            .altavista => { if (uy >= py + 96 and uy < py + 116) return "http://w3.org"; if (uy >= py + 140 and uy < py + 160) return "http://info.cern.ch"; if (uy >= py + 184 and uy < py + 204) return "http://example.com"; },
            .cern => { if (uy >= py + 96 and uy < py + 116) return "http://w3.org"; if (uy >= py + 140 and uy < py + 160) return "http://example.com"; },
            .w3c => { if (uy >= py + 96 and uy < py + 116) return "http://info.cern.ch"; if (uy >= py + 140 and uy < py + 160) return "http://yahoo.com"; },
            .textfiles => { if (uy >= py + 96 and uy < py + 116) return "http://yahoo.com"; if (uy >= py + 140 and uy < py + 160) return "http://frogfind.com"; },
            .frogfind => { if (uy >= py + 96 and uy < py + 116) return "http://yahoo.com"; if (uy >= py + 140 and uy < py + 160) return "http://neverssl.com"; },
            .example => if (uy >= py + 124 and uy < py + 144) return "http://core97/home",
            .neverssl => if (uy >= py + 124 and uy < py + 144) return "http://core97/status",
            .local_status => if (uy >= py + 152 and uy < py + 172) return "http://router",
            else => {},
        }
        return null;
    }

    pub fn title(_: *Browser) []const u8 { return "Internet Browser"; }
    pub fn titleDetail(_: *Browser) []const u8 { return ""; }
    pub fn draw(self: *Browser, x: u32, y: u32, w: u32, h: u32) void {
        self.ensure(); network.initAll(); fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        drawButton(x + 6, y + 3, 48, "Back"); drawButton(x + 58, y + 3, 58, "Reload"); drawButton(x + 120, y + 3, 48, "Go");
        fb.drawString(x + 178, y + 10, "Address", fb.CORE97_BLACK, fb.CORE97_GREY); drawField(x + 232, y + 5, w - 240, self.url[0..self.url_len], self.focus == .address);
        fb.drawString(x + 12, y + 36, "Search", fb.CORE97_BLACK, fb.CORE97_GREY); drawField(x + 64, y + 31, w - 138, self.search[0..self.search_len], self.focus == .search); drawButton(x + w - 68, y + 30, 56, "Search");
        fb.fillRect(x + 6, y + 58, w - 12, h - 84, fb.CORE97_WHITE); fb.draw3DBorder(x + 6, y + 58, w - 12, h - 84, false); self.drawPage(x + 18, y + 72);
        fb.fillRect(x + 6, y + h - 22, w - 12, 18, fb.CORE97_GREY); fb.draw3DBorder(x + 6, y + h - 22, w - 12, 18, false); fb.drawString(x + 12, y + h - 17, if (self.status_len != 0) self.status[0..self.status_len] else "Ready", fb.CORE97_BLACK, fb.CORE97_GREY);
    }

    pub fn onMouseDown(self: *Browser, mx: i32, my: i32, _: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        self.ensure(); _ = h; const ux: u32 = if (mx < 0) 0 else @intCast(mx); const uy: u32 = if (my < 0) 0 else @intCast(my);
        if (uy >= y + 3 and uy < y + 25 and ux >= x + 6 and ux < x + 54) { self.goBack(); return .none; }
        if (uy >= y + 3 and uy < y + 25 and ux >= x + 58 and ux < x + 116) { self.reload(); return .none; }
        if (uy >= y + 3 and uy < y + 25 and ux >= x + 120 and ux < x + 168) { self.focus = .address; self.go(); return .none; }
        if (uy >= y + 5 and uy < y + 25 and ux >= x + 232 and ux < x + w - 8) { self.focus = .address; self.select_address = true; self.select_search = false; self.setStatus("Address selected"); return .none; }
        if (uy >= y + 31 and uy < y + 51 and ux >= x + 64 and ux < x + w - 76) { self.focus = .search; self.select_search = true; self.select_address = false; self.setStatus("Search selected"); return .none; }
        if (uy >= y + 30 and uy < y + 52 and ux >= x + w - 68 and ux < x + w - 12) { self.focus = .search; self.submitSearch(); return .none; }
        if (ux >= x + 18 and ux < x + 408) if (self.pageLink(uy, y)) |target| self.navigate(target, true);
        return .none;
    }
    pub fn onMouseDrag(_: *Browser, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *Browser) void {}

    fn typeChar(self: *Browser, c: u8) void {
        if (self.focus == .search) { if (c == 8) { if (self.search_len > 0) self.search_len -= 1; return; } if (c >= 32 and c <= 126 and self.search_len < self.search.len) { if (self.select_search) { self.search_len = 0; self.select_search = false; } self.search[self.search_len] = c; self.search_len += 1; self.setStatus("Editing search"); } return; }
        if (c == 8) { if (self.url_len > 0) self.url_len -= 1; return; }
        if (c >= 32 and c <= 126 and self.url_len < self.url.len) { if (self.select_address) { self.url_len = 0; self.select_address = false; } self.url[self.url_len] = c; self.url_len += 1; self.setStatus("Editing address"); }
    }
    pub fn onKeyAscii(self: *Browser, c: u8) void { self.ensure(); if (c == 9) { self.focus = if (self.focus == .address) .search else .address; self.select_address = self.focus == .address; self.select_search = self.focus == .search; return; } if (c == 13) { self.go(); return; } self.typeChar(c); }

    fn hidToAscii(code: u8, modifiers: u8) u8 {
        const shift = (modifiers & 0x22) != 0;
        if (code >= 0x04 and code <= 0x1d) { const c: u8 = 'a' + (code - 0x04); return if (shift) c - 32 else c; }
        if (code >= 0x1e and code <= 0x26) { const normal = "123456789"; const shifted = "!@#$%^&*("; const idx: usize = @intCast(code - 0x1e); return if (shift) shifted[idx] else normal[idx]; }
        if (code == 0x27) return if (shift) ')' else '0'; if (code == 0x2c) return ' '; if (code == 0x2d) return if (shift) '_' else '-'; if (code == 0x2e) return if (shift) '+' else '='; if (code == 0x2f) return if (shift) '{' else '['; if (code == 0x30) return if (shift) '}' else ']'; if (code == 0x31) return if (shift) '|' else '\\'; if (code == 0x33) return if (shift) ':' else ';'; if (code == 0x34) return if (shift) @as(u8, 34) else @as(u8, 39); if (code == 0x36) return if (shift) '<' else ','; if (code == 0x37) return if (shift) '>' else '.'; if (code == 0x38) return if (shift) '?' else '/'; return 0;
    }
    pub fn onKeyUsb(self: *Browser, code: u8, modifiers: u8, _: u32) bool { self.ensure(); if (code == 0x2b) { self.focus = if (self.focus == .address) .search else .address; self.select_address = self.focus == .address; self.select_search = self.focus == .search; return true; } if (code == 0x28) { self.go(); return true; } if (code == 0x2a) { self.typeChar(8); return true; } const c = hidToAscii(code, modifiers); if (c != 0) { self.typeChar(c); return true; } return false; }
    pub fn hasModalCapture(_: *Browser) bool { return false; }
};

var instance: Browser = .{};
pub fn asApp() window.App { return window.appFrom(Browser, &instance); }
