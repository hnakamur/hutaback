const std = @import("std");
const io = std.io;
const mem = std.mem;
const BytesView = @import("parser/bytes.zig").BytesView;

const SecurityParameters = struct {
    entity: ConnectionEnd,
    prf_algorithm: PrfAlgorithm,
    bulk_cipher_algorithm: BulkCipherAlgorithm,
    cipher_type: CipherType,
    enc_key_length: u8,
    block_length: u8,
    fixed_iv_length: u8,
    record_iv_length: u8,
    mac_algorithm: MacAlgorithm,
    mac_length: u8,
    mac_key_length: u8,
    compression_algorithm: CompressionMethod,
    master_secret: [48]u8,
    client_random: [32]u8,
    server_random: [32]u8,
};

const ConnectionEnd = enum {
    server,
    client,
};

const PrfAlgorithm = enum {
    tls_prf_sha256,
};

const BulkCipherAlgorithm = enum {
    @"null",
    rc4,
    @"3des",
    aes,
};

const CipherType = enum {
    stream,
    block,
    aead,
};

const MacAlgorithm = enum {
    @"null",
    hmac_md5,
    hmac_sha1,
    hmac_sha256,
    hmac_sha384,
    hmac_sha512,
};

const CompressionMethod = enum(u8) {
    @"null" = 0,

    fn write(self: CompressionMethod, writer: anytype) !void {
        try writer.writeByte(@enumToInt(self));
    }
};
fn writeCompressionMethodList(methods: []const CompressionMethod, writer: anytype) !void {
    try writer.writeByte(@truncate(u8, methods.len * @sizeOf(CompressionMethod)));
    for (methods) |method| {
        try method.write(writer);
    }
}

const HashAlgorithm = enum(u8) {
    none = 0,
    md5 = 1,
    sha1 = 2,
    sha224 = 3,
    sha256 = 4,
    sha384 = 5,
    sha512 = 6,
};

const SignatureAlgorithm = enum(u8) {
    anonymous = 0,
    rsa = 1,
    dsa = 2,
    ecdsa = 3,
};

const SignatureAndHashAlgorithm = struct {
    hash: HashAlgorithm,
    signature: SignatureAlgorithm,
};

const ProtocolVersion = struct {
    major: u8,
    minor: u8,

    fn write(self: *const ProtocolVersion, writer: anytype) !void {
        try writer.writeByte(self.major);
        try writer.writeByte(self.minor);
    }

    fn read(reader: anytype) !ProtocolVersion {
        const major = try reader.readByte();
        const minor = try reader.readByte();
        const ver = ProtocolVersion{ .major = major, .minor = minor };
        if (!(ver.eql(v1_2) or ver.eql(v1_0))) return error.UnsupportedProtocolVersion;
        return ver;
    }

    fn eql(self: ProtocolVersion, other: ProtocolVersion) bool {
        return self.major == other.major and self.minor == other.minor;
    }
};
const v1_2 = ProtocolVersion{ .major = 3, .minor = 3 };
const v1_0 = ProtocolVersion{ .major = 3, .minor = 1 };

const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

const TlsPlaintext = struct {
    content_type: ContentType,
    version: ProtocolVersion,
    length: u16,
    fragment: []u8,
};

// https://datatracker.ietf.org/doc/html/rfc6066#section-4
const tls_ciphertext_fragment_max_len: usize = 1 << (14 - 1);

const TlsCiphertext = struct {
    const Fragment = union(CipherType) {
        stream: GenericStreamCipher,
        block: GenericBlockCipher,
        aead: GenericAeadCipher,
    };

    content_type: ContentType,
    version: ProtocolVersion,
    length: u16,
    fragment: Fragment,
};

const GenericStreamCipher = struct {
    content: []u8,
    mac: []u8,
};

const GenericBlockCipher = struct {
    const BlockCiphered = struct {
        content: []u8,
        mac: []u8,
        padding: []u8,
        padding_length: u8,
    };

    iv: []u8,
    block_ciphered: BlockCiphered,
};

