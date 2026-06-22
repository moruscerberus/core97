// sdk/script.zig - tiny scripting language for SDK apps.
//
// No std, no allocator: programs compile into fixed-size arrays (same
// static-pool style as the rest of this kernel), and the interpreter
// walks the AST directly rather than compiling to a separate bytecode
// form - simpler to get right, and fast enough for UI-scale scripts
// (a handful of draw calls per frame, not a hot inner loop).
//
// Drawing/host-call side effects go through an injected HostOps vtable
// instead of calling framebuffer.zig directly, so this file has zero
// kernel dependencies and can be unit-tested on a regular host target.
// See docs/sdk-vm-design.md for the overall design rationale.

pub const NONE: u16 = 0xFFFF;

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

// ===========================================================================
// Lexer
// ===========================================================================

pub const TokKind = enum {
    eof,
    int,
    str,
    ident,
    plus,
    minus,
    star,
    slash,
    eq,
    eq_eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    lparen,
    rparen,
    lbrace,
    rbrace,
    comma,
    invalid,
};

pub const Token = struct {
    kind: TokKind = .eof,
    text: []const u8 = "",
    int_val: i32 = 0,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    fn peekChar(self: *Lexer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        if (self.pos >= self.src.len) return .{ .kind = .eof };
        const c = self.src[self.pos];

        if (isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
            var v: i32 = 0;
            var i = start;
            while (i < self.pos) : (i += 1) v = v * 10 + @as(i32, self.src[i] - '0');
            return .{ .kind = .int, .int_val = v };
        }
        if (isAlpha(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isAlnum(self.src[self.pos])) self.pos += 1;
            return .{ .kind = .ident, .text = self.src[start..self.pos] };
        }
        if (c == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '"') self.pos += 1;
            const text = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .kind = .str, .text = text };
        }
        self.pos += 1;
        return switch (c) {
            '+' => .{ .kind = .plus },
            '-' => .{ .kind = .minus },
            '*' => .{ .kind = .star },
            '/' => .{ .kind = .slash },
            '(' => .{ .kind = .lparen },
            ')' => .{ .kind = .rparen },
            '{' => .{ .kind = .lbrace },
            '}' => .{ .kind = .rbrace },
            ',' => .{ .kind = .comma },
            '<' => if (self.peekChar() == '=') blk: {
                self.pos += 1;
                break :blk .{ .kind = .lt_eq };
            } else .{ .kind = .lt },
            '>' => if (self.peekChar() == '=') blk: {
                self.pos += 1;
                break :blk .{ .kind = .gt_eq };
            } else .{ .kind = .gt },
            '=' => if (self.peekChar() == '=') blk: {
                self.pos += 1;
                break :blk .{ .kind = .eq_eq };
            } else .{ .kind = .eq },
            '!' => if (self.peekChar() == '=') blk: {
                self.pos += 1;
                break :blk .{ .kind = .bang_eq };
            } else .{ .kind = .invalid },
            else => .{ .kind = .invalid },
        };
    }
};

// ===========================================================================
// AST
// ===========================================================================

pub const NodeTag = enum {
    int_lit,
    str_lit,
    bool_lit,
    ident,
    add,
    sub,
    mul,
    div,
    eqq,
    neq,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    neg,
    call,
    assign,
    if_stmt,
    while_stmt,
    block,
    var_decl,
};

pub const Node = struct {
    tag: NodeTag = .int_lit,
    str_val: []const u8 = "",
    int_val: i32 = 0,
    bool_val: bool = false,
    a: u16 = NONE,
    b: u16 = NONE,
    c: u16 = NONE,
    extra: u16 = NONE,
    extra_count: u16 = 0,
};

pub const MAX_NODES: usize = 160;
pub const MAX_EXTRA: usize = 160;
pub const MAX_VAR_DECLS: usize = 16;

