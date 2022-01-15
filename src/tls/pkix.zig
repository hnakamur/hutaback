const std = @import("std");
const mem = std.mem;
const asn1 = @import("asn1.zig");
const x509 = @import("x509.zig");

// AlgorithmIdentifier represents the ASN.1 structure of the same name. See RFC
// 5280, section 4.1.1.2.
pub const AlgorithmIdentifier = struct {
    algorithm: asn1.ObjectIdentifier,
    parameters: ?asn1.RawValue = null,

    pub fn parse(allocator: mem.Allocator, input: *asn1.String) !AlgorithmIdentifier {
        var algorithm = asn1.ObjectIdentifier.parse(
            allocator,
            input,
        ) catch return error.MalformedOid;
        errdefer algorithm.deinit(allocator);

        if (input.empty()) {
            return AlgorithmIdentifier{ .algorithm = algorithm };
        }

        var tag: asn1.Tag = undefined;
        var params = input.readAnyAsn1Element(&tag) catch return error.MalformedParameters;
        return AlgorithmIdentifier{
            .algorithm = algorithm,
            .parameters = .{ .tag = tag, .full_bytes = try allocator.dupe(u8, params.bytes) },
        };
    }

    pub fn deinit(self: *AlgorithmIdentifier, allocator: mem.Allocator) void {
        self.algorithm.deinit(allocator);
        if (self.parameters) |*params| params.deinit(allocator);
    }
};

