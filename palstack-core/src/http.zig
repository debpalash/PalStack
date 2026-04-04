// HTTP utility functions — pure, zero-dependency helpers for HTTP parsing.
//
// Ported from turboapi-core and extended for PalStack.

const std = @import("std");

/// Fast query-string value lookup. Format: "k1=v1&k2=v2&...".
/// No percent-decoding (fine for int/float/simple str params in hot path).
pub fn queryStringGet(qs: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// Percent-decode src into buf. '+' → space, '%XX' → byte. Returns decoded slice.
/// If buf is too small, copies as many bytes as fit (safe truncation).
pub fn percentDecode(src: []const u8, buf: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < buf.len) {
        if (src[i] == '+') {
            buf[out] = ' ';
            out += 1;
            i += 1;
        } else if (src[i] == '%' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]);
            const lo = hexNibble(src[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (hi.? << 4) | lo.?;
                out += 1;
                i += 3;
            } else {
                buf[out] = src[i];
                out += 1;
                i += 1;
            }
        } else {
            buf[out] = src[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

pub fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// Format an RFC 2822 HTTP Date header value into buf.
/// Returns the formatted slice (e.g. "Wed, 19 Mar 2026 11:30:27 GMT").
pub fn formatHttpDate(buf: *[40]u8) []const u8 {
    const ts = std.time.timestamp();
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const ds = es.getDaySeconds();
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const di: usize = @intCast(@mod(@as(i32, @intCast(ed.day)) + 3, 7));
    const dw = [7][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const mn = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        dw[di], md.day_index + 1, mn[@intFromEnum(md.month) - 1], yd.year,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "Thu, 01 Jan 2026 00:00:00 GMT";
}

/// Simple request metadata parser — finds the split between headers and body.
pub const RequestParser = struct {
    pub const Info = struct {
        method: []const u8,
        path: []const u8,
        query: []const u8,
        header_len: usize,
        content_length: usize = 0,
    };

    pub fn parse(raw: []const u8) !Info {
        const double_crlf = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.NoHeaders;
        const header_len = double_crlf + 4;
        const headers = raw[0..double_crlf];

        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        const first_line = lines.next() orelse return error.EmptyRequest;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return error.InvalidMethod;
        const full_path = parts.next() orelse return error.InvalidPath;

        const qmark = std.mem.indexOfScalar(u8, full_path, '?');
        const path = if (qmark) |q| full_path[0..q] else full_path;
        const query = if (qmark) |q| full_path[q + 1 ..] else "";

        var content_length: usize = 0;
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                const val = std.mem.trim(u8, line["Content-Length:".len..], " ");
                content_length = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }

        return Info{
            .method = method,
            .path = path,
            .query = query,
            .header_len = header_len,
            .content_length = content_length,
        };
    }
};
