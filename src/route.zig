const std = @import("std");
const resting = @import("resting");
const trace = @import("trace");

const MIN = -1; // maxColor sentinel: below every real color.

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

    // Qubit IDs fixed in the SLM in the compute zone.
    fixed: []const ?usize,

    // Per timeframe: qubit IDs moving across the fixed SLM qubits.
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
};

/// Left-to-right SLM ordering constraints built during edge coloring:
/// adj[q] holds the qubits q must sit left of. Kept acyclic by construction
/// - leastAdmissible checks reachability before committing.
const SlmOrder = struct {
    gpa: std.mem.Allocator,
    adj: []std.ArrayList(usize),
    n: usize,

    fn init(gpa: std.mem.Allocator, n: usize) !SlmOrder {
        const adj = try gpa.alloc(std.ArrayList(usize), n);
        for (adj) |*a| a.* = .empty;
        return .{ .adj = adj, .n = n, .gpa = gpa };
    }

    fn deinit(self: *SlmOrder) void {
        for (self.adj) |*a| a.deinit(self.gpa);
        self.gpa.free(self.adj);
    }

    // Is `from` transitively forced left of `to`? Reflexive.
    fn mustPrecede(self: *const SlmOrder, from: usize, to: usize) bool {
        if (from == to) return true;

        var visited = self.gpa.alloc(bool, self.n) catch return false;
        @memset(visited, false);
        defer self.gpa.free(visited);

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

    // Record `from` left of `to`. Does not check for cycles; callers verify
    // via mustPrecede before committing.
    fn addConstraint(self: *SlmOrder, from: usize, to: usize) !void {
        if (from == to) return;
        for (self.adj[from].items) |x| if (x == to) return;
        try self.adj[from].append(self.gpa, to);
    }
};

fn maxIndependentSet(gpa: std.mem.Allocator, g: Graph) !Aod {
    var set = try gpa.alloc(bool, g.n);
    @memset(set, false);

    var order = try std.ArrayList(usize).initCapacity(gpa, g.n);
    defer order.deinit(gpa);

    for (0..g.n) |i| order.appendAssumeCapacity(i);

    std.sort.heap(usize, order.items, g, struct {
        fn less(graph: Graph, a: usize, b: usize) bool {
            if (graph.degree[a] != graph.degree[b]) {
                return graph.degree[a] > graph.degree[b];
            }
            return a > b;
        }
    }.less);

    // Greedy MIS. Isolated nodes have no two-qubit interactions and must
    // remain SLM qubits.
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

    var nodes = try std.ArrayList(usize).initCapacity(gpa, g.n);
    defer nodes.deinit(gpa);

    for (order.items) |v| {
        if (set[v]) try nodes.append(gpa, v);
    }

    // Group AODs by connected component, keeping degree order within each.
    // This order is final: nodes[0] is the rightmost AOD column, and the
    // coloring only ever accepts colors that respect it.
    const none = std.math.maxInt(usize);

    const comp = try gpa.alloc(usize, g.n);
    @memset(comp, none);
    defer gpa.free(comp);

    var n_comp: usize = 0;
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);

    for (0..g.n) |root| {
        if (comp[root] != none) continue;

        comp[root] = n_comp;
        try stack.append(gpa, root);

        while (stack.pop()) |u| {
            var e = g.edges[u];

            while (e) |edge| : (e = edge.next) {
                if (comp[edge.y] == none) {
                    comp[edge.y] = n_comp;
                    try stack.append(gpa, edge.y);
                }
            }
        }

        n_comp += 1;
    }

    const done = try gpa.alloc(bool, n_comp);
    @memset(done, false);
    defer gpa.free(done);

    var grouped = try std.ArrayList(usize).initCapacity(gpa, nodes.items.len);
    for (nodes.items) |v| {
        if (done[comp[v]]) continue;

        done[comp[v]] = true;

        for (nodes.items) |u| {
            if (comp[u] == comp[v]) grouped.appendAssumeCapacity(u);
        }
    }

    return .{ .set = set, .nodes = grouped };
}

const ColoredEdge = struct { aod: usize, slm: usize, color: i32 };

