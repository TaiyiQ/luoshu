const std = @import("std");
const rl = @import("raylib");
const arch = @import("arch");

const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

const Point = struct { x: i32, y: i32 };
const RamanTarget = struct { qubit: u32, pos: Point };
const MoveAtom = struct { qubit: u32, src: Point, dest: Point };

const Raman = struct {
    angle: f32,
    phase: f32,
    targets: []const RamanTarget,
};

const Move = struct {
    aod: u32,
    translate: Axis,
    src_zone: Zone,
    dest_zone: Zone,
    atoms: []const MoveAtom,
};

const Rydberg = struct { zone: Zone };

const Measure = struct { zone: Zone, qubits: []u32 };

const OpKind = union(enum) {
    raman: Raman,
    move: Move,
    rydberg: Rydberg,
    measure: Measure,
};

fn fmtNm(nm: i32) struct { val: f64, sign: u8 } {
    return .{
        .val = @abs(@as(f64, @floatFromInt(nm))) / 1000.0,
        .sign = if (nm < 0) '-' else ' ',
    };
}

const Op = struct {
    t: u32,
    kind: OpKind,

    pub fn print(self: Op) void {
        std.debug.print("t={d:0>3}  ", .{self.t});
        switch (self.kind) {
            .move => |m| {
                std.debug.print("move   aod={d}  axis={s}  {s} → {s}\n", .{
                    m.aod,
                    @tagName(m.translate),
                    @tagName(m.src_zone),
                    @tagName(m.dest_zone),
                });
                for (m.atoms) |atom| {
                    const sx = fmtNm(atom.src.x);
                    const sy = fmtNm(atom.src.y);
                    const dx = fmtNm(atom.dest.x);
                    const dy = fmtNm(atom.dest.y);
                    std.debug.print(
                        "         q{d:<2} ({c}{d:>5.1}, {c}{d:>5.1}) → ({c}{d:>5.1}, {c}{d:>5.1})\n",
                        .{
                            atom.qubit,
                            sx.sign,
                            sx.val,
                            sy.sign,
                            sy.val,
                            dx.sign,
                            dx.val,
                            dy.sign,
                            dy.val,
                        },
                    );
                }
            },
            .raman => |r| {
                std.debug.print("raman  angle={d:.4}  phase={d:.4}\n", .{ r.angle, r.phase });
                for (r.targets) |tgt| {
                    const px = fmtNm(tgt.pos.x);
                    const py = fmtNm(tgt.pos.y);
                    std.debug.print("         q{d:<2} ({c}{d:>5.1}, {c}{d:>5.1})\n", .{
                        tgt.qubit, px.sign, px.val, py.sign, py.val,
                    });
                }
            },
            .rydberg => |r| {
                std.debug.print("rydberg zone={s}\n", .{@tagName(r.zone)});
            },
            .measure => |m| {
                std.debug.print("measure zone={s}  qubits=[", .{@tagName(m.zone)});
                for (m.qubits, 0..) |q, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{d}", .{q});
                }
                std.debug.print("]\n", .{});
            },
        }
    }
};

