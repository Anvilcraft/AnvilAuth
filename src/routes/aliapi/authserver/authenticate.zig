const std = @import("std");
const c = ffi.c;

const UUID = @import("uuid").Uuid;

const ffi = @import("../../../ffi.zig");
const conutil = @import("../../../conutil.zig");

const State = @import("../../../State.zig");
const UserID = @import("../../../UserID.zig");
const UserResponse = @import("../../../util/UserResponse.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/aliapi/authserver/authenticate");
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
        username: UserID,
        password: []const u8,
        clientToken: ?[:0]const u8 = null,
        requestUser: bool = false,
    };

    var req_payload = try conutil.parseJsonPayloadOrRepondErr(
        Request,
        state.allocator,
        req,
    ) orelse return;
    defer req_payload.deinit();

    std.log.info("authentification attempt from user {}", .{req_payload.value.username});

    if (req_payload.value.username.domain == null)
        req_payload.value.username.domain = state.domain;

    const valid = valid: {
        if (!std.mem.eql(u8, req_payload.value.username.domain.?, state.domain))
            break :valid false;

        const sel_dbret = state.db.execParams(
            \\SELECT 1
            \\FROM users, tokens
            \\WHERE
            \\  tokens.id = $1::text AND
            \\  users.name = $2::text AND
            \\  tokens.userid = users.id;
        , .{ req_payload.value.password, req_payload.value.username.name });
        defer sel_dbret.deinit();
        try sel_dbret.expectTuples();

        if (sel_dbret.cols() != 1) return error.InvalidResultFromPostgresServer;

        const valid = sel_dbret.rows() > 0;

        const set_last_use_dbret = state.db.execParams(
            \\UPDATE tokens
            \\SET last_use = EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)
            \\WHERE id = $1::text;
        , .{req_payload.value.password});
        defer set_last_use_dbret.deinit();
        try set_last_use_dbret.expectCommand();

        break :valid valid;
    };

    if (valid) {
        std.log.info("issuing new token", .{});

        // Get user UUID
        const sel_result = state.db.execParams(
            "SELECT id FROM users WHERE name = $1::text;",
            .{req_payload.value.username.name},
        );
        defer sel_result.deinit();
        try sel_result.expectTuples();

        if (sel_result.rows() != 1 or sel_result.cols() != 1)
            return error.InvalidResultFromPostgresServer;

        const userid = sel_result.get(UUID, 0, 0);

        const Profile = struct {
            name: UserID,
            id: []const u8,
        };

        const ResponsePayload = struct {
            user: ?UserResponse,
            clientToken: []const u8,
            accessToken: []const u8,
            availableProfiles: []const Profile,
            selectedProfile: Profile,
        };

        var gen_token_buf: [32:0]u8 = undefined;
        const client_token: [:0]const u8 = req_payload.value.clientToken orelse gentoken: {
            // According to https://wiki.vg/Legacy_Mojang_Authentication, the normal server
            // would invalidate all existing tokens here. This makes no sense, so we don't do it.
            var rand_bytes: [16]u8 = undefined;
            state.rand.bytes(&rand_bytes);
            @memcpy(&gen_token_buf, &UUID.fromRawBytes(4, rand_bytes)
                .toStringCompact());
            break :gentoken &gen_token_buf;
        };

        // remains valid for one week
        const expiry = std.time.timestamp() + std.time.s_per_week;

        var tokenid_bytes: [16]u8 = undefined;
        state.rand.bytes(&tokenid_bytes);
        const tokenid = UUID.fromRawBytes(4, tokenid_bytes);

        const add_tok_stat = state.db.execParams(
            \\INSERT INTO sessions (id, userid, expiry, client_token)
            \\  VALUES ($1::uuid, $2::uuid, $3::bigint, $4::text);
        ,
            .{ tokenid, userid, expiry, client_token },
        );
        defer add_tok_stat.deinit();
        try add_tok_stat.expectCommand();

        const uid_hex = userid.toStringCompact();

        const profile = Profile{
            .name = req_payload.value.username,
            .id = &uid_hex,
        };

        const res_payload = ResponsePayload{
            .user = if (req_payload.value.requestUser) .{
                .username = req_payload.value.username.name,
                .id = &uid_hex,
            } else null,
            .clientToken = client_token,
            .accessToken = &tokenid.toStringCompact(),
            .availableProfiles = &.{profile},
            .selectedProfile = profile,
        };

        const data = try std.json.stringifyAlloc(
            state.allocator,
            res_payload,
            .{ .emit_null_optional_fields = false },
        );
        defer state.allocator.free(data);

        try req.respond(data, .{
            .extra_headers = &.{.{
                .name = "Content-Type",
                .value = "application/json",
            }},
        });
    } else {
        std.log.warn("user invalid", .{});

        // .forbidden makes no sense here, but that was mojank's idea
        try conutil.sendJsonError(req, .forbidden, "invalid credentials", .{});
    }
}
