const std = @import("std");

const INF = std.math.maxInt(usize);
const MIN = std.math.minInt(i32);

const Adj = struct { y: usize, col: i32 };

const SortCtx = struct {
    g: *Graph,
    v: usize,
};

const Schedule = struct {
    slm_slots: []const ?usize,
    aod_slots_per_color: [][]?usize,
    max_color: i32,

    fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        for (self.aod_slots_per_color) |slot| {
            allocator.free(slot);
        }
        allocator.free(self.aod_slots_per_color);
    }

    fn print(self: Schedule) void {
        std.debug.print("Schedule (max_color={}):\n", .{self.max_color});
        std.debug.print("  slm_slots: {any}\n", .{self.slm_slots});
        for (self.aod_slots_per_color, 0..) |slot, c| {
            std.debug.print("  t{}: {any}\n", .{ c, slot });
        }
    }
};

const EdgeNode = struct {
    y: usize,
    color: ?i32,
    next: ?*EdgeNode,
};

const Graph = struct {
    allocator: std.mem.Allocator,
    edges: []?*EdgeNode,
    degree: []usize,
    n: usize,
    m: usize,
    directed: bool,

    fn init(allocator: std.mem.Allocator, n: usize, directed: bool) !Graph {
        const edges = try allocator.alloc(?*EdgeNode, n);
        @memset(edges, null);

        const degree = try allocator.alloc(usize, n);
        @memset(degree, 0);

        return Graph{
            .allocator = allocator,
            .edges = edges,
            .degree = degree,
            .n = n,
            .m = 0,
            .directed = directed,
        };
    }

    fn deinit(self: *Graph) void {
        for (self.edges) |v| {
            var node = v;
            while (node) |n| {
                const next = n.next;
                self.allocator.destroy(n);
                node = next;
            }
        }
        self.allocator.free(self.edges);
        self.allocator.free(self.degree);
    }

    fn addNode(s: *Graph, x: usize, y: usize) !void {
        const n = try s.allocator.create(EdgeNode);
        n.* = .{ .y = y, .color = null, .next = s.edges[x] };
        s.edges[x] = n;
        s.degree[x] += 1;
    }

    fn addEdge(s: *Graph, x: usize, y: usize) !void {
        try s.addNode(x, y);
        if (!s.directed) try s.addNode(y, x);
        s.m += 1;
    }

    fn print(self: *const Graph, name: []const u8) void {
        std.debug.print(">> Graph(name={s}, n={d}, m={d}, directed={}) \n", .{ name, self.n, self.m, self.directed });
        for (0..self.n) |u| {
            std.debug.print("  {d} -> ", .{u});
            var e = self.edges[u];
            while (e) |edge| : (e = edge.next) {
                std.debug.print("{d} ", .{edge.y});
            }
            std.debug.print("\n", .{});
        }
    }
};

fn aodSet(allocator: std.mem.Allocator, g: Graph) ![]bool {
    var aod_set = try allocator.alloc(bool, g.n);
    @memset(aod_set, false);

    // Sort nodes descending by degree.
    var order = try std.ArrayList(usize).initCapacity(allocator, g.n);
    defer order.deinit(allocator);

    for (0..g.n) |i| order.appendAssumeCapacity(i);
    std.sort.heap(usize, order.items, g, struct {
        fn less(graph: Graph, a: usize, b: usize) bool {
            return graph.degree[a] > graph.degree[b];
        }
    }.less);
    std.debug.print("order: {any}\n", .{order});

    // Add node when all it's neighbours are false.
    for (order.items) |v| {
        var add = true;
        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) {
            if (aod_set[edge.y]) {
                add = false;
                break;
            }
        }
        if (add) aod_set[v] = true;
    }

    return aod_set;
}