const GenericAeadCipher = struct {
    const AeadCiphered = struct {
        content: []u8,
    };

    nonce_explicit: []u8,
    aead_ciphered: AeadCiphered,
};

const HandshakeType = enum(u8) {
    hello_request = 0,
    client_hello = 1,
    server_hello = 2,
    certificate = 11,
    server_key_exchange = 12,
    certificate_request = 13,
    server_hello_done = 14,
    certificate_verify = 15,
    client_key_exchange = 16,
    finished = 20,

    fn write(self: HandshakeType, writer: anytype) !void {
        try writer.writeByte(@enumToInt(self));
    }

    fn read(reader: anytype) !HandshakeType {
        const b = try reader.readByte();
        return @intToEnum(HandshakeType, b);
    }
};

const Handshake = struct {
    const Body = union(HandshakeType) {
        hello_request: HelloRequest,
        client_hello: ClientHello,
        server_hello: ServerHello,
        certificate: Certificate,
        server_key_exchange: ServerKeyExchange,
        certificate_request: CertificateRequest,
        server_hello_done: ServerHelloDone,
        certificate_verify: CertificateVerify,
        client_key_exchange: ClientKeyExchange,
        finished: Finished,

        fn write(self: *const Body, writer: anytype) !void {
            switch (self.*) {
                .client_hello => |*ch| try ch.write(writer),
                else => @panic("not implemented yet"),
            }
        }

        fn read(allocator: mem.Allocator, msg_type: HandshakeType, reader: anytype) !Body {
            switch (msg_type) {
                .server_hello => return Body{
                    .server_hello = try ServerHello.read(allocator, reader),
                },
                .server_hello_done => return Body{
                    .server_hello_done = try ServerHelloDone.read(allocator, reader),
                },
                else => @panic("not implemented yet"),
            }
        }
    };

    msg_type: HandshakeType,
    length: u24,
    body: Body,

    fn updateLength(self: *Handshake) !void {
        var writer = io.countingWriter(io.null_writer);
        try self.body.write(writer.writer());
        self.length = @truncate(u24, writer.bytes_written);
    }

    fn write(self: *const Handshake, writer: anytype) !void {
        try self.msg_type.write(writer);
        try writer.writeIntBig(u24, self.length);
        try self.body.write(writer);
    }

    fn read(allocator: mem.Allocator, reader: anytype) !Handshake {
        const hs_type = try HandshakeType.read(reader);
        const len = try reader.readIntBig(u24);
        var cr = io.countingReader(reader);
        const body = try Body.read(allocator, hs_type, cr.reader());
        if (cr.bytes_read != len) return error.MismatchedLength;
        return Handshake{ .msg_type = hs_type, .length = len, .body = body };
    }
};

const ClientHello = struct {
    client_version: ProtocolVersion,
    random: Random,
    session_id: SessionId,
    cipher_suites: []CipherSuite,
    compression_methods: []const CompressionMethod,
    extensions: []const Extension,

    fn write(self: *const ClientHello, writer: anytype) !void {
        try self.client_version.write(writer);
        try writer.writeAll(&self.random);
        try writeSessionId(self.session_id, writer);
        try writeCipherSuiteList(self.cipher_suites, writer);
        try writeCompressionMethodList(self.compression_methods, writer);
        try writeExtensions(self.extensions, writer);
    }
};

const ServerHello = struct {
    server_version: ProtocolVersion,
    random: Random,
    session_id: SessionId,
    cipher_suite: CipherSuite,
    compression_method: []const CompressionMethod,
    extensions: []const Extension,

    fn deinit(self: *ServerHello, allocator: mem.Allocator) void {
        allocator.free(self.session_id);
    }

    fn read(allocator: mem.Allocator, reader: anytype) !ServerHello {
        const ver = try ProtocolVersion.read(reader);
        const rnd = try readRandom(reader);
        const ses_id = try readSessionId(allocator, reader);
        _ = ver;
        _ = rnd;
        _ = ses_id;
        @panic("not implemented yet");
    }
};

const random_len = 32;
const Random = [random_len]u8;
fn readRandom(reader: anytype) !Random {
    return try reader.readBytesNoEof(random_len);
}

