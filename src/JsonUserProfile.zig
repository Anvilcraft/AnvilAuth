// TODO: implement JSON serializer instead of this jank
const std = @import("std");
const c = ffi.c;

const ffi = @import("ffi.zig");

const Id = @import("Id.zig");

pub const Property = struct {
    name: []const u8,
    value: []const u8,
    signature: ?[]const u8 = null,
};

id: []const u8,
name: []const u8,
properties: [1]Property,

const JsonUserProfile = @This();

/// id and skin_url are copied, name is only copied for properties!
pub fn init(
    alloc: std.mem.Allocator,
    id: Id,
    name: []const u8,
    skin_url: []const u8,
    rsa: ?*c.RSA,
) !JsonUserProfile {
    const id_s = try alloc.dupe(u8, &id.toString());
    errdefer alloc.free(id_s);

    const textures_value = .{
        .timestamp = std.time.timestamp(),
        .profileId = id_s,
        .profileName = name,
        .textures = .{
            .SKIN = .{
                .url = skin_url,
            },
        },
    };
    const textures_json = try std.json.stringifyAlloc(alloc, textures_value, .{});
    defer alloc.free(textures_json);

    const textures_b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(textures_json.len));
    errdefer alloc.free(textures_b64);
    std.debug.assert(std.base64.standard.Encoder.encode(textures_b64, textures_json).len == textures_b64.len);

    var textures_prop = Property{
        .name = "textures",
        .value = textures_b64,
    };

    if (rsa) |r| {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(textures_b64);

        const retbuf = try alloc.alloc(u8, @intCast(c.RSA_size(r)));
        defer alloc.free(retbuf);

        var retlen: c_uint = 0;
        if (c.RSA_sign(
            c.NID_sha1,
            &hasher.finalResult(),
            std.crypto.hash.Sha1.digest_length,
            retbuf.ptr,
            &retlen,
            r,
        ) != 1) return error.OpenSSLBorked;

        const signature = retbuf[0..retlen];

        const sig_b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(signature.len));
        errdefer alloc.free(sig_b64);
        std.debug.assert(std.base64.standard.Encoder.encode(sig_b64, signature).len == sig_b64.len);

        textures_prop.signature = sig_b64;
    }

    return .{
        .id = id_s,
        .name = name,
        .properties = .{textures_prop},
    };
}

pub fn deinit(self: JsonUserProfile, alloc: std.mem.Allocator) void {
    alloc.free(self.id);
    for (self.properties) |prop| {
        alloc.free(prop.value);
        if (prop.signature) |sig| alloc.free(sig);
    }
}
