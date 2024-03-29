const std = @import("std");
const mem = std.mem;
const Method = @import("method.zig").Method;
const Version = @import("version.zig").Version;
const isTokenChar = @import("parser.zig").lex.isTokenChar;
const FieldsScanner = @import("fields_scanner.zig").FieldsScanner;
const Fields = @import("fields.zig").Fields;
const config = @import("config.zig");

const http_log = std.log.scoped(.http);

/// A receiving request.
pub const RecvRequest = struct {
    pub const Error = error{
        BadRequest,
        UriTooLong,
    };

    buf: []const u8,
    method: Method,
    uri: []const u8,
    version: Version,
    headers: Fields,

    /// Caller owns `buf`. Returned request is valid for use only while `buf` is valid.
    pub fn init(buf: []const u8, scanner: *const RecvRequestScanner) Error!RecvRequest {
        std.debug.assert(scanner.headers.state == .done);
        const result = scanner.request_line.result;
        const method_len = result.method_len;
        const request_line_len = result.total_bytes_read;
        const headers_len = scanner.headers.total_bytes_read;

        const method = Method.fromBytes(buf[0..method_len]) catch unreachable;
        const uri = buf[result.uri_start_pos .. result.uri_start_pos + result.uri_len];
        const ver_buf = buf[result.version_start_pos .. result.version_start_pos + result.version_len];
        const version = Version.fromBytes(ver_buf) catch return error.BadRequest;
        const headers = Fields.init(buf[request_line_len .. request_line_len + headers_len]);

        return RecvRequest{
            .buf = buf,
            .method = method,
            .uri = uri,
            .version = version,
            .headers = headers,
        };
    }

    pub fn isKeepAlive(self: *const RecvRequest) !bool {
        return switch (self.version) {
            .http1_1 => !self.headers.hasConnectionToken("close"),
            .http1_0 => self.headers.hasConnectionToken("keep-alive"),
            else => error.HttpVersionNotSupported,
        };
    }
};

pub const RecvRequestScanner = struct {
    pub const Error = RequestLineScanner.Error || FieldsScanner.Error;

    request_line: RequestLineScanner = RequestLineScanner{},
    headers: FieldsScanner = FieldsScanner{},

    pub fn scan(self: *RecvRequestScanner, chunk: []const u8) Error!bool {
        if (self.request_line.state != .done) {
            const old = self.request_line.result.total_bytes_read;
            if (!try self.request_line.scan(chunk)) {
                http_log.debug("RecvRequestScanner.scan status line not complete", .{});
                return false;
            }
            const read = self.request_line.result.total_bytes_read - old;
            return self.headers.scan(chunk[read..]) catch |err| blk: {
                http_log.debug("RecvRequestScanner.scan err#1={s}", .{@errorName(err)});
                break :blk error.BadRequest;
            };
        }
        return self.headers.scan(chunk) catch |err| blk: {
            http_log.debug("RecvRequestScanner.scan err#2={s}", .{@errorName(err)});
            break :blk error.BadRequest;
        };
    }

    pub fn totalBytesRead(self: *const RecvRequestScanner) usize {
        return self.request_line.result.total_bytes_read +
            self.headers.total_bytes_read;
    }
};

