const std = @import("std");
const resting = @import("resting");

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
    gpa: std.mem.Allocator,
    edges: []?*EdgeNode,
    degree: []usize,
    n: usize,
    m: usize,
    directed: bool,

    pub fn init(gpa: std.mem.Allocator, n: usize, directed: bool) !Graph {
        const edges = try gpa.alloc(?*EdgeNode, n);
        @memset(edges, null);

        const degree = try gpa.alloc(usize, n);
        @memset(degree, 0);

        return Graph{
            .gpa = gpa,
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
                self.gpa.destroy(n);
                node = next;
            }
        }
        self.gpa.free(self.edges);
        self.gpa.free(self.degree);
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
        const n = try s.gpa.create(EdgeNode);
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

    fn deinit(s: *Aod, gpa: std.mem.Allocator) void {
        gpa.free(s.set);
        s.nodes.deinit(gpa);
    }

    // TODO: To be removed.
    fn reversed(s: *const Aod, gpa: std.mem.Allocator) ![]usize {
        const out = try gpa.dupe(usize, s.nodes.items);
        std.mem.reverse(usize, out);
        return out;
    }
};

const AodConstraints = struct {
    adj: []std.ArrayList(usize), // adj[i] = AOD indices that i must come before
    n: usize,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, n: usize) !AodConstraints {
        const adj = try gpa.alloc(std.ArrayList(usize), n);
        for (adj) |*a| a.* = .empty;
        return .{ .adj = adj, .n = n, .gpa = gpa };
    }

    fn deinit(self: *AodConstraints) void {
        for (self.adj) |*a| a.deinit(self.gpa);
        self.gpa.free(self.adj);
    }

    // BFS: can `from` reach `to`?
    fn canReach(self: *const AodConstraints, from: usize, to: usize) bool {
        if (from == to) return true;

        var visited = self.gpa.alloc(bool, self.n) catch return false;

        defer self.gpa.free(visited);
        @memset(visited, false);

        var queue: std.ArrayList(usize) = .empty;
        defer queue.deinit(self.gpa);

        visited[from] = true;
        queue.append(self.gpa, from) catch return false;

        while (queue.items.len > 0) {
            const u = queue.orderedRemove(0);

            if (u == to) return true;

            for (self.adj[u].items) |v| {
                if (!visited[v]) {
                    visited[v] = true;
                    queue.append(self.gpa, v) catch return false;
                }
            }
        }
        return false;
    }

    fn addConstraint(self: *AodConstraints, from: usize, to: usize) !void {
        if (from == to) return;
        for (self.adj[from].items) |x| if (x == to) return; // no duplicates
        try self.adj[from].append(self.gpa, to);
    }
};

fn maxIndependentSet(gpa: std.mem.Allocator, g: Graph) !Aod {
    var set = try gpa.alloc(bool, g.n);
    @memset(set, false);

    // Sort nodes descending by degree.
    var order = try std.ArrayList(usize).initCapacity(gpa, g.n);
    defer order.deinit(gpa);

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
    var nodes = try std.ArrayList(usize).initCapacity(gpa, g.n);

    for (order.items) |v| {
        if (set[v]) try nodes.append(gpa, v);
    }

    trace.print(">> AOD ordered nodes: {any}\n", .{nodes.items});

    return .{ .set = set, .nodes = nodes };
}

