// browser/engine.zig - staged browser pipeline for Core97.
// URL -> network fetch -> HTTP parse/status -> codecs -> HTML text render -> DOM/CSS/JS hooks.

const network = @import("../drivers/network.zig");
const html = @import("html.zig");
const codecs = @import("codecs.zig");
const tls = @import("tls.zig");
const storage = @import("storage.zig");

pub const Feature = enum { dns, http, redirect, tls, gzip, brotli, html, css, dom, javascript, forms, cookies, storage };
pub const FeatureState = enum { off, stub, partial, ready };
pub const FeatureReport = struct { name: []const u8, state: FeatureState, note: []const u8 };

pub const report = [_]FeatureReport{
    .{ .name = "DNS", .state = .partial, .note = "host cache + URL resolver; real UDP/53 packet module staged next" },
    .{ .name = "HTTP", .state = .partial, .note = "request builder/parser + browser fetch facade; socket RX/TX still emulator-gated" },
    .{ .name = "Redirects", .state = .partial, .note = "Location policy model present; bounded follow in browser engine" },
    .{ .name = "TLS/HTTPS", .state = .partial, .note = "TLS record/session and ClientHello bytes staged; crypto/certs not complete" },
    .{ .name = "gzip", .state = .partial, .note = "detects compression and requests identity; inflater not complete" },
    .{ .name = "brotli", .state = .off, .note = "not advertised; modern br pages need decoder later" },
    .{ .name = "HTML", .state = .partial, .note = "forgiving tag stripper, entities, line breaks and link extraction" },
    .{ .name = "CSS", .state = .partial, .note = "default block/inline styling; no full cascade yet" },
    .{ .name = "DOM", .state = .partial, .note = "flat document model for text, links and forms" },
    .{ .name = "JavaScript", .state = .stub, .note = "safe tiny entry point; unsupported scripts ignored instead of crashing" },
    .{ .name = "Forms", .state = .partial, .note = "GET/search forms route through address/search box" },
    .{ .name = "Cookies", .state = .partial, .note = "in-memory cookie jar; persistence waits for VFS" },
    .{ .name = "Storage", .state = .stub, .note = "local storage API shape; filesystem backing pending" },
};

pub const RenderKind = enum { text, google_live_blocked, diagnostics };
pub const RenderedPage = struct {
    kind: RenderKind,
    title: []const u8,
    line1: []const u8,
    line2: []const u8,
    line3: []const u8,
    line4: []const u8,
    line5: []const u8,
    status: []const u8,
};

fn upper(c: u8) u8 { return if (c >= 'a' and c <= 'z') c - 32 else c; }
fn startsWith(a: []const u8, b: []const u8) bool { if (a.len < b.len) return false; var i: usize = 0; while (i < b.len) : (i += 1) if (upper(a[i]) != upper(b[i])) return false; return true; }
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

fn lineAt(text: []const u8, n: usize) []const u8 {
    var current: usize = 0; var start: usize = 0; var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            if (current == n) return text[start..i];
            current += 1; start = i + 1;
        }
    }
    return "";
}

pub fn render(url: []const u8) RenderedPage {
    const parsed = network.parseUrl(url);
    if (parsed.https) {
        var hello: [96]u8 = undefined;
        const ch = tls.buildClientHello(parsed.host, &hello);
        _ = ch;
        return .{
            .kind = .google_live_blocked,
            .title = "HTTPS pipeline reached TLS",
            .line1 = "DNS and browser routing reached the secure host.",
            .line2 = "Core97 can now build a ClientHello/SNI record skeleton.",
            .line3 = "Missing for true live HTTPS: AES/ChaCha, SHA/HMAC, X.509 cert chain, TCP RX/TX.",
            .line4 = "Use plain HTTP pages while the HTTPS transport is completed.",
            .line5 = network.networkPipelineStatus(),
            .status = "HTTPS waits for TCP stream + crypto",
        };
    }

    const http = network.httpGet(url);
    if (http.status != .ok) return .{ .kind=.diagnostics, .title=http.title, .line1=http.body1, .line2=http.body2, .line3=http.body3, .line4="", .line5="", .status=http.note };

    if (startsWith(url, "about:webstack") or contains(url, "core97/webstack")) return .{
        .kind = .diagnostics,
        .title = "Core97 Browser Stack - One-Go Patch",
        .line1 = "Added HTTP parser/request builder, TLS ClientHello skeleton, codec dispatch, HTML text renderer.",
        .line2 = "Added flat DOM, CSS defaults, tiny JS guard, forms routing, cookies/storage APIs.",
        .line3 = "Plain HTTP pages now travel through one shared browser pipeline.",
        .line4 = "Compression is detected safely; browser asks for identity until gzip inflater is finished.",
        .line5 = network.networkPipelineStatus(),
        .status = "Network transport staging active",
    };

    // Convert the network facade result through the same HTML text pipeline so the UI is no longer site-specific.
    var raw: [512]u8 = undefined;
    var p: usize = 0;
    append(&raw, &p, "<html><body><h1>"); append(&raw, &p, http.title); append(&raw, &p, "</h1><p>"); append(&raw, &p, http.body1); append(&raw, &p, "</p><p>"); append(&raw, &p, http.body2); append(&raw, &p, "</p><p>"); append(&raw, &p, http.body3); append(&raw, &p, "</p></body></html>");
    var scratch: [512]u8 = undefined;
    const enc = codecs.detect("");
    const decoded = codecs.decode(enc, raw[0..p], &scratch);
    var textbuf: [512]u8 = undefined;
    const text = html.renderToText(decoded, &textbuf);
    storage.setCookie(parsed.host, "last", "1");
    return .{ .kind=.text, .title=http.title, .line1=lineAt(text,0), .line2=lineAt(text,1), .line3=lineAt(text,2), .line4=lineAt(text,3), .line5=lineAt(text,4), .status=http.note };
}
fn append(out: []u8, pos: *usize, text: []const u8) void { var i: usize = 0; while (i < text.len and pos.* < out.len) : (i += 1) { out[pos.*] = text[i]; pos.* += 1; } }
