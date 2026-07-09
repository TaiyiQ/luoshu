//! The compiler's one tracing facility. Library code
//! is silent by default; the driver flips `enabled` (the CLI's -v flag).
//! Error diagnostics that accompany a returned error are not traces and
//! still go through std.debug.print directly.
const std = @import("std");

/// Set once by the driver before compilation; passes only read it.
pub var enabled: bool = false;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (enabled) std.debug.print(fmt, args);
}

/// Shared body of the "diagnostic print, suppressible by a module-local
/// `quiet` flag" idiom used by architecture.validate, assembly.check, and
/// verify.verify — each keeps its own `quiet` (tests toggle it per-module)
/// and a thin wrapper that supplies its own prefix.
pub fn diag(quiet: bool, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    std.debug.print(fmt ++ "\n", args);
}

test {
    std.testing.refAllDecls(@This());
}
