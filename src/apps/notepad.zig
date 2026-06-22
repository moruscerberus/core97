// apps/notepad.zig - Simple Notepad/editor app.
// Owns the text buffer, undo/redo, clipboard, and keyboard-layout-aware
// key decoding. Knows nothing about window position - callers pass in
// the area rectangle to draw into / hit-test against.

const fb = @import("../gui/framebuffer.zig");
const vfs = @import("../fs/vfs.zig");
const keymap = @import("keymap.zig");

pub const KeyboardLayout = keymap.KeyboardLayout;
pub var keyboard_layout: KeyboardLayout = .sv; // F12 toggles Swedish/American
pub var editor_open: bool = true;

pub const WindowState = enum { normal, minimized, maximized, closed };
pub var window_state: WindowState = .closed;

const EDIT_BUF_MAX: usize = 4096;
const CLIP_BUF_MAX: usize = 1024;
var editor_buf: [EDIT_BUF_MAX]u8 = undefined;
var editor_len: usize = 0;
var cursor_pos: usize = 0;

var undo_buf: [EDIT_BUF_MAX]u8 = undefined;
var undo_len: usize = 0;
var undo_cursor: usize = 0;
var undo_valid: bool = false;

var redo_buf: [EDIT_BUF_MAX]u8 = undefined;
var redo_len: usize = 0;
var redo_cursor: usize = 0;
var redo_valid: bool = false;

var caret_tick: u32 = 0;
var caret_visible: bool = true;
var select_anchor: usize = 0;
var mouse_selecting: bool = false;
var clipboard: [CLIP_BUF_MAX]u8 = undefined;
var clipboard_len: usize = 0;

const DEFAULT_NOTES_PATH = "/users/default/notes.txt";
const SAVE_AS_PATH = "/users/default/saved-as.txt";
var current_file: vfs.NodeHandle = vfs.INVALID_HANDLE;

/// Seeds the editor with the startup banner text, read from /readme.txt
/// in the VFS (see kernel.zig, which creates it before calling this).
/// Falls back to a literal if the VFS lookup fails for any reason, so a
/// missing/broken filesystem degrades gracefully instead of leaving the
/// editor empty.
pub fn init() void {
    editor_len = 0;
    cursor_pos = 0;
    select_anchor = 0;

    const text: []const u8 = if (vfs.resolvePath(DEFAULT_NOTES_PATH)) |h| blk: {
        current_file = h;
        break :blk vfs.readFile(h);
    }
    else if (vfs.resolvePath("/system/readme.txt")) |h|
        vfs.readFile(h)
    else
        "CORE97 EDITOR READY - TYPE HERE\n";

    for (text) |c| {
        if (editor_len < EDIT_BUF_MAX) {
            editor_buf[editor_len] = c;
            editor_len += 1;
        }
    }
    cursor_pos = editor_len;
    select_anchor = cursor_pos;
}



fn replaceBuffer(text: []const u8) void {
    editor_len = 0;
    cursor_pos = 0;
    select_anchor = 0;
    for (text) |c| {
        if (editor_len < EDIT_BUF_MAX) {
            editor_buf[editor_len] = c;
            editor_len += 1;
        }
    }
    cursor_pos = editor_len;
    select_anchor = cursor_pos;
    undo_valid = false;
    redo_valid = false;
}

pub fn saveCurrentFile() bool {
    if (current_file != vfs.INVALID_HANDLE and vfs.kindOf(current_file) == .file) {
        return vfs.writeFile(current_file, editor_buf[0..editor_len]);
    }
    return saveDefaultFile();
}

pub fn saveDefaultFile() bool {
    if (vfs.resolvePath(DEFAULT_NOTES_PATH)) |h| {
        current_file = h;
        return vfs.writeFile(h, editor_buf[0..editor_len]);
    }
    return false;
}

pub fn saveAsCopy() bool {
    if (vfs.resolvePath("/users/default")) |dir| {
        const h = vfs.ensureFile(dir, "saved-as.txt") orelse return false;
        current_file = h;
        return vfs.writeFile(h, editor_buf[0..editor_len]);
    }
    return false;
}

pub fn loadDefaultFile() bool {
    if (vfs.resolvePath(DEFAULT_NOTES_PATH)) |h| {
        current_file = h;
        replaceBuffer(vfs.readFile(h));
        return true;
    }
    return false;
}