const RequestLineScanner = struct {
    const Error = error{
        BadRequest,
        UriTooLong,
        VersionNotSupported,
    };

    const State = enum {
        on_method,
        post_method,
        on_uri,
        post_uri,
        on_version,
        seen_cr,
        done,
    };

    const Result = struct {
        total_bytes_read: usize = 0,
        method_len: usize = 0,
        uri_start_pos: usize = 0,
        uri_len: usize = 0,
        version_start_pos: usize = 0,
        version_len: usize = 0,
    };

    const version_max_len: usize = Version.http1_1.toBytes().len;

    method_max_len: usize = 32,
    uri_max_len: usize = 8192,
    state: State = .on_method,
    result: Result = Result{},

    pub fn scan(self: *RequestLineScanner, chunk: []const u8) Error!bool {
        var pos: usize = 0;
        while (pos < chunk.len) : (pos += 1) {
            const c = chunk[pos];
            self.result.total_bytes_read += 1;
            switch (self.state) {
                .on_method => {
                    if (c == ' ') {
                        self.state = .post_method;
                    } else {
                        self.result.method_len += 1;
                        if (!isTokenChar(c) or self.result.method_len > self.method_max_len) {
                            http_log.debug("RequestLineScanner.scan err#1", .{});
                            return error.BadRequest;
                        }
                    }
                },
                .post_method => {
                    if (c != ' ') {
                        self.result.uri_start_pos = self.result.total_bytes_read - 1;
                        self.result.uri_len += 1;
                        self.state = .on_uri;
                    } else {
                        http_log.debug("RequestLineScanner.scan err#2", .{});
                        return error.BadRequest;
                    }
                },
                .on_uri => {
                    if (c == ' ') {
                        self.state = .post_uri;
                    } else if (c == '\r') {
                        // HTTP/0.9 is not supported.
                        // https://www.ietf.org/rfc/rfc1945.txt
                        // Simple-Request  = "GET" SP Request-URI CRLF
                        http_log.debug("RequestLineScanner.scan err#3", .{});
                        return error.VersionNotSupported;
                    } else {
                        self.result.uri_len += 1;
                        if (self.result.uri_len > self.uri_max_len) {
                            http_log.debug("RequestLineScanner.scan err#4", .{});
                            return error.UriTooLong;
                        }
                    }
                },
                .post_uri => {
                    if (c != ' ') {
                        self.result.version_start_pos = self.result.total_bytes_read - 1;
                        self.result.version_len += 1;
                        self.state = .on_version;
                    } else {
                        http_log.debug("RequestLineScanner.scan err#5", .{});
                        return error.BadRequest;
                    }
                },
                .on_version => {
                    if (c == '\r') {
                        self.state = .seen_cr;
                    } else {
                        self.result.version_len += 1;
                        if (self.result.version_len > version_max_len) {
                            http_log.debug("RequestLineScanner.scan err#6", .{});
                            return error.BadRequest;
                        }
                    }
                },
                .seen_cr => {
                    if (c == '\n') {
                        self.state = .done;
                        return true;
                    }
                    http_log.debug("RequestLineScanner.scan err#7", .{});
                    return error.BadRequest;
                },
                .done => {
                    // NOTE: panic would be more appropriate since calling scan after complete
                    // is a programming bug. But I don't know how to catch panic in test, so
                    // use return for now.
                    // See https://github.com/ziglang/zig/issues/1356
                    // @panic("StatusLineScanner.scan called again after scan is complete");
                    http_log.debug("RequestLineScanner.scan err#8", .{});
                    return error.BadRequest;
                },
            }
        }
        return false;
    }
};

const testing = std.testing;

test "RecvRequest.init - GET method" {
    const method = "GET";
    const uri = "/where?q=now";
    const version = "HTTP/1.1";
    const headers = "Host: www.example.com\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n" ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(try scanner.scan(input));

    var req = try RecvRequest.init(input, &scanner);
    try testing.expectEqual(Method{ .get = undefined }, req.method);
    try testing.expectEqualStrings(uri, req.uri);
    try testing.expectEqual(try Version.fromBytes(version), req.version);
    try testing.expectEqualStrings(headers, req.headers.fields);
}

test "RecvRequest.init - custom method" {
    const method = "PURGE_ALL";
    const uri = "/where?q=now";
    const version = "HTTP/1.1";
    const headers = "Host: www.example.com\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n" ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(try scanner.scan(input));

    var req = try RecvRequest.init(input, &scanner);
    try testing.expectEqualStrings("custom", @tagName(req.method));
    try testing.expectEqualStrings(method, req.method.custom);
    try testing.expectEqualStrings(uri, req.uri);
    try testing.expectEqual(try Version.fromBytes(version), req.version);
    try testing.expectEqualStrings(headers, req.headers.fields);
}

