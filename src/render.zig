const std = @import("std");
const rl = @import("raylib");
const widgets = @import("widgets.zig");
const data = @import("data.zig");
const chart = @import("chart.zig");
const systems = @import("systems.zig");

pub fn drawSongSelect(ui: *widgets.WidgetStream, io: std.Io, state: *data.GameState) data.Screen {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    if (data.song_select_needs_scan) {
        systems.scan_songs(io);
        data.song_scroll_y = 0.0;
        data.song_select_needs_scan = false;
        for (data.discovered[0..data.discovered_count]) |*d| {
            d.selected = false;
        }
    }

    const header_h: f32 = 70;
    const footer_h: f32 = 50;
    const card_h: f32 = 110;
    const card_pad: f32 = 10;
    const img_size: f32 = 90;

    var back_pressed = false;
    var start_pressed = false;

    ui.begin();

    // Header
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = header_h }, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    const title = "Select Songs";
    const title_size: i32 = 36;
    const title_w = rl.measureText(title, title_size);
    rl.drawText(title, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(title_w)) / 2.0), @intFromFloat((header_h - @as(f32, @floatFromInt(title_size))) / 2.0), title_size, rl.Color.white);

    ui.button(.{ .x = 12, .y = header_h / 2.0 - 18, .width = 80, .height = 36 }, "< Back", .{ .func = setBool, .ctx = &back_pressed });

    var any_selected = false;
    for (data.discovered[0..data.discovered_count]) |d| {
        if (d.selected) {
            any_selected = true;
            break;
        }
    }

    ui.buttonStyled(
        .{ .x = sw - 92, .y = header_h / 2.0 - 18, .width = 80, .height = 36 },
        .{
            .label = "Start",
            .color = if (any_selected) .{ .r = 30, .g = 80, .b = 30, .a = 255 } else .{ .r = 60, .g = 60, .b = 60, .a = 255 },
            .hover_color = if (any_selected) .{ .r = 50, .g = 120, .b = 50, .a = 255 } else .{ .r = 80, .g = 80, .b = 80, .a = 255 },
            .press_color = if (any_selected) .{ .r = 20, .g = 55, .b = 20, .a = 255 } else .{ .r = 50, .g = 50, .b = 50, .a = 255 },
        },
        if (any_selected) .{ .func = setBool, .ctx = &start_pressed } else null,
    );

    // Scrollable content
    rl.beginScissorMode(0, @intFromFloat(header_h), @intFromFloat(sw), @intFromFloat(sh - header_h - footer_h));

    const content_h = @as(f32, @floatFromInt(data.discovered_count)) * (card_h + card_pad);
    const visible_h = sh - header_h - footer_h;
    const max_scroll = @max(0.0, content_h - visible_h);

    data.song_scroll_y -= rl.getMouseWheelMove() * 50.0;
    data.song_scroll_y = std.math.clamp(data.song_scroll_y, 0.0, max_scroll);

    // Handle drag-to-reorder
    const mouse = rl.getMousePosition();
    const mouse_pressed = rl.isMouseButtonPressed(.left);
    const mouse_down = rl.isMouseButtonDown(.left);
    const mouse_released = rl.isMouseButtonReleased(.left);

    if (mouse_released) {
        data.drag_song_ID = null;
    }

    if (data.discovered_count == 0) {
        rl.drawText("No songs found. Drop an .mp3 onto the window to import one.", @intFromFloat(20), @intFromFloat(header_h + 20), 20, .{ .r = 150, .g = 150, .b = 150, .a = 255 });
    } else {
        for (data.discovered[0..data.discovered_count], 0..) |*song, i| {
            const card_y = header_h + @as(f32, @floatFromInt(i)) * (card_h + card_pad) - data.song_scroll_y;

            if (card_y + card_h < header_h or card_y > sh - footer_h) continue;

            const card_rect = rl.Rectangle{ .x = 10, .y = card_y, .width = sw - 20, .height = card_h };
            const drag_handle_rect = rl.Rectangle{ .x = 10, .y = card_y, .width = 30, .height = card_h };
            const is_over_handle = rl.checkCollisionPointRec(mouse, drag_handle_rect);
            const is_dragging = data.drag_song_ID == i;

            // Drag start
            if (mouse_pressed and is_over_handle and data.drag_song_ID == null) {
                data.drag_song_ID = i;
                data.drag_start_y = mouse.y;
            }

            // Swap with other cards during drag
            if (is_dragging and mouse_down) {
                const delta_y = mouse.y - data.drag_start_y;
                if (@abs(delta_y) > (card_h + card_pad) / 2.0) {
                    if (delta_y > 0 and i + 1 < data.discovered_count) {
                        const temp = data.discovered[i];
                        data.discovered[i] = data.discovered[i + 1];
                        data.discovered[i + 1] = temp;
                        data.drag_song_ID = i + 1;
                        data.drag_start_y = mouse.y;
                    } else if (delta_y < 0 and i > 0) {
                        const temp = data.discovered[i];
                        data.discovered[i] = data.discovered[i - 1];
                        data.discovered[i - 1] = temp;
                        data.drag_song_ID = i - 1;
                        data.drag_start_y = mouse.y;
                    }
                }
            }

            // Draw card with drag feedback
            const card_color: rl.Color = if (is_dragging) .{ .r = 50, .g = 50, .b = 70, .a = 255 } else .{ .r = 35, .g = 35, .b = 45, .a = 255 };
            const border_color: rl.Color = if (is_dragging) .{ .r = 120, .g = 180, .b = 255, .a = 255 } else .{ .r = 80, .g = 80, .b = 100, .a = 200 };
            rl.drawRectangleRec(card_rect, card_color);
            rl.drawRectangleLinesEx(card_rect, if (is_dragging) 2.0 else 1.0, border_color);

            // Draw drag handle indicator
            rl.drawRectangleRec(drag_handle_rect, if (is_over_handle) .{ .r = 100, .g = 150, .b = 255, .a = 200 } else .{ .r = 50, .g = 70, .b = 100, .a = 150 });
            rl.drawText("⋮⋮", @intFromFloat(15), @intFromFloat(card_y + card_h / 2.0 - 10), 16, if (is_over_handle) rl.Color.white else .{ .r = 150, .g = 150, .b = 180, .a = 255 });

            const img_rect = rl.Rectangle{ .x = card_y + 10, .y = card_y + 10, .width = img_size, .height = img_size };
            if (song.has_texture) {
                rl.drawTexturePro(song.texture, .{ .x = 0, .y = 0, .width = @floatFromInt(song.texture.width), .height = @floatFromInt(song.texture.height) }, img_rect, .{ .x = 0, .y = 0 }, 0, rl.Color.white);
            } else {
                rl.drawRectangleRec(img_rect, .{ .r = 50, .g = 50, .b = 70, .a = 255 });
                rl.drawRectangleLinesEx(img_rect, 1.0, .{ .r = 100, .g = 100, .b = 120, .a = 255 });
            }

            const text_x = card_y + img_size + 20;
            const card_title_size: i32 = 22;
            rl.drawText(song.title[0..], @intFromFloat(text_x), @intFromFloat(card_y + 15), card_title_size, rl.Color.white);

            var bps_buf: [32]u8 = undefined;
            const bps_str = std.fmt.bufPrintZ(&bps_buf, "{d:.1} BPS", .{song.bps}) catch "? BPS";
            rl.drawText(bps_str, @intFromFloat(text_x), @intFromFloat(card_y + 45), 16, .{ .r = 180, .g = 180, .b = 180, .a = 255 });

            const checkbox_x = sw - 50;
            const checkbox_y = card_y + (card_h - 32) / 2.0;
            ui.checkbox(.{ .x = checkbox_x, .y = checkbox_y, .width = 32, .height = 32 }, "", &song.selected, null);
        }
    }

    rl.endScissorMode();

    // Footer
    rl.drawRectangleRec(.{ .x = 0, .y = sh - footer_h, .width = sw, .height = footer_h }, .{ .r = 20, .g = 20, .b = 30, .a = 255 });

    var selected_count: usize = 0;
    for (data.discovered[0..data.discovered_count]) |d| {
        if (d.selected) selected_count += 1;
    }
    var count_buf: [64]u8 = undefined;
    const count_str = std.fmt.bufPrintZ(&count_buf, "{d} song(s) selected", .{selected_count}) catch "? selected";
    const count_size: i32 = 16;
    const count_w = rl.measureText(count_str, count_size);
    rl.drawText(count_str, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(count_w)) / 2.0), @intFromFloat(sh - footer_h + (footer_h - @as(f32, @floatFromInt(count_size))) / 2.0), count_size, .{ .r = 180, .g = 180, .b = 180, .a = 255 });

    rl.drawText("Drop an .mp3 here to import", 12, @intFromFloat(sh - footer_h + (footer_h - 14) / 2.0), 14, .{ .r = 120, .g = 120, .b = 140, .a = 255 });

    ui.processAndDraw();

    if (back_pressed) {
        for (data.discovered[0..data.discovered_count]) |*d| {
            if (d.has_texture) {
                rl.unloadTexture(d.texture);
            }
        }
        data.discovered_count = 0;
        data.song_select_needs_scan = true;
        return .main;
    }

    if (start_pressed and any_selected) {
        state.songs.reset();
        // Pool slots are reused, so force update() to treat the first song as new.
        state.prevSong = null;
        for (data.discovered[0..data.discovered_count]) |*d| {
            if (d.selected) {
                if (state.songs.poolLen >= data.MAX_SONGS) break;
                state.songs.append(d.title[0..], d.folder[0..], d.bps);
                if (state.songs.tail) |tail| {
                    tail.notes = d.notes;
                    tail.audio_path = d.audio_path;
                    tail.offset = d.offset;
                }
            }
        }
        return .game;
    }

    return .songSelect;
}
pub fn drawResults(ui: *widgets.WidgetStream, state: *data.GameState) data.Screen {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    if (data.resultsState.fresh) {
        data.resultsState.max_score = systems.maxPossibleScore(state);
        data.resultsState.stats = systems.countNoteStats(state);
        data.resultsState.fresh = false;
    }

    var continue_pressed = false;

    // Background
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = sh }, .{ .r = 10, .g = 10, .b = 15, .a = 255 });

    // Title
    const title = "SONG COMPLETE";
    const title_size: i32 = 44;
    const title_w = rl.measureText(title, title_size);
    rl.drawText(title, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(title_w)) / 2.0), @intFromFloat(sh * 0.1), title_size, rl.Color.white);

    // Song title
    if (state.songs.current) |song| {
        const song_size: i32 = 28;
        const song_w = rl.measureText(song.title, song_size);
        rl.drawText(song.title, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(song_w)) / 2.0), @intFromFloat(sh * 0.18), song_size, .{ .r = 200, .g = 200, .b = 200, .a = 255 });
    }

    // Stats section
    const stats_y: f32 = sh * 0.35;
    const stats_size: i32 = 24;
    const label_size: i32 = 20;
    const line_h: f32 = 50;

    // Score
    rl.drawText("Score:", @intFromFloat(sw * 0.2), @intFromFloat(stats_y), label_size, .{ .r = 150, .g = 150, .b = 150, .a = 255 });
    var score_buf: [128]u8 = undefined;
    const score_str = std.fmt.bufPrintZ(&score_buf, "{d} / {d}", .{ state.score, data.resultsState.max_score }) catch "? / ?";
    const score_w = rl.measureText(score_str, stats_size);
    rl.drawText(score_str, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(score_w)) / 2.0), @intFromFloat(stats_y + 5), stats_size, rl.Color.white);

    // Score percentage
    var score_pct: f32 = 0.0;
    if (data.resultsState.max_score > 0) {
        score_pct = @as(f32, @floatFromInt(state.score)) / @as(f32, @floatFromInt(data.resultsState.max_score)) * 100.0;
    }
    var pct_buf: [32]u8 = undefined;
    const pct_str = std.fmt.bufPrintZ(&pct_buf, "({d:.0}%)", .{score_pct}) catch "(?)";
    const pct_w = rl.measureText(pct_str, label_size);
    rl.drawText(pct_str, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(pct_w)) / 2.0), @intFromFloat(stats_y + 35), label_size, .{ .r = 180, .g = 180, .b = 180, .a = 255 });

    // Max Combo
    const combo_y = stats_y + line_h * 2.0;
    rl.drawText("Max Combo:", @intFromFloat(sw * 0.2), @intFromFloat(combo_y), label_size, .{ .r = 150, .g = 150, .b = 150, .a = 255 });
    var combo_buf: [32]u8 = undefined;
    const combo_str = std.fmt.bufPrintZ(&combo_buf, "{d}", .{state.maxCombo}) catch "?";
    const combo_w = rl.measureText(combo_str, stats_size);
    rl.drawText(combo_str, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(combo_w)) / 2.0), @intFromFloat(combo_y + 5), stats_size, rl.Color.white);

    // Accuracy
    const acc_y = combo_y + line_h * 2.0;
    rl.drawText("Accuracy:", @intFromFloat(sw * 0.2), @intFromFloat(acc_y), label_size, .{ .r = 150, .g = 150, .b = 150, .a = 255 });
    var acc_pct: f32 = 0.0;
    if (data.resultsState.stats.total > 0) {
        acc_pct = @as(f32, @floatFromInt(data.resultsState.stats.hits)) / @as(f32, @floatFromInt(data.resultsState.stats.total)) * 100.0;
    }
    var acc_buf: [64]u8 = undefined;
    const acc_str = std.fmt.bufPrintZ(&acc_buf, "{d:.0}%  ({d}/{d} notes)", .{ acc_pct, data.resultsState.stats.hits, data.resultsState.stats.total }) catch "?(?)";
    const acc_w = rl.measureText(acc_str, stats_size);
    rl.drawText(acc_str, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(acc_w)) / 2.0), @intFromFloat(acc_y + 5), stats_size, rl.Color.white);

    ui.begin();
    ui.buttonStyled(
        .{ .x = sw / 2.0 - 60, .y = sh * 0.85, .width = 120, .height = 50 },
        .{
            .label = "Continue",
            .color = .{ .r = 30, .g = 80, .b = 30, .a = 255 },
            .hover_color = .{ .r = 50, .g = 120, .b = 50, .a = 255 },
            .press_color = .{ .r = 20, .g = 55, .b = 20, .a = 255 },
        },
        .{ .func = setBool, .ctx = &continue_pressed },
    );
    ui.processAndDraw();

    if (continue_pressed) {
        state.songs.goNext();
        data.resultsState.fresh = true;
        if (state.songs.current != null and state.songs.current != state.prevSong) {
            return .game;
        } else {
            return .songSelect;
        }
    }

    return .results;
}
// Returns the screen-space x for a normalized track position [0,1] at a given y.
// Lanes converge toward a vanishing point at the top center.
pub fn trackX(norm: f32, y: f32, sw: f32, sh: f32) f32 {
    const horizon_y = sh * 0.12;
    const t = (y - horizon_y) / (sh - horizon_y); // 0 at horizon, 1 at bottom
    const hw = sw * (0.04 + 0.44 * t);
    return sw * 0.5 - hw + norm * hw * 2.0;
}
pub fn drawTrap(x0: f32, x1: f32, y0: f32, x2: f32, x3: f32, y1: f32, col: rl.Color) void {
    const tl = rl.Vector2{ .x = x0, .y = y0 };
    const tr = rl.Vector2{ .x = x1, .y = y0 };
    const bl = rl.Vector2{ .x = x2, .y = y1 };
    const br = rl.Vector2{ .x = x3, .y = y1 };
    rl.drawTriangle(tl, bl, br, col);
    rl.drawTriangle(tl, br, tr, col);
}
pub fn drawNotes(state: *const data.GameState, settings: *const data.Settings, sw: f32, sh: f32) void {
    const horizon_y = sh * 0.12;
    const hit_y = sh * 0.82;
    const note_h: f32 = 10.0;

    for (0..5) |l| {
        const lane_bits = state.notes[l];
        const fl: f32 = @floatFromInt(l);
        const t0 = fl / 5.0;
        const t1 = (fl + 1.0) / 5.0;
        const lane_col = if (state.starPowerActive) settings.colors[6] else settings.colors[l];

        // Look back far enough to include the longest hold that started before the current beat
        const s_min = systems.slot_at(state.beat - @as(f32, @floatFromInt(state.longest_hold + 1)));
        const s_max = @min(systems.SLOTS - 1, systems.slot_at(state.beat + systems.SCROLL_BEATS) + 1);

        var s = s_min;
        while (s <= s_max) : (s += 1) {
            if (!systems.present(lane_bits, s)) continue;
            const sf: f32 = @floatFromInt(s);
            const t = (sf - state.beat) / systems.SCROLL_BEATS;

            const is_hit = systems.isHitMarked(state.hitMask[l], s);

            // Render hold bar even if head is off-screen
            if (systems.connected(lane_bits, s)) {
                const hlen = systems.holdLen(lane_bits, s);
                const endF = sf + @as(f32, @floatFromInt(hlen));
                const t_end = (endF - state.beat) / systems.SCROLL_BEATS;

                // Only skip if hold tail is way off-screen
                if (t_end < -5.0) continue;

                const noteY = hit_y - t * (hit_y - horizon_y);
                const holdYRaw = hit_y - t_end * (hit_y - horizon_y);
                const barY0 = @min(noteY, holdYRaw);
                const barY1 = @max(noteY, holdYRaw);

                const barCol: rl.Color = if (state.holdActive[l] and
                    state.holdSlot[l] == s)
                    settings.colors[5]
                else
                    lane_col;
                drawTrap(
                    trackX(t0, barY0, sw, sh),
                    trackX(t1, barY0, sw, sh),
                    barY0,
                    trackX(t0, barY1, sw, sh),
                    trackX(t1, barY1, sw, sh),
                    barY1,
                    .{ .r = barCol.r, .g = barCol.g, .b = barCol.b, .a = 140 },
                );
            }

            // Skip note head if off-screen
            if (t < -0.15 or t > 1.0) continue;

            const noteY = hit_y - t * (hit_y - horizon_y);
            const nyBot = noteY + note_h;
            const col: rl.Color = if (is_hit) rl.Color.white else lane_col;
            if (systems.isHalf(lane_bits, s)) {
                const cx: i32 = @intFromFloat((trackX(t0, noteY, sw, sh) + trackX(t1, noteY, sw, sh)) / 2.0);
                rl.drawCircleLines(cx, @intFromFloat(noteY), (trackX(t1, noteY, sw, sh) - trackX(t0, noteY, sw, sh)) * 0.35, col);
            } else {
                drawTrap(
                    trackX(t0, noteY, sw, sh),
                    trackX(t1, noteY, sw, sh),
                    noteY,
                    trackX(t0, nyBot, sw, sh),
                    trackX(t1, nyBot, sw, sh),
                    nyBot,
                    col,
                );
            }

            if (is_hit and @abs(sf - state.beat) < 1.0) {
                const hx0 = trackX(t0, hit_y, sw, sh);
                const hx1 = trackX(t1, hit_y, sw, sh);
                rl.drawCircleLines(
                    @intFromFloat((hx0 + hx1) / 2.0),
                    @intFromFloat(hit_y),
                    (hx1 - hx0) * 0.45,
                    .{ .r = 255, .g = 255, .b = 255, .a = 200 },
                );
            }
        }
    }
}
pub fn drawMain(ui: *widgets.WidgetStream) data.Screen {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    var playPressed = false;
    var settingsPressed = false;
    var exitPressed = false;

    const btnW: f32 = sw * 0.2;
    const btnH: f32 = sh * 0.07;
    const gap: f32 = sh * 0.02;
    const btnStartY = sh / 2.0 - (btnH * 3.0 + gap * 2.0) / 2.0;

    const title = "Guitar Game";
    const titleSz: i32 = @intFromFloat(sh * 0.08);
    const titleH: f32 = @floatFromInt(titleSz);
    const titleW: f32 = @floatFromInt(rl.measureText(title, titleSz));

    const btnSize = rl.Rectangle{ .x = 0, .y = 0, .width = btnW, .height = btnH };
    const swRect = rl.Rectangle{ .x = 0, .y = 0, .width = sw, .height = btnH };

    ui.begin();

    ui.label(
        widgets.centerIn(
            .{ .x = swRect.x, .y = sh * 0.18, .width = swRect.width, .height = titleH },
            .{ .x = 0, .y = 0, .width = titleW, .height = titleH },
        ),
        title,
        titleSz,
        rl.Color.white,
    );
    ui.button(
        widgets.centerIn(.{ .x = swRect.x, .y = btnStartY, .width = swRect.width, .height = swRect.height }, btnSize),
        "Play",
        .{ .func = setBool, .ctx = &playPressed },
    );
    ui.button(
        widgets.centerIn(.{ .x = swRect.x, .y = btnStartY + btnH + gap, .width = swRect.width, .height = swRect.height }, btnSize),
        "Settings",
        .{ .func = setBool, .ctx = &settingsPressed },
    );
    ui.buttonStyled(
        widgets.centerIn(.{ .x = swRect.x, .y = btnStartY + (btnH + gap) * 2.0, .width = swRect.width, .height = swRect.height }, btnSize),
        .{
            .label = "Exit",
            .color = .{ .r = 140, .g = 40, .b = 40, .a = 255 },
            .hover_color = .{ .r = 190, .g = 55, .b = 55, .a = 255 },
            .press_color = .{ .r = 100, .g = 25, .b = 25, .a = 255 },
        },
        .{ .func = setBool, .ctx = &exitPressed },
    );

    ui.processAndDraw();

    if (playPressed) return .songSelect;
    if (settingsPressed) return .settings;
    if (exitPressed) return .exit;
    return .main;
}
pub fn keyName(key: rl.KeyboardKey) [:0]const u8 {
    return switch (key) {
        .a => "A",
        .b => "B",
        .c => "C",
        .d => "D",
        .e => "E",
        .f => "F",
        .g => "G",
        .h => "H",
        .i => "I",
        .j => "J",
        .k => "K",
        .l => "L",
        .m => "M",
        .n => "N",
        .o => "O",
        .p => "P",
        .q => "Q",
        .r => "R",
        .s => "S",
        .t => "T",
        .u => "U",
        .v => "V",
        .w => "W",
        .x => "X",
        .y => "Y",
        .z => "Z",
        .zero => "0",
        .one => "1",
        .two => "2",
        .three => "3",
        .four => "4",
        .five => "5",
        .six => "6",
        .seven => "7",
        .eight => "8",
        .nine => "9",
        .space => "SPC",
        .enter => "ENT",
        .backspace => "BSP",
        .left => "LEFT",
        .right => "RGHT",
        .up => "UP",
        .down => "DN",
        .left_shift, .right_shift => "SHFT",
        .left_control, .right_control => "CTRL",
        .left_alt, .right_alt => "ALT",
        .tab => "TAB",
        .escape => "ESC",
        else => "???",
    };
}
pub fn startRebind(ctx: ?*anyopaque) void {
    const slot: *usize = @ptrCast(@alignCast(ctx.?));
    data.settings_state.rebinding_slot = slot.*;
}
pub fn drawSettings(ui: *widgets.WidgetStream, io: std.Io, settings: *data.Settings) data.Screen {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    const mouse = rl.getMousePosition();
    const clicked = rl.isMouseButtonPressed(.left);
    const ss = &data.settings_state;

    // Sync color float values when selection changes
    if (ss.selected_color != ss.prev_selected_color) {
        if (ss.selected_color) |ci| {
            const c = settings.colors[ci];
            ss.colR = @floatFromInt(c.r);
            ss.colG = @floatFromInt(c.g);
            ss.colB = @floatFromInt(c.b);
            ss.colA = @floatFromInt(c.a);
        }
        ss.prev_selected_color = ss.selected_color;
    }
    if (ss.selected_color) |ci| {
        settings.colors[ci] = .{
            .r = @intFromFloat(std.math.clamp(ss.colR, 0.0, 255.0)),
            .g = @intFromFloat(std.math.clamp(ss.colG, 0.0, 255.0)),
            .b = @intFromFloat(std.math.clamp(ss.colB, 0.0, 255.0)),
            .a = @intFromFloat(std.math.clamp(ss.colA, 0.0, 255.0)),
        };
    }

    // Key rebinding capture
    if (ss.rebinding_slot != null) {
        const k = rl.getKeyPressed();
        if (k == .escape) {
            ss.rebinding_slot = null;
        } else if (k != .null) {
            settings.keys[ss.rebinding_slot.?] = k;
            ss.rebinding_slot = null;
        }
    }

    var backPressed = false;
    var savePressed = false;

    const leftX = sw * 0.05;
    const leftW = sw * 0.40;
    const rightX = sw * 0.55;
    const rightW = sw * 0.42;
    const contentY: f32 = 110;
    const keyRowH: f32 = @max(52.0, sh * 0.09);
    const sectionColor = rl.Color{ .r = 120, .g = 170, .b = 255, .a = 255 };

    // Heading
    const heading = "Settings";
    const headingSz: i32 = 44;
    const headingW = rl.measureText(heading, headingSz);
    rl.drawText(heading, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(headingW)) / 2.0), 18, headingSz, rl.Color.white);

    // Vertical divider
    rl.drawLineEx(
        .{ .x = sw * 0.505, .y = 70 },
        .{ .x = sw * 0.505, .y = sh - 10 },
        1.0,
        .{ .r = 55, .g = 55, .b = 80, .a = 180 },
    );

    rl.drawText("Key Bindings", @intFromFloat(leftX), 78, 19, sectionColor);
    rl.drawText("Colors", @intFromFloat(rightX), 78, 19, sectionColor);

    ui.begin();
    ui.button(.{ .x = 16, .y = 16, .width = 110, .height = 40 }, "< Back", .{ .func = setBool, .ctx = &backPressed });

    // ── Key binding rows ──
    const keyLabelsText = [6][:0]const u8{ "Lane 1", "Lane 2", "Lane 3", "Lane 4", "Lane 5", "Action" };
    const keyBtnW: f32 = 90;
    const keyBtnH: f32 = 38;

    for (0..6) |i| {
        const fi: f32 = @floatFromInt(i);
        const ry = contentY + fi * keyRowH;
        const isRebinding = (ss.rebinding_slot != null and ss.rebinding_slot.? == i);

        rl.drawText(
            keyLabelsText[i],
            @intFromFloat(leftX + 6),
            @intFromFloat(ry + (keyRowH - 24.0) / 2.0),
            24,
            rl.Color.white,
        );

        const btnRect = rl.Rectangle{
            .x = leftX + leftW - keyBtnW - 6,
            .y = ry + (keyRowH - keyBtnH) / 2.0,
            .width = keyBtnW,
            .height = keyBtnH,
        };

        if (isRebinding) {
            ui.buttonStyled(btnRect, .{
                .label = "...",
                .color = .{ .r = 60, .g = 60, .b = 100, .a = 255 },
                .hover_color = .{ .r = 60, .g = 60, .b = 100, .a = 255 },
                .press_color = .{ .r = 60, .g = 60, .b = 100, .a = 255 },
            }, null);
        } else {
            ui.buttonStyled(btnRect, .{
                .label = keyName(settings.keys[i]),
                .color = .{ .r = 40, .g = 60, .b = 100, .a = 255 },
                .hover_color = .{ .r = 60, .g = 90, .b = 140, .a = 255 },
                .press_color = .{ .r = 28, .g = 42, .b = 70, .a = 255 },
            }, if (ss.rebinding_slot == null) .{ .func = startRebind, .ctx = &data.slot_indices[i] } else null);
        }

        rl.drawLineEx(
            .{ .x = leftX, .y = ry + keyRowH - 1 },
            .{ .x = leftX + leftW, .y = ry + keyRowH - 1 },
            0.5,
            .{ .r = 45, .g = 45, .b = 65, .a = 150 },
        );
    }

    // ── Delay ──
    const delaySectionY = contentY + 6.0 * keyRowH + 18;
    var delay_buf: [48]u8 = undefined;
    const delay_label = std.fmt.bufPrintZ(&delay_buf, "Note delay: {d:.2} s", .{settings.delay}) catch "Note delay";
    rl.drawText(delay_label, @intFromFloat(leftX + 6), @intFromFloat(delaySectionY), 18, sectionColor);
    ui.slider(
        .{ .x = leftX + 6, .y = delaySectionY + 22, .width = leftW - 12, .height = 30 },
        "",
        0.0,
        2.0,
        &settings.delay,
        null,
    );

    // ── Save button ──
    const saveBtnY = delaySectionY + 68;
    ui.buttonStyled(
        .{ .x = leftX + 6, .y = saveBtnY, .width = leftW - 12, .height = 44 },
        .{
            .label = "Save Settings",
            .color = .{ .r = 30, .g = 80, .b = 30, .a = 255 },
            .hover_color = .{ .r = 50, .g = 120, .b = 50, .a = 255 },
            .press_color = .{ .r = 20, .g = 55, .b = 20, .a = 255 },
        },
        .{ .func = setBool, .ctx = &savePressed },
    );
    if (ss.save_msg_timer > 0) {
        ss.save_msg_timer -= rl.getFrameTime();
        const savedTxt = "Settings saved!";
        const savedSz: i32 = 16;
        const savedW = rl.measureText(savedTxt, savedSz);
        rl.drawText(
            savedTxt,
            @intFromFloat(leftX + 6 + (leftW - 12 - @as(f32, @floatFromInt(savedW))) / 2.0),
            @intFromFloat(saveBtnY + 40),
            savedSz,
            .{ .r = 100, .g = 220, .b = 100, .a = 255 },
        );
    }

    // ── Color swatches (2-row grid) ──
    const swatchSize: f32 = 70;
    const swatchLabelH: f32 = 20;
    const swatchRowH: f32 = swatchSize + swatchLabelH + 8;
    const swatchCols = 4;
    const swatchColW = rightW / 4.0;

    const colorNamesText = [7][:0]const u8{ "Lane 1", "Lane 2", "Lane 3", "Lane 4", "Lane 5", "Held", "Star" };

    for (0..7) |i| {
        const col: usize = i % swatchCols;
        const row: usize = i / swatchCols;
        const sx = rightX + @as(f32, @floatFromInt(col)) * swatchColW + swatchColW / 2.0 - swatchSize / 2.0;
        const sy = contentY + @as(f32, @floatFromInt(row)) * swatchRowH;
        const isSelected = (ss.selected_color != null and ss.selected_color.? == i);

        const swatchRect = rl.Rectangle{
            .x = sx,
            .y = sy,
            .width = swatchSize,
            .height = swatchSize,
        };

        rl.drawRectangleRec(swatchRect, settings.colors[i]);
        rl.drawRectangleLinesEx(swatchRect, if (isSelected) 3.0 else 1.5, if (isSelected) rl.Color.white else .{ .r = 80, .g = 80, .b = 100, .a = 200 });

        const labelW = rl.measureText(colorNamesText[i], 17);
        rl.drawText(
            colorNamesText[i],
            @intFromFloat(sx + (swatchSize - @as(f32, @floatFromInt(labelW))) / 2.0),
            @intFromFloat(sy + swatchSize + 3),
            17,
            if (isSelected) rl.Color.white else .{ .r = 160, .g = 160, .b = 180, .a = 255 },
        );

        if (ss.rebinding_slot == null and rl.checkCollisionPointRec(mouse, swatchRect) and clicked) {
            ss.selected_color = if (isSelected) null else i;
        }
    }

    // ── RGB sliders for selected color ──
    if (ss.selected_color) |ci| {
        const sliderBaseY = contentY + 2.0 * swatchRowH + 24;
        const sliderW = rightW - 12;
        const sliderX = rightX + 6;
        const sliderH: f32 = 34;
        const sliderRow: f32 = 56;

        const editName = colorNamesText[ci];
        const editW = rl.measureText(editName, 20);
        rl.drawText(editName, @intFromFloat(sliderX + (sliderW - @as(f32, @floatFromInt(editW))) / 2.0), @intFromFloat(sliderBaseY - 24), 20, sectionColor);

        ui.slider(.{ .x = sliderX, .y = sliderBaseY, .width = sliderW, .height = sliderH }, "R", 0, 255, &ss.colR, null);
        ui.slider(.{ .x = sliderX, .y = sliderBaseY + sliderRow, .width = sliderW, .height = sliderH }, "G", 0, 255, &ss.colG, null);
        ui.slider(.{ .x = sliderX, .y = sliderBaseY + sliderRow * 2.0, .width = sliderW, .height = sliderH }, "B", 0, 255, &ss.colB, null);
        ui.slider(.{ .x = sliderX, .y = sliderBaseY + sliderRow * 3.0, .width = sliderW, .height = sliderH }, "A", 0, 255, &ss.colA, null);
    }

    ui.processAndDraw();

    // ── Rebinding overlay ──
    if (ss.rebinding_slot) |slot| {
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), .{ .r = 0, .g = 0, .b = 0, .a = 150 });

        const boxW: f32 = sw * 0.45;
        const boxH: f32 = 110;
        const boxX = (sw - boxW) / 2.0;
        const boxY = (sh - boxH) / 2.0;

        rl.drawRectangleRec(.{ .x = boxX, .y = boxY, .width = boxW, .height = boxH }, .{ .r = 25, .g = 25, .b = 40, .a = 255 });
        rl.drawRectangleLinesEx(.{ .x = boxX, .y = boxY, .width = boxW, .height = boxH }, 1.5, .{ .r = 80, .g = 80, .b = 120, .a = 255 });

        const laneLabels = [6][:0]const u8{ "Lane 1", "Lane 2", "Lane 3", "Lane 4", "Lane 5", "Action" };
        const title = "Press a key to bind";
        const titleSz: i32 = 20;
        const titleW = rl.measureText(title, titleSz);
        rl.drawText(title, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(titleW)) / 2.0), @intFromFloat(boxY + 14), titleSz, rl.Color.white);

        const laneW = rl.measureText(laneLabels[slot], 15);
        rl.drawText(laneLabels[slot], @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(laneW)) / 2.0), @intFromFloat(boxY + 44), 15, sectionColor);

        const cancelTxt = "ESC to cancel";
        const cancelSz: i32 = 13;
        const cancelW = rl.measureText(cancelTxt, cancelSz);
        rl.drawText(cancelTxt, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(cancelW)) / 2.0), @intFromFloat(boxY + 74), cancelSz, .{ .r = 130, .g = 130, .b = 150, .a = 255 });
    }

    if (savePressed) {
        systems.saveSettings(io, settings) catch {};
        ss.save_msg_timer = 2.0;
    }
    if (backPressed) {
        ss.rebinding_slot = null;
        ss.selected_color = null;
        return .main;
    }
    return .settings;
}
// Draws all settings content inside a floating overlay panel (like the pause menu).
pub fn drawSettingsOverlay(ui: *widgets.WidgetStream, io: std.Io, state: *data.GameState, settings: *data.Settings) bool {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    const mouse = rl.getMousePosition();
    const clicked = rl.isMouseButtonPressed(.left);
    const ss = &data.settings_state;

    // Sync color float values when selection changes
    if (ss.selected_color != ss.prev_selected_color) {
        if (ss.selected_color) |ci| {
            const c = settings.colors[ci];
            ss.colR = @floatFromInt(c.r);
            ss.colG = @floatFromInt(c.g);
            ss.colB = @floatFromInt(c.b);
            ss.colA = @floatFromInt(c.a);
        }
        ss.prev_selected_color = ss.selected_color;
    }
    if (ss.selected_color) |ci| {
        settings.colors[ci] = .{
            .r = @intFromFloat(std.math.clamp(ss.colR, 0.0, 255.0)),
            .g = @intFromFloat(std.math.clamp(ss.colG, 0.0, 255.0)),
            .b = @intFromFloat(std.math.clamp(ss.colB, 0.0, 255.0)),
            .a = @intFromFloat(std.math.clamp(ss.colA, 0.0, 255.0)),
        };
    }

    // Key rebinding capture
    if (ss.rebinding_slot != null) {
        const k = rl.getKeyPressed();
        if (k == .escape) {
            ss.rebinding_slot = null;
        } else if (k != .null) {
            settings.keys[ss.rebinding_slot.?] = k;
            ss.rebinding_slot = null;
        }
    }

    var closePressed = false;
    var savePressed = false;

    // Dim background
    rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), .{ .r = 0, .g = 0, .b = 0, .a = 160 });

    // Panel
    const ovW = sw * 0.88;
    const ovH = sh * 0.90;
    const ovX = (sw - ovW) / 2.0;
    const ovY = (sh - ovH) / 2.0;
    rl.drawRectangleRec(.{ .x = ovX, .y = ovY, .width = ovW, .height = ovH }, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    rl.drawRectangleLinesEx(.{ .x = ovX, .y = ovY, .width = ovW, .height = ovH }, 1.5, .{ .r = 80, .g = 80, .b = 120, .a = 255 });

    const leftX = ovX + ovW * 0.05;
    const leftW = ovW * 0.40;
    const rightX = ovX + ovW * 0.55;
    const rightW = ovW * 0.42;
    const contentY: f32 = ovY + 110;
    const keyRowH: f32 = @max(52.0, sh * 0.09);
    const sectionColor = rl.Color{ .r = 120, .g = 170, .b = 255, .a = 255 };

    // Heading
    const heading = "Settings";
    const headingSz: i32 = 44;
    const headingW = rl.measureText(heading, headingSz);
    rl.drawText(heading, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(headingW)) / 2.0), @intFromFloat(ovY + 18), headingSz, rl.Color.white);

    // Vertical divider
    rl.drawLineEx(
        .{ .x = ovX + ovW * 0.505, .y = ovY + 70 },
        .{ .x = ovX + ovW * 0.505, .y = ovY + ovH - 10 },
        1.0,
        .{ .r = 55, .g = 55, .b = 80, .a = 180 },
    );

    rl.drawText("Key Bindings", @intFromFloat(leftX), @intFromFloat(ovY + 78), 19, sectionColor);
    rl.drawText("Colors", @intFromFloat(rightX), @intFromFloat(ovY + 78), 19, sectionColor);

    ui.begin();
    ui.button(.{ .x = ovX + 16, .y = ovY + 16, .width = 110, .height = 40 }, "< Back", .{ .func = setBool, .ctx = &closePressed });

    // ── Key binding rows ──
    const keyLabelsText = [6][:0]const u8{ "Lane 1", "Lane 2", "Lane 3", "Lane 4", "Lane 5", "Action" };
    const keyBtnW: f32 = 90;
    const keyBtnH: f32 = 38;

    for (0..6) |i| {
        const fi: f32 = @floatFromInt(i);
        const ry = contentY + fi * keyRowH;
        const isRebinding = (ss.rebinding_slot != null and ss.rebinding_slot.? == i);

        rl.drawText(
            keyLabelsText[i],
            @intFromFloat(leftX + 6),
            @intFromFloat(ry + (keyRowH - 24.0) / 2.0),
            24,
            rl.Color.white,
        );

        const btnRect = rl.Rectangle{
            .x = leftX + leftW - keyBtnW - 6,
            .y = ry + (keyRowH - keyBtnH) / 2.0,
            .width = keyBtnW,
            .height = keyBtnH,
        };

        if (isRebinding) {
            ui.buttonStyled(btnRect, .{
                .label = "...",
                .color = .{ .r = 60, .g = 60, .b = 100, .a = 255 },
                .hover_color = .{ .r = 60, .g = 60, .b = 100, .a = 255 },
                .press_color = .{ .r = 60, .g = 60, .b = 100, .a = 255 },
            }, null);
        } else {
            ui.buttonStyled(btnRect, .{
                .label = keyName(settings.keys[i]),
                .color = .{ .r = 40, .g = 60, .b = 100, .a = 255 },
                .hover_color = .{ .r = 60, .g = 90, .b = 140, .a = 255 },
                .press_color = .{ .r = 28, .g = 42, .b = 70, .a = 255 },
            }, if (ss.rebinding_slot == null) .{ .func = startRebind, .ctx = &data.slot_indices[i] } else null);
        }

        rl.drawLineEx(
            .{ .x = leftX, .y = ry + keyRowH - 1 },
            .{ .x = leftX + leftW, .y = ry + keyRowH - 1 },
            0.5,
            .{ .r = 45, .g = 45, .b = 65, .a = 150 },
        );
    }

    // ── Delay ──
    const delaySectionY = contentY + 6.0 * keyRowH + 18;
    var delay_buf: [48]u8 = undefined;
    const delay_label = std.fmt.bufPrintZ(&delay_buf, "Note delay: {d:.2} s", .{settings.delay}) catch "Note delay";
    rl.drawText(delay_label, @intFromFloat(leftX + 6), @intFromFloat(delaySectionY), 18, sectionColor);
    ui.slider(
        .{ .x = leftX + 6, .y = delaySectionY + 22, .width = leftW - 12, .height = 30 },
        "",
        0.0,
        2.0,
        &settings.delay,
        null,
    );

    // ── Save button ──
    const saveBtnY = delaySectionY + 68;
    ui.buttonStyled(
        .{ .x = leftX + 6, .y = saveBtnY, .width = leftW - 12, .height = 44 },
        .{
            .label = "Save Settings",
            .color = .{ .r = 30, .g = 80, .b = 30, .a = 255 },
            .hover_color = .{ .r = 50, .g = 120, .b = 50, .a = 255 },
            .press_color = .{ .r = 20, .g = 55, .b = 20, .a = 255 },
        },
        .{ .func = setBool, .ctx = &savePressed },
    );
    if (ss.save_msg_timer > 0) {
        ss.save_msg_timer -= rl.getFrameTime();
        const savedTxt = "Settings saved!";
        const savedSz: i32 = 16;
        const savedW = rl.measureText(savedTxt, savedSz);
        rl.drawText(
            savedTxt,
            @intFromFloat(leftX + 6 + (leftW - 12 - @as(f32, @floatFromInt(savedW))) / 2.0),
            @intFromFloat(saveBtnY + 50),
            savedSz,
            .{ .r = 100, .g = 220, .b = 100, .a = 255 },
        );
    }

    // ── Color swatches (2-row grid) ──
    const swatchSize: f32 = 70;
    const swatchLabelH: f32 = 20;
    const swatchRowH: f32 = swatchSize + swatchLabelH + 8;
    const swatchCols = 4;
    const swatchColW = rightW / 4.0;

    const colorNamesText = [7][:0]const u8{ "Lane 1", "Lane 2", "Lane 3", "Lane 4", "Lane 5", "Held", "Star" };

    for (0..7) |i| {
        const col: usize = i % swatchCols;
        const row: usize = i / swatchCols;
        const sx = rightX + @as(f32, @floatFromInt(col)) * swatchColW + swatchColW / 2.0 - swatchSize / 2.0;
        const sy = contentY + @as(f32, @floatFromInt(row)) * swatchRowH;
        const isSelected = (ss.selected_color != null and ss.selected_color.? == i);

        const swatchRect = rl.Rectangle{ .x = sx, .y = sy, .width = swatchSize, .height = swatchSize };
        rl.drawRectangleRec(swatchRect, settings.colors[i]);
        rl.drawRectangleLinesEx(swatchRect, if (isSelected) 3.0 else 1.5, if (isSelected) rl.Color.white else .{ .r = 80, .g = 80, .b = 100, .a = 200 });

        const labelW = rl.measureText(colorNamesText[i], 17);
        rl.drawText(
            colorNamesText[i],
            @intFromFloat(sx + (swatchSize - @as(f32, @floatFromInt(labelW))) / 2.0),
            @intFromFloat(sy + swatchSize + 3),
            17,
            if (isSelected) rl.Color.white else .{ .r = 160, .g = 160, .b = 180, .a = 255 },
        );

        if (ss.rebinding_slot == null and rl.checkCollisionPointRec(mouse, swatchRect) and clicked) {
            ss.selected_color = if (isSelected) null else i;
        }
    }

    // ── RGB sliders for selected color ──
    if (ss.selected_color) |ci| {
        const sliderBaseY = contentY + 2.0 * swatchRowH + 24;
        const sliderW = rightW - 12;
        const sliderX = rightX + 6;
        const sliderH: f32 = 34;
        const sliderRow: f32 = 56;

        const editName = colorNamesText[ci];
        const editW = rl.measureText(editName, 20);
        rl.drawText(editName, @intFromFloat(sliderX + (sliderW - @as(f32, @floatFromInt(editW))) / 2.0), @intFromFloat(sliderBaseY - 24), 20, sectionColor);

        ui.slider(.{ .x = sliderX, .y = sliderBaseY, .width = sliderW, .height = sliderH }, "R", 0, 255, &ss.colR, null);
        ui.slider(.{ .x = sliderX, .y = sliderBaseY + sliderRow, .width = sliderW, .height = sliderH }, "G", 0, 255, &ss.colG, null);
        ui.slider(.{ .x = sliderX, .y = sliderBaseY + sliderRow * 2.0, .width = sliderW, .height = sliderH }, "B", 0, 255, &ss.colB, null);
        ui.slider(.{ .x = sliderX, .y = sliderBaseY + sliderRow * 3.0, .width = sliderW, .height = sliderH }, "A", 0, 255, &ss.colA, null);
    }

    ui.processAndDraw();

    // ── Rebinding overlay ──
    if (ss.rebinding_slot) |slot| {
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), .{ .r = 0, .g = 0, .b = 0, .a = 150 });

        const boxW: f32 = sw * 0.45;
        const boxH: f32 = 110;
        const boxX = (sw - boxW) / 2.0;
        const boxY = (sh - boxH) / 2.0;

        rl.drawRectangleRec(.{ .x = boxX, .y = boxY, .width = boxW, .height = boxH }, .{ .r = 25, .g = 25, .b = 40, .a = 255 });
        rl.drawRectangleLinesEx(.{ .x = boxX, .y = boxY, .width = boxW, .height = boxH }, 1.5, .{ .r = 80, .g = 80, .b = 120, .a = 255 });

        const laneLabels = [6][:0]const u8{ "Lane 1", "Lane 2", "Lane 3", "Lane 4", "Lane 5", "Action" };
        const title = "Press a key to bind";
        const titleSz: i32 = 20;
        const titleW = rl.measureText(title, titleSz);
        rl.drawText(title, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(titleW)) / 2.0), @intFromFloat(boxY + 14), titleSz, rl.Color.white);

        const laneW = rl.measureText(laneLabels[slot], 15);
        rl.drawText(laneLabels[slot], @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(laneW)) / 2.0), @intFromFloat(boxY + 44), 15, sectionColor);

        const cancelTxt = "ESC to cancel";
        const cancelSz: i32 = 13;
        const cancelW = rl.measureText(cancelTxt, cancelSz);
        rl.drawText(cancelTxt, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(cancelW)) / 2.0), @intFromFloat(boxY + 74), cancelSz, .{ .r = 130, .g = 130, .b = 150, .a = 255 });
    }

    if (savePressed) {
        systems.saveSettings(io, settings) catch {};
        ss.save_msg_timer = 2.0;
    }

    if (closePressed) {
        ss.rebinding_slot = null;
        ss.selected_color = null;
        state.showing_settings = false;
        state.paused = true;
        return true;
    }
    return false;
}
pub fn drawGame(ui: *widgets.WidgetStream, io: std.Io, state: *data.GameState, settings: *data.Settings) data.Screen {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    if (state.resultsCountdown == 0) {
        return .results;
    }

    const horizonY = sh * 0.12;
    const hitY = sh * 0.82;

    const laneColors = settings.colors;

    // Toggle pause on Escape
    if (rl.isKeyPressed(.escape)) state.paused = !state.paused;

    // --- Draw track ---
    rl.drawRectangleRec(.{ .x = 0, .y = 0, .width = sw, .height = sh }, .{ .r = 10, .g = 10, .b = 15, .a = 255 });

    for (0..5) |i| {
        const fi: f32 = @floatFromInt(i);
        const t0 = fi / 5.0;
        const t1 = (fi + 1.0) / 5.0;

        // Lane trapezoid background
        const bg: rl.Color = if (i % 2 == 0)
            .{ .r = 22, .g = 22, .b = 28, .a = 255 }
        else
            .{ .r = 32, .g = 32, .b = 40, .a = 255 };
        drawTrap(
            trackX(t0, horizonY, sw, sh),
            trackX(t1, horizonY, sw, sh),
            horizonY,
            trackX(t0, sh, sw, sh),
            trackX(t1, sh, sw, sh),
            sh,
            bg,
        );

        // Lane divider line
        rl.drawLineEx(
            .{ .x = trackX(t0, horizonY, sw, sh), .y = horizonY },
            .{ .x = trackX(t0, sh, sw, sh), .y = sh },
            1.5,
            .{ .r = 55, .g = 55, .b = 65, .a = 255 },
        );

        // Hit bar strip
        rl.drawLineEx(
            .{ .x = trackX(t0, hitY, sw, sh), .y = hitY },
            .{ .x = trackX(t1, hitY, sw, sh), .y = hitY },
            4,
            laneColors[i],
        );

        // Fret button
        const cx: i32 = @intFromFloat((trackX(t0, hitY, sw, sh) + trackX(t1, hitY, sw, sh)) / 2.0);
        const cy: i32 = @intFromFloat(hitY);
        const fretR = (trackX(t1, hitY, sw, sh) - trackX(t0, hitY, sw, sh)) * 0.20;
        const fretCol = laneColors[i];
        rl.drawCircle(cx, cy, fretR, fretCol);
        if (rl.isKeyDown(settings.keys[i])) rl.drawCircle(cx, cy, fretR, settings.colors[5]);
        rl.drawCircleLines(cx, cy, fretR, rl.Color.white);
    }

    // Right edge divider
    rl.drawLineEx(
        .{ .x = trackX(1.0, horizonY, sw, sh), .y = horizonY },
        .{ .x = trackX(1.0, sh, sw, sh), .y = sh },
        1.5,
        .{ .r = 55, .g = 55, .b = 65, .a = 255 },
    );

    // --- Draw notes ---
    drawNotes(state, settings, sw, sh);

    // --- Score, Stars, and Combo HUD ---
    var scoreBuf: [32]u8 = undefined;
    const scoreStr = std.fmt.bufPrintZ(&scoreBuf, "Score: {d}", .{state.score}) catch "Score: ?";
    rl.drawText(scoreStr, @intFromFloat(sw - 320), 12, 48, rl.Color.white);

    var starsBuf: [64]u8 = undefined;
    const starsStr = std.fmt.bufPrintZ(&starsBuf, "★ {d}/5 ({d}x)", .{ state.starCount, state.starMultiplier }) catch "★ ?";
    rl.drawText(starsStr, @intFromFloat(sw - 320), 68, 40, .{ .r = 255, .g = 215, .b = 0, .a = 255 });

    var comboBuf: [32]u8 = undefined;
    const comboStr = std.fmt.bufPrintZ(&comboBuf, "Combo: {d}", .{state.comboCount}) catch "Combo: ?";
    rl.drawText(comboStr, @intFromFloat(sw - 320), 118, 40, .{ .r = 100, .g = 200, .b = 255, .a = 255 });

    // --- Star Power Meter ---
    const meterX = sw - 320;
    const meterY = 175.0;
    const meterW = 200.0;
    const meterH = 20.0;

    // Draw meter background
    rl.drawRectangleRec(.{ .x = meterX, .y = meterY, .width = meterW, .height = meterH }, .{ .r = 40, .g = 40, .b = 40, .a = 255 });

    // Calculate meter fill based on whether star power is active
    const fillAmount = if (state.starPowerActive)
        state.starPowerTimer / 8.0 // Depleting meter during active period
    else
        state.starPowerMeter; // Building meter otherwise

    const fillW = meterW * fillAmount;

    // Determine fill color based on fill amount
    const fillCol: rl.Color = if (state.starPowerActive)
        .{ .r = 255, .g = 200, .b = 0, .a = 255 }
    else if (fillAmount >= 0.5)
        .{ .r = 0, .g = 255, .b = 0, .a = 255 }
    else
        .{ .r = 100, .g = 150, .b = 255, .a = 255 };
    rl.drawRectangleRec(.{ .x = meterX, .y = meterY, .width = fillW, .height = meterH }, fillCol);

    // Draw meter border
    rl.drawRectangleLinesEx(.{ .x = meterX, .y = meterY, .width = meterW, .height = meterH }, 2.0, .{ .r = 200, .g = 200, .b = 200, .a = 255 });

    // Draw meter label
    if (state.starPowerActive) {
        rl.drawText("STAR POWER ACTIVE!", @intFromFloat(meterX - 50), @intFromFloat(meterY + 25), 24, .{ .r = 255, .g = 200, .b = 0, .a = 255 });
    } else if (state.starPowerMeter >= 0.5) {
        var powerBuf: [64]u8 = undefined;
        const actionKeyName = keyName(settings.keys[5]);
        const powerStr = std.fmt.bufPrintZ(&powerBuf, "Press {s} for Star Power (50%)", .{actionKeyName}) catch "Press Action for Star Power";
        rl.drawText(powerStr, @intFromFloat(meterX - 120), @intFromFloat(meterY + 25), 18, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    }

    // --- Jukebox (bottom-left) ---
    if (!state.paused) {
        var prevPressed = false;
        var queuePressed = false;
        var nextPressed = false;

        const jukePad: f32 = 12;
        const jukeSz: f32 = @min(sw * 0.17, sh * 0.22);
        const jukeBtnH: f32 = sh * 0.048;
        const jukeBtnGap: f32 = 3;
        const jukeX = jukePad;
        const jukeBoxY = sh - jukePad - jukeBtnH - jukeBtnGap - jukeSz;

        rl.drawRectangleRec(
            .{ .x = jukeX, .y = jukeBoxY, .width = jukeSz, .height = jukeSz },
            .{ .r = 15, .g = 15, .b = 22, .a = 210 },
        );
        rl.drawRectangleLinesEx(
            .{ .x = jukeX, .y = jukeBoxY, .width = jukeSz, .height = jukeSz },
            1.5,
            .{ .r = 80, .g = 80, .b = 110, .a = 255 },
        );

        const rowH = jukeSz / 3.0;
        const songSz: i32 = @intFromFloat(jukeSz * 0.1);
        const dim = rl.Color{ .r = 110, .g = 110, .b = 125, .a = 180 };
        const bright = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

        const rows = [3]struct { label: [:0]const u8, col: rl.Color }{
            .{ .label = state.songs.prevTitle() orelse "---", .col = dim },
            .{ .label = state.songs.currentTitle(), .col = bright },
            .{ .label = state.songs.nextTitle() orelse "---", .col = dim },
        };
        for (rows, 0..) |row, ri| {
            const ry = jukeBoxY + @as(f32, @floatFromInt(ri)) * rowH;
            const rw = rl.measureText(row.label, songSz);
            rl.drawText(
                row.label,
                @intFromFloat(jukeX + (jukeSz - @as(f32, @floatFromInt(rw))) / 2.0),
                @intFromFloat(ry + (rowH - @as(f32, @floatFromInt(songSz))) / 2.0),
                songSz,
                row.col,
            );
        }

        const jukeBtnY = jukeBoxY + jukeSz + jukeBtnGap;
        const jukeBtnW = (jukeSz - jukeBtnGap * 2.0) / 3.0;

        ui.begin();
        ui.button(.{ .x = jukeX, .y = jukeBtnY, .width = jukeBtnW, .height = jukeBtnH }, "|<", .{ .func = setBool, .ctx = &prevPressed });
        ui.button(.{ .x = jukeX + jukeBtnW + jukeBtnGap, .y = jukeBtnY, .width = jukeBtnW, .height = jukeBtnH }, "Queue", .{ .func = setBool, .ctx = &queuePressed });
        ui.button(.{ .x = jukeX + (jukeBtnW + jukeBtnGap) * 2.0, .y = jukeBtnY, .width = jukeBtnW, .height = jukeBtnH }, ">|", .{ .func = setBool, .ctx = &nextPressed });
        ui.processAndDraw();

        if (prevPressed) state.songs.goPrev();
        if (queuePressed) state.showing_queue = true;
        if (nextPressed) state.songs.goNext();
    }

    // --- Queue overlay (takes priority over pause menu) ---
    if (state.showing_queue) {
        rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), .{ .r = 0, .g = 0, .b = 0, .a = 120 });

        const ovW = sw * 0.55;
        const ovH = sh * 0.72;
        const ovRect = rl.Rectangle{
            .x = (sw - ovW) / 2.0,
            .y = (sh - ovH) / 2.0,
            .width = ovW,
            .height = ovH,
        };

        var nodesBuf: [data.MAX_SONGS]*data.SongNode = undefined;
        var itemsBuf: [data.MAX_SONGS][:0]const u8 = undefined;
        var itemCount: usize = 0;
        var it = state.songs.head;
        while (it) |n| : (it = n.next) {
            nodesBuf[itemCount] = n;
            itemsBuf[itemCount] = n.title;
            itemCount += 1;
        }

        const qr = data.queueOverlay.draw("Queue", itemsBuf[0..itemCount], ovRect);

        if (qr.closed) state.showing_queue = false;
        if (qr.removeIdx) |idx| state.songs.remove(nodesBuf[idx]);
        if (qr.reorder) |r| {
            const fromNode = nodesBuf[r.from];
            if (r.to >= itemCount) {
                state.songs.moveToEnd(fromNode);
            } else {
                state.songs.moveBefore(fromNode, nodesBuf[r.to]);
            }
        }
        if (qr.addPressed) {} // TODO: open file picker
        return .game;
    }

    // --- Settings overlay (takes priority over pause menu) ---
    if (state.showing_settings) {
        _ = drawSettingsOverlay(ui, io, state, settings);
        return .game;
    }

    // --- Pause overlay ---
    if (state.paused) {
        if (drawPauseMenu(ui, state)) return .main;
        return .game;
    }

    return .game;
}
pub fn drawPauseMenu(ui: *widgets.WidgetStream, state: *data.GameState) bool {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    var resumePressed = false;
    var queuePressed = false;
    var settingsPressed = false;
    var exitPressed = false;

    rl.drawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), .{ .r = 0, .g = 0, .b = 0, .a = 160 });

    const btnW = sw * 0.22;
    const btnH = sh * 0.07;
    const gap = sh * 0.025;
    const btnSize = rl.Rectangle{ .x = 0, .y = 0, .width = btnW, .height = btnH };
    const swRect = rl.Rectangle{ .x = 0, .y = 0, .width = sw, .height = btnH };
    const totalH = btnH * 4.0 + gap * 3.0;
    const centerY = sh / 2.0 - totalH / 2.0;

    const pauseText = "PAUSED";
    const pauseSz: i32 = @intFromFloat(sh * 0.07);
    const pauseW = rl.measureText(pauseText, pauseSz);
    rl.drawText(pauseText, @intFromFloat(sw / 2.0 - @as(f32, @floatFromInt(pauseW)) / 2.0), @intFromFloat(centerY - @as(f32, @floatFromInt(pauseSz)) - gap), pauseSz, rl.Color.white);

    ui.begin();
    ui.button(widgets.centerIn(.{ .x = swRect.x, .y = centerY, .width = swRect.width, .height = btnH }, btnSize), "Resume", .{ .func = setBool, .ctx = &resumePressed });
    ui.button(widgets.centerIn(.{ .x = swRect.x, .y = centerY + (btnH + gap), .width = swRect.width, .height = btnH }, btnSize), "Add to Queue", .{ .func = setBool, .ctx = &queuePressed });
    ui.button(widgets.centerIn(.{ .x = swRect.x, .y = centerY + (btnH + gap) * 2.0, .width = swRect.width, .height = btnH }, btnSize), "Settings", .{ .func = setBool, .ctx = &settingsPressed });
    ui.buttonStyled(widgets.centerIn(.{ .x = swRect.x, .y = centerY + (btnH + gap) * 3.0, .width = swRect.width, .height = btnH }, btnSize), .{ .label = "Main Menu", .color = .{ .r = 140, .g = 40, .b = 40, .a = 255 }, .hover_color = .{ .r = 190, .g = 55, .b = 55, .a = 255 }, .press_color = .{ .r = 100, .g = 25, .b = 25, .a = 255 } }, .{ .func = setBool, .ctx = &exitPressed });
    ui.processAndDraw();

    if (resumePressed) state.paused = false;
    if (queuePressed) state.showing_queue = true;
    if (settingsPressed) state.showing_settings = true;
    return exitPressed;
}
pub fn setBool(ctx: ?*anyopaque) void {
    const b: *bool = @ptrCast(@alignCast(ctx.?));
    b.* = true;
}

