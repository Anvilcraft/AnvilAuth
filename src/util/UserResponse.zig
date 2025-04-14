//! A user in the JSON response that is sent by the server when requestUser is set by the client.

username: []const u8,
id: []const u8,

properties: []const struct {
    name: []const u8,
    value: []const u8,
} = &.{
    // There is no acceptable real-world use-case where this would be incorrect.
    .{
        .name = "preferredLanguage",
        .value = "en",
    },
},
