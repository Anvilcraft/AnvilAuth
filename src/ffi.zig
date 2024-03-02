const std = @import("std");

pub const c = @cImport({
    @cInclude("libpq-fe.h");
    @cInclude("openssl/rsa.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/x509.h");
});

const libpq_log = std.log.scoped(.libpq);

pub fn libpqNoticeReceiverCb(_: ?*anyopaque, res: ?*const c.PGresult) callconv(.C) void {
    const severity_str: [*:0]const u8 = c.PQresultErrorField(res, c.PG_DIAG_SEVERITY_NONLOCALIZED) orelse
        c.PQresultErrorField(res, c.PG_DIAG_SEVERITY) orelse
        "LOG";

    const msg = c.PQresultErrorField(res, c.PG_DIAG_MESSAGE_PRIMARY);
    const sev = std.mem.span(severity_str);
    if (std.mem.eql(u8, sev, "ERROR") or
        std.mem.eql(u8, sev, "FATAL") or
        std.mem.eql(u8, sev, "PANIC"))
    {
        libpq_log.err("{s}", .{msg});
    } else if (std.mem.eql(u8, sev, "WARNING")) {
        libpq_log.warn("{s}", .{msg});
    } else if (std.mem.eql(u8, sev, "DEBUG")) {
        libpq_log.debug("{s}", .{msg});
    } else {
        libpq_log.info("{s}", .{msg});
    }
}
