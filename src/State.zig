const std = @import("std");
const c = @import("ffi.zig").c;

const Db = @import("Db.zig");

pub const SkinCache = std.StringHashMapUnmanaged(struct { has_skin: bool, expiration: i64 });

allocator: std.mem.Allocator,
base_url: []const u8,
forgejo_url: []const u8,
skin_domains: []const []const u8,
server_name: []const u8,
http: std.http.Client,
db: Db,
rand: std.rand.Random,
rsa: *c.RSA,
x509: *c.X509,
default_skin_url: []const u8,
skin_cache: SkinCache,
skin_cache_mtx: std.Thread.Mutex = .{},

const State = @This();

/// Gets the skin URL for a given user, if the user has a skin URL set. May do network IO for checking.
pub fn getSkinUrl(self: *State, username: []const u8) !?[]const u8 {
    self.skin_cache_mtx.lock();
    defer self.skin_cache_mtx.unlock();

    const url = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/.anvilauth/raw/branch/master/skin.png",
        .{ self.forgejo_url, username },
    );
    errdefer self.allocator.free(url);

    if (self.skin_cache.get(username)) |entry| {
        if (std.time.milliTimestamp() < entry.expiration) {
            if (entry.has_skin)
                return url;

            self.allocator.free(url);
            return null;
        }
    }

    const res = try self.http.fetch(.{
        .method = .HEAD,
        .location = .{ .url = url },
    });

    const username_d = try self.allocator.dupe(u8, username);
    errdefer self.allocator.free(username_d);
    try self.skin_cache.put(self.allocator, username_d, .{
        .has_skin = res.status == .ok,
        .expiration = std.time.milliTimestamp() + std.time.ms_per_day,
    });

    if (res.status == .ok)
        return url;

    self.allocator.free(url);
    return null;
}
