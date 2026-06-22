// browser/html.zig - early forgiving HTML-to-text renderer.
pub const Link = struct { text: []const u8, href: []const u8 };
pub const TextPage = struct { title: []const u8, lines: [12][]const u8, line_count: usize, links: [8]Link, link_count: usize };
fn lower(c: u8) u8 { return if (c >= 'A' and c <= 'Z') c + 32 else c; }
fn eqi(a: []const u8, b: []const u8) bool { if (a.len != b.len) return false; var i:usize=0; while(i<a.len):(i+=1) if(lower(a[i])!=lower(b[i])) return false; return true; }
fn containsTag(tag: []const u8, name: []const u8) bool { if (tag.len < name.len) return false; var i:usize=0; while(i+name.len<=tag.len):(i+=1) if(eqi(tag[i..i+name.len], name)) return true; return false; }
fn startsWithI(a: []const u8, b: []const u8) bool { if(a.len<b.len)return false; return eqi(a[0..b.len], b); }
fn append(out: []u8, p: *usize, s: []const u8) void { var i:usize=0; while(i<s.len and p.*<out.len):(i+=1){ out[p.*]=s[i]; p.*+=1; } }
fn entity(out: []u8, p:*usize, s:[]const u8, i:*usize) bool {
    if (startsWithI(s[i.*..], "&amp;")) { append(out,p,"&"); i.* += 4; return true; }
    if (startsWithI(s[i.*..], "&lt;")) { append(out,p,"<"); i.* += 3; return true; }
    if (startsWithI(s[i.*..], "&gt;")) { append(out,p,">"); i.* += 3; return true; }
    if (startsWithI(s[i.*..], "&quot;")) { append(out,p,"\""); i.* += 5; return true; }
    return false;
}
fn attr(tag: []const u8, name: []const u8) []const u8 {
    var i:usize=0; while(i+name.len<tag.len):(i+=1){
        if(eqi(tag[i..i+name.len], name) and i+name.len<tag.len and tag[i+name.len]=='='){
            var v=i+name.len+1; if(v>=tag.len)return ""; const q=tag[v]; if(q=='\"' or q=='\''){ v+=1; var e=v; while(e<tag.len and tag[e]!=q):(e+=1){} return tag[v..e]; }
            var e=v; while(e<tag.len and tag[e]!=' ' and tag[e]!='>'):(e+=1){} return tag[v..e];
        }
    }
    return "";
}
pub fn renderToText(html: []const u8, scratch: []u8) []const u8 {
    var p:usize=0; var i:usize=0; var in_tag=false; var last_space=false;
    while(i<html.len and p<scratch.len):(i+=1){
        const c=html[i];
        if(c=='<'){ in_tag=true; var e=i+1; while(e<html.len and html[e]!='>'):(e+=1){} const tag=html[i+1..e]; if(containsTag(tag,"br") or containsTag(tag,"/p") or containsTag(tag,"/h1") or containsTag(tag,"/h2") or containsTag(tag,"/li")){ append(scratch,&p,"\n"); last_space=true; } i=e; in_tag=false; continue; }
        if(in_tag) continue;
        if(c=='&' and entity(scratch,&p,html,&i)) { last_space=false; continue; }
        if(c=='\r') continue;
        if(c=='\n' or c=='\t' or c==' '){ if(!last_space){ scratch[p]=' '; p+=1; last_space=true; } continue; }
        scratch[p]=c; p+=1; last_space=false;
    }
    return scratch[0..p];
}
pub fn extractLinks(html: []const u8, store: []Link) []Link {
    var count:usize=0; var i:usize=0;
    while(i<html.len and count<store.len):(i+=1){
        if(html[i]=='<' and i+2<html.len and lower(html[i+1])=='a'){
            var e=i+1;
            while(e<html.len and html[e]!='>'):(e+=1){}
            if(e>=html.len) break;
            const tag=html[i+1..e]; const href=attr(tag,"href");
            var close=e+1; while(close+4<html.len and !(html[close]=='<' and html[close+1]=='/' and lower(html[close+2])=='a')):(close+=1){}
            const label=html[e+1..close]; if(href.len!=0){ store[count]=.{.text=label,.href=href}; count+=1; }
            i=close;
        }
    }
    return store[0..count];
}
