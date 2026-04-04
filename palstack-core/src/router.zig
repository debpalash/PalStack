// ZigStack Router — Compressed radix trie with fullstack route metadata.
//
// Adapted from turboapi-core's router with enhancements for fullstack use:
//   1. Route metadata: page vs API, SSR config, handler classification
//   2. Streaming response support for SSR pages
//   3. Compile-time route registration from file-system (Ziex pattern)
//   4. Handler classification for optimal dispatch path
//
// Preserved from turboapi-core:
//   - Prefix-compressed nodes — shared prefixes stored once
//   - Child lookup via indices byte array — O(1) for <16 children
//   - Priority ordering — hot routes checked first
//   - Path walked as raw string — no segment splitting on lookup
//   - Method-indexed trees — one radix trie per HTTP method

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Public types ────────────────────────────────────────────────────────────

pub const MAX_ROUTE_PARAMS = 16;

pub const RouteParam = struct {
    key: []const u8,
    value: []const u8,
    int_value: i64 = 0,
    has_int_value: bool = false,
};

/// Zero-alloc route params — fixed-size stack array instead of HashMap.
/// Supports up to MAX_ROUTE_PARAMS path parameters per route.
pub const RouteParams = struct {
    items_buf: [MAX_ROUTE_PARAMS]RouteParam = undefined,
    len: usize = 0,

    pub fn get(self: *const RouteParams, key: []const u8) ?[]const u8 {
        for (self.items_buf[0..self.len]) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    pub fn getInt(self: *const RouteParams, key: []const u8) ?i64 {
        for (self.items_buf[0..self.len]) |p| {
            if (std.mem.eql(u8, p.key, key) and p.has_int_value) return p.int_value;
        }
        return null;
    }

    pub fn put(self: *RouteParams, key: []const u8, value: []const u8) void {
        if (self.len < MAX_ROUTE_PARAMS) {
            var int_value: i64 = 0;
            var has_int_value = false;
            if (std.fmt.parseInt(i64, value, 10)) |n| {
                int_value = n;
                has_int_value = true;
            } else |_| {}
            self.items_buf[self.len] = .{
                .key = key,
                .value = value,
                .int_value = int_value,
                .has_int_value = has_int_value,
            };
            self.len += 1;
        }
    }

    pub fn removeLast(self: *RouteParams) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn entries(self: *const RouteParams) []const RouteParam {
        return self.items_buf[0..self.len];
    }
};

// ── Route Metadata (ZigStack enhancement) ───────────────────────────────────

/// Handler classification — determines the lightest dispatch path.
/// Inspired by TurboAPI's handler types, extended for fullstack.
pub const HandlerClass = enum(u8) {
    /// Pre-rendered at build time. Single writeAll, zero runtime overhead.
    static_prerendered,
    /// No parameters. Response cached after first render.
    noargs_cached,
    /// Path/query params only. Zero-alloc RouteParams on stack.
    simple,
    /// JSON body with schema validation. Zig validates before handler runs.
    model_validated,
    /// SSR page render. Streaming response with hydration markers.
    page_ssr,
    /// SSR page with async data. Streaming + out-of-order rendering.
    page_ssr_async,
    /// Full handler — middleware, complex types, dependencies.
    enhanced,
};

/// Rendering strategy for page routes.
pub const RenderMode = enum(u8) {
    /// Server-side rendered on every request.
    ssr,
    /// Static site generation — rendered at build time.
    ssg,
    /// Client-side only — minimal HTML shell + WASM.
    csr,
    /// Hybrid — SSR for initial load, CSR for subsequent navigations.
    hybrid,
};

/// Route metadata attached to each registered route.
pub const RouteMeta = struct {
    /// Route kind.
    kind: RouteKind = .api,
    /// Handler classification for optimal dispatch.
    handler_class: HandlerClass = .enhanced,
    /// Rendering mode (page routes only).
    render_mode: RenderMode = .ssr,
    /// Whether this route supports streaming SSR.
    streaming: bool = true,
    /// Cache TTL in seconds (0 = no cache, -1 = immutable).
    cache_ttl: i32 = 0,
    /// Pre-rendered response bytes (for static_prerendered routes).
    prerendered: ?[]const u8 = null,

    pub const RouteKind = enum(u2) {
        page,
        api,
        asset,
        websocket,
    };
};

/// Result of a route match.
pub const RouteMatch = struct {
    handler_key: []const u8,
    params: RouteParams = .{},
    meta: RouteMeta = .{},
    /// Heap-allocated values that this match owns (e.g. joined wildcard paths).
    owned_values: std.ArrayListUnmanaged([]const u8) = .empty,
    alloc: Allocator,

    pub fn deinit(self: *RouteMatch) void {
        for (self.owned_values.items) |v| {
            self.alloc.free(v);
        }
        self.owned_values.deinit(self.alloc);
    }
};

/// HTTP method enum — one radix trie per method for O(1) method dispatch.
pub const Method = enum(u3) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    HEAD = 5,
    OPTIONS = 6,
    OTHER = 7,

    pub fn fromString(s: []const u8) Method {
        if (s.len < 3) return .OTHER;
        return switch (s[0]) {
            'G' => if (s.len == 3 and s[1] == 'E' and s[2] == 'T') .GET else .OTHER,
            'P' => switch (s.len) {
                3 => if (s[1] == 'U' and s[2] == 'T') .PUT else .OTHER,
                4 => if (s[1] == 'O' and s[2] == 'S' and s[3] == 'T') .POST else .OTHER,
                5 => if (s[1] == 'A' and s[2] == 'T' and s[3] == 'C' and s[4] == 'H') .PATCH else .OTHER,
                else => .OTHER,
            },
            'D' => if (s.len == 6 and std.mem.eql(u8, s, "DELETE")) .DELETE else .OTHER,
            'H' => if (s.len == 4 and std.mem.eql(u8, s, "HEAD")) .HEAD else .OTHER,
            'O' => if (s.len == 7 and std.mem.eql(u8, s, "OPTIONS")) .OPTIONS else .OTHER,
            else => .OTHER,
        };
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .OTHER => "OTHER",
        };
    }
};

