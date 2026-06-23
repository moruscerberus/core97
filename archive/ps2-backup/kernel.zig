// kernel.zig - läser multiboot framebuffer-info och ritar grafik

const idt = @import("idt.zig");
const keyboard = @import("keyboard.zig");
const mouse = @import("mouse.zig");

// --- CPU-exception-hantering ---
// Anropas från interrupts.asm när en CPU-exception (0-19) inträffar.
// Ritar en röd banderoll + felnumret som tända/släckta rutor (binärt,
// vi har ingen font än) längst upp på skärmen, och stannar säkert.
// Detta ersätter en tyst triple fault/reboot med synlig diagnostik.
export fn exception_handler(exception_num: u32, error_code: u32) callconv(.C) void {
    _ = error_code;

    if (fb_addr == 0) {
        // Vi har inte ens framebuffer än - bara stanna
        while (true) asm volatile ("hlt");
    }

    // Röd banderoll över hela skärmens topp
    fillRect(0, 0, fb_width, 60, 0xCC0000);

    // Rita exception_num i binärt som 8 rutor (tänd=vit, släckt=mörkröd)
    var bit: u32 = 0;
    while (bit < 8) : (bit += 1) {
        const mask: u32 = @as(u32, 1) << @intCast(7 - bit);
        const on = (exception_num & mask) != 0;
        const color: u32 = if (on) 0xFFFFFF else 0x660000;
        fillRect(10 + bit * 25, 10, 20, 40, color);
    }

    while (true) {
        asm volatile ("hlt");
    }
}

// --- Freestanding-stöd ---
// Utan libc eller Zigs std-runtime måste vi själva definiera dessa
// "kompilator-genererade" funktioner som Zig (och dess egen std.debug)
// ibland förväntar sig finns tillgängliga.

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    // Ingen fancy felutskrift än - bara fastna säkert istället för krasch
    while (true) {
        asm volatile ("hlt");
    }
}

export fn memset(dest: ?[*]u8, val: c_int, len: usize) callconv(.C) ?[*]u8 {
    if (dest) |d| {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            d[i] = @as(u8, @truncate(@as(c_uint, @bitCast(val))));
        }
    }
    return dest;
}

export fn memcpy(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.C) ?[*]u8 {
    if (dest) |d| {
        if (src) |s| {
            var i: usize = 0;
            while (i < len) : (i += 1) {
                d[i] = s[i];
            }
        }
    }
    return dest;
}

export fn memmove(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.C) ?[*]u8 {
    if (dest) |d| {
        if (src) |s| {
            if (@intFromPtr(d) < @intFromPtr(s)) {
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    d[i] = s[i];
                }
            } else {
                var i: usize = len;
                while (i > 0) {
                    i -= 1;
                    d[i] = s[i];
                }
            }
        }
    }
    return dest;
}

// --- Multiboot info struct (bara de fält vi behöver) ---
// Layout enligt Multiboot Specification 0.6.96
const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,
    drives_length: u32,
    drives_addr: u32,
    config_table: u32,
    bootloader_name: u32,
    apm_table: u32,
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
    // Framebuffer info (flagga bit 12 = 0x1000)
    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,
    color_info: [6]u8,
};

var fb_addr: usize = 0;
var fb_pitch: u32 = 0;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_bpp: u8 = 0;

// --- Dubbelbuffring ---
// Att rita direkt till framebuffer-minnet pixel-för-pixel ger synligt
// flimmer (vi ser skärmen mitt i en omritning, särskilt vid snabba
// musrörelser som triggar många redraws/sekund). Lösningen: rita allt
// till en buffer i vanligt RAM, sen kopiera HELA buffern till skärmen
// i en enda svep när vi är klara.
const MAX_BACKBUFFER_PIXELS: usize = 1024 * 768;
var backbuffer: [MAX_BACKBUFFER_PIXELS]u32 = undefined;

