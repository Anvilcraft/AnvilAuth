const std = @import("std");
const c = ffi.c;

const conutil = @import("../../../../../conutil.zig");
const ffi = @import("../../../../../ffi.zig");

const Id = @import("../../../../../Id.zig");
const State = @import("../../../../../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/aliapi/sessionserver/session/minecraft/join");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const Request = struct {
        accessToken: []const u8,
        selectedProfile: []const u8,
        serverId: [:0]const u8,
    };

    var json_reader = std.json.reader(state.allocator, try req.reader());
    defer json_reader.deinit();
    const req_payload = std.json.parseFromTokenSource(Request, state.allocator, &json_reader, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        try conutil.sendJsonError(req, .bad_request, "unable to parse JSON payload: {}", .{e});
        return;
    };
    defer req_payload.deinit();

    const access_token = Id.parse(req_payload.value.accessToken) orelse {
        try conutil.sendJsonError(req, .bad_request, "accessToken is not a valid ID!", .{});
        return;
    };

    const sel_profile = Id.parse(req_payload.value.selectedProfile) orelse {
        try conutil.sendJsonError(req, .bad_request, "selectedProfile is not a valid ID!", .{});
        return;
    };

    const dbret = state.db.execParams("SELECT userid FROM tokens WHERE id=$1::uuid;", .{access_token});
    defer dbret.deinit();
    try dbret.expectTuples();

    if (dbret.cols() != 1) return error.InvalidResultFromPostgresServer;

    if (dbret.rows() >= 1) {
        const token_user = dbret.get(Id, 0, 0);
        if (std.mem.eql(u8, &sel_profile.bytes, &token_user.bytes)) {
            const ins_dbret = state.db.execParams(
                \\INSERT INTO joins (userid, serverid)
                \\VALUES ($1::uuid, $2::text)
                \\ON CONFLICT (userid) DO
                \\UPDATE SET serverid = EXCLUDED.serverid;
            , .{ token_user, req_payload.value.serverId });
            defer ins_dbret.deinit();
            try ins_dbret.expectCommand();

            try req.respond("", .{ .status = .no_content });
        } else {
            // acces token belongs to other user (hehe)
            try conutil.sendJsonError(req, .forbidden, "invalid access token!", .{});
        }
    } else {
        // invalid access token
        try conutil.sendJsonError(req, .forbidden, "invalid access token!", .{});
    }
}
