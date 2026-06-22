// browser/storage.zig - in-memory cookies/localStorage until VFS persistence is ready.
pub const Cookie = struct { host: []const u8, name: []const u8, value: []const u8 };
var cookies: [16]Cookie = undefined; var cookie_count: usize = 0;
pub fn setCookie(host: []const u8, name: []const u8, value: []const u8) void { if(cookie_count>=cookies.len)return; cookies[cookie_count]=.{.host=host,.name=name,.value=value}; cookie_count+=1; }
pub fn getCookie(host: []const u8, name: []const u8) []const u8 { var i:usize=0; while(i<cookie_count):(i+=1) if(cookies[i].host.len==host.len and cookies[i].name.len==name.len) return cookies[i].value; return ""; }
pub fn count() usize { return cookie_count; }