// Sätter en pixel i back-buffern (INTE direkt på skärmen)
fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height) return;
    const idx = y * fb_width + x;
    if (idx >= backbuffer.len) return;
    backbuffer[idx] = color;
}

fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            putPixel(x + col, y + row, color);
        }
    }
}

// Kopierar hela back-buffern till den riktiga skärmen i en svep.
// Måste anropas en gång i SLUTET av varje frame, aldrig mitt i.
fn presentFrame() void {
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        const row_offset = y * fb_pitch;
        var x: u32 = 0;
        while (x < fb_width) : (x += 1) {
            const idx = y * fb_width + x;
            if (idx >= backbuffer.len) continue;
            const ptr: *volatile u32 = @ptrFromInt(fb_addr + row_offset + x * (fb_bpp / 8));
            ptr.* = backbuffer[idx];
        }
    }
}

// Core97 color palette
const CORE97_TEAL: u32 = 0x008080;       // klassisk skrivbordsbakgrund
const CORE97_GREY: u32 = 0xC0C0C0;       // fönster/knappar
const CORE97_DARK_GREY: u32 = 0x808080;  // skuggor/border
const CORE97_WHITE: u32 = 0xFFFFFF;      // highlights
const CORE97_BLUE: u32 = 0x000080;       // titelbar
const CORE97_BLACK: u32 = 0x000000;
const CORE97_RED: u32 = 0xFF0000;        // placeholder för start-logo

// --- Fönster-state (gör fönstret flyttbart) ---
var win_x: i32 = 200;
var win_y: i32 = 150;
const win_w: u32 = 400;
const win_h: u32 = 300;

var dragging: bool = false;
var drag_offset_x: i32 = 0;
var drag_offset_y: i32 = 0;

fn getPixel(x: u32, y: u32) u32 {
    if (x >= fb_width or y >= fb_height) return 0;
    const idx = y * fb_width + x;
    if (idx >= backbuffer.len) return 0;
    return backbuffer[idx];
}

// Ritar ett "raised" 3D-block i Core97-stil (knapp/fönsterkant)
fn draw3DBorder(x: u32, y: u32, w: u32, h: u32, raised: bool) void {
    const light = if (raised) CORE97_WHITE else CORE97_DARK_GREY;
    const dark = if (raised) CORE97_DARK_GREY else CORE97_WHITE;

    // Top + left = ljus
    fillRect(x, y, w, 1, light);
    fillRect(x, y, 1, h, light);
    // Bottom + right = mörk
    fillRect(x, y + h - 1, w, 1, dark);
    fillRect(x + w - 1, y, 1, h, dark);
}

// Ritar en liten upphöjd kontrollknapp (16x14) i titelbaren
fn drawTitlebarButton(x: u32, y: u32) void {
    const w: u32 = 16;
    const h: u32 = 14;
    fillRect(x, y, w, h, CORE97_GREY);
    draw3DBorder(x, y, w, h, true);
}

// Minimera: en kort horisontell linje längst ner i knappen
fn drawMinimizeIcon(x: u32, y: u32) void {
    drawTitlebarButton(x, y);
    fillRect(x + 3, y + 9, 8, 2, CORE97_BLACK);
}

// Maximera: en liten tom ruta (fönster-symbol)
fn drawMaximizeIcon(x: u32, y: u32) void {
    drawTitlebarButton(x, y);
    fillRect(x + 3, y + 3, 10, 8, CORE97_BLACK);
    fillRect(x + 4, y + 5, 8, 5, CORE97_GREY);
}

// Stäng: ett X gjort av två diagonala "tjocka" linjer
fn drawCloseIcon(x: u32, y: u32) void {
    drawTitlebarButton(x, y);
    const size: u32 = 8;
    const ox = x + 4;
    const oy = y + 3;
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        putPixel(ox + i, oy + i, CORE97_BLACK);
        putPixel(ox + i + 1, oy + i, CORE97_BLACK);
        putPixel(ox + (size - 1 - i), oy + i, CORE97_BLACK);
        putPixel(ox + (size - 1 - i) + 1, oy + i, CORE97_BLACK);
    }
}