pub fn loadFromVfsFile(handle: vfs.NodeHandle) bool {
    if (vfs.kindOf(handle) != .file) return false;
    current_file = handle;
    replaceBuffer(vfs.readFile(handle));
    return true;
}

pub fn currentFileName() []const u8 {
    if (current_file != vfs.INVALID_HANDLE) return vfs.nameOf(current_file);
    return "Untitled";
}

fn selectionStart() usize {
    return if (cursor_pos < select_anchor) cursor_pos else select_anchor;
}

fn selectionEnd() usize {
    return if (cursor_pos > select_anchor) cursor_pos else select_anchor;
}

fn hasSelection() bool {
    return cursor_pos != select_anchor;
}

fn snapshotUndo() void {
    var i: usize = 0;
    while (i < editor_len) : (i += 1) {
        undo_buf[i] = editor_buf[i];
    }
    undo_len = editor_len;
    undo_cursor = cursor_pos;
    undo_valid = true;
    redo_valid = false;
}

fn snapshotRedo() void {
    var i: usize = 0;
    while (i < editor_len) : (i += 1) {
        redo_buf[i] = editor_buf[i];
    }
    redo_len = editor_len;
    redo_cursor = cursor_pos;
    redo_valid = true;
}

fn restoreFrom(buf: *[EDIT_BUF_MAX]u8, len: usize, cursor: usize) void {
    const safe_len = if (len > EDIT_BUF_MAX) EDIT_BUF_MAX else len;
    var i: usize = 0;
    while (i < safe_len) : (i += 1) {
        editor_buf[i] = buf[i];
    }
    editor_len = safe_len;

    cursor_pos = if (cursor > editor_len) editor_len else cursor;
    select_anchor = cursor_pos;
}

fn undoEdit() bool {
    if (!undo_valid) return false;
    snapshotRedo();
    restoreFrom(&undo_buf, undo_len, undo_cursor);
    undo_valid = false;
    return true;
}

fn redoEdit() bool {
    if (!redo_valid) return false;

    var i: usize = 0;
    while (i < editor_len) : (i += 1) {
        undo_buf[i] = editor_buf[i];
    }
    undo_len = editor_len;
    undo_cursor = cursor_pos;
    undo_valid = true;

    restoreFrom(&redo_buf, redo_len, redo_cursor);
    redo_valid = false;
    return true;
}

fn deleteRange(start_idx: usize, end_idx: usize) void {
    if (end_idx <= start_idx or start_idx >= editor_len) return;
    snapshotUndo();
    const e = if (end_idx > editor_len) editor_len else end_idx;
    var i = e;
    while (i < editor_len) : (i += 1) {
        editor_buf[start_idx + (i - e)] = editor_buf[i];
    }
    editor_len -= (e - start_idx);
    cursor_pos = start_idx;
    select_anchor = cursor_pos;
}

fn deleteSelection() bool {
    if (!hasSelection()) return false;
    deleteRange(selectionStart(), selectionEnd());
    return true;
}

fn insertEditorChar(c: u8) void {
    _ = deleteSelection();
    if (editor_len >= EDIT_BUF_MAX) return;
    var i = editor_len;
    while (i > cursor_pos) {
        i -= 1;
        if (i + 1 < EDIT_BUF_MAX) {
            editor_buf[i + 1] = editor_buf[i];
        }
    }
    editor_buf[cursor_pos] = c;
    editor_len += 1;
    cursor_pos += 1;
    select_anchor = cursor_pos;
}

fn backspaceEditor() void {
    if (deleteSelection()) return;
    if (cursor_pos == 0) return;
    deleteRange(cursor_pos - 1, cursor_pos);
}

fn deleteEditorForward() void {
    if (deleteSelection()) return;
    if (cursor_pos < editor_len) deleteRange(cursor_pos, cursor_pos + 1);
}

fn copySelection() void {
    clipboard_len = 0;
    if (!hasSelection()) return;
    var i = selectionStart();
    const e = selectionEnd();
    while (i < e and clipboard_len < CLIP_BUF_MAX) : (i += 1) {
        clipboard[clipboard_len] = editor_buf[i];
        clipboard_len += 1;
    }
}

fn cutSelection() void {
    copySelection();
    _ = deleteSelection();
}

