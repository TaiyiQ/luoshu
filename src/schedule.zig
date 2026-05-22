const std = @import("std");
const arch = @import("arch");

const Zone = enum { storage, compute, readout };
const Axis = enum { x, y };

pub const Point = struct { x: i32, y: i32 };
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

pub const Op = struct {
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

pub const PhysicalSchedule = struct {
    arena: std.heap.ArenaAllocator,
    ops: []const Op,
    placement: []Point, // Index corresponds to qubit id.
    compute_slots: []const Point, // SLM trap sites in the entanglement zone.

    pub fn deinit(s: *PhysicalSchedule) void {
        s.arena.deinit();
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
