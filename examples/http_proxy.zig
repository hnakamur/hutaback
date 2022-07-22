const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const IO = @import("tigerbeetle-io").IO;
const http = @import("hutaback");

fn getEnvUint(comptime T: type, name: []const u8, default: T, max: T) T {
    if (os.getenv(name)) |s| {
        if (std.fmt.parseInt(T, s, 10)) |v| {
            if (v <= max) return v;
        } else |err| {
            std.debug.print("bad environment variable \"{s}\" value={s}, err={s}\n", .{ name, s, @errorName(err) });
        }
    }
    return default;
}

const Context = @This();
const Proxy = http.Proxy(Context);

pub const log_level: std.log.Level = .warn;

var proxy: *Proxy = undefined;

fn sigchld(signo: i32) callconv(.C) void {
    std.debug.print("got signal, signo={d}\n", .{signo});
    proxy.server.requestShutdown();
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var io = try IO.init(32, 0);
    defer io.deinit();

    const port_max = 65535;
    const origin_port_default = 80;
    const origin_port = getEnvUint(u16, "ORIGIN_PORT", origin_port_default, port_max);
    const origin_address = try net.Address.parseIp4("127.0.0.1", origin_port);

    const proxy_port_default = 8080;
    const proxy_port = getEnvUint(u16, "PROXY_PORT", proxy_port_default, port_max);
    const proxy_address = try net.Address.parseIp4("127.0.0.1", proxy_port);

    var self = Context{};

    proxy = try Proxy.init(
        allocator,
        &io,
        &self,
        proxy_address,
        origin_address,
        .{},
        .{},
    );
    defer proxy.deinit();

    try os.sigaction(os.SIG.INT, &.{
        .handler = .{ .handler = sigchld },
        .mask = os.system.empty_sigset,
        .flags = os.system.SA.NOCLDSTOP,
    }, null);

    try proxy.server.start();

    while (!proxy.server.done) {
        try io.tick();
    }
}
