//! Turns an mp3notes transcription into a playable 5-lane chart (meta.cfg).
//! One slot = one beat of the detected tempo (half a beat on expert); slot 0 sits `offset` seconds into the song.

const std = @import("std");
const mp3notes = @import("mp3notes.zig");
const Allocator = std.mem.Allocator;

pub const LANES = 5;
pub const SLOTS = 4096;
pub const SLOTS_PER_CHUNK = 42;
pub const CHUNKS = (SLOTS + SLOTS_PER_CHUNK - 1) / SLOTS_PER_CHUNK;
pub const LaneNotes = [CHUNKS]u128;
const HOLD_MIN_BEATS = 2;

const BIT_PRESENT: u128 = 0b001;
const BIT_CONNECTED: u128 = 0b100;

pub const Role = enum { bass, melody, harmony };

pub const Difficulty = enum {
    easy,
    medium,
    hard,
    expert,

    const Params = struct {
        lanes: usize,
        max_chord: usize,
        /// Drop notes quieter than this fraction of the role's notes.
        quiet_cut: f32,
        /// Minimum slots between notes (any lane).
        min_gap: usize,
        /// Slots per beat.
        subdivision: usize,
    };

    pub fn params(d: Difficulty) Params {
        return switch (d) {
            .easy => .{ .lanes = 3, .max_chord = 1, .quiet_cut = 0.5, .min_gap = 2, .subdivision = 1 },
            .medium => .{ .lanes = 4, .max_chord = 1, .quiet_cut = 0.25, .min_gap = 1, .subdivision = 1 },
            .hard => .{ .lanes = 5, .max_chord = 2, .quiet_cut = 0, .min_gap = 1, .subdivision = 1 },
            .expert => .{ .lanes = 5, .max_chord = 2, .quiet_cut = 0, .min_gap = 1, .subdivision = 2 },
        };
    }
};

pub const Chart = struct {
    bps: f32,
    offset: f32,
    role: Role,
    difficulty: Difficulty,
    prevalence: [3]f32,
    notes: [LANES]LaneNotes = .{.{0} ** CHUNKS} ** LANES,
    note_count: usize = 0,
};

pub const BuildOptions = struct {
    role: ?Role = null,
    difficulty: Difficulty = .hard,
};

pub const Options = struct {
    build: BuildOptions = .{},
    bpm_hint: ?f32 = null,
    title: ?[]const u8 = null,
};

const Grid = struct {
    period: f32,
    offset: f32,

    fn slot(g: Grid, t: f32) i64 {
        return @intFromFloat(@round((t - g.offset) / g.period));
    }
};

/// Fits a fixed-tempo grid to the tracked beats, with slot 0 within one beat of the song start.
fn fit_grid(r: mp3notes.Analysis, subdivision: usize) Grid {
    const beat = 60.0 / r.bpm;
    const period = beat / @as(f32, @floatFromInt(subdivision));
    if (r.beats.len == 0) return .{ .period = period, .offset = 0 };
    var sum: f32 = 0;
    for (r.beats, 0..) |b, i| sum += b - @as(f32, @floatFromInt(i)) * beat;
    const intercept = sum / @as(f32, @floatFromInt(r.beats.len));
    return .{ .period = period, .offset = intercept - @floor(intercept / beat) * beat };
}

fn role_notes(r: mp3notes.Analysis, role: Role) []const mp3notes.Note {
    return switch (role) {
        .bass => r.bass,
        .melody => r.melody,
        .harmony => r.harmony,
    };
}

/// Velocity-weighted sounding time as a fraction of the song length.
fn prevalence(notes: []const mp3notes.Note, duration: f32) f32 {
    var sum: f32 = 0;
    for (notes) |n| sum += (n.end - n.start) * n.velocity;
    return if (duration > 0) sum / duration else 0;
}

pub fn prevalences(r: mp3notes.Analysis) [3]f32 {
    var prev: [3]f32 = undefined;
    for (std.enums.values(Role)) |role| prev[@intFromEnum(role)] = prevalence(role_notes(r, role), r.duration);
    return prev;
}

pub fn most_prevalent(prev: [3]f32) Role {
    var best: Role = .bass;
    for (std.enums.values(Role)) |role| {
        if (prev[@intFromEnum(role)] > prev[@intFromEnum(best)]) best = role;
    }
    return best;
}

/// Velocity below which `fraction` of the notes fall (histogram over 0..1).
fn velocity_cut(notes: []const mp3notes.Note, fraction: f32) f32 {
    if (fraction <= 0 or notes.len == 0) return 0;
    var hist = [_]usize{0} ** 100;
    for (notes) |n| hist[@intFromFloat(std.math.clamp(n.velocity * 100, 0, 99))] += 1;
    const target: usize = @intFromFloat(fraction * @as(f32, @floatFromInt(notes.len)));
    var below: usize = 0;
    for (hist, 0..) |h, i| {
        below += h;
        if (below > target) return @as(f32, @floatFromInt(i)) / 100;
    }
    return 1;
}

/// Pitch -> lane by rank among the distinct pitches played, so the contour spreads over all lanes.
fn lane_map(notes: []const mp3notes.Note, lanes_used: usize) [128]u8 {
    var used = [_]bool{false} ** 128;
    for (notes) |n| used[n.pitch & 0x7f] = true;
    var distinct: usize = 0;
    for (used) |u| distinct += @intFromBool(u);
    var lanes = [_]u8{0} ** 128;
    var rank: usize = 0;
    for (used, 0..) |u, p| if (u) {
        lanes[p] = @intCast(rank * lanes_used / distinct);
        rank += 1;
    };
    return lanes;
}