const PhysicalSchedule = struct {
    arena: std.heap.ArenaAllocator,
    ops: []const Op,
    placement: []Point, // Index corresponds to qubit id.
    compute_slots: []const Point, // SLM trap sites in the entanglement zone.

    pub fn deinit(s: *PhysicalSchedule) void {
        s.arena.deinit();
    }

    /// Open a raylib window and step through the schedule interactively.
    ///   j / k     step back / forward one frame
    ///   space     toggle auto-play
    ///   esc       quit (raylib's default)
    pub fn showSlideshow(
        self: *const PhysicalSchedule,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.placement.len == 0 or self.ops.len == 0) return;

        // Positions of every qubit before any operation has been applied.
        const positions0 = try initialPositions(allocator, self.placement, self.ops);
        defer allocator.free(positions0);

        // Pre-compute each frame's position state so the user can scrub back
        // and forth without re-simulating the schedule on every keystroke.
        const frames = self.ops.len;
        const positions_per_frame = try allocator.alloc([]Point, frames);
        defer {
            for (positions_per_frame) |row| allocator.free(row);
            allocator.free(positions_per_frame);
        }
        {
            const cur = try allocator.dupe(Point, positions0);
            defer allocator.free(cur);
            for (self.ops, 0..) |op, i| {
                positions_per_frame[i] = try allocator.dupe(Point, cur);
                applyOp(cur, op);
            }
        }

        // Camera bounds are derived from every position the slideshow ever
        // touches, so the same projection is valid for every frame.
        const cam = try computeCamera(allocator, positions0, self.ops, self.compute_slots);
        defer allocator.free(cam.zones);

        // Scratch buffer reused each frame to mark which qubits are "active".
        const active = try allocator.alloc(bool, positions0.len);
        defer allocator.free(active);

        // ---- raylib window ---------------------------------------------------
        rl.initWindow(
            @intFromFloat(Camera.canvas_w),
            @intFromFloat(Camera.canvas_h),
            "Physical schedule slideshow",
        );
        defer rl.closeWindow();
        rl.setTargetFPS(60);

        var frame: usize = 0;
        var playing: bool = false;
        var play_timer: f32 = 0.0;
        const play_period: f32 = 0.7;

        while (!rl.windowShouldClose()) {
            // ---- input ------------------------------------------------------
            if (rl.isKeyPressed(.k)) {
                playing = false;
                if (frame + 1 < frames) frame += 1;
            }
            if (rl.isKeyPressed(.j)) {
                playing = false;
                if (frame > 0) frame -= 1;
            }
            if (rl.isKeyPressed(.space)) {
                playing = !playing;
                play_timer = 0;
            }

            if (playing) {
                play_timer += rl.getFrameTime();
                if (play_timer >= play_period) {
                    play_timer = 0;
                    if (frame + 1 < frames) {
                        frame += 1;
                    } else {
                        playing = false;
                    }
                }
            }

            // ---- draw -------------------------------------------------------
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(palette.bg);
            drawFrame(
                cam,
                positions_per_frame[frame],
                self.compute_slots,
                active,
                self.ops[frame],
                frame,
                frames,
                playing,
            );
        }
    }

    pub fn dumpSvg(
        self: *const PhysicalSchedule,
        allocator: std.mem.Allocator,
        io: std.Io,
        filename: []const u8,
    ) !void {
        if (self.placement.len == 0) return;

        // Bounding box of all qubit positions (nm).
        var min_x = self.placement[0].x;
        var max_x = min_x;
        var min_y = self.placement[0].y;
        var max_y = min_y;
        for (self.placement[1..]) |p| {
            if (p.x < min_x) min_x = p.x;
            if (p.x > max_x) max_x = p.x;
            if (p.y < min_y) min_y = p.y;
            if (p.y > max_y) max_y = p.y;
        }

        // Fit-and-center transform from physical nm to SVG px.
        const canvas_w: f64 = 680.0;
        const canvas_h: f64 = 460.0;
        const margin: f64 = 60.0;
        const span_x: f64 = @floatFromInt(max_x - min_x);
        const span_y: f64 = @floatFromInt(max_y - min_y);
        const scale_x: f64 = if (span_x > 0) (canvas_w - 2 * margin) / span_x else 1.0;
        const scale_y: f64 = if (span_y > 0) (canvas_h - 2 * margin) / span_y else 1.0;
        const scale = @min(scale_x, scale_y);
        const off_x = (canvas_w - span_x * scale) / 2.0;
        const off_y = (canvas_h - span_y * scale) / 2.0;

        // Trap radius: 35% of the closest-pair distance, clamped.
        // O(n^2) but n is small for debug output.
        var min_gap_sq: f64 = 0.0;
        var found_gap = false;
        for (self.placement, 0..) |a, i| {
            for (self.placement[i + 1 ..]) |b| {
                const adx: f64 = @floatFromInt(a.x - b.x);
                const ady: f64 = @floatFromInt(a.y - b.y);
                const d_sq = adx * adx + ady * ady;
                if (d_sq > 0 and (!found_gap or d_sq < min_gap_sq)) {
                    min_gap_sq = d_sq;
                    found_gap = true;
                }
            }
        }
        const radius: f64 = if (found_gap) @sqrt(min_gap_sq) * scale * 0.35 else 20.0;

        // Build SVG in a buffer.
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        try w.writeAll(
            \\<svg xmlns="http://www.w3.org/2000/svg" width="680" height="460" viewBox="0 0 680 460">
            \\  <title>Storage zone placement</title>
            \\  <defs><style>
            \\    .qubit  { fill: #E1F5EE; stroke: #0F6E56; stroke-width: 0.5; }
            \\    .qlabel { font: 500 14px system-ui, sans-serif; fill: #085041;
            \\              text-anchor: middle; dominant-baseline: central; }
            \\  </style></defs>
            \\
        );

        for (self.placement, 0..) |p, id| {
            const dx: f64 = @floatFromInt(p.x - min_x);
            // Physical y points up; SVG y points down — flip so max_y is at the top.
            const dy: f64 = @floatFromInt(max_y - p.y);
            const sx = off_x + dx * scale;
            const sy = off_y + dy * scale;
            try w.print(
                \\  <circle class="qubit" cx="{d:.1}" cy="{d:.1}" r="{d:.1}"/>
                \\  <text class="qlabel" x="{d:.1}" y="{d:.1}">{d}</text>
                \\
            , .{ sx, sy, radius, sx, sy, id });
        }

        try w.writeAll("</svg>\n");

        const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, buf.written(), 0);
    }
};

