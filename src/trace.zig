//! The compiler's one tracing facility (§8 in REFACTORING.md). Library code
//! is silent by default; the driver flips `enabled` (the CLI's -v flag).
//! Error diagnostics that accompany a returned error are not traces and
//! still go through std.debug.print directly.
const std = @import("std");

/// Set once by the driver before compilation; passes only read it.
pub var enabled: bool = false;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (enabled) std.debug.print(fmt, args);
}

test {
    @import("testutil").refAllDeclsRecursive(@This());
}
