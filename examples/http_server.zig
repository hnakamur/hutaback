const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const time = std.time;
const IO = @import("tigerbeetle-io").IO;
const http = @import("hutaback");
const datetime = @import("datetime");
const config = http.config;

const Server = struct {
    io: IO,
    server: os.socket_t,
    allocator: mem.Allocator,
    client_handlers: std.ArrayList(?*ClientHandler),
    shutdown_requested: bool = false,
    done: bool = false,

    fn init(allocator: mem.Allocator, address: std.net.Address) !Server {
        const kernel_backlog = 513;
        const server = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);

        try os.setsockopt(
            server,
            os.SOL.SOCKET,
            os.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        try os.bind(server, &address.any, address.getOsSockLen());
        if (address.getPort() == 0) {
            var bound_addr: std.net.Address = address;
            var bound_socklen: os.socklen_t = address.getOsSockLen();
            try os.getsockname(server, &bound_addr.any, &bound_socklen);
            std.debug.print("bound port={d}\n", .{bound_addr.getPort()});
        }

        try os.listen(server, kernel_backlog);

        var self: Server = .{
            .io = try IO.init(256, 0),
            .server = server,
            .allocator = allocator,
            .client_handlers = std.ArrayList(?*ClientHandler).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Server) void {
        os.close(self.server);
        self.client_handlers.deinit();
        self.io.deinit();
    }

    pub fn run(self: *Server) !void {
        var server_completion: IO.Completion = undefined;
        self.io.accept(*Server, self, acceptCallback, &server_completion, self.server, 0);
        while (!self.done) {
            try self.io.run_for_ns(time.ns_per_s);
        }
    }

    fn acceptCallback(
        self: *Server,
        completion: *IO.Completion,
        result: IO.AcceptError!os.socket_t,
    ) void {
        // std.debug.print("acceptCallback\n", .{});
        const accepted_sock = result catch @panic("accept error");
        var handler = self.createClientHandler(accepted_sock) catch @panic("handler create error");
        handler.start() catch @panic("handler");
        self.io.accept(*Server, self, acceptCallback, completion, self.server, 0);
    }

    fn createClientHandler(self: *Server, accepted_sock: os.socket_t) !*ClientHandler {
        const handler_id = if (self.findEmptyClientHandlerId()) |id| id else self.client_handlers.items.len;
        // std.debug.print("client_handler_id={d}\n", .{handler_id});
        const handler = try ClientHandler.init(self, handler_id, self.allocator, &self.io, accepted_sock);
        if (handler_id < self.client_handlers.items.len) {
            self.client_handlers.items[handler_id] = handler;
        } else {
            try self.client_handlers.append(handler);
        }
        return handler;
    }

    fn findEmptyClientHandlerId(self: *Server) ?usize {
        for (self.client_handlers.items) |h, i| {
            // std.debug.print("findEmptyClientHandlerId, i={d}\n", .{i});
            if (h) |_| {
                // std.debug.print("handler is running, i={d}\n", .{i});
            } else {
                return i;
            }
        }
        return null;
    }

    fn removeClientHandlerId(self: *Server, handler_id: usize) void {
        self.client_handlers.items[handler_id] = null;
        if (self.shutdown_requested) {
            self.setDoneIfNoClient();
        }
    }

    pub fn requestShutdown(self: *Server) void {
        self.shutdown_requested = true;
        std.debug.print("set Server.shutdown_requested to true\n", .{});
        for (self.client_handlers.items) |handler, i| {
            if (handler) |h| {
                if (!h.processing) {
                    h.close();
                    std.debug.print("closed client_handler id={d}\n", .{i});
                }
            }
        }
        self.setDoneIfNoClient();
    }

    fn setDoneIfNoClient(self: *Server) void {
        for (self.client_handlers.items) |h| {
            if (h) |_| {
                return;
            }
        }

        self.done = true;
    }
};

const ClientHandler = struct {
    server: *Server,
    handler_id: usize,
    io: *IO,
    linked_completion: IO.LinkedCompletion = undefined,
    sock: os.socket_t,
    recv_buf: []u8,
    send_buf: []u8,
    allocator: mem.Allocator,
    recv_timeout_ns: u63 = 5 * time.ns_per_s,
    send_timeout_ns: u63 = 5 * time.ns_per_s,
    request_scanner: *http.RecvRequestScanner,
    request_version: http.Version = undefined,
    keep_alive: bool = true,
    req_content_length: ?u64 = null,
    content_length_read_so_far: u64 = 0,
    processing: bool = false,
    resp_headers_len: u64 = 0,
    content_length: u64 = 0,
    content_len_sent_so_far: u64 = 0,
    sent_bytes_so_far: u64 = 0,
    send_buf_data_len: u64 = 0,
    send_buf_sent_len: u64 = 0,
    state: enum {
        ReceivingHeaders,
        ReceivingContent,
        SendingHeaders,
        SendingContent,
    } = .ReceivingHeaders,

    fn init(server: *Server, handler_id: usize, allocator: mem.Allocator, io: *IO, sock: os.socket_t) !*ClientHandler {
        const req_scanner = try allocator.create(http.RecvRequestScanner);
        req_scanner.* = http.RecvRequestScanner{};
        const recv_buf = try allocator.alloc(u8, config.recv_buf_ini_len);
        const send_buf = try allocator.alloc(u8, 1024);
        var self = try allocator.create(ClientHandler);
        self.* = ClientHandler{
            .server = server,
            .handler_id = handler_id,
            .io = io,
            .sock = sock,
            .request_scanner = req_scanner,
            .recv_buf = recv_buf,
            .send_buf = send_buf,
            .allocator = allocator,
        };
        return self;
    }

    fn deinit(self: *ClientHandler) !void {
        self.server.removeClientHandlerId(self.handler_id);
        self.allocator.destroy(self.request_scanner);
        self.allocator.free(self.send_buf);
        self.allocator.free(self.recv_buf);
        self.allocator.destroy(self);
    }

    fn close(self: *ClientHandler) void {
        os.closeSocket(self.sock);
        if (self.deinit()) |_| {} else |err| {
            std.debug.print("ClientHandler deinit err={s}\n", .{@errorName(err)});
        }
        // std.debug.print("close and exit\n", .{});
    }

    fn start(self: *ClientHandler) !void {
        self.recvWithTimeout(self.recv_buf);
    }

    fn recvWithTimeout(
        self: *ClientHandler,
        buf: []u8,
    ) void {
        // std.debug.print("recvWithTimeout handler_id={d}\n", .{self.handler_id});
        self.io.recvWithTimeout(
            *ClientHandler,
            self,
            recvCallback,
            &self.linked_completion,
            self.sock,
            buf,
            0,
            self.recv_timeout_ns,
        );
    }
    fn recvCallback(
        self: *ClientHandler,
        completion: *IO.LinkedCompletion,
        result: IO.RecvError!usize,
    ) void {
        _ = completion;
        if (result) |received| {
            // std.debug.print("received={d}\n", .{received});

            if (received == 0) {
                if (self.request_scanner.totalBytesRead() > 0) {
                    // std.debug.print("closed from client during request, close connection.\n", .{});
                }
                self.close();
                return;
            }

            self.handleStreamingRequest(received);
        } else |err| {
            std.debug.print("recv error: {s}\n", .{@errorName(err)});
        }
    }

    fn handleStreamingRequest(self: *ClientHandler, received: usize) void {
        switch (self.state) {
            .ReceivingHeaders => {
                self.processing = true;
                const old = self.request_scanner.totalBytesRead();
                // std.debug.print("handleStreamingRequest old={}, received={}\n", .{ old, received });
                // std.debug.print("handleStreamingRequest scan data={s}\n", .{self.recv_buf[old .. old + received]});
                if (self.request_scanner.scan(self.recv_buf[old .. old + received])) |done| {
                    if (done) {
                        self.state = .ReceivingContent;
                        const total = self.request_scanner.totalBytesRead();
                        if (http.RecvRequest.init(self.recv_buf[0..total], self.request_scanner)) |req| {
                            // std.debug.print("request method={s}, version={s}, url={s}, headers=\n{s}\n", .{
                            //     req.method.toText(),
                            //     req.version.toText(),
                            //     req.uri,
                            //     req.headers.fields,
                            // });
                            if (req.isKeepAlive()) |keep_alive| {
                                self.keep_alive = keep_alive;
                            } else |_| {
                                self.sendError(.http_version_not_supported);
                                return;
                            }
                            self.request_version = req.version;
                            self.req_content_length = if (req.headers.getContentLength()) |len| len else |_| {
                                // std.debug.print("bad request, invalid content-length, err={s}\n", .{@errorName(err)});
                                self.sendError(.bad_request);
                                return;
                            };
                            if (self.req_content_length) |len| {
                                // std.debug.print("content_length={}\n", .{len});
                                const actual_content_chunk_len = old + received - total;
                                self.content_length_read_so_far += actual_content_chunk_len;
                                // std.debug.print("first content chunk length={},\ncontent=\n{s}", .{
                                //     actual_content_chunk_len,
                                //     self.recv_buf[total .. old + received],
                                // });
                                if (actual_content_chunk_len < len) {
                                    self.io.recvWithTimeout(
                                        *ClientHandler,
                                        self,
                                        recvCallback,
                                        &self.linked_completion,
                                        self.sock,
                                        self.recv_buf,
                                        0,
                                        self.recv_timeout_ns,
                                    );
                                    return;
                                }
                            }
                        } else |_| {
                            self.sendError(.bad_request);
                            return;
                        }
                        self.sendResponseWithTimeout();
                    } else {
                        // std.debug.print("handleStreamingRequest not done\n", .{});
                        if (old + received == self.recv_buf.len) {
                            const new_len = self.recv_buf.len + config.recv_buf_ini_len;
                            if (config.recv_buf_max_len < new_len) {
                                std.debug.print("request header fields too long.\n", .{});
                                self.sendError(.bad_request);
                                return;
                            }
                            self.recv_buf = self.allocator.realloc(self.recv_buf, new_len) catch unreachable;
                        }
                        self.io.recvWithTimeout(
                            *ClientHandler,
                            self,
                            recvCallback,
                            &self.linked_completion,
                            self.sock,
                            self.recv_buf[old + received ..],
                            0,
                            self.recv_timeout_ns,
                        );
                    }
                } else |err| {
                    std.debug.print("handleStreamingRequest scan failed with {s}\n", .{@errorName(err)});
                    self.sendError(switch (err) {
                        error.UriTooLong => .uri_too_long,
                        error.VersionNotSupported => .http_version_not_supported,
                        else => .bad_request,
                    });
                }
            },
            .ReceivingContent => {
                // std.debug.print("{s}", .{self.recv_buf[0..received]});
                self.content_length_read_so_far += received;
                if (self.content_length_read_so_far < self.req_content_length.?) {
                    self.io.recvWithTimeout(
                        *ClientHandler,
                        self,
                        recvCallback,
                        &self.linked_completion,
                        self.sock,
                        self.recv_buf,
                        0,
                        self.recv_timeout_ns,
                    );
                    return;
                }
                self.sendResponseWithTimeout();
            },
            else => @panic("unexpected state in recvCallback"),
        }
    }

    fn sendError(self: *ClientHandler, status_code: http.StatusCode) void {
        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "{s} {d} {s}\r\n", .{
            http.Version.http1_1.toBytes(),
            status_code.code(),
            status_code.toText(),
        }) catch unreachable;
        http.writeDatetimeHeader(w, "Date", datetime.datetime.Datetime.now()) catch unreachable;

        self.keep_alive = false;
        std.fmt.format(w, "Connection: {s}\r\n", .{"close"}) catch unreachable;
        std.fmt.format(w, "Content-Length: 0\r\n", .{}) catch unreachable;
        std.fmt.format(w, "\r\n", .{}) catch unreachable;
        self.io.sendWithTimeout(
            *ClientHandler,
            self,
            sendCallback,
            &self.linked_completion,
            self.sock,
            fbs.getWritten(),
            0,
            self.send_timeout_ns,
        );
    }

    fn sendResponseWithTimeout(self: *ClientHandler) void {
        var fbs = std.io.fixedBufferStream(self.send_buf);
        var w = fbs.writer();
        std.fmt.format(w, "{s} {d} {s}\r\n", .{
            http.Version.http1_1.toBytes(),
            http.StatusCode.ok.code(),
            http.StatusCode.ok.toText(),
        }) catch unreachable;
        http.writeDatetimeHeader(w, "Date", datetime.datetime.Datetime.now()) catch unreachable;

        switch (self.request_version) {
            .http1_1 => if (!self.keep_alive) {
                std.fmt.format(w, "Connection: {s}\r\n", .{"close"}) catch unreachable;
                // std.debug.print("wrote connection: close for HTTP/1.1\n", .{});
            } else {
                std.fmt.format(w, "Connection: {s}\r\n", .{"keep-alive"}) catch unreachable;
            },
            .http1_0 => if (self.keep_alive) {
                // std.debug.print("wrote connection: keep-alive for HTTP/1.0\n", .{});
                std.fmt.format(w, "Connection: {s}\r\n", .{"keep-alive"}) catch unreachable;
            },
            else => {},
        }
        self.content_length = 17;
        std.fmt.format(w, "Content-Type: {s}\r\n", .{"text/plain; charset=utf-8"}) catch unreachable;
        std.fmt.format(w, "Content-Length: {d}\r\n", .{self.content_length}) catch unreachable;
        std.fmt.format(w, "\r\n", .{}) catch unreachable;
        var pos = fbs.getPos() catch unreachable;
        self.resp_headers_len = pos;
        self.send_buf_data_len = std.math.min(
            pos + self.content_length,
            self.send_buf.len,
        );
        while (pos < self.send_buf_data_len) : (pos += 1) {
            self.send_buf[pos] = 'e';
        }
        self.send_buf_sent_len = 0;
        // self.state = .SendingHeaders;
        self.state = .SendingContent;
        self.io.sendWithTimeout(
            *ClientHandler,
            self,
            sendCallback,
            &self.linked_completion,
            self.sock,
            self.send_buf[0..self.send_buf_data_len],
            0,
            self.send_timeout_ns,
        );
    }
    fn sendCallback(
        self: *ClientHandler,
        completion: *IO.LinkedCompletion,
        result: IO.SendError!usize,
    ) void {
        _ = completion;
        if (result) |sent| {
            // std.debug.print("sent response bytes={d}\n", .{sent});
            self.send_buf_sent_len += sent;
            self.sent_bytes_so_far += sent;
            if (self.send_buf_sent_len < self.send_buf_data_len) {
                self.io.sendWithTimeout(
                    *ClientHandler,
                    self,
                    sendCallback,
                    &self.linked_completion,
                    self.sock,
                    self.send_buf[self.send_buf_sent_len..self.send_buf_data_len],
                    0,
                    self.send_timeout_ns,
                );
                return;
            }

            switch (self.state) {
                .SendingHeaders => {
                    self.state = .SendingContent;
                    self.send_buf_data_len = std.math.min(
                        self.content_length - (self.sent_bytes_so_far - self.resp_headers_len),
                        self.send_buf.len,
                    );
                    self.send_buf_sent_len = 0;
                    var pos: usize = 0;
                    while (pos < self.send_buf_data_len) : (pos += 1) {
                        self.send_buf[pos] = 'f';
                    }
                    self.io.sendWithTimeout(
                        *ClientHandler,
                        self,
                        sendCallback,
                        &self.linked_completion,
                        self.sock,
                        self.send_buf[0..self.send_buf_data_len],
                        0,
                        self.send_timeout_ns,
                    );
                    return;
                },
                .SendingContent => {
                    self.send_buf_data_len = std.math.min(
                        self.content_length - (self.sent_bytes_so_far - self.resp_headers_len),
                        self.send_buf.len,
                    );
                    if (self.send_buf_data_len > 0) {
                        self.send_buf_sent_len = 0;
                        var pos: usize = 0;
                        while (pos < self.send_buf_data_len) : (pos += 1) {
                            self.send_buf[pos] = 'g';
                        }
                        self.io.sendWithTimeout(
                            *ClientHandler,
                            self,
                            sendCallback,
                            &self.linked_completion,
                            self.sock,
                            self.send_buf[0..self.send_buf_data_len],
                            0,
                            self.send_timeout_ns,
                        );
                        return;
                    }
                },
                else => @panic("unexpected state in sendCallback"),
            }

            if (!self.keep_alive or self.server.shutdown_requested) {
                self.close();
                return;
            }

            self.processing = false;
            self.request_scanner.* = http.RecvRequestScanner{};
            self.recvWithTimeout(self.recv_buf);
        } else |err| {
            std.debug.print("send error: {s}\n", .{@errorName(err)});
            self.close();
        }
    }
};

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

var global_server: Server = undefined;

fn sigchld(signo: i32) callconv(.C) void {
    std.debug.print("got signal, signo={d}\n", .{signo});
    global_server.requestShutdown();
}

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    const port_max = 65535;
    const port_default = 3131;
    const port = getEnvUint(u16, "PORT", port_default, port_max);
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    global_server = try Server.init(allocator, address);
    try os.sigaction(os.SIG.INT, &.{
        .handler = .{ .handler = sigchld },
        .mask = os.system.empty_sigset,
        .flags = os.system.SA.NOCLDSTOP,
    }, null);
    defer global_server.deinit();
    try global_server.run();
}
