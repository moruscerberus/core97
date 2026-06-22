// fs/vfs.zig - minimal in-memory VFS node tree.
//
// Phase 2 of docs/roadmap.md asks for a "basic VFS node tree" - this is
// it. No real storage backing yet (that's Phase 8: block device API +
// FAT32) and no dynamic allocation yet (Phase 4: kernel heap) - nodes
// come from a fixed-size static pool, the same style already used for
// apps/notepad.zig's text buffer. Phase 5 builds the RAM filesystem and
// initramfs on top of this; for now it's just directories, files, and
// simple absolute-path lookups.

pub const NodeType = enum { directory, file };

const MAX_NODES: usize = 64;
const MAX_NAME_LEN: usize = 32;
const MAX_FILE_DATA: usize = 2048;
const MAX_CHILDREN: usize = 16;

pub const NodeHandle = u16;
pub const INVALID_HANDLE: NodeHandle = 0xFFFF;
const INVALID: NodeHandle = INVALID_HANDLE;

const Node = struct {
    in_use: bool = false,
    kind: NodeType = .file,
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
    parent: NodeHandle = INVALID,
    children: [MAX_CHILDREN]NodeHandle = [_]NodeHandle{INVALID} ** MAX_CHILDREN,
    child_count: u8 = 0,
    data: [MAX_FILE_DATA]u8 = undefined,
    data_len: usize = 0,
};

var nodes: [MAX_NODES]Node = undefined;
pub var root: NodeHandle = INVALID;
var initialized: bool = false;

fn allocNode() ?NodeHandle {
    var i: usize = 0;
    while (i < MAX_NODES) : (i += 1) {
        if (!nodes[i].in_use) {
            nodes[i] = Node{};
            nodes[i].in_use = true;
            return @intCast(i);
        }
    }
    return null;
}

fn setName(handle: NodeHandle, name: []const u8) void {
    const n = &nodes[handle];
    const len = if (name.len > MAX_NAME_LEN) MAX_NAME_LEN else name.len;
    var i: usize = 0;
    while (i < len) : (i += 1) n.name[i] = name[i];
    n.name_len = @intCast(len);
}

fn eqlName(handle: NodeHandle, name: []const u8) bool {
    const n = &nodes[handle];
    if (n.name_len != name.len) return false;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (n.name[i] != name[i]) return false;
    }
    return true;
}

fn validHandle(handle: NodeHandle) bool {
    return handle != INVALID_HANDLE and handle < MAX_NODES and nodes[handle].in_use;
}

pub fn nameOf(handle: NodeHandle) []const u8 {
    if (!validHandle(handle)) return "";
    return nodes[handle].name[0..nodes[handle].name_len];
}

pub fn kindOf(handle: NodeHandle) NodeType {
    if (!validHandle(handle)) return .file;
    return nodes[handle].kind;
}

pub fn parentOf(handle: NodeHandle) NodeHandle {
    return nodes[handle].parent;
}

pub fn childCount(handle: NodeHandle) usize {
    if (!validHandle(handle)) return 0;
    return nodes[handle].child_count;
}

pub fn childAt(handle: NodeHandle, index: usize) NodeHandle {
    if (!validHandle(handle)) return INVALID_HANDLE;
    if (index >= childCount(handle)) return INVALID_HANDLE;
    return nodes[handle].children[index];
}

/// Creates the root "/" directory. Must be called once before anything
/// else in this module. Idempotent - safe to call more than once.
pub fn init() void {
    if (initialized) return;
    const h = allocNode() orelse unreachable; // pool is empty at boot, can't fail
    nodes[h].kind = .directory;
    setName(h, "/");
    root = h;
    initialized = true;
}

/// Creates a child node of `parent`. Returns null if the pool is full,
/// `parent` already has MAX_CHILDREN entries, or `parent` isn't a
/// directory.
pub fn createNode(parent: NodeHandle, name: []const u8, kind: NodeType) ?NodeHandle {
    if (nodes[parent].kind != .directory) return null;
    if (nodes[parent].child_count >= MAX_CHILDREN) return null;
    const h = allocNode() orelse return null;
    nodes[h].kind = kind;
    nodes[h].parent = parent;
    setName(h, name);
    nodes[parent].children[nodes[parent].child_count] = h;
    nodes[parent].child_count += 1;
    return h;
}