pub fn physicalSchedule(allocator: std.mem.Allocator, layout: arch.ArchConfig, logical: Schedule) !PhysicalSchedule {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // FIXME: Update the qubit count.
    const max_qubit = layout.storage_zone.slm.num_col * layout.storage_zone.slm.num_row;
    const placement = try a.alloc(Point, max_qubit);

    try storagePlacement(layout, placement);

    // Enumerate every SLM trap site in the entanglement zone. These are drawn
    // as background indicators in the slideshow (grey ring = empty, green = occupied).
    var slots: std.ArrayListUnmanaged(Point) = .empty;
    for (layout.entanglement_zone.slms) |slm| {
        const x0 = layout.entanglement_zone.offset_nm[0] + slm.offset_nm[0];
        const y0 = layout.entanglement_zone.offset_nm[1] + slm.offset_nm[1];
        const x_sep_s: i32 = @intCast(slm.sep_nm[0]);
        const y_sep_s: i32 = @intCast(slm.sep_nm[1]);
        for (0..slm.num_row) |ri| for (0..slm.num_col) |ci| {
            try slots.append(a, .{
                .x = x0 + @as(i32, @intCast(ci)) * x_sep_s,
                .y = y0 + @as(i32, @intCast(ri)) * y_sep_s,
            });
        };
    }
    const compute_slots = try slots.toOwnedSlice(a);

    // FIXME: Only move operations for now.
    // One move per timestep (color).
    //const n_timesteps = @as(usize, @intCast(logical.max_color));

    const ent = layout.entanglement_zone;

    const control = layout.entanglement_zone.slms[0];
    const x_slm_orig = ent.offset_nm[0] + control.offset_nm[0];
    const y_slm_orig = ent.offset_nm[1] + control.offset_nm[1];
    const x_sep = control.sep_nm[0];

    std.debug.print("{} {} {}\n", .{ x_slm_orig, y_slm_orig, x_sep });

    // NOTE: There is a relationship between the logical timesteps and the coloring steps.
    // For example, we need to place the SLMs first (t0).

    var ops: std.ArrayList(Op) = .empty;

    var atomsSlm: std.ArrayList(MoveAtom) = .empty;
    for (logical.slm_slots, 0..) |maybe_slm, i| {
        const x = x_slm_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_sep));
        const y = y_slm_orig + @as(i32, @intCast(control.sep_nm[1]));

        if (maybe_slm) |qubit_id| {
            const src = placement[qubit_id];
            const dest = Point{ .x = x, .y = y };

            try atomsSlm.append(allocator, MoveAtom{
                .qubit = @as(u32, @intCast(qubit_id)),
                .src = src,
                .dest = dest,
            });

            placement[qubit_id] = dest;
        }
    }

    var op = Op{ .t = 0, .kind = .{
        .move = .{
            .aod = 0,
            .translate = Axis.y,
            .src_zone = Zone.storage,
            .dest_zone = Zone.compute,
            .atoms = atomsSlm.items,
        },
    } };
    try ops.append(allocator, op);

    std.debug.print(">> SLM Operations\n", .{});
    op.print();

    // --------------------------------

    // 2. Use second SLM in the compute zone for AOD qubits (targets).
    const target = layout.entanglement_zone.slms[1];
    const x_aod_orig = ent.offset_nm[0] + target.offset_nm[0];
    const y_aod_orig = ent.offset_nm[1] + target.offset_nm[1];
    std.debug.print("----- {}\n", .{target.offset_nm[1]});
    const x_aod_sep = target.sep_nm[0];

    for (logical.aod_slots_per_color, 0..) |aod_row, t| {
        var atomsAod: std.ArrayList(MoveAtom) = .empty;

        for (aod_row, 0..) |maybe_aod, i| {
            const x = x_aod_orig + @as(i32, @intCast(i)) * @as(i32, @intCast(x_aod_sep));
            const y = y_aod_orig + @as(i32, @intCast(target.sep_nm[1]));

            if (maybe_aod) |qubit_id| {
                const src = placement[qubit_id];
                const dest = Point{ .x = x, .y = y };

                try atomsAod.append(allocator, MoveAtom{
                    .qubit = @as(u32, @intCast(qubit_id)),
                    .src = src,
                    .dest = dest,
                });

                placement[qubit_id] = dest;
            }
        }

        op = Op{ .t = @as(u32, @intCast(t)) + 1, .kind = .{
            .move = .{
                .aod = 0,
                .translate = Axis.y,
                .src_zone = Zone.storage,
                .dest_zone = Zone.compute,
                .atoms = atomsAod.items,
            },
        } };
        try ops.append(allocator, op);
    }

    return .{
        .arena = arena,
        .ops = ops.items,
        .placement = placement,
        .compute_slots = compute_slots,
    };
}

