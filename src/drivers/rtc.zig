// drivers/rtc.zig - CMOS Real-Time Clock + civil date math.
//
// Every PC since the original IBM AT has a battery-backed CMOS RTC chip
// (the "Motorola MC146818" or a compatible clone) accessed via two I/O
// ports - 0x70 (register index) and 0x71 (data). This is true on real
// hardware AND in QEMU/VirtualBox: both emulate this exact chip
// interface for compatibility (the same reason Bochs dispi works
// identically in both for video - see vbe.zig), so this one driver
// works unmodified on a real motherboard or under either hypervisor.
//
// taskbar.zig's clock used to just draw the literal string "12:00" -
// there was no time source to read from at all. now() fixes that with
// real wall-clock time. The CMOS RTC alone has no concept of timezone
// or network sync - it's just whatever the battery-backed registers
// say - so ntp.zig (network time sync) can call setDateTime() here to
// correct it from an NTP server, and that correction persists across
// reboots since it's written into the same battery-backed hardware.

const idt = @import("../arch/x86/idt.zig");

const CMOS_INDEX_PORT: u16 = 0x70;
const CMOS_DATA_PORT: u16 = 0x71;

const REG_SECONDS: u8 = 0x00;
const REG_MINUTES: u8 = 0x02;
const REG_HOURS: u8 = 0x04;
const REG_DAY: u8 = 0x07;
const REG_MONTH: u8 = 0x08;
const REG_YEAR: u8 = 0x09;
const REG_STATUS_A: u8 = 0x0A;
const REG_STATUS_B: u8 = 0x0B;

const STATUS_A_UPDATE_IN_PROGRESS: u8 = 0x80;
const STATUS_B_BINARY_MODE: u8 = 0x04; // 1 = values are plain binary, 0 = BCD
const STATUS_B_24_HOUR: u8 = 0x02; // 1 = 24-hour mode, 0 = 12-hour + PM bit

pub const DateTime = struct {
    year: u16, // full year, e.g. 2026 - not the raw 2-digit register value
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8,
    second: u8,
};


fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

fn addHours(dt: DateTime, hours: i8) DateTime {
    var out = dt;
    var h: i16 = @as(i16, out.hour) + @as(i16, hours);
    while (h >= 24) {
        h -= 24;
        out.day += 1;
        const dim = daysInMonth(out.year, out.month);
        if (out.day > dim) {
            out.day = 1;
            out.month += 1;
            if (out.month > 12) {
                out.month = 1;
                out.year += 1;
            }
        }
    }
    while (h < 0) {
        h += 24;
        if (out.day > 1) {
            out.day -= 1;
        } else {
            if (out.month > 1) {
                out.month -= 1;
            } else {
                out.month = 12;
                out.year -= 1;
            }
            out.day = daysInMonth(out.year, out.month);
        }
    }
    out.hour = @intCast(h);
    return out;
}

fn lastSundayOfMonth(year: u16, month: u8) u8 {
    var d = daysInMonth(year, month);
    while (dayOfWeek(year, month, d) != 0) : (d -= 1) {}
    return d;
}

// 0 = Sunday, 1 = Monday, ... 6 = Saturday. Sakamoto's algorithm.
fn dayOfWeek(year_in: u16, month: u8, day: u8) u8 {
    const t = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i32 = @intCast(year_in);
    if (month < 3) y -= 1;
    const w = y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + @as(i32, t[@intCast(month - 1)]) + @as(i32, day);
    return @intCast(@mod(w, 7));
}

/// Returns true when UTC time is inside the EU daylight-saving interval:
/// from 01:00 UTC on the last Sunday in March until 01:00 UTC on the
/// last Sunday in October. Sweden is CET (UTC+1) outside this window and
/// CEST (UTC+2) inside it.
fn isEuropeStockholmDstUtc(utc: DateTime) bool {
    if (utc.month < 3 or utc.month > 10) return false;
    if (utc.month > 3 and utc.month < 10) return true;

    if (utc.month == 3) {
        const start_day = lastSundayOfMonth(utc.year, 3);
        if (utc.day > start_day) return true;
        if (utc.day < start_day) return false;
        return utc.hour >= 1;
    }

    const end_day = lastSundayOfMonth(utc.year, 10);
    if (utc.day < end_day) return true;
    if (utc.day > end_day) return false;
    return utc.hour < 1;
}

