const std = @import("std");
const mem = std.mem;

// A Block represents a PEM encoded structure.
//
// The encoded form is:
//    -----BEGIN label-----
//    base64-encoded Bytes
//    -----END label-----
//
// https://datatracker.ietf.org/doc/html/rfc7468
pub const Block = struct {
    const begin_boundary_prefix = "-----BEGIN ";
    const boundary_suffix = "-----";
    const end_boundary_prefix = "-----END ";
    const eol_chars = &[_]u8{ '\r', '\n' };
    const wsp_chars = &[_]u8{ '\t', ' ' };
    const eol_wsp_chars = &[_]u8{ '\t', ' ', '\r', '\n' };
    const base64_pad_char = '=';
    const label_line_first_char = '-';

    // The label, taken from the preamble (i.e. "RSA PRIVATE KEY").
    label: []const u8,

    // The decoded bytes of the contents. Typically a DER encoded ASN.1 structure.
    bytes: []const u8,

    pub fn deinit(self: *Block, allocator: mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.bytes);
    }

    pub fn decode(allocator: mem.Allocator, input: []const u8, offset: *usize) !Block {
        const label = try readBeginBoundaryLine(input, offset);
        var encoded_buf = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
        defer encoded_buf.deinit(allocator);
        var seen_pad: bool = false;
        while (offset.* < input.len) {
            const b = input[offset.*];
            if (b == label_line_first_char) {
                try readEndBoundaryLine(input, offset, label);
                const Decoder = std.base64.standard.Decoder;
                const decoded_len = try Decoder.calcSizeForSlice(encoded_buf.items);
                var decoded_buf = try allocator.alloc(u8, decoded_len);
                errdefer allocator.free(decoded_buf);
                try Decoder.decode(decoded_buf, encoded_buf.items);
                return Block{
                    .label = try allocator.dupe(u8, label),
                    .bytes = decoded_buf,
                };
            }

            if (seen_pad) {
                try readPadLine(allocator, &encoded_buf, input, offset);
            } else {
                try readBase64Line(allocator, &encoded_buf, input, offset, &seen_pad);
            }
        }
        return error.UnexpectedEof;
    }

    fn readBeginBoundaryLine(input: []const u8, offset: *usize) ![]const u8 {
        try readExpectedString(input, offset, begin_boundary_prefix);
        const label = try readLabelAndSuffix(input, offset);
        skipWsp(input, offset);
        if (offset.* < input.len) {
            if (!readEol(input, offset)) {
                return error.InvalidPem;
            }
        } else {
            return error.UnexpectedEof;
        }
        skipEolWsp(input, offset);
        return label;
    }

    fn readLabelAndSuffix(input: []const u8, offset: *usize) ![]const u8 {
        var label_start_pos: usize = offset.*;
        var seen_sep: bool = false;
        var sep: u8 = undefined;
        while (offset.* < input.len) : (offset.* += 1) {
            const b = input[offset.*];
            if (seen_sep) {
                if (sep == '-' and b == '-') {
                    offset.* -= 1;
                    const label_end_pos = offset.*;
                    try readExpectedString(input, offset, boundary_suffix);
                    return input[label_start_pos..label_end_pos];
                } else if (isLabelChar(b)) {
                    seen_sep = false;
                } else {
                    break;
                }
            } else {
                if (isLabelWordSeparatorChar(b)) {
                    if (offset.* == label_start_pos) {
                        break;
                    }
                    seen_sep = true;
                    sep = b;
                } else if (!isLabelChar(b)) {
                    break;
                }
            }
        }
        return error.InvalidPem;
    }

    fn skipWsp(input: []const u8, offset: *usize) void {
        while (offset.* < input.len and
            mem.indexOfScalar(u8, wsp_chars, input[offset.*]) != null) : (offset.* += 1)
        {}
    }

    fn skipEolWsp(input: []const u8, offset: *usize) void {
        while (offset.* < input.len and
            mem.indexOfScalar(u8, eol_wsp_chars, input[offset.*]) != null) : (offset.* += 1)
        {}
    }

    fn readEndBoundaryLine(input: []const u8, offset: *usize, label: []const u8) !void {
        std.log.debug(
            "readEndBoundaryLine start label={s}, offset={}, rest={s}",
            .{ label, offset.*, input[offset.*..] },
        );
        try readExpectedString(input, offset, end_boundary_prefix);
        try readExpectedString(input, offset, label);
        try readExpectedString(input, offset, boundary_suffix);
        try skipWspAndOptionalEol(input, offset);
    }

    fn skipWspAndOptionalEol(input: []const u8, offset: *usize) !void {
        skipWsp(input, offset);
        if (offset.* < input.len) {
            if (!readEol(input, offset)) {
                return error.InvalidPem;
            }
        }
    }

    fn readEol(input: []const u8, offset: *usize) bool {
        const b = input[offset.*];
        if (mem.indexOfScalar(u8, eol_chars, b) != null) {
            offset.* += 1;
            if (b == '\r' and offset.* < input.len and input[offset.*] == '\n') {
                offset.* += 1;
            }
            return true;
        }
        return false;
    }

    fn readExpectedString(input: []const u8, offset: *usize, expected: []const u8) !void {
        if (input[offset.*..].len < expected.len) {
            return error.UnexpectedEof;
        }
        if (!mem.startsWith(u8, input[offset.*..], expected)) {
            return error.InvalidPem;
        }
        offset.* += expected.len;
    }

    fn isLabelChar(b: u8) bool {
        return '\x21' <= b and b <= '\x7e' and b != '-';
    }

    fn isLabelWordSeparatorChar(b: u8) bool {
        return b == '-' or b == ' ';
    }

    fn isBase64Char(b: u8) bool {
        return 'A' <= b and b <= 'Z' or
            'a' <= b and b <= 'z' or
            '0' <= b and b <= '9' or
            b == '+' or b == '/';
    }

    fn readBase64Line(
        allocator: mem.Allocator,
        encoded_buf: *std.ArrayListUnmanaged(u8),
        input: []const u8,
        offset: *usize,
        seen_pad: *bool,
    ) !void {
        var seen_wsp: bool = false;
        while (offset.* < input.len) : (offset.* += 1) {
            const b = input[offset.*];
            if (readEol(input, offset)) {
                std.log.debug(
                    "readBase64Line readEol done, offset={}, rest={s}",
                    .{ offset.*, input[offset.*..] },
                );
                return;
            }
            if (seen_wsp) {
                if (mem.indexOfScalar(u8, wsp_chars, b) == null) {
                    break;
                }
            } else {
                if (isBase64Char(b)) {
                    try encoded_buf.append(allocator, b);
                } else if (b == base64_pad_char) {
                    seen_pad.* = true;
                    std.log.debug(
                        "readBase64Line calling readPadLine, offset={}, rest={s}",
                        .{ offset.*, input[offset.*..] },
                    );
                    try readPadLine(allocator, encoded_buf, input, offset);
                    return;
                }
            }
        }
        return error.InvalidPem;
    }

    fn readPadLine(
        allocator: mem.Allocator,
        encoded_buf: *std.ArrayListUnmanaged(u8),
        input: []const u8,
        offset: *usize,
    ) !void {
        var seen_wsp: bool = false;
        while (offset.* < input.len) : (offset.* += 1) {
            const b = input[offset.*];
            if (readEol(input, offset)) {
                std.log.debug(
                    "readPadLine readEol done, offset={}, rest={s}",
                    .{ offset.*, input[offset.*..] },
                );
                return;
            }
            if (seen_wsp) {
                if (mem.indexOfScalar(u8, wsp_chars, b) == null) {
                    break;
                }
            } else {
                if (b == base64_pad_char) {
                    try encoded_buf.append(allocator, b);
                } else if (mem.indexOfScalar(u8, wsp_chars, b) != null) {
                    seen_wsp = true;
                }
            }
        }
        return error.InvalidPem;
    }
};

const testing = std.testing;

test "Block.decode" {
    testing.log_level = .debug;
    const allocator = testing.allocator;
    const priv_rsa_pem = @embedFile("../../tests/priv-rsa.pem");
    const priv_rsa_der = @embedFile("../../tests/priv-rsa.der");
    var offset: usize = 0;
    var block = try Block.decode(allocator, priv_rsa_pem, &offset);
    defer block.deinit(allocator);
    try testing.expectEqual(priv_rsa_pem.len, offset);
    try testing.expectEqualStrings("RSA PRIVATE KEY", block.label);
    try testing.expectEqualSlices(u8, priv_rsa_der, block.bytes);
}