pub fn storagePlacement(layout: arch.ArchConfig, placement: []Point) !void {
    const zone = layout.storage_zone;
    const slm = layout.storage_zone.slm;

    // Relative starting origin of grid (bottom-left).
    const x_orig = zone.offset_nm[0] + slm.offset_nm[0];
    const y_orig = zone.offset_nm[1] + slm.offset_nm[1];

    // Seperation spacing between grid items.
    const x_sep = @as(i32, @intCast(slm.sep_nm[0]));
    const y_sep = @as(i32, @intCast(slm.sep_nm[1]));

    var qubit_id: u32 = 0;

    for (0..slm.num_row) |i| {
        for (0..slm.num_col) |j| {
            const x = x_orig + @as(i32, @intCast(j)) * x_sep;
            const y = y_orig + @as(i32, @intCast(i)) * y_sep;
            placement[qubit_id] = Point{ .x = x, .y = y };
            qubit_id += 1;
        }
    }
}

pub const Schedule = struct {
    slm_slots: []const ?usize,
    aod_slots_per_color: [][]?usize,
    max_color: i32,

    pub fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        allocator.free(self.slm_slots);
        for (self.aod_slots_per_color) |slot| allocator.free(slot);
        allocator.free(self.aod_slots_per_color);
    }

    pub fn print(self: Schedule) void {
        const n_slots = self.slm_slots.len;

        std.debug.print("\n", .{});

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        std.debug.print(" SLM |", .{});
        for (self.slm_slots) |v| {
            if (v) |id| std.debug.print("{d:^5}|", .{id}) else std.debug.print("  ·  |", .{});
        }
        std.debug.print("\n", .{});

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        for (self.aod_slots_per_color, 0..) |aod_slot, t| {
            std.debug.print("  t{d} |", .{t});
            for (aod_slot, 0..) |v, s| {
                const has_slm = self.slm_slots[s] != null;
                if (v) |id| {
                    if (has_slm) std.debug.print(" {d:^3} |", .{id}) else std.debug.print("{d:^5}|", .{id});
                } else {
                    std.debug.print("  ·  |", .{});
                }
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});
        std.debug.print("\n", .{});
    }
};