fn drawWindow(x: i32, y: i32, w: u32, h: u32, title: []const u8) void {
    _ = title; // textrendering kommer senare (behöver font)
    // Säkerhetsklampning: negativa koordinater får ALDRIG nå @intCast,
    // det är odefinierat beteende / krasch. clamp till 0 om något
    // ovanligt smiter igenom anroparens egen klampning.
    const safe_x: i32 = if (x < 0) 0 else x;
    const safe_y: i32 = if (y < 0) 0 else y;
    const ux: u32 = @intCast(safe_x);
    const uy: u32 = @intCast(safe_y);
    // Fönsterbakgrund
    fillRect(ux, uy, w, h, CORE97_GREY);
    // Yttre 3D-ram
    draw3DBorder(ux, uy, w, h, true);
    // Titelbar
    fillRect(ux + 2, uy + 2, w - 4, 18, CORE97_BLUE);

    // Kontrollknappar i titelbarens högra hörn (minimera, maximera, stäng)
    const btn_y = uy + 3;
    const btn_spacing: u32 = 18;
    const close_x = ux + w - 2 - 16;
    const maximize_x = close_x - btn_spacing;
    const minimize_x = maximize_x - btn_spacing;

    drawMinimizeIcon(minimize_x, btn_y);
    drawMaximizeIcon(maximize_x, btn_y);
    drawCloseIcon(close_x, btn_y);
}

const TASKBAR_HEIGHT: u32 = 28;

fn drawTaskbar() void {
    const y = fb_height - TASKBAR_HEIGHT;

    // Grå taskbar-bakgrund
    fillRect(0, y, fb_width, TASKBAR_HEIGHT, CORE97_GREY);

    // Övre highlight-linje (ger 3D-känsla mot skrivbordet ovanför)
    fillRect(0, y, fb_width, 1, CORE97_WHITE);

    // Start-knapp
    const btn_x: u32 = 2;
    const btn_y: u32 = y + 2;
    const btn_w: u32 = 70;
    const btn_h: u32 = TASKBAR_HEIGHT - 4;

    fillRect(btn_x, btn_y, btn_w, btn_h, CORE97_GREY);
    draw3DBorder(btn_x, btn_y, btn_w, btn_h, true);
    // Liten "logo"-ruta i knappen (placeholder for the OS logo)
    fillRect(btn_x + 4, btn_y + 4, 12, 12, CORE97_RED);

    // Klock-ruta längst till höger
    const clock_w: u32 = 60;
    const clock_x: u32 = fb_width - clock_w - 2;
    fillRect(clock_x, btn_y, clock_w, btn_h, CORE97_GREY);
    draw3DBorder(clock_x, btn_y, clock_w, btn_h, false); // "sunken" look

    // Skiljelinje mellan start-knapp och resten av taskbaren
    fillRect(btn_x + btn_w + 6, btn_y, 1, btn_h, CORE97_DARK_GREY);
    fillRect(btn_x + btn_w + 7, btn_y, 1, btn_h, CORE97_WHITE);
}

// --- Muspekare ---
// Enkel pil ritad som en liten triangel av pixlar.
const cursor_shape = [_][2]i32{
    .{ 0, 0 },  .{ 0, 1 },  .{ 0, 2 },  .{ 0, 3 },  .{ 0, 4 },
    .{ 0, 5 },  .{ 0, 6 },  .{ 0, 7 },  .{ 0, 8 },  .{ 1, 1 },
    .{ 1, 2 },  .{ 1, 3 },  .{ 1, 4 },  .{ 1, 5 },  .{ 1, 6 },
    .{ 2, 2 },  .{ 2, 3 },  .{ 2, 4 },  .{ 2, 5 },  .{ 3, 3 },
    .{ 3, 4 },  .{ 1, 7 },  .{ 2, 6 },  .{ 4, 4 },
};

