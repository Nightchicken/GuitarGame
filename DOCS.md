# Guitar Game

A Zig + raylib project targeting Zig 0.16.0.

## Dependencies

Uses [raylib-zig/raylib-zig](https://github.com/raylib-zig/raylib-zig) (community fork with Zig 0.16.0 support, raylib 6.0).

> Note: The original `Not-Nik/raylib-zig` is archived and not compatible with Zig 0.16.0.

## Commands

```sh
zig build        # compile
zig build run    # compile and run
```

## Project Structure

```
src/main.zig      # entry point — raylib window loop
src/widgets.zig   # immediate-mode widget stream (button, slider, checkbox, label)
src/screens.zig   # screen drawing functions
src/structs.zig   # shared data structures
build.zig         # build script
build.zig.zon     # package manifest with raylib dependency
```

## Game Screen — 5-Lane Track

The game screen draws a Guitar Hero-style 5-lane track using raw raylib calls (not widgets). Each lane spans 1/5 of the screen width with alternating dark backgrounds. A colored hit bar sits at 82% of screen height; fret buttons are circles centered on it that flash white when their key is held.

| Lane | Color  | Key   |
|------|--------|-------|
| 0    | Green  | A     |
| 1    | Red    | S     |
| 2    | Yellow | D     |
| 3    | Blue   | F     |
| 4    | Orange | Space |

## Responsive Layout

Main menu buttons and title scale proportionally with the window size. `btn_w` is 20% of screen width, `btn_h` is 7% of screen height, gap is 2% of screen height, and title font size is 8% of screen height. Button label font size is derived from the button's own height (44%), so text scales automatically with any button rect.

## Widget System (`src/widgets.zig`)

Data-oriented immediate-mode UI. Push widgets into a `WidgetStream` each frame, then call `processAndDraw`. Persistent hover/active state lives in `UiState` on the stream.

### Utilities

`centerIn(parent, child)` returns `child` repositioned so it is centered inside `parent`. Both are `rl.Rectangle`; only `x`/`y` change, `width`/`height` are preserved.

```zig
const screen = rl.Rectangle{ .x = 0, .y = 0, .width = sw, .height = sh };
const btn_rect = widgets.centerIn(screen, .{ .x = 0, .y = 0, .width = btn_w, .height = btn_h });
```

### Basic usage

```zig
const widgets = @import("widgets.zig");

var ui = widgets.WidgetStream{};
var volume: f32 = 0.5;
var muted: bool = false;

// inside game loop, between BeginDrawing / EndDrawing:
ui.begin();
ui.button(.{ .x = 10, .y = 10, .width = 120, .height = 34 }, "Play", .{
    .func = onPlay,
    .ctx = &game_state,
});
ui.slider(.{ .x = 10, .y = 60, .width = 200, .height = 20 }, "Volume", 0, 1, &volume, null);
ui.checkbox(.{ .x = 10, .y = 100, .width = 20, .height = 20 }, "Mute", &muted, null);
ui.label(.{ .x = 10, .y = 140, .width = 0, .height = 0 }, "Hello", 18, rl.WHITE);
ui.processAndDraw();
```

### Callbacks

```zig
fn onPlay(ctx: ?*anyopaque) void {
    const state: *GameState = @ptrCast(@alignCast(ctx.?));
    state.playing = true;
}
```

`Callback` is `{ func: *const fn(?*anyopaque) void, ctx: ?*anyopaque }`.

Slider and checkbox mutate the caller-owned `*f32`/`*bool` directly; the callback fires on each change as a side-effect hook.

### Widget IDs

IDs are assigned by push order starting at 1 each frame. Keep widget push order stable across frames for correct active-widget tracking (slider drag state persists via `UiState.active_id`).

## Adding raylib APIs

Import raylib in any source file:
```zig
const rl = @import("raylib");
```
