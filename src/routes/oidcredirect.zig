const std = @import("std");

const UUID = @import("uuid").Uuid;

const State = @import("../State.zig");

const conutil = @import("../conutil.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/oidcredirect");
}

const Userinfo = struct {
    sub: []const u8,
    preferred_username: ?[]const u8 = null,
    anvilauth_skin: ?[]const u8 = null,
};

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const req_url = try std.Uri.parseAfterScheme("", req.head.target);
    const params = conutil.parseQueryParametersFromUri(
        req_url,
        struct { code: []const u8 },
    ) catch |e| {
        try conutil.sendJsonError(req, .bad_request, "invalid query parameters: {}", .{e});
        return;
    };

    const userinfo = try requestUserinfo(state, params.code);
    defer userinfo.deinit();

    var skin_uri: ?[]const u8 = null;
    if (userinfo.value.anvilauth_skin) |maybe_skin_uri| {
        if (std.Uri.parse(maybe_skin_uri)) |_| {
            skin_uri = maybe_skin_uri;
        } else |e| {
            std.log.warn("OIDC provider returned invalid URL for anvilauth_skin: {}", .{e});
        }
    }

    // check if user exists, get ID
    const query_user_dbret = state.db.execParams(
        \\SELECT id FROM users WHERE oidc_sub = $1::text;
    , .{userinfo.value.sub});
    defer query_user_dbret.deinit();
    try query_user_dbret.expectTuples();
    if (query_user_dbret.cols() != 1) return error.InvalidResultFromPostgresServer;

    const username = userinfo.value.preferred_username orelse userinfo.value.sub;

    var user_id: UUID = .{ .bytes = @splat(0) };
    if (query_user_dbret.rows() > 0) { // User exists, update values
        user_id = query_user_dbret.get(UUID, 0, 0);

        std.log.info("updating user {s}", .{username});
        const update_user_dbret = state.db.execParams(
            \\UPDATE users SET name = $1::text, skin_uri = $2::text WHERE id = $3::uuid;
        , .{
            username,
            skin_uri,
            user_id,
        });
        defer update_user_dbret.deinit();
        try update_user_dbret.expectCommand();
    } else { // User doesn't exist, create new one
        std.log.info("creating new user {s}", .{username});
        state.rand.bytes(&user_id.bytes);
        user_id = UUID.fromRawBytes(4, user_id.bytes);
        const create_user_dbret = state.db.execParams(
            \\INSERT INTO users (id, oidc_sub, name, skin_uri)
            \\VALUES ($1::uuid, $2::text, $3::text, $4::text);
        , .{
            user_id,
            userinfo.value.sub,
            username,
            skin_uri,
        });
        defer create_user_dbret.deinit();
        try create_user_dbret.expectCommand();
    }

    // Create token
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01234567890";
    var token_id: [32]u8 = undefined;
    for (&token_id) |*ch| {
        ch.* = alphabet[state.rand.uintAtMost(u8, alphabet.len)];
    }

    const mktoken_dbret = state.db.execParams(
        \\INSERT INTO tokens (id, userid, creation, last_use)
        \\VALUES (
        \\  $1::text,
        \\  $2::uuid,
        \\  EXTRACT(EPOCH FROM CURRENT_TIMESTAMP),
        \\  EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)
        \\);
    , .{ @as([]const u8, &token_id), user_id });
    defer mktoken_dbret.deinit();
    try mktoken_dbret.expectCommand();

    const response = try std.fmt.allocPrint(state.allocator,
        \\<html><head><title>Token Created</title></head><body>
        \\<p>Success!</p>
        \\<p>User ID: {s}</p>
        \\<p>Username: {s}</p>
        \\<p>Token: {s}</p>
        \\</body></html>
    , .{
        &user_id.toStringCompact(),
        username,
        token_id,
    });
    defer state.allocator.free(response);

    try req.respond(response, .{
        .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "text/html",
        }},
    });
}

fn requestUserinfo(state: *State, code: []const u8) !std.json.Parsed(Userinfo) {
    const accept_hdr = std.http.Header{
        .name = "Accept",
        .value = "application/json",
    };

    var header_buf: [1024]u8 = undefined;
    const token_res = token: {
        const auth_hdr_raw = try std.fmt.allocPrint(
            state.allocator,
            "{s}:{s}",
            .{ state.oidc.id, state.oidc.secret },
        );
        defer state.allocator.free(auth_hdr_raw);

        var auth_hdr = std.ArrayList(u8).init(state.allocator);
        defer auth_hdr.deinit();

        try auth_hdr.appendSlice("Basic ");
        try std.base64.standard.Encoder.encodeWriter(auth_hdr.writer(), auth_hdr_raw);

        const body = try std.fmt.allocPrint(
            state.allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={%}%2Foidcredirect",
            .{ code, std.Uri.Component{ .raw = state.base_url } },
        );
        defer state.allocator.free(body);

        var token_req = try state.http.open(.POST, state.oidc_config.token_endpoint, .{
            .headers = .{
                .authorization = .{ .override = auth_hdr.items },
                .content_type = .{ .override = "application/x-www-form-urlencoded" },
            },
            .extra_headers = &.{accept_hdr},
            .server_header_buffer = &header_buf,
        });
        defer token_req.deinit();

        token_req.transfer_encoding = .{ .content_length = body.len };
        try token_req.send();

        try token_req.writeAll(body);
        try token_req.finish();
        try token_req.wait();

        var buf_reader = std.io.bufferedReader(token_req.reader());
        var json_reader = std.json.reader(state.allocator, buf_reader.reader());
        defer json_reader.deinit();

        break :token try std.json.parseFromTokenSource(
            struct {
                access_token: []const u8,
            },
            state.allocator,
            &json_reader,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    };
    defer token_res.deinit();

    const auth_hdr = try std.fmt.allocPrint(
        state.allocator,
        "Bearer {s}",
        .{token_res.value.access_token},
    );
    defer state.allocator.free(auth_hdr);

    var userinfo_req = try state.http.open(.GET, state.oidc_config.userinfo_endpoint, .{
        .headers = .{ .authorization = .{ .override = auth_hdr } },
        .extra_headers = &.{accept_hdr},
        .server_header_buffer = &header_buf,
    });

    try userinfo_req.send();
    try userinfo_req.finish();
    try userinfo_req.wait();

    var buf_reader = std.io.bufferedReader(userinfo_req.reader());
    var json_reader = std.json.reader(state.allocator, buf_reader.reader());
    defer json_reader.deinit();

    return try std.json.parseFromTokenSource(
        Userinfo,
        state.allocator,
        &json_reader,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always,  },
    );
}