fn pasteClipboard() void {
    _ = deleteSelection();
    var i: usize = 0;
    while (i < clipboard_len) : (i += 1) {
        insertEditorChar(clipboard[i]);
    }
}

fn selectAll() void {
    select_anchor = 0;
    cursor_pos = editor_len;
}

fn moveCursorTo(pos: usize, selecting: bool) void {
    const p = if (pos > editor_len) editor_len else pos;
    if (!selecting) select_anchor = p;
    cursor_pos = p;
}

fn moveCursorLeft(selecting: bool) void {
    if (!selecting and hasSelection()) {
        moveCursorTo(selectionStart(), false);
    } else if (cursor_pos > 0) {
        moveCursorTo(cursor_pos - 1, selecting);
    }
}

fn moveCursorRight(selecting: bool) void {
    if (!selecting and hasSelection()) {
        moveCursorTo(selectionEnd(), false);
    } else if (cursor_pos < editor_len) {
        moveCursorTo(cursor_pos + 1, selecting);
    }
}

fn lineColForIndex(idx: usize, area_w: u32, out_line: *u32, out_col: *u32) void {
    const chars_per_line: u32 = if (area_w < 12) 1 else area_w / 6;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < idx and i < editor_len) : (i += 1) {
        const c = editor_buf[i];
        if (c == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= chars_per_line) {
                line += 1;
                col = 0;
            }
        }
    }
    out_line.* = line;
    out_col.* = col;
}

/// Converts a (line, col) position - in the wrapped-text sense used by
/// drawEditorText - back into a buffer index. Exposed so gui/desktop.zig
/// can do mouse hit-testing without reaching into editor internals.
pub fn indexForLineCol(target_line: u32, target_col: u32, area_w: u32) usize {
    const chars_per_line: u32 = if (area_w < 12) 1 else area_w / 6;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < editor_len) : (i += 1) {
        if (line == target_line and col >= target_col) return i;
        const c = editor_buf[i];
        if (c == '\n') {
            if (line == target_line) return i;
            line += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= chars_per_line) {
                line += 1;
                col = 0;
            }
        }
    }
    return editor_len;
}

fn moveCursorVertical(up: bool, selecting: bool, area_w: u32) void {
    var line: u32 = 0;
    var col: u32 = 0;
    lineColForIndex(cursor_pos, area_w, &line, &col);
    if (up) {
        if (line > 0) line -= 1;
    } else {
        line += 1;
    }
    moveCursorTo(indexForLineCol(line, col, area_w), selecting);
}

/// Begins (or replaces) a mouse-driven selection at the given buffer index.
/// Called by gui/desktop.zig once it has translated a click into an index
/// via indexForLineCol.
pub fn beginMouseSelection(idx: usize) void {
    cursor_pos = if (idx > editor_len) editor_len else idx;
    select_anchor = cursor_pos;
    mouse_selecting = true;
}

pub fn dragMouseSelection(idx: usize) void {
    cursor_pos = if (idx > editor_len) editor_len else idx;
}

pub fn endMouseSelection() void {
    mouse_selecting = false;
}

pub fn isMouseSelecting() bool {
    return mouse_selecting;
}

pub fn drawEditorText(x: u32, y: u32, w: u32, h: u32) void {
    const char_w: u32 = 6;
    const line_h: u32 = 9;
    var cx: u32 = x;
    var cy: u32 = y;
    var i: usize = 0;
    const sel_s = selectionStart();
    const sel_e = selectionEnd();
    var caret_x = x;
    var caret_y = y;

    while (i <= editor_len) : (i += 1) {
        if (i == cursor_pos and caret_visible) {
            caret_x = cx;
            caret_y = cy;
        }
        if (i == editor_len) break;

        const c = editor_buf[i];
        if (c == '\n' or cx + char_w >= x + w) {
            cx = x;
            cy += line_h;
            if (c == '\n') continue;
        }
        if (cy + 8 >= y + h) break;

        const selected = i >= sel_s and i < sel_e;
        const fgc = if (selected) fb.CORE97_WHITE else fb.CORE97_BLACK;
        const bgc = if (selected) fb.CORE97_BLUE else fb.CORE97_WHITE;
        fb.drawChar(cx, cy, c, fgc, bgc);
        cx += char_w;
    }

    if (caret_y + 8 < y + h) fb.fillRect(caret_x, caret_y, 1, 8, fb.CORE97_BLACK);
}

