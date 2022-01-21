const std = @import("std");
const mem = std.mem;
const SignatureScheme = @import("handshake_msg.zig").SignatureScheme;
const x509 = @import("x509.zig");

pub const CertificateChain = struct {
    certificate_chain: []const []const u8,
    // PrivateKey contains the private key corresponding to the public key in
    // Leaf. This must implement crypto.Signer with an RSA, ECDSA or Ed25519 PublicKey.
    // For a server up to TLS 1.2, it can also implement crypto.Decrypter with
    // an RSA PublicKey.
    private_key: ?PrivateKey = null,
    // SupportedSignatureAlgorithms is an optional list restricting what
    // signature algorithms the PrivateKey can be used for.
    supported_signature_algorithms: ?[]const SignatureScheme = null,
    // OCSPStaple contains an optional OCSP response which will be served
    // to clients that request it.
    ocsp_staple: ?[]const u8 = null,
    // SignedCertificateTimestamps contains an optional list of Signed
    // Certificate Timestamps which will be served to clients that request it.
    signed_certificate_timestamps: ?[]const []const u8 = null,
    // Leaf is the parsed form of the leaf certificate, which may be initialized
    // using x509.ParseCertificate to reduce per-handshake processing. If nil,
    // the leaf certificate will be parsed as needed.
    leaf: ?*x509.Certificate = null,

    pub fn deinit(self: *CertificateChain, allocator: mem.Allocator) void {
        allocator.free(self.certificate_chain);
    }
};

pub const PrivateKey = struct {
    raw: []const u8,
};
