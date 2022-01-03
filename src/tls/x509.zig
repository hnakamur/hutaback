const std = @import("std");
const mem = std.mem;
const CurveId = @import("handshake_msg.zig").CurveId;

const KeyType = enum {
    rsa,
    ec,
};

pub const PublicKey = union(KeyType) {
    const Self = @This();

    pub const empty = Self{ .ec = .{ .id = .x25519, .curve_point = &[_]u8{} } };

    /// RSA public key
    rsa: struct {
        //Positive std.math.big.int.Const numbers.
        modulus: []const usize,
        exponent: []const usize,
    },
    /// Elliptic curve public key
    ec: struct {
        id: CurveId,
        /// Public curve point (uncompressed format)
        curve_point: []const u8,
    },

    pub fn deinit(self: Self, alloc: mem.Allocator) void {
        switch (self) {
            .rsa => |rsa| {
                alloc.free(rsa.modulus);
                alloc.free(rsa.exponent);
            },
            .ec => |ec| alloc.free(ec.curve_point),
        }
    }

    pub fn eql(self: Self, other: Self) bool {
        if (@as(KeyType, self) != @as(KeyType, other))
            return false;
        switch (self) {
            .rsa => |rsa| {
                return mem.eql(usize, rsa.exponent, other.rsa.exponent) and
                    mem.eql(usize, rsa.modulus, other.rsa.modulus);
            },
            .ec => |ec| {
                return ec.id == other.ec.id and mem.eql(u8, ec.curve_point, other.ec.curve_point);
            },
        }
    }
};

pub const PrivateKey = union(KeyType) {
    const Self = @This();

    pub const empty = Self{ .ec = .{ .id = .x25519, .curve_point = &[_]u8{} } };

    /// RSA public key
    rsa: struct {
        //Positive std.math.big.int.Const numbers.
        modulus: []const usize,
        exponent: []const usize,
    },
    /// Elliptic curve public key
    ec: struct {
        id: CurveId,
        /// Public curve point (uncompressed format)
        curve_point: []const u8,
    },

    pub fn deinit(self: Self, alloc: mem.Allocator) void {
        switch (self) {
            .rsa => |rsa| {
                alloc.free(rsa.modulus);
                alloc.free(rsa.exponent);
            },
            .ec => |ec| alloc.free(ec.curve_point),
        }
    }

    pub fn eql(self: Self, other: Self) bool {
        if (@as(KeyType, self) != @as(KeyType, other))
            return false;
        switch (self) {
            .rsa => |rsa| {
                return mem.eql(usize, rsa.exponent, other.rsa.exponent) and
                    mem.eql(usize, rsa.modulus, other.rsa.modulus);
            },
            .ec => |ec| {
                return ec.id == other.ec.id and mem.eql(u8, ec.curve_point, other.ec.curve_point);
            },
        }
    }
};

pub const SignatureAlgorithm = enum {
    MD2WithRSA = 1, // Unsupported.
    MD5WithRSA, // Only supported for signing, not verification.
    SHA1WithRSA, // Only supported for signing, not verification.
    SHA256WithRSA,
    SHA384WithRSA,
    SHA512WithRSA,
    DSAWithSHA1, // Unsupported.
    DSAWithSHA256, // Unsupported.
    ECDSAWithSHA1, // Only supported for signing, not verification.
    ECDSAWithSHA256,
    ECDSAWithSHA384,
    ECDSAWithSHA512,
    SHA256WithRSAPSS,
    SHA384WithRSAPSS,
    SHA512WithRSAPSS,
    PureEd25519,
};

const testing = std.testing;

test "SignatureAlgorithm" {
    try testing.expectEqual(1, @enumToInt(SignatureAlgorithm.MD5WithRSA));
}

test "PublicKey/PrivateKey" {
    std.debug.print("PublicKey.empty={}\n", .{PublicKey.empty});
    std.debug.print("PrivateKey.empty={}\n", .{PrivateKey.empty});
}
