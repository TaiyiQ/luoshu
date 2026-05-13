const std = @import("std");

const INF = std.math.maxInt(usize);

const Adj = struct { y: usize, col: usize };

const SortCtx = struct {
    edge_color: [][]?usize,
    g: *Graph,
    v: usize,
};

const EdgeNode = struct {
    y: usize,
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
        n.* = .{ .y = y, .next = s.edges[x] };
        s.edges[x] = n;
        s.degree[x] += 1;
    }

    fn addEdge(s: *Graph, x: usize, y: usize) !void {
        try s.addNode(x, y);
        if (!s.directed) try s.addNode(y, x);
        s.m += 1;
    }

    fn print(self: *const Graph) void {
        std.debug.print(">> Graph(n={d}, m={d}, directed={}) \n", .{ self.n, self.m, self.directed });
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

fn independentSet(allocator: std.mem.Allocator, g: Graph) ![]bool {
    var I = try allocator.alloc(bool, g.n);
    @memset(I, false);

    // Sort nodes descending by degree.
    var order = try std.ArrayList(usize).initCapacity(allocator, g.n);
    defer order.deinit(allocator);

    for (0..g.n) |i| order.appendAssumeCapacity(i);
    std.sort.heap(usize, order.items, g, struct {
        fn lessThan(graph: Graph, a: usize, b: usize) bool {
            return graph.degree[a] > graph.degree[b];
        }
    }.lessThan);

    for (order.items) |v| {
        var can_add = true;
        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) {
            if (I[edge.y]) {
                can_add = false;
                break;
            }
        }
        if (can_add) I[v] = true;
    }

    return I;
}

fn dsatur(allocator: std.mem.Allocator, g: *Graph, I: []const bool) ![][]?usize {
    // edge_color[u][v] = color of edge u-v (null if no edge).
    var edge_color = try allocator.alloc([]?usize, g.n);
    for (0..g.n) |i| {
        edge_color[i] = try allocator.alloc(?usize, g.n);
        @memset(edge_color[i], null);
    }

    // 1. Get AOD nodes sorted by degree descending.
    var I_list: std.ArrayList(usize) = .empty;
    defer I_list.deinit(allocator);

    for (0..g.n) |i| if (I[i]) try I_list.append(allocator, i);
    std.sort.heap(usize, I_list.items, g, struct {
        fn less(graph: *Graph, a: usize, b: usize) bool {
            return graph.degree[a] > graph.degree[b];
        }
    }.less);

    // 2. For each AOD v...
    for (I_list.items) |v| {
        var S: std.ArrayList(usize) = .empty;
        defer S.deinit(allocator);

        var e = g.edges[v];
        while (e) |edge| : (e = edge.next) try S.append(allocator, edge.y);

        std.sort.heap(usize, S.items, SortCtx{ .edge_color = edge_color, .g = g, .v = v }, struct {
            fn less(ctx: SortCtx, a: usize, b: usize) bool {
                const sat_a = countSaturation(ctx.edge_color, ctx.g, ctx.v, a);
                const sat_b = countSaturation(ctx.edge_color, ctx.g, ctx.v, b);
                if (sat_a != sat_b) return sat_a > sat_b;
                return ctx.g.degree[a] > ctx.g.degree[b];
            }
        }.less);

        // 3. Color each edge in the sorted order.
        for (S.items) |y| {
            const c = leastAdmissible(edge_color, g, v, y);
            edge_color[v][y] = c;
            edge_color[y][v] = c; // undirected;
        }
    }

    return edge_color;
}

fn leastAdmissible(edge_color: [][]?usize, g: *Graph, v: usize, y: usize) usize {
    var forbidden = std.AutoHashMap(usize, void).init(g.allocator);
    defer forbidden.deinit();

    // All edges from v.
    // Share AOD node v.
    // Only forbidden, no order constaint.
    var e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        if (edge.y != y) {
            if (edge_color[v][edge.y]) |c| {
                _ = forbidden.getOrPut(c) catch {};
            }
        }
    }

    // Max color from adj edges not sharing the AOD node v.
    var order_max: usize = 0;

    // All edges from y.
    // Do not share AOD node v.
    // Both forbidden and order constraint.
    e = g.edges[y];
    while (e) |edge| : (e = edge.next) {
        if (edge.y != v) {
            if (edge_color[y][edge.y]) |c| {
                _ = forbidden.getOrPut(c) catch {};
                order_max = @max(order_max, c);
            }
        }
    }

    // Smallest k > order_max that is not forbidden.
    var k: usize = order_max + 1;
    while (true) : (k += 1) {
        if (forbidden.get(k) == null) return k;
    }
}

fn countSaturation(edge_color: [][]?usize, g: *Graph, u: usize, v: usize) usize {
    var seen = std.AutoHashMap(usize, void).init(g.allocator);
    defer seen.deinit();

    // Edges from u.
    var e = g.edges[u];
    while (e) |edge| : (e = edge.next) {
        const w = edge.y;
        if (w != v) {
            if (edge_color[u][w]) |c| {
                _ = seen.getOrPut(c) catch {};
            }
        }
    }

    // Edges from v.
    e = g.edges[v];
    while (e) |edge| : (e = edge.next) {
        const w = edge.y;
        if (w != v) {
            if (edge_color[v][w]) |c| {
                _ = seen.getOrPut(c) catch {};
            }
        }
    }

    return seen.count();
}

fn printEdgeColors(g: Graph, edge_color: [][]?usize) void {
    for (0..g.n) |u| {
        var has_any = false;
        for (0..g.n) |v| {
            if (u < v) {
                if (edge_color[u][v]) |c| {
                    if (!has_any) {
                        std.debug.print("  {d} -> ", .{u});
                        has_any = true;
                    }
                    std.debug.print("{d}:{d} ", .{ v, c });
                }
            }
        }
        if (has_any) std.debug.print("\n", .{});
    }
}

