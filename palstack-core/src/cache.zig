// ZigStack Response Cache — Bounded, thread-safe response caching.
//
// Adapted from TurboAPI's response cache. After the first render/computation,
// the complete HTTP response bytes are stored. Subsequent requests serve
// directly from cache — zero computation, zero allocation, single writeAll.
//
// Two tiers:
//   1. Static cache: Pre-rendered at build time (SSG pages, static API responses)
//   2. Dynamic cache: Populated on first request (noargs handlers, SSR pages with TTL)
//
// Thread safety: Mutex-protected writes, lock-free reads after population.
// Memory: Bounded to MAX_ENTRIES to prevent OOM from unique path flooding.

const std = @import("std");

pub const CacheConfig = struct {
    /// Maximum number of cached entries. Prevents OOM from unique-path flooding.
    max_entries: usize = 10_000,
    /// Whether caching is enabled.
    enabled: bool = true,
};

pub const CacheEntry = struct {
    /// Complete pre-rendered HTTP response bytes, ready for writeAll.
    response_bytes: []const u8,
    /// Unix timestamp when this entry was created.
    created_at: i64,
    /// TTL in seconds. 0 = no expiry. -1 = immutable (never expires).
    ttl: i32,
};

pub const ResponseCache = struct {
    store: std.StringHashMapUnmanaged(CacheEntry),
    alloc: std.mem.Allocator,
    count: usize,
    max_entries: usize,
    mutex: std.Thread.Mutex,
    enabled: bool,

    pub fn init(alloc: std.mem.Allocator, config: CacheConfig) ResponseCache {
        return .{
            .store = .empty,
            .alloc = alloc,
            .count = 0,
            .max_entries = config.max_entries,
            .mutex = .{},
            .enabled = config.enabled,
        };
    }

    pub fn deinit(self: *ResponseCache) void {
        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.response_bytes);
        }
        self.store.deinit(self.alloc);
    }

    /// Look up a cached response. Returns null if not found or expired.
    /// Lock-free read — safe for concurrent access after population.
    pub fn get(self: *ResponseCache, key: []const u8) ?[]const u8 {
        if (!self.enabled) return null;

        const entry = self.store.get(key) orelse return null;

        // Check TTL
        if (entry.ttl > 0) {
            const now = std.time.timestamp();
            if (now - entry.created_at > entry.ttl) {
                return null; // Expired — caller should re-render and re-cache
            }
        }

        return entry.response_bytes;
    }

    /// Cache a pre-rendered response. Thread-safe, bounded.
    pub fn put(self: *ResponseCache, key: []const u8, response: []const u8, ttl: i32) void {
        if (!self.enabled) {
            self.alloc.free(response);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Bound check — prevent OOM
        if (self.count >= self.max_entries) {
            self.alloc.free(response);
            return;
        }

        const key_dupe = self.alloc.dupe(u8, key) catch {
            self.alloc.free(response);
            return;
        };

        const gop = self.store.getOrPut(self.alloc, key_dupe) catch {
            self.alloc.free(response);
            self.alloc.free(key_dupe);
            return;
        };

        if (gop.found_existing) {
            // Already cached — discard the new response
            self.alloc.free(response);
            self.alloc.free(key_dupe);
            return;
        }

        gop.value_ptr.* = .{
            .response_bytes = response,
            .created_at = std.time.timestamp(),
            .ttl = ttl,
        };
        self.count += 1;
    }

    /// Register a static (build-time) response. These never expire.
    pub fn putStatic(self: *ResponseCache, key: []const u8, response: []const u8) void {
        self.put(key, response, -1);
    }

    /// Pre-render a full HTTP response into a heap-allocated buffer.
    pub fn renderResponse(
        self: *ResponseCache,
        status: u16,
        content_type: []const u8,
        body: []const u8,
        cors_headers: []const u8,
    ) ?[]const u8 {
        const status_text = httpStatusText(status);

        // Generate RFC 7231 Date header
        var date_buf: [40]u8 = undefined;
        const date_str = formatHttpDate(&date_buf) catch "Thu, 01 Jan 2026 00:00:00 GMT";

        return std.fmt.allocPrint(self.alloc,
            "HTTP/1.1 {d} {s}\r\n" ++
                "Server: ZigStack\r\n" ++
                "Date: {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: keep-alive" ++
                "{s}\r\n\r\n{s}",
            .{ status, status_text, date_str, content_type, body.len, cors_headers, body },
        ) catch null;
    }

    /// Get cache statistics.
    pub fn stats(self: *const ResponseCache) struct { entries: usize, max: usize } {
        return .{ .entries = self.count, .max = self.max_entries };
    }
};

// ── HTTP helpers ────────────────────────────────────────────────────────────

fn httpStatusText(code: u16) []const u8 {
    return switch (code) {
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
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

fn formatHttpDate(buf: *[40]u8) ![]u8 {
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
        dw[di],              md.day_index + 1, mn[@intFromEnum(md.month) - 1], yd.year,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "cache put and get" {
    const alloc = std.testing.allocator;
    var cache = ResponseCache.init(alloc, .{});
    defer cache.deinit();

    const response = try alloc.dupe(u8, "HTTP/1.1 200 OK\r\n\r\nHello");
    cache.put("GET /hello", response, 0);

    const cached = cache.get("GET /hello");
    try std.testing.expect(cached != null);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\nHello", cached.?);
}

test "cache miss returns null" {
    const alloc = std.testing.allocator;
    var cache = ResponseCache.init(alloc, .{});
    defer cache.deinit();

    try std.testing.expect(cache.get("GET /missing") == null);
}

test "cache respects max entries" {
    const alloc = std.testing.allocator;
    var cache = ResponseCache.init(alloc, .{ .max_entries = 2 });
    defer cache.deinit();

    const r1 = try alloc.dupe(u8, "response1");
    cache.put("key1", r1, 0);

    const r2 = try alloc.dupe(u8, "response2");
    cache.put("key2", r2, 0);

    const r3 = try alloc.dupe(u8, "response3");
    cache.put("key3", r3, 0); // Should be rejected (freed internally)

    try std.testing.expect(cache.get("key1") != null);
    try std.testing.expect(cache.get("key2") != null);
    try std.testing.expect(cache.get("key3") == null);

    const s = cache.stats();
    try std.testing.expectEqual(@as(usize, 2), s.entries);
}

test "cache disabled returns null" {
    const alloc = std.testing.allocator;
    var cache = ResponseCache.init(alloc, .{ .enabled = false });
    defer cache.deinit();

    const response = try alloc.dupe(u8, "test"); // Will be freed by put()
    cache.put("key", response, 0);
    try std.testing.expect(cache.get("key") == null);
}

test "render response format" {
    const alloc = std.testing.allocator;
    var cache = ResponseCache.init(alloc, .{});
    defer cache.deinit();

    const rendered = cache.renderResponse(200, "application/json", "{\"ok\":true}", "");
    try std.testing.expect(rendered != null);
    defer alloc.free(rendered.?);

    try std.testing.expect(std.mem.indexOf(u8, rendered.?, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.?, "ZigStack") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.?, "{\"ok\":true}") != null);
}
