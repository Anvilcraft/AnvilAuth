const std = @import("std");
const c = ffi.c;

const UUID = @import("uuid").Uuid;

const ffi = @import("../../../../../ffi.zig");
const conutil = @import("../../../../../conutil.zig");

const jsonUserWriter = @import("../../../../../json_user_writer.zig").jsonUserWriter;
const State = @import("../../../../../State.zig");

const path_prefix = "/aliapi/sessionserver/session/minecraft/profile/";

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, path_prefix);
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const req_url = try std.Uri.parseWithoutScheme(req.head.target);

    // This is sound as we only go here if the path starts with path_prefix.
    const profile_id = UUID.fromString(req_url.path[path_prefix.len..]) catch {
        try conutil.sendJsonError(
            req,
            .bad_request,
            "not a valid UUID: {s}",
            .{req_url.path[path_prefix.len..]},
        );
        return;
    };

    const unsigned = unsigned: {
        if (req_url.query == null) break :unsigned true;

        const params = conutil.parseQueryParametersOrDefaults(
            req_url.query.?,
            struct { unsigned: []const u8 = "true" },
        ) catch |e| {
            try conutil.sendJsonError(req, .bad_request, "invalid query parameters: {}", .{e});
            return;
        };

        if (std.mem.eql(u8, params.unsigned, "true")) {
            break :unsigned true;
        } else if (std.mem.eql(u8, params.unsigned, "false")) {
            break :unsigned false;
        } else {
            try conutil.sendJsonError(
                req,
                .bad_request,
                "`unsigned` parameter must be either `true` or `false`, got `{s}`",
                .{params.unsigned},
            );
            return;
        }
    };

    const status = state.db.execParams(
        "SELECT name FROM users WHERE id=$1::uuid;",
        .{profile_id},
    );
    defer status.deinit();
    try status.expectTuples();

    if (status.cols() != 1) return error.InvalidResultFromPostgresServer;

    if (status.rows() >= 1) {
        const username = status.get([]const u8, 0, 0);

        const skin_url = try state.getSkinUrl(username);
        defer if (skin_url) |url| state.allocator.free(url);

        var response_data = std.ArrayList(u8).init(state.allocator);
        defer response_data.deinit();
        var uprofile = jsonUserWriter(
            state.allocator,
            response_data.writer(),
            if (unsigned) null else state.rsa,
        );
        try uprofile.writeHeaderAndStartProperties(profile_id, username);
        try uprofile.texturesProperty(
            profile_id,
            username,
            skin_url orelse state.default_skin_url,
        );
        try uprofile.finish();

        try req.respond(response_data.items, .{
            .extra_headers = &.{.{
                .name = "Content-Type",
                .value = "application/json",
            }},
        });
    } else {
        // -> User not found
        // This retarded API design brought to you by Mojang!
        try req.respond("", .{ .status = .no_content });
    }
}
