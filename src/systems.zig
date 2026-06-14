const std = @import("std");
const rl = @import("raylib");
const data = @import("data.zig");

pub const SLOTS: usize = 300;
pub const SCROLL_BEATS: f32 = 8.0;
pub const HIT_WINDOW: f32 = 0.35;
pub fn getNoteU128(laneNotes: [10]u128, slot: usize) u128 {
    return laneNotes[slot / 42];
}
pub fn getNoteOffset(slot: usize) usize {
    return (slot % 42) * 3;
}
pub fn getHitU64(hitMask: [5]u64, slot: usize) u64 {
    return hitMask[slot / 64];
}
pub fn getHitOffset(slot: usize) usize {
    return slot % 64;
}
pub fn isHitMarked(hitMask: [5]u64, slot: usize) bool {
    return (getHitU64(hitMask, slot) >> @intCast(getHitOffset(slot))) & 1 != 0;
}
pub fn markHit(hitMask: *[5]u64, slot: usize) void {
    const u64Idx = slot / 64;
    const offset = slot % 64;
    hitMask[u64Idx] |= @as(u64, 1) << @intCast(offset);
}

pub inline fn present(laneNotes: [10]u128, slot: usize) bool {
    const noteU128 = getNoteU128(laneNotes, slot);
    const offset = getNoteOffset(slot);
    return (noteU128 >> @intCast(offset)) & 1 != 0;
}

pub inline fn isHalf(laneNotes: [10]u128, slot: usize) bool {
    const noteU128 = getNoteU128(laneNotes, slot);
    const offset = getNoteOffset(slot);
    return (noteU128 >> @intCast(offset + 1)) & 1 != 0;
}

