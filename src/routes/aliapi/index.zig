const std = @import("std");
const c = ffi.c;

const ffi = @import("../../ffi.zig");

const State = @import("../../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/aliapi");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.OutOfMemory;
    defer _ = c.BIO_free(bio);

    if (c.PEM_write_bio_X509_PUBKEY(
        bio,
        c.X509_get_X509_PUBKEY(state.x509),
    ) != 1) return error.OpenSSLBorked;

    var dataptr: ?[*]const u8 = null;
    const datalen: usize = @intCast(c.BIO_get_mem_data(bio, &dataptr));
    const keydata = dataptr.?[0..datalen];

    const response_payload = .{
        .meta = .{
            .serverName = state.server_name,
            .implementationName = "AnvilAuth",
            .implementationVersion = "0.0.0",
            .links = .{ .source = "https://git.tilera.org/Anvilcraft/AnvilAuth" },
        },
        .skinDomains = state.skin_domains,
        .signaturePublickey = keydata,
    };

    const json = try std.json.stringifyAlloc(state.allocator, response_payload, .{});
    defer state.allocator.free(json);

    try req.respond(json, .{
        .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "application/json",
        }}
    });
}
