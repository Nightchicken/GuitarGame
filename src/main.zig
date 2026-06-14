const rl = @import("raylib");
const std = @import("std");
const widgets = @import("widgets.zig");
const data = @import("data.zig");
const systems = @import("systems.zig");
const render = @import("render.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

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

    state.songs.append("Demo Song", "", 2.5);

    // Lane 0: regular taps and holds
    state.notes[0][0] = (1 << 6) | (1 << 15) | (1 << 24) | (1 << 33) |
        (@as(u128, 0b101) << 36) | (@as(u128, 0b100) << 39) | (@as(u128, 0b100) << 42) |
        (1 << 51) | (1 << 60) | (1 << 69) | (1 << 78) | (1 << 87) | (1 << 96) | (1 << 105) | (1 << 114);
    state.notes[0][1] = (1 << 3) | (1 << 12) | (1 << 21) | (1 << 30) | (1 << 39) | (1 << 48) | (1 << 57) | (1 << 66) | (1 << 75) | (1 << 84);
    state.notes[0][2] = (1 << 9) | (1 << 18) | (1 << 27) | (1 << 36) | (1 << 45) | (1 << 54) | (1 << 63) | (1 << 72) | (1 << 81) | (1 << 90);
    state.notes[0][3] = (1 << 6) | (1 << 15) | (1 << 24) | (1 << 33) | (1 << 42) | (1 << 51) | (1 << 60) | (1 << 69) | (1 << 78);
    state.notes[0][4] = (1 << 0) | (1 << 9) | (1 << 18) | (1 << 27) | (1 << 36) | (1 << 45) | (1 << 54) | (1 << 63) | (1 << 72);
    state.notes[0][5] = (1 << 3) | (1 << 12) | (1 << 21) | (1 << 30) | (1 << 39) | (1 << 48) | (1 << 57) | (1 << 66) | (1 << 75);
    state.notes[0][6] = (1 << 6) | (1 << 15) | (1 << 24) | (1 << 33) | (1 << 42) | (1 << 51) | (1 << 60) | (1 << 69);
    state.notes[0][7] = (1 << 0) | (1 << 9) | (1 << 18) | (1 << 27) | (1 << 36) | (1 << 45) | (1 << 54) | (1 << 63);

    // Lane 1: alternating pattern
    state.notes[1][0] = (1 << 9) | (1 << 27) | (1 << 45) | (1 << 63) | (1 << 81) | (1 << 99) | (1 << 117);
    state.notes[1][1] = (1 << 6) | (1 << 24) | (1 << 42) | (1 << 60) | (1 << 78) | (1 << 96) | (1 << 114);
    state.notes[1][2] = (1 << 3) | (1 << 21) | (1 << 39) | (1 << 57) | (1 << 75) | (1 << 93) | (1 << 111);
    state.notes[1][3] = (1 << 12) | (1 << 30) | (1 << 48) | (1 << 66) | (1 << 84) | (1 << 102);
    state.notes[1][4] = (1 << 9) | (1 << 27) | (1 << 45) | (1 << 63) | (1 << 81) | (1 << 99) | (1 << 117);
    state.notes[1][5] = (1 << 0) | (1 << 18) | (1 << 36) | (1 << 54) | (1 << 72) | (1 << 90) | (1 << 108);
    state.notes[1][6] = (1 << 6) | (1 << 24) | (1 << 42) | (1 << 60) | (1 << 78) | (1 << 96) | (1 << 114);
    state.notes[1][7] = (1 << 12) | (1 << 30) | (1 << 48) | (1 << 66) | (1 << 84) | (1 << 102);

    // Lane 2: sparse pattern
    state.notes[2][0] = (1 << 3) | (1 << 30) | (1 << 57) | (1 << 84) | (1 << 111);
    state.notes[2][1] = (1 << 18) | (1 << 45) | (1 << 72) | (1 << 99);
    state.notes[2][2] = (1 << 9) | (1 << 36) | (1 << 63) | (1 << 90) | (1 << 117);
    state.notes[2][3] = (1 << 0) | (1 << 27) | (1 << 54) | (1 << 81) | (1 << 108);
    state.notes[2][4] = (1 << 21) | (1 << 48) | (1 << 75) | (1 << 102);
    state.notes[2][5] = (1 << 12) | (1 << 39) | (1 << 66) | (1 << 93) | (1 << 120);
    state.notes[2][6] = (1 << 3) | (1 << 30) | (1 << 57) | (1 << 84) | (1 << 111);
    state.notes[2][7] = (1 << 18) | (1 << 45) | (1 << 72) | (1 << 99);

    state.prevSong = state.songs.current;

    gameLoop: while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 25, .g = 25, .b = 35, .a = 255 });

        if (screen == .game and !state.paused) systems.update(&state, &settings);

        screen = switch (screen) {
            .main => render.drawMain(&ui),
            .settings => render.drawSettings(&ui, io, &settings),
            .songSelect => render.drawSongSelect(&ui, io, &state),
            .game => render.drawGame(&ui, io, &state, &settings),
            .results => render.drawResults(&ui, &state),
            .exit => break :gameLoop,
        };
    }
}