// ── Router ──────────────────────────────────────────────────────────────────

pub const Router = struct {
    trees: [8]?*RouteNode,
    alloc: Allocator,
    /// Metadata store — indexed by handler_key.
    meta_store: std.StringHashMapUnmanaged(RouteMeta),
    /// Count of registered routes per kind.
    page_count: usize = 0,
    api_count: usize = 0,

    pub fn init(alloc: Allocator) Router {
        return .{
            .trees = .{null} ** 8,
            .alloc = alloc,
            .meta_store = .empty,
        };
    }

    pub fn deinit(self: *Router) void {
        for (&self.trees) |*tree| {
            if (tree.*) |root| {
                root.deinitRecursive(self.alloc);
                self.alloc.destroy(root);
                tree.* = null;
            }
        }
        // Free the duped handler_key strings used as meta_store keys
        var it = self.meta_store.keyIterator();
        while (it.next()) |key_ptr| {
            self.alloc.free(key_ptr.*);
        }
        self.meta_store.deinit(self.alloc);
    }

    /// Add a route with metadata. `handler_key` is stored as-is.
    pub fn addRoute(
        self: *Router,
        method: []const u8,
        path: []const u8,
        handler_key: []const u8,
        meta: RouteMeta,
    ) !void {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        const m = Method.fromString(method);
        const idx = @intFromEnum(m);
        if (self.trees[idx] == null) {
            const root = try self.alloc.create(RouteNode);
            root.* = RouteNode.initEmpty();
            self.trees[idx] = root;
        }
        try self.addRouteImpl(path[1..], handler_key, self.trees[idx].?);

        // Store metadata
        const key_dupe = try self.alloc.dupe(u8, handler_key);
        try self.meta_store.put(self.alloc, key_dupe, meta);

        // Update counts
        switch (meta.kind) {
            .page => self.page_count += 1,
            .api => self.api_count += 1,
            else => {},
        }
    }

    /// Convenience: add a simple API route.
    pub fn addApiRoute(self: *Router, method: []const u8, path: []const u8, handler_key: []const u8) !void {
        try self.addRoute(method, path, handler_key, .{ .kind = .api });
    }

    /// Convenience: add a page route.
    pub fn addPageRoute(
        self: *Router,
        path: []const u8,
        handler_key: []const u8,
        render_mode: RenderMode,
    ) !void {
        try self.addRoute("GET", path, handler_key, .{
            .kind = .page,
            .handler_class = if (render_mode == .ssg) .static_prerendered else .page_ssr,
            .render_mode = render_mode,
        });
    }

    /// Find the handler key, params, and metadata for the given path.
    pub fn findRoute(self: *const Router, method: []const u8, path: []const u8) ?RouteMatch {
        const m = Method.fromString(method);
        const root = self.trees[@intFromEnum(m)] orelse return null;
        const search = if (path.len > 0 and path[0] == '/') path[1..] else path;

        var params: RouteParams = .{};
        var owned: std.ArrayListUnmanaged([]const u8) = .empty;
        if (self.getValue(root, search, &params, &owned)) |handler_key| {
            const meta = self.meta_store.get(handler_key) orelse RouteMeta{};
            return RouteMatch{
                .handler_key = handler_key,
                .params = params,
                .meta = meta,
                .owned_values = owned,
                .alloc = self.alloc,
            };
        }
        owned.deinit(self.alloc);
        return null;
    }

    /// Print all registered routes (TurboAPI-style diagnostics).
    pub fn printRoutes(self: *const Router) void {
        std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
        std.debug.print("║       ZigStack Routes                        ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════╣\n", .{});
        std.debug.print("║  Pages: {d:<5}  APIs: {d:<5}                  ║\n", .{ self.page_count, self.api_count });
        std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});
    }

    // ── addRoute internals ──────────────────────────────────────────────

    fn addRouteImpl(self: *Router, path: []const u8, handler_key: []const u8, node: *RouteNode) !void {
        if (path.len == 0) {
            return self.setHandler(node, handler_key);
        }

        // Check for param segment: {name}
        if (path[0] == '{') {
            const close = std.mem.indexOfScalar(u8, path, '}') orelse return error.InvalidPath;
            const param_name = path[1..close];
            const rest = if (close + 1 < path.len) path[close + 1 ..] else "";
            const rest_trimmed = if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;

            if (node.param_child == null) {
                const child = try self.alloc.create(RouteNode);
                child.* = RouteNode.initEmpty();
                child.param_name = try self.alloc.dupe(u8, param_name);
                node.param_child = child;
            }
            return self.addRouteImpl(rest_trimmed, handler_key, node.param_child.?);
        }

        // Check for wildcard: *name
        if (path[0] == '*') {
            const param_name = if (path.len > 1) path[1..] else "wildcard";
            const child = if (node.wildcard_child) |wc| wc else blk: {
                const c = try self.alloc.create(RouteNode);
                c.* = RouteNode.initEmpty();
                c.param_name = try self.alloc.dupe(u8, param_name);
                node.wildcard_child = c;
                break :blk c;
            };
            return self.setHandler(child, handler_key);
        }

        // Static path — find longest common prefix with existing children
        const first_byte = path[0];
        const child_idx = node.findChildIndex(first_byte);

        if (child_idx) |idx| {
            const child = node.children_list[idx];
            const common_len = longestCommonPrefix(path, child.path);

            if (common_len == child.path.len) {
                const rest = path[common_len..];
                const rest_trimmed = if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;
                try self.addRouteImpl(rest_trimmed, handler_key, child);
                self.incrementChildPrio(node, idx);
                return;
            }

            // Partial match — split the existing node
            const split_child = try self.alloc.create(RouteNode);
            split_child.* = RouteNode.initEmpty();
            split_child.path = try self.alloc.dupe(u8, path[0..common_len]);

            const old_path = child.path;
            child.path = try self.alloc.dupe(u8, old_path[common_len..]);
            self.alloc.free(old_path);

            try split_child.addChild(self.alloc, child);

            node.children_list[idx] = split_child;
            node.indices[idx] = split_child.path[0];

            const rest = path[common_len..];
            const rest_trimmed = if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;
            try self.addRouteImpl(rest_trimmed, handler_key, split_child);
            return;
        }

        // No matching child — create a new one
        const seg_end = findSegmentEnd(path);
        const segment = path[0..seg_end];
        const rest = path[seg_end..];
        const rest_trimmed = if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;

        const child = try self.alloc.create(RouteNode);
        child.* = RouteNode.initEmpty();
        child.path = try self.alloc.dupe(u8, segment);

        try node.addChild(self.alloc, child);

        if (rest_trimmed.len == 0 and rest.len == 0) {
            return self.setHandler(child, handler_key);
        }

        try self.addRouteImpl(rest_trimmed, handler_key, child);
    }

    fn setHandler(self: *Router, node: *RouteNode, handler_key: []const u8) !void {
        if (node.handler_key) |old| {
            self.alloc.free(old);
        }
        node.handler_key = try self.alloc.dupe(u8, handler_key);
    }

    fn incrementChildPrio(_: *Router, node: *RouteNode, idx: usize) void {
        node.children_list[idx].priority += 1;
        const prio = node.children_list[idx].priority;

        var pos = idx;
        while (pos > 0 and node.children_list[pos - 1].priority < prio) {
            const tmp = node.children_list[pos];
            node.children_list[pos] = node.children_list[pos - 1];
            node.children_list[pos - 1] = tmp;
            const tmp_idx = node.indices[pos];
            node.indices[pos] = node.indices[pos - 1];
            node.indices[pos - 1] = tmp_idx;
            pos -= 1;
        }
    }

    // ── findRoute internals ─────────────────────────────────────────────

    fn getValue(
        self: *const Router,
        start_node: *const RouteNode,
        start_path: []const u8,
        params: *RouteParams,
        owned: *std.ArrayListUnmanaged([]const u8),
    ) ?[]const u8 {
        var current = start_node;
        var remaining = start_path;

        walk: while (true) {
            if (remaining.len == 0) {
                return current.handler_key;
            }

            // 1. Try static children via indices lookup
            const first_byte = remaining[0];
            if (current.findChildIndex(first_byte)) |idx| {
                const child = current.children_list[idx];
                const child_path = child.path;

                if (remaining.len >= child_path.len and
                    std.mem.eql(u8, remaining[0..child_path.len], child_path))
                {
                    remaining = remaining[child_path.len..];
                    if (remaining.len > 0 and remaining[0] == '/') {
                        remaining = remaining[1..];
                    }
                    current = child;
                    continue :walk;
                }
            }

            // 2. Try parameter child
            if (current.param_child) |param_child| {
                if (param_child.param_name) |pname| {
                    const seg_end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
                    const value = remaining[0..seg_end];

                    params.put(pname, value);
                    const rest = if (seg_end < remaining.len) remaining[seg_end + 1 ..] else "";

                    if (self.getValue(param_child, rest, params, owned)) |h| {
                        return h;
                    }
                    params.removeLast();
                }
            }

            // 3. Try wildcard child
            if (current.wildcard_child) |wc| {
                if (wc.param_name) |pname| {
                    if (wc.handler_key) |hk| {
                        // Reject path traversal
                        var check = remaining;
                        while (check.len > 0) {
                            const seg_end = std.mem.indexOfScalar(u8, check, '/') orelse check.len;
                            const seg = check[0..seg_end];
                            if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return null;
                            if (seg_end >= check.len) break;
                            check = check[seg_end + 1 ..];
                        }
                        const joined = self.alloc.dupe(u8, remaining) catch return null;
                        params.put(pname, joined);
                        owned.append(self.alloc, joined) catch return null;
                        return hk;
                    }
                }
            }

            return null;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fn findSegmentEnd(path: []const u8) usize {
        for (path, 0..) |ch, i| {
            if (ch == '/' or ch == '{' or ch == '*') return i;
        }
        return path.len;
    }

    fn longestCommonPrefix(a: []const u8, b: []const u8) usize {
        const max = @min(a.len, b.len);
        var i: usize = 0;
        while (i < max and a[i] == b[i]) : (i += 1) {}
        return i;
    }
};

// ── Route node ──────────────────────────────────────────────────────────────

const RouteNode = struct {
    path: []const u8,
    indices: []u8,
    children_list: []*RouteNode,
    param_child: ?*RouteNode,
    wildcard_child: ?*RouteNode,
    param_name: ?[]const u8,
    handler_key: ?[]const u8,
    priority: u32,

    fn initEmpty() RouteNode {
        return .{
            .path = "",
            .indices = &.{},
            .children_list = &.{},
            .param_child = null,
            .wildcard_child = null,
            .param_name = null,
            .handler_key = null,
            .priority = 0,
        };
    }

    fn findChildIndex(self: *const RouteNode, ch: u8) ?usize {
        for (self.indices, 0..) |idx_byte, i| {
            if (idx_byte == ch) return i;
        }
        return null;
    }

    fn addChild(self: *RouteNode, alloc: Allocator, child: *RouteNode) !void {
        const old_len = self.indices.len;
        const new_len = old_len + 1;
        const first_byte = if (child.path.len > 0) child.path[0] else 0;

        const new_indices = try alloc.alloc(u8, new_len);
        if (old_len > 0) {
            @memcpy(new_indices[0..old_len], self.indices);
            alloc.free(self.indices);
        }
        new_indices[old_len] = first_byte;
        self.indices = new_indices;

        const new_children = try alloc.alloc(*RouteNode, new_len);
        if (old_len > 0) {
            @memcpy(new_children[0..old_len], self.children_list);
            alloc.free(self.children_list);
        }
        new_children[old_len] = child;
        self.children_list = new_children;
    }

    fn deinitRecursive(self: *RouteNode, alloc: Allocator) void {
        for (self.children_list) |child| {
            child.deinitRecursive(alloc);
            alloc.destroy(child);
        }
        if (self.indices.len > 0) alloc.free(self.indices);
        if (self.children_list.len > 0) alloc.free(self.children_list);
        if (self.param_child) |pc| {
            pc.deinitRecursive(alloc);
            alloc.destroy(pc);
        }
        if (self.wildcard_child) |wc| {
            wc.deinitRecursive(alloc);
            alloc.destroy(wc);
        }
        if (self.path.len > 0) alloc.free(self.path);
        if (self.param_name) |pn| alloc.free(pn);
        if (self.handler_key) |hk| alloc.free(hk);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "static routes" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addApiRoute("GET", "/users", "GET /users");

    var m1 = r.findRoute("GET", "/users").?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("GET /users", m1.handler_key);
    try std.testing.expect(m1.meta.kind == .api);
}

test "page routes with metadata" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addPageRoute("/", "page:/", .ssr);
    try r.addPageRoute("/about", "page:/about", .ssg);

    var m1 = r.findRoute("GET", "/").?;
    defer m1.deinit();
    try std.testing.expect(m1.meta.kind == .page);
    try std.testing.expect(m1.meta.render_mode == .ssr);

    var m2 = r.findRoute("GET", "/about").?;
    defer m2.deinit();
    try std.testing.expect(m2.meta.render_mode == .ssg);
    try std.testing.expect(m2.meta.handler_class == .static_prerendered);
}

test "multiple methods on same path" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addApiRoute("GET", "/items", "GET /items");
    try r.addApiRoute("POST", "/items", "POST /items");

    var m1 = r.findRoute("GET", "/items").?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("GET /items", m1.handler_key);

    var m2 = r.findRoute("POST", "/items").?;
    defer m2.deinit();
    try std.testing.expectEqualStrings("POST /items", m2.handler_key);

    const m3 = r.findRoute("DELETE", "/items");
    try std.testing.expect(m3 == null);
}

