const rl = @import("raylib");
const std = @import("std");
const widgets = @import("widgets.zig");
const data = @import("data.zig");
const systems = @import("systems.zig");
const render = @import("render.zig");
const analysis = @import("analysis.zig");
const chart = @import("chart.zig");
const mp3notes = @import("mp3notes.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--analyze")) return runAnalyze(init, &args);
        if (std.mem.eql(u8, flag, "--chart")) return run_chart(init, &args);
        if (std.mem.eql(u8, flag, "--transcribe")) return run_transcribe(init, &args);
    }

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(800, 600, "Guitar Game");
    rl.setWindowMinSize(500, 400);
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.setExitKey(.null);

    var ui = widgets.WidgetStream{};
    var screen: data.Screen = .main;
    var state = data.GameState{};
    var settings = data.Settings{};

    systems.loadSettings(io, &settings);
    systems.loadUiTheme(io);

    gameLoop: while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 25, .g = 25, .b = 35, .a = 255 });

        if (screen == .game and !state.paused) systems.update(&state, &settings);
        if (screen != .game) screen = handle_drop(io, screen);
        systems.poll_import(io);

        screen = switch (screen) {
            .main => render.drawMain(&ui),
            .settings => render.drawSettings(&ui, io, &settings),
            .songSelect => render.drawSongSelect(&ui, io, &state),
            .game => render.drawGame(&ui, io, &state, &settings),
            .results => render.drawResults(&ui, &state),
            .import_song => render.draw_import(&ui, io),
            .exit => break :gameLoop,
        };
    }
}

fn runAnalyze(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const input = args.next() orelse {
        std.debug.print("usage: guitarGame --analyze <song.mp3> [out.txt]\n", .{});
        return error.MissingArgument;
    };
    const output = args.next() orelse blk: {
        const ext = std.fs.path.extension(input);
        break :blk try std.fmt.allocPrint(init.arena.allocator(), "{s}.txt", .{input[0 .. input.len - ext.len]});
    };

    rl.setTraceLogLevel(.warning);
    var result = try analysis.analyzeFile(init.gpa, input);
    defer result.deinit();
    try analysis.writeReport(init.io, &result, input, output);

    std.debug.print("bpm {d:.1}  duration {d:.1}s\n", .{ result.bpm, result.duration });
    for (result.instruments) |inst| {
        std.debug.print("  {s:<7} energy {d:.2}  active {d:.2}  notes {d}\n", .{ inst.name, inst.energyShare, inst.activeRatio, inst.notes.len });
    }
    std.debug.print("wrote {s}\n", .{output});
}

const CHART_USAGE =
    \\usage: guitarGame --chart <song.mp3> [song_dir] [--instrument bass|melody|harmony] [--difficulty easy|medium|hard|expert] [--bpm-hint BPM] [--title TITLE]
    \\  song_dir defaults to songs/<song name>
    \\
;

fn run_chart(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const a = init.arena.allocator();
    var input: ?[]const u8 = null;
    var song_dir: ?[]const u8 = null;
    var opts = chart.Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--instrument")) {
            const v = args.next() orelse return usage_error(CHART_USAGE);
            opts.build.role = std.meta.stringToEnum(chart.Role, v) orelse return usage_error(CHART_USAGE);
        } else if (std.mem.eql(u8, arg, "--difficulty")) {
            const v = args.next() orelse return usage_error(CHART_USAGE);
            opts.build.difficulty = std.meta.stringToEnum(chart.Difficulty, v) orelse return usage_error(CHART_USAGE);
        } else if (std.mem.eql(u8, arg, "--bpm-hint")) {
            const v = args.next() orelse return usage_error(CHART_USAGE);
            opts.bpm_hint = std.fmt.parseFloat(f32, v) catch return usage_error(CHART_USAGE);
            if (opts.bpm_hint.? < mp3notes.TEMPO_MIN or opts.bpm_hint.? > mp3notes.TEMPO_MAX) return usage_error(CHART_USAGE);
        } else if (std.mem.eql(u8, arg, "--title")) {
            opts.title = args.next() orelse return usage_error(CHART_USAGE);
        } else if (input == null) {
            input = arg;
        } else if (song_dir == null) {
            song_dir = arg;
        } else return usage_error(CHART_USAGE);
    }
    const in_path = input orelse return usage_error(CHART_USAGE);
    const dir = song_dir orelse try std.fmt.allocPrint(a, "songs/{s}", .{std.fs.path.stem(in_path)});

    const c = try chart.chart_song(a, init.io, in_path, dir, opts);
    std.debug.print("bpm {d:.1}  offset {d:.3}s\n", .{ c.bps * 60, c.offset });
    for (std.enums.values(chart.Role)) |role| {
        std.debug.print("  {s:<8} prevalence {d:.2}{s}\n", .{ @tagName(role), c.prevalence[@intFromEnum(role)], if (role == c.role) "  <- charted" else "" });
    }
    std.debug.print("{d} notes ({s}), wrote {s}/meta.cfg\n", .{ c.note_count, @tagName(c.difficulty), dir });
}

fn run_transcribe(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const usage = "usage: guitarGame --transcribe <song.mp3> [out.txt]\n";
    const a = init.arena.allocator();
    const input = args.next() orelse return usage_error(usage);
    const output = args.next() orelse try std.fmt.allocPrint(a, "{s}.txt", .{input[0 .. input.len - std.fs.path.extension(input).len]});

    const r = try mp3notes.analyze_file(a, init.io, input, null);
    try mp3notes.write_report(init.io, output, input, r.audio, r.analysis);
    std.debug.print("wrote {s}\n", .{output});
}

fn usage_error(comptime usage: []const u8) error{InvalidArgument} {
    std.debug.print(usage, .{});
    return error.InvalidArgument;
}

/// Starts importing the first dropped .mp3 and switches to the import screen.
fn handle_drop(io: std.Io, screen: data.Screen) data.Screen {
    if (!rl.isFileDropped()) return screen;
    const files = rl.loadDroppedFiles();
    defer rl.unloadDroppedFiles(files);
    for (files.paths[0..files.count]) |p| {
        const path = std.mem.span(p);
        if (!std.ascii.endsWithIgnoreCase(path, ".mp3")) continue;
        return if (systems.start_import(io, path, screen)) .import_song else screen;
    }
    return screen;
}