// Use a modified DSatur algorithm to color edges instead of nodes.
fn colorEdges(gpa: std.mem.Allocator, g: *Graph, aod: Aod) !void {
    // Map node_id -> index in aod_nodes (stable across the whole coloring).
    var aod_idx = std.AutoHashMap(usize, usize).init(gpa);
    defer aod_idx.deinit();

    for (aod.nodes.items, 0..) |a, i| try aod_idx.put(a, i);

    // Constraint graph: maintained incrementally to detect cycles early.
    var constraints = try AodConstraints.init(gpa, aod.nodes.items.len);
    defer constraints.deinit();

    for (aod.nodes.items) |v| {
        var adj: std.ArrayList(usize) = .empty;
        defer adj.deinit(gpa);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) try adj.append(gpa, edge.y);

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

    var forbidden = std.AutoHashMap(i32, void).init(g.gpa);
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
    var seen = std.AutoHashMap(i32, void).init(g.gpa);
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

fn slmGraph(gpa: std.mem.Allocator, g: *Graph, aod_set: []const bool) !Graph {
    var dep = try Graph.init(gpa, g.n, true);

    // For each AOD v...
    for (0..g.n) |v| {
        // Only AODs give constraints.
        if (!aod_set[v]) continue;

        // Collect SLM neighbours and their colors.
        const Adj = struct { y: usize, col: i32 };
        var adj: std.ArrayList(Adj) = .empty;
        defer adj.deinit(gpa);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) {
            const u = edge.y;
            // If the neighbour is an SLM.
            if (!aod_set[u]) {
                if (edge.color) |c| {
                    try adj.append(gpa, .{ .y = u, .col = c });
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

/// The SLM partner AOD `v` gates with in color class `t`, if any.
fn activePartner(g: *const Graph, aod_set: []const bool, v: usize, t: i32) ?usize {
    var e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        if (edge.color == t and !aod_set[edge.y]) return edge.y;
    }
    return null;
}

/// The schedule assumes a fixed physical column order for the AODs
/// (aod.nodes[0] is the rightmost column). Two AODs active in the same
/// color class sit at their partners' slots simultaneously, so their
/// column order is dictated by the partners' SLM order. Reorders
/// aod.nodes to satisfy every color class at once (topological sort over
/// the per-class constraints); the MIS degree order survives wherever the
/// constraints leave slack. Errors if the color classes demand
/// contradictory orders — such a coloring cannot be laid out with rigid
/// AOD columns.
fn orderAodNodes(gpa: std.mem.Allocator, g: *Graph, aod: *Aod, slm_order: []const usize) !void {
    const n = aod.nodes.items.len;
    if (n < 2) return;

    var slm_pos = std.AutoHashMap(usize, usize).init(gpa);
    defer slm_pos.deinit();
    for (slm_order, 0..) |q, i| try slm_pos.put(q, i);

    // adj[i] contains j: nodes[i] must sit left of nodes[j].
    var constraints = try AodConstraints.init(gpa, n);
    defer constraints.deinit();

    const in_degree = try gpa.alloc(usize, n);
    defer gpa.free(in_degree);
    @memset(in_degree, 0);

    const Active = struct { idx: usize, slot: usize };
    var active: std.ArrayList(Active) = .empty;
    defer active.deinit(gpa);

    const max_c = g.maxColor() catch return;
    var t: i32 = 0;
    while (t <= max_c) : (t += 1) {
        active.clearRetainingCapacity();
        for (aod.nodes.items, 0..) |v, i| {
            const partner = activePartner(g, aod.set, v, t) orelse continue;
            const slot = slm_pos.get(partner) orelse continue;
            try active.append(gpa, .{ .idx = i, .slot = slot });
        }

        std.sort.heap(Active, active.items, {}, struct {
            fn less(_: void, a: Active, b: Active) bool {
                return a.slot < b.slot;
            }
        }.less);

        // Consecutive pairs suffice: order is transitive.
        for (0..@as(usize, if (active.items.len == 0) 0 else active.items.len - 1)) |i| {
            const from = active.items[i].idx;
            const to = active.items[i + 1].idx;
            const before = constraints.adj[from].items.len;
            try constraints.addConstraint(from, to);
            if (constraints.adj[from].items.len > before) in_degree[to] += 1;
        }
    }

    // Kahn topological sort, emitting left to right. Among free nodes pick
    // the highest original index — the leftmost under the MIS order — so an
    // unconstrained input keeps its original order exactly.
    const placed = try gpa.alloc(bool, n);
    defer gpa.free(placed);
    @memset(placed, false);

    var ordered = try std.ArrayList(usize).initCapacity(gpa, n);
    defer ordered.deinit(gpa);

    while (ordered.items.len < n) {
        var pick: ?usize = null;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (!placed[i] and in_degree[i] == 0) {
                pick = i;
                break;
            }
        }
        const p = pick orelse return error.CyclicAodOrder;
        placed[p] = true;
        ordered.appendAssumeCapacity(aod.nodes.items[p]);
        for (constraints.adj[p].items) |j| in_degree[j] -= 1;
    }

    // `ordered` reads left to right; nodes[0] must be the rightmost column.
    std.mem.reverse(usize, ordered.items);
    @memcpy(aod.nodes.items, ordered.items);

    trace.print(">> AOD nodes ordered by SLM slots: {any}\n", .{aod.nodes.items});
}

fn topoSort(gpa: std.mem.Allocator, g: Graph, aod_set: []const bool, orig: Graph) ![]usize {
    // Only SLM qubits that participate in at least one CZ interaction.
    // Isolated qubits (orig.degree == 0) have no placement constraints.
    var n_slm: usize = 0;
    for (0..g.n) |i| {
        if (!aod_set[i] and orig.degree[i] > 0) n_slm += 1;
    }

    var order = try std.ArrayList(usize).initCapacity(gpa, n_slm);
    defer order.deinit(gpa);

    // Compure in-degrees; arrows pointing INTO each SLM.
    var in_degree = try gpa.alloc(usize, g.n);
    @memset(in_degree, 0);
    defer gpa.free(in_degree);

    for (0..g.n) |u| {
        if (aod_set[u] or orig.degree[u] == 0) continue;
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            if (!aod_set[edge.y] and orig.degree[edge.y] > 0) in_degree[edge.y] += 1;
        }
    }

    // Queue of SLM with zero in-degree can be placed first.
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(gpa);

    for (0..g.n) |i| {
        if (!aod_set[i] and orig.degree[i] > 0 and in_degree[i] == 0) try queue.append(gpa, i);
    }

    while (queue.items.len > 0) {
        const u = queue.orderedRemove(0);
        try order.append(gpa, u);

        // Reduce in-degrees of neighbours.
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            const v = edge.y;
            if (!aod_set[v] and orig.degree[v] > 0) {
                in_degree[v] -= 1;
                if (in_degree[v] == 0) try queue.append(gpa, v);
            }
        }
    }

    // A cycle leaves nodes with nonzero in-degree unplaced; a partial order
    // would silently produce an illegal layout downstream.
    if (order.items.len != n_slm) return error.CyclicSlmConstraints;

    return order.toOwnedSlice(gpa);
}

// Returns a 2D array containing the moveable AOD qubits per color (timestep).
// `timesteps[t][i]` is the SLM partner of aod.nodes.items[i] at timestep t, or
// null if that AOD is resting (precomputed by activePerTimestep).
fn logicalSchedule(
    arena: std.mem.Allocator,
    aod: Aod,
    slm_slots: []const ?usize,
    timesteps: []const []const ?usize,
) ![][]?usize {
    var slm_pos = std.AutoHashMap(usize, usize).init(arena);
    defer slm_pos.deinit();
    for (slm_slots, 0..) |v, t| {
        if (v) |id| try slm_pos.put(id, t);
    }

    std.debug.print("{any}\n", .{slm_slots});
    var it = slm_pos.iterator();
    while (it.next()) |v| {
        std.debug.print("{}:{}\n", .{ v.key_ptr.*, v.value_ptr.* });
    }

    var moveable = try arena.alloc([]?usize, timesteps.len);

    for (timesteps, 0..) |match, t| {
        // NOTE: Maybe we can use the length of the arch that
        // is known at comptime, and store this on the stack instead.
        const aod_slot = try arena.alloc(?usize, slm_slots.len);
        @memset(aod_slot, null);

        // Phase 1: Place active AODs with their SLM partners.
        const aod_nodes = try aod.reversed(arena);
        std.debug.print("{any}\n", .{aod_nodes});
        std.debug.print("match: {any}\n", .{match});
        for (match, 0..) |slm, qubit_id| {
            if (slm) |id| {
                if (slm_pos.get(id)) |c| {
                    std.debug.print("id: {}\n", .{qubit_id});
                    aod_slot[c] = aod_nodes[qubit_id];
                }
            }
        }
        std.debug.print("t{} - {any}\n", .{ t, aod_slot });

        // Phase 2: place resting AODs.
        // nodes[0]=rightmost; nodes[i] must land strictly LEFT of nodes[i-1].
        // match[] is indexed against aod_nodes (reversed, left-to-right), so
        // aod.nodes.items[i] corresponds to match[match.len - 1 - i].
        for (aod.nodes.items, 0..) |v, i| {
            if (match[match.len - 1 - i] != null) continue;

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
                trace.print("Failed to place resting AOD {d} at time step {d}\n", .{ v, t });
                return error.NoRestingSlotAvailable;
            }
        }

        moveable[t] = aod_slot;
        //trace.print("{any}\n", .{aod_slot});
    }

    return moveable;
}

