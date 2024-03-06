const std = @import("std");
const c = ffi.c;

const UUID = @import("uuid").Uuid;

const ffi = @import("ffi.zig");

pub fn jsonUserWriter(
    alloc: std.mem.Allocator,
    writer: anytype,
    rsa: ?*c.RSA,
) JsonUserWriter(@TypeOf(writer)) {
    return JsonUserWriter(@TypeOf(writer)){
        .json_stream = std.json.writeStream(writer, .{}),
        .alloc = alloc,
        .rsa = rsa,
    };
}

pub fn JsonUserWriter(Writer: type) type {
    return struct {
        json_stream: std.json.WriteStream(
            Writer,
            .{ .checked_to_fixed_depth = 256 },
        ),
        alloc: std.mem.Allocator,
        rsa: ?*c.RSA = null,
        state: enum { start, properties, end } = .start,

        const Self = @This();

        pub fn writeHeaderAndStartProperties(self: *Self, id: UUID, name: []const u8) !void {
            std.debug.assert(self.state == .start);

            try self.json_stream.beginObject();
            try self.json_stream.objectField("id");
            try self.json_stream.write(&id.toStringCompact());
            try self.json_stream.objectField("name");
            try self.json_stream.write(name);
            try self.json_stream.objectField("properties");
            try self.json_stream.beginArray();

            self.state = .properties;
        }

        pub fn property(self: *Self, name: []const u8, value: []const u8) !void {
            std.debug.assert(self.state == .properties);

            try self.json_stream.beginObject();
            try self.json_stream.objectField("name");
            try self.json_stream.write(name);
            try self.json_stream.objectField("value");
            try self.json_stream.write(value);
            if (self.rsa) |rsa| {
                var hasher = std.crypto.hash.Sha1.init(.{});
                hasher.update(value);

                const sig_buf = try self.alloc.alloc(u8, @intCast(c.RSA_size(rsa)));
                defer self.alloc.free(sig_buf);

                var sig_len: c_uint = 0;
                if (c.RSA_sign(
                    c.NID_sha1,
                    &hasher.finalResult(),
                    std.crypto.hash.Sha1.digest_length,
                    sig_buf.ptr,
                    &sig_len,
                    rsa,
                ) != 1) return error.OpenSSLBorked;

                const sig = sig_buf[0..sig_len];

                const sig_b64 = try self.alloc.alloc(
                    u8,
                    std.base64.standard.Encoder.calcSize(sig.len),
                );
                defer self.alloc.free(sig_b64);
                std.debug.assert(std.base64.standard.Encoder.encode(
                    sig_b64,
                    sig,
                ).len == sig_b64.len);

                try self.json_stream.objectField("signature");
                try self.json_stream.write(sig_b64);
            }
            try self.json_stream.endObject();
        }

        pub fn texturesProperty(
            self: *Self,
            user_id: UUID,
            user_name: []const u8,
            skin_url: []const u8,
        ) !void {
            var json_data = std.ArrayList(u8).init(self.alloc);
            defer json_data.deinit();
            var write_stream = std.json.writeStream(json_data.writer(), .{});
            {
                try write_stream.beginObject();
                try write_stream.objectField("timestamp");
                try write_stream.write(std.time.timestamp());
                try write_stream.objectField("profileId");
                try write_stream.write(&user_id.toStringCompact());
                try write_stream.objectField("profileName");
                try write_stream.write(user_name);
                try write_stream.objectField("textures");
                {
                    try write_stream.beginObject();
                    try write_stream.objectField("SKIN");
                    {
                        try write_stream.beginObject();
                        try write_stream.objectField("url");
                        try write_stream.write(skin_url);
                        try write_stream.endObject();
                    }
                    try write_stream.endObject();
                }
                try write_stream.endObject();
            }

            const value = try self.alloc.alloc(
                u8,
                std.base64.standard.Encoder.calcSize(json_data.items.len),
            );
            defer self.alloc.free(value);
            std.debug.assert(std.base64.standard.Encoder.encode(
                value,
                json_data.items,
            ).len == value.len);

            try self.property("textures", value);
        }

        pub fn finish(self: *Self) !void {
            std.debug.assert(self.state == .properties);
            try self.json_stream.endArray();
            try self.json_stream.endObject();
            self.state = .end;
        }
    };
}
