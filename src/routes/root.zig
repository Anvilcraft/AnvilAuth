const std = @import("std");

const State = @import("../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/");
}

pub fn call(req: *std.http.Server.Request, state: *State) !void {
    const base_url = try std.fmt.allocPrint(state.allocator, "{s}/aliapi", .{state.base_url});
    defer state.allocator.free(base_url);

    var content = std.ArrayList(u8).init(state.allocator);
    defer content.deinit();
    const w = content.writer();

    try w.print(
        \\<html>
        \\<head>
        \\<title>AnvilAuth</title>
        \\</head>
        \\<body>
        \\<a href="{}?scope=openid+profile&response_type=code&client_id={s}&redirect_uri={%}%2Foidcredirect">
        \\<button>Login</button></a>
        \\</body></html>
    , .{
        state.oidc_config.authorization_endpoint,
        state.oidc.id,
        std.Uri.Component{ .raw = state.base_url },
    });

    try req.respond(content.items, .{
        .extra_headers = &.{ .{
            .name = "x-authlib-injector-api-location",
            .value = base_url,
        }, .{
            .name = "Content-Type",
            .value = "text/html",
        } },
    });
}