fn dsatur(allocator: std.mem.Allocator, g: *Graph, I: []const bool) !void {
    // 1. Get AOD nodes sorted by degree descending.
    var aod_nodes: std.ArrayList(usize) = .empty;
    defer aod_nodes.deinit(allocator);

    for (0..g.n) |i| if (I[i]) try aod_nodes.append(allocator, i);

    std.sort.heap(usize, aod_nodes.items, g, struct {
        fn less(graph: *Graph, a: usize, b: usize) bool {
            return graph.degree[a] > graph.degree[b];
        }
    }.less);

    // 2. For each AOD node.
    for (aod_nodes.items) |v| {
        var adj: std.ArrayList(usize) = .empty;
        defer adj.deinit(allocator);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) try adj.append(allocator, edge.y);

        std.sort.heap(usize, adj.items, SortCtx{ .g = g, .v = v }, struct {
            fn less(ctx: SortCtx, a: usize, b: usize) bool {
                const sat_a = countSaturation(ctx.g, ctx.v, a);
                const sat_b = countSaturation(ctx.g, ctx.v, b);
                if (sat_a != sat_b) return sat_a > sat_b;
                return ctx.g.degree[a] > ctx.g.degree[b];
            }
        }.less);

        // 3. Color each edge in the sorted order.
        for (adj.items) |y| {
            const c = leastAdmissible(g, v, y);

            // Color edge v -> u
            var n = g.edges[v];
            while (n) |edge| : (n = edge.next) {
                if (edge.y == y) edge.color = c;
            }

            // Color edge u -> v
            n = g.edges[y];
            while (n) |edge| : (n = edge.next) {
                if (edge.y == v) edge.color = c;
            }
        }
    }
}

fn leastAdmissible(g: *Graph, v: usize, y: usize) i32 {
    var forbidden = std.AutoHashMap(i32, void).init(g.allocator);
    defer forbidden.deinit();

    // All edges from v.
    // Share AOD node v.
    // Only forbidden, no order constaint.
    var e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        if (edge.y != y) {
            if (edge.color) |c| {
                _ = forbidden.getOrPut(c) catch {};
            }
        }
    }

    // Max color from adj edges not sharing the AOD node v.
    var order_max: i32 = -1;

    // All edges from y.
    // Do not share AOD node v.
    // Both forbidden and order constraint.
    e = g.edges[y];
    while (e) |edge| : (e = edge.next) {
        if (edge.y != v) {
            if (edge.color) |c| {
                std.debug.print(">>>>> {} \n", .{c});
                _ = forbidden.getOrPut(c) catch {};
                order_max = @max(order_max, c);
            }
        }
    }

    // Smallest k > order_max that is not forbidden.
    var k: i32 = order_max + 1;
    while (true) : (k += 1) {
        if (forbidden.get(k) == null) {
            return k;
        }
    }
}

fn countSaturation(g: *Graph, u: usize, v: usize) usize {
    var seen = std.AutoHashMap(i32, void).init(g.allocator);
    defer seen.deinit();

    // Edges from u.
    var e = g.edges[u];
    while (e) |edge| : (e = edge.next) {
        const w = edge.y;
        if (w != v) {
            if (edge.color) |c| {
                _ = seen.getOrPut(c) catch {};
            }
        }
    }

    // Edges from v.
    e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        const w = edge.y;
        if (w != v) {
            if (edge.color) |c| {
                _ = seen.getOrPut(c) catch {};
            }
        }
    }

    return seen.count();
}

fn slmGraph(allocator: std.mem.Allocator, g: *Graph, I: []const bool) !Graph {
    var dep = try Graph.init(allocator, g.n, true);

    // For each AOD v...
    for (0..g.n) |v| {
        // Only AODs give constraints.
        if (!I[v]) continue;

        // Collect SLM neighbours and their colors.
        var adj: std.ArrayList(Adj) = .empty;
        defer adj.deinit(allocator);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) {
            const u = edge.y;
            // If the neighbour is an SLM.
            if (!I[u]) {
                if (edge.color) |c| {
                    try adj.append(allocator, Adj{ .y = u, .col = c });
                }
            }
        }

        // Sort by increasing color.
        std.sort.heap(Adj, adj.items, {}, struct {
            fn less(_: void, a: Adj, b: Adj) bool {
                return a.col < b.col;
            }
        }.less);

        // Add directed constraints: consecutive pais y1 -> y2 ("y1" left of "y2").
        for (0..adj.items.len - 1) |i| {
            const y1 = adj.items[i].y;
            const y2 = adj.items[i + 1].y;
            try dep.addEdge(y1, y2);
        }
    }

    return dep;
}

