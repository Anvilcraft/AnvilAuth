const std = @import("std");
const c = ffi.c;

const UUID = @import("uuid").Uuid;

const ffi = @import("../../../ffi.zig");
const conutil = @import("../../../conutil.zig");

const State = @import("../../../State.zig");
const UserID = @import("../../../UserID.zig");

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

    var json_reader = std.json.reader(state.allocator, try req.reader());
    defer json_reader.deinit();
    var req_payload = std.json.parseFromTokenSource(Request, state.allocator, &json_reader, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        try conutil.sendJsonError(req, .bad_request, "unable to parse JSON payload: {}", .{e});
        return;
    };
    defer req_payload.deinit();

    std.log.info("authentification attempt from user {}", .{req_payload.value.username});

    if (req_payload.value.username.domain == null)
        req_payload.value.username.domain = state.domain;

    const valid = valid: {
        if (req_payload.value.username.domain == null or
            !std.mem.eql(u8, req_payload.value.username.domain.?, state.domain))
            break :valid false;

        const forgejo_url = try std.fmt.allocPrint(state.allocator, "{s}/api/v1/user", .{state.forgejo_url});
        defer state.allocator.free(forgejo_url);

        const unenc_auth = try std.fmt.allocPrint(
            state.allocator,
            "{s}:{s}",
            .{ req_payload.value.username.name, req_payload.value.password },
        );
        defer state.allocator.free(unenc_auth);

        const auth_prefix = "Basic ";
        const auth_str = try state.allocator.alloc(
            u8,
            auth_prefix.len + std.base64.standard.Encoder.calcSize(unenc_auth.len),
        );
        defer state.allocator.free(auth_str);

        @memcpy(auth_str[0..auth_prefix.len], auth_prefix);
        _ = std.base64.standard.Encoder.encode(auth_str[auth_prefix.len..], unenc_auth);

        var fres = try state.http.fetch(.{
            .location = .{ .url = forgejo_url },
            .extra_headers = &.{.{
                .name = "Authorization",
                .value = auth_str,
            }},
        });

        break :valid fres.status.class() == .success;
    };

    if (valid) {
        std.log.info("issuing new token", .{});
        // Ensure user record exists
        const insert_result = state.db.execParams(
            "INSERT INTO users (id, name) VALUES (gen_random_uuid(), $1) ON CONFLICT DO NOTHING;",
            .{req_payload.value.username.name},
        );
        defer insert_result.deinit();
        try insert_result.expectCommand();

        // Get user UUID
        const sel_result = state.db.execParams(
            "SELECT id FROM users WHERE name=$1::text;",
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
            user: ?struct {
                username: []const u8,
                properties: []const struct {
                    name: []const u8,
                    value: []const u8,
                },
                id: []const u8,
            } = null,
            clientToken: []const u8,
            accessToken: []const u8,
            availableProfiles: []const Profile,
            selectedProfile: Profile,
        };

        var gen_token_buf: [32:0]u8 = undefined;
        const client_token: [:0]const u8 = req_payload.value.clientToken orelse gentoken: {
            // TODO: according to https://wiki.vg/Legacy_Mojang_Authentication, the normal server
            // would invalidate all existing tokens here. This makes no sense, so we don't do it.
            var rand_bytes: [16]u8 = undefined;
            state.rand.bytes(&rand_bytes);
            @memcpy(&gen_token_buf, &UUID.fromRawBytes(4, rand_bytes)
                .toStringCompact());
            break :gentoken &gen_token_buf;
        };

        // remains valid for one week
        const expiry = std.time.timestamp() + std.time.ms_per_week;

        var tokenid_bytes: [16]u8 = undefined;
        state.rand.bytes(&tokenid_bytes);
        const tokenid = UUID.fromRawBytes(4, tokenid_bytes);

        const add_tok_stat = state.db.execParams(
            \\INSERT INTO tokens (id, userid, expiry, client_token)
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
                .properties = &.{
                    // There is no acceptable real-world use-case where this would be incorrect.
                    .{
                        .name = "preferredLanguage",
                        .value = "en",
                    },
                },
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
