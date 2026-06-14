const rl = @import("raylib");
const std = @import("std");

pub const MAX_WIDGETS: usize = 256;

pub const Callback = struct {
    func: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque = null,

    pub fn call(self: Callback) void {
        self.func(self.ctx);
    }
};

pub const ButtonDesc = struct {
    label: [:0]const u8,
    color: rl.Color = rl.Color.gray,
    hover_color: rl.Color = rl.Color.light_gray,
    press_color: rl.Color = rl.Color.dark_gray,
};

pub const SliderDesc = struct {
    label: [:0]const u8,
    min: f32,
    max: f32,
    value: *f32,
};

pub const CheckboxDesc = struct {
    label: [:0]const u8,
    checked: *bool,
};

pub const LabelDesc = struct {
    text: [:0]const u8,
    fontSize: i32 = 20,
    color: rl.Color = rl.Color.white,
};

pub const WidgetDesc = union(enum) {
    button: ButtonDesc,
    slider: SliderDesc,
    checkbox: CheckboxDesc,
    label: LabelDesc,
};

pub const Widget = struct {
    id: u32,
    rect: rl.Rectangle,
    desc: WidgetDesc,
    callback: ?Callback = null,
    visible: bool = true,
};

// Persistent state across frames: tracks which widget is hot (hovered) or active (interacting)
pub const UiState = struct {
    hotId: u32 = 0,
    activeId: u32 = 0,
    dragOriginX: f32 = 0,
    dragOriginVal: f32 = 0,
};

pub fn centerIn(parent: rl.Rectangle, child: rl.Rectangle) rl.Rectangle {
    return .{
        .x = parent.x + (parent.width - child.width) / 2.0,
        .y = parent.y + (parent.height - child.height) / 2.0,
        .width = child.width,
        .height = child.height,
    };
}