pub fn europeStockholmOffsetHours(utc: DateTime) i8 {
    return if (isEuropeStockholmDstUtc(utc)) 2 else 1;
}

/// Interprets the CMOS clock as UTC and converts it to Swedish civil
/// time for display. NTP writes UTC into CMOS, and many Linux/dual-boot
/// systems keep hardware RTC in UTC too; showing local time here fixes
/// the exact +1/+2 hour CET/CEST offset without corrupting the RTC.
pub fn nowEuropeStockholm() DateTime {
    const utc = now();
    return addHours(utc, europeStockholmOffsetHours(utc));
}

fn readReg(reg: u8) u8 {
    idt.outb(CMOS_INDEX_PORT, reg);
    return idt.inb(CMOS_DATA_PORT);
}

fn writeReg(reg: u8, value: u8) void {
    idt.outb(CMOS_INDEX_PORT, reg);
    idt.outb(CMOS_DATA_PORT, value);
}

fn bcdToBinary(v: u8) u8 {
    return (v & 0x0F) + ((v >> 4) * 10);
}

fn binaryToBcd(v: u8) u8 {
    return (v % 10) | ((v / 10) << 4);
}

/// Reads the current date/time from CMOS. Always returns a 24-hour,
/// 4-digit-year, binary-decoded result regardless of how the hardware
/// happens to be configured (BCD/binary, 12/24-hour) - callers never
/// need to think about CMOS's quirky encoding.
///
/// Waits out any in-progress hardware update first (Status Register A's
/// top bit), then reads all six fields - without that wait, it's
/// possible to catch the registers mid-tick and read e.g. seconds=59
/// alongside a minutes value that already advanced, or vice versa.
pub fn now() DateTime {
    var spins: u32 = 0;
    while ((readReg(REG_STATUS_A) & STATUS_A_UPDATE_IN_PROGRESS) != 0) {
        spins += 1;
        if (spins > 100_000) break; // don't hang forever on a stuck/missing RTC
    }

    var second = readReg(REG_SECONDS);
    var minute = readReg(REG_MINUTES);
    var hour_reg = readReg(REG_HOURS);
    var day = readReg(REG_DAY);
    var month = readReg(REG_MONTH);
    var year_reg = readReg(REG_YEAR);
    const status_b = readReg(REG_STATUS_B);

    const is_binary = (status_b & STATUS_B_BINARY_MODE) != 0;
    const is_24hour = (status_b & STATUS_B_24_HOUR) != 0;

    if (!is_binary) {
        second = bcdToBinary(second);
        minute = bcdToBinary(minute);
        // The hour register's PM bit (0x80) lives outside the BCD
        // nibbles even in BCD mode, so mask it off before decoding,
        // then handle 12 -> 24 hour conversion separately below.
        const pm = (hour_reg & 0x80) != 0;
        hour_reg = bcdToBinary(hour_reg & 0x7F);
        if (!is_24hour) {
            if (pm and hour_reg != 12) hour_reg += 12;
            if (!pm and hour_reg == 12) hour_reg = 0;
        }
        day = bcdToBinary(day);
        month = bcdToBinary(month);
        year_reg = bcdToBinary(year_reg);
    } else if (!is_24hour) {
        const pm = (hour_reg & 0x80) != 0;
        hour_reg &= 0x7F;
        if (pm and hour_reg != 12) hour_reg += 12;
        if (!pm and hour_reg == 12) hour_reg = 0;
    }

    // CMOS only stores a 2-digit year. Century register (0x32) exists
    // on many systems but isn't universally reliable across emulators,
    // so this assumes 2000-2099, true for the entire plausible lifetime
    // of this kernel.
    const year: u16 = 2000 + @as(u16, year_reg);

    return DateTime{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour_reg,
        .minute = minute,
        .second = second,
    };
}