pub inline fn connected(laneNotes: [10]u128, slot: usize) bool {
    const noteU128 = getNoteU128(laneNotes, slot);
    const offset = getNoteOffset(slot);
    return (noteU128 >> @intCast(offset + 2)) & 1 != 0;
}
pub fn holdLen(laneNotes: [10]u128, slot: usize) u8 {
    var len: u8 = 1;
    var s = slot;
    while (s + 1 < SLOTS and connected(laneNotes, s + 1)) : (s += 1) len += 1;
    return len;
}
pub fn updateStars(state: *data.GameState) void {
    if (state.comboCount == 0) {
        state.starCount = 0;
        state.starPowerComboComplete = false;
    } else {
        state.starCount = @min(5, @as(u8, @intCast(1 + (state.comboCount - 1) / 10)));
    }

    state.starMultiplier = switch (state.starCount) {
        0 => 1,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 5,
        else => 1,
    };
}
pub fn getScoreMultiplier(state: *const data.GameState) u32 {
    var multiplier = @as(u32, state.starMultiplier);
    if (state.starPowerActive) multiplier *= 2;
    return multiplier;
}
pub fn computeEndBeat(state: *data.GameState) void {
    var lastSlot: usize = 0;
    for (0..5) |l| {
        for (0..SLOTS) |s| {
            if (present(state.notes[l], s)) {
                lastSlot = @max(lastSlot, s);
            }
        }
    }
    const bps = if (state.songs.current) |c| c.bps else 2.0;
    state.endBeat = @as(f32, @floatFromInt(lastSlot + 1)) + bps;
}
pub fn maxPossibleScore(state: *const data.GameState) u32 {
    var combo: u32 = 0;
    var totalScore: u32 = 0;

    for (0..SLOTS) |s| {
        for (0..5) |l| {
            if (present(state.notes[l], s)) {
                const mult: u32 = @min(5, 1 + combo / 10);
                if (connected(state.notes[l], s)) {
                    const hlen = holdLen(state.notes[l], s);
                    totalScore += 25 * @as(u32, hlen) * mult;
                } else {
                    totalScore += 50 * mult;
                }
                combo += 1;
            }
        }
    }
    return totalScore;
}
pub fn countNoteStats(state: *const data.GameState) data.NoteStats {
    var stats = data.NoteStats{ .total = 0, .hits = 0 };
    for (0..5) |l| {
        for (0..SLOTS) |s| {
            if (present(state.notes[l], s)) {
                stats.total += 1;
                if (isHitMarked(state.hitMask[l], s)) {
                    stats.hits += 1;
                }
            }
        }
    }
    return stats;
}
pub fn update(state: *data.GameState, settings: *const data.Settings) void {
    if (state.songs.current != state.prevSong) {
        state.beat = 0;
        state.hitMask = .{.{0} ** 5} ** 5;
        state.missSlot = .{0} ** 5;
        state.holdActive = .{false} ** 5;
        state.holdStartBeat = .{0} ** 5;
        state.starPowerMeter = 0.0;
        state.starPowerActive = false;
        state.starPowerTimer = 0.0;
        state.starPowerComboComplete = false;
        state.resultsCountdown = -1.0;
        state.prevSong = state.songs.current;
        computeEndBeat(state);
    }

    const dt = rl.getFrameTime();
    const bps = if (state.songs.current) |c| c.bps else 2.0;
    state.beat += bps * dt;

    // Handle star power activation with action button (settings.keys[5])
    if (rl.isKeyPressed(settings.keys[5]) and state.starPowerMeter >= 0.5 and !state.starPowerActive) {
        state.starPowerActive = true;
        state.starPowerTimer = 8.0;
        state.starPowerMeter = 0.0;
        state.starPowerComboComplete = true;
    }

    // Update star power timer
    if (state.starPowerActive) {
        state.starPowerTimer -= dt;
        if (state.starPowerTimer <= 0.0) {
            // If combo increased during star power, reward with 25% meter
            if (state.starPowerComboComplete) {
                state.starPowerMeter = 0.25;
            }
            state.starPowerActive = false;
            state.starPowerTimer = 0.0;
            state.starPowerComboComplete = false;
        }
    }

    for (0..5) |l| {
        const laneBits = state.notes[l];

        // Detect notes that scrolled past the hit window without being hit
        while (state.missSlot[l] < SLOTS and
            @as(f32, @floatFromInt(state.missSlot[l])) + HIT_WINDOW < state.beat) : (state.missSlot[l] += 1)
        {
            const ms = state.missSlot[l];
            if (present(laneBits, ms) and !isHitMarked(state.hitMask[l], ms)) {
                state.comboCount = 0;
                state.starPowerComboComplete = false;
            }
        }

        if (state.holdActive[l]) {
            if (!rl.isKeyDown(settings.keys[l])) {
                const beatsHeld = state.beat - state.holdStartBeat[l];
                const multiplier = getScoreMultiplier(state);
                const points = 25 * @as(u32, @intFromFloat(beatsHeld)) * multiplier;
                if (points > 0) {
                    state.score += points;
                    state.comboCount += 1;
                    if (state.comboCount > state.maxCombo) state.maxCombo = state.comboCount;
                    if (!state.starPowerActive) {
                        state.starPowerMeter = @min(1.0, state.starPowerMeter + 0.10);
                    }
                } else {
                    state.comboCount = 0;
                    state.starPowerComboComplete = false;
                }
                state.holdActive[l] = false;
            }
        } else if (rl.isKeyPressed(settings.keys[l])) {
            var bestSlot: ?usize = null;
            var bestDist: f32 = HIT_WINDOW;
            const sMin: usize = if (state.beat > HIT_WINDOW) @intFromFloat(state.beat - HIT_WINDOW) else 0;
            const sMax: usize = @min(SLOTS - 1, @as(usize, @intFromFloat(state.beat + HIT_WINDOW)) + 1);
            var s = sMin;
            while (s <= sMax) : (s += 1) {
                if (!present(laneBits, s)) continue;
                if (isHitMarked(state.hitMask[l], s)) continue;
                const dist = @abs(state.beat - @as(f32, @floatFromInt(s)));
                if (dist < bestDist) {
                    bestDist = dist;
                    bestSlot = s;
                }
            }
            if (bestSlot) |slot| {
                markHit(&state.hitMask[l], slot);
                if (connected(laneBits, slot)) {
                    state.holdActive[l] = true;
                    state.holdSlot[l] = @intCast(slot);
                    state.holdLen[l] = holdLen(laneBits, slot);
                    state.holdStartBeat[l] = state.beat;
                } else {
                    const multiplier = getScoreMultiplier(state);
                    state.score += 50 * multiplier;
                    state.comboCount += 1;
                    if (state.comboCount > state.maxCombo) state.maxCombo = state.comboCount;
                    if (!state.starPowerActive) {
                        state.starPowerMeter = @min(1.0, state.starPowerMeter + 0.15);
                    }
                }
            } else {
                state.comboCount = 0;
                state.starPowerComboComplete = false;
            }
        }
    }

    if (state.endBeat > 0 and state.beat >= state.endBeat) {
        if (state.resultsCountdown < 0) {
            state.resultsCountdown = 1.0;
        } else {
            state.resultsCountdown -= dt;
            if (state.resultsCountdown < 0) {
                state.resultsCountdown = 0;
            }
        }
    }

    updateStars(state);
}
pub const RESOURCE_PATH = "resources";
pub fn parseColor(val: []const u8) !rl.Color {
    var parts = std.mem.splitScalar(u8, val, ',');
    const r = try std.fmt.parseInt(u8, std.mem.trim(u8, parts.next() orelse return error.Invalid, " "), 10);
    const g = try std.fmt.parseInt(u8, std.mem.trim(u8, parts.next() orelse return error.Invalid, " "), 10);
    const b = try std.fmt.parseInt(u8, std.mem.trim(u8, parts.next() orelse return error.Invalid, " "), 10);
    const a = try std.fmt.parseInt(u8, std.mem.trim(u8, parts.next() orelse return error.Invalid, " "), 10);
    return .{ .r = r, .g = g, .b = b, .a = a };
}
pub fn parseLine(line: []const u8, keyOut: *[]const u8, valOut: *[]const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \r\t");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    keyOut.* = trimmed[0..eq];
    valOut.* = trimmed[eq + 1 ..];
    return true;
}
pub fn loadSettings(io: std.Io, out: *data.Settings) void {
    loadSettingsInner(io, out) catch {};
}
pub fn loadSettingsInner(io: std.Io, out: *data.Settings) !void {
    var buf: [2048]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, "settings.cfg", &buf);
    var tok = std.mem.tokenizeSequence(u8, content, "\n");
    while (tok.next()) |line| {
        var key: []const u8 = undefined;
        var val: []const u8 = undefined;
        if (!parseLine(line, &key, &val)) continue;
        if (std.mem.eql(u8, key, "delay")) {
            out.delay = std.fmt.parseFloat(f32, val) catch continue;
        } else if (std.mem.startsWith(u8, key, "key")) {
            const idx = std.fmt.parseInt(usize, key[3..], 10) catch continue;
            if (idx >= 6) continue;
            const ki = std.fmt.parseInt(i32, val, 10) catch continue;
            if (ki < 0 or ki > 400) continue;
            out.keys[idx] = @enumFromInt(ki);
        } else if (std.mem.startsWith(u8, key, "col")) {
            const idx = std.fmt.parseInt(usize, key[3..], 10) catch continue;
            if (idx >= 7) continue;
            out.colors[idx] = parseColor(val) catch continue;
        }
    }
}
pub fn saveSettings(io: std.Io, s: *const data.Settings) !void {
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    pos += (try std.fmt.bufPrint(buf[pos..], "delay={d:.3}\n", .{s.delay})).len;
    for (s.keys, 0..) |k, i| {
        pos += (try std.fmt.bufPrint(buf[pos..], "key{d}={d}\n", .{ i, @intFromEnum(k) })).len;
    }
    for (s.colors, 0..) |c, i| {
        pos += (try std.fmt.bufPrint(buf[pos..], "col{d}={d},{d},{d},{d}\n", .{ i, c.r, c.g, c.b, c.a })).len;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "settings.cfg", .data = buf[0..pos] });
}
pub fn loadUiTheme(io: std.Io) void {
    loadUiThemeInner(io) catch {};
}
pub fn loadUiThemeInner(io: std.Io) !void {
    var buf: [2048]u8 = undefined;
    const content = try std.Io.Dir.cwd().readFile(io, RESOURCE_PATH ++ "/theme.cfg", &buf);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var key: []const u8 = undefined;
        var val: []const u8 = undefined;
        if (!parseLine(line, &key, &val)) continue;
        const c = parseColor(val) catch continue;
        if (std.mem.eql(u8, key, "bg")) {
            data.theme.bg = c;
        } else if (std.mem.eql(u8, key, "section")) {
            data.theme.section = c;
        } else if (std.mem.eql(u8, key, "btn")) {
            data.theme.btn = c;
        } else if (std.mem.eql(u8, key, "btn_hover")) {
            data.theme.btnHover = c;
        } else if (std.mem.eql(u8, key, "btn_press")) {
            data.theme.btnPress = c;
        } else if (std.mem.eql(u8, key, "key_btn")) {
            data.theme.keyBtn = c;
        } else if (std.mem.eql(u8, key, "key_btn_hover")) {
            data.theme.keyBtnHover = c;
        } else if (std.mem.eql(u8, key, "key_btn_press")) {
            data.theme.keyBtnPress = c;
        }
    }
}
pub fn scan_songs(io: std.Io) void {
    // Clear textures
    for (data.discovered[0..data.discovered_count]) |*d| {
        if (d.has_texture) {
            rl.unloadTexture(d.texture);
        }
    }
    // Reload songs
    data.discovered_count = 0;

    var songsDir = (std.Io.Dir.cwd()).openDir(io, "songs", .{ .iterate = true }) catch return;
    defer songsDir.close(io);
    var iter = songsDir.iterate();

    while (iter.next(io) catch null) |entry| {
        if (data.discovered_count >= data.MAX_DISCOVERED) break;
        if (entry.kind != .directory) continue;

        var songData = &data.discovered[data.discovered_count];
        data.discovered_count += 1;

        @memcpy(songData.folder[0..entry.name.len], entry.name);
        songData.folder[entry.name.len] = 0;

        var metaPathBuf: [256]u8 = undefined;
        const metaPath = std.fmt.bufPrintZ(&metaPathBuf, "songs/{s}/meta.cfg", .{entry.name}) catch {
            songData.title[0] = 0;
            songData.bps = 2.5;
            continue;
        };

        var metaBuf: [512]u8 = undefined;
        const metaContent = std.Io.Dir.cwd().readFile(io, metaPath, &metaBuf) catch {
            songData.title[0] = 0;
            songData.bps = 2.5;
            continue;
        };

        var isTitleFound = false;
        var lines = std.mem.splitSequence(u8, metaContent, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eqIdx| {
                const key = std.mem.trim(u8, trimmed[0..eqIdx], " \t");
                const val = std.mem.trim(u8, trimmed[eqIdx + 1 ..], " \t");

                if (std.mem.eql(u8, key, "title")) {
                    const copyLen = @min(val.len, 63);
                    std.mem.copyForwards(u8, songData.title[0..], val[0..copyLen]);
                    songData.title[copyLen] = 0;
                    isTitleFound = true;
                } else if (std.mem.eql(u8, key, "bps")) {
                    songData.bps = std.fmt.parseFloat(f32, val) catch 2.5;
                } else {
                    // Parse notes_lane0 through notes_lane4
                    for (0..5) |lane| {
                        var laneKeyBuf: [32]u8 = undefined;
                        const laneKey = std.fmt.bufPrintZ(&laneKeyBuf, "notes_lane{d}", .{lane}) catch continue;
                        if (std.mem.eql(u8, key, laneKey)) {
                            var hexVals = std.mem.splitSequence(u8, val, ",");
                            for (0..10) |chunk| {
                                if (hexVals.next()) |hexStr| {
                                    const hexTrimmed = std.mem.trim(u8, hexStr, " \t");
                                    songData.notes[lane][chunk] = std.fmt.parseInt(u128, hexTrimmed, 0) catch 0;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!isTitleFound) {
            std.mem.copyForwards(u8, songData.title[0..], entry.name);
            songData.title[entry.name.len] = 0;
        }

        var imagePathBuf: [256]u8 = undefined;
        if (std.fmt.bufPrintZ(&imagePathBuf, "songs/{s}/image.png", .{entry.name}) catch null) |imagePath| {
            if (rl.loadImage(imagePath)) |img| {
                if (rl.loadTextureFromImage(img)) |tex| {
                    songData.texture = tex;
                    songData.has_texture = true;
                } else |_| {
                    songData.has_texture = false;
                }
                rl.unloadImage(img);
            } else |_| {
                songData.has_texture = false;
            }
        } else {
            songData.has_texture = false;
        }
        songData.selected = false;
    }
}
