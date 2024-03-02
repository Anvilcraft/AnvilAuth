const std = @import("std");
const assets = @import("assets");

const State = @import("../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/default_skin");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    _ = state;

    try req.respond(assets.steve_skin, .{
        .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "image/png",
        }},
    });
}
