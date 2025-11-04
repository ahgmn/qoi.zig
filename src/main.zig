const std = @import("std");
const qoi = @import("qoi");

pub fn main() !void {
    std.debug.print("Hello world!", .{});
}

test {
    std.testing.refAllDecls(@This());
}