fn drawCursor(x: i32, y: i32) void {
    for (cursor_shape) |offset| {
        const px = x + offset[0];
        const py = y + offset[1];
        if (px >= 0 and py >= 0) {
            putPixel(@intCast(px), @intCast(py), CORE97_BLACK);
        }
    }
}

// Ritar om hela scenen: skrivbord, fönster, taskbar, muspekare.
// Enklast och mest robust just nu — ingen "dirty rect"-optimering än.
fn redrawScene() void {
    fillRect(0, 0, fb_width, fb_height, CORE97_TEAL);
    drawWindow(win_x, win_y, win_w, win_h, "Demo");
    drawTaskbar();
    drawCursor(mouse.mouse_x, mouse.mouse_y);

    // Kopiera hela back-buffern till skärmen i en svep - detta eliminerar
    // flimret som annars uppstår vid många snabba redraws (musrörelser).
    presentFrame();
}

// --- Titelbar-hit-test för drag ---
fn isOverTitlebar(mx: i32, my: i32) bool {
    if (mx < win_x + 2 or mx > win_x + @as(i32, @intCast(win_w)) - 2) return false;
    if (my < win_y + 2 or my > win_y + 20) return false;
    return true;
}

fn onMouseUpdate() void {
    if (mouse.left_button) {
        if (!dragging) {
            // Just nu nedtryckt - kolla om vi klickade på titelbaren
            if (isOverTitlebar(mouse.mouse_x, mouse.mouse_y)) {
                dragging = true;
                drag_offset_x = mouse.mouse_x - win_x;
                drag_offset_y = mouse.mouse_y - win_y;
            }
        } else {
            // Fortsätt dra: flytta fönstret med musen
            win_x = mouse.mouse_x - drag_offset_x;
            win_y = mouse.mouse_y - drag_offset_y;

            // Klampa så fönstret aldrig kan gå negativt eller helt utanför
            // skärmen - annars kraschar @intCast(x) till u32 i drawWindow.
            const max_x: i32 = @as(i32, @intCast(fb_width)) - 20;
            const max_y: i32 = @as(i32, @intCast(fb_height)) - 20 - @as(i32, @intCast(TASKBAR_HEIGHT));
            if (win_x < 0) win_x = 0;
            if (win_y < 0) win_y = 0;
            if (win_x > max_x) win_x = max_x;
            if (win_y > max_y) win_y = max_y;
        }
    } else {
        dragging = false;
    }

    redrawScene();
}

fn onKeyPress(ascii: u8) void {
    _ = ascii; // text-input kopplas in när vi bygger editorn
}

export fn kernel_main(multiboot_info_ptr: u32) callconv(.C) void {
    const info: *MultibootInfo = @ptrFromInt(multiboot_info_ptr);

    fb_addr = @intCast(info.framebuffer_addr);
    fb_pitch = info.framebuffer_pitch;
    fb_width = info.framebuffer_width;
    fb_height = info.framebuffer_height;
    fb_bpp = info.framebuffer_bpp;

    // Om GRUB inte gav oss en framebuffer, gör ingenting (undvik krasch)
    if (fb_addr == 0 or fb_bpp != 32) {
        while (true) {
            asm volatile ("hlt");
        }
    }

    // Tala om för musdrivrutinen var skärmens gränser är
    mouse.screen_width = @intCast(fb_width);
    mouse.screen_height = @intCast(fb_height);
    mouse.mouse_x = @intCast(fb_width / 2);
    mouse.mouse_y = @intCast(fb_height / 2);

    // Sätt upp IDT/PIC innan vi aktiverar någon drivrutin
    idt.init();

    keyboard.setKeyHandler(onKeyPress);
    mouse.setMouseHandler(onMouseUpdate);
    mouse.init(null);

    redrawScene();

    // Kerneln "sover" tills nästa interrupt (mus/tangentbord) väcker den.
    // All faktisk ritning sker i onMouseUpdate/onKeyPress via callbacks.
    while (true) {
        asm volatile ("hlt");
    }
}