// Modified DSatur edge coloring, after arXiv:2405.08068 (and qmap's
// NAGraphAlgorithms). Edges are colored AOD by AOD in the fixed sequence
// order while a partial order on the SLM qubits grows alongside: an AOD
// gates its SLM partners left to right in color order, and AODs sharing a
// color class order their partners by AOD rank. leastAdmissible rejects
// colors that contradict the partial order, so the AOD sequence never needs
// reordering and the SLM layout is just a topological sort of `order`.
fn colorEdges(gpa: std.mem.Allocator, g: *Graph, aod: Aod, order: *SlmOrder) !void {
    // rank_of[q] = index of AOD q in the fixed sequence (0 = rightmost).
    const rank_of = try gpa.alloc(usize, g.n);
    @memset(rank_of, 0);
    defer gpa.free(rank_of);

    for (aod.nodes.items, 0..) |q, i| rank_of[q] = i;

    // cov_degree[q] = number of AOD neighbours; edge-sort tie-break.
    const cov_degree = try gpa.alloc(usize, g.n);
    @memset(cov_degree, 0);
    defer gpa.free(cov_degree);

    for (0..g.n) |u| {
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            if (aod.set[edge.y]) cov_degree[u] += 1;
        }
    }

    var colored: std.ArrayList(ColoredEdge) = .empty;
    defer colored.deinit(gpa);

    for (aod.nodes.items, 0..) |v, rank_v| {
        var adj: std.ArrayList(usize) = .empty;
        defer adj.deinit(gpa);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) try adj.append(gpa, edge.y);

        const Ctx = struct { g: *Graph, v: usize, order: *const SlmOrder, cov: []const usize };
        std.sort.heap(usize, adj.items, Ctx{ .g = g, .v = v, .order = order, .cov = cov_degree }, struct {
            fn less(ctx: Ctx, a: usize, b: usize) bool {
                if (a == b) return false;

                // An SLM already ordered left of another must be gated first.
                if (ctx.order.mustPrecede(a, b)) return true;
                if (ctx.order.mustPrecede(b, a)) return false;

                const sat_a = countSaturation(ctx.g, ctx.v, a);
                const sat_b = countSaturation(ctx.g, ctx.v, b);
                if (sat_a != sat_b) return sat_a > sat_b;

                if (ctx.cov[a] != ctx.cov[b]) return ctx.cov[a] > ctx.cov[b];

                return a < b;
            }
        }.less);

        for (adj.items) |y| {
            const c = try leastAdmissible(v, y, rank_v, rank_of, colored.items, order);

            var n = g.edges[v];
            while (n) |edge| : (n = edge.next) {
                if (edge.y == y) edge.color = c;
            }

            n = g.edges[y];
            while (n) |edge| : (n = edge.next) {
                if (edge.y == v) edge.color = c;
            }

            // Commit the constraints the color implies; leastAdmissible
            // already verified none closes a cycle.
            for (colored.items) |f| {
                if (f.aod == v) {
                    if (f.color < c) {
                        try order.addConstraint(f.slm, y);
                    } else {
                        try order.addConstraint(y, f.slm);
                    }
                } else if (f.color == c) {
                    if (rank_v < rank_of[f.aod]) {
                        try order.addConstraint(f.slm, y);
                    } else {
                        try order.addConstraint(y, f.slm);
                    }
                }
            }

            try colored.append(gpa, .{ .aod = v, .slm = y, .color = c });
        }
    }
}

/// Smallest color for edge (v, y) - v the AOD, y the SLM - that keeps the
/// SLM partial order acyclic. Errors when no color can: the coloring cannot
/// complete against the fixed AOD column order.
fn leastAdmissible(
    v: usize,
    y: usize,
    rank_v: usize,
    rank_of: []const usize,
    colored: []const ColoredEdge,
    order: *const SlmOrder,
) !i32 {
    // Colors already on y are a floor, not just forbidden: y sits at one
    // column, so every AOD gating it must have left before v arrives.
    var min_c: i32 = 0;
    for (colored) |f| {
        if (f.slm == y) min_c = @max(min_c, f.color + 1);
    }

    var k: i32 = min_c;
    outer: while (true) : (k += 1) {
        for (colored) |f| {
            if (f.aod == v) {
                // v cannot gate two partners in one class...
                if (f.color == k) continue :outer;

                if (f.color > k) {
                    // ...and would add y -> f.slm; cycle if f.slm already reaches y.
                    if (order.mustPrecede(f.slm, y)) continue :outer;
                } else {
                    // Would add f.slm -> y. f.color stays below every later
                    // candidate too, so this cycle cannot be colored around.
                    if (order.mustPrecede(y, f.slm)) return error.CyclicAodOrder;
                }
            } else if (f.color == k) {
                // Same class: the SLM order must mirror the AOD ranks.
                if (rank_v > rank_of[f.aod]) {
                    if (order.mustPrecede(f.slm, y)) continue :outer;
                } else {
                    if (order.mustPrecede(y, f.slm)) continue :outer;
                }
            }
        }
        return k;
    }
}