fn appendEditorChar(ascii: u8) void {
    if (ascii == 8) {
        backspaceEditor();
        return;
    }
    if (ascii == 13) {
        insertEditorChar('\n');
        return;
    }
    if ((ascii >= 32 and ascii <= 126) or ascii >= 0x80) {
        insertEditorChar(ascii);
    }
}

/// PS/2 ASCII fallback path. Returns void; always "handled".
pub fn handleAsciiKey(ascii: u8) void {
    if (ascii == 0) return;

    if (ascii == 8) {
        backspaceEditor();
        return;
    }

    if (ascii == 13) {
        appendEditorChar(13);
        return;
    }

    appendEditorChar(ascii);
}

/// Handles one USB-HID-style key code (also used for translated PS/2
/// scancodes). `area_w` is needed for Up/Down line-wrap math. Returns
/// true if the editor state changed and a redraw is needed.
pub fn handleUsbKey(code: u8, modifiers: u8, area_w: u32) bool {
    const ctrl = (modifiers & 0x11) != 0;
    var changed = false;

    // F12 toggles keyboard layout between Swedish and American/US.
    if (code == 0x45) {
        keyboard_layout = if (keyboard_layout == .sv) .us else .sv;
        return true;
    }

    if (ctrl) {
        switch (code) {
            0x04 => {
                selectAll();
                changed = true;
            }, // Ctrl+A
            0x06 => {
                copySelection();
            }, // Ctrl+C
            0x16 => {
                changed = saveCurrentFile();
            }, // Ctrl+S
            0x19 => {
                pasteClipboard();
                changed = true;
            }, // Ctrl+V
            0x1D => {
                changed = undoEdit();
            }, // Ctrl+Z
            0x1C => {
                changed = redoEdit();
            }, // Ctrl+Y
            0x1B => {
                cutSelection();
                changed = true;
            }, // Ctrl+X
            else => {},
        }
        return changed;
    }

    switch (code) {
        0x4F => {
            moveCursorRight((modifiers & 0x22) != 0);
            changed = true;
        }, // Right
        0x50 => {
            moveCursorLeft((modifiers & 0x22) != 0);
            changed = true;
        }, // Left
        0x51 => {
            moveCursorVertical(false, (modifiers & 0x22) != 0, area_w);
            changed = true;
        }, // Down
        0x52 => {
            moveCursorVertical(true, (modifiers & 0x22) != 0, area_w);
            changed = true;
        }, // Up
        0x4A => {
            moveCursorTo(0, (modifiers & 0x22) != 0);
            changed = true;
        }, // Home, simple document home
        0x4D => {
            moveCursorTo(editor_len, (modifiers & 0x22) != 0);
            changed = true;
        }, // End, simple document end
        0x4C => {
            deleteEditorForward();
            changed = true;
        }, // Delete
        0x2A => {
            if (cursor_pos > 0) deleteRange(cursor_pos - 1, cursor_pos);
            changed = true;
        }, // Backspace
        else => {
            if (code == 0x28) { // Enter
                appendEditorChar(13);
                changed = true;
            } else if (code == 0x2B) { // Tab
                appendEditorChar(' ');
                appendEditorChar(' ');
                appendEditorChar(' ');
                appendEditorChar(' ');
                changed = true;
            } else {
                const ascii = keymap.keycodeToAscii(code, modifiers, keyboard_layout);
                if (ascii != 0) {
                    appendEditorChar(ascii);
                    changed = true;
                }
            }
        },
    }
    return changed;
}


// Native Core97 Open/Save dialog state. It is deliberately small but real:
// a current folder, filename edit box, explorer-style file list, and OK/Cancel.
const DialogMode = enum { none, open, save_as };
var dialog_mode: DialogMode = .none;
var dialog_dir: vfs.NodeHandle = vfs.INVALID_HANDLE;
var dialog_input: [64]u8 = undefined;
var dialog_input_len: usize = 0;

fn dialogStart(mode: DialogMode) void {
    dialog_mode = mode;
    dialog_dir = if (current_file != vfs.INVALID_HANDLE and vfs.parentOf(current_file) != vfs.INVALID_HANDLE) vfs.parentOf(current_file) else (vfs.resolvePath("/users/default") orelse vfs.root);
    dialog_input_len = 0;
    const name = if (mode == .save_as) currentFileName() else "";
    var i: usize = 0;
    while (i < name.len and i < dialog_input.len) : (i += 1) dialog_input[i] = name[i];
    dialog_input_len = i;
}

