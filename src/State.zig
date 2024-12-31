const std = @import("std");
const c = @import("ffi.zig").c;

const UUID = @import("uuid").Uuid;

const Db = @import("Db.zig");

pub const UserCache = std.StringHashMapUnmanaged(struct {
    skin_url: ?[]const u8,
    cape_url: ?[]const u8,
    expiration: i64,
});

allocator: std.mem.Allocator,
base_url: []const u8,
domain: []const u8,
forgejo_url: []const u8,
anvillib_url: ?[]const u8,
skin_domains: []const []const u8,
server_name: []const u8,
http: std.http.Client,
db: Db,
rand: std.rand.Random,
rsa: *c.RSA,
x509: *c.X509,
default_skin_url: []const u8,
user_cache: UserCache,
user_cache_mtx: std.Thread.Mutex = .{},

const State = @This();

pub const TextureUrls = struct {
    skin_url: ?[]const u8,
    cape_url: ?[]const u8,
};

/// Gets the skin URL for a given user, if the user has a skin URL set. May do network IO for checking.
pub fn getTextureUrls(self: *State, username: []const u8, uuid: UUID) !TextureUrls {
    self.user_cache_mtx.lock();
    defer self.user_cache_mtx.unlock();

    if (self.user_cache.get(username)) |entry| {
        if (std.time.milliTimestamp() < entry.expiration) {
            return .{
                .skin_url = entry.skin_url,
                .cape_url = entry.cape_url,
            };
        }

        if (entry.skin_url) |skin| self.allocator.free(skin);
        if (entry.cape_url) |cape| self.allocator.free(cape);
        std.debug.assert(self.user_cache.remove(username));
    }

    std.log.info("checking presence of custom skin and cape for user '{s}'", .{username});

    const skin_url = skin: {
        const skin_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/.anvilauth/raw/branch/master/skin.png",
            .{ self.forgejo_url, username },
        );
        errdefer self.allocator.free(skin_url);

        const skin_res = try self.http.fetch(.{
            .method = .HEAD,
            .location = .{ .url = skin_url },
        });

        if (skin_res.status == .ok)
            break :skin skin_url;

        self.allocator.free(skin_url);
        break :skin null;
    };
    errdefer if (skin_url) |url| self.allocator.free(url);

    const cape_url = cape: {
        if (self.anvillib_url == null) break :cape null;

        const extra_headers = [_]std.http.Header{
            .{ .name = "X-AnvilLib-Version", .value = "0.2.0" },
            .{ .name = "X-Minecraft-Version", .value = "0.0.0-anvilauth" },
        };

        var header_buf: [1024]u8 = undefined;
        const cape_id = players: {
            const players_url = try std.fmt.allocPrint(
                self.allocator,
                "{s}/data/players/{s}",
                .{ self.anvillib_url.?, &uuid.toStringWithDashes() },
            );
            defer self.allocator.free(players_url);

            var players_req = try self.http.open(
                .GET,
                try std.Uri.parse(players_url),
                .{
                    .server_header_buffer = &header_buf,
                    .extra_headers = &extra_headers,
                },
            );
            defer players_req.deinit();
            try players_req.send();
            try players_req.wait();

            if (players_req.response.status != .ok) {
                break :players null;
            }

            var players_json_reader = std.json.reader(self.allocator, players_req.reader());
            defer players_json_reader.deinit();

            const players_parsed = try std.json.parseFromTokenSource(
                struct { cape: ?[]const u8 },
                self.allocator,
                &players_json_reader,
                .{ .ignore_unknown_fields = true },
            );
            defer players_parsed.deinit();

            break :players if (players_parsed.value.cape) |cape|
                try self.allocator.dupe(u8, cape)
            else
                null;
        };
        defer if (cape_id) |u| self.allocator.free(u);

        if (cape_id == null) break :cape null;

        const capes_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/data/capes/{s}",
            .{ self.anvillib_url.?, cape_id.? },
        );
        defer self.allocator.free(capes_url);

        var capes_req = try self.http.open(
            .GET,
            try std.Uri.parse(capes_url),
            .{
                .server_header_buffer = &header_buf,
                .extra_headers = &extra_headers,
            },
        );
        defer capes_req.deinit();

        try capes_req.send();
        try capes_req.wait();

        var capes_json_reader = std.json.reader(self.allocator, capes_req.reader());
        defer capes_json_reader.deinit();

        const capes_parsed = try std.json.parseFromTokenSource(
            struct { url: []const u8 },
            self.allocator,
            &capes_json_reader,
            .{ .ignore_unknown_fields = true },
        );
        defer capes_parsed.deinit();

        break :cape try self.allocator.dupe(u8, capes_parsed.value.url);
    };
    errdefer if (cape_url) |cape| self.allocator.free(cape);

    const username_d = try self.allocator.dupe(u8, username);
    errdefer self.allocator.free(username_d);
    try self.user_cache.putNoClobber(self.allocator, username_d, .{
        .cape_url = cape_url,
        .skin_url = skin_url,
        .expiration = std.time.milliTimestamp() + std.time.ms_per_day,
    });

    return .{
        .skin_url = skin_url,
        .cape_url = cape_url,
    };
}
