const std = @import("std");
const rl = @import("raylib");
const widgets = @import("widgets.zig");
const chart = @import("chart.zig");
const mp3notes = @import("mp3notes.zig");

pub const MAX_SONGS: usize = 32;
pub const LaneNotes = chart.LaneNotes;
pub const NO_NOTES: [5]LaneNotes = .{.{0} ** chart.CHUNKS} ** 5;
pub const HIT_WORDS = (chart.SLOTS + 63) / 64;
pub const NO_HITS: [5][HIT_WORDS]u64 = .{.{0} ** HIT_WORDS} ** 5;
pub const SongNode = struct {
    title: [:0]const u8,
    file_path: [:0]const u8,
    bps: f32,
    notes: [5]LaneNotes = NO_NOTES,
    prev: ?*SongNode,
    next: ?*SongNode,
};
// Doubly linked list backed by a fixed-size pool — no allocator needed.
pub const SongList = struct {
    pool: [MAX_SONGS]SongNode = undefined,
    poolLen: usize = 0,
    head: ?*SongNode = null,
    tail: ?*SongNode = null,
    current: ?*SongNode = null,

    pub fn append(self: *SongList, title: [:0]const u8, file_path: [:0]const u8, bps: f32) void {
        if (self.poolLen >= MAX_SONGS) return;
        const node = &self.pool[self.poolLen];
        self.poolLen += 1;
        node.* = .{ .title = title, .file_path = file_path, .bps = bps, .prev = self.tail, .next = null };
        if (self.tail) |t| t.next = node else self.head = node;
        self.tail = node;
        if (self.current == null) self.current = node;
    }

    pub fn remove(self: *SongList, node: *SongNode) void {
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        if (self.current == node) self.current = node.next orelse node.prev;
        node.prev = null;
        node.next = null;
    }

    // Unlink node and insert it immediately before target.
    pub fn moveBefore(self: *SongList, node: *SongNode, target: *SongNode) void {
        if (node == target) return;
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = target.prev;
        node.next = target;
        if (target.prev) |p| p.next = node else self.head = node;
        target.prev = node;
    }

    // Unlink node and move it to the end.
    pub fn moveToEnd(self: *SongList, node: *SongNode) void {
        if (node == self.tail) return;
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = self.tail;
        node.next = null;
        if (self.tail) |t| t.next = node else self.head = node;
        self.tail = node;
    }

    pub fn currentTitle(self: *const SongList) [:0]const u8 {
        const c = self.current orelse return "No Song";
        return c.title;
    }

    pub fn prevTitle(self: *const SongList) ?[:0]const u8 {
        const c = self.current orelse return null;
        const p = c.prev orelse return null;
        return p.title;
    }

    pub fn nextTitle(self: *const SongList) ?[:0]const u8 {
        const c = self.current orelse return null;
        const n = c.next orelse return null;
        return n.title;
    }

    pub fn goPrev(self: *SongList) void {
        const c = self.current orelse return;
        const p = c.prev orelse return;
        self.current = p;
    }

    pub fn goNext(self: *SongList) void {
        const c = self.current orelse return;
        const n = c.next orelse return;
        self.current = n;
    }
    pub fn reset(self: *SongList) void {
        self.poolLen = 0;
        self.head = null;
        self.tail = null;
        self.current = null;
    }
};
pub const Settings = struct {
    keys: [6]rl.KeyboardKey = .{ rl.KeyboardKey.a, rl.KeyboardKey.s, rl.KeyboardKey.d, rl.KeyboardKey.f, rl.KeyboardKey.space, rl.KeyboardKey.v },
    delay: f32 = 0.25,
    colors: [7]rl.Color = .{
        .{ .r = 0, .g = 200, .b = 50, .a = 255 }, // green  — Key1
        .{ .r = 210, .g = 30, .b = 30, .a = 255 }, // red    — Key2
        .{ .r = 220, .g = 210, .b = 0, .a = 255 }, // yellow — Key3
        .{ .r = 30, .g = 80, .b = 220, .a = 255 }, // blue   — Key4
        .{ .r = 230, .g = 130, .b = 0, .a = 255 }, // orange — Key5
        .{ .r = 255, .g = 255, .b = 255, .a = 100 }, // pink — Held
        .{ .r = 230, .g = 130, .b = 0, .a = 255 }, // pink — Star
    },
};
pub const GameState = struct {
    paused: bool = false,
    showing_queue: bool = false,
    showing_settings: bool = false,
    songs: SongList = .{},
    notes: [5]LaneNotes = NO_NOTES,
    starMultiplier: u8 = 1,
    starCount: u8 = 1,
    comboCount: u32 = 0,
    score: u32 = 0,
    beat: f32 = 0,
    hitMask: [5][HIT_WORDS]u64 = NO_HITS,
    missSlot: [5]usize = .{0} ** 5,
    holdActive: [5]bool = .{false} ** 5,
    holdSlot: [5]usize = .{0} ** 5,
    holdLen: [5]u16 = .{0} ** 5,
    holdStartBeat: [5]f32 = .{0} ** 5,
    prevSong: ?*SongNode = null,
    starPowerMeter: f32 = 0.0,
    starPowerActive: bool = false,
    starPowerTimer: f32 = 0.0,
    starPowerComboComplete: bool = false,
    maxCombo: u32 = 0,
    endBeat: f32 = 0,
    resultsCountdown: f32 = -1.0,
};
pub const NoteStats = struct {
    total: u32,
    hits: u32,
};
pub const UiTheme = struct {
    bg: rl.Color = .{ .r = 25, .g = 25, .b = 35, .a = 255 },
    section: rl.Color = .{ .r = 120, .g = 170, .b = 255, .a = 255 },
    btn: rl.Color = .{ .r = 130, .g = 130, .b = 130, .a = 255 },
    btnHover: rl.Color = .{ .r = 200, .g = 200, .b = 200, .a = 255 },
    btnPress: rl.Color = .{ .r = 80, .g = 80, .b = 80, .a = 255 },
    keyBtn: rl.Color = .{ .r = 40, .g = 60, .b = 100, .a = 255 },
    keyBtnHover: rl.Color = .{ .r = 60, .g = 90, .b = 140, .a = 255 },
    keyBtnPress: rl.Color = .{ .r = 28, .g = 42, .b = 70, .a = 255 },
};
pub var theme = UiTheme{};
pub const Screen = enum { main, settings, songSelect, game, results, import_song, exit };
// Persistent overlay state (lives here, not in GameState, because it's purely UI).
pub var queueOverlay = widgets.DragListOverlay{};
// Song select screen state
pub const MAX_DISCOVERED = 64;
pub const DiscoveredSong = struct {
    title: [64:0]u8 = undefined,
    folder: [128:0]u8 = undefined,
    bps: f32 = 2.5,
    selected: bool = false,
    texture: rl.Texture2D = undefined,
    has_texture: bool = false,
    notes: [5]LaneNotes = NO_NOTES,
};
pub var discovered: [MAX_DISCOVERED]DiscoveredSong = undefined;
pub var discovered_count: usize = 0;
pub var song_scroll_y: f32 = 0.0;
pub var song_select_needs_scan: bool = true;
// Song select drag-reorder state
pub var drag_song_ID: ?usize = null;
pub var drag_start_y: f32 = 0.0;
// Results screen state
pub const ResultsUiState = struct {
    fresh: bool = true,
    max_score: u32 = 0,
    stats: NoteStats = .{ .total = 0, .hits = 0 },
};
pub var resultsState = ResultsUiState{};
// ─ Settings UI State ──────────────────────────────────────────────────────
pub const SettingsUiState = struct {
    rebinding_slot: ?usize = null,
    selected_color: ?usize = null,
    prev_selected_color: ?usize = null,
    colR: f32 = 0,
    colG: f32 = 0,
    colB: f32 = 0,
    colA: f32 = 255,
    save_msg_timer: f32 = 0,
};
pub var settings_state = SettingsUiState{};
pub var slot_indices = [6]usize{ 0, 1, 2, 3, 4, 5 };
// Song import (drag-and-drop an mp3 onto the window)
pub const ImportPhase = enum { idle, analyzing, ready, failed };
pub const ImportState = struct {
    phase: ImportPhase = .idle,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    thread: ?std.Thread = null,
    // Written by the worker thread before `done` is set.
    done: std.atomic.Value(bool) = .init(false),
    bytes: []const u8 = &.{},
    analysis: ?mp3notes.Analysis = null,
    err: ?anyerror = null,
    cancelled: bool = false,
    folder: [128]u8 = undefined,
    folder_len: usize = 0,
    title: [64:0]u8 = .{0} ** 64,
    role: ?chart.Role = null,
    difficulty: chart.Difficulty = .hard,
    return_screen: Screen = .songSelect,

    pub fn folder_path(self: *const ImportState) []const u8 {
        return self.folder[0..self.folder_len];
    }
};
pub var import_state = ImportState{};