pub const WidgetStream = struct {
    buf: [MAX_WIDGETS]Widget = undefined,
    len: usize = 0,
    ui: UiState = .{},
    _next_id: u32 = 1,

    // Call once per frame before pushing widgets
    pub fn begin(self: *WidgetStream) void {
        self.len = 0;
        self._next_id = 1;
        self.ui.hotId = 0;
    }

    pub fn button(self: *WidgetStream, rect: rl.Rectangle, lbl: [:0]const u8, cb: ?Callback) void {
        self.push(rect, .{ .button = .{ .label = lbl } }, cb);
    }

    pub fn buttonStyled(self: *WidgetStream, rect: rl.Rectangle, desc: ButtonDesc, cb: ?Callback) void {
        self.push(rect, .{ .button = desc }, cb);
    }

    // value is a pointer owned by the caller; the slider reads and writes through it
    pub fn slider(self: *WidgetStream, rect: rl.Rectangle, lbl: [:0]const u8, min: f32, max: f32, value: *f32, cb: ?Callback) void {
        self.push(rect, .{ .slider = .{ .label = lbl, .min = min, .max = max, .value = value } }, cb);
    }

    // checked is a pointer owned by the caller; toggled in place on click
    pub fn checkbox(self: *WidgetStream, rect: rl.Rectangle, lbl: [:0]const u8, checked: *bool, cb: ?Callback) void {
        self.push(rect, .{ .checkbox = .{ .label = lbl, .checked = checked } }, cb);
    }

    pub fn label(self: *WidgetStream, rect: rl.Rectangle, text: [:0]const u8, fontSize: i32, color: rl.Color) void {
        self.push(rect, .{ .label = .{ .text = text, .fontSize = fontSize, .color = color } }, null);
    }

    // Call once per frame after pushing all widgets; handles input and draws
    pub fn processAndDraw(self: *WidgetStream) void {
        const mouse = rl.getMousePosition();
        const pressed = rl.isMouseButtonPressed(.left);
        const released = rl.isMouseButtonReleased(.left);
        const down = rl.isMouseButtonDown(.left);

        for (self.buf[0..self.len]) |*w| {
            if (!w.visible) continue;
            switch (w.desc) {
                .button => |*d| self.drawButton(w, d, mouse, pressed, down),
                .slider => |*d| self.drawSlider(w, d, mouse, pressed, released, down),
                .checkbox => |*d| self.drawCheckbox(w, d, mouse, pressed),
                .label => |*d| drawLabel(w.rect, d),
            }
        }
    }

    fn push(self: *WidgetStream, rect: rl.Rectangle, desc: WidgetDesc, cb: ?Callback) void {
        if (self.len >= MAX_WIDGETS) return;
        self.buf[self.len] = .{ .id = self._next_id, .rect = rect, .desc = desc, .callback = cb };
        self._next_id += 1;
        self.len += 1;
    }

    fn drawButton(self: *WidgetStream, w: *Widget, d: *ButtonDesc, mouse: rl.Vector2, pressed: bool, down: bool) void {
        const hovered = rl.checkCollisionPointRec(mouse, w.rect);
        if (hovered) self.ui.hotId = w.id;

        const color = if (hovered and down) d.press_color else if (hovered) d.hover_color else d.color;
        rl.drawRectangleRec(w.rect, color);

        const fontSize: i32 = @intFromFloat(w.rect.height * 0.44);
        const textW = rl.measureText(d.label, fontSize);
        rl.drawText(
            d.label,
            @as(i32, @intFromFloat(w.rect.x + (w.rect.width - @as(f32, @floatFromInt(textW))) / 2.0)),
            @as(i32, @intFromFloat(w.rect.y + (w.rect.height - @as(f32, @floatFromInt(fontSize))) / 2.0)),
            fontSize,
            rl.Color.black,
        );

        if (hovered and pressed) {
            if (w.callback) |cb| cb.call();
        }
    }

    fn drawSlider(self: *WidgetStream, w: *Widget, d: *SliderDesc, mouse: rl.Vector2, pressed: bool, released: bool, down: bool) void {
        const hovered = rl.checkCollisionPointRec(mouse, w.rect);
        if (hovered) self.ui.hotId = w.id;

        if (hovered and pressed) {
            self.ui.activeId = w.id;
            self.ui.dragOriginX = mouse.x;
            self.ui.dragOriginVal = d.value.*;
        }

        if (self.ui.activeId == w.id) {
            if (down) {
                const dx = mouse.x - self.ui.dragOriginX;
                const newVal = std.math.clamp(
                    self.ui.dragOriginVal + dx * (d.max - d.min) / w.rect.width,
                    d.min,
                    d.max,
                );
                if (newVal != d.value.*) {
                    d.value.* = newVal;
                    if (w.callback) |cb| cb.call();
                }
            }
            if (released) self.ui.activeId = 0;
        }

        const trackH: f32 = 6;
        const trackY = w.rect.y + (w.rect.height - trackH) / 2.0;
        const t = std.math.clamp((d.value.* - d.min) / (d.max - d.min), 0.0, 1.0);
        const fillW = t * w.rect.width;
        const thumbR = w.rect.height / 2.0;

        rl.drawRectangleRec(.{ .x = w.rect.x, .y = trackY, .width = w.rect.width, .height = trackH }, rl.Color.dark_gray);
        rl.drawRectangleRec(.{ .x = w.rect.x, .y = trackY, .width = fillW, .height = trackH }, rl.Color.sky_blue);
        rl.drawRectangleRec(
            .{ .x = w.rect.x + fillW - thumbR, .y = w.rect.y, .width = thumbR * 2, .height = w.rect.height },
            if (self.ui.activeId == w.id) rl.Color.blue else if (hovered) rl.Color.light_gray else rl.Color.gray,
        );

        const fontSize: i32 = 14;
        rl.drawText(
            d.label,
            @as(i32, @intFromFloat(w.rect.x)),
            @as(i32, @intFromFloat(w.rect.y - @as(f32, @floatFromInt(fontSize)) - 2.0)),
            fontSize,
            rl.Color.white,
        );
    }

    fn drawCheckbox(self: *WidgetStream, w: *Widget, d: *CheckboxDesc, mouse: rl.Vector2, pressed: bool) void {
        const box = rl.Rectangle{ .x = w.rect.x, .y = w.rect.y, .width = w.rect.height, .height = w.rect.height };
        const hovered = rl.checkCollisionPointRec(mouse, box);
        if (hovered) self.ui.hotId = w.id;

        rl.drawRectangleRec(box, if (hovered) rl.Color.light_gray else rl.Color.gray);
        if (d.checked.*) {
            const pad: f32 = 4;
            rl.drawRectangleRec(.{
                .x = box.x + pad,
                .y = box.y + pad,
                .width = box.width - pad * 2,
                .height = box.height - pad * 2,
            }, rl.Color.green);
        }

        const fontSize: i32 = 16;
        rl.drawText(
            d.label,
            @as(i32, @intFromFloat(w.rect.x + w.rect.height + 8)),
            @as(i32, @intFromFloat(w.rect.y + (w.rect.height - @as(f32, @floatFromInt(fontSize))) / 2.0)),
            fontSize,
            rl.Color.white,
        );

        if (hovered and pressed) {
            d.checked.* = !d.checked.*;
            if (w.callback) |cb| cb.call();
        }
    }

    fn drawLabel(rect: rl.Rectangle, d: *LabelDesc) void {
        rl.drawText(d.text, @as(i32, @intFromFloat(rect.x)), @as(i32, @intFromFloat(rect.y)), d.fontSize, d.color);
    }
};