fn topoSort(allocator: std.mem.Allocator, g: Graph, I: []const bool) ![]usize {
    // Only SLM qubits
    var n_slm: usize = 0;
    for (0..g.n) |i| {
        if (!I[i]) n_slm += 1;
    }

    var order = try std.ArrayList(usize).initCapacity(allocator, n_slm);
    defer order.deinit(allocator);

    // Compure in-degrees; arrows pointing INTO each SLM.
    var in_degree = try allocator.alloc(usize, g.n);
    @memset(in_degree, 0);
    defer allocator.free(in_degree);

    for (0..g.n) |u| {
        if (I[u]) continue;
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            if (!I[edge.y]) in_degree[edge.y] += 1;
        }
    }

    // Queue of SLM with zero in-degree can be placed first.
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    for (0..g.n) |i| {
        if (!I[i] and in_degree[i] == 0) try queue.append(allocator, i);
    }

    while (queue.items.len > 0) {
        const u = queue.orderedRemove(0);
        try order.append(allocator, u);

        // Reduce in-degrees of neighbours.
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            const v = edge.y;
            if (!I[v]) {
                in_degree[v] -= 1;
                if (in_degree[v] == 0) try queue.append(allocator, v);
            }
        }
    }

    return order.toOwnedSlice(allocator);
}

fn matchingForColor(
    allocator: std.mem.Allocator,
    g: *const Graph,
    aod_order: []const usize,
    I: []const bool,
    t: i32,
) ![]?usize {
    if (aod_order.len == 0) {
        return try allocator.alloc(?usize, 0);
    }

    const matching = try allocator.alloc(?usize, aod_order.len);
    @memset(matching, null);
    errdefer allocator.free(matching);

    for (aod_order, 0..) |x, i| {
        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.color == t and !I[edge.y]) {
                matching[i] = edge.y;
                break; // There can only be 1 SLM-AOD match per timestep.
            }
        }
    }

    return matching;
}