test "RecvRequest.isKeepAlive - HTTP/1.1" {
    const method = "GET";
    const uri = "/";
    const version = "HTTP/1.1";
    const headers = "Host: www.example.com\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n" ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(try scanner.scan(input));

    var req = try RecvRequest.init(input, &scanner);
    try testing.expect(try req.isKeepAlive());
}

test "RecvRequest.isKeepAlive - HTTP/1.0" {
    const method = "GET";
    const uri = "/";
    const version = "HTTP/1.0";
    const headers = "Host: www.example.com\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n" ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(try scanner.scan(input));

    var req = try RecvRequest.init(input, &scanner);
    try testing.expect(!try req.isKeepAlive());
}

test "RecvRequest.isKeepAlive - HTTP/2" {
    const method = "GET";
    const uri = "/";
    const version = "HTTP/2";
    const headers = "Host: www.example.com\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n" ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(try scanner.scan(input));

    var req = try RecvRequest.init(input, &scanner);
    try testing.expectError(error.HttpVersionNotSupported, req.isKeepAlive());
}

test "RecvRequestScanner - GET method" {
    const method = "GET";
    const uri = "/where?q=now";
    const version = "HTTP/1.1";
    const headers = "Host: www.example.com\r\n" ++
        "Accept: */*\r\n" ++
        "\r\n";
    const request_line = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";
    const input = request_line ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(try scanner.scan(input));
    const result = scanner.request_line.result;
    try testing.expectEqual(method.len, result.method_len);
    try testing.expectEqual(method.len + 1, result.uri_start_pos);
    try testing.expectEqual(uri.len, result.uri_len);
    try testing.expectEqual(method.len + 1 + uri.len + 1, result.version_start_pos);
    try testing.expectEqual(version.len, result.version_len);
    try testing.expectEqual(request_line.len, result.total_bytes_read);
    try testing.expectEqual(headers.len, scanner.headers.total_bytes_read);
}

test "RecvRequestScanner - bad header with request line" {
    // testing.log_level = .debug;
    const method = "GET";
    const uri = "/";
    const version = "HTTP/1.1";
    const headers = "Host : www.example.com\r\n" ++
        "\r\n";
    const request_line = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";
    const input = request_line ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expectError(error.BadRequest, scanner.scan(input));
}

test "RecvRequestScanner - bad header after request line" {
    // testing.log_level = .debug;
    const method = "GET";
    const uri = "/";
    const version = "HTTP/1.1";
    const headers = "Host : www.example.com\r\n" ++
        "\r\n";
    const request_line = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";
    const input = request_line ++ headers;

    var scanner = RecvRequestScanner{};
    try testing.expect(!try scanner.scan(input[0..request_line.len]));
    try testing.expectError(error.BadRequest, scanner.scan(input[request_line.len..]));
}

test "RequestLineScanner - whole in one buf" {
    const method = "GET";
    const uri = "http://www.example.org/where?q=now";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    var scanner = RequestLineScanner{};
    try testing.expect(try scanner.scan(input));
    const result = scanner.result;
    try testing.expectEqual(method.len, result.method_len);
    try testing.expectEqual(method.len + 1, result.uri_start_pos);
    try testing.expectEqual(uri.len, result.uri_len);
    try testing.expectEqual(method.len + 1 + uri.len + 1, result.version_start_pos);
    try testing.expectEqual(version.len, result.version_len);
    try testing.expectEqual(input.len, result.total_bytes_read);
}

test "RequestLineScanner - one byte at time" {
    const method = "GET";
    const uri = "http://www.example.org/where?q=now";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    var scanner = RequestLineScanner{};
    var i: usize = 0;
    while (i < input.len - 2) : (i += 1) {
        try testing.expect(!try scanner.scan(input[i .. i + 1]));
    }
    try testing.expect(try scanner.scan(input[i..]));
    const result = scanner.result;
    try testing.expectEqual(method.len, result.method_len);
    try testing.expectEqual(method.len + 1, result.uri_start_pos);
    try testing.expectEqual(uri.len, result.uri_len);
    try testing.expectEqual(method.len + 1 + uri.len + 1, result.version_start_pos);
    try testing.expectEqual(version.len, result.version_len);
    try testing.expectEqual(input.len, result.total_bytes_read);
}