pub fn toJson(allocator: std.mem.Allocator, schedule: *const Schedule) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");

    try w.writeAll("  \"slm_slots\": [");
    for (schedule.slm_slots, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
    }
    try w.writeAll("],\n");

    try w.writeAll("  \"aod_slots_per_color\": [\n");
    for (schedule.aod_slots_per_color, 0..) |row, ci| {
        try w.writeAll("    [");
        for (row, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
        }
        const last = ci == schedule.aod_slots_per_color.len - 1;
        try w.writeAll(if (last) "]\n" else "],\n");
    }
    try w.writeAll("  ],\n");

    try w.print("  \"max_color\": {d}\n", .{schedule.max_color});
    try w.writeAll("}");

    return allocator.dupe(u8, buf.written());
}

pub fn writeToFile(allocator: std.mem.Allocator, io: std.Io, schedule: *const Schedule, filename: []const u8) !void {
    const json = try toJson(allocator, schedule);
    defer allocator.free(json);

    const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
}

const Zone2 = struct {
    y_lo: i32,
    y_hi: i32,
    x_lo: i32,
    x_hi: i32,
    band_top: f64,
    band_bot: f64,
};

const Camera = struct {
    zones: []const Zone2,
    radius: f64,

    const canvas_w: f64 = 1000;
    const canvas_h: f64 = 700;
    const header_h: f64 = 70;
    const margin: f64 = 50;
    const band_gap: f64 = 36;

    fn zoneOf(self: Camera, p: Point) Zone2 {
        for (self.zones) |z| if (p.y >= z.y_lo and p.y <= z.y_hi) return z;
        return self.zones[0];
    }

    fn project(self: Camera, p: Point) struct { x: f64, y: f64 } {
        const z = self.zoneOf(p);
        const x_span: f64 = @floatFromInt(z.x_hi - z.x_lo);
        const y_span: f64 = @floatFromInt(z.y_hi - z.y_lo);
        const draw_w = canvas_w - 2 * margin;
        const px = if (x_span > 0)
            margin + @as(f64, @floatFromInt(p.x - z.x_lo)) * (draw_w / x_span)
        else
            canvas_w / 2.0;
        const py = if (y_span > 0)
            z.band_bot - @as(f64, @floatFromInt(p.y - z.y_lo)) / y_span * (z.band_bot - z.band_top)
        else
            (z.band_top + z.band_bot) / 2.0;
        return .{ .x = px, .y = py };
    }
};

