// gui/colors.zig - Core97 palette and shared UI colours.

pub const TEAL: u32 = 0x008080;
pub const GREY: u32 = 0xC0C0C0;
pub const DARK_GREY: u32 = 0x808080;

/// The desktop's background fill color - Control Panel's Background
/// page (apps/control_panel.zig) changes this; gui/desktop.zig's
/// drawSceneContents() reads it. Lives here, not in desktop.zig itself,
/// specifically so control_panel.zig can set it without creating a
/// circular import (desktop.zig already imports control_panel.zig, to
/// launch it) - colors.zig has no imports of its own, so anything can
/// safely depend on it.
pub var desktop_background: u32 = TEAL;

/// A handful of preset swatches for the Background page - plain, named
/// colors rather than a full picker, matching the scope of an actual
/// retro-era "Display Properties" background tab.
pub const BACKGROUND_PRESETS = [_]struct { name: []const u8, color: u32 }{
    .{ .name = "Teal", .color = TEAL },
    .{ .name = "Navy", .color = 0x000080 },
    .{ .name = "Maroon", .color = 0x800000 },
    .{ .name = "Forest", .color = 0x004000 },
    .{ .name = "Slate", .color = 0x405060 },
    .{ .name = "Black", .color = 0x000000 },
};
pub const WHITE: u32 = 0xFFFFFF;
pub const BLUE: u32 = 0x000080;
pub const BLACK: u32 = 0x000000;
pub const RED: u32 = 0xFF0000;
