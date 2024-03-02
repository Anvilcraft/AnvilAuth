/// This file implements something similar to UUIDs without the bullshit.
/// It implements a simple even U-er UID, which is simply 16 random bytes.
const std = @import("std");

bytes: [16]u8,

const Id = @This();

/// Returns a hex encoded version of the ID.
pub fn toString(self: Id) [32]u8 {
    var ret: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&ret, "{}", .{std.fmt.fmtSliceHexLower(&self.bytes)}) catch unreachable;
    return ret;
}

pub fn genRandom(rand: std.rand.Random) Id {
    var bytes: [16]u8 = undefined;
    rand.bytes(&bytes);
    return .{ .bytes = bytes };
}

// Parses the given string as an ID, or returns null if it is invalid.
pub fn parse(str: []const u8) ?Id {
    if (str.len != 32) return null;
    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*out, ihalf| {
        out.* = std.fmt.parseInt(u8, str[ihalf * 2 ..][0..2], 16) catch return null;
    }
    return .{ .bytes = bytes };
}
