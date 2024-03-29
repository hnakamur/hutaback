const std = @import("std");
const time = std.time;

const http = @import("hutaback");
const IO = @import("tigerbeetle-io").IO;

const testing = std.testing;
const iptables = @import("iptables.zig");

test "real / error / connection timedout" {
    if (std.os.linux.getuid() != 0) return error.SkipZigTest;

    try struct {
        const Context = @This();
        const Client = http.Client(Context);

        client: Client = undefined,
        connect_result: IO.ConnectError!void = undefined,

        fn connectCallback(
            self: *Context,
            result: IO.ConnectError!void,
        ) void {
            self.connect_result = result;
        }

        fn runTest() !void {
            const dest_addr = "127.0.0.1";
            const dest_port = 3131;

            const allocator = testing.allocator;
            try iptables.appendRule(allocator, dest_addr, dest_port, .drop);
            defer iptables.deleteRule(allocator, dest_addr, dest_port, .drop) catch @panic("delete iptables rule");

            var io = try IO.init(32, 0);
            defer io.deinit();

            const address = try std.net.Address.parseIp4(dest_addr, dest_port);

            var self: Context = .{};

            self.client = try Client.init(allocator, &io, &self, &.{
                .connect_timeout_ns = 100 * time.ns_per_ms,
            });
            defer self.client.deinit();

            try self.client.connect(address, connectCallback);

            while (!self.client.done) {
                try io.tick();
            }

            try testing.expectError(error.Canceled, self.connect_result);
        }
    }.runTest();
}