test "readRandom" {
    const data = [_]u8{0} ** 32;
    var fbs = io.fixedBufferStream(&data);
    const rnd = try readRandom(fbs.reader());
    try testing.expectEqual(Random, @TypeOf(rnd));
}

const SessionId = []const u8;
const session_id_max_len = 32;

fn writeSessionId(self: SessionId, writer: anytype) !void {
    try writer.writeByte(@truncate(u8, self.len));
    try writer.writeAll(self);
}
fn readSessionId(allocator: mem.Allocator, reader: anytype) !SessionId {
    return try readLenAndBytes(u8, allocator, reader);
}

fn readLenAndBytes(comptime LengthType: type, allocator: mem.Allocator, reader: anytype) ![]u8 {
    const len = try reader.readIntBig(LengthType);
    var buf = try allocator.alloc(u8, len);
    try reader.readNoEof(buf);
    return buf;
}

test "readSessionId" {
    const allocator = testing.allocator;
    const data = "\x03\x01\x02\x03";
    var fbs = io.fixedBufferStream(data);
    const id = try readSessionId(allocator, fbs.reader());
    defer allocator.free(id);
    try testing.expectEqualSlices(u8, "\x01\x02\x03", id);
}

fn unmarshalSessionId(input: *BytesView) !SessionId {
    return try unmarshalLenAndBytes(u8, input);
}
fn unmarshalLenAndBytes(comptime LengthType: type, input: *BytesView) ![]const u8 {
    const len = try input.readIntBig(LengthType);
    return try input.sliceBytesNoEof(len);
}

test "unmarshalSessionId" {
    const data = "\x03\x01\x02\x03";
    var input = BytesView.init(data, true);
    const id = try unmarshalSessionId(&input);
    try testing.expectEqualSlices(u8, "\x01\x02\x03", id);
}

const CipherSuite = [2]u8;

fn writeCipherSuiteList(cipher_suites: []const CipherSuite, writer: anytype) !void {
    try writer.writeIntBig(u16, @truncate(u16, cipher_suites.len) * @sizeOf(CipherSuite));
    for (cipher_suites) |*suite| {
        try writer.writeAll(suite);
    }
}

fn writeExtensions(extensions: []const Extension, writer: anytype) !void {
    const len = try calcExtensionsContentswritedLen(extensions);
    try writer.writeIntBig(u16, @truncate(u16, len));
    try writeExtensionsContents(extensions, writer);
}

fn calcExtensionsContentswritedLen(extensions: []const Extension) !u64 {
    var writer = io.countingWriter(io.null_writer);
    try writeExtensionsContents(extensions, writer.writer());
    return writer.bytes_written;
}

fn writeExtensionsContents(extensions: []const Extension, writer: anytype) !void {
    for (extensions) |*ext| {
        try ext.write(writer);
    }
}

const Extension = struct {
    extension_type: ExtensionType,
    extension_data: ExtensionData,

    fn write(self: *const Extension, writer: anytype) !void {
        try writer.writeIntBig(u16, @enumToInt(self.extension_type));
        try self.extension_data.write(writer);
    }
};

// https://datatracker.ietf.org/doc/html/rfc6066#section-1.1
const ExtensionType = enum(u16) {
    server_name = 0,
    // max_fragment_length = 1,
    // client_certificate_url = 2,
    // trusted_ca_keys = 3,
    // truncated_hmac = 4,
    // status_request = 5,
    // signature_algorithms = 13,
};

const ExtensionData = union(ExtensionType) {
    server_name: ServerNameList,

    fn write(self: *const ExtensionData, writer: anytype) !void {
        switch (self.*) {
            .server_name => |sn| try sn.write(writer),
        }
    }
};

const asn1_cert_len = 1 << (24 - 1) - 1;
const Asn1Cert = [asn1_cert_len]u8;

const Certificate = struct {
    certificate_list: []Asn1Cert,
};

const KeyExchangeAlgorithm = enum {
    dhe_dss,
    dhe_rsa,
    dh_anon,
    rsa,
    dh_dss,
    dh_rsa,
    // may be extended, e.g., for ECDH -- see [TLSECC]
};

