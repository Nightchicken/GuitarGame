const std = @import("std");
const rl = @import("raylib");
const data = @import("data.zig");
const chart = @import("chart.zig");

pub const SLOTS: usize = chart.SLOTS;
pub const SCROLL_BEATS: f32 = 8.0;
pub const HIT_WINDOW: f32 = 0.35;
/// Slot index at a (possibly negative) beat position, clamped to the chart.
pub fn slot_at(beat: f32) usize {
    if (beat <= 0) return 0;
    return @min(SLOTS - 1, @as(usize, @intFromFloat(beat)));
}
pub fn getNoteU128(laneNotes: data.LaneNotes, slot: usize) u128 {
    return laneNotes[slot / chart.SLOTS_PER_CHUNK];
}
pub fn getNoteOffset(slot: usize) usize {
    return (slot % chart.SLOTS_PER_CHUNK) * 3;
}
pub fn getHitU64(hitMask: [data.HIT_WORDS]u64, slot: usize) u64 {
    return hitMask[slot / 64];
}
pub fn getHitOffset(slot: usize) usize {
    return slot % 64;
}
pub fn isHitMarked(hitMask: [data.HIT_WORDS]u64, slot: usize) bool {
    return (getHitU64(hitMask, slot) >> @intCast(getHitOffset(slot))) & 1 != 0;
}
pub fn markHit(hitMask: *[data.HIT_WORDS]u64, slot: usize) void {
    const u64Idx = slot / 64;
    const offset = slot % 64;
    hitMask[u64Idx] |= @as(u64, 1) << @intCast(offset);
}

pub inline fn present(laneNotes: data.LaneNotes, slot: usize) bool {
    const noteU128 = getNoteU128(laneNotes, slot);
    const offset = getNoteOffset(slot);
    return (noteU128 >> @intCast(offset)) & 1 != 0;
}

pub inline fn isHalf(laneNotes: data.LaneNotes, slot: usize) bool {
    const noteU128 = getNoteU128(laneNotes, slot);
    const offset = getNoteOffset(slot);
    return (noteU128 >> @intCast(offset + 1)) & 1 != 0;
}

