const std = @import("std");
const c = ffi.c;

const conutil = @import("../../../../../conutil.zig");
const ffi = @import("../../../../../ffi.zig");

const Id = @import("../../../../../Id.zig");
const jsonUserWriter = @import("../../../../../json_user_writer.zig").jsonUserWriter;
const State = @import("../../../../../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/aliapi/sessionserver/session/minecraft/hasJoined");
}

// TODO: case-correct username in response
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

        var profile_json = std.ArrayList(u8).init(state.allocator);
        defer profile_json.deinit();
        var uprofile = jsonUserWriter(state.allocator, profile_json.writer(), state.rsa);
        try uprofile.writeHeaderAndStartProperties(id, params.username);
        try uprofile.texturesProperty(
            id,
            params.username,
            skin_url orelse state.default_skin_url,
        );
        try uprofile.finish();

        try req.respond(profile_json.items, .{ .extra_headers = &.{.{
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