/// Looks up a direct child of `parent` by exact name match.
pub fn findChild(parent: NodeHandle, name: []const u8) ?NodeHandle {
    const n = &nodes[parent];
    var i: usize = 0;
    while (i < n.child_count) : (i += 1) {
        const child = n.children[i];
        if (eqlName(child, name)) return child;
    }
    return null;
}

/// Resolves a simple absolute "/a/b/c" path from the root. No "..", no
/// symlinks, no relative paths - intentionally the simplest thing that
/// could work for Phase 2. Returns null if any segment is missing.
pub fn resolvePath(path: []const u8) ?NodeHandle {
    if (!initialized) return null;
    if (path.len == 0 or path[0] != '/') return null;
    var current = root;
    var i: usize = 1;
    while (i < path.len) {
        var j = i;
        while (j < path.len and path[j] != '/') : (j += 1) {}
        if (j > i) {
            current = findChild(current, path[i..j]) orelse return null;
        }
        i = j + 1;
    }
    return current;
}

/// Overwrites a file node's contents, truncating to MAX_FILE_DATA bytes.
/// Returns false if `handle` isn't a file.
pub fn writeFile(handle: NodeHandle, data: []const u8) bool {
    if (nodes[handle].kind != .file) return false;
    const len = if (data.len > MAX_FILE_DATA) MAX_FILE_DATA else data.len;
    var i: usize = 0;
    while (i < len) : (i += 1) nodes[handle].data[i] = data[i];
    nodes[handle].data_len = len;
    return true;
}

/// Returns a file node's contents, or an empty slice if `handle` isn't a
/// file.
pub fn readFile(handle: NodeHandle) []const u8 {
    if (nodes[handle].kind != .file) return &[_]u8{};
    return nodes[handle].data[0..nodes[handle].data_len];
}


/// Creates a directory child if it does not already exist.
pub fn ensureDirectory(parent: NodeHandle, name: []const u8) ?NodeHandle {
    if (findChild(parent, name)) |existing| {
        if (kindOf(existing) == .directory) return existing;
        return null;
    }
    return createNode(parent, name, .directory);
}

/// Creates a file child if it does not already exist.
pub fn ensureFile(parent: NodeHandle, name: []const u8) ?NodeHandle {
    if (findChild(parent, name)) |existing| {
        if (kindOf(existing) == .file) return existing;
        return null;
    }
    return createNode(parent, name, .file);
}

/// Seed the initial RAM VFS tree.
pub fn seedCore97Files() void {
    if (!initialized) init();

    const users = ensureDirectory(root, "users") orelse return;
    const def = ensureDirectory(users, "default") orelse return;
    const system = ensureDirectory(root, "system") orelse return;
    const apps = ensureDirectory(root, "apps") orelse return;

    const notes = ensureFile(def, "notes.txt") orelse return;
    if (readFile(notes).len == 0) {
        _ = writeFile(notes, "Welcome to Core97 Notepad.\n\nPress Ctrl+S to save this document.\n");
    }

    const readme = ensureFile(system, "readme.txt") orelse return;
    if (readFile(readme).len == 0) {
        _ = writeFile(readme, "Core97 RAM VFS online.\nFiles live under /users/default for now.\n");
    }

    _ = ensureFile(apps, "notepad.app");
    _ = ensureFile(apps, "explorer.app");
    _ = ensureFile(apps, "devmgr.app");
    _ = ensureFile(apps, "cmd.app");
    _ = ensureFile(apps, "taskmgr.app");
    _ = ensureFile(def, "saved-as.txt");

    const counter_script = ensureFile(apps, "counter.ws") orelse return;
    if (readFile(counter_script).len == 0) {
        _ = writeFile(counter_script,
            \\var count = 0
            \\
            \\on draw {
            \\    rect(0, 0, width(), height(), 12632256)
            \\    border(0, 0, width(), height(), true)
            \\    text(10, 12, "Count:", 0, 12632256)
            \\    text(70, 12, str(count), 0, 12632256)
            \\    rect(10, 34, 64, 24, 12632256)
            \\    border(10, 34, 64, 24, true)
            \\    text(28, 42, "+1", 0, 12632256)
            \\    rect(82, 34, 64, 24, 12632256)
            \\    border(82, 34, 64, 24, true)
            \\    text(98, 42, "Reset", 0, 12632256)
            \\}
            \\
            \\on click {
            \\    if mouse_x() >= 10 and mouse_x() < 74 and mouse_y() >= 34 and mouse_y() < 58 {
            \\        count = count + 1
            \\    }
            \\    if mouse_x() >= 82 and mouse_x() < 146 and mouse_y() >= 34 and mouse_y() < 58 {
            \\        count = 0
            \\    }
            \\}
        );
    }
}

