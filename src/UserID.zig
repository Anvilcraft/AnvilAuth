const std = @import("std");

name: []const u8,
domain: ?[]const u8,

const UserID = @This();

pub fn jsonParse(
    alloc: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !UserID {
    const token = try source.nextAlloc(alloc, options.allocate.?);
    switch (token) {
        inline .string, .allocated_string => |s| return try UserID.parse(s),
        else => return error.UnexpectedToken,
    }
}

pub fn jsonStringify(self: UserID, ws: anytype) !void {
    var buf: [1024]u8 = undefined;
    const username_str = std.fmt.bufPrint(&buf, "{}", .{self}) catch return error.OutOfMemory;
    try ws.write(username_str);
}

pub fn format(
    self: UserID,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.writeAll(self.name);
    if (self.domain) |domain| {
        try writer.writeByte('@');
        try writer.writeAll(domain);
    }
}

pub const ParseError = error{
    InvalidFormat,
    InvalidCharacter,
};

/// Parses a UserID from a string.
/// The returned UserID will contain only slices into the provided string.
pub fn parse(txt: []const u8) ParseError!UserID {
    if (txt.len == 0)
        return error.InvalidFormat;

    const valid_domain_chars =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.";

    const valid_name_chars =
        valid_domain_chars ++ "_";

    if (std.mem.indexOfScalar(u8, txt, '@')) |at_idx| {
        if (std.mem.lastIndexOfScalar(u8, txt, '@').? != at_idx or
            at_idx == 0 or
            at_idx == txt.len - 1)
            return error.InvalidFormat;

        const name = txt[0..at_idx];
        if (!allContainedIn(name, valid_name_chars))
            return error.InvalidCharacter;

        const domain = txt[at_idx + 1 ..];
        if (!allContainedIn(domain, valid_domain_chars))
            return error.InvalidCharacter;

        return .{
            .name = name,
            .domain = domain,
        };
    }

    if (!allContainedIn(txt, valid_name_chars))
        return error.InvalidCharacter;

    return .{
        .name = txt,
        .domain = null,
    };
}

fn allContainedIn(a: []const u8, b: []const u8) bool {
    for (a) |c_a| {
        for (b) |c_b| {
            if (c_a == c_b) break;
        } else return false;
    }
    return true;
}