pub const RdnSequence = struct {
    names: []RelativeDistinguishedName,

    pub fn parse(allocator: mem.Allocator, raw: *asn1.String) !RdnSequence {
        var s = raw.readAsn1(.sequence) catch return error.InvalidRdnSequence;
        var names = std.ArrayListUnmanaged(RelativeDistinguishedName){};
        errdefer deinitArrayListAndElems(RelativeDistinguishedName, &names, allocator);
        while (!s.empty()) {
            var attributes = std.ArrayListUnmanaged(AttributeTypeAndValue){};
            errdefer deinitArrayListAndElems(AttributeTypeAndValue, &attributes, allocator);
            var set = s.readAsn1(.set) catch return error.X509InvalidRdnSequence;
            while (!set.empty()) {
                var atav = set.readAsn1(.sequence) catch return error.X509InvalidRdnSequence;
                var attr_type = asn1.ObjectIdentifier.parse(allocator, &atav) catch
                    return error.X509InvalidRdnSequence;
                errdefer attr_type.deinit(allocator);
                var value_tag: asn1.Tag = undefined;
                var raw_value = atav.readAnyAsn1(&value_tag) catch
                    return error.X509InvalidRdnSequence;

                var attr_value = x509.parseAsn1String(
                    allocator,
                    value_tag,
                    raw_value.bytes,
                ) catch return error.X509InvalidRdnSequenceAttributeValue;
                var attr = AttributeTypeAndValue{
                    .@"type" = attr_type,
                    .value = attr_value,
                };
                try attributes.append(allocator, attr);
            }
            const name = RelativeDistinguishedName{
                .attributes = attributes.toOwnedSlice(allocator),
            };
            try names.append(allocator, name);
        }
        return RdnSequence{ .names = names.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *RdnSequence, allocator: mem.Allocator) void {
        deinitSliceAndElems(RelativeDistinguishedName, self.names, allocator);
    }
};

const RelativeDistinguishedName = struct {
    attributes: []AttributeTypeAndValue,

    pub fn deinit(self: *RelativeDistinguishedName, allocator: mem.Allocator) void {
        deinitSliceAndElems(AttributeTypeAndValue, self.attributes, allocator);
    }
};

// AttributeTypeAndValue mirrors the ASN.1 structure of the same name in
// RFC 5280, Section 4.1.2.4.
const AttributeTypeAndValue = struct {
    @"type": asn1.ObjectIdentifier,
    value: []const u8,

    pub fn clone(self: AttributeTypeAndValue, allocator: mem.Allocator) !AttributeTypeAndValue {
        return AttributeTypeAndValue{
            .@"type" = try self.@"type".clone(allocator),
            .value = try allocator.dupe(u8, self.value),
        };
    }

    pub fn deinit(self: *AttributeTypeAndValue, allocator: mem.Allocator) void {
        self.@"type".deinit(allocator);
        allocator.free(self.value);
    }
};

// Name represents an X.509 distinguished name. This only includes the common
// elements of a DN. Note that Name is only an approximation of the X.509
// structure. If an accurate representation is needed, asn1.Unmarshal the raw
// subject or issuer as an RDNSequence.
pub const Name = struct {
    // elements of these fields references to memory holded by the names field.
    country: []const []const u8 = &[_][]u8{},
    organization: []const []const u8 = &[_][]u8{},
    organizational_unit: []const []const u8 = &[_][]u8{},
    locality: []const []const u8 = &[_][]u8{},
    province: []const []const u8 = &[_][]u8{},
    street_address: []const []const u8 = &[_][]u8{},
    postal_code: []const []const u8 = &[_][]u8{},
    serial_number: []const u8 = "",
    common_name: []const u8 = "",

    // names contains all parsed attributes. When parsing distinguished names,
    // this can be used to extract non-standard attributes that are not parsed
    // by this package. When marshaling to RDNSequences, the Names field is
    // ignored, see extra_names.
    names: []AttributeTypeAndValue,

    // extra_names contains attributes to be copied, raw, into any marshaled
    // distinguished names. Values override any attributes with the same OID.
    // The extra_names field is not populated when parsing, see Names.
    extra_names: []AttributeTypeAndValue = &[_]AttributeTypeAndValue{},

    // Multi-entry RDNs are flattened, all entries are added to the
    // relevant Name's fields, and the grouping is not preserved.
    pub fn fromRdnSequence(allocator: mem.Allocator, rdns: *RdnSequence) !Name {
        var country = std.ArrayListUnmanaged([]const u8){};
        errdefer country.deinit(allocator);
        var organization = std.ArrayListUnmanaged([]const u8){};
        errdefer organization.deinit(allocator);
        var organizational_unit = std.ArrayListUnmanaged([]const u8){};
        errdefer organizational_unit.deinit(allocator);
        var locality = std.ArrayListUnmanaged([]const u8){};
        errdefer locality.deinit(allocator);
        var province = std.ArrayListUnmanaged([]const u8){};
        errdefer province.deinit(allocator);
        var street_address = std.ArrayListUnmanaged([]const u8){};
        errdefer street_address.deinit(allocator);
        var postal_code = std.ArrayListUnmanaged([]const u8){};
        errdefer postal_code.deinit(allocator);
        var serial_number: []const u8 = "";
        var common_name: []const u8 = "";
        var names = std.ArrayListUnmanaged(AttributeTypeAndValue){};
        errdefer deinitArrayListAndElems(AttributeTypeAndValue, &names, allocator);
        for (rdns.names) |rdn| {
            if (rdn.attributes.len == 0) {
                continue;
            }

            for (rdn.attributes) |attr| {
                var name = try attr.clone(allocator);
                try names.append(allocator, name);

                const t = attr.@"type".components;
                if (t.len == 4 and t[0] == 2 and t[1] == 5 and t[2] == 4) {
                    switch (t[3]) {
                        3 => common_name = name.value,
                        4 => serial_number = name.value,
                        6 => try country.append(allocator, name.value),
                        7 => try locality.append(allocator, name.value),
                        8 => try province.append(allocator, name.value),
                        9 => try street_address.append(allocator, name.value),
                        10 => try organization.append(allocator, name.value),
                        11 => try organizational_unit.append(allocator, name.value),
                        17 => try postal_code.append(allocator, name.value),
                        else => {},
                    }
                }
            }
        }
        return Name{
            .country = country.toOwnedSlice(allocator),
            .organization = organization.toOwnedSlice(allocator),
            .organizational_unit = organizational_unit.toOwnedSlice(allocator),
            .locality = locality.toOwnedSlice(allocator),
            .province = province.toOwnedSlice(allocator),
            .street_address = street_address.toOwnedSlice(allocator),
            .postal_code = postal_code.toOwnedSlice(allocator),
            .serial_number = serial_number,
            .common_name = common_name,
            .names = names.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Name, allocator: mem.Allocator) void {
        if (self.country.len > 0) allocator.free(self.country);
        if (self.organization.len > 0) allocator.free(self.organization);
        if (self.organizational_unit.len > 0) allocator.free(self.organizational_unit);
        if (self.locality.len > 0) allocator.free(self.locality);
        if (self.province.len > 0) allocator.free(self.province);
        if (self.street_address.len > 0) allocator.free(self.street_address);
        if (self.postal_code.len > 0) allocator.free(self.postal_code);
        deinitSliceAndElems(AttributeTypeAndValue, self.names, allocator);
        deinitSliceAndElems(AttributeTypeAndValue, self.extra_names, allocator);
    }

    pub fn format(
        self: *const Name,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        _ = try writer.write("Name{ ");
        try formatStringSliceField("country", self.country, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringSliceField("organization", self.organization, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringSliceField("organizational_unit", self.organizational_unit, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringSliceField("locality", self.locality, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringSliceField("province", self.province, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringSliceField("street_address", self.street_address, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringSliceField("postal_code", self.postal_code, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringField("serial_number", self.serial_number, fmt, options, writer);
        _ = try writer.write(", ");
        try formatStringField("common_name", self.common_name, fmt, options, writer);
        _ = try writer.write(" }");
    }
};

fn formatStringSliceField(
    name: []const u8,
    slice: []const []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try std.fmt.format(writer, "{s} = {{ ", .{name});
    for (slice) |s, i| {
        if (i > 0) {
            _ = try writer.write(", ");
        }
        try std.fmt.format(writer, "\"{s}\"", .{s});
    }
    _ = try writer.write(" }");
}

fn formatStringField(
    name: []const u8,
    s: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    try std.fmt.format(writer, "{s} = \"{s}\"", .{ name, s });
}

fn deinitArrayListAndElems(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    allocator: mem.Allocator,
) void {
    for (list.items) |*elem| elem.deinit(allocator);
    list.deinit(allocator);
}

fn deinitSliceAndElems(
    comptime T: type,
    slice: []T,
    allocator: mem.Allocator,
) void {
    for (slice) |*elem| elem.deinit(allocator);
    if (slice.len > 0) allocator.free(slice);
}