fn dialogClose() void { dialog_mode = .none; }

fn dialogCurrentName() []const u8 { return dialog_input[0..dialog_input_len]; }

fn dialogAccept() bool {
    if (dialog_mode == .none) return false;
    const name = dialogCurrentName();
    if (name.len == 0) return false;
    const existing = vfs.findChild(dialog_dir, name);
    if (dialog_mode == .open) {
        const h = existing orelse return false;
        if (vfs.kindOf(h) == .directory) { dialog_dir = h; dialog_input_len = 0; return true; }
        const ok = loadFromVfsFile(h);
        if (ok) dialogClose();
        return ok;
    }
    const h = existing orelse (vfs.ensureFile(dialog_dir, name) orelse return false);
    if (vfs.kindOf(h) != .file) return false;
    current_file = h;
    const ok = vfs.writeFile(h, editor_buf[0..editor_len]);
    if (ok) dialogClose();
    return ok;
}

fn drawDialogIcon(x: u32, y: u32, folder: bool) void {
    if (folder) {
        fb.fillRect(x, y + 5, 15, 10, 0xFFFF80);
        fb.fillRect(x + 2, y + 3, 8, 3, 0xFFFF80);
        fb.draw3DBorder(x, y + 5, 15, 10, true);
    } else {
        fb.fillRect(x + 2, y + 1, 12, 14, fb.CORE97_WHITE);
        fb.draw3DBorder(x + 2, y + 1, 12, 14, true);
        fb.fillRect(x + 5, y + 6, 7, 1, fb.CORE97_DARK_GREY);
        fb.fillRect(x + 5, y + 9, 7, 1, fb.CORE97_DARK_GREY);
    }
}

fn dialogX(parent_x: u32, parent_w: u32) u32 { return parent_x + if (parent_w > 360) (parent_w - 360) / 2 else 4; }
fn dialogY(parent_y: u32, parent_h: u32) u32 { return parent_y + if (parent_h > 245) (parent_h - 245) / 2 else 4; }

