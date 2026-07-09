const std = @import("std");

const Graph = @import("graph").Graph;

// TODO: This should not belong here. Maybe rethink this struct.
pub const Aod = struct {
    set: []bool,
    nodes: std.ArrayList(usize), // ordered nodes

    pub fn deinit(s: *Aod, gpa: std.mem.Allocator) void {
        gpa.free(s.set);
        s.nodes.deinit(gpa);
    }
};

const ColoredEdge = struct {
    aod: usize,
    slm: usize,
    color: i32,
};

/// Left-to-right SLM ordering constraints built during edge coloring:
/// adj[q] holds the qubits q must sit left of. Kept acyclic by construction
/// - leastAdmissible checks reachability before committing.
pub const SlmOrder = struct {
    gpa: std.mem.Allocator,
    adj: []std.ArrayList(usize),
    n: usize,

    pub fn init(gpa: std.mem.Allocator, n: usize) !SlmOrder {
        const adj = try gpa.alloc(std.ArrayList(usize), n);
        for (adj) |*a| a.* = .empty;
        return .{ .adj = adj, .n = n, .gpa = gpa };
    }

    pub fn deinit(self: *SlmOrder) void {
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

// Modified DSatur edge coloring, after arXiv:2405.08068 (and qmap's
// NAGraphAlgorithms). Edges are colored AOD by AOD in the fixed sequence
// order while a partial order on the SLM qubits grows alongside: an AOD
// gates its SLM partners left to right in color order, and AODs sharing a
// color class order their partners by AOD rank. leastAdmissible rejects
// colors that contradict the partial order, so the AOD sequence never needs
// reordering and the SLM layout is just a topological sort of `order`.
pub fn dsatur(gpa: std.mem.Allocator, g: *Graph, aod: Aod, order: *SlmOrder) !void {
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
