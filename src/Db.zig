const std = @import("std");

const UUID = @import("uuid").Uuid;

const ffi = @import("ffi.zig");
const c = ffi.c;

con: *c.PGconn,

const Db = @This();

pub fn initDb(self: Db) !void {
    const query =
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id UUID NOT NULL PRIMARY KEY,
        \\  oidc_sub VARCHAR NOT NULL UNIQUE,
        \\  name VARCHAR NOT NULL UNIQUE,
        \\  skin_uri VARCHAR
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\  id UUID NOT NULL PRIMARY KEY,
        \\  userid UUID NOT NULL,
        \\  expiry BIGINT NOT NULL,
        \\  client_token VARCHAR NOT NULL,
        \\
        \\  FOREIGN KEY (userid) REFERENCES users (id)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS joins (
        \\  userid UUID NOT NULL PRIMARY KEY,
        \\  serverid VARCHAR NOT NULL,
        \\
        \\  FOREIGN KEY (userid) REFERENCES users (id)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS tokens (
        \\  id CHAR(32) NOT NULL PRIMARY KEY,
        \\  userid UUID NOT NULL,
        \\  creation BIGINT NOT NULL,
        \\  last_use BIGINT NOT NULL,
        \\
        \\  FOREIGN KEY (userid) REFERENCES users (id)
        \\);
    ;

    const status = self.exec(query);
    defer status.deinit();
    try status.expectCommand();
}

pub fn exec(self: Db, query: [:0]const u8) Result {
    return .{ .res = c.PQexec(self.con, query.ptr) };
}

pub fn execParams(self: Db, query: [:0]const u8, params: anytype) Result {
    var args_buf: [1024 * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&args_buf);
    const alloc = fba.allocator();

    const nparams = @typeInfo(@TypeOf(params)).@"struct".fields.len;

    const vals = alloc.alloc(?[*]const u8, nparams) catch return .oom;
    const lengths = alloc.alloc(c_int, nparams) catch return .oom;
    const formats = alloc.alloc(c_int, nparams) catch return .oom;

    inline for (params, vals, lengths, formats) |param, *val, *len, *format| {
        setParam(alloc, &param, val, len, format) catch return .oom;
    }

    const ret = c.PQexecParams(
        self.con,
        query,
        nparams,
        null,
        vals.ptr,
        lengths.ptr,
        formats.ptr,
        1,
    );
    return .{ .res = ret };
}

fn setParam(
    alloc: std.mem.Allocator,
    param: anytype,
    val: *?[*]const u8,
    len: *c_int,
    format: *c_int,
) !void {
    switch (@typeInfo(@TypeOf(param.*))) {
        .optional => |_| {
            if (param.*) |*p| {
                try setParam(alloc, p, val, len, format);
            } else {
                val.* = null;
                len.* = 0;
                format.* = 1;
            }
        },
        else => switch (@TypeOf(param.*)) {
            []const u8, [:0]const u8 => {
                val.* = param.ptr;
                len.* = @intCast(param.len);
                format.* = 1;
            },
            [*:0]const u8 => {
                val.* = param.*;
                len.* = -1;
                format.* = 0;
            },
            i64 => {
                const bytes = try alloc.dupe(u8, std.mem.asBytes(&std.mem.nativeToBig(i64, param.*)));
                val.* = bytes.ptr;
                len.* = @intCast(bytes.len);
                format.* = 1;
            },
            UUID => {
                val.* = &param.bytes;
                len.* = param.bytes.len;
                format.* = 1;
            },
            else => @compileError("unsupported parameter type: " ++ @typeName(@TypeOf(param))),
        },
    }
}

pub const Result = struct {
    pub const oom = Result{ .res = null };

    res: ?*c.PGresult,

    pub inline fn deinit(self: Result) void {
        if (self.res) |res| c.PQclear(res);
    }

    pub fn expect(self: Result, expected: c_uint) !void {
        const actual = c.PQresultStatus(self.res); // safe to call with null
        if (actual != expected) {
            std.log.err("expected result `{s}`, got `{s}` (msg: `{s}`)", .{
                c.PQresStatus(expected),
                c.PQresStatus(actual),
                @as([*:0]const u8, c.PQresultErrorField(self.res, c.PG_DIAG_MESSAGE_PRIMARY) orelse "<not present>"),
            });
            return error.UnexpectedSqlStatus;
        }
    }

    pub inline fn expectTuples(self: Result) !void {
        try self.expect(c.PGRES_TUPLES_OK);
    }

    pub inline fn expectCommand(self: Result) !void {
        try self.expect(c.PGRES_COMMAND_OK);
    }

    pub inline fn rows(self: Result) c_int {
        return c.PQntuples(self.res);
    }

    pub inline fn cols(self: Result) c_int {
        return c.PQnfields(self.res);
    }

    pub fn getOptional(self: Result, comptime T: type, row: c_int, col: c_int) ?T {
        return if (c.PQgetisnull(self.res, row, col) == 1) null else self.get(T, row, col);
    }

    pub inline fn get(self: Result, comptime T: type, row: c_int, col: c_int) T {
        return switch (T) {
            []const u8 => c.PQgetvalue(self.res, row, col)[0..@intCast(c.PQgetlength(self.res, row, col))],
            UUID => .{ .bytes = c.PQgetvalue(self.res, row, col)[0..16].* },
            i64 => std.mem.readInt(
                i64,
                c.PQgetvalue(self.res, row, col)[0..8],
                .big,
            ),
            else => @compileError("unsuppored type: " ++ @typeName(T)),
        };
    }
};
