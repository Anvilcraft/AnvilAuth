const std = @import("std");
const c = ffi.c;

const UUID = @import("uuid").Uuid;

const ffi = @import("../../../ffi.zig");
const conutil = @import("../../../conutil.zig");

const State = @import("../../../State.zig");
const UserID = @import("../../../UserID.zig");
const UserResponse = @import("../../../util/UserResponse.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/aliapi/authserver/refresh");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    if (req.head.method != .POST) {
        try conutil.sendJsonError(
            req,
            .method_not_allowed,
            "only POST requests are allowed to this endpoint!",
            .{},
        );
        return;
    }

    const Request = struct {
        accessToken: []const u8,
        clientToken: []const u8,
        requestUser: bool = false,
    };

    const req_payload = try conutil.parseJsonPayloadOrRepondErr(
        Request,
        state.allocator,
        req,
    ) orelse return;
    defer req_payload.deinit();

    const access_token = UUID.fromString(req_payload.value.accessToken) catch {
        try conutil.sendJsonError(req, .bad_request, "accessToken is not a valid UUID!", .{});
        return;
    };

    const query_dbret = state.db.execParams(
        \\SELECT sessions.expiry, users.id, users.name
        \\FROM sessions, users
        \\WHERE
        \\  sessions.id = $1::uuid AND
        \\  sessions.client_token = $2::text AND
        \\  users.id = sessions.userid;
    , .{ access_token, req_payload.value.clientToken });
    defer query_dbret.deinit();
    try query_dbret.expectTuples();

    if (query_dbret.cols() != 3) return error.InvalidResultFromPostgresServer;

    const now = std.time.timestamp();
    if (query_dbret.rows() < 1 or query_dbret.get(i64, 0, 0) < now) {
        try conutil.sendJsonError(req, .forbidden, "Token does not exist", .{});
        return;
    }

    const userid = query_dbret.get(UUID, 0, 1);

    var uuid_buf: [16]u8 = undefined;
    state.rand.bytes(&uuid_buf);
    const uuid = UUID.fromRawBytes(4, uuid_buf);

    const expiry = now + std.time.s_per_week;

    const create_dbret = state.db.execParams(
        \\INSERT INTO sessions (id, userid, expiry, client_token)
        \\VALUES ($1::uuid, $2::uuid, $3::bigint, $4::text);
    , .{ uuid, userid, expiry, req_payload.value.clientToken });
    defer create_dbret.deinit();
    try create_dbret.expectCommand();

    const rm_dbret = state.db.execParams(
        "DELETE FROM sessions WHERE id = $1::uuid;",
        .{access_token},
    );
    defer rm_dbret.deinit();
    try rm_dbret.expectCommand();

    const userid_str = userid.toStringCompact();
    const uuid_str = uuid.toStringCompact();
    const username = try std.fmt.allocPrint(state.allocator, "{s}@{s}", .{
        query_dbret.get([]const u8, 0, 2),
        state.domain,
    });
    defer state.allocator.free(username);
    const res_payload = .{
        .clientToken = req_payload.value.clientToken,
        .accessToken = &uuid_str,
        .selectedProfile = .{ .name = username, .id = &userid_str },
        .user = if (req_payload.value.requestUser) UserResponse{
            .username = username,
            .id = &userid_str,
        } else null,
    };

    const res_json = try std.json.stringifyAlloc(
        state.allocator,
        res_payload,
        .{ .emit_null_optional_fields = false },
    );
    defer state.allocator.free(res_json);

    try req.respond(res_json, .{
        .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}