const ServerDHParams = struct {
    dh_p: []u8,
    dh_g: []u8,
    dh_Ys: []u8,
};

const ServerKeyExchange = union(KeyExchangeAlgorithm) {
    const SignedParams = struct {
        client_random: [32]u8,
        server_random: [32]u8,
        params: ServerDHParams,
    };
    const ParamsAndSigned = struct {
        params: ServerDHParams,
        signed_params: SignedParams,
    };

    dh_anon: ServerDHParams,
    dhe_dss: ParamsAndSigned,
    dhe_rsa: ParamsAndSigned,
    rsa: void,
    dh_dss: void,
    dh_rsa: void,
    // message is omitted for rsa, dh_dss, and dh_rsa
    // may be extended, e.g., for ECDH -- see [TLSECC]
};

const ClientCertificateType = enum(u8) {
    rsa_sign = 1,
    dss_sign = 2,
    rsa_fixed_dh = 3,
    dss_fixed_dh = 4,
    rsa_ephemeral_dh_RESERVED = 5,
    dss_ephemeral_dh_RESERVED = 6,
    fortezza_dms_RESERVED = 20,
};

const HelloRequest = struct {};

const DistinguishedName = []u8;

const CertificateRequest = struct {
    certificate_types: ClientCertificateType,
    supported_signature_algorithms: []SignatureAndHashAlgorithm,
    certificate_authorities: []DistinguishedName,
};

const ServerHelloDone = struct {
    fn read(_: mem.Allocator, _: anytype) !ServerHelloDone {
        return ServerHelloDone{};
    }
};

const CertificateVerify = struct {
    handshake_messages: []u8,
};

const ClientKeyExchange = struct {
    const Keys = union(KeyExchangeAlgorithm) {
        rsa: EncryptedPreMasterSecret,
        dhe_dss: ClientDiffieHellmanPublic,
        dhe_rsa: ClientDiffieHellmanPublic,
        dh_dss: ClientDiffieHellmanPublic,
        dh_rsa: ClientDiffieHellmanPublic,
        dh_anon: ClientDiffieHellmanPublic,
    };

    exchange_keys: Keys,
};

const EncryptedPreMasterSecret = struct {
    pre_master_secret: PreMasterSecret, //  public-key-encrypted
};

const PreMasterSecret = struct {
    client_version: ProtocolVersion,
    random: [46]u8,
};

const PublicValueEncoding = enum { implicit, explicit };

const ClientDiffieHellmanPublic = struct {
    const DhPublic = union(PublicValueEncoding) {
        implicit: void,
        explicit: DhYc,
    };

    dh_public: DhPublic,
};

const DhYc = []u8;

const Finished = struct {
    verify_data: []u8,
};

const ServerNameList = struct {
    server_name_list: []const ServerName,

    fn write(self: *const ServerNameList, writer: anytype) !void {
        const len = try calcServerNameListContentswritedLen(self.server_name_list);
        try writer.writeIntBig(u16, @truncate(u16, len));
        try writeServerNameListContents(self.server_name_list, writer);
    }
};

fn calcServerNameListContentswritedLen(server_name_list: []const ServerName) !u64 {
    var writer = io.countingWriter(io.null_writer);
    try writeServerNameListContents(server_name_list, writer.writer());
    return writer.bytes_written;
}

fn writeServerNameListContents(server_name_list: []const ServerName, writer: anytype) !void {
    for (server_name_list) |server_name| {
        try server_name.write(writer);
    }
}

const ServerName = union(NameType) {
    host_name: HostName,

    fn write(self: *const ServerName, writer: anytype) !void {
        try writer.writeByte(@enumToInt(@as(NameType, self.*)));
        switch (self.*) {
            .host_name => |n| try writeHostName(n, writer),
        }
    }
};

const NameType = enum(u8) {
    host_name = 0,
};

const HostName = []const u8;
fn writeHostName(hostname: []const u8, writer: anytype) !void {
    try writer.writeIntBig(u16, @truncate(u16, hostname.len));
    try writer.writeAll(hostname);
}