pub inline fn connected(laneNotes: data.LaneNotes, slot: usize) bool {
    const noteU128 = getNoteU128(laneNotes, slot);
    const offset = getNoteOffset(slot);
    return (noteU128 >> @intCast(offset + 2)) & 1 != 0;
}
pub fn holdLen(laneNotes: data.LaneNotes, slot: usize) u16 {
    var len: u16 = 1;
    var s = slot;
    while (s + 1 < SLOTS and connected(laneNotes, s + 1)) : (s += 1) len += 1;
    return len;
}
pub fn updateStars(state: *data.GameState) void {
    if (state.comboCount == 0) {
        state.starCount = 0;
        state.starPowerComboComplete = false;
    } else {
        state.starCount = @intCast(@min(5, 1 + (state.comboCount - 1) / 10));
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
    state.longest_hold = 0;
    for (0..5) |l| {
        for (0..SLOTS) |s| {
            if (present(state.notes[l], s)) {
                lastSlot = @max(lastSlot, s);
                if (connected(state.notes[l], s)) state.longest_hold = @max(state.longest_hold, holdLen(state.notes[l], s));
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
        state.hitMask = data.NO_HITS;
        state.missSlot = .{0} ** 5;
        state.holdActive = .{false} ** 5;
        state.holdStartBeat = .{0} ** 5;
        state.starPowerMeter = 0.0;
        state.starPowerActive = false;
        state.starPowerTimer = 0.0;
        state.starPowerComboComplete = false;
        state.resultsCountdown = -1.0;
        state.prevSong = state.songs.current;
        state.notes = if (state.songs.current) |song| song.notes else data.NO_NOTES;
        computeEndBeat(state);
        start_song_audio(state);
    }

    const dt = rl.getFrameTime();
    const bps = if (state.songs.current) |c| c.bps else 2.0;
    const offset = if (state.songs.current) |c| c.offset else 0;
    state.song_time += dt;
    sync_song_clock(state);
    state.beat = (state.song_time - offset - settings.delay) * bps;

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
                // The beat can step back (audio resync, delay changed while paused), so clamp at 0.
                const beatsHeld = @max(0, state.beat - state.holdStartBeat[l]);
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
            const sMin = slot_at(state.beat - HIT_WINDOW);
            const sMax = @min(SLOTS - 1, slot_at(state.beat + HIT_WINDOW) + 1);
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
                    state.holdSlot[l] = slot;
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
/// Generates meta.cfg for a song folder that has an mp3 but no chart yet.
fn auto_chart(io: std.Io, songs_dir: std.Io.Dir, name: []const u8) void {
    var dir = songs_dir.openDir(io, name, .{ .iterate = true }) catch return;
    defer dir.close(io);
    if (dir.access(io, "meta.cfg", .{})) |_| return else |_| {}
    const im = &data.import_state;
    if (im.phase != .idle and std.mem.eql(u8, std.fs.path.basename(im.folder_path()), name)) return;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".mp3")) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const song_dir = std.fmt.allocPrint(a, "songs/{s}", .{name}) catch return;
        const mp3_path = std.fmt.allocPrint(a, "{s}/{s}", .{ song_dir, entry.name }) catch return;
        std.debug.print("charting {s}\n", .{mp3_path});
        _ = chart.chart_song(a, io, mp3_path, song_dir, .{ .title = name }) catch |err| {
            std.debug.print("charting {s} failed: {t}\n", .{ mp3_path, err });
        };
        return;
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
        // Folder names must fit DiscoveredSong.folder; longer ones can't be addressed later.
        if (entry.name.len >= data.discovered[0].folder.len) continue;

        var songData = &data.discovered[data.discovered_count];
        songData.* = .{};
        data.discovered_count += 1;

        @memcpy(songData.folder[0..entry.name.len], entry.name);
        songData.folder[entry.name.len] = 0;

        auto_chart(io, songsDir, entry.name);

        var metaPathBuf: [256]u8 = undefined;
        const metaPath = std.fmt.bufPrintZ(&metaPathBuf, "songs/{s}/meta.cfg", .{entry.name}) catch {
            songData.title[0] = 0;
            songData.bps = 2.5;
            continue;
        };

        var metaBuf: [32 * 1024]u8 = undefined;
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
                } else if (std.mem.eql(u8, key, "offset")) {
                    songData.offset = std.fmt.parseFloat(f32, val) catch 0;
                } else {
                    // Parse notes_lane0 through notes_lane4
                    for (0..5) |lane| {
                        var laneKeyBuf: [32]u8 = undefined;
                        const laneKey = std.fmt.bufPrintZ(&laneKeyBuf, "notes_lane{d}", .{lane}) catch continue;
                        if (std.mem.eql(u8, key, laneKey)) {
                            var hexVals = std.mem.splitSequence(u8, val, ",");
                            for (0..chart.CHUNKS) |chunk| {
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
            const copyLen = @min(entry.name.len, songData.title.len - 1);
            std.mem.copyForwards(u8, songData.title[0..], entry.name[0..copyLen]);
            songData.title[copyLen] = 0;
        }
        find_audio(io, songsDir, entry.name, &songData.audio_path);

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

// ─ Song import ─────────────────────────────────────────────────────────────
const mp3notes = @import("mp3notes.zig");

/// Copies a dropped mp3 into a fresh songs/<name>/ folder and starts analyzing it in the background.
pub fn start_import(io: std.Io, path: []const u8, from: data.Screen) bool {
    const im = &data.import_state;
    if (im.phase == .analyzing) return false;
    cancel_import(io);
    im.return_screen = if (from == .import_song) im.return_screen else from;

    const stem = std.fs.path.stem(path);
    const title_len = @min(stem.len, im.title.len - 1);
    @memcpy(im.title[0..title_len], stem[0..title_len]);
    im.title[title_len] = 0;

    const cwd = std.Io.Dir.cwd();
    var n: usize = 1;
    while (true) : (n += 1) {
        const folder = if (n == 1)
            std.fmt.bufPrint(&im.folder, "songs/{s}", .{stem[0..title_len]})
        else
            std.fmt.bufPrint(&im.folder, "songs/{s}_{d}", .{ stem[0..title_len], n });
        im.folder_len = (folder catch return fail_import(error.NameTooLong)).len;
        if (cwd.access(io, im.folder_path(), .{})) |_| continue else |_| break;
    }

    const a = im.arena.allocator();
    const copy = chart.copy_into(a, io, path, im.folder_path()) catch |err| return fail_import(err);
    im.bytes = cwd.readFileAlloc(io, copy, a, .limited(1 << 30)) catch |err| return fail_import(err);
    im.phase = .analyzing;
    im.thread = std.Thread.spawn(.{}, import_worker, .{}) catch |err| return fail_import(err);
    return true;
}

fn import_worker() void {
    const im = &data.import_state;
    const a = im.arena.allocator();
    if (mp3notes.decode_mp3(a, im.bytes)) |audio| {
        im.analysis = mp3notes.analyze(a, audio, mp3notes.tempo_prior(null)) catch |err| blk: {
            im.err = err;
            break :blk null;
        };
    } else |err| im.err = err;
    im.done.store(true, .release);
}

fn fail_import(err: anyerror) bool {
    data.import_state.err = err;
    data.import_state.phase = .failed;
    return true;
}

/// Call every frame: picks up a finished analysis, or cleans up after a cancel.
pub fn poll_import(io: std.Io) void {
    const im = &data.import_state;
    if (im.phase != .analyzing or !im.done.load(.acquire)) return;
    if (im.thread) |t| t.join();
    im.thread = null;
    if (im.cancelled) {
        delete_import_folder(io);
        reset_import();
    } else {
        im.phase = if (im.analysis != null) .ready else .failed;
    }
}

pub fn import_preview() ?chart.Chart {
    const im = &data.import_state;
    const r = im.analysis orelse return null;
    return chart.build(r, .{ .role = im.role, .difficulty = im.difficulty });
}

/// Writes meta.cfg for the analyzed song; returns false if the import isn't ready or the write failed.
pub fn finish_import(io: std.Io) bool {
    const im = &data.import_state;
    const preview = import_preview() orelse return false;
    var path_buf: [160]u8 = undefined;
    const meta = std.fmt.bufPrint(&path_buf, "{s}/meta.cfg", .{im.folder_path()}) catch return false;
    chart.write_meta(io, meta, std.mem.sliceTo(&im.title, 0), preview) catch |err| return !fail_import(err);
    reset_import();
    data.song_select_needs_scan = true;
    return true;
}

/// Removes the copied song folder; if analysis is still running, cleanup happens when it finishes.
pub fn cancel_import(io: std.Io) void {
    const im = &data.import_state;
    if (im.phase == .analyzing) {
        im.cancelled = true;
        return;
    }
    delete_import_folder(io);
    reset_import();
}

fn delete_import_folder(io: std.Io) void {
    const im = &data.import_state;
    if (im.folder_len == 0) return;
    std.Io.Dir.cwd().deleteTree(io, im.folder_path()) catch {};
}

fn reset_import() void {
    const im = &data.import_state;
    _ = im.arena.reset(.free_all);
    im.phase = .idle;
    im.thread = null;
    im.done.store(false, .release);
    im.bytes = &.{};
    im.analysis = null;
    im.err = null;
    im.cancelled = false;
    im.folder_len = 0;
}

// ─ Song audio ──────────────────────────────────────────────────────────────
const AUDIO_EXTENSIONS = [_][]const u8{ ".mp3", ".ogg", ".wav", ".flac", ".qoa" };
/// Drift between the song clock and the audio position that is snapped instead of smoothed.
const DRIFT_SNAP = 0.1;
const DRIFT_SMOOTHING = 0.05;

/// Finds the first playable audio file in songs/<name>/ and writes its path into `out`.
fn find_audio(io: std.Io, songs_dir: std.Io.Dir, name: []const u8, out: *[256:0]u8) void {
    out[0] = 0;
    var dir = songs_dir.openDir(io, name, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        for (AUDIO_EXTENSIONS) |ext| if (std.ascii.endsWithIgnoreCase(entry.name, ext)) {
            _ = std.fmt.bufPrintZ(out, "songs/{s}/{s}", .{ name, entry.name }) catch {
                out[0] = 0;
            };
            return;
        };
    }
}

/// Loads the current song's audio and rewinds the clock to the start of the lead-in.
fn start_song_audio(state: *data.GameState) void {
    stop_song_audio(state);
    const song = state.songs.current orelse return;
    // Lead-in long enough for the first notes to scroll down from the horizon.
    state.song_time = -SCROLL_BEATS / song.bps;
    const path = std.mem.sliceTo(&song.audio_path, 0);
    if (path.len == 0) return;
    var music = rl.loadMusicStream(song.audio_path[0..path.len :0]) catch {
        std.debug.print("could not load audio {s}\n", .{path});
        return;
    };
    music.looping = false;
    state.music = music;
}

pub fn stop_song_audio(state: *data.GameState) void {
    if (state.music) |m| {
        rl.stopMusicStream(m);
        rl.unloadMusicStream(m);
    }
    state.music = null;
    state.music_started = false;
    state.music_paused = false;
}

/// Starts the music when the lead-in ends, then keeps the song clock locked to the audio position.
fn sync_song_clock(state: *data.GameState) void {
    const m = state.music orelse return;
    if (!state.music_started) {
        if (state.song_time < 0) return;
        rl.playMusicStream(m);
        state.music_started = true;
        return;
    }
    if (state.music_paused or !rl.isMusicStreamPlaying(m)) return;
    // getMusicTimePlayed advances in buffer-sized steps, so smooth small differences.
    const drift = rl.getMusicTimePlayed(m) - state.song_time;
    if (@abs(drift) > DRIFT_SNAP) state.song_time += drift else state.song_time += drift * DRIFT_SMOOTHING;
}

/// Call every frame: feeds the audio stream, mirrors the pause state, and stops audio off the game screen.
pub fn update_audio(state: *data.GameState, screen: data.Screen) void {
    const m = state.music orelse return;
    if (screen != .game) return stop_song_audio(state);
    if (state.music_started) {
        if (state.paused and !state.music_paused) {
            rl.pauseMusicStream(m);
            state.music_paused = true;
        } else if (!state.paused and state.music_paused) {
            rl.resumeMusicStream(m);
            state.music_paused = false;
        }
    }
    rl.updateMusicStream(m);
}