fn drawNativeFileDialog(x: u32, y: u32, w: u32, h: u32) void {
    if (dialog_mode == .none) return;
    const dx = dialogX(x, w);
    const dy = dialogY(y, h);
    const dw: u32 = 360;
    const dh: u32 = 245;
    fb.fillRect(dx + 4, dy + 4, dw, dh, fb.CORE97_DARK_GREY);
    fb.fillRect(dx, dy, dw, dh, fb.CORE97_GREY);
    fb.draw3DBorder(dx, dy, dw, dh, true);
    fb.fillRect(dx + 2, dy + 2, dw - 4, 18, fb.CORE97_BLUE);
    fb.drawString(dx + 8, dy + 7, if (dialog_mode == .open) "Open" else "Save As", fb.CORE97_WHITE, fb.CORE97_BLUE);

    fb.drawString(dx + 10, dy + 30, "Look in:", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.fillRect(dx + 62, dy + 26, 210, 18, fb.CORE97_WHITE);
    fb.draw3DBorder(dx + 62, dy + 26, 210, 18, false);
    fb.drawString(dx + 68, dy + 32, vfs.nameOf(dialog_dir), fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.fillRect(dx + 278, dy + 26, 28, 18, fb.CORE97_GREY); fb.draw3DBorder(dx + 278, dy + 26, 28, 18, true); fb.drawString(dx + 287, dy + 32, "^", fb.CORE97_BLACK, fb.CORE97_GREY);

    const lx = dx + 10;
    const ly = dy + 52;
    const lw: u32 = 260;
    const lh: u32 = 122;
    fb.fillRect(lx, ly, lw, lh, fb.CORE97_WHITE);
    fb.draw3DBorder(lx, ly, lw, lh, false);
    var row: usize = 0;
    const cc = vfs.childCount(dialog_dir);
    while (row < cc) : (row += 1) {
        const child = vfs.childAt(dialog_dir, row);
        if (child == vfs.INVALID_HANDLE) continue;
        const ry = ly + 6 + @as(u32, @intCast(row)) * 18;
        if (ry + 18 >= ly + lh) break;
        const folder = vfs.kindOf(child) == .directory;
        drawDialogIcon(lx + 8, ry, folder);
        fb.drawString(lx + 30, ry + 5, vfs.nameOf(child), fb.CORE97_BLACK, fb.CORE97_WHITE);
    }

    fb.drawString(dx + 10, dy + 186, "File name:", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.fillRect(dx + 82, dy + 181, 188, 18, fb.CORE97_WHITE);
    fb.draw3DBorder(dx + 82, dy + 181, 188, 18, false);
    fb.drawString(dx + 88, dy + 187, dialogCurrentName(), fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(dx + 10, dy + 210, "Files of type: Text Documents (*.txt)", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.fillRect(dx + 284, dy + 58, 64, 22, fb.CORE97_GREY); fb.draw3DBorder(dx + 284, dy + 58, 64, 22, true); fb.drawString(dx + 304, dy + 65, "OK", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.fillRect(dx + 284, dy + 86, 64, 22, fb.CORE97_GREY); fb.draw3DBorder(dx + 284, dy + 86, 64, 22, true); fb.drawString(dx + 296, dy + 93, "Cancel", fb.CORE97_BLACK, fb.CORE97_GREY);
}

fn dialogHandleMouse(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) bool {
    if (dialog_mode == .none) return false;
    const dx = dialogX(x, w);
    const dy = dialogY(y, h);
    if (mx >= @as(i32,@intCast(dx + 284)) and mx < @as(i32,@intCast(dx + 348)) and my >= @as(i32,@intCast(dy + 58)) and my < @as(i32,@intCast(dy + 80))) { _ = dialogAccept(); return true; }
    if (mx >= @as(i32,@intCast(dx + 284)) and mx < @as(i32,@intCast(dx + 348)) and my >= @as(i32,@intCast(dy + 86)) and my < @as(i32,@intCast(dy + 108))) { dialogClose(); return true; }
    if (mx >= @as(i32,@intCast(dx + 278)) and mx < @as(i32,@intCast(dx + 306)) and my >= @as(i32,@intCast(dy + 26)) and my < @as(i32,@intCast(dy + 44))) { const p = vfs.parentOf(dialog_dir); if (p != vfs.INVALID_HANDLE) dialog_dir = p; return true; }
    const lx = dx + 10; const ly = dy + 52;
    if (mx >= @as(i32,@intCast(lx)) and mx < @as(i32,@intCast(lx + 260)) and my >= @as(i32,@intCast(ly)) and my < @as(i32,@intCast(ly + 122))) {
        const row: usize = @intCast(@divTrunc(my - @as(i32,@intCast(ly + 6)), 18));
        if (row < vfs.childCount(dialog_dir)) {
            const child = vfs.childAt(dialog_dir, row);
            if (child != vfs.INVALID_HANDLE) {
                if (vfs.kindOf(child) == .directory) { dialog_dir = child; dialog_input_len = 0; }
                else { const nm = vfs.nameOf(child); dialog_input_len = 0; var i: usize = 0; while (i < nm.len and i < dialog_input.len) : (i += 1) dialog_input[i] = nm[i]; dialog_input_len = i; }
            }
        }
        return true;
    }
    return true;
}

fn dialogKey(ascii: u8) bool {
    if (dialog_mode == .none) return false;
    if (ascii == 13) { _ = dialogAccept(); return true; }
    if (ascii == 27) { dialogClose(); return true; }
    if (ascii == 8) { if (dialog_input_len > 0) dialog_input_len -= 1; return true; }
    if (ascii >= 32 and ascii <= 126 and dialog_input_len < dialog_input.len) { dialog_input[dialog_input_len] = ascii; dialog_input_len += 1; return true; }
    return true;
}

// ===========================================================================
// AppVTable adapter
// ===========================================================================
// Everything above this point is unchanged from before the windowing
// refactor - Notepad still owns its text buffer/undo/clipboard exactly
// as it did. What's new is this section, which is what lets desktop.zig
// treat Notepad as just another window.App instead of special-casing it.
// The File menu (previously drawn/hit-tested by gui/desktop.zig using its
// own win_x/win_y globals) moves in here too, since "where's my File
// menu" is squarely Notepad's own business, not the window manager's.

const window = @import("../gui/window.zig");
const ui = @import("../gui/ui.zig");

pub var file_menu_open: bool = false;

/// Layout constants, relative to the content-area rect this app is
/// given (i.e. already below the generic titlebar): an 18px File button
/// directly under the titlebar, then the editor pane below that. These
/// numbers reproduce the exact pixel layout the old hardcoded desktop.zig
/// version used.
const FILE_BTN_W: u32 = 36;
const FILE_BTN_H: u32 = 18;
const FILE_MENU_W: u32 = 96;
const FILE_MENU_ROW_H: u32 = 20;
const MENU_BAR_H: u32 = 26; // matches editorAreaOf's y+26 offset below
const FILE_MENU_ITEMS = [_][]const u8{ "Open", "Save", "Save As", "Quit" };

fn editorAreaOf(x: u32, y: u32, w: u32, h: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
    return .{
        .x = x + 8,
        .y = y + 26,
        .w = if (w > 16) w - 16 else 1,
        .h = if (h > 38) h - 38 else 1,
    };
}

fn drawFileMenuBar(x: u32, y: u32, w: u32) void {
    // Explicit full-width menu-bar background, rather than relying on
    // whatever's already behind it - keeps this row visually solid
    // regardless of what else has drawn to the screen.
    fb.fillRect(x, y, w, MENU_BAR_H, fb.CORE97_GREY);

    const file_hovered = ui.hit(x + 6, y + 2, FILE_BTN_W, FILE_BTN_H);
    const file_bg = if (file_hovered and !file_menu_open) 0xD8E8FF else fb.CORE97_GREY;
    if (file_hovered and !file_menu_open) fb.fillRect(x + 6, y + 2, FILE_BTN_W, FILE_BTN_H, file_bg);
    if (file_menu_open) {
        // Sunken look while its dropdown is open, same affordance
        // Explorer's toolbar buttons use - makes it clear which menu
        // is currently active.
        fb.draw3DBorder(x + 6, y + 2, FILE_BTN_W, FILE_BTN_H, false);
    }
    fb.drawString(x + 14, y + 6, "File", fb.CORE97_BLACK, file_bg);

    // Divider separating the menu bar from the editor pane below it.
    fb.fillRect(x, y + MENU_BAR_H - 2, w, 1, fb.CORE97_DARK_GREY);
    fb.fillRect(x, y + MENU_BAR_H - 1, w, 1, fb.CORE97_WHITE);

    if (!file_menu_open) return;

    const mx = x + 8;
    const my = y + 2 + FILE_BTN_H;
    const menu_h = FILE_MENU_ROW_H * FILE_MENU_ITEMS.len + 4;
    fb.fillRect(mx, my, FILE_MENU_W, menu_h, fb.CORE97_GREY);
    fb.draw3DBorder(mx, my, FILE_MENU_W, menu_h, true);
    for (FILE_MENU_ITEMS, 0..) |label, i| {
        const row_y = my + 7 + @as(u32, @intCast(i)) * FILE_MENU_ROW_H;
        const hit_y = my + 2 + @as(u32, @intCast(i)) * FILE_MENU_ROW_H;
        const hovered = ui.hit(mx + 2, hit_y, FILE_MENU_W - 4, FILE_MENU_ROW_H);
        const bg = if (hovered) fb.CORE97_BLUE else fb.CORE97_GREY;
        const fg = if (hovered) fb.CORE97_WHITE else fb.CORE97_BLACK;
        if (hovered) fb.fillRect(mx + 2, hit_y, FILE_MENU_W - 4, FILE_MENU_ROW_H, bg);
        fb.drawString(mx + 8, row_y, label, fg, bg);
        if (i == 2) {
            // Divider before "Quit", matching the original menu.
            fb.fillRect(mx + 4, row_y + 15, FILE_MENU_W - 8, 1, fb.CORE97_DARK_GREY);
            fb.fillRect(mx + 4, row_y + 16, FILE_MENU_W - 8, 1, fb.CORE97_WHITE);
        }
    }
}

fn indexFromAreaMouse(mx: i32, my: i32, ex: u32, ey: u32, ew: u32) usize {
    const ax: i32 = @intCast(ex + 4);
    const ay: i32 = @intCast(ey + 4);
    if (mx < ax or my < ay) return 0;
    const col: u32 = @intCast(@divTrunc(mx - ax, 6));
    const line: u32 = @intCast(@divTrunc(my - ay, 9));
    return indexForLineCol(line, col, if (ew > 8) ew - 8 else 1);
}

pub const Notepad = struct {
    pub fn title(_: *Notepad) []const u8 {
        return "NOTEPAD";
    }

    pub fn titleDetail(_: *Notepad) []const u8 {
        return currentFileName();
    }

    pub fn draw(_: *Notepad, x: u32, y: u32, w: u32, h: u32) void {
        if (editor_open) {
            const area = editorAreaOf(x, y, w, h);
            window.drawEditorPane(area.x, area.y, area.w, area.h);
            drawEditorText(area.x + 4, area.y + 4, if (area.w > 8) area.w - 8 else 1, if (area.h > 8) area.h - 8 else 1);
        }
        // Drawn last so the dropdown (when open) overlays the editor
        // pane instead of being immediately painted over by it.
        drawFileMenuBar(x, y, w);
        drawNativeFileDialog(x, y, w, h);
    }

    pub fn onMouseDown(_: *Notepad, mx: i32, my: i32, button: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        if (button != .left) return .none;
        if (dialogHandleMouse(mx, my, x, y, w, h)) return .none;

        if (file_menu_open) {
            const mbx: i32 = @intCast(x + 8);
            const mby: i32 = @intCast(y + 2 + FILE_BTN_H);
            const menu_h: i32 = @intCast(FILE_MENU_ROW_H * FILE_MENU_ITEMS.len + 4);
            if (mx >= mbx and mx < mbx + @as(i32, @intCast(FILE_MENU_W)) and my >= mby and my < mby + menu_h) {
                const row = @divTrunc(my - mby, @as(i32, @intCast(FILE_MENU_ROW_H)));
                file_menu_open = false;
                return switch (row) {
                    0 => blk: { dialogStart(.open); break :blk .none; },
                    1 => blk: {
                        _ = saveCurrentFile();
                        break :blk .none;
                    },
                    2 => blk: { dialogStart(.save_as); break :blk .none; },
                    3 => .close, // "Quit"
                    else => .none,
                };
            }
            file_menu_open = false; // clicked elsewhere - close the menu and fall through
        }

        const btn_x: i32 = @intCast(x + 8);
        const btn_y: i32 = @intCast(y + 2);
        if (mx >= btn_x and mx < btn_x + @as(i32, @intCast(FILE_BTN_W)) and my >= btn_y and my < btn_y + @as(i32, @intCast(FILE_BTN_H))) {
            file_menu_open = !file_menu_open;
            return .none;
        }

        const area = editorAreaOf(x, y, w, h);
        const ax: i32 = @intCast(area.x);
        const ay: i32 = @intCast(area.y);
        if (mx >= ax and my >= ay and mx < ax + @as(i32, @intCast(area.w)) and my < ay + @as(i32, @intCast(area.h))) {
            beginMouseSelection(indexFromAreaMouse(mx, my, area.x, area.y, area.w));
        }
        return .none;
    }

    pub fn onMouseDrag(_: *Notepad, mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) void {
        if (!mouse_selecting) return;
        const area = editorAreaOf(x, y, w, h);
        dragMouseSelection(indexFromAreaMouse(mx, my, area.x, area.y, area.w));
    }

    pub fn onMouseUp(_: *Notepad) void {
        endMouseSelection();
    }

    pub fn onKeyAscii(_: *Notepad, ascii: u8) void {
        if (dialogKey(ascii)) return;
        handleAsciiKey(ascii);
    }

    pub fn onKeyUsb(_: *Notepad, code: u8, modifiers: u8, area_w: u32) bool {
        if (dialog_mode != .none) {
            const ascii = keymap.keycodeToAscii(code, modifiers, keyboard_layout);
            if (code == 0x28) {
                _ = dialogKey(13);
            } else if (code == 0x2A) {
                _ = dialogKey(8);
            } else if (ascii != 0) {
                _ = dialogKey(ascii);
            }
            return true;
        }
        // area_w arrives as the full content width; subtract the same
        // editor-pane insets drawing uses so Up/Down line-wrap math
        // matches what's actually on screen.
        const usable = if (area_w > 24) area_w - 24 else 1;
        return handleUsbKey(code, modifiers, usable);
    }

    pub fn hasModalCapture(_: *Notepad) bool {
        return file_menu_open or dialog_mode != .none;
    }
};

var instance: Notepad = .{};

pub fn asApp() window.App {
    return window.appFrom(Notepad, &instance);
}
