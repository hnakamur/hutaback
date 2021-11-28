const std = @import("std");
const os = std.os;
const time = std.time;

const datetime = @import("datetime");
const http = @import("http");
const IO = @import("tigerbeetle-io").IO;

const testing = std.testing;

test "real / success / simple get" {
    const content = "Hello from http.Server\n";

    const Handler = struct {
        const Self = @This();
        pub const Server = http.Server(Self);

        conn: *Server.Conn = undefined,

        pub fn start(self: *Self) void {
            std.debug.print("Handler.start\n", .{});
            self.conn.recvRequestHeader(recvRequestHeaderCallback);
        }

        pub fn recvRequestHeaderCallback(self: *Self, result: Server.RecvRequestHeaderError!usize) void {
            std.debug.print("Handler.recvRequestHeaderCallback start, result={}\n", .{result});
            if (result) |_| {
                if (!self.conn.fullyReadRequestContent()) {
                    self.conn.recvRequestContentFragment(recvRequestContentFragmentCallback);
                    return;
                }

                self.sendResponse();
            } else |err| {
                std.debug.print("Handler.recvRequestHeaderCallback err={s}\n", .{@errorName(err)});
            }
        }

        pub fn recvRequestContentFragmentCallback(self: *Self, result: Server.RecvRequestContentFragmentError!usize) void {
            std.debug.print("Handler.recvRequestContentFragmentCallback start, result={}\n", .{result});
            if (result) |_| {
                if (!self.conn.fullyReadRequestContent()) {
                    self.conn.recvRequestContentFragment(recvRequestContentFragmentCallback);
                    return;
                }

                self.sendResponse();
            } else |err| {
                std.debug.print("Handler.recvRequestContentFragmentCallback err={s}\n", .{@errorName(err)});
            }
        }

        pub fn sendResponse(self: *Self) void {
            std.debug.print("Handler.sendResponse start\n", .{});
            var fbs = std.io.fixedBufferStream(self.conn.send_buf);
            var w = fbs.writer();
            std.fmt.format(w, "{s} {d} {s}\r\n", .{
                http.Version.http1_1.toText(),
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
            self.conn.sendFull(fbs.getWritten(), sendFullCallback);
        }

        fn sendFullCallback(self: *Self, last_result: IO.SendError!usize) void {
            std.debug.print("Handler.sendFullCallback start, last_result={}\n", .{last_result});
            if (last_result) |_| {
                self.conn.finishSend();
            } else |err| {
                std.debug.print("Handler.sendFullCallback err={s}\n", .{@errorName(err)});
            }
        }
    };

    try struct {
        const Context = @This();
        const Client = http.Client(Context);

        client: Client = undefined,
        buffer: std.fifo.LinearFifo(u8, .Dynamic),
        content_read_so_far: u64 = undefined,
        server: Handler.Server = undefined,
        response_content_length: ?u64 = null,
        received_content: ?[]const u8 = null,
        test_error: ?anyerror = null,

        fn connectCallback(
            self: *Context,
            result: IO.ConnectError!void,
        ) void {
            std.debug.print("Context.connectCallback start, result={}\n", .{result});
            if (result) |_| {
                var w = self.buffer.writer();
                std.fmt.format(w, "{s} {s} {s}\r\n", .{
                    (http.Method{ .get = undefined }).toText(),
                    "/",
                    // "/" ++ "a" ** 8192,
                    http.Version.http1_1.toText(),
                }) catch unreachable;
                std.fmt.format(w, "Host: example.com\r\n\r\n", .{}) catch unreachable;
                self.client.sendFull(self.buffer.readableSlice(0), sendFullCallback);
            } else |err| {
                std.debug.print("Connect.connectCallback err={s}\n", .{@errorName(err)});
                self.exitTestWithError(err);
            }
        }
        fn sendFullCallback(
            self: *Context,
            result: IO.SendError!usize,
        ) void {
            std.debug.print("Context.sendFullCallback start, result={}\n", .{result});
            if (result) |_| {
                self.client.recvResponseHeader(recvResponseHeaderCallback);
            } else |err| {
                std.debug.print("Connect.sendFullCallback err={s}\n", .{@errorName(err)});
                self.exitTestWithError(err);
            }
        }
        fn recvResponseHeaderCallback(
            self: *Context,
            result: Client.RecvResponseHeaderError!usize,
        ) void {
            std.debug.print("Context.recvResponseHeaderCallback start, result={}\n", .{result});
            if (result) |_| {
                self.response_content_length = self.client.response_content_length;
                self.received_content = self.client.response_content_fragment_buf;
                if (!self.client.fullyReadResponseContent()) {
                    self.client.recvResponseContentFragment(recvResponseContentFragmentCallback);
                    return;
                }

                std.debug.print("Context.recvResponseHeaderCallback before calling self.client.close\n", .{});
                self.client.close();
                self.exitTest();
            } else |err| {
                std.debug.print("recvResponseHeaderCallback err={s}\n", .{@errorName(err)});
                self.exitTestWithError(err);
            }
        }
        fn recvResponseContentFragmentCallback(
            self: *Context,
            result: Client.RecvResponseBodyFragmentError!usize,
        ) void {
            std.debug.print("Context.recvResponseContentFragmentCallback start, result={}\n", .{result});
            if (result) |_| {
                if (!self.client.fullyReadResponseContent()) {
                    self.client.recvResponseContentFragment(recvResponseContentFragmentCallback);
                    return;
                }

                std.debug.print("Context.recvResponseContentFragmentCallback before calling self.client.close\n", .{});
                self.client.close();
                self.exitTest();
            } else |err| {
                std.debug.print("recvResponseContentFragmentCallback err={s}\n", .{@errorName(err)});
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
                .server = try Handler.Server.init(allocator, &io, address, .{}),
            };
            defer self.buffer.deinit();
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
        }
    }.runTest();
}
