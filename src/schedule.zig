const std = @import("std");
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

    pub fn deinit(s: *PhysicalSchedule) void {
        s.arena.deinit();
    }

    pub fn dumpSlideshow(
        self: *const PhysicalSchedule,
        allocator: std.mem.Allocator,
        io: std.Io,
        out_dir: []const u8,
    ) !void {
        if (self.placement.len == 0 or self.ops.len == 0) return;

        // 1. Reconstruct initial positions by undoing every move in reverse.
        var positions = try allocator.dupe(Point, self.placement);
        defer allocator.free(positions);
        {
            var i: usize = self.ops.len;
            while (i > 0) {
                i -= 1;
                switch (self.ops[i].kind) {
                    .move => |m| for (m.atoms) |a| {
                        positions[a.qubit] = a.src;
                    },
                    else => {},
                }
            }
        }

        // 2. Global bounding box over all positions ever touched, so the camera
        //    is stable across frames.
        var min_x = positions[0].x;
        var max_x = min_x;
        var min_y = positions[0].y;
        var max_y = min_y;
        for (positions) |p| {
            if (p.x < min_x) min_x = p.x;
            if (p.x > max_x) max_x = p.x;
            if (p.y < min_y) min_y = p.y;
            if (p.y > max_y) max_y = p.y;
        }
        for (self.ops) |op| switch (op.kind) {
            .move => |m| for (m.atoms) |a| {
                const pts = [_]Point{ a.src, a.dest };
                for (pts) |p| {
                    if (p.x < min_x) min_x = p.x;
                    if (p.x > max_x) max_x = p.x;
                    if (p.y < min_y) min_y = p.y;
                    if (p.y > max_y) max_y = p.y;
                }
            },
            else => {},
        };

        // 3. Fit-and-center transform. Drawing area sits below a header band.
        const canvas_w: f64 = 680.0;
        const canvas_h: f64 = 500.0;
        const header_h: f64 = 60.0;
        const margin: f64 = 30.0;
        const draw_w: f64 = canvas_w - 2 * margin;
        const draw_h: f64 = canvas_h - header_h - 2 * margin;
        const span_x: f64 = @floatFromInt(max_x - min_x);
        const span_y: f64 = @floatFromInt(max_y - min_y);
        const scale = @min(
            if (span_x > 0) draw_w / span_x else 1.0,
            if (span_y > 0) draw_h / span_y else 1.0,
        );
        const off_x = (canvas_w - span_x * scale) / 2.0;
        const off_y = header_h + (canvas_h - header_h - span_y * scale) / 2.0;

        // 4. Trap radius from closest pair.
        var radius: f64 = 16.0;
        {
            var min_gap_sq: f64 = 0.0;
            var found = false;
            for (positions, 0..) |a, i| {
                for (positions[i + 1 ..]) |b| {
                    const dx: f64 = @floatFromInt(a.x - b.x);
                    const dy: f64 = @floatFromInt(a.y - b.y);
                    const d_sq = dx * dx + dy * dy;
                    if (d_sq > 0 and (!found or d_sq < min_gap_sq)) {
                        min_gap_sq = d_sq;
                        found = true;
                    }
                }
            }
            if (found) radius = @sqrt(min_gap_sq) * scale * 0.35;
        }

        // 5. Make sure the output directory exists.
        std.Io.Dir.cwd().createDirPath(io, out_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Scratch flags for "which qubits are involved in this op".
        var active = try allocator.alloc(bool, positions.len);
        defer allocator.free(active);

        // 6. Emit one frame per op.
        for (self.ops, 0..) |op, frame_idx| {
            @memset(active, false);

            var buf: std.Io.Writer.Allocating = .init(allocator);
            defer buf.deinit();
            const w = &buf.writer;

            try w.writeAll(
                \\<svg xmlns="http://www.w3.org/2000/svg" width="680" height="500" viewBox="0 0 680 500">
                \\  <defs>
                \\    <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                \\      <path d="M2 1L8 5L2 9" fill="none" stroke="#BA7517" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
                \\    </marker>
                \\    <style>
                \\      .qubit   { fill: #E1F5EE; stroke: #0F6E56; stroke-width: 0.5; }
                \\      .qmove   { fill: #FAC775; stroke: #854F0B; stroke-width: 1; }
                \\      .qact    { fill: #F4C0D1; stroke: #993556; stroke-width: 1; }
                \\      .qlabel  { font: 500 12px system-ui, sans-serif; fill: #085041; text-anchor: middle; dominant-baseline: central; }
                \\      .header  { font: 500 16px system-ui, sans-serif; fill: #2C2C2A; }
                \\      .subhead { font: 12px system-ui, sans-serif; fill: #5F5E5A; }
                \\      .movearr { stroke: #BA7517; stroke-width: 1.5; fill: none; }
                \\    </style>
                \\  </defs>
                \\
            );

            // Header band.
            const op_name = switch (op.kind) {
                .move => "move",
                .raman => "raman",
                .rydberg => "rydberg",
                .measure => "measure",
            };
            try w.print(
                "  <text class=\"header\" x=\"24\" y=\"32\">frame {d:0>3}  ·  t={d}  ·  {s}</text>\n",
                .{ frame_idx, op.t, op_name },
            );

            switch (op.kind) {
                .move => |m| {
                    try w.print(
                        "  <text class=\"subhead\" x=\"24\" y=\"52\">aod={d}  axis={s}  {s} → {s}  ({d} atoms)</text>\n",
                        .{ m.aod, @tagName(m.translate), @tagName(m.src_zone), @tagName(m.dest_zone), m.atoms.len },
                    );
                    for (m.atoms) |a| active[a.qubit] = true;
                    // Arrows from src to dest in canvas coords.
                    for (m.atoms) |a| {
                        const sx = off_x + @as(f64, @floatFromInt(a.src.x - min_x)) * scale;
                        const sy = off_y + @as(f64, @floatFromInt(max_y - a.src.y)) * scale;
                        const dx = off_x + @as(f64, @floatFromInt(a.dest.x - min_x)) * scale;
                        const dy = off_y + @as(f64, @floatFromInt(max_y - a.dest.y)) * scale;
                        try w.print(
                            "  <line class=\"movearr\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" marker-end=\"url(#arrow)\"/>\n",
                            .{ sx, sy, dx, dy },
                        );
                    }
                },
                .raman => |r| {
                    try w.print(
                        "  <text class=\"subhead\" x=\"24\" y=\"52\">angle={d:.4}  phase={d:.4}  ({d} targets)</text>\n",
                        .{ r.angle, r.phase, r.targets.len },
                    );
                    for (r.targets) |t| active[t.qubit] = true;
                },
                .rydberg => |r| {
                    try w.print(
                        "  <text class=\"subhead\" x=\"24\" y=\"52\">zone={s}</text>\n",
                        .{@tagName(r.zone)},
                    );
                },
                .measure => |m| {
                    try w.print(
                        "  <text class=\"subhead\" x=\"24\" y=\"52\">zone={s}  ({d} qubits)</text>\n",
                        .{ @tagName(m.zone), m.qubits.len },
                    );
                    for (m.qubits) |q| active[q] = true;
                },
            }

            // Qubit circles at the *current* (pre-move) positions.
            for (positions, 0..) |p, id| {
                const cx = off_x + @as(f64, @floatFromInt(p.x - min_x)) * scale;
                const cy = off_y + @as(f64, @floatFromInt(max_y - p.y)) * scale;
                const class_name: []const u8 = if (!active[id])
                    "qubit"
                else switch (op.kind) {
                    .move => "qmove",
                    else => "qact",
                };
                try w.print(
                    "  <circle class=\"{s}\" cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\"/>\n" ++
                        "  <text class=\"qlabel\" x=\"{d:.1}\" y=\"{d:.1}\">{d}</text>\n",
                    .{ class_name, cx, cy, radius, cx, cy, id },
                );
            }

            try w.writeAll("</svg>\n");

            // Apply move side-effects so the next frame starts from the post-move state.
            switch (op.kind) {
                .move => |m| for (m.atoms) |a| {
                    positions[a.qubit] = a.dest;
                },
                else => {},
            }

            // Write to disk.
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/frame_{d:0>3}.svg",
                .{ out_dir, frame_idx },
            );
            defer allocator.free(path);
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try file.writePositionalAll(io, buf.written(), 0);
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

        if (maybe_slm) |qubit_id| {
            const src = placement[qubit_id];
            const dest = Point{ .x = x, .y = y_slm_orig };

            try atomsSlm.append(allocator, MoveAtom{
                .qubit = @as(u32, @intCast(qubit_id)),
                .src = src,
                .dest = dest,
            });

            placement[qubit_id] = dest;
        }
    }

    const op = Op{ .t = 0, .kind = .{
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

    // 2. Use second SLM in the compute zone for AOD qubits (targets).
    //const target = layout.entanglement_zone.slms[1];

    for (logical.aod_slots_per_color, 0..) |aods, t| {
        std.debug.print("{}:{any}\n", .{ t, aods });
    }

    return .{
        .arena = arena,
        .ops = ops.items,
        .placement = placement,
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