fn computeCamera(allocator: std.mem.Allocator, positions: []const Point, ops: []const Op, slots: []const Point) !Camera {
    // 1. Every y value the slideshow will touch.
    var ys: std.ArrayListUnmanaged(i32) = .empty;
    defer ys.deinit(allocator);
    for (positions) |p| try ys.append(allocator, p.y);
    for (slots) |s| try ys.append(allocator, s.y);
    for (ops) |op| switch (op.kind) {
        .move => |m| for (m.atoms) |a| {
            try ys.append(allocator, a.src.y);
            try ys.append(allocator, a.dest.y);
        },
        else => {},
    };
    std.mem.sort(i32, ys.items, {}, std.sort.asc(i32));

    // 2. Smallest non-zero gap; anything ≥10× this is a zone boundary.
    var min_gap: i32 = std.math.maxInt(i32);
    for (ys.items[1..], 0..) |v, i| {
        const g = v - ys.items[i];
        if (g > 0 and g < min_gap) min_gap = g;
    }
    if (min_gap == std.math.maxInt(i32)) min_gap = 1;
    const threshold = min_gap * 10;

    // 3. Cut into zones at the big gaps.
    var zones: std.ArrayListUnmanaged(Zone2) = .empty;
    var lo = ys.items[0];
    for (ys.items[1..], 0..) |v, i| {
        if (v - ys.items[i] > threshold) {
            try zones.append(allocator, .{ .y_lo = lo, .y_hi = ys.items[i], .x_lo = 0, .x_hi = 0, .band_top = 0, .band_bot = 0 });
            lo = v;
        }
    }
    try zones.append(allocator, .{ .y_lo = lo, .y_hi = ys.items[ys.items.len - 1], .x_lo = 0, .x_hi = 0, .band_top = 0, .band_bot = 0 });

    // 4. Per-zone x extent.
    for (zones.items) |*z| {
        z.x_lo = std.math.maxInt(i32);
        z.x_hi = std.math.minInt(i32);
    }
    const considerPoint = struct {
        fn f(zs: []Zone2, p: Point) void {
            for (zs) |*z| if (p.y >= z.y_lo and p.y <= z.y_hi) {
                if (p.x < z.x_lo) z.x_lo = p.x;
                if (p.x > z.x_hi) z.x_hi = p.x;
                return;
            };
        }
    }.f;
    for (positions) |p| considerPoint(zones.items, p);
    for (slots) |s| considerPoint(zones.items, s);
    for (ops) |op| switch (op.kind) {
        .move => |m| for (m.atoms) |a| {
            considerPoint(zones.items, a.src);
            considerPoint(zones.items, a.dest);
        },
        else => {},
    };

    // 5. Top-down by physical y (highest y first → highest on canvas).
    std.mem.sort(Zone2, zones.items, {}, struct {
        fn lt(_: void, a: Zone2, b: Zone2) bool {
            return a.y_hi > b.y_hi;
        }
    }.lt);

    // 6. Allocate equal canvas bands.
    const n: f64 = @floatFromInt(zones.items.len);
    const draw_h = Camera.canvas_h - Camera.header_h - Camera.margin;
    const usable = draw_h - Camera.band_gap * (n - 1);
    const band_h = usable / n;
    var y_cursor: f64 = Camera.header_h;
    for (zones.items) |*z| {
        z.band_top = y_cursor;
        z.band_bot = y_cursor + band_h;
        y_cursor += band_h + Camera.band_gap;
    }

    return .{ .zones = try zones.toOwnedSlice(allocator), .radius = 7.0 };
}

// ======================================================================
// raylib rendering
// ======================================================================

/// Colour palette transcribed from the original SVG stylesheet so the
/// raylib viewer looks identical to the exported frames.
const palette = struct {
    pub const bg = rl.Color{ .r = 48, .g = 52, .b = 70, .a = 255 }; // base
    pub const zone_fill = rl.Color{ .r = 65, .g = 69, .b = 89, .a = 255 }; // surface0
    pub const zone_stroke = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 }; // overlay0
    pub const slot_off = rl.Color{ .r = 115, .g = 121, .b = 148, .a = 255 }; // overlay0
    pub const slot_on_fill = rl.Color{ .r = 166, .g = 209, .b = 137, .a = 255 }; // green
    pub const slot_on_stroke = rl.Color{ .r = 129, .g = 200, .b = 190, .a = 255 }; // teal
    pub const qdot = rl.Color{ .r = 131, .g = 139, .b = 167, .a = 100 }; // overlay1, dimmed
    pub const qact_fill = rl.Color{ .r = 239, .g = 159, .b = 118, .a = 255 }; // peach
    pub const qact_stroke = rl.Color{ .r = 234, .g = 153, .b = 156, .a = 255 }; // maroon
    pub const qmeas_fill = rl.Color{ .r = 244, .g = 184, .b = 228, .a = 255 }; // pink
    pub const qmeas_stroke = rl.Color{ .r = 202, .g = 158, .b = 230, .a = 255 }; // mauve
    pub const arrow = rl.Color{ .r = 229, .g = 200, .b = 144, .a = 255 }; // yellow
    pub const text = rl.Color{ .r = 198, .g = 208, .b = 245, .a = 255 }; // text
    pub const text_sub = rl.Color{ .r = 165, .g = 173, .b = 206, .a = 255 }; // subtext0
};

