const std = @import("std");

const Graph = @import("graph").Graph;

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
pub fn dsatur(gpa: std.mem.Allocator, g: *Graph, aod_nodes: []const usize, order: *SlmOrder) !void {
    // rank_of[q] = index of AOD q in the fixed sequence (0 = rightmost);
    // aod_set[q] = q is one of aod_nodes.
    const rank_of = try gpa.alloc(usize, g.n);
    @memset(rank_of, 0);
    defer gpa.free(rank_of);

    const aod_set = try gpa.alloc(bool, g.n);
    @memset(aod_set, false);
    defer gpa.free(aod_set);

    for (aod_nodes, 0..) |q, i| {
        rank_of[q] = i;
        aod_set[q] = true;
    }

    // cov_degree[q] = number of AOD neighbours; edge-sort tie-break.
    const cov_degree = try gpa.alloc(usize, g.n);
    @memset(cov_degree, 0);
    defer gpa.free(cov_degree);

    for (0..g.n) |u| {
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            if (aod_set[edge.y]) cov_degree[u] += 1;
        }
    }

    var colored: std.ArrayList(ColoredEdge) = .empty;
    defer colored.deinit(gpa);

    for (aod_nodes, 0..) |v, rank_v| {
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

test {
    std.testing.refAllDecls(@This());
}

fn edgeColor(g: *const Graph, x: usize, y: usize) ?i32 {
    var e = g.edges[x];
    while (e) |edge| : (e = edge.next) {
        if (edge.y == y) return edge.color;
    }
    return null;
}

test "mustPrecede is reflexive and empty without constraints" {
    var order = try SlmOrder.init(std.testing.allocator, 2);
    defer order.deinit();

    try std.testing.expect(order.mustPrecede(0, 0));
    try std.testing.expect(!order.mustPrecede(0, 1));
}

test "mustPrecede follows constraint chains transitively, not backwards" {
    // Transitively here means:
    // If constraint A contains constraint B, and constraint B contains
    // constraint C, then C is transitively located within A.
    var order = try SlmOrder.init(std.testing.allocator, 3);
    defer order.deinit();

    try order.addConstraint(0, 1);
    try order.addConstraint(1, 2);

    try std.testing.expect(order.mustPrecede(0, 2)); // transitively
    try std.testing.expect(!order.mustPrecede(2, 0));
    try std.testing.expect(!order.mustPrecede(1, 0));
}

test "addConstraint drops self loops and duplicates" {
    var order = try SlmOrder.init(std.testing.allocator, 2);
    defer order.deinit();

    try order.addConstraint(0, 0);
    try std.testing.expectEqual(0, order.adj[0].items.len);

    try order.addConstraint(0, 1);
    try order.addConstraint(0, 1);
    try std.testing.expectEqual(1, order.adj[0].items.len);
}

test "leastAdmissible starts at color zero with nothing colored" {
    var order = try SlmOrder.init(std.testing.allocator, 2);
    defer order.deinit();

    const rank_of = [_]usize{ 0, 0 };
    try std.testing.expectEqual(0, try leastAdmissible(0, 1, 0, &rank_of, &.{}, &order));
}

test "colors already on the slm are a floor, not just forbidden" {
    var order = try SlmOrder.init(std.testing.allocator, 3);
    defer order.deinit();

    // AOD 2 gated y=1 at color 1; AOD 0 must arrive strictly later.
    const colored = [_]ColoredEdge{.{ .aod = 2, .slm = 1, .color = 1 }};
    const rank_of = [_]usize{ 0, 0, 1 };

    try std.testing.expectEqual(2, try leastAdmissible(0, 1, 0, &rank_of, &colored, &order));
}

test "an aod cannot gate two partners in one color class" {
    var order = try SlmOrder.init(std.testing.allocator, 3);
    defer order.deinit();

    const colored = [_]ColoredEdge{.{ .aod = 0, .slm = 1, .color = 0 }};
    const rank_of = [_]usize{ 0, 0, 0 };

    try std.testing.expectEqual(1, try leastAdmissible(0, 2, 0, &rank_of, &colored, &order));
}

test "a partner ordered right of an already-gated one colors above it" {
    var order = try SlmOrder.init(std.testing.allocator, 3);
    defer order.deinit();

    // 1 sits left of 2 and v already gated 1 at color 1, so the
    // edge to 2 can slot neither below nor beside it.
    try order.addConstraint(1, 2);
    const colored = [_]ColoredEdge{.{ .aod = 0, .slm = 1, .color = 1 }};
    const rank_of = [_]usize{ 0, 0, 0 };

    try std.testing.expectEqual(2, try leastAdmissible(0, 2, 0, &rank_of, &colored, &order));
}

test "leastAdmissible errors when every color inverts the slm order" {
    var order = try SlmOrder.init(std.testing.allocator, 3);
    defer order.deinit();

    // 2 sits left of 1, but v already gated 1 below every candidate color.
    try order.addConstraint(2, 1);
    const colored = [_]ColoredEdge{.{ .aod = 0, .slm = 1, .color = 0 }};
    const rank_of = [_]usize{ 0, 0, 0 };

    try std.testing.expectError(error.CyclicAodOrder, leastAdmissible(0, 2, 0, &rank_of, &colored, &order));
}

test "a shared color class must mirror the aod ranks" {
    var order = try SlmOrder.init(std.testing.allocator, 4);
    defer order.deinit();

    // AOD 0 (rank 0, right of v=1) gated 2 at color 0. With 2 already left
    // of 3, putting (1, 3) in class 0 would need 3 left of 2: skip to 1.
    try order.addConstraint(2, 3);
    const colored = [_]ColoredEdge{.{ .aod = 0, .slm = 2, .color = 0 }};
    const rank_of = [_]usize{ 0, 1, 0, 0 };

    try std.testing.expectEqual(1, try leastAdmissible(1, 3, 1, &rank_of, &colored, &order));
}

test "dsatur colors a star left to right in gating order" {
    const gpa = std.testing.allocator;

    var g = try Graph.init(gpa, 4, false);
    defer g.deinit();
    try g.addEdge(0, 1);
    try g.addEdge(0, 2);
    try g.addEdge(0, 3);

    var order = try SlmOrder.init(gpa, 4);
    defer order.deinit();

    try dsatur(gpa, &g, &.{0}, &order);

    // All ties in the neighbour sort: lowest index gated first.
    try std.testing.expectEqual(0, edgeColor(&g, 0, 1));
    try std.testing.expectEqual(1, edgeColor(&g, 0, 2));
    try std.testing.expectEqual(2, edgeColor(&g, 0, 3));

    // Partners end up left to right in color order.
    try std.testing.expect(order.mustPrecede(1, 2));
    try std.testing.expect(order.mustPrecede(2, 3));
    try std.testing.expect(order.mustPrecede(1, 3));
    try std.testing.expect(!order.mustPrecede(3, 1));
}

test "dsatur gives a shared slm strictly increasing colors" {
    const gpa = std.testing.allocator;

    var g = try Graph.init(gpa, 3, false);
    defer g.deinit();
    try g.addEdge(0, 1);
    try g.addEdge(2, 1);

    var order = try SlmOrder.init(gpa, 3);
    defer order.deinit();

    try dsatur(gpa, &g, &.{ 0, 2 }, &order);

    try std.testing.expectEqual(0, edgeColor(&g, 0, 1));
    try std.testing.expectEqual(1, edgeColor(&g, 2, 1));

    // Both directions of an edge carry the same color.
    try std.testing.expectEqual(0, edgeColor(&g, 1, 0));
    try std.testing.expectEqual(1, edgeColor(&g, 1, 2));
}

test "aods sharing a color class order their partners by rank" {
    const gpa = std.testing.allocator;

    var g = try Graph.init(gpa, 4, false);
    defer g.deinit();
    try g.addEdge(0, 2);
    try g.addEdge(1, 3);

    var order = try SlmOrder.init(gpa, 4);
    defer order.deinit();

    try dsatur(gpa, &g, &.{ 0, 1 }, &order);

    // Disjoint edges share class 0; nodes[0] is the rightmost AOD, so the
    // later (leftward) AOD's partner sits left.
    try std.testing.expectEqual(0, edgeColor(&g, 0, 2));
    try std.testing.expectEqual(0, edgeColor(&g, 1, 3));

    try std.testing.expect(order.mustPrecede(3, 2));
    try std.testing.expect(!order.mustPrecede(2, 3));
}