fn countSaturation(g: *Graph, u: usize, v: usize) usize {
    var seen = std.AutoHashMap(i32, void).init(g.gpa);
    defer seen.deinit();

    var e = g.edges[u];
    while (e) |edge| : (e = edge.next) {
        const w = edge.y;
        if (w != v) {
            if (edge.color) |c| {
                _ = seen.getOrPut(c) catch {};
            }
        }
    }

    e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        const w = edge.y;
        if (w != u) {
            if (edge.color) |c| {
                _ = seen.getOrPut(c) catch {};
            }
        }
    }

    return seen.count();
}

/// Left-to-right SLM layout: topological sort of the partial order built
/// during coloring. Isolated qubits (degree 0) are not placed.
fn topoSort(gpa: std.mem.Allocator, order: SlmOrder, aod_set: []const bool, g: Graph) ![]usize {
    var n_slm: usize = 0;
    for (0..g.n) |i| {
        if (!aod_set[i] and g.degree[i] > 0) n_slm += 1;
    }

    var out = try std.ArrayList(usize).initCapacity(gpa, n_slm);
    defer out.deinit(gpa);

    var in_degree = try gpa.alloc(usize, g.n);
    @memset(in_degree, 0);
    defer gpa.free(in_degree);

    for (order.adj) |list| {
        for (list.items) |j| in_degree[j] += 1;
    }

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(gpa);

    for (0..g.n) |i| {
        if (!aod_set[i] and g.degree[i] > 0 and in_degree[i] == 0) try queue.append(gpa, i);
    }

    while (queue.items.len > 0) {
        const u = queue.orderedRemove(0);
        try out.append(gpa, u);

        for (order.adj[u].items) |w| {
            in_degree[w] -= 1;
            if (in_degree[w] == 0) try queue.append(gpa, w);
        }
    }

    // The coloring keeps the partial order acyclic by construction; a
    // leftover node would silently produce an illegal layout downstream.
    if (out.items.len != n_slm) return error.CyclicSlmConstraints;

    return out.toOwnedSlice(gpa);
}

// `timesteps[t][k]` is the SLM partner of aod_nodes[k] (left-to-right column
// order) at timestep t, or null if that AOD is resting.
fn activePerTimestep(
    gpa: std.mem.Allocator,
    g: *Graph,
    aod_nodes: []const usize,
    slm_order: []const usize,
) ![]const []const ?usize {
    const max_c = try g.maxColor();
    const steps = @as(usize, @intCast(max_c + 1));

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

    // AOD set. Its order is final: nodes[0] is the rightmost column.
    var aod = try maxIndependentSet(gpa, g.*);
    defer aod.deinit(gpa);
    trace.print(">> AOD ordered nodes: {any}\n", .{aod.nodes.items});

    // Color edges against the fixed AOD order, accumulating the SLM
    // partial order as colors commit.
    var order = try SlmOrder.init(gpa, g.n);
    defer order.deinit();
    try colorEdges(gpa, g, aod, &order);
    edgeColors(g.*);

    const slm_order = try topoSort(gpa, order, aod.set, g.*);
    defer gpa.free(slm_order);
    trace.print(">> Topological Order of SLM Qubits\n{any}\n", .{slm_order});

    // Downstream stages work with the physical left-to-right order.
    const aod_lr = try arena_alloc.dupe(usize, aod.nodes.items);
    std.mem.reverse(usize, aod_lr);

    const timesteps = try activePerTimestep(arena_alloc, g, aod_lr, slm_order);
    const gaps = try resting.computePositions(arena_alloc, slm_order, timesteps);
    const fixed = try resting.placeControlQubits(arena_alloc, slm_order, gaps);
    const moveable = try resting.scheduleTargetQubits(arena_alloc, aod_lr, fixed, timesteps);

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
    graph_10_0,
};

