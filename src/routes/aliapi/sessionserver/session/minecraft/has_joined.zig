const std = @import("std");
const c = ffi.c;

const conutil = @import("../../../../../conutil.zig");
const ffi = @import("../../../../../ffi.zig");

const Id = @import("../../../../../Id.zig");
const JsonUserProfile = @import("../../../../../JsonUserProfile.zig");
const State = @import("../../../../../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/aliapi/sessionserver/session/minecraft/hasJoined");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const req_url = try std.Uri.parseWithoutScheme(req.head.target);
    const params = conutil.parseQueryParametersFromUri(req_url, struct {
        serverId: []const u8,
        username: []const u8,
    }) catch |e| {
        try conutil.sendJsonError(req, .bad_request, "invalid query parameters: {}", .{e});
        return;
    };

    const sel_dbret = state.db.execParams(
        \\SELECT users.id
        \\FROM users, joins
        \\WHERE
        \\  joins.userid = users.id AND
        \\  users.name = $1::text AND
        \\  joins.serverid = $2::text;
    , .{ params.username, params.serverId });
    defer sel_dbret.deinit();
    try sel_dbret.expectTuples();

    if (sel_dbret.cols() != 1) return error.InvalidResultFromPostgresServer;

    if (sel_dbret.rows() >= 1) {
        const id = sel_dbret.get(Id, 0, 0);

        const skin_url = try state.getSkinUrl(params.username);
        defer if (skin_url) |url| state.allocator.free(url);

        const profile = try JsonUserProfile.init(
            state.allocator,
            id,
            params.username,
            skin_url orelse state.default_skin_url,
            state.rsa,
        );
        defer profile.deinit(state.allocator);

        const profile_json = try std.json.stringifyAlloc(
            state.allocator,
            profile,
            .{ .emit_null_optional_fields = false },
        );
        defer state.allocator.free(profile_json);

        try req.respond(profile_json, .{ .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "application/json",
        }} });

        const del_dbret = state.db.execParams("DELETE FROM joins WHERE userid = $1::uuid;", .{id});
        defer del_dbret.deinit();
        try del_dbret.expectCommand();
    } else {
        // task failed successfully! (good api design, mojank!)
        try req.respond("", .{
            .status = .no_content,
        });
    }
}