fn logicalSchedule(
    allocator: std.mem.Allocator,
    g: *Graph,
    aod_order: []const usize,
    slm_slots: []const ?usize,
    I: []const bool,
) !Schedule {
    std.debug.print("\n\n>> logicalSchedule\n", .{});
    // 1. Precompute max color used.
    var max_c: i32 = MIN;
    for (0..g.n) |x| {
        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.color) |c| {
                max_c = @max(max_c, c);
            }
        }
    }
    if (max_c == MIN) return error.NoColors;

    // 2. Precompute slm_pos[slm_id] = its index in slm_order
    var slm_pos = std.AutoHashMap(usize, usize).init(allocator);
    defer slm_pos.deinit();

    for (slm_slots, 0..) |v, i| {
        if (v != null) try slm_pos.put(v.?, i);
    }

    std.debug.print("Schedule - SLM Pos\n", .{});
    var it = slm_pos.iterator();
    while (it.next()) |entry| {
        std.debug.print("Key: {} -> {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // Collect gates per color.
    const n_slot = @as(usize, @intCast(max_c)) + 1;
    var aod_slots_per_color = try allocator.alloc([]?usize, n_slot);
    errdefer {
        var t: usize = 0;
        while (t < max_c + 1) : (t += 1) {
            allocator.free(aod_slots_per_color[t]);
        }
        allocator.free(aod_slots_per_color);
    }

    var t: usize = 0;
    while (t < max_c + 1) : (t += 1) {
        const matching = try matchingForColor(allocator, g, aod_order, I, @intCast(t));
        defer allocator.free(matching);
        std.debug.print("{} - Matching: {any}\n", .{ t, matching });

        const aod_slot = try allocator.alloc(?usize, slm_slots.len);
        @memset(aod_slot, null);

        // First pass: place matched AODs (existing code)
        for (matching, 0..) |slm, i| {
            if (slm == null) continue;
            const aod = aod_order[i];
            const idx: usize = slm_pos.get(slm.?).?;
            aod_slot[idx] = aod;
            std.debug.print("aod:{any} - slm:{any}\n", .{ aod, slm });
        }

        // Second pass: place unmatched AODs into resting (gap) positions
        var gap_ptr: usize = 0;
        for (aod_order, 0..) |aod, i| {
            if (matching[i]) |slm_v| {
                // Jump gap_ptr past this matched AOD's slot so the
                // next unmatched AOD searches only in the region after it.
                gap_ptr = slm_pos.get(slm_v).? + 1;
            } else {
                // Find the next slot that is neither an SLM position
                // nor already claimed by a matched AOD.
                while (gap_ptr < aod_slot.len) : (gap_ptr += 1) {
                    if (slm_slots[gap_ptr] == null and aod_slot[gap_ptr] == null) {
                        aod_slot[gap_ptr] = aod;
                        gap_ptr += 1;
                        break;
                    }
                }
            }
        }

        aod_slots_per_color[t] = aod_slot;

        std.debug.print("AOD Slot: {any}\n", .{aod_slot});
    }

    return Schedule{
        .slm_slots = slm_slots,
        .aod_slots_per_color = aod_slots_per_color,
        .max_color = max_c,
    };
}

fn placeSlmQubits(
    allocator: std.mem.Allocator,
    g: *const Graph,
    aod_order: []const usize,
    slm_order: []const usize,
    I: []const bool,
) ![]?usize {
    // 1. Precompute max color used.
    var max_c: i32 = MIN;
    for (0..g.n) |x| {
        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.color) |c| {
                max_c = @max(max_c, c);
            }
        }
    }
    if (max_c == MIN) return error.NoColors;

    // 2. Precompute slm_pos[slm_id] = its index in slm_order
    var slm_slot = try allocator.alloc(?usize, g.n);
    @memset(slm_slot, null);

    var n: usize = aod_order.len - 1;
    for (slm_order) |v| {
        slm_slot[n] = v;
        n += 1;
    }
    std.debug.print("SLM Slots: {any}\n", .{slm_slot});

    // 2. Precompute slm_pos[slm_id] = its index in slm_order
    var slm_pos = std.AutoHashMap(usize, usize).init(allocator);
    defer slm_pos.deinit();

    for (slm_slot, 0..) |v, i| {
        if (v != null) try slm_pos.put(v.?, i);
    }
    std.debug.print("SLM Pos\n", .{});
    var it = slm_pos.iterator();
    while (it.next()) |entry| {
        std.debug.print("Key: {} -> {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    var t: usize = 0;
    while (t < max_c + 1) : (t += 1) {
        const matching = try matchingForColor(allocator, g, aod_order, I, @intCast(t));
        defer allocator.free(matching);
        std.debug.print("{} - Matching: {any}\n", .{ t, matching });

        var i: usize = 0;
        while (matching[i] == null) : (i += 1) {}

        // If i is already at the end, move to the next time step.
        // FIXME: Maybe this is always the case for the first iter.
        if (i == matching.len - 1) continue;

        var j: usize = i + 1;
        while (j < matching.len - 1) : (j += 1) {
            if (matching[j] != null) break;
        }

        // Ignore is no more qubits to the right.
        // For example, t4: [1, null, null]
        if (matching[j] == null) continue;

        std.debug.print("i:{} - j:{}\n", .{ i, j });
        var m = j - i;
        while (m > 1) : (m -= 1) {
            const p = slm_pos.get(matching[i].?).? + 1;
            const temp = slm_slot[p];
            slm_slot[p] = null;
            slm_slot[p + 1] = temp;
        }
        //std.debug.print("New SLM Slots: {} - {any}\n", .{ t, slm_slot });

        //    const aod_slot = try computeAodSlotsForTimeStep(allocator, aod_order, matching, fixed_slm_slots, slm_order);
        //   defer allocator.free(aod_slot);

        //debugPrintPositions(t, aod_order, slm_order, matching, fixed_slm_slots, aod_slot);
    }

    return slm_slot;
}

fn writeToJsonCompact(allocator: std.mem.Allocator, io: std.Io, schedule: *const Schedule, filename: []const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");

    // aod_order
    try w.writeAll("  \"aod_order\": [");
    for (schedule.aod_order, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{d}", .{v});
    }
    try w.writeAll("],\n");

    // slm_order
    try w.writeAll("  \"slm_order\": [");
    for (schedule.slm_order, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{d}", .{v});
    }
    try w.writeAll("],\n");

    // aod_targets_per_color
    try w.writeAll("  \"aod_targets_per_color\": [\n");
    const targets = schedule.aod_targets_per_color[1..];
    for (targets, 0..) |row, ci| {
        try w.writeAll("    [");
        for (row, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{d}", .{v});
        }
        try w.writeAll(if (ci < targets.len - 1) "],\n" else "]\n");
    }
    try w.writeAll("  ],\n");

    // gates_per_color
    try w.writeAll("  \"gates_per_color\": [\n");
    const gates = schedule.gates_per_color[1..];
    for (gates, 0..) |layer, ci| {
        try w.writeAll("    [");
        for (layer, 0..) |gate, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{{\"u\": {d}, \"v\": {d}}}", .{ gate.u, gate.v });
        }
        try w.writeAll(if (ci < gates.len - 1) "],\n" else "]\n");
    }
    try w.writeAll("  ],\n");

    // max_color
    try w.print("  \"max_color\": {d}\n", .{schedule.max_color});
    try w.writeAll("}");

    const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    try file.writePositionalAll(io, buf.written(), 0);
}

fn debugEdgeColors(g: Graph) void {
    std.debug.print(">> Edge Colors\n", .{});

    for (0..g.n) |x| {
        var has_any = false;

        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            const y = edge.y;
            if (x < y) {
                if (edge.color) |c| {
                    if (!has_any) {
                        std.debug.print("  {d} -> ", .{x});
                        has_any = true;
                    }
                    std.debug.print("{d}:{d} ", .{ y, c });
                }
            }
        }

        if (has_any) std.debug.print("\n", .{});
    }
}

