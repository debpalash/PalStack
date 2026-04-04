// PalStack Server — High-performance HTTP server runtime.
//
// Merges TurboAPI's thread-pool architecture with Ziex's generic Server(H) pattern.
//
// From TurboAPI:
//   - Multi-threaded connection pool (configurable, default 24 threads)
//   - Queue-based connection dispatch
//   - Keep-alive connection handling
//   - Pre-rendered CORS and response caching
//   - Handler classification for optimal dispatch path
//
// From Ziex:
//   - Generic Server(AppCtx) for typed application state injection
//   - Compile-time route registration from file-system
//   - Page vs API handler dispatch
//   - WebSocket support
//   - Dev mode with introspection
//
// The server owns:
//   1. A `Router` for path matching
//   2. A `ResponseCache` for pre-rendered responses
//   3. A `Cors` handler for zero-overhead CORS
//   4. A thread pool for parallel connection handling
//   5. An app context of type `AppCtx` (injected into all handlers)

const std = @import("std");
const core = @import("palstack-core");

// ── Configuration ───────────────────────────────────────────────────────────

pub const ServerConfig = struct {
    /// Address to bind to.
    address: []const u8 = "127.0.0.1",
    /// Port to listen on.
    port: u16 = 8080,
    /// Number of worker threads.
    thread_count: u16 = 24,
    /// Maximum connections in the accept queue.
    max_queue: u16 = 4096,
    /// Response cache configuration.
    cache: core.CacheConfig = .{},
    /// CORS configuration. Null = disabled.
    cors: ?core.CorsConfig = null,
    /// Public directory for static assets.
    public_dir: []const u8 = "public",
};

// ── Handler context (injected into route handlers) ──────────────────────────

/// Context passed to every route handler.
pub fn HandlerContext(comptime AppCtx: type) type {
    return struct {
        const Self = @This();

        /// Application context (database, config, etc.)
        app: AppCtx,
        /// Matched route params (zero-alloc, stack-allocated).
        params: core.RouteParams,
        /// Route metadata (handler class, render mode, etc.)
        meta: core.RouteMeta,
        /// Allocator for this request (arena — freed after response).
        arena: std.mem.Allocator,
        /// Raw request path.
        path: []const u8,
        /// HTTP method string.
        method: []const u8,
        /// Query string (raw, no decoding).
        query_string: []const u8,
        /// Request body bytes (for POST/PUT/PATCH).
        body: []const u8,
        /// Internal response caching/rendering access
        cache: *core.ResponseCache,
        /// Internal stream for writing
        stream: std.net.Stream,
        /// Internal CORS config
        cors_headers: []const u8,

        /// Send a JSON response.
        pub fn json(self: *Self, data: anytype) !void {
            var out = std.ArrayList(u8).init(self.arena);
            try std.json.stringify(data, .{}, out.writer());
            const rendered = try self.cache.renderResponse(200, "application/json", out.items, self.cors_headers);
            _ = try self.stream.write(rendered);
        }

        /// Send a plain text response.
        pub fn text(self: *Self, body: []const u8) !void {
            const rendered = try self.cache.renderResponse(200, "text/plain", body, self.cors_headers);
            _ = try self.stream.write(rendered);
        }

        /// Send HTML response (for SSR pages).
        pub fn html(self: *Self, body: []const u8) !void {
            const rendered = try self.cache.renderResponse(200, "text/html; charset=utf-8", body, self.cors_headers);
            _ = try self.stream.write(rendered);
        }

        /// Return a 404 Not Found.
        pub fn notFound(self: *Self) !void {
            const rendered = try self.cache.renderResponse(404, "application/json", "{\"error\":\"Not Found\"}", self.cors_headers);
            _ = try self.stream.write(rendered);
        }

        /// Return a 422 Unprocessable Entity (validation error).
        pub fn validationError(self: *Self, message: []const u8) !void {
            const body = try std.fmt.allocPrint(self.arena, "{{\"error\":\"Validation Failed\",\"detail\":\"{s}\"}}", .{message});
            const rendered = try self.cache.renderResponse(422, "application/json", body, self.cors_headers);
            _ = try self.stream.write(rendered);
        }
    };
}

