const std = @import("std");
const c = ffi.c;

const ffi = @import("../../../../../ffi.zig");
const conutil = @import("../../../../../conutil.zig");

const Id = @import("../../../../../Id.zig");
const JsonUserProfile = @import("../../../../../JsonUserProfile.zig");
const State = @import("../../../../../State.zig");

const path_prefix = "/aliapi/sessionserver/session/minecraft/profile/";

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, path_prefix);
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const req_url = try std.Uri.parseWithoutScheme(req.head.target);

    // This is sound as we only go here if the path starts with path_prefix.
    const profile_id = Id.parse(req_url.path[path_prefix.len..]) orelse {
        try conutil.sendJsonError(
            req,
            .bad_request,
            "not a valid UUID: {s} (NOTE: AnvilAuth technically doesn't use UUIDs, this endpoint expects 16 hex-encoded, undelimited bytes.)",
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

        const uprofile = try JsonUserProfile.init(
            state.allocator,
            profile_id,
            username,
            skin_url orelse state.default_skin_url,
            if (unsigned) null else state.rsa,
        );
        defer uprofile.deinit(state.allocator);

        const response_data = try std.json.stringifyAlloc(
            state.allocator,
            uprofile,
            .{ .emit_null_optional_fields = false },
        );
        defer state.allocator.free(response_data);

        try req.respond(response_data, .{
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
