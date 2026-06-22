// browser/http.zig - small HTTP/1.x parser and request builder for Core97.
// No heap, no std: fixed buffers only.

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Response = struct {
    valid: bool,
    status_code: usize,
    reason: []const u8,
    headers: []const Header,
    body: []const u8,
    location: []const u8,
    content_encoding: []const u8,
};

fn lower(c: u8) u8 { return if (c >= 'A' and c <= 'Z') c + 32 else c; }
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0; while (i < a.len) : (i += 1) if (lower(a[i]) != lower(b[i])) return false;
    return true;
}
fn startsWith(a: []const u8, b: []const u8) bool {
    if (a.len < b.len) return false;
    var i: usize = 0; while (i < b.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}
fn find(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0; while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0; while (j < needle.len and hay[i+j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return i;
    }
    return null;
}
fn parseInt(text: []const u8) usize {
    var v: usize = 0; var i: usize = 0;
    while (i < text.len) : (i += 1) { if (text[i] < '0' or text[i] > '9') break; v = v * 10 + @as(usize, text[i] - '0'); }
    return v;
}
fn trim(s: []const u8) []const u8 {
    var a: usize = 0; var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n')) : (a += 1) {}
    while (b > a and (s[b-1] == ' ' or s[b-1] == '\t' or s[b-1] == '\r' or s[b-1] == '\n')) : (b -= 1) {}
    return s[a..b];
}

pub fn buildGet(host: []const u8, path: []const u8, out: []u8) []const u8 {
    var p: usize = 0;
    append(out, &p, "GET "); append(out, &p, if (path.len == 0) "/" else path); append(out, &p, " HTTP/1.1\r\nHost: ");
    append(out, &p, host); append(out, &p, "\r\nUser-Agent: Core97/0.1\r\nAccept: text/html,text/plain,*/*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n");
    return out[0..p];
}
fn append(out: []u8, p: *usize, s: []const u8) void { var i: usize = 0; while (i < s.len and p.* < out.len) : (i += 1) { out[p.*] = s[i]; p.* += 1; } }

pub fn parse(raw: []const u8, header_store: []Header) Response {
    var headers_len: usize = 0;
    const split = find(raw, "\r\n\r\n") orelse return .{ .valid=false, .status_code=0, .reason="bad response", .headers=header_store[0..0], .body="", .location="", .content_encoding="" };
    const head = raw[0..split];
    const body = raw[split+4..];
    var line_start: usize = 0;
    const line_end = find(head, "\r\n") orelse head.len;
    const status_line = head[0..line_end];
    var status: usize = 0; var reason: []const u8 = "";
    if (startsWith(status_line, "HTTP/")) {
        var sp: usize = 0; while (sp < status_line.len and status_line[sp] != ' ') : (sp += 1) {}
        while (sp < status_line.len and status_line[sp] == ' ') : (sp += 1) {}
        status = parseInt(status_line[sp..]);
        while (sp < status_line.len and status_line[sp] != ' ') : (sp += 1) {}
        reason = if (sp < status_line.len) trim(status_line[sp..]) else "";
    }
    line_start = if (line_end < head.len) line_end + 2 else head.len;
    var location: []const u8 = ""; var enc: []const u8 = "";
    while (line_start < head.len and headers_len < header_store.len) {
        var e = line_start; while (e < head.len and !(head[e] == '\r' and e + 1 < head.len and head[e+1] == '\n')) : (e += 1) {}
        const line = head[line_start..e];
        var c: usize = 0; while (c < line.len and line[c] != ':') : (c += 1) {}
        if (c < line.len) {
            const n = trim(line[0..c]); const v = trim(line[c+1..]);
            header_store[headers_len] = .{ .name=n, .value=v }; headers_len += 1;
            if (eqIgnoreCase(n, "Location")) location = v;
            if (eqIgnoreCase(n, "Content-Encoding")) enc = v;
        }
        line_start = if (e + 2 <= head.len) e + 2 else head.len;
    }
    return .{ .valid=true, .status_code=status, .reason=reason, .headers=header_store[0..headers_len], .body=body, .location=location, .content_encoding=enc };
}