fn debugAodTargets(g: *Graph, aod_order: []const usize, aod_targets: [][]usize) void {
    std.debug.print(">> AOD Target Positions\n", .{});

    for (1..aod_targets.len) |c| {
        const targets = aod_targets[c];
        std.debug.print("Color {d} (parallel CZ layer):\n", .{c});

        var shift: usize = 0;
        var current_col: usize = 0;

        for (aod_order, 0..) |aod_id, i| {
            var partner: ?usize = null;

            var e = g.edges[aod_id];
            while (e) |edge| : (e = edge.next) {
                if (edge.color == c) {
                    partner = edge.y;
                    break;
                }
            }

            const target = targets[i];
            if (partner) |p| {
                // ACTIVE
                std.debug.print("  AOD {d} (qubit {d}) -> ACTIVE partner {d} | column {d} (shift={d})\n", .{ i, aod_id, p, target, shift });
                current_col = target + 1;
            } else {
                // RESTING
                std.debug.print("  AOD {d} (qubit {d}) -> RESTING          | column {d} (shift={d} -> {d})\n", .{ i, aod_id, target, shift, shift + 1 });
                current_col = target + 1;
                shift += 1;
            }
        }
    }
}

pub fn debugPrintPositions(
    time_step: usize,
    aod_order: []const usize,
    slm_order: []const usize,
    matching: []const ?usize,
    fixed_slm_slots: []const usize,
    aod_slot: []const usize,
) void {
    std.debug.print("\n=== Resting Positions Debug — Time Step t = {} (SLMs FIXED) ===\n", .{time_step});
    std.debug.print("AOD order : ", .{});
    for (aod_order) |id| std.debug.print("AOD{d} ", .{id});
    std.debug.print("\nMatching  : ", .{});
    for (matching) |m| {
        if (m) |v| std.debug.print("SLM{d} ", .{v}) else std.debug.print("null ", .{});
    }
    std.debug.print("\n\nFIXED SLM layout (never changes):\n", .{});
    for (slm_order, 0..) |slm_id, i| {
        std.debug.print("  SLM {d:2} → slot {d}\n", .{ slm_id, fixed_slm_slots[i] });
    }
    var max_slot: usize = 0;
    for (fixed_slm_slots) |s| max_slot = @max(max_slot, s);
    for (aod_slot) |s| max_slot = @max(max_slot, s);
    std.debug.print("\nTrap layout this step:\n", .{});
    std.debug.print("────────────────────────────────────\n", .{});
    for (0..max_slot + 1) |slot| {
        std.debug.print("Slot {d:2} → ", .{slot});
        var printed = false;
        for (slm_order, 0..) |slm_id, i| {
            if (fixed_slm_slots[i] == slot) {
                std.debug.print("SLM{d} (FIXED)", .{slm_id});
                printed = true;
                break;
            }
        }
        if (!printed) {
            for (aod_order, 0..) |aod_id, i| {
                if (aod_slot[i] == slot) {
                    if (matching[i]) |slm_id| {
                        std.debug.print("AOD{d} ↔ SLM{d}", .{ aod_id, slm_id });
                    } else {
                        std.debug.print("AOD{d} (RESTING GAP)", .{aod_id});
                    }
                    printed = true;
                    break;
                }
            }
        }
        if (!printed) std.debug.print("(empty)", .{});
        std.debug.print("\n", .{});
    }
    std.debug.print("────────────────────────────────────\nTotal slots used: {d}\n====================================\n\n", .{max_slot + 1});
}

