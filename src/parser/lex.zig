const std = @import("std");
const memx = @import("../memx.zig");

pub fn isDelimChar(c: u8) bool {
    return delim_char_bitset.isSet(c);
}

pub fn isTokenChar(c: u8) bool {
    return token_char_bitset.isSet(c);
}

pub fn isQdTextChar(c: u8) bool {
    return qd_text_char_bitset.isSet(c);
}

pub fn isQuotedPairChar(c: u8) bool {
    return quoted_pair_char_bitset.isSet(c);
}

pub fn isVisibleChar(c: u8) bool {
    return '\x21' <= c and c <= '\x7e';
}

pub fn isObsTextChar(c: u8) bool {
    return '\x80' <= c;
}

pub fn isFieldVisibleChar(c: u8) bool {
    return isVisibleChar(c) or isObsTextChar(c);
}

pub fn isWhiteSpaceChar(c: u8) bool {
    return c == ' ' or c == '\t';
}

const delim_char_bitset = makeStaticCharBitSet(_isDelimChar);
const token_char_bitset = makeStaticCharBitSet(_isTokenChar);
const qd_text_char_bitset = makeStaticCharBitSet(_isQdTextChar);
const quoted_pair_char_bitset = makeStaticCharBitSet(_isQuotedPairChar);

const char_bitset_size = 256;

pub fn makeStaticCharBitSet(predicate: fn (u8) bool) std.StaticBitSet(char_bitset_size) {
    @setEvalBranchQuota(10000);
    var bitset = std.StaticBitSet(char_bitset_size).initEmpty();
    var c: u8 = 0;
    while (true) : (c += 1) {
        if (predicate(c)) bitset.set(c);
        if (c == '\xff') break;
    }
    return bitset;
}

const delim_chars = "\"(),/:;<=>?@[\\]{}";

fn _isDelimChar(c: u8) bool {
    return memx.containsScalar(u8, delim_chars, c);
}

fn _isTokenChar(c: u8) bool {
    return _isVisibleChar(c) and !_isDelimChar(c);
}

fn _isVisibleChar(c: u8) bool {
    return c > '\x20' and c < '\x7f';
}

fn _isQdTextChar(c: u8) bool {
    return switch (c) {
        '\t', ' ', '\x21', '\x23'...'\x5b', '\x5d'...'\x7e', '\x80'...'\xff' => true,
        else => false,
    };
}

fn _isQuotedPairChar(c: u8) bool {
    return switch (c) {
        '\t', ' ', '\x21'...'\x7e', '\x80'...'\xff' => true,
        else => false,
    };
}

const testing = std.testing;

test "makeStaticCharBitSet" {
    const bs = makeStaticCharBitSet(_isTokenChar);
    var c: u8 = 0;
    while (true) : (c += 1) {
        try testing.expectEqual(_isTokenChar(c), bs.isSet(c));
        if (c == '\xff') break;
    }
}

test "isVisibleChar" {
    try testing.expect(!isVisibleChar('\x20'));
    try testing.expect(isVisibleChar('\x21'));
    try testing.expect(isVisibleChar('\x7e'));
    try testing.expect(!isVisibleChar('\x7f'));
}

test "isObsTextChar" {
    try testing.expect(!isObsTextChar('\x00'));
    try testing.expect(!isObsTextChar('\x7f'));
    try testing.expect(isObsTextChar('\x80'));
    try testing.expect(isObsTextChar('\xff'));
}

test "isDelimChar" {
    var c: u8 = 0;
    while (true) : (c += 1) {
        try testing.expectEqual(_isDelimChar(c), isDelimChar(c));
        if (c == '\xff') break;
    }
}

test "isTokenChar" {
    var c: u8 = 0;
    while (true) : (c += 1) {
        try testing.expectEqual(_isTokenChar(c), isTokenChar(c));
        if (c == '\xff') break;
    }
}

test "isQdTextChar" {
    var c: u8 = 0;
    while (true) : (c += 1) {
        try testing.expectEqual(_isQdTextChar(c), isQdTextChar(c));
        if (c == '\xff') break;
    }
}

test "isQuotedPairChar" {
    var c: u8 = 0;
    while (true) : (c += 1) {
        try testing.expectEqual(_isQuotedPairChar(c), isQuotedPairChar(c));
        if (c == '\xff') break;
    }
}

test "isFieldVisibleChar" {
    try testing.expect(isFieldVisibleChar('a'));
    try testing.expect(isFieldVisibleChar('\xff'));
    try testing.expect(!isFieldVisibleChar('\t'));
}

test "isWhiteSpaceChar" {
    try testing.expect(isWhiteSpaceChar(' '));
    try testing.expect(isWhiteSpaceChar('\t'));
    try testing.expect(!isWhiteSpaceChar('\r'));
    try testing.expect(!isWhiteSpaceChar('\n'));
}
