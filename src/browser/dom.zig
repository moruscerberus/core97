// browser/dom.zig - flat DOM model for simple web pages.
pub const NodeKind = enum { document, element, text, link, form, input, script };
pub const Node = struct { kind: NodeKind, name: []const u8, text: []const u8, href: []const u8 };
pub const Document = struct { title: []const u8, nodes: []Node };
pub fn makeTextDocument(title: []const u8, text: []const u8, nodes: []Node) Document { if(nodes.len>0) nodes[0]=.{.kind=.text,.name="text",.text=text,.href=""}; return .{.title=title,.nodes=nodes[0..if(nodes.len>0)1 else 0]}; }