fn activePerTimestep(
    gpa: std.mem.Allocator,
    g: *Graph,
    aod: Aod,
    slm_order: []const usize,
) ![]const []const ?usize {
    const max_c = try g.maxColor();
    const steps = @as(usize, @intCast(max_c + 1));

    const aod_nodes = try aod.reversed(gpa);
    defer gpa.free(aod_nodes);

    const timesteps = try gpa.alloc([]?usize, steps);
    errdefer gpa.free(timesteps);

    for (0..steps) |t_usize| {
        const t: i32 = @intCast(t_usize);

        const active = try gpa.alloc(?usize, aod_nodes.len);
        @memset(active, null);

        for (aod_nodes, 0..) |v, i| {
            var e = g.edges[v];
            while (e) |edge| : (e = edge.next) {
                if (edge.color == t) {
                    for (slm_order) |slm| {
                        if (slm == edge.y) {
                            active[i] = slm;
                        }
                    }
                }
            }
        }

        timesteps[t_usize] = active;
    }

    return timesteps;
}

pub fn computeSequence(gpa: std.mem.Allocator, g: *Graph) !Sequence {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. AOD set.
    var aod = try maxIndependentSet(gpa, g.*);
    defer aod.deinit(gpa);

    // 2. Color edges.
    try colorEdges(gpa, g, aod);
    edgeColors(g.*);

    // 3. SLM order.
    var dep_graph = try slmGraph(gpa, g, aod.set);
    defer dep_graph.deinit();
    //dep_graph.print("slm-dep");

    const slm_order = try topoSort(gpa, dep_graph, aod.set, g.*);
    defer gpa.free(slm_order);
    trace.print(">> Topological Order of SLM Qubits\n{any}\n", .{slm_order});

    // 4. Make the assumed AOD column order consistent with the SLM layout.
    try orderAodNodes(gpa, g, &aod, slm_order);

    const timesteps = try activePerTimestep(arena_alloc, g, aod, slm_order);
    const gaps = try resting.computeRestPositions(arena_alloc, slm_order, timesteps);
    const fixed = try resting.updateSlm(arena_alloc, slm_order, gaps);
    const moveable = try logicalSchedule(arena_alloc, aod, fixed, timesteps);

    return .{ .arena = arena, .fixed = fixed, .moveable = moveable };
}