pub fn createUniqueFolder(parent: NodeHandle) ?NodeHandle {
    if (kindOf(parent) != .directory) return null;

    if (findChild(parent, "New Folder") == null)
        return createNode(parent, "New Folder", .directory);

    if (findChild(parent, "New Folder 2") == null)
        return createNode(parent, "New Folder 2", .directory);

    if (findChild(parent, "New Folder 3") == null)
        return createNode(parent, "New Folder 3", .directory);

    return null;
}

pub fn createUniqueTextFile(parent: NodeHandle) ?NodeHandle {
    if (kindOf(parent) != .directory) return null;

    const h = if (findChild(parent, "New Text Document.txt") == null)
        createNode(parent, "New Text Document.txt", .file)
    else if (findChild(parent, "New Text Document 2.txt") == null)
        createNode(parent, "New Text Document 2.txt", .file)
    else if (findChild(parent, "New Text Document 3.txt") == null)
        createNode(parent, "New Text Document 3.txt", .file)
    else
        null;

    if (h) |file| {
        _ = writeFile(file, "");
        return file;
    }

    return null;
}

fn deleteRecursive(handle: NodeHandle) void {
    if (!validHandle(handle)) return;
    if (nodes[handle].kind == .directory) {
        var i: usize = 0;
        while (i < nodes[handle].child_count) : (i += 1) {
            deleteRecursive(nodes[handle].children[i]);
        }
    }
    nodes[handle].in_use = false;
    nodes[handle].child_count = 0;
    nodes[handle].data_len = 0;
}

/// Deletes a direct child of parent. Directories are deleted recursively.
pub fn deleteChild(parent: NodeHandle, name: []const u8) bool {
    if (!validHandle(parent)) return false;
    if (nodes[parent].kind != .directory) return false;
    var i: usize = 0;
    while (i < nodes[parent].child_count) : (i += 1) {
        const child = nodes[parent].children[i];
        if (eqlName(child, name)) {
            deleteRecursive(child);
            var j = i + 1;
            while (j < nodes[parent].child_count) : (j += 1) {
                nodes[parent].children[j - 1] = nodes[parent].children[j];
            }
            nodes[parent].child_count -= 1;
            nodes[parent].children[nodes[parent].child_count] = INVALID;
            return true;
        }
    }
    return false;
}

/// Appends data to a file node, truncating at MAX_FILE_DATA.
pub fn appendFile(handle: NodeHandle, data: []const u8) bool {
    if (!validHandle(handle)) return false;
    if (nodes[handle].kind != .file) return false;
    var pos = nodes[handle].data_len;
    var i: usize = 0;
    while (i < data.len and pos < MAX_FILE_DATA) : (i += 1) {
        nodes[handle].data[pos] = data[i];
        pos += 1;
    }
    nodes[handle].data_len = pos;
    return true;
}

/// Renames a direct child of parent. Returns false on duplicate/invalid name.
pub fn renameChild(parent: NodeHandle, old_name: []const u8, new_name: []const u8) bool {
    if (!validHandle(parent)) return false;
    if (nodes[parent].kind != .directory) return false;
    if (new_name.len == 0 or new_name.len > MAX_NAME_LEN) return false;
    if (findChild(parent, new_name) != null) return false;
    const h = findChild(parent, old_name) orelse return false;
    setName(h, new_name);
    return true;
}

pub fn maxNodes() usize { return MAX_NODES; }
pub fn usedNodes() usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < MAX_NODES) : (i += 1) { if (nodes[i].in_use) count += 1; }
    return count;
}

pub fn fileSize(handle: NodeHandle) usize {
    if (!validHandle(handle)) return 0;
    if (nodes[handle].kind != .file) return 0;
    return nodes[handle].data_len;
}
