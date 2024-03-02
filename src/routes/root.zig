const std = @import("std");

const State = @import("../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const base_url = try std.fmt.allocPrint(state.allocator, "{s}/aliapi", .{state.base_url});
    defer state.allocator.free(base_url);

    try req.respond("", .{
        .extra_headers = &.{.{
            .name = "x-authlib-injector-api-location",
            .value = base_url,
        }},
    });
}
