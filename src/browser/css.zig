// browser/css.zig - tiny default style layer.
pub const Display = enum { block, inline, none };
pub const Style = struct { display: Display, margin_top: u8, margin_bottom: u8, bold: bool, underline: bool };
pub fn defaultStyle(tag: []const u8) Style { if(tag.len>0 and (tag[0]=='h' or tag[0]=='H')) return .{.display=.block,.margin_top=1,.margin_bottom=1,.bold=true,.underline=false}; if(tag.len==1 and (tag[0]=='a' or tag[0]=='A')) return .{.display=.inline,.margin_top=0,.margin_bottom=0,.bold=false,.underline=true}; return .{.display=.block,.margin_top=0,.margin_bottom=1,.bold=false,.underline=false}; }