/// Writes a new date/time into CMOS, encoding back into whatever mode
/// (BCD/binary, 12/24-hour) the hardware is already configured for -
/// matches now()'s decoding so a read-modify-write round trip is
/// lossless. Used by ntp.zig after a successful time sync; because
/// CMOS is battery-backed, this correction survives reboots, not just
/// the current session.
pub fn setDateTime(dt: DateTime) void {
    const status_b = readReg(REG_STATUS_B);
    const is_binary = (status_b & STATUS_B_BINARY_MODE) != 0;
    const is_24hour = (status_b & STATUS_B_24_HOUR) != 0;

    var hour_out: u8 = dt.hour;
    var pm = false;
    if (!is_24hour) {
        pm = dt.hour >= 12;
        hour_out = if (dt.hour == 0) 12 else if (dt.hour > 12) dt.hour - 12 else dt.hour;
    }

    const year_2digit: u8 = @intCast(dt.year % 100);

    if (is_binary) {
        writeReg(REG_SECONDS, dt.second);
        writeReg(REG_MINUTES, dt.minute);
        writeReg(REG_HOURS, if (pm) hour_out | 0x80 else hour_out);
        writeReg(REG_DAY, dt.day);
        writeReg(REG_MONTH, dt.month);
        writeReg(REG_YEAR, year_2digit);
    } else {
        writeReg(REG_SECONDS, binaryToBcd(dt.second));
        writeReg(REG_MINUTES, binaryToBcd(dt.minute));
        const hour_bcd = binaryToBcd(hour_out);
        writeReg(REG_HOURS, if (pm) hour_bcd | 0x80 else hour_bcd);
        writeReg(REG_DAY, binaryToBcd(dt.day));
        writeReg(REG_MONTH, binaryToBcd(dt.month));
        writeReg(REG_YEAR, binaryToBcd(year_2digit));
    }
}

// --- Civil date math (pure logic, no hardware - used by ntp.zig to
// turn a Unix timestamp into the DateTime struct above). Based on the
// well-known "days_from_civil"/"civil_from_days" algorithm (Howard
// Hinnant's public-domain chrono algorithms), valid for any date in the
// proleptic Gregorian calendar - far more range than this kernel will
// ever need, but it's not worth implementing a deliberately-narrower,
// more error-prone version of well-understood, easily-verified math.

const SECONDS_PER_DAY: i32 = 86400;

/// Converts a Unix timestamp (seconds since 1970-01-01 00:00:00 UTC)
/// into year/month/day/hour/minute/second. No timezone handling - this
/// kernel has no timezone concept anywhere yet, so the result is UTC,
/// same as the timestamp itself.
///
/// Takes i32, not i64: NTP's own wire format only has a 32-bit seconds
/// field (see network.zig's ntp.zig-equivalent NTP client), which
/// already bounds every timestamp this function will ever actually
/// receive to a range that fits comfortably in i32 (roughly 1970-2036 -
/// the well-known "NTP era rollover" limit, not something introduced
/// here). That matters mechanically, not just numerically: this is a
/// freestanding 32-bit kernel with no compiler-rt/libgcc linked in, so
/// i64 division/modulo - which doesn't fit in a single x86 instruction
/// the way 32-bit division does - silently turned into calls to
/// __divdi3/__moddi3 that don't exist anywhere in this binary, and the
/// kernel failed to LINK, not just behave wrong. Restructuring this to
/// stay within i32 the whole way through sidesteps that entirely.
pub fn civilFromUnixTimestamp(timestamp: i32) DateTime {
    var days = @divFloor(timestamp, SECONDS_PER_DAY);
    var secs_of_day = timestamp - days * SECONDS_PER_DAY;
    if (secs_of_day < 0) {
        secs_of_day += SECONDS_PER_DAY;
        days -= 1;
    }

    const hour: u8 = @intCast(@divFloor(secs_of_day, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(secs_of_day, 3600), 60));
    const second: u8 = @intCast(@mod(secs_of_day, 60));

    // days_from_civil's inverse: shift the epoch so March 1st is the
    // first day of the "computational year" (so the Feb 29 leap day
    // always falls at the very end, simplifying the month lookup).
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    const full_year = if (m <= 2) y + 1 else y;

    return DateTime{
        .year = @intCast(full_year),
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}
