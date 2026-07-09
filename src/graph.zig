const std = @import("std");

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