fn choice_button(ui: *widgets.WidgetStream, rect: rl.Rectangle, lbl: [:0]const u8, selected: bool, pressed: *bool) void {
    ui.buttonStyled(rect, .{
        .label = lbl,
        .color = if (selected) .{ .r = 40, .g = 90, .b = 170, .a = 255 } else .{ .r = 60, .g = 60, .b = 75, .a = 255 },
        .hover_color = if (selected) .{ .r = 60, .g = 120, .b = 210, .a = 255 } else .{ .r = 90, .g = 90, .b = 110, .a = 255 },
        .press_color = .{ .r = 30, .g = 60, .b = 120, .a = 255 },
    }, .{ .func = setBool, .ctx = pressed });
}

pub fn draw_import(ui: *widgets.WidgetStream, io: std.Io) data.Screen {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    const im = &data.import_state;
    const grey: rl.Color = .{ .r = 180, .g = 180, .b = 180, .a = 255 };

    const panel_w = @min(sw - 40, 640);
    const px = (sw - panel_w) / 2.0;
    const row_h: f32 = 40;
    const gap: f32 = 10;
    const col_w = (panel_w - gap * 3) / 4.0;
    var y: f32 = sh * 0.08;

    var role_pressed = [_]bool{false} ** 4;
    var diff_pressed = [_]bool{false} ** 4;
    var cancel_pressed = false;
    var create_pressed = false;
    var role_bufs: [4][32]u8 = undefined;
    var status_buf: [128]u8 = undefined;
    var preview_buf: [128]u8 = undefined;

    ui.begin();

    rl.drawText("Import Song", @intFromFloat(px), @intFromFloat(y), 36, rl.Color.white);
    y += 46;
    rl.drawText(&im.title, @intFromFloat(px), @intFromFloat(y), 22, grey);
    y += 40;

    const status: [:0]const u8 = switch (im.phase) {
        .idle => "Drop an .mp3 onto the window",
        .analyzing => if (im.cancelled) "Cancelling..." else blk: {
            const dots = "..."[0 .. @as(usize, @intFromFloat(rl.getTime() * 2)) % 4];
            break :blk std.fmt.bufPrintZ(&status_buf, "Analyzing{s}  (about 15 s)", .{dots}) catch "Analyzing...";
        },
        .ready => "Analysis done - pick an instrument and difficulty",
        .failed => std.fmt.bufPrintZ(&status_buf, "Import failed: {t}", .{im.err orelse error.Unknown}) catch "Import failed",
    };
    rl.drawText(status, @intFromFloat(px), @intFromFloat(y), 18, if (im.phase == .failed) rl.Color.red else grey);
    y += 40;

    const prev: ?[3]f32 = if (im.analysis) |r| chart.prevalences(r) else null;
    rl.drawText("Instrument", @intFromFloat(px), @intFromFloat(y), 20, rl.Color.white);
    y += 28;
    for (0..4) |i| {
        const role: ?chart.Role = if (i == 0) null else @enumFromInt(i - 1);
        const name = if (role) |r| @tagName(r) else "auto";
        const lbl: [:0]const u8 = if (role != null and prev != null)
            std.fmt.bufPrintZ(&role_bufs[i], "{s} {d:.0}%", .{ name, prev.?[i - 1] * 100 }) catch name
        else if (role == null and prev != null)
            std.fmt.bufPrintZ(&role_bufs[i], "auto ({s})", .{@tagName(chart.most_prevalent(prev.?))}) catch name
        else
            name;
        const rect = rl.Rectangle{ .x = px + @as(f32, @floatFromInt(i)) * (col_w + gap), .y = y, .width = col_w, .height = row_h };
        choice_button(ui, rect, lbl, im.role == role, &role_pressed[i]);
    }
    y += row_h + 24;

    rl.drawText("Difficulty", @intFromFloat(px), @intFromFloat(y), 20, rl.Color.white);
    y += 28;
    for (std.enums.values(chart.Difficulty), 0..) |d, i| {
        const rect = rl.Rectangle{ .x = px + @as(f32, @floatFromInt(i)) * (col_w + gap), .y = y, .width = col_w, .height = row_h };
        choice_button(ui, rect, @tagName(d), im.difficulty == d, &diff_pressed[i]);
    }
    y += row_h + 24;

    if (systems.import_preview()) |c| {
        const p = c.difficulty.params();
        const preview = std.fmt.bufPrintZ(&preview_buf, "{d} notes  |  {d:.0} BPM  |  {d} lanes  |  charting {s}", .{
            c.note_count, c.bps * 60 / @as(f32, @floatFromInt(p.subdivision)), p.lanes, @tagName(c.role),
        }) catch "";
        rl.drawText(preview, @intFromFloat(px), @intFromFloat(y), 18, grey);
    }

    const btn_w: f32 = 140;
    const btn_y = sh - 70;
    ui.button(.{ .x = px, .y = btn_y, .width = btn_w, .height = row_h }, "Cancel", .{ .func = setBool, .ctx = &cancel_pressed });
    const ready = im.phase == .ready;
    ui.buttonStyled(
        .{ .x = px + panel_w - btn_w, .y = btn_y, .width = btn_w, .height = row_h },
        .{
            .label = "Create",
            .color = if (ready) .{ .r = 30, .g = 80, .b = 30, .a = 255 } else .{ .r = 60, .g = 60, .b = 60, .a = 255 },
            .hover_color = if (ready) .{ .r = 50, .g = 120, .b = 50, .a = 255 } else .{ .r = 80, .g = 80, .b = 80, .a = 255 },
            .press_color = if (ready) .{ .r = 20, .g = 55, .b = 20, .a = 255 } else .{ .r = 50, .g = 50, .b = 50, .a = 255 },
        },
        if (ready) .{ .func = setBool, .ctx = &create_pressed } else null,
    );

    ui.processAndDraw();

    for (role_pressed, 0..) |pressed, i| if (pressed) {
        im.role = if (i == 0) null else @enumFromInt(i - 1);
    };
    for (diff_pressed, 0..) |pressed, i| if (pressed) {
        im.difficulty = @enumFromInt(i);
    };
    if (cancel_pressed) {
        const back = im.return_screen;
        systems.cancel_import(io);
        return back;
    }
    if (create_pressed and systems.finish_import(io)) return .songSelect;
    return .import_song;
}