test "RequestLineScanner - variable length chunks" {
    const method = "GET";
    const uri = "http://www.example.org/where?q=now";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    const ends = [_]usize{
        method.len - 1,
        method.len + " ".len + uri.len - 1,
        method.len + " ".len + uri.len + " ".len + version.len - 1,
        input.len,
    };
    var scanner = RequestLineScanner{};

    var start: usize = 0;
    for (ends) |end| {
        try testing.expect((try scanner.scan(input[start..end])) == (end == input.len));
        start = end;
    }
    const result = scanner.result;
    try testing.expectEqual(method.len, result.method_len);
    try testing.expectEqual(method.len + 1, result.uri_start_pos);
    try testing.expectEqual(uri.len, result.uri_len);
    try testing.expectEqual(method.len + 1 + uri.len + 1, result.version_start_pos);
    try testing.expectEqual(version.len, result.version_len);
    try testing.expectEqual(input.len, result.total_bytes_read);
}

test "RequestLineScanner - method too long" {
    const method = "PURGE_ALL";
    const uri = "http://www.example.org/where?q=now";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    const method_max_len_test = 7;
    var scanner = RequestLineScanner{ .method_max_len = method_max_len_test };
    try testing.expectError(error.BadRequest, scanner.scan(input));
    try testing.expectEqual(@as(usize, method_max_len_test + 1), scanner.result.total_bytes_read);
}

test "RequestLineScanner - URI too long" {
    const method = "GET";
    const uri = "http://www.example.org/where?q=now";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    const uri_max_len_test = 12;
    var scanner = RequestLineScanner{ .uri_max_len = uri_max_len_test };
    try testing.expectError(error.UriTooLong, scanner.scan(input));
    const expected_total_len = method.len + " ".len + uri_max_len_test + 1;
    try testing.expectEqual(expected_total_len, scanner.result.total_bytes_read);
}

test "RequestLineScanner - version too long" {
    const method = "GET";
    const uri = "http://www.example.org/where?q=now";
    const version = "HTTP/3.14";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    var scanner = RequestLineScanner{};
    try testing.expectError(error.BadRequest, scanner.scan(input));
    const expected_total_len = method.len + " ".len + uri.len + " ".len + "HTTP/1.1".len + 1;
    try testing.expectEqual(expected_total_len, scanner.result.total_bytes_read);
}

test "RequestLineScanner - HTTP/0.9 not supported" {
    const method = "GET";
    const uri = "/";
    const input = method ++ " " ++ uri ++ "\r\n";

    var scanner = RequestLineScanner{};
    try testing.expectError(error.VersionNotSupported, scanner.scan(input));
}

test "RequestLineScanner - two spaces after method" {
    // testing.log_level = .debug;
    const method = "GET";
    const input = method ++ "  ";

    var scanner = RequestLineScanner{};
    try testing.expectError(error.BadRequest, scanner.scan(input));
}

test "RequestLineScanner - two spaces after uri" {
    // testing.log_level = .debug;
    const method = "GET";
    const uri = "/";
    const input = method ++ " " ++ uri ++ "  ";

    var scanner = RequestLineScanner{};
    try testing.expectError(error.BadRequest, scanner.scan(input));
}

test "RequestLineScanner - not lf after cr" {
    // testing.log_level = .debug;
    const method = "GET";
    const uri = "/";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\r";

    var scanner = RequestLineScanner{};
    try testing.expectError(error.BadRequest, scanner.scan(input));
}

test "RequestLineScanner - called again after scan is complete" {
    // testing.log_level = .debug;
    const method = "GET";
    const uri = "/";
    const version = "HTTP/1.1";
    const input = method ++ " " ++ uri ++ " " ++ version ++ "\r\n";

    var scanner = RequestLineScanner{};
    try testing.expect(try scanner.scan(input));
    try testing.expectError(error.BadRequest, scanner.scan(input));
}