test {
    std.testing.refAllDecls(@This());
}

/// Graph snapshot cases, routed and byte-compared against testdata/. The
/// snapshot tests below and `zig build update-snapshots` both walk this
/// table, so the regenerator can never drift from the tests.
pub const SnapshotKind = enum {
    mvp,
    cycle,
    ladder,
    grid,
    ghz,
    qft,
};

pub fn buildSnapshotGraph(kind: SnapshotKind, gpa: std.mem.Allocator) !Graph {
    return switch (kind) {
        .mvp => buildMvpGraph(gpa),
        .cycle => buildCycleGraph(gpa),
        .ladder => buildLadderGraph(gpa),
        .grid => buildGridGraph(gpa),
        .ghz => buildGhzGraph(gpa),
        .qft => buildQftGraph(gpa),
    };
}

pub const SnapshotCase = struct {
    kind: SnapshotKind,
    path: []const u8,

    /// A known routing bug (the route-level sibling of
    /// golden.Case.known_violation): this graph is non-bipartite, so no
    /// independent vertex cover exists — the greedy MIS must leave an edge
    /// between two SLM qubits, and computeSequence silently drops that CZ
    /// (active pairs are only ever AOD-SLM). Asserted so the completeness
    /// test fails loudly the day routing rejects or splits such graphs.
    known_incomplete: bool = false,
};

pub const snapshot_cases = [_]SnapshotCase{
    // aod set, coloring, schedule shape; triangle {2,3,4}
    .{ .kind = .mvp, .path = "testdata/mvp.json", .known_incomplete = true },

    // detect cycle in graph.
    .{ .kind = .cycle, .path = "testdata/cycle.json" },

    // parallel AOD lanes
    .{ .kind = .ladder, .path = "testdata/ladder.json" },

    // complex MIS and gap pressure
    .{ .kind = .grid, .path = "testdata/grid.json" },

    // binary tree
    .{ .kind = .ghz, .path = "testdata/ghz.json" },

    // K5: SLM set is K4
    .{ .kind = .qft, .path = "testdata/qft.json", .known_incomplete = true },
};

test "snapshots: routed graphs match testdata/" {
    for (snapshot_cases) |case| {
        try @import("snapshot.zig").snapshotTest(std.testing.allocator, std.testing.io, case);
    }
}

