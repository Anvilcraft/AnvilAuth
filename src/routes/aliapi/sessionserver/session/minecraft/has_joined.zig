const std = @import("std");
const c = ffi.c;

const UUID = @import("uuid").Uuid;

const conutil = @import("../../../../../conutil.zig");
const ffi = @import("../../../../../ffi.zig");

const jsonUserWriter = @import("../../../../../json_user_writer.zig").jsonUserWriter;
const State = @import("../../../../../State.zig");
const UserID = @import("../../../../../UserID.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/aliapi/sessionserver/session/minecraft/hasJoined");
}

// TODO: case-correct username in response
pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const req_url = try std.Uri.parseAfterScheme("", req.head.target);
    const params = conutil.parseQueryParametersFromUri(req_url, struct {
        serverId: []const u8,
        username: []const u8,
    }) catch |e| {
        try conutil.sendJsonError(req, .bad_request, "invalid query parameters: {}", .{e});
        return;
    };

    const userid = UserID.parse(params.username) catch |e| {
        try conutil.sendJsonError(
            req,
            .bad_request,
            "username parameter is invalid: {s}",
            .{@errorName(e)},
        );
        return;
    };

    if (userid.domain != null and std.mem.eql(u8, userid.domain.?, state.domain)) {
        const sel_dbret = state.db.execParams(
            \\SELECT users.id
            \\FROM users, joins
            \\WHERE
            \\  joins.userid = users.id AND
            \\  users.name = $1::text AND
            \\  joins.serverid = $2::text;
        , .{ userid.name, params.serverId });
        defer sel_dbret.deinit();
        try sel_dbret.expectTuples();

        if (sel_dbret.cols() != 1) return error.InvalidResultFromPostgresServer;

        if (sel_dbret.rows() >= 1) {
            const id = sel_dbret.get(UUID, 0, 0);

            const texture_urls = try state.getTextureUrls(userid.name, id);

            var profile_json = std.ArrayList(u8).init(state.allocator);
            defer profile_json.deinit();
            var uprofile = jsonUserWriter(state.allocator, profile_json.writer(), state.rsa);
            try uprofile.writeHeaderAndStartProperties(id, params.username);
            try uprofile.texturesProperty(
                id,
                params.username,
                texture_urls.skin_url orelse state.default_skin_url,
                texture_urls.cape_url,
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
    } else {
        // TODO: federation
        try req.respond("", .{
            .status = .no_content,
        });
    }
}
