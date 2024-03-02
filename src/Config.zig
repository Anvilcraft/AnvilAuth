bind: struct {
    ip: []const u8,
    port: u16,
},
base_url: []const u8,
postgres_url: [:0]const u8,
forgejo_url: []const u8,
skin_domains: []const []const u8,
server_name: []const u8,