test "parameterized routes" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addApiRoute("GET", "/users/{id}", "GET /users/{id}");

    var m = r.findRoute("GET", "/users/123").?;
    defer m.deinit();
    try std.testing.expectEqualStrings("GET /users/{id}", m.handler_key);
    try std.testing.expectEqualStrings("123", m.params.get("id").?);
    try std.testing.expectEqual(@as(i64, 123), m.params.getInt("id").?);
}

test "multi-param routes" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addApiRoute("GET", "/api/v1/users/{id}/posts/{post_id}", "GET /api/v1/users/{id}/posts/{post_id}");

    var m = r.findRoute("GET", "/api/v1/users/42/posts/7").?;
    defer m.deinit();
    try std.testing.expectEqualStrings("42", m.params.get("id").?);
    try std.testing.expectEqualStrings("7", m.params.get("post_id").?);
}

test "wildcard routes" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addRoute("GET", "/files/*path", "GET /files/*path", .{ .kind = .asset });

    var m = r.findRoute("GET", "/files/docs/readme.txt").?;
    defer m.deinit();
    try std.testing.expectEqualStrings("docs/readme.txt", m.params.get("path").?);
    try std.testing.expect(m.meta.kind == .asset);
}

test "static takes priority over param" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addApiRoute("GET", "/users/me", "GET /users/me");
    try r.addApiRoute("GET", "/users/{id}", "GET /users/{id}");

    var m1 = r.findRoute("GET", "/users/me").?;
    defer m1.deinit();
    try std.testing.expectEqualStrings("GET /users/me", m1.handler_key);

    var m2 = r.findRoute("GET", "/users/123").?;
    defer m2.deinit();
    try std.testing.expectEqualStrings("GET /users/{id}", m2.handler_key);
}