const testing = std.testing;

test "ServerKeyExchange" {
    const xchg = ServerKeyExchange{ .rsa = {} };
    std.debug.print("xchg = {}\n", .{xchg});
}

test "ClientHello" {
    const client_hello = TlsPlaintext{
        .content_type = .handshake,
        .version = v1_0,
        .length = 0,
        .fragment = "",
    };

    std.debug.print("client_hello = {}\n", .{client_hello});
}

test "write_u24" {
    var buf = [_]u8{0} ** 3;
    var fbs = io.fixedBufferStream(&buf);

    const length: u24 = 0x123456;
    try fbs.writer().writeIntBig(u24, length);
    try testing.expectEqualSlices(u8, &[_]u8{ '\x12', '\x34', '\x56' }, &buf);
}

test "Handshake.write" {
    var hs = Handshake{
        .msg_type = .client_hello,
        .length = 0,
        .body = .{
            .client_hello = ClientHello{
                .client_version = v1_2,
                .random = [_]u8{0} ** 32,
                .session_id = &[_]u8{0},
                .cipher_suites = &[_]CipherSuite{},
                .compression_methods = &[_]CompressionMethod{.@"null"},
                .extensions = &[_]Extension{
                    .{
                        .extension_type = .server_name,
                        .extension_data = .{
                            .server_name = ServerNameList{
                                .server_name_list = &[_]ServerName{
                                    .{
                                        .host_name = "example.com",
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    };

    const allocator = testing.allocator;
    const DynamicBytesBuf = std.fifo.LinearFifo(u8, .Dynamic);
    var buf = DynamicBytesBuf.init(allocator);
    defer buf.deinit();
    var writer = buf.writer();
    try hs.updateLength();
    try testing.expectEqual(@as(u24, 49 + "example.com".len), hs.length);
    try hs.write(writer);
    const want = "\x01\x00\x00\x3c" ++ "\x03\x03" ++ "\x00" ** 32 ++ "\x01\x00" ++
        "\x00\x00" ++ "\x01\x00" ++
        "\x00\x12" ++
        "\x00\x00" ++
        "\x00\x0e" ++
        "\x00" ++
        "\x00\x0b" ++
        "example.com";
    try testing.expectEqualSlices(u8, want, buf.readableSlice(0));
}

test "read ServerHelloDone" {
    const allocator = testing.allocator;

    const data = "\x0e" ++ // server_hello_done
        "\x00\x00\x00";
    var fbs = io.fixedBufferStream(data);
    const hs = try Handshake.read(allocator, fbs.reader());
    try testing.expectEqual(HandshakeType.server_hello_done, hs.msg_type);
}

// test "read ServerHello" {
//     const data = "\x16\x03\x03\x00\x6c" ++ // handshake TLSv1.2, length 0x006c
//         "\x02" ++ // server_hello
//         "\x00\x00\x68" ++ // length:u24 = 0x68 = 104
//         "\x03\x03" ++ // server_version
//         "\xca\xe3\x95\xf7\x9b\x56\x53\xa4\x06\x88\x47\xa8\xb5\x4c\xc6\xfb\x6d\xb5\xbd\x3f\xeb\xde\x45\x84\x44\x4f\x57\x4e\x47\x52\x44\x01" ++ // server random 32 bytes
//         "\x20" ++ // session_id length
//         "\x28\xb1\x79\x8c\x0f\x26\xbe\x48\x64\x6b\x6f\xd3\x2b\x4d\x49\x10\xf4\x0e\x05\x8b\x09\xb2\x95\x4e\xda\xa6\x22\xc9\xbb\x4f\x8c\x27" ++ // session_id
//         "\xcc\xa8" ++ // cipher suite ECDHE-RSA-CHACHA20-POLY1305
//         "\x00" ++ // compression method 0x00 = null
//         "\x00\x20" ++ // extensions length: u16 0x0020 = 32
//         "\xff\x01" ++ // extension type: u16 = 0xff01 = Renegotiation info
//         "\x00\x01" ++ // extention length: u16 = 0x0001
//         "\x00" ++ // renegotiation info: u8 = 0x00
//         "\x00\x00" ++ // extension type: u16 = 0x0000 = servername
//         "\x00\x00" ++ // extention length: u16 = 0x0000
//         "\x00\x0b" ++ // extension type: u16 = 0x000b = SupportedPoints RFC 4492, Section 5.1.2 https://datatracker.ietf.org/doc/html/rfc4492#section-5.1.2
//         "\x00\x04" ++ // extension length: u16 = 0x0004
//         "\x03\x00\x01\x02" ++ // extension data: length u1: 0x03 + 3 bytes data
//         "\x00\x10" ++ // extension type: u16 0x0010 = 16 ALPN RFC 7301, Section 3.1 https://datatracker.ietf.org/doc/html/rfc7301#section-3.1
//         "\x00\x0b" ++ // extension length: u16 0x000b = 11
//         "\x00\x09\x08\x68\x74\x74\x70\x2f\x31\x2e\x31" ++ // u16 len = 0x009, u8 len = 0x08, 8 bytes data
//         "\x16\x03\x03\x03\x78" ++ // handshake TLSv1.2 length 0x0378
//         "\x0b" ++ // certificate
//         "\x00\x03\x74" ++ // length:u24 0x000374 = 884
//         "\x00\x03\x71" ++ // length:u24 0x000371 = 881
//         "\x00\x03\x6e" ++ // length:u24 0x00036e = 878
//         "\x30\x82\x03\x6a\x30\x82\x02\x52\xa0\x03\x02\x01\x02\x02\x01\x01\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x05\x05\x00\x30\x4e\x31\x0b\x30\x09\x06\x03\x55\x04\x06\x13\x02\x4a\x50\x31\x0e\x30\x0c\x06\x03\x55\x04\x08\x0c\x05\x4f\x73\x61\x6b\x61\x31\x13\x30\x11\x06\x03\x55\x04\x07\x0c\x0a\x4f\x73\x61\x6b\x61\x20\x43\x69\x74\x79\x31\x1a\x30\x18\x06\x03\x55\x04\x03\x0c\x11\x74\x68\x69\x6e\x6b\x63\x65\x6e\x74\x72\x65\x32\x2e\x74\x65\x73\x74\x30\x1e\x17\x0d\x32\x31\x31\x31\x32\x37\x32\x32\x31\x31\x31\x33\x5a\x17\x0d\x32\x32\x31\x31\x32\x37\x32\x32\x31\x31\x31\x33\x5a\x30\x4e\x31\x0b\x30\x09\x06\x03\x55\x04\x06\x13\x02\x4a\x50\x31\x0e\x30\x0c\x06\x03\x55\x04\x08\x0c\x05\x4f\x73\x61\x6b\x61\x31\x13\x30\x11\x06\x03\x55\x04\x07\x0c\x0a\x4f\x73\x61\x6b\x61\x20\x43\x69\x74\x79\x31\x1a\x30\x18\x06\x03\x55\x04\x03\x0c\x11\x74\x68\x69\x6e\x6b\x63\x65\x6e\x74\x72\x65\x32\x2e\x74\x65\x73\x74\x30\x82\x01\x22\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00\x03\x82\x01\x0f\x00\x30\x82\x01\x0a\x02\x82\x01\x01\x00\xe3\xbd\x28\xba\xbf\xf8\x48\xa1\x5d\xc9\x2b\x83\xc5\x82\x6c\xe1\xc8\x5e\x32\xb0\x36\x05\xe8\xcc\xbc\x32\x59\x42\xe4\x87\x8e\xd3\xf4\x85\x26\x9c\xac\x3c\x46\xaa\x25\x45\x5a\x42\xcb\x7c\x0d\x25\xbf\x49\x2b\xf2\x38\x42\x29\x29\xb6\x2c\x43\xf8\xca\x10\xe0\x84\xf0\xef\x3c\x01\x72\xf8\xcf\x07\x2b\xe2\x5f\x46\xa5\x48\x1a\x0f\xb3\x6e\x53\x21\x5e\xd8\xf8\xeb\x31\x97\x05\x31\xec\x57\xdf\xcb\x2c\x7a\x13\x2d\x12\xff\x1e\xf5\xda\x89\x7a\x1a\xff\xd9\x76\x3a\x3b\xb9\xe3\x66\x2d\x3c\xf8\x80\xd0\x28\x99\x21\x84\xfb\xd4\x4d\x48\xc9\xc8\x7a\xeb\x67\x49\xf1\x52\xdc\x3a\x27\x71\xbb\xd2\x5a\x57\x8e\xa7\x2b\x3f\xb8\x2e\x8d\xa9\x0c\x83\xe2\x26\x2e\x98\x80\x5d\x88\xbc\xc8\x55\x5c\xde\x32\x41\xd1\x76\xea\xda\x92\xee\x2b\xd3\xda\xcd\x62\xa7\x9c\x07\x71\x5f\x49\xc2\x62\xfa\xb9\x4a\x9b\x3c\xa9\xf8\xb1\x0f\x23\x33\x7e\x08\x16\x15\x9b\xff\xd5\x16\x6c\xdb\x28\x08\x3f\xc9\x3e\xc9\xae\x28\xb1\x3c\x08\x0c\xaa\xde\x63\x00\xdc\x14\x1b\x1c\xa1\x44\x98\xdb\x03\xc0\x46\xaf\x34\x79\xb1\x67\xc8\xaa\x06\xd1\x2e\x01\xd5\x59\x6b\xb4\x83\x51\xd9\xc6\x0d\x02\x03\x01\x00\x01\xa3\x53\x30\x51\x30\x1d\x06\x03\x55\x1d\x0e\x04\x16\x04\x14\x00\xc8\x14\x1c\x66\xef\x38\xc4\x39\xb1\x4e\x61\x6e\xff\xe8\x69\x8c\x66\x03\xc4\x30\x1f\x06\x03\x55\x1d\x23\x04\x18\x30\x16\x80\x14\x00\xc8\x14\x1c\x66\xef\x38\xc4\x39\xb1\x4e\x61\x6e\xff\xe8\x69\x8c\x66\x03\xc4\x30\x0f\x06\x03\x55\x1d\x13\x01\x01\xff\x04\x05\x30\x03\x01\x01\xff\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x05\x05\x00\x03\x82\x01\x01\x00\x68\xde\x75\x92\x59\xec\x60\x22\x79\xa0\x48\x02\x2a\x9b\xf6\x27\x8d\x84\x83\x97\xe2\x3a\x74\xd2\x47\x0b\xb6\x3c\x8d\x46\x90\xd5\xf3\x66\x78\x6c\x10\x06\x45\x37\x77\xb2\x35\x14\xbf\x29\xd1\xba\xf7\xef\x7c\x21\x1b\xe9\x49\x3d\x62\xf5\x95\xaf\x41\x53\x1e\x90\xaf\x26\xef\xb6\x6a\x52\x29\x9c\x49\x10\x72\xa3\xac\x57\xe0\x7f\x8e\x25\xaa\x08\x16\x18\x4f\x53\x6e\xc2\xf2\x36\x74\xba\xb3\x1c\xf8\x45\x64\x3d\x8c\xa9\xc8\xe7\x8d\x7f\x65\x08\xd3\xf1\x89\x3d\xd1\x52\x52\x86\x2d\x7d\xeb\xc7\xf5\x7f\xdc\xd6\x0d\xb7\x76\x15\x99\xc6\xa3\xa6\x5e\xdb\x51\xc0\xa3\xdb\x30\x4d\xa1\xf4\x9b\xd8\x16\xf1\x9b\x18\xd6\xe7\x22\x01\xc2\xf7\xbb\xf7\xf3\x57\xa8\xcd\x3a\xce\x7f\xfc\xea\x91\xd8\xaf\x3e\xc5\x89\x4e\xe1\xc2\xff\x26\x4a\xb3\x2c\x23\x90\xe3\x54\x64\x3f\xa1\xc5\x12\x8f\x89\x1c\xe8\x3b\xa2\xc5\x71\x83\x08\x47\xe9\x4f\xce\x28\x5f\x5a\xc3\xab\x1b\xf6\xba\x69\x7b\x3a\x81\x68\x56\x6d\xf9\x97\x83\xa3\xa4\x72\x34\xb6\x81\x6e\x92\xda\x3b\x5a\x32\xb0\xe1\x8e\xb3\x10\xf3\x72\x8b\xac\x45\x88\x8e\x1f\xb3\x84\x73\x84\xe4\x71\xe5\x34\xbf\xae\x0f" ++ // cerificate
//         "\x16\x03\x03\x01\x2c" ++ // handshake TLSv1.2 length 0x012c
//         "\x0c" ++ // server_key_exchange
//         "\x00\x01\x28" ++ // length: u24 = 0x00128 = 296
//         "\x03" ++ // must be 0x03
//         "\x00\x1d" ++ // curve_id 0x001d = x25519
//         "\x20" ++ // pub key len = 0x20 = 32
//         "\x45\x0b\x06\xec\xfa\xc3\x2d\x22\x79\x27\x50\x80\xb4\xbe\x85\xee\xcd\xfb\x91\xb8\x77\xf4\x3d\x64\xc0\x34\x89\xd1\xc5\x22\x2d\x4d" ++ // pub key
//         "\x04\x01" ++ // signature_id 0x0401 = RSA/PKCS1/SHA256
//         "\x01\x00" ++ // signature_len 0x0100 = 256
//         "\x22\xe1\xdf\x1d\x2c\x06\xe6\x67\x97\xb7\x55\x4c\x91\x12\x35\x3f\xe2\x05\x43\xa5\x0a\xaf\xdc\xaa\x6c\x16\x4b\xd6\xf8\x97\x73\xb5\x1d\xbe\x0b\x25\xd2\x22\xc4\x0d\xcd\xc1\x22\x5c\x10\xe9\x23\xce\x10\x90\x40\xc5\xbd\x82\x4c\x87\xf5\x2c\x29\xcb\xad\xfc\xf9\x33\xed\x7b\xcd\x9b\x9c\x9a\x64\x88\x5a\xdd\xf1\x8a\x21\x8f\xae\x26\x9f\xe1\xfd\xf4\x69\x40\x90\xbe\xdc\xe8\xc2\x5a\xee\xed\x45\x82\x14\xef\xac\x86\x9c\x05\x22\xd2\x2f\x32\xfe\xb1\xf6\x4b\x74\x1b\x76\x58\x28\x8b\x59\xfe\x07\xba\x4a\x15\x7e\xc2\x45\xa0\x63\x8a\xb6\xf2\xf7\xa8\xca\x90\x71\xa5\xdd\xd0\xef\xbf\xe2\xf2\xff\xc6\x51\x34\x34\xcb\x66\x68\x2b\xd6\x16\xea\xa0\x51\x58\x73\xb3\xd9\x90\x73\x4c\xb0\x14\x41\x50\x4b\xb9\x1f\xf1\x9e\xf2\x10\x19\xc6\x0e\x8b\xfb\x3a\x64\xb3\x68\x79\xfa\x64\xff\x41\xe5\xeb\x10\x44\x69\xb2\xc8\x6a\x60\x81\x2d\xdc\xff\xf2\xaa\xa2\xa9\xf6\xec\x4a\x03\x20\xb5\xe8\x9e\x05\xf8\xd2\x6b\x95\x9f\x28\x06\xc6\x36\x83\x7e\x1e\x4f\xb5\x4c\xa0\xa6\x00\x0e\x5f\x7d\x8e\xbe\x07\xf7\xeb\xc6\x42\x4e\x7f\x19\x83\x26\x24\x53\xd3\xd8\x31\x6b\x64\x86\x8e" ++ // signature 256 bytes
//         "\x16\x03\x03\x00\x04" ++ // handshake TLSv1.2 length 0x0004
//         "\x0e" ++ // server_hello_done
//         "\x00\x00\x00";
// }