fn projectV(cam: Camera, p: Point) rl.Vector2 {
    const proj = cam.project(p);
    return .{ .x = @floatCast(proj.x), .y = @floatCast(proj.y) };
}

/// Approximate the SVG `marker-end` arrowhead with two short line segments.
fn drawArrow(start: rl.Vector2, end: rl.Vector2, thickness: f32, color: rl.Color) void {
    rl.drawLineEx(start, end, thickness, color);

    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;

    const head_len: f32 = 9.0;
    const wing_off: f32 = std.math.pi / 7.0;
    const ang = std.math.atan2(dy, dx);
    const a1 = ang + std.math.pi - wing_off;
    const a2 = ang + std.math.pi + wing_off;

    const w1 = rl.Vector2{
        .x = end.x + std.math.cos(a1) * head_len,
        .y = end.y + std.math.sin(a1) * head_len,
    };
    const w2 = rl.Vector2{
        .x = end.x + std.math.cos(a2) * head_len,
        .y = end.y + std.math.sin(a2) * head_len,
    };
    rl.drawLineEx(end, w1, thickness, color);
    rl.drawLineEx(end, w2, thickness, color);
}

/// Manual dashed line; raylib has no built-in dashed primitive.
fn drawDashedLine(a: rl.Vector2, b: rl.Vector2, dash: f32, gap: f32, color: rl.Color) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    const ux = dx / len;
    const uy = dy / len;
    var t: f32 = 0;
    while (t < len) {
        const e = @min(t + dash, len);
        const p0 = rl.Vector2{ .x = a.x + ux * t, .y = a.y + uy * t };
        const p1 = rl.Vector2{ .x = a.x + ux * e, .y = a.y + uy * e };
        rl.drawLineV(p0, p1, color);
        t = e + gap;
    }
}

fn drawDashedRect(rect: rl.Rectangle, dash: f32, gap: f32, color: rl.Color) void {
    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;
    drawDashedLine(.{ .x = x, .y = y }, .{ .x = x + w, .y = y }, dash, gap, color);
    drawDashedLine(.{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h }, dash, gap, color);
    drawDashedLine(.{ .x = x, .y = y + h }, .{ .x = x + w, .y = y + h }, dash, gap, color);
    drawDashedLine(.{ .x = x, .y = y }, .{ .x = x, .y = y + h }, dash, gap, color);
}