pub const Program = struct {
    nodes: [MAX_NODES]Node = undefined,
    node_count: u16 = 0,
    extra: [MAX_EXTRA]u16 = undefined,
    extra_count: u16 = 0,
    on_draw: u16 = NONE,
    on_click: u16 = NONE,
    on_key: u16 = NONE,
    var_decls: [MAX_VAR_DECLS]u16 = undefined,
    var_decl_count: u16 = 0,
    valid: bool = true,
    error_msg: []const u8 = "",
};

// ===========================================================================
// Parser (recursive descent, one token of lookahead)
// ===========================================================================

const ParseError = error{ UnexpectedToken, TooManyNodes, TooManyExtras };

const Parser = struct {
    lex: Lexer,
    cur: Token,
    prog: *Program,

    fn init(source: []const u8, prog: *Program) Parser {
        var lex = Lexer.init(source);
        const first = lex.next();
        return .{ .lex = lex, .cur = first, .prog = prog };
    }

    fn advance(self: *Parser) void {
        self.cur = self.lex.next();
    }

    fn expect(self: *Parser, kind: TokKind) ParseError!Token {
        if (self.cur.kind != kind) return error.UnexpectedToken;
        const t = self.cur;
        self.advance();
        return t;
    }

    fn isKeyword(tok: Token, kw: []const u8) bool {
        return tok.kind == .ident and strEq(tok.text, kw);
    }

    fn addNode(self: *Parser, n: Node) ParseError!u16 {
        if (self.prog.node_count >= MAX_NODES) return error.TooManyNodes;
        const idx = self.prog.node_count;
        self.prog.nodes[idx] = n;
        self.prog.node_count += 1;
        return idx;
    }

    fn addExtra(self: *Parser, items: []const u16) ParseError!u16 {
        if (@as(usize, self.prog.extra_count) + items.len > MAX_EXTRA) return error.TooManyExtras;
        const start = self.prog.extra_count;
        for (items) |it| {
            self.prog.extra[self.prog.extra_count] = it;
            self.prog.extra_count += 1;
        }
        return start;
    }

    /// program := (var_decl | on_handler)*
    fn parseProgram(self: *Parser) ParseError!void {
        while (self.cur.kind != .eof) {
            if (isKeyword(self.cur, "var")) {
                const idx = try self.parseVarDecl();
                if (self.prog.var_decl_count < self.prog.var_decls.len) {
                    self.prog.var_decls[self.prog.var_decl_count] = idx;
                    self.prog.var_decl_count += 1;
                }
            } else if (isKeyword(self.cur, "on")) {
                try self.parseOnHandler();
            } else {
                return error.UnexpectedToken;
            }
        }
    }

    fn parseVarDecl(self: *Parser) ParseError!u16 {
        self.advance(); // "var"
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.eq);
        const value = try self.parseExpr();
        return self.addNode(.{ .tag = .var_decl, .str_val = name_tok.text, .a = value });
    }

    fn parseOnHandler(self: *Parser) ParseError!void {
        self.advance(); // "on"
        const name_tok = try self.expect(.ident);
        const body = try self.parseBlock();
        if (strEq(name_tok.text, "draw")) {
            self.prog.on_draw = body;
        } else if (strEq(name_tok.text, "click")) {
            self.prog.on_click = body;
        } else if (strEq(name_tok.text, "key")) {
            self.prog.on_key = body;
        } else return error.UnexpectedToken;
    }

    fn parseBlock(self: *Parser) ParseError!u16 {
        _ = try self.expect(.lbrace);
        var stmts: [64]u16 = undefined;
        var count: usize = 0;
        while (self.cur.kind != .rbrace) {
            if (self.cur.kind == .eof) return error.UnexpectedToken;
            if (count >= stmts.len) return error.TooManyNodes;
            stmts[count] = try self.parseStatement();
            count += 1;
        }
        self.advance(); // "}"
        const extra_start = try self.addExtra(stmts[0..count]);
        return self.addNode(.{ .tag = .block, .extra = extra_start, .extra_count = @intCast(count) });
    }

    fn parseStatement(self: *Parser) ParseError!u16 {
        if (isKeyword(self.cur, "if")) return self.parseIf();
        if (isKeyword(self.cur, "while")) return self.parseWhile();
        if (self.cur.kind == .ident) {
            const name_tok = self.cur;
            var look = self.lex; // Lexer is a plain value (slice + index) - this is a real independent snapshot, safe to peek ahead with.
            const after = look.next();
            if (after.kind == .eq) {
                self.advance(); // ident
                self.advance(); // "="
                const value = try self.parseExpr();
                return self.addNode(.{ .tag = .assign, .str_val = name_tok.text, .a = value });
            }
        }
        // Otherwise it's an expression used as a statement (a bare call,
        // e.g. `redraw()`).
        return self.parseExpr();
    }

    fn parseIf(self: *Parser) ParseError!u16 {
        self.advance(); // "if"
        const cond = try self.parseExpr();
        const then_block = try self.parseBlock();
        var else_block: u16 = NONE;
        if (isKeyword(self.cur, "else")) {
            self.advance();
            else_block = try self.parseBlock();
        }
        return self.addNode(.{ .tag = .if_stmt, .a = cond, .b = then_block, .c = else_block });
    }

    fn parseWhile(self: *Parser) ParseError!u16 {
        self.advance(); // "while"
        const cond = try self.parseExpr();
        const body = try self.parseBlock();
        return self.addNode(.{ .tag = .while_stmt, .a = cond, .b = body });
    }

    fn parseExpr(self: *Parser) ParseError!u16 {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!u16 {
        var left = try self.parseAnd();
        while (isKeyword(self.cur, "or")) {
            self.advance();
            const right = try self.parseAnd();
            left = try self.addNode(.{ .tag = .or_, .a = left, .b = right });
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!u16 {
        var left = try self.parseCmp();
        while (isKeyword(self.cur, "and")) {
            self.advance();
            const right = try self.parseCmp();
            left = try self.addNode(.{ .tag = .and_, .a = left, .b = right });
        }
        return left;
    }

    fn parseCmp(self: *Parser) ParseError!u16 {
        var left = try self.parseAdd();
        while (true) {
            const tag: NodeTag = switch (self.cur.kind) {
                .eq_eq => .eqq,
                .bang_eq => .neq,
                .lt => .lt,
                .lt_eq => .le,
                .gt => .gt,
                .gt_eq => .ge,
                else => break,
            };
            self.advance();
            const right = try self.parseAdd();
            left = try self.addNode(.{ .tag = tag, .a = left, .b = right });
        }
        return left;
    }

    fn parseAdd(self: *Parser) ParseError!u16 {
        var left = try self.parseMul();
        while (self.cur.kind == .plus or self.cur.kind == .minus) {
            const tag: NodeTag = if (self.cur.kind == .plus) .add else .sub;
            self.advance();
            const right = try self.parseMul();
            left = try self.addNode(.{ .tag = tag, .a = left, .b = right });
        }
        return left;
    }

    fn parseMul(self: *Parser) ParseError!u16 {
        var left = try self.parseUnary();
        while (self.cur.kind == .star or self.cur.kind == .slash) {
            const tag: NodeTag = if (self.cur.kind == .star) .mul else .div;
            self.advance();
            const right = try self.parseUnary();
            left = try self.addNode(.{ .tag = tag, .a = left, .b = right });
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!u16 {
        if (self.cur.kind == .minus) {
            self.advance();
            const v = try self.parseUnary();
            return self.addNode(.{ .tag = .neg, .a = v });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!u16 {
        switch (self.cur.kind) {
            .int => {
                const v = self.cur.int_val;
                self.advance();
                return self.addNode(.{ .tag = .int_lit, .int_val = v });
            },
            .str => {
                const s = self.cur.text;
                self.advance();
                return self.addNode(.{ .tag = .str_lit, .str_val = s });
            },
            .lparen => {
                self.advance();
                const e = try self.parseExpr();
                _ = try self.expect(.rparen);
                return e;
            },
            .ident => {
                const name = self.cur.text;
                if (strEq(name, "true") or strEq(name, "false")) {
                    self.advance();
                    return self.addNode(.{ .tag = .bool_lit, .bool_val = strEq(name, "true") });
                }
                self.advance();
                if (self.cur.kind == .lparen) {
                    self.advance();
                    var args: [8]u16 = undefined;
                    var count: usize = 0;
                    if (self.cur.kind != .rparen) {
                        while (true) {
                            if (count >= args.len) return error.TooManyNodes;
                            args[count] = try self.parseExpr();
                            count += 1;
                            if (self.cur.kind == .comma) {
                                self.advance();
                                continue;
                            }
                            break;
                        }
                    }
                    _ = try self.expect(.rparen);
                    const extra_start = try self.addExtra(args[0..count]);
                    return self.addNode(.{ .tag = .call, .str_val = name, .extra = extra_start, .extra_count = @intCast(count) });
                }
                return self.addNode(.{ .tag = .ident, .str_val = name });
            },
            else => return error.UnexpectedToken,
        }
    }
};

/// Compiles source text into a Program. Never fails outwardly - a
/// malformed script just comes back with `valid = false` and a short
/// `error_msg`, so a broken app shows an error in its own window
/// instead of anything going wrong at the call site.
pub fn compile(source: []const u8) Program {
    var prog = Program{};
    compileInto(source, &prog);
    return prog;
}

/// Same as compile(), but writes into `out` directly instead of
/// building the Program (160 nodes + 160 extras, a few KB) as a stack
/// local and returning it by value. On this kernel's 16KB stack that's
/// not optional: `out` should point at a field of an already-static
/// instance (see apps/script_app.zig), never a fresh stack local.
pub fn compileInto(source: []const u8, out: *Program) void {
    out.* = .{};
    var parser = Parser.init(source, out);
    parser.parseProgram() catch |err| {
        out.valid = false;
        out.error_msg = switch (err) {
            error.UnexpectedToken => "syntax error",
            error.TooManyNodes => "script too large",
            error.TooManyExtras => "script too large",
        };
    };
}

// ===========================================================================
// Interpreter
// ===========================================================================

pub const Value = union(enum) {
    int: i32,
    str: []const u8,
    boolean: bool,
    none,

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .int => |v| v != 0,
            .boolean => |b| b,
            .str => |s| s.len != 0,
            .none => false,
        };
    }

    pub fn asInt(self: Value) i32 {
        return switch (self) {
            .int => |v| v,
            .boolean => |b| if (b) 1 else 0,
            else => 0,
        };
    }
};

fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .int => |av| switch (b) {
            .int => |bv| av == bv,
            else => false,
        },
        .boolean => |av| switch (b) {
            .boolean => |bv| av == bv,
            else => false,
        },
        .str => |av| switch (b) {
            .str => |bv| strEq(av, bv),
            else => false,
        },
        .none => b == .none,
    };
}

/// Everything a script can observe about the world this frame/event,
/// supplied by the embedder (script_app.zig in the kernel build).
/// Coordinates here are content-area-relative, so scripts never need to
/// know their window's screen position.
pub const HostCtx = struct {
    w: u32 = 0,
    h: u32 = 0,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_down: bool = false,
    key_ascii: u8 = 0,
};

/// Side-effecting drawing calls, injected so this file has no drawing
/// dependency of its own. `ctx` is opaque to the interpreter - it's
/// whatever the embedder needs to actually draw (e.g. the content
/// area's absolute screen origin, to translate the relative coordinates
/// scripts use).
pub const HostOps = struct {
    drawRect: *const fn (ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, color: i32) void,
    drawText: *const fn (ctx: *anyopaque, x: i32, y: i32, text: []const u8, fg: i32, bg: i32) void,
    drawBorder: *const fn (ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, raised: bool) void,
};

const VarSlot = struct { name: []const u8 = "", value: Value = .none };
const MAX_VARS: usize = 32;

pub const Interp = struct {
    prog: *const Program,
    vars: [MAX_VARS]VarSlot = [_]VarSlot{.{}} ** MAX_VARS,
    var_count: u16 = 0,
    ops: *const HostOps,
    ops_ctx: *anyopaque,
    hctx: HostCtx = .{},
    fmt_buf: [16]u8 = undefined,
    loop_guard: u32 = 0,

    pub fn init(prog: *const Program, ops: *const HostOps, ops_ctx: *anyopaque) Interp {
        return .{ .prog = prog, .ops = ops, .ops_ctx = ops_ctx };
    }

    /// Runs every top-level `var x = ...` once. Call after init(), before
    /// the first runDraw/runClick/runKey - this is what makes state
    /// persist across redraws instead of resetting every frame.
    pub fn loadVarDecls(self: *Interp) void {
        var i: usize = 0;
        while (i < self.prog.var_decl_count) : (i += 1) {
            self.execStmt(self.prog.var_decls[i]);
        }
    }

    fn findVar(self: *Interp, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.var_count) : (i += 1) {
            if (strEq(self.vars[i].name, name)) return i;
        }
        return null;
    }

    fn setVar(self: *Interp, name: []const u8, value: Value) void {
        if (self.findVar(name)) |i| {
            self.vars[i].value = value;
            return;
        }
        if (self.var_count < self.vars.len) {
            self.vars[self.var_count] = .{ .name = name, .value = value };
            self.var_count += 1;
        }
    }

    pub fn getVar(self: *Interp, name: []const u8) Value {
        if (self.findVar(name)) |i| return self.vars[i].value;
        return .none;
    }

    pub fn getVarForTest(self: *Interp, name: []const u8) Value {
        return self.getVar(name);
    }

    fn itoa(buf: *[16]u8, value: i32) []const u8 {
        var n = value;
        var neg = false;
        if (n < 0) {
            neg = true;
            n = -n;
        }
        var i: usize = buf.len;
        if (n == 0) {
            i -= 1;
            buf[i] = '0';
        }
        while (n > 0) {
            i -= 1;
            buf[i] = @as(u8, @intCast(@mod(n, 10))) + '0';
            n = @divTrunc(n, 10);
        }
        if (neg) {
            i -= 1;
            buf[i] = '-';
        }
        return buf[i..];
    }

    fn formatValue(self: *Interp, v: Value) []const u8 {
        return switch (v) {
            .str => |s| s,
            .boolean => |b| if (b) "true" else "false",
            .int => |n| itoa(&self.fmt_buf, n),
            .none => "",
        };
    }

    fn callHost(self: *Interp, name: []const u8, args: []const Value) Value {
        if (strEq(name, "rect")) {
            if (args.len >= 5) self.ops.drawRect(self.ops_ctx, args[0].asInt(), args[1].asInt(), args[2].asInt(), args[3].asInt(), args[4].asInt());
            return .none;
        }
        if (strEq(name, "text")) {
            if (args.len >= 5) self.ops.drawText(self.ops_ctx, args[0].asInt(), args[1].asInt(), self.formatValue(args[2]), args[3].asInt(), args[4].asInt());
            return .none;
        }
        if (strEq(name, "border")) {
            if (args.len >= 5) self.ops.drawBorder(self.ops_ctx, args[0].asInt(), args[1].asInt(), args[2].asInt(), args[3].asInt(), args[4].truthy());
            return .none;
        }
        if (strEq(name, "mouse_x")) return .{ .int = self.hctx.mouse_x };
        if (strEq(name, "mouse_y")) return .{ .int = self.hctx.mouse_y };
        if (strEq(name, "mouse_down")) return .{ .boolean = self.hctx.mouse_down };
        if (strEq(name, "width")) return .{ .int = @intCast(self.hctx.w) };
        if (strEq(name, "height")) return .{ .int = @intCast(self.hctx.h) };
        if (strEq(name, "key_code")) return .{ .int = self.hctx.key_ascii };
        if (strEq(name, "str")) return .{ .str = self.formatValue(if (args.len >= 1) args[0] else .none) };
        return .none;
    }

    fn node(self: *Interp, idx: u16) Node {
        return self.prog.nodes[idx];
    }

    pub fn eval(self: *Interp, idx: u16) Value {
        if (idx == NONE) return .none;
        const n = self.node(idx);
        return switch (n.tag) {
            .int_lit => .{ .int = n.int_val },
            .str_lit => .{ .str = n.str_val },
            .bool_lit => .{ .boolean = n.bool_val },
            .ident => self.getVar(n.str_val),
            .neg => .{ .int = -self.eval(n.a).asInt() },
            .add => .{ .int = self.eval(n.a).asInt() + self.eval(n.b).asInt() },
            .sub => .{ .int = self.eval(n.a).asInt() - self.eval(n.b).asInt() },
            .mul => .{ .int = self.eval(n.a).asInt() * self.eval(n.b).asInt() },
            .div => blk: {
                const denom = self.eval(n.b).asInt();
                break :blk Value{ .int = if (denom == 0) 0 else @divTrunc(self.eval(n.a).asInt(), denom) };
            },
            .eqq => .{ .boolean = valuesEqual(self.eval(n.a), self.eval(n.b)) },
            .neq => .{ .boolean = !valuesEqual(self.eval(n.a), self.eval(n.b)) },
            .lt => .{ .boolean = self.eval(n.a).asInt() < self.eval(n.b).asInt() },
            .le => .{ .boolean = self.eval(n.a).asInt() <= self.eval(n.b).asInt() },
            .gt => .{ .boolean = self.eval(n.a).asInt() > self.eval(n.b).asInt() },
            .ge => .{ .boolean = self.eval(n.a).asInt() >= self.eval(n.b).asInt() },
            .and_ => .{ .boolean = self.eval(n.a).truthy() and self.eval(n.b).truthy() },
            .or_ => .{ .boolean = self.eval(n.a).truthy() or self.eval(n.b).truthy() },
            .call => blk: {
                var args: [8]Value = undefined;
                var i: usize = 0;
                while (i < n.extra_count) : (i += 1) args[i] = self.eval(self.prog.extra[n.extra + i]);
                break :blk self.callHost(n.str_val, args[0..n.extra_count]);
            },
            else => .none, // statement-only tags never reach eval()
        };
    }

    pub fn execStmt(self: *Interp, idx: u16) void {
        if (idx == NONE) return;
        const n = self.node(idx);
        switch (n.tag) {
            .var_decl, .assign => self.setVar(n.str_val, self.eval(n.a)),
            .if_stmt => if (self.eval(n.a).truthy()) self.execStmt(n.b) else self.execStmt(n.c),
            .while_stmt => {
                while (self.eval(n.a).truthy()) {
                    self.loop_guard += 1;
                    // Safety valve: a runaway script must not be able to
                    // hang the OS. 50000 iterations is far more than any
                    // UI-scale script should ever need per event.
                    if (self.loop_guard > 50000) break;
                    self.execStmt(n.b);
                }
            },
            .block => {
                var i: usize = 0;
                while (i < n.extra_count) : (i += 1) self.execStmt(self.prog.extra[n.extra + i]);
            },
            else => _ = self.eval(idx), // bare expression statement, e.g. a call
        }
    }

    pub fn runDraw(self: *Interp, hctx: HostCtx) void {
        self.hctx = hctx;
        self.loop_guard = 0;
        self.execStmt(self.prog.on_draw);
    }

    pub fn runClick(self: *Interp, hctx: HostCtx) void {
        self.hctx = hctx;
        self.loop_guard = 0;
        self.execStmt(self.prog.on_click);
    }

    pub fn runKey(self: *Interp, hctx: HostCtx) void {
        self.hctx = hctx;
        self.loop_guard = 0;
        self.execStmt(self.prog.on_key);
    }
};
