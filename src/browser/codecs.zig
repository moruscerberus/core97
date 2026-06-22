// browser/codecs.zig - content-encoding dispatch. Identity works now; gzip is detected safely.
pub const Encoding = enum { identity, gzip, brotli, deflate, unsupported };
fn lower(c:u8)u8{return if(c>='A' and c<='Z')c+32 else c;}
fn contains(h:[]const u8,n:[]const u8)bool{if(n.len==0)return true; var i:usize=0; while(i+n.len<=h.len):(i+=1){var j:usize=0; while(j<n.len and lower(h[i+j])==lower(n[j])):(j+=1){} if(j==n.len)return true;} return false;}
pub fn detect(header: []const u8) Encoding { if(header.len==0 or contains(header,"identity")) return .identity; if(contains(header,"gzip")) return .gzip; if(contains(header,"br")) return .brotli; if(contains(header,"deflate")) return .deflate; return .unsupported; }
pub fn decode(enc: Encoding, input: []const u8, out: []u8) []const u8 { switch(enc){ .identity => return input, else => { const msg="Compressed response detected. Core97 asks servers for identity encoding until inflater lands."; var p:usize=0; while(p<msg.len and p<out.len):(p+=1)out[p]=msg[p]; return out[0..p]; } } }