fn drawFrame(
    cam: Camera,
    positions: []const Point,
    slots: []const Point,
    active: []bool,
    op: Op,
    frame_idx: usize,
    total_frames: usize,
    playing: bool,
) void {
    @memset(active, false);

    // Zone backdrops + labels.
    for (cam.zones, 0..) |z, zi| {
        const rect = rl.Rectangle{
            .x = 30,
            .y = @floatCast(z.band_top),
            .width = 940,
            .height = @floatCast(z.band_bot - z.band_top),
        };
        rl.drawRectangleRec(rect, palette.zone_fill);
        drawDashedRect(rect, 5, 4, palette.zone_stroke);

        var buf: [128]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "zone {d}  ·  y={d}..{d}", .{ zi, z.y_lo, z.y_hi }) catch "?";
        rl.drawText(label, 42, @intFromFloat(z.band_top + 6), 11, palette.text_sub);
    }

    // Compute slot indicators: grey ring if empty, green disc if occupied.
    for (slots) |s| {
        var occupied = false;
        for (positions) |p| if (p.x == s.x and p.y == s.y) {
            occupied = true;
            break;
        };
        const c = projectV(cam, s);
        const r: f32 = @floatCast(cam.radius * 1.3);
        if (occupied) {
            rl.drawCircleV(c, r, palette.slot_on_fill);
            rl.drawCircleLinesV(c, r, palette.slot_on_stroke);
        } else {
            rl.drawCircleLinesV(c, r, palette.slot_off);
        }
    }

    // Header.
    {
        var buf: [128]u8 = undefined;
        const header = std.fmt.bufPrintZ(&buf, "frame {d:0>3}  ·  t={d}  ·  {s}", .{
            frame_idx, op.t, @tagName(op.kind),
        }) catch "?";
        rl.drawText(header, 30, 18, 18, palette.text);
    }

    // Footer with controls hint.
    {
        var buf: [160]u8 = undefined;
        const footer = std.fmt.bufPrintZ(&buf, "{d}/{d}   j/k step   space {s}   esc quit", .{
            frame_idx + 1,
            total_frames,
            if (playing) "pause" else "play",
        }) catch "?";
        rl.drawText(footer, 30, @intFromFloat(Camera.canvas_h - 26), 12, palette.text_sub);
    }

    // Per-op visual + sub-text + active-qubit colour selection.
    var highlight_fill = palette.qact_fill;
    var highlight_stroke = palette.qact_stroke;

    switch (op.kind) {
        .move => |m| {
            var buf: [192]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "aod={d}  axis={s}  {s} → {s}  ({d} atoms)", .{
                m.aod, @tagName(m.translate), @tagName(m.src_zone), @tagName(m.dest_zone), m.atoms.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);

            for (m.atoms) |a| {
                active[a.qubit] = true;
                drawArrow(projectV(cam, a.src), projectV(cam, a.dest), 1.5, palette.arrow);
            }
        },
        .raman => |r| {
            var buf: [160]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "angle={d:.4}  phase={d:.4}  ({d} targets)", .{
                r.angle, r.phase, r.targets.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);

            for (r.targets) |t| active[t.qubit] = true;
        },
        .rydberg => |r| {
            var buf: [96]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "zone={s}", .{@tagName(r.zone)}) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);
        },
        .measure => |m| {
            var buf: [96]u8 = undefined;
            const sub = std.fmt.bufPrintZ(&buf, "zone={s}  ({d} qubits)", .{
                @tagName(m.zone), m.qubits.len,
            }) catch "?";
            rl.drawText(sub, 30, 44, 13, palette.text_sub);

            highlight_fill = palette.qmeas_fill;
            highlight_stroke = palette.qmeas_stroke;
            for (m.qubits) |q| active[q] = true;
        },
    }

    // Inactive qubits first: small dim dots, no label.
    for (positions, 0..) |p, id| if (!active[id]) {
        const c = projectV(cam, p);
        rl.drawCircleV(c, 2.0, palette.qdot);
    };

    // Active qubits on top so the arrows / highlights sit cleanly.
    for (positions, 0..) |p, id| if (active[id]) {
        const c = projectV(cam, p);
        const r: f32 = @floatCast(cam.radius);
        rl.drawCircleV(c, r, highlight_fill);
        rl.drawCircleLinesV(c, r, highlight_stroke);

        var buf: [16]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{d}", .{id}) catch "?";
        const text_w = rl.measureText(label, 11);
        rl.drawText(
            label,
            @as(i32, @intFromFloat(c.x)) - @divFloor(text_w, 2),
            @as(i32, @intFromFloat(c.y)) - 5,
            11,
            palette.text,
        );
    };
}

fn initialPositions(allocator: std.mem.Allocator, final: []const Point, ops: []const Op) ![]Point {
    const positions = try allocator.dupe(Point, final);
    var i = ops.len;
    while (i > 0) {
        i -= 1;
        switch (ops[i].kind) {
            .move => |m| for (m.atoms) |a| {
                positions[a.qubit] = a.src;
            },
            else => {},
        }
    }
    return positions;
}

fn applyOp(positions: []Point, op: Op) void {
    switch (op.kind) {
        .move => |m| for (m.atoms) |a| {
            positions[a.qubit] = a.dest;
        },
        else => {},
    }
}
