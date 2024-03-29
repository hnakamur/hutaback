const std = @import("std");
const os = std.os;
const time = std.time;

const datetime = @import("datetime");
const http = @import("hutaback");
const IO = @import("tigerbeetle-io").IO;

const testing = std.testing;

test "real / success / reuse conn slot" {
    // testing.log_level = .debug;
    const content = "Hello from http.Server\n";

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
                std.log.debug("Handler.recvRequestHeaderCallback start, result={}", .{result});
                if (result) |_| {
                    if (!self.conn.fullyReadRequestContent()) {
                        self.conn.recvRequestContentFragment(recvRequestContentFragmentCallback);
                        return;
                    }

                    self.sendResponse();
                } else |err| {
                    std.log.err("Handler.recvRequestHeaderCallback err={s}", .{@errorName(err)});
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
                    http.StatusCode.ok.code(),
                    http.StatusCode.ok.toText(),
                }) catch unreachable;
                http.writeDatetimeHeader(w, "Date", datetime.datetime.Datetime.now()) catch unreachable;

                switch (self.conn.request.version) {
                    .http1_1 => if (!self.conn.keep_alive) {
                        std.fmt.format(w, "Connection: {s}\r\n", .{"close"}) catch unreachable;
                    },
                    .http1_0 => if (self.conn.keep_alive) {
                        std.fmt.format(w, "Connection: {s}\r\n", .{"keep-alive"}) catch unreachable;
                    },
                    else => {},
                }
                const content_length = content.len;
                std.fmt.format(w, "Content-Length: {d}\r\n", .{content_length}) catch unreachable;
                std.fmt.format(w, "\r\n", .{}) catch unreachable;
                std.fmt.format(w, "{s}", .{content}) catch unreachable;
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

        client: Client = undefined,
        buffer: std.fifo.LinearFifo(u8, .Dynamic),
        content_read_so_far: u64 = undefined,
        server: Server = undefined,
        response_content_length: ?u64 = null,
        received_content: ?[]const u8 = null,
        test_error: ?anyerror = null,
        req_count: usize = 0,

        fn connectCallback(
            self: *Context,
            result: IO.ConnectError!void,
        ) void {
            std.log.debug("Context.connectCallback start, result={}", .{result});
            if (result) |_| {
                var w = self.buffer.writer();
                std.fmt.format(w, "{s} {s} {s}\r\n", .{
                    (http.Method{ .get = undefined }).toBytes(),
                    "/",
                    http.Version.http1_1.toBytes(),
                }) catch unreachable;
                std.fmt.format(w, "Host: example.com\r\n\r\n", .{}) catch unreachable;
                self.client.sendFull(self.buffer.readableSlice(0), sendFullCallback);
            } else |err| {
                std.log.err("Connect.connectCallback err={s}", .{@errorName(err)});
                self.exitTestWithError(err);
            }
        }
        fn sendFullCallback(
            self: *Context,
            result: IO.SendError!usize,
        ) void {
            std.log.debug("Context.sendFullCallback start, result={}", .{result});
            if (result) |_| {
                self.client.recvResponseHeader(recvResponseHeaderCallback);
            } else |err| {
                std.log.err("Connect.sendFullCallback err={s}", .{@errorName(err)});
                self.exitTestWithError(err);
            }
        }
        fn recvResponseHeaderCallback(
            self: *Context,
            result: Client.RecvResponseHeaderError!usize,
        ) void {
            std.log.debug("Context.recvResponseHeaderCallback start, result={}", .{result});
            if (result) |_| {
                self.response_content_length = self.client.response_content_length;
                self.received_content = self.client.response_content_fragment_buf;
                if (!self.client.fullyReadResponseContent()) {
                    self.client.recvResponseContentFragment(recvResponseContentFragmentCallback);
                    return;
                }

                std.log.debug("Context.recvResponseHeaderCallback before calling self.client.close", .{});
                self.client.close();
                self.req_count += 1;
                if (self.req_count == 1) {
                    if (self.client.connect(self.server.bound_address, connectCallback)) |_| {} else |err| {
                        std.log.err("recvResponseContentFragmentCallback connect err={s}", .{@errorName(err)});
                    }
                } else {
                    self.exitTest();
                }
            } else |err| {
                std.log.err("recvResponseHeaderCallback err={s}", .{@errorName(err)});
                self.exitTestWithError(err);
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

                std.log.debug("Context.recvResponseContentFragmentCallback before calling self.client.close", .{});
                self.client.close();
                self.req_count += 1;
                if (self.req_count == 1) {
                    if (self.client.connect(self.server.bound_address, connectCallback)) |_| {} else |err| {
                        std.log.err("recvResponseContentFragmentCallback connect err={s}", .{@errorName(err)});
                    }
                } else {
                    self.exitTest();
                }
            } else |err| {
                std.log.err("recvResponseContentFragmentCallback err={s}", .{@errorName(err)});
                self.exitTestWithError(err);
            }
        }

        fn exitTest(self: *Context) void {
            self.server.requestShutdown();
        }

        fn exitTestWithError(self: *Context, test_error: anyerror) void {
            self.test_error = test_error;
            self.server.requestShutdown();
        }

        fn runTest() !void {
            var io = try IO.init(32, 0);
            defer io.deinit();

            const allocator = testing.allocator;
            // Use a random port
            const address = try std.net.Address.parseIp4("127.0.0.1", 0);

            var self: Context = .{
                .buffer = std.fifo.LinearFifo(u8, .Dynamic).init(allocator),
            };
            defer self.buffer.deinit();

            self.server = try Server.init(allocator, &io, &self, address, .{});
            defer self.server.deinit();

            self.client = try Client.init(allocator, &io, &self, &.{});
            defer self.client.deinit();

            try self.server.start();
            try self.client.connect(self.server.bound_address, connectCallback);

            while (!self.client.done or !self.server.done) {
                try io.tick();
            }

            if (self.test_error) |err| {
                return err;
            }
            try testing.expectEqual(content.len, self.response_content_length.?);
            try testing.expectEqualStrings(content, self.received_content.?);
            try testing.expectEqual(@as(usize, 2), self.req_count);
        }
    }.runTest();
}
