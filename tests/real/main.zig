const std = @import("std");

const _ = @import("success/main.zig");

comptime {
    std.testing.refAllDecls(@This());
}