fn set_bits(lane: *LaneNotes, s: usize, bits: u128) void {
    lane[s / SLOTS_PER_CHUNK] |= bits << @intCast((s % SLOTS_PER_CHUNK) * 3);
}

pub fn build(r: mp3notes.Analysis, opts: BuildOptions) Chart {
    const p = opts.difficulty.params();
    const g = fit_grid(r, p.subdivision);
    const prev = prevalences(r);
    const role = opts.role orelse most_prevalent(prev);
    const notes = role_notes(r, role);
    const lanes = lane_map(notes, p.lanes);
    const min_velocity = velocity_cut(notes, p.quiet_cut);

    const Cell = struct { velocity: f32 = 0, len: u32 = 0 };
    var cells: [SLOTS][LANES]Cell = .{.{Cell{}} ** LANES} ** SLOTS;
    for (notes) |n| {
        if (n.velocity < min_velocity) continue;
        const s = g.slot(n.start);
        if (s < 0 or s >= SLOTS) continue;
        const len: u32 = @intFromFloat(@min(SLOTS, @max(1, @round((n.end - n.start) / g.period))));
        const cell = &cells[@intCast(s)][lanes[n.pitch & 0x7f]];
        if (n.velocity > cell.velocity) cell.* = .{ .velocity = n.velocity, .len = len };
    }

    var last_kept: ?usize = null;
    for (&cells, 0..) |*row, s| {
        while (true) {
            var used: usize = 0;
            var weakest: usize = 0;
            for (row, 0..) |c, l| if (c.len > 0) {
                used += 1;
                if (row[weakest].len == 0 or c.velocity < row[weakest].velocity) weakest = l;
            };
            if (used == 0) break;
            if (last_kept) |k| if (s - k < p.min_gap) {
                row.* = .{Cell{}} ** LANES;
                break;
            };
            if (used <= p.max_chord) {
                last_kept = s;
                break;
            }
            row[weakest] = .{};
        }
    }

    var chart = Chart{
        .bps = r.bpm / 60.0 * @as(f32, @floatFromInt(p.subdivision)),
        .offset = g.offset,
        .role = role,
        .difficulty = opts.difficulty,
        .prevalence = prev,
    };
    const hold_min = HOLD_MIN_BEATS * p.subdivision;
    for (0..LANES) |l| {
        var s: usize = 0;
        while (s < SLOTS) : (s += 1) {
            const c = cells[s][l];
            if (c.len == 0) continue;
            chart.note_count += 1;
            var next = s + 1;
            while (next < SLOTS and cells[next][l].len == 0) next += 1;
            // Leave an empty slot before the next note so holdLen doesn't run into it.
            const tail_end = @min(s + c.len - 1, next -| 2, SLOTS - 1);
            if (c.len >= hold_min and tail_end > s) {
                set_bits(&chart.notes[l], s, BIT_PRESENT | BIT_CONNECTED);
                for (s + 1..tail_end + 1) |t| set_bits(&chart.notes[l], t, BIT_CONNECTED);
            } else {
                set_bits(&chart.notes[l], s, BIT_PRESENT);
            }
        }
    }
    return chart;
}

pub fn write_meta(io: std.Io, path: []const u8, title: []const u8, chart: Chart) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.print("title={s}\nbps={d:.4}\noffset={d:.3}\ninstrument={s}\ndifficulty={s}\n", .{
        title, chart.bps, chart.offset, @tagName(chart.role), @tagName(chart.difficulty),
    });
    for (chart.notes, 0..) |lane, l| {
        try w.print("notes_lane{d}=", .{l});
        // Trailing empty chunks are omitted; the parser leaves missing chunks at zero.
        var used: usize = CHUNKS;
        while (used > 1 and lane[used - 1] == 0) used -= 1;
        for (lane[0..used], 0..) |chunk, i| try w.print("{s}0x{x}", .{ if (i == 0) "" else ",", chunk });
        try w.print("\n", .{});
    }
    try w.flush();
}

/// Copies `mp3_path` into `song_dir` unless it already lives there; returns the path of the copy.
pub fn copy_into(a: Allocator, io: std.Io, mp3_path: []const u8, song_dir: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, song_dir);
    const dest = try std.fs.path.join(a, &.{ song_dir, std.fs.path.basename(mp3_path) });
    const src_dir = std.fs.path.dirname(mp3_path) orelse ".";
    if (!std.mem.eql(u8, try std.fs.path.resolve(a, &.{src_dir}), try std.fs.path.resolve(a, &.{song_dir}))) {
        try cwd.copyFile(mp3_path, cwd, dest, io, .{});
    }
    return dest;
}

/// Analyzes `mp3_path` and writes `<song_dir>/meta.cfg`, copying the mp3 into `song_dir` if it lives elsewhere.
pub fn chart_song(a: Allocator, io: std.Io, mp3_path: []const u8, song_dir: []const u8, opts: Options) !Chart {
    const result = try mp3notes.analyze_file(a, io, mp3_path, opts.bpm_hint);
    const chart = build(result.analysis, opts.build);
    _ = try copy_into(a, io, mp3_path, song_dir);
    const meta = try std.fs.path.join(a, &.{ song_dir, "meta.cfg" });
    try write_meta(io, meta, opts.title orelse std.fs.path.stem(mp3_path), chart);
    return chart;
}
