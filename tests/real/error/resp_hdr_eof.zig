const std = @import("std");
const os = std.os;
const math = std.math;
const mem = std.mem;
const rand = std.rand;
const time = std.time;

const datetime = @import("datetime");
const http = @import("hutaback");
const IO = @import("tigerbeetle-io").IO;

const testing = std.testing;

test "real / error / resp header eof" {
    // testing.log_level = .warn;

    try struct {
        const Context = @This();
        const Client = http.Client(Context);
        const Server = http.Server(Context, Handler);

        const Handler = struct {
            conn: *Server.Conn = undefined,

            pub fn start(self: *Handler) void {
                std.log.debug("Handler.start", .{});
                self.conn.recvRequestHeader(recvRequestHeaderCallback);
            }

            pub fn recvRequestHeaderCallback(self: *Handler, result: Server.RecvRequestHeaderError!usize) void {
                std.log.info("Handler.recvRequestHeaderCallback start, result={}", .{result});
                if (result) |_| {
                    if (!self.conn.fullyReadRequestContent()) {
                        self.conn.recvRequestContentFragment(recvRequestContentFragmentCallback);
                        return;
                    }

                    self.sendResponse();
                } else |err| {
                    std.log.err("Handler.recvRequestHeaderCallback should get error.InvalidCharacter, found={s}", .{@errorName(err)});
                }
            }

            pub fn recvRequestContentFragmentCallback(self: *Handler, result: Server.RecvRequestContentFragmentError!usize) void {
                std.log.debug("Handler.recvRequestContentFragmentCallback start, result={}", .{result});
                if (result) |_| {
                    if (!self.conn.fullyReadRequestContent()) {
                        self.conn.recvRequestContentFragment(recvRequestContentFragmentCallback);
                        return;
                    }

                    self.sendResponse();
                } else |err| {
                    std.log.err("Handler.recvRequestContentFragmentCallback err={s}", .{@errorName(err)});
                }
            }

            pub fn sendResponse(self: *Handler) void {
                std.log.debug("Handler.sendResponse start", .{});
                var fbs = std.io.fixedBufferStream(self.conn.send_buf);
                var w = fbs.writer();
                std.fmt.format(w, "{s} {d} {s}\r\n", .{
                    http.Version.http1_1.toBytes(),
                    http.StatusCode.no_content.code(),
                    http.StatusCode.no_content.toText(),
                }) catch unreachable;
                http.writeDatetimeHeader(w, "Date", datetime.datetime.Datetime.now()) catch unreachable;
                self.conn.keep_alive = false;
                std.fmt.format(w, "Connection: {s}\r\n", .{"close"}) catch unreachable;
                // incomplete response header
                self.conn.sendFull(fbs.getWritten(), sendResponseCallback);
            }

            fn sendResponseCallback(self: *Handler, last_result: IO.SendError!usize) void {
                std.log.debug("Handler.sendResponseCallback start, last_result={}", .{last_result});
                if (last_result) |_| {
                    self.conn.finishSend();
                } else |err| {
                    std.log.err("Handler.sendResponseCallback err={s}", .{@errorName(err)});
                }
            }
        };

        server: Server = undefined,
        client: Client = undefined,
        allocator: mem.Allocator = undefined,
        send_header_buf: []u8 = undefined,
        recv_header_result: Client.RecvResponseHeaderError!usize = undefined,

        fn connectCallback(
            self: *Context,
            result: IO.ConnectError!void,
        ) void {
            std.log.debug("Context.connectCallback start, result={}", .{result});
            if (result) |_| {
                var fbs = std.io.fixedBufferStream(self.send_header_buf);
                var w = fbs.writer();
                std.fmt.format(w, "{s} {s} {s}\r\n", .{
                    (http.Method{ .get = undefined }).toBytes(),
                    "/",
                    http.Version.http1_1.toBytes(),
                }) catch unreachable;
                std.fmt.format(w, "Host: example.com\r\n", .{}) catch unreachable;
                std.fmt.format(w, "\r\n", .{}) catch unreachable;
                self.client.sendFull(fbs.getWritten(), sendHeaderCallback);
            } else |err| {
                std.log.err("Context.connectCallback err={s}", .{@errorName(err)});
                self.exitTest();
            }
        }
        fn sendHeaderCallback(
            self: *Context,
            result: IO.SendError!usize,
        ) void {
            std.log.info("Context.sendHeaderCallback start, result={}", .{result});
            if (result) |_| {
                self.client.recvResponseHeader(recvResponseHeaderCallback);
            } else |err| {
                std.log.err("Context.sendFullCallback err={s}", .{@errorName(err)});
                self.exitTest();
            }
        }
        fn recvResponseHeaderCallback(
            self: *Context,
            result: Client.RecvResponseHeaderError!usize,
        ) void {
            std.log.info("Context.recvResponseHeaderCallback start, result={}", .{result});
            if (result) |_| {
                if (!self.client.fullyReadResponseContent()) {
                    self.client.recvResponseContentFragment(recvResponseContentFragmentCallback);
                    return;
                }

                std.log.info("Context.recvResponseHeaderCallback before calling self.client.close", .{});
                self.client.close();
                self.exitTest();
            } else |err| {
                self.recv_header_result = err;
                if (err != error.UnexpectedEof) {
                    std.log.err("recvResponseHeaderCallback err={s}", .{@errorName(err)});
                }
                self.exitTest();
            }
        }
        fn recvResponseContentFragmentCallback(
            self: *Context,
            result: Client.RecvResponseContentFragmentError!usize,
        ) void {
            std.log.debug("Context.recvResponseContentFragmentCallback start, result={}", .{result});
            if (result) |_| {
                if (!self.client.fullyReadResponseContent()) {
                    self.client.recvResponseContentFragment(recvResponseContentFragmentCallback);
                    return;
                }

                std.log.info("Context.recvResponseContentFragmentCallback before calling self.client.close", .{});
                self.client.close();
                self.exitTest();
            } else |err| {
                std.log.err("recvResponseContentFragmentCallback err={s}", .{@errorName(err)});
                self.exitTest();
            }
        }

        fn exitTest(self: *Context) void {
            self.server.requestShutdown();
        }

        fn generateRandomHeader(allocator: mem.Allocator) ![]const u8 {
            var bin_buf: [16384]u8 = undefined;
            var encoded_buf: [32768]u8 = undefined;

            var r = rand.DefaultPrng.init(@intCast(u64, time.nanoTimestamp())).random();
            r.bytes(&bin_buf);

            const encoder = std.base64.url_safe_no_pad.Encoder;
            const encoded = encoder.encode(&encoded_buf, &bin_buf);
            return try allocator.dupe(u8, encoded);
        }

        fn runTest() !void {
            var io = try IO.init(32, 0);
            defer io.deinit();

            const allocator = testing.allocator;
            // Use a random port
            const address = try std.net.Address.parseIp4("127.0.0.1", 0);

            var self: Context = .{
                .allocator = allocator,
                .send_header_buf = try allocator.alloc(u8, 8192 * 4),
            };
            defer allocator.free(self.send_header_buf);

            self.server = try Server.init(allocator, &io, &self, address, .{
                .response_buf_len = 1024,
            });
            defer self.server.deinit();

            self.client = try Client.init(allocator, &io, &self, &.{
                .response_header_buf_ini_len = 512,
                .response_header_buf_max_len = 1024,
            });
            defer self.client.deinit();

            try self.server.start();
            try self.client.connect(self.server.bound_address, connectCallback);

            while (!self.client.done or !self.server.done) {
                try io.tick();
            }

            try testing.expectError(error.UnexpectedEof, self.recv_header_result);
        }
    }.runTest();
}
