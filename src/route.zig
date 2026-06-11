const std = @import("std");

// Pass tracing, off by default so the compiler is silent as a library and
// in tests (the build runner displays any stderr a test step produces,
// decorated with a misleading "failed command:" line). The driver enables
// it via trace.enabled (the CLI's -v flag).
const trace = @import("trace");

const MIN = -1; // -1 to help k in leastAdmissible start at 0.

const EdgeNode = struct {
    y: usize,
    color: ?i32,
    next: ?*EdgeNode,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    edges: []?*EdgeNode,
    degree: []usize,
    n: usize,
    m: usize,
    directed: bool,

    pub fn init(allocator: std.mem.Allocator, n: usize, directed: bool) !Graph {
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

    pub fn deinit(self: *Graph) void {
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

    pub fn addEdge(s: *Graph, x: usize, y: usize) !void {
        if (x == y) return;

        var e = s.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.y == y) return;
        }

        try s.addNode(x, y);
        if (!s.directed) try s.addNode(y, x);
        s.m += 1;
    }

    fn addNode(s: *Graph, x: usize, y: usize) !void {
        const n = try s.allocator.create(EdgeNode);
        n.* = .{ .y = y, .color = null, .next = s.edges[x] };
        s.edges[x] = n;
        s.degree[x] += 1;
    }

    pub fn maxColor(g: *const Graph) !i32 {
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
        return max_c;
    }

    pub fn print(self: *const Graph, name: []const u8) void {
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

pub const Sequence = struct {
    arena: std.heap.ArenaAllocator,

    // List of qubit IDs that will be fixed in the SLM in compute zone.
    fixed: []const ?usize,

    // Key is the timeframe, and value if a list of qubit IDs that
    // will move across the fixed SLM qubits in the compute zone.
    moveable: [][]?usize,

    pub fn deinit(s: *Sequence) void {
        s.arena.deinit();
    }

    pub fn print(s: Sequence) void {
        const n_slots = s.fixed.len;

        std.debug.print("\n", .{});

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        std.debug.print(" SLM |", .{});
        for (s.fixed) |v| {
            if (v) |id| std.debug.print("{d:^5}|", .{id}) else std.debug.print("  ·  |", .{});
        }
        std.debug.print("\n", .{});

        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        for (s.moveable, 0..) |aod_slot, t| {
            std.debug.print("  t{d} |", .{t});
            for (aod_slot, 0..) |v, i| {
                const has_slm = s.fixed[i] != null;
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

const Aod = struct {
    set: []bool,
    nodes: std.ArrayList(usize), // ordered nodes

    fn deinit(s: *Aod, allocator: std.mem.Allocator) void {
        allocator.free(s.set);
        s.nodes.deinit(allocator);
    }
};

const AodConstraints = struct {
    adj: []std.ArrayList(usize), // adj[i] = AOD indices that i must come before
    n: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, n: usize) !AodConstraints {
        const adj = try allocator.alloc(std.ArrayList(usize), n);
        for (adj) |*a| a.* = .empty;
        return .{ .adj = adj, .n = n, .allocator = allocator };
    }

    fn deinit(self: *AodConstraints) void {
        for (self.adj) |*a| a.deinit(self.allocator);
        self.allocator.free(self.adj);
    }

    // BFS: can `from` reach `to`?
    fn canReach(self: *const AodConstraints, from: usize, to: usize) bool {
        if (from == to) return true;
        var visited = self.allocator.alloc(bool, self.n) catch return false;
        defer self.allocator.free(visited);
        @memset(visited, false);

        var queue: std.ArrayList(usize) = .empty;
        defer queue.deinit(self.allocator);

        visited[from] = true;
        queue.append(self.allocator, from) catch return false;

        while (queue.items.len > 0) {
            const u = queue.orderedRemove(0);
            if (u == to) return true;
            for (self.adj[u].items) |v| {
                if (!visited[v]) {
                    visited[v] = true;
                    queue.append(self.allocator, v) catch return false;
                }
            }
        }
        return false;
    }

    fn addConstraint(self: *AodConstraints, from: usize, to: usize) !void {
        if (from == to) return;
        for (self.adj[from].items) |x| if (x == to) return; // no duplicates
        try self.adj[from].append(self.allocator, to);
    }
};

fn maxIndependentSet(allocator: std.mem.Allocator, g: Graph) !Aod {
    var set = try allocator.alloc(bool, g.n);
    @memset(set, false);

    // Sort nodes descending by degree.
    var order = try std.ArrayList(usize).initCapacity(allocator, g.n);
    defer order.deinit(allocator);

    for (0..g.n) |i| order.appendAssumeCapacity(i);
    std.sort.heap(usize, order.items, g, struct {
        fn less(graph: Graph, a: usize, b: usize) bool {
            //return graph.degree[a] > graph.degree[b];
            if (graph.degree[a] != graph.degree[b]) {
                return graph.degree[a] > graph.degree[b];
            }
            return a > b;
        }
    }.less);

    // Greedy MIS: add a node when none of its neighbours are in the set.
    // Skip isolated nodes (degree 0): they have no two-qubit interactions and
    // must remain SLM qubits.
    for (order.items) |v| {
        if (g.degree[v] == 0) continue;
        var add = true;
        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) {
            if (set[edge.y]) {
                add = false;
                break;
            }
        }
        if (add) set[v] = true;
    }

    // nodes holds only AOD nodes, in degree-sorted order.
    var nodes = try std.ArrayList(usize).initCapacity(allocator, g.n);
    for (order.items) |v| {
        if (set[v]) try nodes.append(allocator, v);
    }

    trace.print(">> AOD ordered nodes: {any}\n", .{nodes.items});

    return .{ .set = set, .nodes = nodes };
}

// Use a modified DSatur algorithm to color edges instead of nodes.
fn colorEdges(allocator: std.mem.Allocator, g: *Graph, aod: Aod) !void {
    // Map node_id -> index in aod_nodes (stable across the whole coloring).
    var aod_idx = std.AutoHashMap(usize, usize).init(allocator);
    defer aod_idx.deinit();

    for (aod.nodes.items, 0..) |a, i| try aod_idx.put(a, i);

    // Constraint graph: maintained incrementally to detect cycles early.
    var constraints = try AodConstraints.init(allocator, aod.nodes.items.len);
    defer constraints.deinit();

    for (aod.nodes.items) |v| {
        var adj: std.ArrayList(usize) = .empty;
        defer adj.deinit(allocator);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) try adj.append(allocator, edge.y);

        const Ctx = struct { g: *Graph, v: usize };
        std.sort.heap(usize, adj.items, Ctx{ .g = g, .v = v }, struct {
            fn less(ctx: Ctx, a: usize, b: usize) bool {
                const sat_a = countSaturation(ctx.g, ctx.v, a);
                const sat_b = countSaturation(ctx.g, ctx.v, b);
                if (sat_a != sat_b) return sat_a > sat_b;
                return ctx.g.degree[a] > ctx.g.degree[b];
            }
        }.less);

        for (adj.items) |y| {
            const c = try leastAdmissible(g, v, y, &aod_idx, &constraints);

            var n = g.edges[v];
            while (n) |edge| : (n = edge.next) {
                if (edge.y == y) edge.color = c;
            }

            n = g.edges[y];
            while (n) |edge| : (n = edge.next) {
                if (edge.y == v) edge.color = c;
            }
        }
    }
}

fn leastAdmissible(
    g: *Graph,
    v: usize,
    y: usize,
    aod_idx: *const std.AutoHashMap(usize, usize),
    constraints: *AodConstraints,
) !i32 {
    const v_idx = aod_idx.get(v).?;

    var forbidden = std.AutoHashMap(i32, void).init(g.allocator);
    defer forbidden.deinit();

    // Edges from v (same AOD): forbidden only, no order constraint.
    var e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        if (edge.y != y) {
            if (edge.color) |c| _ = forbidden.getOrPut(c) catch {};
        }
    }

    // Edges from y to other AODs: forbidden + local order constraint.
    var order_max: i32 = MIN;
    e = g.edges[y];
    while (e) |edge| : (e = edge.next) {
        if (edge.y != v) {
            if (edge.color) |c| {
                _ = forbidden.getOrPut(c) catch {};
                order_max = @max(order_max, c);
            }
        }
    }

    var k: i32 = order_max + 1;
    outer: while (true) : (k += 1) {
        if (forbidden.get(k) != null) continue;

        // Cycle check: would assigning color k to edge (v→y) create a cycle
        // in the global AOD constraint graph?
        //
        // Assigning color k means:
        //   for each AOD u also connected to y with color c_u:
        //     c_u < k  →  u must come before v  →  add constraint u→v
        //     c_u > k  →  v must come before u  →  add constraint v→u
        //
        // u→v creates a cycle iff v can already reach u.
        // v→u creates a cycle iff u can already reach v.
        e = g.edges[y];
        while (e) |edge| : (e = edge.next) {
            if (edge.y == v) continue;
            const u_idx = aod_idx.get(edge.y) orelse continue; // skip SLM neighbors
            if (edge.color) |c| {
                if (c < k) {
                    // Would add u→v; cycle if v can already reach u.
                    if (constraints.canReach(v_idx, u_idx)) continue :outer;
                } else if (c > k) {
                    // Would add v→u; cycle if u can already reach v.
                    if (constraints.canReach(u_idx, v_idx)) continue :outer;
                }
            }
        }

        // k is valid — permanently commit all new constraints.
        e = g.edges[y];
        while (e) |edge| : (e = edge.next) {
            if (edge.y == v) continue;
            const u_idx = aod_idx.get(edge.y) orelse continue;
            if (edge.color) |c| {
                if (c < k) {
                    try constraints.addConstraint(u_idx, v_idx);
                } else if (c > k) {
                    try constraints.addConstraint(v_idx, u_idx);
                }
            }
        }

        return k;
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

fn slmGraph(allocator: std.mem.Allocator, g: *Graph, aod_set: []const bool) !Graph {
    var dep = try Graph.init(allocator, g.n, true);

    // For each AOD v...
    for (0..g.n) |v| {
        // Only AODs give constraints.
        if (!aod_set[v]) continue;

        // Collect SLM neighbours and their colors.
        const Adj = struct { y: usize, col: i32 };
        var adj: std.ArrayList(Adj) = .empty;
        defer adj.deinit(allocator);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) {
            const u = edge.y;
            // If the neighbour is an SLM.
            if (!aod_set[u]) {
                if (edge.color) |c| {
                    try adj.append(allocator, .{ .y = u, .col = c });
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
        for (0..@as(usize, if (adj.items.len == 0) 0 else adj.items.len - 1)) |i| {
            const y1 = adj.items[i].y;
            const y2 = adj.items[i + 1].y;
            try dep.addEdge(y1, y2);
        }
    }

    return dep;
}

fn topoSort(allocator: std.mem.Allocator, g: Graph, aod_set: []const bool, orig: Graph) ![]usize {
    // Only SLM qubits that participate in at least one CZ interaction.
    // Isolated qubits (orig.degree == 0) have no placement constraints.
    var n_slm: usize = 0;
    for (0..g.n) |i| {
        if (!aod_set[i] and orig.degree[i] > 0) n_slm += 1;
    }

    var order = try std.ArrayList(usize).initCapacity(allocator, n_slm);
    defer order.deinit(allocator);

    // Compure in-degrees; arrows pointing INTO each SLM.
    var in_degree = try allocator.alloc(usize, g.n);
    @memset(in_degree, 0);
    defer allocator.free(in_degree);

    for (0..g.n) |u| {
        if (aod_set[u] or orig.degree[u] == 0) continue;
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            if (!aod_set[edge.y] and orig.degree[edge.y] > 0) in_degree[edge.y] += 1;
        }
    }

    // Queue of SLM with zero in-degree can be placed first.
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    for (0..g.n) |i| {
        if (!aod_set[i] and orig.degree[i] > 0 and in_degree[i] == 0) try queue.append(allocator, i);
    }

    while (queue.items.len > 0) {
        const u = queue.orderedRemove(0);
        try order.append(allocator, u);

        // Reduce in-degrees of neighbours.
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            const v = edge.y;
            if (!aod_set[v] and orig.degree[v] > 0) {
                in_degree[v] -= 1;
                if (in_degree[v] == 0) try queue.append(allocator, v);
            }
        }
    }

    return order.toOwnedSlice(allocator);
}

fn matchAodToSlm(
    allocator: std.mem.Allocator,
    g: *const Graph,
    aod: Aod,
    t: i32,
) ![]?usize {
    if (aod.nodes.items.len == 0) return try allocator.alloc(?usize, 0);

    const match = try allocator.alloc(?usize, aod.nodes.items.len);
    @memset(match, null);
    errdefer allocator.free(match);

    for (aod.nodes.items, 0..) |x, i| {
        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.color == t and !aod.set[edge.y]) {
                match[i] = edge.y;
                break; // There can only be 1 SLM-AOD match per timestep.
            }
        }
    }

    return match;
}

fn logicalSchedule(
    allocator: std.mem.Allocator,
    g: *Graph,
    aod: Aod,
    slm_slots: []const ?usize,
) ![][]?usize {
    var slm_pos = std.AutoHashMap(usize, usize).init(allocator);
    defer slm_pos.deinit();
    for (slm_slots, 0..) |v, t| {
        if (v) |id| try slm_pos.put(id, t);
    }

    const max_c = try g.maxColor();
    const n_slot = @as(usize, @intCast(max_c)) + 1;

    var aod_slots_per_color = try allocator.alloc([]?usize, n_slot);

    // Track last known column of each AOD.
    var last_pos = try allocator.alloc(usize, aod.nodes.items.len);
    defer allocator.free(last_pos);
    @memset(last_pos, 0);

    for (0..n_slot) |t| {
        const aod_slot = try allocator.alloc(?usize, slm_slots.len);
        @memset(aod_slot, null);

        // TODO: Is this correct?
        //defer allocator.free(aod_slot);

        // Phase 1: Place active AODs with their SLM partners.
        const match = try matchAodToSlm(allocator, g, aod, @intCast(t));
        defer allocator.free(match);
        for (match, 0..) |slm, i| {
            if (slm) |id| {
                if (slm_pos.get(id)) |c| {
                    aod_slot[c] = aod.nodes.items[i];
                    last_pos[i] = c;
                }
            }
        }

        // Phase 2: place resting AODs.
        // nodes[0]=rightmost; nodes[i] must land strictly LEFT of nodes[i-1].
        for (aod.nodes.items, 0..) |v, i| {
            if (match[i] != null) continue;

            // Upper bound: must be strictly left of our right-neighbour's slot.
            var max_pos: usize = aod_slot.len; // i==0 has no right neighbour
            if (i > 0) {
                const right_aod = aod.nodes.items[i - 1];
                for (aod_slot, 0..) |placed, c| {
                    if (placed == right_aod) {
                        max_pos = c; // must land in [0, max_pos)
                        break;
                    }
                }
            }

            // Scan right-to-left: pick rightmost free null slot before max_pos.
            var placed = false;
            if (max_pos > 0) {
                var gap_ptr: usize = max_pos - 1;
                while (true) {
                    if (slm_slots[gap_ptr] == null and aod_slot[gap_ptr] == null) {
                        aod_slot[gap_ptr] = v;
                        placed = true;
                        break;
                    }
                    if (gap_ptr == 0) break;
                    gap_ptr -= 1;
                }
            }

            if (!placed) {
                std.debug.print("Failed to place resting AOD {d} at time step {d}\n", .{ v, t });
                return error.NoRestingSlotAvailable;
            }
        }

        aod_slots_per_color[t] = aod_slot;
    }

    return aod_slots_per_color;
}

fn placeSlmWithResting(
    allocator: std.mem.Allocator,
    slm_order: []const usize,
    resting_xs: []const usize,
    n_aod: usize,
) ![]?usize {
    const boundary = if (n_aod > 0) n_aod - 1 else 0;
    const total = boundary + slm_order.len + resting_xs.len + boundary;
    const slots = try allocator.alloc(?usize, total);
    @memset(slots, null);

    var pos: usize = boundary; // skip leading buffer
    var r_idx: usize = 0;
    for (slm_order, 0..) |slm_id, i| {
        while (r_idx < resting_xs.len and resting_xs[r_idx] <= i) {
            pos += 1; // interior gap
            r_idx += 1;
        }
        slots[pos] = slm_id;
        pos += 1;
    }
    // trailing nulls already null from memset

    trace.print("SLM Slots: {any}\n", .{slots});
    return slots;
}

const Rest = struct {
    left: usize,
    right: usize,
};

fn computeRestingPositions(
    allocator: std.mem.Allocator,
    g: *Graph,
    aod: Aod,
    slm_order: []const usize,
) ![]usize {
    const max_c = try g.maxColor();

    var resting = std.AutoHashMap(Rest, usize).init(allocator);
    defer resting.deinit();

    for (0..@as(usize, @intCast(max_c + 1))) |t_usize| {
        const t: i32 = @intCast(t_usize);

        // Find ACTIVE AOD positions this timestep.
        var active = std.AutoHashMap(usize, usize).init(allocator);
        defer active.deinit();

        for (aod.nodes.items) |v| {
            var e = g.edges[v];
            while (e) |edge| : (e = edge.next) {
                if (edge.color == t) {
                    // Find SLM index.
                    for (slm_order, 0..) |slm, x| {
                        if (slm == edge.y) {
                            try active.put(v, x);
                            break;
                        }
                    }
                }
            }
        }

        if (trace.enabled) {
            trace.print("ACTIVE AODs: t({})\n", .{t});
            var it = active.iterator();
            while (it.next()) |entry| {
                trace.print("  {} => {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        var t_resting = std.AutoHashMap(Rest, usize).init(allocator);
        defer t_resting.deinit();

        for (aod.nodes.items, 0..) |v, i| {
            // Go to the next AOD, if this one is not resting.
            if (active.contains(v)) continue;

            // Find nearest left and right active neighbours.
            var l: ?usize = null;
            var r: ?usize = null;
            for (aod.nodes.items, 0..) |u, j| {
                // Next, if this one is resting.
                if (!active.contains(u)) continue;

                if (j < i) {
                    if (r == null or j > r.?) r = j;
                } else if (j > i) {
                    if (l == null or j > l.?) l = j;
                }
            }

            if (l != null and r != null) {
                const l_aod = active.get(aod.nodes.items[l.?]).?;
                const r_aod = active.get(aod.nodes.items[r.?]).?;
                const key = Rest{ .left = l_aod, .right = r_aod };
                const cnt = if (t_resting.get(key)) |c| c + 1 else 1;
                try t_resting.put(key, cnt);
                trace.print("t:{}, left:{any} resting_aod:{} right:{any} count:{}\n", .{ t, l_aod, v, r_aod, cnt });
            }
        }

        // Merging
        var new_resting = std.AutoHashMap(Rest, usize).init(allocator);
        errdefer new_resting.deinit();

        var old_it = resting.iterator();
        while (old_it.next()) |entry| {
            const old_pair = entry.key_ptr.*;
            const cnt = entry.value_ptr.*;

            for (0..cnt) |_| {
                // Find overlapping new intervals.
                var overlaps: std.ArrayList(Rest) = .empty;
                defer overlaps.deinit(allocator);

                var t_it = t_resting.iterator();
                while (t_it.next()) |t_entry| {
                    const tp = t_entry.key_ptr.*;
                    if (tp.left < old_pair.right and old_pair.left < tp.right) {
                        try overlaps.append(allocator, tp);
                    }
                }

                if (overlaps.items.len == 0) {
                    // No overlap. Keep old.
                    const c = if (new_resting.get(old_pair)) |c| c + 1 else 1;
                    try new_resting.put(old_pair, c);
                } else {
                    // Pick narrowest overlapping interval.
                    var best = overlaps.items[0];
                    for (overlaps.items[1..]) |o| {
                        if (o.right - o.left < best.right - best.left) best = o;
                    }

                    // Consume one from t_resting.
                    const old_cnt = t_resting.get(best).?;
                    if (old_cnt == 1) {
                        _ = t_resting.remove(best);
                    } else {
                        try t_resting.put(best, old_cnt - 1);
                    }

                    // Create merged interval.
                    const merged = Rest{
                        .left = @max(old_pair.left, best.left),
                        .right = @max(old_pair.right, best.right),
                    };
                    const c = if (new_resting.get(merged)) |c| c + 1 else 1;
                    try new_resting.put(merged, c);
                }
            }
        }

        // Add remaining new requirements.
        trace.print(">> t_resting:\n", .{});
        var t_it = t_resting.iterator();
        while (t_it.next()) |entry| {
            const p = entry.key_ptr.*;
            const c = entry.value_ptr.*;
            trace.print("  {}:{}\n", .{ p, c });
            const nc = if (new_resting.get(p)) |v| v + c else c;
            try new_resting.put(p, nc);
        }

        resting.deinit();
        resting = new_resting;
        new_resting = undefined; // ownership moved.
    }

    var positions: std.ArrayList(usize) = .empty;
    var it = resting.iterator();
    while (it.next()) |entry| {
        for (0..entry.value_ptr.*) |_| {
            try positions.append(allocator, entry.key_ptr.*.right);
        }
    }

    trace.print(">> POSITIONS: {any}\n", .{positions});

    std.mem.sort(usize, positions.items, {}, std.sort.asc(usize));

    return positions.toOwnedSlice(allocator);
}

pub fn compile(allocator: std.mem.Allocator, g: *Graph) !Sequence {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. AOD set.
    var aod = try maxIndependentSet(allocator, g.*);
    defer aod.deinit(allocator);

    // 2. Color edges.
    try colorEdges(allocator, g, aod);
    edgeColors(g.*);

    // 3. SLM order.
    var dep_graph = try slmGraph(allocator, g, aod.set);
    defer dep_graph.deinit();
    //dep_graph.print("slm-dep");

    const slm_order = try topoSort(allocator, dep_graph, aod.set, g.*);
    defer allocator.free(slm_order);
    trace.print(">> Topological Order of SLM Qubits\n{any}\n", .{slm_order});

    const resting_xs = try computeRestingPositions(allocator, g, aod, slm_order);
    defer allocator.free(resting_xs);
    trace.print("resting_xs: {any}\n", .{resting_xs});

    const fixed = try placeSlmWithResting(arena_alloc, slm_order, resting_xs, aod.nodes.items.len);
    const moveable = try logicalSchedule(arena_alloc, g, aod, fixed);

    return .{
        .arena = arena,
        .fixed = fixed,
        .moveable = moveable,
    };
}

test {
    @import("testutil").refAllDeclsRecursive(@This());
}

test "snapshot: mvp - aod set, coloring, schedule shape" {
    try @import("snapshot.zig").snapshotTest(
        std.testing.allocator,
        std.testing.io,
        buildMvpGraph,
        "testdata/mvp.json",
    );
}

test "snapshot: cycle" {
    try @import("snapshot.zig").snapshotTest(
        std.testing.allocator,
        std.testing.io,
        buildCycleGraph,
        "testdata/cycle.json",
    );
}

test "snapshot: ladder — parallel AOD lanes" {
    try @import("snapshot.zig").snapshotTest(
        std.testing.allocator,
        std.testing.io,
        buildLadderGraph,
        "testdata/ladder.json",
    );
}

// TODO
test "snapshot: 3x3 grid — complex MIS and gap pressure" {
    try @import("snapshot.zig").snapshotTest(
        std.testing.allocator,
        std.testing.io,
        buildGridGraph,
        "testdata/grid.json",
    );
}

test "snapshot: ghz - binary tree" {
    try @import("snapshot.zig").snapshotTest(
        std.testing.allocator,
        std.testing.io,
        buildGhzGraph,
        "testdata/ghz.json",
    );
}

test "snapshot: qft" {
    try @import("snapshot.zig").snapshotTest(
        std.testing.allocator,
        std.testing.io,
        buildQftGraph,
        "testdata/qft.json",
    );
}

pub fn buildMvpGraph(allocator: std.mem.Allocator) !Graph {
    var g = try Graph.init(allocator, 7, false);
    try g.addEdge(0, 1);
    try g.addEdge(0, 5);
    try g.addEdge(1, 6);
    try g.addEdge(5, 6);
    try g.addEdge(6, 3);
    try g.addEdge(6, 4);
    try g.addEdge(3, 4);
    try g.addEdge(3, 2);
    try g.addEdge(4, 2);
    return g;
}

pub fn buildCycleGraph(allocator: std.mem.Allocator) !Graph {
    var g = try Graph.init(allocator, 6, false);
    try g.addEdge(0, 1);
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(3, 4);
    try g.addEdge(4, 5);
    try g.addEdge(5, 0);
    return g;
}

// Two rows of AODs interleaved with SLMs, with vertical rungs
// creating cross-row ordering constraints. Tests whether the
// SLM topo-sort correctly handles constraints coming from
// two independent "lanes" of AODs simultaneously.
//
// 0-1-2-3
// | | | |
// 4-5-6-7
pub fn buildLadderGraph(allocator: std.mem.Allocator) !Graph {
    var g = try Graph.init(allocator, 8, false);
    try g.addEdge(0, 1);
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);
    try g.addEdge(5, 6);
    try g.addEdge(6, 7);
    try g.addEdge(0, 4);
    try g.addEdge(1, 5);
    try g.addEdge(2, 6);
    try g.addEdge(3, 7);
    return g;
}

// Checkerboard MIS gives 5 AODs and 4 SLMs.
// Many unmatched AODs at each timestep means
// maximum pressure on placeSlmQubits gap
// counting and the left-scan resting logic.
//
// 0-1-2
// | | |
// 3-4-5
// | | |
// 6-7-8
pub fn buildGridGraph(allocator: std.mem.Allocator) !Graph {
    var g = try Graph.init(allocator, 9, false);
    try g.addEdge(0, 1);
    try g.addEdge(1, 2);
    try g.addEdge(3, 4);
    try g.addEdge(4, 5);
    try g.addEdge(6, 7);
    try g.addEdge(7, 8);
    try g.addEdge(0, 3);
    try g.addEdge(3, 6);
    try g.addEdge(1, 4);
    try g.addEdge(4, 7);
    try g.addEdge(2, 5);
    try g.addEdge(5, 8);
    return g;
}

pub fn buildGhzGraph(allocator: std.mem.Allocator) !Graph {
    var g = try Graph.init(allocator, 8, false);
    try g.addEdge(0, 4);
    try g.addEdge(0, 2);
    try g.addEdge(4, 6);
    try g.addEdge(0, 1);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);
    try g.addEdge(6, 7);
    return g;
}

pub fn buildQftGraph(allocator: std.mem.Allocator) !Graph {
    var g = try Graph.init(allocator, 5, false);
    try g.addEdge(0, 1);
    try g.addEdge(0, 2);
    try g.addEdge(0, 3);
    try g.addEdge(0, 4);
    try g.addEdge(1, 2);
    try g.addEdge(1, 3);
    try g.addEdge(1, 4);
    try g.addEdge(2, 3);
    try g.addEdge(2, 4);
    try g.addEdge(3, 4);
    return g;
}

pub fn edgeColors(g: Graph) void {
    if (!trace.enabled) return;
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

pub fn aodTargets(g: *Graph, aod_order: []const usize, aod_targets: [][]usize) void {
    if (!trace.enabled) return;
    std.debug.print(">> AOD Target Positions\n", .{});

    for (1..aod_targets.len) |c| {
        const targets = aod_targets[c];
        std.debug.print("Color {d} (parallel CZ layer):\n", .{c});

        var shift: usize = 0;

        for (aod_order, 0..) |aod_id, i| {
            var partner: ?usize = null;

            var e = g.edges[aod_id];
            while (e) |edge| : (e = edge.next) {
                if (edge.color == @as(i32, @intCast(c))) {
                    partner = edge.y;
                    break;
                }
            }

            const target = targets[i];
            if (partner) |p| {
                std.debug.print("  AOD {d} (qubit {d}) -> ACTIVE partner {d} | column {d} (shift={d})\n", .{ i, aod_id, p, target, shift });
            } else {
                std.debug.print("  AOD {d} (qubit {d}) -> RESTING          | column {d} (shift={d} -> {d})\n", .{ i, aod_id, target, shift, shift + 1 });
                shift += 1;
            }
        }
    }
}

pub fn qubitPositions(
    time_step: usize,
    aod_order: []const usize,
    slm_order: []const usize,
    match: []const ?usize,
    fixed_slm_slots: []const usize,
    aod_slot: []const usize,
) void {
    if (!trace.enabled) return;
    std.debug.print("\n=== Resting Positions Debug — Time Step t = {} (SLMs FIXED) ===\n", .{time_step});
    std.debug.print("AOD order : ", .{});
    for (aod_order) |id| std.debug.print("AOD{d} ", .{id});
    std.debug.print("\nMatching  : ", .{});
    for (match) |m| {
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
                    if (match[i]) |slm_id| {
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