fn slmGraph(allocator: std.mem.Allocator, g: *Graph, I: []const bool, edge_color: [][]?usize) !Graph {
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
            if (!I[u]) {
                if (edge_color[v][u]) |col| {
                    try adj.append(allocator, .{ .y = u, .col = col });
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

fn targetPosition(
    allocator: std.mem.Allocator,
    g: *Graph,
    aod_order: []const usize,
    slm_order: []const usize,
    edge_color: [][]?usize,
) ![][]usize {
    // 1. Precompute max color used.
    var max_c: usize = 0;
    for (0..g.n) |u| {
        for (0..g.n) |v| {
            if (edge_color[u][v]) |c| {
                max_c = @max(max_c, c);
            }
        }
    }
    if (max_c == 0) return error.NoColors;

    // 2. Precompute slm_pos[slm_id] = its index in slm_order
    var slm_pos = try allocator.alloc(usize, g.n);
    defer allocator.free(slm_pos);
    for (0..slm_order.len) |i| {
        slm_pos[slm_order[i]] = i;
    }

    // 3. Allocate result: one slice per color.
    var positions_per_color = try allocator.alloc([]usize, max_c + 1);
    for (1..max_c + 1) |c| {
        positions_per_color[c] = try allocator.alloc(usize, aod_order.len);
    }

    // 4. For each color, compute targets with the shift trick.
    for (1..max_c + 1) |c| {
        var targets = positions_per_color[c];
        var shift: usize = 0;
        var current_column: usize = 0;

        for (aod_order, 0..) |aod, i| {
            // Check if AOD has a partner for this color.
            var partnet_y: ?usize = null;
            var e = g.edges[aod];
            while (e) |edge| : (e = edge.next) {
                if (edge_color[aod][edge.y] == c) {
                    partnet_y = edge.y;
                    break;
                }
            }

            if (partnet_y) |y| {
                // ACTIVE: move to the shifted SLM position.
                const base = slm_pos[y];
                const target = base + shift;
                targets[i] = target;
                current_column = target + 1;
            } else {
                // INACTIVE: park in the resting position at the current column.
                targets[i] = current_column;
                current_column += 1;
                shift += 1;
            }
        }
    }

    return positions_per_color;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = try Graph.init(alloc, 7, false);
    defer g.deinit();

    // Ex. 1
    //    try g.addEdge(0, 1);
    //    try g.addEdge(0, 3);
    //    try g.addEdge(1, 2);
    //    try g.addEdge(2, 3);

    // Ex. 2
    try g.addEdge(0, 1);
    try g.addEdge(0, 5);
    try g.addEdge(1, 6);
    try g.addEdge(5, 6);
    try g.addEdge(6, 3);
    try g.addEdge(6, 4);
    try g.addEdge(3, 4);
    try g.addEdge(3, 2);
    try g.addEdge(4, 2);

    // ----------
    // 0
    // ----------

    const I = try independentSet(alloc, g);
    defer alloc.free(I);
    for (I, 0..) |v, i| {
        std.debug.print("{} {}\n", .{ i, v });
    }

    const edge_colors = try dsatur(alloc, &g, I);
    defer {
        for (edge_colors) |row| alloc.free(row);
        alloc.free(edge_colors);
    }
    printEdgeColors(g, edge_colors);

    // ----------
    // 1
    // ----------

    // Build the SLM dependency DAQ from colors.
    var dep_graph = try slmGraph(alloc, &g, I, edge_colors);
    defer dep_graph.deinit();
    dep_graph.print();

    // Get the perfect left-to-right SLM order.
    const slm_order = try topoSort(alloc, dep_graph, I);
    defer alloc.free(slm_order);
    std.debug.print(">> Topological Order of SLM Qubits\n", .{});
    std.debug.print("{any}\n", .{slm_order});

    // ----------
    // 2
    // ----------

    var aod_order: std.ArrayList(usize) = .empty;
    defer aod_order.deinit(alloc);
    for (0..g.n) |i| {
        if (I[i]) try aod_order.append(alloc, i);
    }

    const aod_targets = try targetPosition(alloc, &g, aod_order.items, slm_order, edge_colors);
    defer {
        for (1..aod_targets.len) |c| {
            alloc.free(aod_targets[c]);
        }
        alloc.free(aod_targets);
    }
    debugAodTargets(&g, aod_order.items, aod_targets, edge_colors);
}

fn debugAodTargets(
    g: *Graph,
    aod_order: []const usize,
    aod_targets: [][]usize,
    edge_color: [][]?usize,
) void {
    std.debug.print(">> AOD Order\n", .{});

    for (1..aod_targets.len) |c| {
        const targets = aod_targets[c];
        std.debug.print("Color {d} (parallel CZ layer):\n", .{c});

        var shift: usize = 0;
        var current_col: usize = 0;

        for (aod_order, 0..) |aod_id, i| {
            var partner: ?usize = null;
            var e = g.edges[aod_id];
            while (e) |edge| : (e = edge.next) {
                if (edge_color[aod_id][edge.y] == c) {
                    partner = edge.y;
                    break;
                }
            }

            const target = targets[i];
            if (partner) |p| {
                // ACTIVE
                std.debug.print("  AOD {d} -> ACTIVE partner {d} | column {d} (shift={d})\n", .{ aod_id, p, target, shift });
                current_col = target + 1;
            } else {
                // RESTING
                std.debug.print("  AOD {d} -> RESTING          | column {d} (shift={d} -> {d})\n", .{ aod_id, target, shift, shift + 1 });
                current_col = target + 1;
                shift += 1;
            }
        }
    }
}