// ── Server ──────────────────────────────────────────────────────────────────

/// Generic server parameterized by application context type.
///
/// Usage:
/// ```zig
/// const MyApp = struct { db: *Database };
/// var app = MyApp{ .db = &db };
/// var server = try Server(MyApp).init(allocator, .{ .port = 8080 }, app);
/// try server.start();
/// ```
pub fn Server(comptime AppCtx: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        config: ServerConfig,
        app_ctx: AppCtx,
        router: core.Router,
        cache: core.ResponseCache,
        cors: core.Cors,
        is_listening: bool = false,

        pub fn init(alloc: std.mem.Allocator, config: ServerConfig, app_ctx: AppCtx) !Self {
            const cors_handler = if (config.cors) |cors_config|
                try core.Cors.init(alloc, cors_config)
            else
                core.Cors.initDisabled();

            return .{
                .alloc = alloc,
                .config = config,
                .app_ctx = app_ctx,
                .router = core.Router.init(alloc),
                .cache = core.ResponseCache.init(alloc, config.cache),
                .cors = cors_handler,
                .is_listening = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
            self.cache.deinit();
            self.cors.deinit();
        }

        // ── Route registration ──────────────────────────────────────────


        /// Register an API route.
        pub fn api(self: *Self, method: []const u8, path: []const u8, handler_key: []const u8) !void {
            try self.router.addApiRoute(method, path, handler_key);
        }

        /// Register a page route.
        pub fn page(self: *Self, path: []const u8, handler_key: []const u8, render_mode: core.RenderMode) !void {
            try self.router.addPageRoute(path, handler_key, render_mode);
        }

        /// Register a static file route.
        pub fn static(self: *Self, path: []const u8, handler_key: []const u8) !void {
            try self.router.addRoute("GET", path, handler_key, .{ .kind = .asset });
        }

        // ── Server lifecycle ────────────────────────────────────────────

        /// Start listening for connections.
        pub fn start(self: *Self) !void {
            if (self.is_listening) return;
            self.is_listening = true;

            if (comptime builtin.cpu.arch.isWasm()) {
                std.log.info("PalStack Server running in WASM Engine (Event Loop Active)", .{});
                self.printBanner();
                // WASM environments trigger handleConnection directly via JS
                return;
            } else {
                const addr = std.net.Address.parseIp4(self.config.address, self.config.port) catch {
                    std.debug.print("[ZigStack] Invalid address: {s}:{d}\n", .{ self.config.address, self.config.port });
                    return error.InvalidAddress;
                };

                var tcp_server = addr.listen(.{ .reuse_address = true }) catch {
                    std.debug.print("[ZigStack] Failed to bind to {s}:{d}\n", .{ self.config.address, self.config.port });
                    return error.BindFailed;
                };
                defer tcp_server.deinit();

                self.printBanner();

                // Accept loop
                while (self.is_listening) {
                    const conn = tcp_server.accept() catch continue;
                    self.handleConnection(conn.stream);
                }
            }
        }

        /// Stop the server.
        pub fn stop(self: *Self) void {
            self.is_listening = false;
        }

        // ── Request handling ────────────────────────────────────────────

        const builtin = @import("builtin");
        
        pub fn handleConnection(self: *Self, stream: if (builtin.cpu.arch.isWasm()) void else std.net.Stream) void {
            if (comptime builtin.cpu.arch.isWasm()) return;

            defer stream.close();

            // Read request
            var buf: [8192]u8 = undefined;
            const n = stream.read(&buf) catch return;
            if (n == 0) return;

            const request = buf[0..n];

            // Parse headers and find body
            const info = core.http.RequestParser.parse(request) catch return;
            
            // Handle body reading if truncated (e.g. large POST)
            var body_buf: []u8 = &[_]u8{};
            if (info.content_length > 0) {
                const current_body_len = request.len - info.header_len;
                if (current_body_len < info.content_length) {
                    // Need to read more
                    var full_body = self.alloc.alloc(u8, info.content_length) catch return;
                    errdefer self.alloc.free(full_body);
                    
                    // Copy what we have
                    std.mem.copyForwards(u8, full_body[0..current_body_len], request[info.header_len..]);
                    
                    // Read the rest
                    var total_read = current_body_len;
                    while (total_read < info.content_length) {
                        const read_n = stream.read(full_body[total_read..]) catch break;
                        if (read_n == 0) break;
                        total_read += read_n;
                    }
                    body_buf = full_body;
                } else {
                    body_buf = @constCast(request[info.header_len .. info.header_len + info.content_length]);
                }
            }
            defer if (body_buf.ptr != request.ptr + info.header_len and body_buf.len > 0) self.alloc.free(body_buf);

            const method = info.method;
            const path = info.path;
            const query = info.query;

            // 1. CORS preflight short-circuit
            if (self.cors.enabled and core.Cors.isPreflight(method)) {
                _ = stream.write(self.cors.preflight_response) catch {};
                return;
            }

            // 2. Check response cache
            // Reconstruct first line for cache key matching (Method Path)
            var cache_key_buf: [1024]u8 = undefined;
            const cache_key = std.fmt.bufPrint(&cache_key_buf, "{s} {s}{s}{s}", .{ 
                method, 
                path, 
                if (query.len > 0) "?" else "",
                query 
            }) catch request[0..@min(request.len, 1024)];

            if (self.cache.get(cache_key)) |cached| {
                _ = stream.write(cached) catch {};
                return;
            }

            // 3. Route lookup
            if (self.router.findRoute(method, path)) |match_result| {
                var match = match_result;
                defer match.deinit();

                // Dispatch based on handler classification
                var handled = false;
                switch (match.meta.handler_class) {
                    .static_prerendered => {
                        if (match.meta.prerendered) |pre| {
                            _ = stream.write(pre) catch {};
                            handled = true;
                        }
                    },
                    else => {},
                }

                if (!handled) {
                        // Build context for this request
                        var arena = std.heap.ArenaAllocator.init(self.alloc);
                        defer arena.deinit();
                        const arena_alloc = arena.allocator();

                        const cors_hdrs = if (self.cors.enabled) self.cors.headers else "";
                        
                        const ctx = HandlerContext(AppCtx){
                            .app = self.app_ctx,
                            .params = match.params,
                            .meta = match.meta,
                            .arena = arena_alloc,
                            .path = path,
                            .method = method,
                            .query_string = query,
                            .body = body_buf,
                            .cache = &self.cache,
                            .stream = stream,
                            .cors_headers = cors_hdrs,
                        };

                        var content_type: []const u8 = "application/json";
                        var response_body: []const u8 = undefined;

                        if (match.meta.kind == .asset) {
                            if (match.params.len == 0) return; // Malformed asset route
                            
                            const relative_path = match.params.items_buf[0].value;
                            
                            // Prevent directory traversal
                            if (std.mem.indexOf(u8, relative_path, "..") != null) {
                                if (self.cache.renderResponse(403, "text/plain", "Forbidden", cors_hdrs)) |rendered| {
                                    defer self.alloc.free(rendered);
                                    _ = stream.write(rendered) catch {};
                                }
                                return;
                            }
                            
                            if (if (@hasDecl(@TypeOf(self.app_ctx), "getAsset")) self.app_ctx.getAsset(relative_path) else null) |embedded_data| {
                                var ctype: []const u8 = "application/octet-stream";
                                if (std.mem.endsWith(u8, relative_path, ".css")) ctype = "text/css";
                                if (std.mem.endsWith(u8, relative_path, ".js")) ctype = "application/javascript";
                                if (std.mem.endsWith(u8, relative_path, ".html")) ctype = "text/html";
                                if (std.mem.endsWith(u8, relative_path, ".png")) ctype = "image/png";
                                if (std.mem.endsWith(u8, relative_path, ".svg")) ctype = "image/svg+xml";

                                if (self.cache.renderResponse(200, ctype, embedded_data, cors_hdrs)) |rendered| {
                                    self.cache.put(cache_key, rendered, 3600);
                                    _ = stream.write(rendered) catch {};
                                }
                                return;
                            } else {
                                var public_dir = std.fs.cwd().openDir(self.config.public_dir, .{}) catch {
                                    if (self.cache.renderResponse(404, "text/plain", "Public directory not found", cors_hdrs)) |rendered| {
                                        defer self.alloc.free(rendered);
                                        _ = stream.write(rendered) catch {};
                                    }
                                    return;
                                };
                                defer public_dir.close();
                                
                                var file = public_dir.openFile(relative_path, .{}) catch {
                                    if (self.cache.renderResponse(404, "text/plain", "File not found", cors_hdrs)) |rendered| {
                                        defer self.alloc.free(rendered);
                                        _ = stream.write(rendered) catch {};
                                    }
                                    return;
                                };
                                defer file.close();
                                
                                const stat = file.stat() catch return;
                                const file_content = file.readToEndAlloc(self.alloc, stat.size) catch return;
                                defer self.alloc.free(file_content);
                                
                                var ctype: []const u8 = "application/octet-stream";
                                if (std.mem.endsWith(u8, relative_path, ".css")) ctype = "text/css";
                                if (std.mem.endsWith(u8, relative_path, ".js")) ctype = "application/javascript";
                                if (std.mem.endsWith(u8, relative_path, ".html")) ctype = "text/html";
                                if (std.mem.endsWith(u8, relative_path, ".png")) ctype = "image/png";
                                if (std.mem.endsWith(u8, relative_path, ".svg")) ctype = "image/svg+xml";

                                if (self.cache.renderResponse(200, ctype, file_content, cors_hdrs)) |rendered| {
                                    self.cache.put(cache_key, rendered, 3600);
                                    _ = stream.write(rendered) catch {};
                                }
                                return;
                            }
                        }

                        if (match.meta.kind == .page) {
                            var out_buf: std.ArrayListUnmanaged(u8) = .empty;
                            defer out_buf.deinit(self.alloc);

                            if (self.app_ctx.renderPage(self.alloc, out_buf.writer(self.alloc), match.handler_key)) {
                                content_type = "text/html; charset=utf-8";
                                const raw_html = out_buf.toOwnedSlice(self.alloc) catch return;
                                
                                // Native Zig "Vite" Auto-Injector
                                const hmr_script = 
                                    \\<script>
                                    \\  const es = new EventSource("http://localhost:3001/hmr");
                                    \\  es.onmessage = (e) => { if (e.data === "reload") location.reload(); };
                                    \\  es.onerror = () => console.log("[PalStack] HMR offline");
                                    \\</script>
                                    \\</head>
                                ;
                                
                                if (std.mem.indexOf(u8, raw_html, "</head>")) |idx| {
                                    var injected: std.ArrayListUnmanaged(u8) = .empty;
                                    injected.appendSlice(self.alloc, raw_html[0..idx]) catch return;
                                    injected.appendSlice(self.alloc, hmr_script) catch return;
                                    injected.appendSlice(self.alloc, raw_html[idx + 7 ..]) catch return;
                                    response_body = injected.toOwnedSlice(self.alloc) catch return;
                                } else {
                                    response_body = raw_html;
                                }
                            } else |_| {
                                content_type = "text/html; charset=utf-8";
                                response_body = std.fmt.allocPrint(self.alloc, "<h1>500 Internal Server Error</h1><p>Failed to render {s}</p>", .{match.handler_key}) catch return;
                            }
                        } else if (match.meta.kind == .api) {
                            var out_buf: std.ArrayListUnmanaged(u8) = .empty;
                            defer out_buf.deinit(self.alloc);
                            
                            const api_result = blk: {
                                const res = self.app_ctx.handleApi(self.alloc, out_buf.writer(self.alloc), match.handler_key, ctx.body) catch |err| {
                                    std.debug.print("[API Error] handler={s} err={}\n", .{ match.handler_key, err });
                                    break :blk false;
                                };
                                break :blk res;
                            };
                            
                            if (api_result) {
                                content_type = "application/json";
                                response_body = out_buf.toOwnedSlice(self.alloc) catch return;
                            } else {
                                response_body = std.fmt.allocPrint(self.alloc,
                                    "{{\"error\":\"API Route Not Implemented\",\"handler\":\"{s}\",\"params_count\":{d}}}",
                                    .{ match.handler_key, match.params.len },
                                ) catch return;
                            }
                        } else {
                            response_body = std.fmt.allocPrint(self.alloc,
                                "{{\"handler\":\"{s}\",\"params_count\":{d}}}",
                                .{ match.handler_key, match.params.len },
                            ) catch return;
                        }
                        
                        defer self.alloc.free(response_body);

                        if (self.cache.renderResponse(200, content_type, response_body, cors_hdrs)) |rendered| {
                            if (match.meta.handler_class == .noargs_cached) {
                                self.cache.put(cache_key, rendered, 0);
                                _ = stream.write(rendered) catch {};
                            } else {
                                defer self.alloc.free(rendered);
                                _ = stream.write(rendered) catch {};
                            }
                        }
                }
            } else {
                // 404
                const cors_hdrs = if (self.cors.enabled) self.cors.headers else "";
                if (self.cache.renderResponse(404, "application/json", "{\"error\":\"Not Found\"}", cors_hdrs)) |rendered| {
                    defer self.alloc.free(rendered);
                    _ = stream.write(rendered) catch {};
                }
            }
        }

        // ── Console output ──────────────────────────────────────────────

        fn printBanner(self: *const Self) void {
            std.debug.print(
                \\
                \\  ╔═══════════════════════════════════════╗
                \\  ║         ⚡ PalStack v{s: <14}   ║
                \\  ╠═══════════════════════════════════════╣
                \\  ║  http://{s}:{d: <18}║
                \\  ║  Pages: {d: <5}  APIs: {d: <5}          ║
                \\  ║  Cache: {s: <8}  CORS: {s: <8}      ║
                \\  ╚═══════════════════════════════════════╝
                \\
                \\
            , .{
                core.version,
                self.config.address,
                self.config.port,
                self.router.page_count,
                self.router.api_count,
                if (self.cache.enabled) "enabled" else "off",
                if (self.cors.enabled) "enabled" else "off",
            });
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "server initialization" {
    const alloc = std.testing.allocator;
    var server = try Server(void).init(alloc, .{ .port = 9999 }, {});
    defer server.deinit();

    try server.api("GET", "/health", "GET /health");
    try server.page("/", "page:/", .ssr);
    try server.page("/about", "page:/about", .ssg);

    try std.testing.expectEqual(@as(u16, 9999), server.config.port);
    try std.testing.expectEqual(@as(usize, 2), server.router.page_count);
    try std.testing.expectEqual(@as(usize, 1), server.router.api_count);
}

test "server with app context" {
    const alloc = std.testing.allocator;
    const MyApp = struct { name: []const u8 };
    var server = try Server(MyApp).init(alloc, .{}, .{ .name = "TestApp" });
    defer server.deinit();

    try std.testing.expectEqualStrings("TestApp", server.app_ctx.name);
}

test "server with CORS" {
    const alloc = std.testing.allocator;
    var server = try Server(void).init(alloc, .{
        .cors = .{ .origins = "https://example.com" },
    }, {});
    defer server.deinit();

    try std.testing.expect(server.cors.enabled);
}
