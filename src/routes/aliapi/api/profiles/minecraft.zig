const std = @import("std");

const conutil = @import("../../../../conutil.zig");

const Id = @import("../../../../Id.zig");
const State = @import("../../../../State.zig");

pub fn matches(path: []const u8) bool {
    return std.mem.eql(u8, path, "/aliapi/api/profiles/minecraft");
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

    var json_reader = std.json.reader(state.allocator, try req.reader());
    defer json_reader.deinit();

    const usernames_req = try std.json.parseFromTokenSource(
        [][]u8,
        state.allocator,
        &json_reader,
        .{},
    );
    defer usernames_req.deinit();

    if (usernames_req.value.len > 10) {
        try conutil.sendJsonError(
            req,
            .bad_request,
            "Only up to 10 usernames may be requested at a time, got {}",
            .{usernames_req.value.len},
        );
        return;
    }

    for (usernames_req.value) |username| {
        for (username) |*char|
            char.* = std.ascii.toLower(char.*);
    }

    var param_str = std.ArrayList(u8).init(state.allocator);
    defer param_str.deinit();
    try param_str.append('{');
    for (usernames_req.value, 0..) |username, i| {
        if (i != 0) try param_str.append(',');
        try param_str.appendSlice(username);
    }
    try param_str.append('}');
    try param_str.append(0);

    const db_res = state.db.execParams(
        \\SELECT id, name FROM users
        \\WHERE lower(name)=any($1::varchar[]);
    , .{@as([*:0]const u8, @ptrCast(param_str.items.ptr))});
    defer db_res.deinit();
    try db_res.expectTuples();

    if (db_res.cols() != 2) return error.InvalidResultFromPostgresServer;

    var response_json = std.ArrayList(u8).init(state.allocator);
    defer response_json.deinit();

    var json_writer = std.json.writeStream(response_json.writer(), .{});

    try json_writer.beginArray();
    for (0..@intCast(db_res.rows())) |rowidx| {
        const id = db_res.get(Id, @intCast(rowidx), 0);
        const name = db_res.get([]const u8, @intCast(rowidx), 1);

        try json_writer.beginObject();
        try json_writer.objectField("id");
        try json_writer.write(&id.toString());
        try json_writer.objectField("name");
        try json_writer.write(name);
        try json_writer.endObject();
    }
    try json_writer.endArray();

    try req.respond(response_json.items, .{
        .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}
