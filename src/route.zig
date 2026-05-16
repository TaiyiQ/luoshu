const std = @import("std");

const INF = std.math.maxInt(usize);
const MIN = -1; // -1 to help k in leastAdmissible start at 0.

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

const Schedule = struct {
    slm_slots: []const ?usize,
    aod_slots_per_color: [][]?usize,
    max_color: i32,

    fn deinit(self: *Schedule, allocator: std.mem.Allocator) void {
        allocator.free(self.slm_slots);
        for (self.aod_slots_per_color) |slot| {
            allocator.free(slot);
        }
        allocator.free(self.aod_slots_per_color);
    }

    fn print(self: Schedule) void {
        const n_slots = self.slm_slots.len;

        std.debug.print("\n", .{});

        // Divider
        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        // Header
        std.debug.print("     |", .{});
        for (0..n_slots) |s| std.debug.print("{d:^5}|", .{s});
        std.debug.print("\n", .{});

        // Divider
        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        // SLM row
        std.debug.print(" SLM |", .{});
        for (self.slm_slots) |v| {
            if (v) |id| std.debug.print("{d:^5}|", .{id}) else std.debug.print("  ·  |", .{});
        }
        std.debug.print("\n", .{});

        // Divider
        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});

        // AOD rows
        for (self.aod_slots_per_color, 0..) |aod_slot, t| {
            std.debug.print("  t{d} |", .{t});
            for (aod_slot, 0..) |v, s| {
                const has_slm = self.slm_slots[s] != null;
                if (v) |id| {
                    if (has_slm) std.debug.print(" {d:^3} |", .{id}) // conflict: 5 chars total
                    else std.debug.print("{d:^5}|", .{id});
                } else {
                    std.debug.print("  ·  |", .{});
                }
            }
            std.debug.print("\n", .{});
        }

        // Footer
        std.debug.print("     +", .{});
        for (0..n_slots) |_| std.debug.print("-----+", .{});
        std.debug.print("\n", .{});
        std.debug.print("\n", .{});
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
    directed: bool, // Used for topological sorting of SLMs.

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
        // Ignore self-loops.
        if (x == y) return;

        // Ignore duplicate edges.
        var e = s.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.y == y) return;
        }

        try s.addNode(x, y);
        if (!s.directed) try s.addNode(y, x);
        s.m += 1;
    }

    fn maxColor(g: *const Graph) !i32 {
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

//fn aodSet(allocator: std.mem.Allocator, g: Graph) ![]bool {
//    var aod_set = try allocator.alloc(bool, g.n);
//    @memset(aod_set, false);
//
//    // Sort nodes descending by degree.
//    var order = try std.ArrayList(usize).initCapacity(allocator, g.n);
//    defer order.deinit(allocator);
//
//    for (0..g.n) |i| order.appendAssumeCapacity(i);
//    std.sort.heap(usize, order.items, g, struct {
//        fn less(graph: Graph, a: usize, b: usize) bool {
//            return graph.degree[a] > graph.degree[b];
//        }
//    }.less);
//    std.debug.print("1 -- order: {any}", .{order.items});
//
//    // Add node when all it's neighbours are false.
//    for (order.items) |v| {
//        var add = true;
//        var e = g.edges[v];
//        while (e) |edge| : (e = edge.next) {
//            if (aod_set[edge.y]) {
//                add = false;
//                break;
//            }
//        }
//        if (add) aod_set[v] = true;
//    }
//
//    return aod_set;
//}

fn aodSet(allocator: std.mem.Allocator, g: Graph) ![]bool {
    // Try 2-coloring (BFS). For bipartite graphs this gives a valid
    // vertex cover, ensuring every edge has one AOD endpoint.
    const color = try allocator.alloc(i8, g.n); // -1=unvisited, 0=SLM, 1=AOD
    defer allocator.free(color);
    @memset(color, -1);

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    // Handle disconnected components.
    for (0..g.n) |start| {
        if (color[start] != -1) continue;
        color[start] = 1; // seed each component as AOD
        try queue.append(allocator, start);

        while (queue.items.len > 0) {
            const u = queue.orderedRemove(0);
            var e = g.edges[u];
            while (e) |edge| : (e = edge.next) {
                const v = edge.y;
                if (color[v] == -1) {
                    color[v] = 1 - color[u]; // flip color
                    try queue.append(allocator, v);
                } else if (color[v] == color[u]) {
                    // Odd cycle — not bipartite. Fall back to greedy MIS.
                    return aodSetGreedy(allocator, g);
                }
            }
        }
    }

    // Use the smaller partition as AODs to minimize atom moves.
    var count: [2]usize = .{ 0, 0 };
    for (color) |c| count[@intCast(c)] += 1;
    const aod_color: i8 = if (count[0] <= count[1]) 0 else 1;

    const aod_set = try allocator.alloc(bool, g.n);
    for (0..g.n) |i| aod_set[i] = (color[i] == aod_color);
    return aod_set;
}

// Original greedy MIS as fallback for non-bipartite graphs.
fn aodSetGreedy(allocator: std.mem.Allocator, g: Graph) ![]bool {
    var aod_set = try allocator.alloc(bool, g.n);
    @memset(aod_set, false);

    var order = try std.ArrayList(usize).initCapacity(allocator, g.n);
    defer order.deinit(allocator);
    for (0..g.n) |i| order.appendAssumeCapacity(i);
    std.sort.heap(usize, order.items, g, struct {
        fn less(graph: Graph, a: usize, b: usize) bool {
            if (graph.degree[a] != graph.degree[b]) return graph.degree[a] > graph.degree[b];
            return a < b;
        }
    }.less);

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
fn dsatur(allocator: std.mem.Allocator, g: *Graph, aod_set: []const bool) !void {
    var aod_nodes: std.ArrayList(usize) = .empty;
    defer aod_nodes.deinit(allocator);
    for (0..g.n) |i| if (aod_set[i]) try aod_nodes.append(allocator, i);

    std.sort.heap(usize, aod_nodes.items, g, struct {
        fn less(graph: *Graph, a: usize, b: usize) bool {
            if (graph.degree[a] != graph.degree[b]) return graph.degree[a] > graph.degree[b];
            return a < b;
        }
    }.less);

    // Map node_id -> index in aod_nodes (stable across the whole coloring).
    var aod_idx = std.AutoHashMap(usize, usize).init(allocator);
    defer aod_idx.deinit();
    for (aod_nodes.items, 0..) |a, i| try aod_idx.put(a, i);

    // Constraint graph: maintained incrementally to detect cycles early.
    var constraints = try AodConstraints.init(allocator, aod_nodes.items.len);
    defer constraints.deinit();

    for (aod_nodes.items) |v| {
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
        for (0..adj.items.len - 1) |i| {
            const y1 = adj.items[i].y;
            const y2 = adj.items[i + 1].y;
            try dep.addEdge(y1, y2);
        }
    }

    return dep;
}

fn topoSortAods(
    allocator: std.mem.Allocator,
    g: *const Graph,
    aod_set: []const bool,
    slm_order: []const usize,
    max_c: i32,
) !?[]usize {
    // Rank map: slm_id -> left-to-right rank from topo sort
    var slm_rank = std.AutoHashMap(usize, usize).init(allocator);
    defer slm_rank.deinit();
    for (slm_order, 0..) |s, i| try slm_rank.put(s, i);

    // Collect AOD nodes in stable index order
    var aods: std.ArrayList(usize) = .empty;
    defer aods.deinit(allocator);

    for (0..g.n) |i| if (aod_set[i]) try aods.append(allocator, i);
    const n = aods.items.len;

    var aod_idx = std.AutoHashMap(usize, usize).init(allocator);
    defer aod_idx.deinit();
    for (aods.items, 0..) |a, i| try aod_idx.put(a, i);

    // Boolean adjacency matrix for "must be left of" constraints
    const matrix = try allocator.alloc(bool, n * n);
    defer allocator.free(matrix);
    @memset(matrix, false);

    // For each time step, sort active AODs by SLM rank and record ordering constraints
    var t: i32 = 0;
    while (t <= max_c) : (t += 1) {
        const Pair = struct { ai: usize, rank: usize };
        var active: std.ArrayList(Pair) = .empty;
        defer active.deinit(allocator);

        for (aods.items, 0..) |aod, ai| {
            var e = g.edges[aod];
            while (e) |edge| : (e = edge.next) {
                if (!aod_set[edge.y] and edge.color == t) {
                    if (slm_rank.get(edge.y)) |rank| {
                        try active.append(allocator, .{ .ai = ai, .rank = rank });
                    }
                    break;
                }
            }
        }

        std.sort.heap(Pair, active.items, {}, struct {
            fn less(_: void, a: Pair, b: Pair) bool {
                return a.rank < b.rank;
            }
        }.less);

        for (0..active.items.len -| 1) |i| {
            matrix[active.items[i].ai * n + active.items[i + 1].ai] = true;
        }
    }

    // Topological sort on the AOD constraint graph
    var in_deg = try allocator.alloc(usize, n);
    defer allocator.free(in_deg);
    @memset(in_deg, 0);
    for (0..n) |i| {
        for (0..n) |j| {
            if (matrix[i * n + j]) in_deg[j] += 1;
        }
    }

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    for (0..n) |i| if (in_deg[i] == 0) try queue.append(allocator, i);

    var result: std.ArrayList(usize) = .empty;
    defer result.deinit(allocator);

    while (queue.items.len > 0) {
        const u = queue.orderedRemove(0);
        try result.append(allocator, aods.items[u]);
        for (0..n) |v| {
            if (matrix[u * n + v]) {
                in_deg[v] -= 1;
                if (in_deg[v] == 0) try queue.append(allocator, v);
            }
        }
    }

    // Cycle detected — not all nodes were sorted.
    if (result.items.len != n) return null;

    const slice = try result.toOwnedSlice(allocator);
    return slice;
}

fn topoSort(allocator: std.mem.Allocator, g: Graph, aod_set: []const bool) ![]usize {
    // Only SLM qubits
    var n_slm: usize = 0;
    for (0..g.n) |i| {
        if (!aod_set[i]) n_slm += 1;
    }

    var order = try std.ArrayList(usize).initCapacity(allocator, n_slm);
    defer order.deinit(allocator);

    // Compure in-degrees; arrows pointing INTO each SLM.
    var in_degree = try allocator.alloc(usize, g.n);
    @memset(in_degree, 0);
    defer allocator.free(in_degree);

    for (0..g.n) |u| {
        if (aod_set[u]) continue;
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            if (!aod_set[edge.y]) in_degree[edge.y] += 1;
        }
    }

    // Queue of SLM with zero in-degree can be placed first.
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    for (0..g.n) |i| {
        if (!aod_set[i] and in_degree[i] == 0) try queue.append(allocator, i);
    }

    while (queue.items.len > 0) {
        const u = queue.orderedRemove(0);
        try order.append(allocator, u);

        // Reduce in-degrees of neighbours.
        var e = g.edges[u];
        while (e) |edge| : (e = edge.next) {
            const v = edge.y;
            if (!aod_set[v]) {
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
    aod_order: []const usize,
    aod_set: []const bool,
    t: i32,
) ![]?usize {
    if (aod_order.len == 0) return try allocator.alloc(?usize, 0);

    const match = try allocator.alloc(?usize, aod_order.len);
    @memset(match, null);
    errdefer allocator.free(match);

    for (aod_order, 0..) |x, i| {
        var e = g.edges[x];
        while (e) |edge| : (e = edge.next) {
            if (edge.color == t and !aod_set[edge.y]) {
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
    aod_order: []const usize,
    slm_slots: []const ?usize,
    aod_set: []const bool,
) !Schedule {
    var slm_pos = std.AutoHashMap(usize, usize).init(allocator);
    defer slm_pos.deinit();
    for (slm_slots, 0..) |v, i| {
        if (v != null) try slm_pos.put(v.?, i);
    }

    const max_c = try g.maxColor();
    const n_slot = @as(usize, @intCast(max_c)) + 1;
    var aod_slots_per_color = try allocator.alloc([]?usize, n_slot);

    // Track each AOD's last known slot position to enforce left-to-right movement.
    var last_pos = try allocator.alloc(usize, aod_order.len);
    defer allocator.free(last_pos);
    @memset(last_pos, 0);

    var t: usize = 0;
    while (t < max_c + 1) : (t += 1) {
        const match = try matchAodToSlm(allocator, g, aod_order, aod_set, @intCast(t));
        defer allocator.free(match);

        const aod_slot = try allocator.alloc(?usize, slm_slots.len);
        @memset(aod_slot, null);

        // First pass: place matched AODs.
        for (match, 0..) |slm, i| {
            if (slm == null) continue;
            const idx = slm_pos.get(slm.?).?;
            aod_slot[idx] = aod_order[i];
            last_pos[i] = idx;
        }

        // Second pass: place unmatched AODs into resting positions.
        for (aod_order, 0..) |aod, i| {
            if (match[i] != null) continue;

            // Must be right of own last position AND right of the AOD to our left
            // in the current timestep (preserves global left-to-right order).
            var min_pos = last_pos[i];
            if (i > 0) {
                // Find where the left neighbour landed this timestep.
                for (0..aod_slot.len) |s| {
                    if (aod_slot[s]) |id| {
                        if (id == aod_order[i - 1]) {
                            min_pos = @max(min_pos, s + 1);
                            break;
                        }
                    }
                }
            }

            var gap_ptr: usize = min_pos;
            var placed = false;
            while (gap_ptr < aod_slot.len) : (gap_ptr += 1) {
                if (slm_slots[gap_ptr] == null and aod_slot[gap_ptr] == null) {
                    aod_slot[gap_ptr] = aod;
                    last_pos[i] = gap_ptr;
                    placed = true;
                    gap_ptr += 1;
                    break;
                }
            }
            if (!placed) return error.NoRestingSlotAvailable;
        }

        // After placing, update last_pos for matched AODs too
        // (already done in first pass above).

        aod_slots_per_color[t] = aod_slot;
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
    aod_set: []const bool,
) ![]?usize {
    if (aod_order.len == 0) return error.NoAodNodes;

    const max_c = try g.maxColor();
    const n_slm = slm_order.len;

    // slm_rank[slm_id] = index in slm_order (left-to-right rank).
    var slm_rank = std.AutoHashMap(usize, usize).init(allocator);
    defer slm_rank.deinit();
    for (slm_order, 0..) |s, i| try slm_rank.put(s, i);

    // aod_rank[aod_id] = index in aod_order.
    var aod_rank = std.AutoHashMap(usize, usize).init(allocator);
    defer aod_rank.deinit();
    for (aod_order, 0..) |a, i| try aod_rank.put(a, i);

    // gap_needs[g] = max AODs that need to rest in gap g across all timesteps.
    // Gap g is the space before SLM at slm_order[g] (gap 0 = before first SLM,
    // gap n_slm = after last SLM, gaps 1..n_slm-1 = between consecutive SLMs).
    const n_gaps = n_slm + 1;
    const gap_needs = try allocator.alloc(usize, n_gaps);
    defer allocator.free(gap_needs);
    @memset(gap_needs, 0);

    var t: i32 = 0;
    while (t <= max_c) : (t += 1) {
        const match = try matchAodToSlm(allocator, g, aod_order, aod_set, t);
        defer allocator.free(match);

        // For each gap, count how many AODs rest there this timestep.
        const gap_count = try allocator.alloc(usize, n_gaps);
        defer allocator.free(gap_count);
        @memset(gap_count, 0);

        // Build active SLM rank set for matched AODs.
        // An unmatched AOD at aod_order index i rests in the gap between
        // the SLM rank of the matched AOD to its left and the one to its right.
        var left_rank: usize = 0; // 0 = before all SLMs
        for (aod_order, 0..) |_, i| {
            if (match[i]) |slm_id| {
                left_rank = slm_rank.get(slm_id).? + 1;
            } else {
                // This AOD rests in the gap just after left_rank - 1,
                // i.e. gap index = left_rank.
                gap_count[left_rank] += 1;
            }
        }

        for (0..n_gaps) |gi| {
            gap_needs[gi] = @max(gap_needs[gi], gap_count[gi]);
        }
    }

    std.debug.print("gap_needs: {any}\n", .{gap_needs});

    // Build slm_slots by inserting gap slots between SLMs.
    // Total slots = n_slm + sum(gap_needs) + leading AOD slots.
    var total_gaps: usize = 0;
    for (gap_needs) |gn| total_gaps += gn;

    // Leading slots: AODs that rest before the first SLM need space too,
    // but we also need n_aod - 1 slots at the front as the initial AOD region.
    // Actually total = n_slm + total_gaps covers everything since gap_needs[0]
    // counts AODs resting before the first SLM.
    const total = n_slm + total_gaps;
    const slm_slot = try allocator.alloc(?usize, total);
    @memset(slm_slot, null);

    // Fill slots: for each gap then SLM in order.
    var pos: usize = 0;
    for (0..n_slm) |si| {
        // Insert gap_needs[si] empty slots before SLM si.
        pos += gap_needs[si];
        slm_slot[pos] = slm_order[si];
        pos += 1;
    }
    // Trailing gap after last SLM.
    // (already accounted for in total; slots remain null)

    std.debug.print("SLM Slots: {any}\n", .{slm_slot});
    return slm_slot;
}

fn writeToJson(allocator: std.mem.Allocator, io: std.Io, schedule: *const Schedule, filename: []const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\n");

    // slm_slots
    try w.writeAll("  \"slm_slots\": [");
    for (schedule.slm_slots, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        if (v) |slot| try w.print("{d}", .{slot}) else try w.writeAll("null");
    }
    try w.writeAll("],\n");

    // aod_slots_per_color
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
    match: []const ?usize,
    fixed_slm_slots: []const usize,
    aod_slot: []const usize,
) void {
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

fn compile(allocator: std.mem.Allocator, g: *Graph) !Schedule {
    const aod_set = try aodSet(allocator, g.*);
    defer allocator.free(aod_set);

    try dsatur(allocator, g, aod_set);
    debugEdgeColors(g.*);

    var dep_graph = try slmGraph(allocator, g, aod_set);
    defer dep_graph.deinit();
    dep_graph.print("slm-dep");

    const slm_order = try topoSort(allocator, dep_graph, aod_set);
    defer allocator.free(slm_order);
    std.debug.print(">> Topological Order of SLM Qubits\n{any}\n", .{slm_order});

    const max_c = try g.maxColor();
    const aod_order = try topoSortAods(allocator, g, aod_set, slm_order, max_c) orelse return error.AodOrderingCycle;
    defer allocator.free(aod_order);
    std.debug.print(">> AOD Order\n{any}\n", .{aod_order});

    const slm_slots = try placeSlmQubits(allocator, g, aod_order, slm_order, aod_set);
    // slm_slots ownership transfers into Schedule; caller must free via schedule.deinit()

    return logicalSchedule(allocator, g, aod_order, slm_slots, aod_set);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = try Graph.init(alloc, 8, false);
    defer g.deinit();
    try g.addEdge(0, 4);
    try g.addEdge(0, 2);
    try g.addEdge(4, 6);
    try g.addEdge(0, 1);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);
    try g.addEdge(6, 7);

    var schedule = try compile(alloc, &g);
    defer schedule.deinit(alloc);
    schedule.print();

    const io = init.io;
    try writeToJson(alloc, io, &schedule, "/tmp/schedule.json");

    std.debug.print(">> Gate compilation completed\n", .{});
}

// TODO: Update unit tests to check for AOD crossings.
test "7-node graph: aod set, coloring, schedule shape" {
    const alloc = std.testing.allocator;

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

    var schedule = try compile(alloc, &g);
    defer schedule.deinit(alloc);

    try std.testing.expect(schedule.max_color >= 3);
    try std.testing.expectEqual(
        @as(usize, @intCast(schedule.max_color + 1)),
        schedule.aod_slots_per_color.len,
    );
}

test "8-node GHZ binary tree: 3 time steps, no crossings" {
    const alloc = std.testing.allocator;

    var g = try Graph.init(alloc, 8, false);
    defer g.deinit();
    try g.addEdge(0, 4);
    try g.addEdge(0, 2);
    try g.addEdge(4, 6);
    try g.addEdge(0, 1);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);
    try g.addEdge(6, 7);

    var schedule = try compile(alloc, &g);
    defer schedule.deinit(alloc);

    try std.testing.expectEqual(@as(i32, 2), schedule.max_color);
    try std.testing.expectEqual(@as(usize, 3), schedule.aod_slots_per_color.len);

    for (schedule.aod_slots_per_color) |aod_slot| {
        var seen = std.AutoHashMap(usize, void).init(alloc);
        defer seen.deinit();
        for (aod_slot) |entry| {
            if (entry) |aod_id| {
                const result = try seen.getOrPut(aod_id);
                try std.testing.expect(!result.found_existing);
            }
        }
    }
}

test "10-node bipartite circuit: no crossings, no conflicts" {
    const alloc = std.testing.allocator;

    var g = try Graph.init(alloc, 10, false);
    defer g.deinit();
    try g.addEdge(0, 6);
    try g.addEdge(0, 2);
    try g.addEdge(1, 7);
    try g.addEdge(1, 2);
    try g.addEdge(3, 9);
    try g.addEdge(3, 6);
    try g.addEdge(4, 9);
    try g.addEdge(4, 8);
    try g.addEdge(5, 8);
    try g.addEdge(5, 7);

    var schedule = try compile(alloc, &g);
    defer schedule.deinit(alloc);

    // Bipartite graph with max degree 2 → at most 2 colors.
    try std.testing.expect(schedule.max_color <= 2);
    try std.testing.expectEqual(
        @as(usize, @intCast(schedule.max_color + 1)),
        schedule.aod_slots_per_color.len,
    );
}