test "no match returns null" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addApiRoute("GET", "/users", "GET /users");

    const m = r.findRoute("GET", "/posts");
    try std.testing.expect(m == null);
}

test "route counts" {
    const alloc = std.testing.allocator;
    var r = Router.init(alloc);
    defer r.deinit();

    try r.addPageRoute("/", "page:/", .ssr);
    try r.addPageRoute("/about", "page:/about", .ssg);
    try r.addApiRoute("GET", "/api/health", "GET /api/health");
    try r.addApiRoute("POST", "/api/users", "POST /api/users");

    try std.testing.expectEqual(@as(usize, 2), r.page_count);
    try std.testing.expectEqual(@as(usize, 2), r.api_count);
}

// ── Fuzz tests ──────────────────────────────────────────────────────────────

fn fuzz_findRoute(_: void, input: []const u8) anyerror!void {
    if (input.len == 0) return;

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "" };
    const method = methods[input[0] % methods.len];
    const path = if (input.len > 1) input[1..] else "/";

    var r = Router.init(std.testing.allocator);
    defer r.deinit();

    r.addApiRoute("GET", "/users", "GET /users") catch return;
    r.addApiRoute("GET", "/users/{id}", "GET /users/{id}") catch return;
    r.addPageRoute("/", "page:/", .ssr) catch return;
    r.addApiRoute("POST", "/users", "POST /users") catch return;
    r.addRoute("GET", "/files/*path", "GET /files/*path", .{ .kind = .asset }) catch return;
    r.addApiRoute("GET", "/health", "GET /health") catch return;

    if (r.findRoute(method, path)) |match_c| {
        var match = match_c;
        defer match.deinit();
        try std.testing.expect(match.handler_key.len > 0);
    }
}

test "fuzz: router findRoute — never panics" {
    try std.testing.fuzz({}, fuzz_findRoute, .{ .corpus = &.{
        "\x00/",
        "\x00/users/42",
        "\x01/users",
        "\x00/users/",
        "\x00/health",
        "\x00/files/deep/nested/path",
        "\x00" ++ "/" ++ ("a/" ** 70),
        "\x00/\x00secret",
        "\x00/" ++ ("a" ** 4096),
        "\x00/%2F%2F/../admin",
        "\x00//double//slash//path",
        "\x00/\xFF\xFE\xFD",
        "\x05/anything",
        "\x00",
    } });
}
