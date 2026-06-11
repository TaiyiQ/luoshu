const std = @import("std");
const builtin = @import("builtin");

/// std.testing.refAllDecls, recursing into pub container decls so every
/// function body in the module is semantically analyzed during tests —
/// dead code fails to compile instead of bit-rotting silently.
/// (std.testing.refAllDeclsRecursive was removed upstream.)
pub fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
