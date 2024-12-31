const std = @import("std");

pub fn sendJsonError(
    req: *std.http.Server.Request,
    code: std.http.Status,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const JsonError = struct {
        @"error": []const u8,
        errorMessage: []const u8,
    };

    var fmt_buf: [1024 * 4]u8 = undefined;
    const json_error = JsonError{
        .@"error" = code.phrase() orelse "Unknown Error",
        .errorMessage = try std.fmt.bufPrint(&fmt_buf, "[AnvilAuth] " ++ fmt, args),
    };

    var ser_buf: [1024 * 4]u8 = undefined;
    var ser_fbs = std.io.fixedBufferStream(&ser_buf);
    try std.json.stringify(json_error, .{}, ser_fbs.writer());

    try req.respond(ser_fbs.getWritten(), .{
        .status = code,
        .extra_headers = &.{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub const QueryParameterError = error{ MissingParameter, InvalidParameters };

pub fn parseQueryParametersFromUri(uri: std.Uri, comptime T: type) QueryParameterError!T {
    return if (uri.query) |q| try parseQueryParameters(q, T) else error.MissingParameter;
}

pub fn parseQueryParameters(params: std.Uri.Component, comptime T: type) QueryParameterError!T {
    const DefaultedT = comptime blk: {
        const info = @typeInfo(T);
        var opt_fields: [info.Struct.fields.len]std.builtin.Type.StructField = undefined;

        for (&opt_fields, info.Struct.fields) |*ofield, field| {
            ofield.* = .{
                .name = field.name,
                .type = ?field.type,
                .default_value = @as(*const ?field.type, &null),
                .is_comptime = false,
                .alignment = 0,
            };
        }

        break :blk @Type(.{ .Struct = .{
            .layout = .auto,
            .fields = &opt_fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    const def_out = try parseQueryParametersOrDefaults(params, DefaultedT);

    var out: T = undefined;
    inline for (comptime std.meta.fieldNames(T)) |fname| {
        @field(out, fname) = @field(def_out, fname) orelse return error.MissingParameter;
    }

    return out;
}

pub fn parseQueryParametersOrDefaults(params: std.Uri.Component, comptime T: type) QueryParameterError!T {
    const params_str = switch (params) {
        // TODO: handle escape sequences
        inline .raw, .percent_encoded => |s| s,
    };

    var out: T = .{};

    var iter = std.mem.splitScalar(u8, params_str, '&');
    while (iter.next()) |param| {
        var psplit = std.mem.splitScalar(u8, param, '=');
        const key = psplit.next() orelse return error.InvalidParameters;
        const value = psplit.next() orelse return error.InvalidParameters;
        if (psplit.next()) |_| return error.InvalidParameters;

        inline for (comptime std.meta.fieldNames(T)) |fname| {
            if (std.mem.eql(u8, key, fname)) {
                @field(out, fname) = value;
                break;
            }
        }
    }

    return out;
}