// Asserts `seq` realizes `g` exactly: every edge appears as an active pair
// — (fixed[i], moveable[t][i]) both non-null — in exactly one timeframe,
// nothing is pulsed that is not an edge, and no qubit is both fixed and
// moveable. A dropped edge is a CZ that never happens; a duplicated one
// cancels itself (CZ·CZ = identity). The snapshots pin the routed bytes;
// only this property says what would make them wrong. (Resting AODs only
// land on slots whose fixed entry is null — see logicalSchedule — so
// both-non-null is always an intended gate.)
fn expectSequenceCoversGraph(gpa: std.mem.Allocator, g: *const Graph, seq: *const Sequence) !void {
    var is_fixed = try gpa.alloc(bool, g.n);
    defer gpa.free(is_fixed);
    @memset(is_fixed, false);
    for (seq.fixed) |maybe_q| {
        if (maybe_q) |q| is_fixed[q] = true;
    }

    // Count every active pair, keyed by the normalized qubit pair.
    var covered = std.AutoHashMap(u64, usize).init(gpa);
    defer covered.deinit();

    for (seq.moveable) |row| {
        for (row, 0..) |maybe_q, i| {
            const q = maybe_q orelse continue;
            try std.testing.expect(!is_fixed[q]); // fixed/moveable disjoint
            const partner = seq.fixed[i] orelse continue;
            const lo: u64 = @min(q, partner);
            const hi: u64 = @max(q, partner);
            const gop = try covered.getOrPut(lo << 32 | hi);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    // Every edge of g covered exactly once...
    var complete = true;
    var n_edges: usize = 0;
    for (g.edges, 0..) |list, u| {
        var e = list;
        while (e) |edge| : (e = edge.next) {
            if (edge.y < u) continue; // undirected: count each edge once
            const key = @as(u64, @intCast(u)) << 32 | @as(u64, @intCast(edge.y));
            const cnt = covered.get(key) orelse 0;
            if (cnt != 1) {
                trace.print("edge ({d},{d}) covered {d} times\n", .{ u, edge.y, cnt });
                complete = false;
            }
            n_edges += 1;
        }
    }
    // ...and no pair pulsed that is not an edge.
    if (covered.count() != n_edges) {
        trace.print("{d} active pairs for {d} edges\n", .{ covered.count(), n_edges });
        complete = false;
    }
    if (!complete) return error.SequenceIncomplete;
}

test "computeSequence covers every snapshot graph's edges exactly once" {
    const gpa = std.testing.allocator;
    for (snapshot_cases) |case| {
        var g = try buildSnapshotGraph(case.kind, gpa);
        defer g.deinit();

        var seq = try computeSequence(gpa, &g);
        defer seq.deinit();

        if (case.known_incomplete) {
            try std.testing.expectError(
                error.SequenceIncomplete,
                expectSequenceCoversGraph(gpa, &g, &seq),
            );
        } else {
            try expectSequenceCoversGraph(gpa, &g, &seq);
        }
    }
}

test "computeSequence rejects a cyclic AOD column order" {
    const gpa = std.testing.allocator;
    // Five-cycle 0-1-3-4-2-0 with a pendant qubit 5 on 1 — the same
    // interaction graph as testdata/cyclic-aod.qasm. No rigid AOD column
    // order satisfies the coloring; the driver reacts by splitting the CZ
    // set into rounds (compiler.routeStageRounds), so the rejection must
    // originate here.
    var g = try Graph.init(gpa, 6, false);
    defer g.deinit();
    try g.addEdge(0, 1);
    try g.addEdge(0, 2);
    try g.addEdge(1, 3);
    try g.addEdge(1, 5);
    try g.addEdge(2, 4);
    try g.addEdge(3, 4);

    try std.testing.expectError(error.CyclicAodOrder, computeSequence(gpa, &g));
}

pub fn buildMvpGraph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 7, false);
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

pub fn buildCycleGraph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 6, false);
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
pub fn buildLadderGraph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 8, false);
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
pub fn buildGridGraph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 9, false);
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

pub fn buildGhzGraph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 8, false);
    try g.addEdge(0, 4);
    try g.addEdge(0, 2);
    try g.addEdge(4, 6);
    try g.addEdge(0, 1);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);
    try g.addEdge(6, 7);
    return g;
}

pub fn buildQftGraph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 5, false);
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
