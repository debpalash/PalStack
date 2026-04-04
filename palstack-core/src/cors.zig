// ZigStack CORS — Zero per-request overhead CORS handler.
//
// Adapted from TurboAPI's Zig-native CORS implementation.
// Headers are pre-rendered once at configuration time into a single
// byte slice. At request time, they're injected via memcpy — no
// parsing, no allocation, no string formatting per request.
//
// Also handles OPTIONS preflight requests inline — no handler dispatch needed.

const std = @import("std");

pub const CorsConfig = struct {
    /// Allowed origins. Use "*" for any. Comma-separated for multiple.
    origins: []const u8 = "*",
    /// Allowed methods.
    methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS, PATCH, HEAD",
    /// Allowed headers.
    headers: []const u8 = "*",
    /// Max age in seconds for preflight cache.
    max_age: u32 = 600,
    /// Whether to include credentials header.
    credentials: bool = false,
};

pub const Cors = struct {
    /// Pre-rendered CORS header block. Empty string = disabled.
    headers: []const u8,
    /// Pre-rendered OPTIONS preflight response (complete HTTP response).
    preflight_response: []const u8,
    /// Whether CORS is enabled.
    enabled: bool,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, config: CorsConfig) !Cors {
        // Validate: reject CRLF in CORS values to prevent header injection
        for ([_][]const u8{ config.origins, config.methods, config.headers }) |val| {
            if (std.mem.indexOfAny(u8, val, "\r\n") != null) {
                return error.CorsHeaderInjection;
            }
        }

        const cred_hdr: []const u8 = if (config.credentials)
            "\r\nAccess-Control-Allow-Credentials: true"
        else
            "";

        var age_buf: [16]u8 = undefined;
        const age_str = std.fmt.bufPrint(&age_buf, "{d}", .{config.max_age}) catch "600";

        // Pre-render the CORS header block (injected into every response)
        const headers = try std.fmt.allocPrint(alloc,
            "\r\nAccess-Control-Allow-Origin: {s}" ++
                "\r\nAccess-Control-Allow-Methods: {s}" ++
                "\r\nAccess-Control-Allow-Headers: {s}" ++
                "{s}" ++
                "\r\nAccess-Control-Max-Age: {s}",
            .{ config.origins, config.methods, config.headers, cred_hdr, age_str },
        );

        // Pre-render the complete OPTIONS preflight response
        const preflight_response = try std.fmt.allocPrint(alloc,
            "HTTP/1.1 204 No Content" ++
                "\r\nAccess-Control-Allow-Origin: {s}" ++
                "\r\nAccess-Control-Allow-Methods: {s}" ++
                "\r\nAccess-Control-Allow-Headers: {s}" ++
                "{s}" ++
                "\r\nAccess-Control-Max-Age: {s}" ++
                "\r\nContent-Length: 0" ++
                "\r\nConnection: keep-alive" ++
                "\r\n\r\n",
            .{ config.origins, config.methods, config.headers, cred_hdr, age_str },
        );

        return .{
            .headers = headers,
            .preflight_response = preflight_response,
            .enabled = true,
            .alloc = alloc,
        };
    }

    pub fn initDisabled() Cors {
        return .{
            .headers = "",
            .preflight_response = "",
            .enabled = false,
            .alloc = undefined,
        };
    }

    pub fn deinit(self: *Cors) void {
        if (self.enabled) {
            self.alloc.free(self.headers);
            self.alloc.free(self.preflight_response);
        }
    }

    /// Check if this is a preflight OPTIONS request that should be short-circuited.
    pub fn isPreflight(method: []const u8) bool {
        return method.len == 7 and std.mem.eql(u8, method, "OPTIONS");
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "cors initialization" {
    const alloc = std.testing.allocator;
    var cors = try Cors.init(alloc, .{
        .origins = "https://example.com",
        .methods = "GET, POST",
        .credentials = true,
    });
    defer cors.deinit();

    try std.testing.expect(cors.enabled);
    try std.testing.expect(cors.headers.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cors.headers, "https://example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, cors.headers, "Credentials: true") != null);
}

test "cors disabled" {
    var cors = Cors.initDisabled();
    try std.testing.expect(!cors.enabled);
    _ = &cors;
}

test "cors rejects header injection" {
    const alloc = std.testing.allocator;
    const result = Cors.init(alloc, .{ .origins = "evil\r\nInjected: true" });
    try std.testing.expect(result == error.CorsHeaderInjection);
}

test "cors preflight detection" {
    try std.testing.expect(Cors.isPreflight("OPTIONS"));
    try std.testing.expect(!Cors.isPreflight("GET"));
    try std.testing.expect(!Cors.isPreflight("POST"));
}
