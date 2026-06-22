// browser/js.zig - deliberately tiny JS entry point. Supports alert()/location assignment detection only.
pub const JsResult = struct { ran: bool, navigation: []const u8, message: []const u8 };
fn startsWith(s:[]const u8,p:[]const u8)bool{ if(s.len<p.len)return false; var i:usize=0; while(i<p.len):(i+=1) if(s[i]!=p[i]) return false; return true; }
pub fn run(script: []const u8) JsResult { if(startsWith(script,"alert(")) return .{.ran=true,.navigation="",.message="script alert suppressed"}; return .{.ran=false,.navigation="",.message="unsupported JavaScript ignored"}; }
