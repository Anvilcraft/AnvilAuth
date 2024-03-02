const std = @import("std");
const c = ffi.c;

const ffi = @import("ffi.zig");

const Config = @import("Config.zig");
const Db = @import("Db.zig");
const State = @import("State.zig");

pub const std_options = std.Options{
    .log_level = if (@import("builtin").mode == .Debug) .debug else .info,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const confpath = conf: {
        var argiter = try std.process.argsWithAllocator(alloc);
        defer argiter.deinit();
        _ = argiter.next() orelse unreachable;

        const confpath = argiter.next() orelse {
            std.log.err("Need a config argument!", .{});
            return error.InvalidArgs;
        };
        const confpath_d = try alloc.dupe(u8, confpath);
        errdefer alloc.free(confpath_d);

        if (argiter.next()) |_| {
            std.log.err("Too many arguments!", .{});
            return error.InvalidArgs;
        }

        break :conf confpath_d;
    };
    defer alloc.free(confpath);

    var conffile = try std.fs.cwd().openFile(confpath, .{});
    defer conffile.close();

    var json_reader = std.json.reader(alloc, conffile.reader());
    defer json_reader.deinit();

    const config_parsed = try std.json.parseFromTokenSource(
        Config,
        alloc,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    );
    defer config_parsed.deinit();

    const postgres_con = c.PQconnectdb(config_parsed.value.postgres_url) orelse unreachable;
    defer c.PQfinish(postgres_con);

    if (c.PQstatus(postgres_con) != c.CONNECTION_OK) {
        std.log.err("connecting to DB: {s}", .{c.PQerrorMessage(postgres_con)});
        return error.DatabaseConnect;
    }

    _ = c.PQsetNoticeReceiver(postgres_con, ffi.libpqNoticeReceiverCb, null);

    const db = Db{ .con = postgres_con };

    std.log.info("initializing database", .{});
    try db.initDb();

    var rand = rand: {
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        break :rand std.rand.DefaultCsprng.init(seed);
    };

    const rsa = c.RSA_new() orelse return error.OutOfMemory;
    {
        errdefer c.RSA_free(rsa);

        const bn = c.BN_new() orelse return error.OutOfMemory;
        defer c.BN_free(bn);

        if (c.BN_set_word(bn, c.RSA_F4) != 1) return error.OpenSSLBorked;
        if (c.RSA_generate_key_ex(rsa, 1024 * 4, bn, null) != 1) return error.OpenSSLBorked;
    }

    const pkey = c.EVP_PKEY_new() orelse return error.OutOfMemory;
    defer c.EVP_PKEY_free(pkey);

    if (c.EVP_PKEY_assign_RSA(pkey, rsa) != 1) return error.OpenSSLBorked;

    const x509 = c.X509_new() orelse return error.OutOfMemory;
    defer c.X509_free(x509);

    {
        if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(x509), 1) != 1) return error.OpenSSLBorked;
        _ = c.X509_gmtime_adj(c.X509_get_notBefore(x509), 0);
        _ = c.X509_gmtime_adj(c.X509_get_notAfter(x509), std.time.s_per_day * 365);
        if (c.X509_set_pubkey(x509, pkey) != 1) return error.OpenSSLBorked;

        const subjname = c.X509_get_subject_name(x509);
        if (c.X509_set_issuer_name(x509, subjname) != 1) return error.OpenSSLBorked;
        if (c.X509_sign(x509, pkey, c.EVP_sha1()) == 0) return error.OpenSSLBorked;
    }

    const base_url = std.mem.trimRight(u8, config_parsed.value.base_url, "/");
    const default_skin_url = try std.fmt.allocPrint(alloc, "{s}/default_skin", .{base_url});
    defer alloc.free(default_skin_url);

    var state = State{
        .allocator = alloc,
        .base_url = base_url,
        .forgejo_url = std.mem.trimRight(u8, config_parsed.value.forgejo_url, "/"),
        .skin_domains = config_parsed.value.skin_domains,
        .server_name = config_parsed.value.server_name,
        .http = .{ .allocator = alloc },
        .db = .{ .con = postgres_con },
        .rand = rand.random(),
        .rsa = rsa,
        .x509 = x509,
        .default_skin_url = default_skin_url,
        .skin_cache = State.SkinCache{},
    };
    defer state.http.deinit();
    defer {
        var kiter = state.skin_cache.keyIterator();
        while (kiter.next()) |key| {
            alloc.free(key.*);
        }
        state.skin_cache.deinit(alloc);
    }

    const addr = try std.net.Address.parseIp(config_parsed.value.bind.ip, config_parsed.value.bind.port);
    var server = try addr.listen(.{});
    std.log.info("listening on {}", .{addr});

    while (true) {
        var con = try server.accept();
        errdefer con.stream.close();

        const thread = try std.Thread.spawn(.{}, handleConnection, .{ con, &state });
        thread.detach();
    }

    return 0;
}

fn handleConnection(con: std.net.Server.Connection, state: *State) void {
    var read_buf: [1024 * 4]u8 = undefined;
    const http = std.http.Server.init(con, &read_buf);
    tryHandleConnection(http, state) catch |e| {
        std.log.warn("error in connection handler: {}", .{e});
    };
}

fn tryHandleConnection(srv_: std.http.Server, state: *State) !void {
    var srv = srv_;
    defer srv.connection.stream.close();

    while (true) {
        var req = srv.receiveHead() catch |e| switch (e) {
            error.HttpConnectionClosing => return,
            else => return e,
        };

        const path = req.head.target;

        std.log.info("{s} {s} from {}", .{
            @tagName(req.head.method),
            path,
            srv.connection.address,
        });

        inline for (.{
            @import("routes/root.zig"),
            @import("routes/aliapi/index.zig"),
            @import("routes/aliapi/api/profiles/minecraft.zig"),
            @import("routes/aliapi/authserver/authenticate.zig"),
            @import("routes/aliapi/sessionserver/session/minecraft/has_joined.zig"),
            @import("routes/aliapi/sessionserver/session/minecraft/join.zig"),
            @import("routes/aliapi/sessionserver/session/minecraft/profile.zig"),
            @import("routes/default_skin.zig"),
        }) |route| {
            if (route.matches(path)) {
                route.call(&req, state) catch |e| {
                    //if (res.state == .waited) {
                    //    try @import("conutil.zig").sendJsonError(
                    //        &res,
                    //        .internal_server_error,
                    //        "alec",
                    //        .{},
                    //    );
                    //}
                    return e;
                };
                break;
            }
        } else {
            try req.respond("", .{ .status = .not_found });
            //res.status = .not_found;
            //res.transfer_encoding = .{ .content_length = 0 };
            //try res.send();
            //try res.finish();
        }

        if (srv.state == .closing) break;
    }
}