// ── DragListOverlay ──────────────────────────────────────────────────────────
// A self-contained reorderable list overlay with drag handles and remove buttons.
// Usage: keep a DragListOverlay in persistent state (e.g. a file-level var or
// a struct field). Call draw() each frame when visible.

pub const ReorderOp = struct { from: usize, to: usize };

pub const DragListResult = struct {
    closed: bool = false,
    addPressed: bool = false,
    removeIdx: ?usize = null,
    reorder: ?ReorderOp = null,
};

pub const DragListOverlay = struct {
    dragIdx: ?usize = null,
    dragY: f32 = 0,
    dragGrabY: f32 = 0,

    // Draw the overlay and return what happened this frame.
    // items: labels in display order (caller owns the slice; rebuild each frame from your data).
    // rect:  bounds of the entire overlay panel.
    pub fn draw(
        self: *DragListOverlay,
        titleText: [:0]const u8,
        items: []const [:0]const u8,
        rect: rl.Rectangle,
    ) DragListResult {
        var result = DragListResult{};
        const mouse = rl.getMousePosition();
        const clicked = rl.isMouseButtonPressed(.left);
        const released = rl.isMouseButtonReleased(.left);
        const held = rl.isMouseButtonDown(.left);

        const headerH: f32 = 42;
        const footerH: f32 = 46;
        const rowH: f32 = 44;
        const listY = rect.y + headerH;
        const textSz: i32 = 14;
        const rmW: f32 = 28;
        const rmPad: f32 = 6;

        // Panel background + border
        rl.drawRectangleRec(rect, .{ .r = 18, .g = 18, .b = 28, .a = 248 });
        rl.drawRectangleLinesEx(rect, 1.5, .{ .r = 75, .g = 75, .b = 105, .a = 255 });

        // Title (centered in header)
        const titleSz: i32 = 18;
        const tw = rl.measureText(titleText, titleSz);
        rl.drawText(titleText, @intFromFloat(rect.x + (rect.width - @as(f32, @floatFromInt(tw))) / 2.0), @intFromFloat(rect.y + (headerH - @as(f32, @floatFromInt(titleSz))) / 2.0), titleSz, rl.Color.white);

        // Back button (left side of header)
        const backTxt = "< Back";
        const backSz: i32 = 14;
        const backW: f32 = @floatFromInt(rl.measureText(backTxt, backSz) + 16);
        const backH: f32 = 28;
        const backR = rl.Rectangle{
            .x = rect.x + 6,
            .y = rect.y + (headerH - backH) / 2.0,
            .width = backW,
            .height = backH,
        };
        const backHot = rl.checkCollisionPointRec(mouse, backR);
        rl.drawRectangleRec(backR, if (backHot) .{ .r = 70, .g = 70, .b = 95, .a = 255 } else .{ .r = 45, .g = 45, .b = 65, .a = 255 });
        const btw = rl.measureText(backTxt, backSz);
        rl.drawText(backTxt, @intFromFloat(backR.x + (backW - @as(f32, @floatFromInt(btw))) / 2.0), @intFromFloat(backR.y + (backH - @as(f32, @floatFromInt(backSz))) / 2.0), backSz, rl.Color.white);
        if (backHot and clicked) result.closed = true;

        // Header separator
        rl.drawLineEx(.{ .x = rect.x + 4, .y = rect.y + headerH }, .{ .x = rect.x + rect.width - 4, .y = rect.y + headerH }, 1, .{ .r = 70, .g = 70, .b = 95, .a = 180 });

        // ── Rows ──
        // Pass 1: non-dragged rows. Pass 2: dragged row on top.
        var removeIdx: ?usize = null;
        var newDrag: ?struct { idx: usize, ry: f32 } = null;

        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            var adj: usize = 0; // visual slot (excludes the dragged item)
            for (items, 0..) |label, i| {
                const isDrag = (self.dragIdx != null and self.dragIdx.? == i);
                if (pass == 0 and isDrag) {
                    continue;
                }
                if (pass == 1 and !isDrag) {
                    if (!isDrag) adj += 1;
                    continue;
                }

                const ry: f32 = if (isDrag)
                    self.dragY
                else
                    listY + @as(f32, @floatFromInt(adj)) * rowH;

                if (!isDrag) adj += 1;

                // Row background (alternating, lifted when dragging)
                const rowBg: rl.Color = if (isDrag)
                    .{ .r = 60, .g = 60, .b = 88, .a = 220 }
                else if (adj % 2 == 0)
                    .{ .r = 28, .g = 28, .b = 42, .a = 255 }
                else
                    .{ .r = 36, .g = 36, .b = 52, .a = 255 };
                rl.drawRectangleRec(.{ .x = rect.x + 4, .y = ry + 1, .width = rect.width - 8, .height = rowH - 2 }, rowBg);

                // Drag handle: three horizontal lines on the left
                for (0..3) |li| {
                    const lfy = ry + rowH / 2.0 - 4.0 + @as(f32, @floatFromInt(li)) * 4.0;
                    rl.drawLineEx(.{ .x = rect.x + 8, .y = lfy }, .{ .x = rect.x + 21, .y = lfy }, 1.5, .{ .r = 100, .g = 100, .b = 120, .a = 190 });
                }

                // Label text
                rl.drawText(label, @intFromFloat(rect.x + 28), @intFromFloat(ry + (rowH - @as(f32, @floatFromInt(textSz))) / 2.0), textSz, rl.Color.white);

                // Remove [X] button
                const rmR = rl.Rectangle{
                    .x = rect.x + rect.width - rmW - rmPad,
                    .y = ry + (rowH - 24) / 2.0,
                    .width = rmW,
                    .height = 24,
                };
                const rmHot = rl.checkCollisionPointRec(mouse, rmR);
                rl.drawRectangleRec(rmR, if (rmHot) .{ .r = 180, .g = 40, .b = 40, .a = 255 } else .{ .r = 110, .g = 25, .b = 25, .a = 255 });
                const rxw = rl.measureText("X", textSz);
                rl.drawText("X", @intFromFloat(rmR.x + (rmW - @as(f32, @floatFromInt(rxw))) / 2.0), @intFromFloat(rmR.y + (24.0 - @as(f32, @floatFromInt(textSz))) / 2.0), textSz, rl.Color.white);
                if (rmHot and clicked and !isDrag) removeIdx = i;

                // Drag start: click on row (not the remove button)
                if (!rmHot and clicked and self.dragIdx == null and !isDrag) {
                    const dragArea = rl.Rectangle{
                        .x = rect.x,
                        .y = ry,
                        .width = rect.width - rmW - rmPad - 2,
                        .height = rowH,
                    };
                    if (rl.checkCollisionPointRec(mouse, dragArea)) {
                        newDrag = .{ .idx = i, .ry = ry };
                    }
                }
            }
        }

        // Apply drag start after the loop (avoid mutating self mid-loop)
        if (newDrag) |nd| {
            self.dragIdx = nd.idx;
            self.dragY = nd.ry;
            self.dragGrabY = mouse.y - nd.ry;
        }

        // Update drag position
        if (self.dragIdx != null and held) {
            self.dragY = mouse.y - self.dragGrabY;
        }

        // Drop: compute insertion point and emit reorder
        if (self.dragIdx) |di| {
            if (released) {
                var insertAt: usize = items.len;
                var adj: usize = 0;
                for (items, 0..) |_, i| {
                    if (i == di) continue;
                    const ny = listY + @as(f32, @floatFromInt(adj)) * rowH;
                    if (self.dragY + rowH / 2.0 < ny + rowH / 2.0) {
                        insertAt = i;
                        break;
                    }
                    adj += 1;
                }
                if (insertAt != di) result.reorder = .{ .from = di, .to = insertAt };
                self.dragIdx = null;
            }
        }

        if (removeIdx) |idx| result.removeIdx = idx;

        // Footer separator + Add Song button
        rl.drawLineEx(.{ .x = rect.x + 4, .y = rect.y + rect.height - footerH }, .{ .x = rect.x + rect.width - 4, .y = rect.y + rect.height - footerH }, 1, .{ .r = 70, .g = 70, .b = 95, .a = 180 });

        const addR = rl.Rectangle{
            .x = rect.x + rect.width * 0.25,
            .y = rect.y + rect.height - footerH + (footerH - 30) / 2.0,
            .width = rect.width * 0.5,
            .height = 30,
        };
        const addHot = rl.checkCollisionPointRec(mouse, addR);
        rl.drawRectangleRec(addR, if (addHot) .{ .r = 50, .g = 85, .b = 50, .a = 255 } else .{ .r = 32, .g = 58, .b = 32, .a = 255 });
        const addTxt = "+ Add Song";
        const addSz: i32 = 13;
        const aw = rl.measureText(addTxt, addSz);
        rl.drawText(addTxt, @intFromFloat(addR.x + (addR.width - @as(f32, @floatFromInt(aw))) / 2.0), @intFromFloat(addR.y + (addR.height - @as(f32, @floatFromInt(addSz))) / 2.0), addSz, rl.Color.white);
        if (addHot and clicked) result.addPressed = true;

        return result;
    }
};
