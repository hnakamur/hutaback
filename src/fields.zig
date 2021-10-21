const std = @import("std");
const testing = std.testing;

const crlf = "\r\n";
const crlf_crlf = "\r\n\r\n";

pub const Field = struct {
    line: []const u8,
    colonPos: usize,

    pub fn name(self: *const Field) []const u8 {
        return self.line[0..self.colonPos];
    }

    pub fn value(self: *const Field) []const u8 {
        return std.mem.trim(u8, self.line[self.colonPos + 1 ..], " \t");
    }
};

pub const FieldIterator = struct {
    buf: []const u8,

    pub fn init(buf: []const u8) !FieldIterator {
        return if (std.mem.indexOf(u8, buf, crlf_crlf)) |_| blk: {
            break :blk .{ .buf = buf };
        } else error.InvalidInput;
    }

    pub fn next(self: *FieldIterator) !?Field {
        if (std.mem.startsWith(u8, self.buf, crlf)) {
            self.buf = self.buf[crlf.len..];
            return null;
        }

        if (std.mem.indexOf(u8, self.buf, ":")) |colonPos| {
            if (std.mem.indexOfPos(u8, self.buf, colonPos, crlf)) |crlfPos| {
                const line = self.buf[0..crlfPos];
                self.buf = self.buf[crlfPos + crlf.len ..];
                return Field{
                    .line = line,
                    .colonPos = colonPos,
                };
            }
        }
        return error.InvalidField;
    }

    pub fn rest(self: *const FieldIterator) []const u8 {
        return self.buf;
    }
};

test "FieldIterator valid fields and body" {
    const input =
        "Date: Mon, 27 Jul 2009 12:28:53 GMT\r\n" ++
        "Server: Apache\r\n" ++
        "Last-Modified: Wed, 22 Jul 2009 19:15:56 GMT\r\n" ++
        "ETag: \"34aa387-d-1568eb00\"\r\n" ++
        "Accept-Ranges: bytes\r\n" ++
        "Content-Length: 51\r\n" ++
        "Vary: Accept-Encoding\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "body";
    var names = [_][]const u8{
        "Date",
        "Server",
        "Last-Modified",
        "ETag",
        "Accept-Ranges",
        "Content-Length",
        "Vary",
        "Content-Type",
    };
    var values = [_][]const u8{
        "Mon, 27 Jul 2009 12:28:53 GMT",
        "Apache",
        "Wed, 22 Jul 2009 19:15:56 GMT",
        "\"34aa387-d-1568eb00\"",
        "bytes",
        "51",
        "Accept-Encoding",
        "text/plain",
    };
    var it = try FieldIterator.init(input);
    var i: usize = 0;
    while (try it.next()) |f| {
        try testing.expectEqualStrings(names[i], f.name());
        try testing.expectEqualStrings(values[i], f.value());
        i += 1;
    }
    try testing.expectEqual(names.len, i);
    try testing.expectEqualStrings("body", it.rest());
}

test "FieldIterator invalid input" {
    const input =
        "Date: Mon, 27 Jul 2009 12:28:53 GMT\r\n";
    try testing.expectError(error.InvalidInput, FieldIterator.init(input));
}

test "FieldIterator trim value" {
    const input =
        "Date:  \tMon, 27 Jul 2009 12:28:53 GMT \r\n" ++
        "\r\n";
    var it = try FieldIterator.init(input);
    while (try it.next()) |f| {
        try testing.expectEqualStrings("Mon, 27 Jul 2009 12:28:53 GMT", f.value());
    }
}