pub fn buildSnapshotGraph(kind: SnapshotKind, gpa: std.mem.Allocator) !Graph {
    return switch (kind) {
        .mvp => buildMvpGraph(gpa),
        .cycle => buildCycleGraph(gpa),
        .ladder => buildLadderGraph(gpa),
        .grid => buildGridGraph(gpa),
        .ghz => buildGhzGraph(gpa),
        .qft => buildQftGraph(gpa),
        .graph_10_0 => buildGraph10Graph(gpa),
    };
}

pub const SnapshotCase = struct {
    kind: SnapshotKind,
    path: []const u8,

    /// Known routing bug (route-level sibling of golden.Case.known_violation):
    /// the graph is non-bipartite, so the greedy MIS leaves an SLM-SLM edge
    /// and computeSequence silently drops that CZ. Asserted so the
    /// completeness test fails loudly the day routing handles such graphs.
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

    // only known graph exercising the mid-sweep flush in
    // resting.mergeConstraints; triangles {0,3,8} and {4,6,9} force
    // SLM-SLM edges, so the cover is incomplete.
    .{ .kind = .graph_10_0, .path = "testdata/graph-10-0.json", .known_incomplete = true },
};

test "snapshots: routed graphs match testdata/" {
    for (snapshot_cases) |case| {
        try @import("snapshot.zig").snapshotTest(std.testing.allocator, std.testing.io, case);
    }
}

// Asserts `seq` realizes `g` exactly: every edge appears as an active pair
// (fixed[i] and moveable[t][i] both non-null) in exactly one timeframe,
// nothing is pulsed that is not an edge, and no qubit is both fixed and
// moveable. A dropped edge is a CZ that never happens; a duplicated one
// cancels itself (CZ*CZ = identity). Resting AODs only land on slots whose
// fixed entry is null (resting.scheduleTargetQubits), so both-non-null is
// always an intended gate.
fn expectSequenceCoversGraph(gpa: std.mem.Allocator, g: *const Graph, seq: *const Sequence) !void {
    var is_fixed = try gpa.alloc(bool, g.n);
    defer gpa.free(is_fixed);
    @memset(is_fixed, false);
    for (seq.fixed) |maybe_q| {
        if (maybe_q) |q| is_fixed[q] = true;
    }

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

test "computeSequence routes the cyclic-aod graph in one round" {
    const gpa = std.testing.allocator;
    // Five-cycle 0-1-3-4-2-0 with a pendant qubit 5 on 1, the interaction
    // graph of testdata/cyclic-aod.qasm. The old post-hoc AOD column
    // ordering rejected this with CyclicAodOrder. The odd cycle still
    // drops one SLM-SLM edge, so coverage stays incomplete.
    var g = try Graph.init(gpa, 6, false);
    defer g.deinit();
    try g.addEdge(0, 1);
    try g.addEdge(0, 2);
    try g.addEdge(1, 3);
    try g.addEdge(1, 5);
    try g.addEdge(2, 4);
    try g.addEdge(3, 4);

    var seq = try computeSequence(gpa, &g);
    defer seq.deinit();

    try std.testing.expectError(
        error.SequenceIncomplete,
        expectSequenceCoversGraph(gpa, &g, &seq),
    );
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

// Vertical rungs create cross-row constraints: the SLM topo-sort
// must merge constraints from two independent AOD lanes.
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

// Checkerboard MIS (5 AODs, 4 SLMs): many unmatched AODs per timestep
// pressure gap counting and the left-scan resting logic.
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

/// Interaction graph of testdata/graph-10-0.qasm, edges in gate order.
pub fn buildGraph10Graph(gpa: std.mem.Allocator) !Graph {
    var g = try Graph.init(gpa, 10, false);
    try g.addEdge(0, 1);
    try g.addEdge(0, 3);
    try g.addEdge(0, 8);
    try g.addEdge(1, 2);
    try g.addEdge(1, 5);
    try g.addEdge(3, 8);
    try g.addEdge(3, 5);
    try g.addEdge(8, 9);
    try g.addEdge(2, 7);
    try g.addEdge(2, 6);
    try g.addEdge(7, 5);
    try g.addEdge(7, 4);
    try g.addEdge(4, 9);
    try g.addEdge(4, 6);
    try g.addEdge(9, 6);
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