//pub fn main(init: std.process.Init) !void {
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = try Graph.init(alloc, 7, false);
    defer g.deinit();

    try g.addEdge(0, 1);
    try g.addEdge(0, 5);
    try g.addEdge(1, 6);
    try g.addEdge(5, 6);
    try g.addEdge(6, 3);
    try g.addEdge(6, 4);
    try g.addEdge(3, 4);
    try g.addEdge(3, 2);
    try g.addEdge(4, 2);

    // Create an independent set to distigues AOD qubits from SLM qubits.
    const aod_set = try aodSet(alloc, g);
    defer alloc.free(aod_set);
    std.debug.print(">> AOD Independent Set\n", .{});
    for (aod_set, 0..) |v, i| {
        std.debug.print("{} {}\n", .{ i, v });
    }

    // Generate a graph using edge coloring
    try dsatur(alloc, &g, aod_set);
    debugEdgeColors(g);

    // Build the SLM dependency DAQ from colors.
    var dep_graph = try slmGraph(alloc, &g, aod_set);
    defer dep_graph.deinit();
    dep_graph.print("slm-dep");

    // Get the perfect left-to-right SLM order.
    const slm_order = try topoSort(alloc, dep_graph, aod_set);
    defer alloc.free(slm_order);
    std.debug.print(">> Topological Order of SLM Qubits\n", .{});
    std.debug.print("{any}\n", .{slm_order});

    var aod_order: std.ArrayList(usize) = .empty;
    defer aod_order.deinit(alloc);
    for (0..g.n) |i| {
        if (aod_set[i]) try aod_order.append(alloc, i);
    }
    std.debug.print(">> AOD Order\n", .{});
    std.debug.print("{any}\n", .{aod_order});

    const slm_slots = try placeSlmQubits(alloc, &g, aod_order.items, slm_order, aod_set);
    defer alloc.free(slm_slots);
    std.debug.print("New SLM Slots: {any}\n", .{slm_slots});

    var schedule = try logicalSchedule(alloc, &g, aod_order.items, slm_slots, aod_set);
    defer schedule.deinit(alloc);
    schedule.print();

    //    const io = init.io;
    //    try writeToJsonCompact(alloc, io, &schedule, "schedule.json");

    std.debug.print(">> Gate compilation completed\n", .{});
}
