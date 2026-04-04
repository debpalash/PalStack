// PalStack Showcase — Fullstack application demo.
//
// This demonstrates the major framework features:
//   - Typed application context
//   - API route registration with handler classification
//   - Page route registration with SSR/SSG modes
//   - Reactive signals for component state
//   - CORS configuration
//   - Response caching
//
// Run: zig build showcase
// Test: zig build test

const std = @import("std");
const core = @import("palstack-core");
const signals = @import("palstack-signals");
const zs = @import("palstack-server");
const routes = @import("routes");
const assets = @import("assets");
const db = @import("palstack-db");
const models = @import("db/models.zig");

// ── App Context ─────────────────────────────────────────────────────────────

pub const AppContext = struct {
    name: []const u8,
    version: []const u8,
    title: []const u8,
    database: db.Client,
    start_time: i64,

    pub fn uptime(self: *const AppContext) i64 {
        return std.time.timestamp() - self.start_time;
    }

    pub fn renderPage(self: *const AppContext, alloc: std.mem.Allocator, writer: anytype, handler_key: []const u8) !void {
        try routes.renderPage(alloc, writer, handler_key, self.*);
    }
    
    pub fn getAsset(self: *const AppContext, relative_path: []const u8) ?[]const u8 {
        _ = self;
        for (assets.embedded_assets) |asset| {
            if (std.mem.endsWith(u8, asset.path, relative_path)) {
                return asset.data;
            }
        }
        return null;
    }
    
    pub fn handleApi(self: *const AppContext, alloc: std.mem.Allocator, writer: anytype, handler_key: []const u8, body: []const u8) !bool {
        if (std.mem.eql(u8, handler_key, "api:increment")) {
            global_count += 1;
            try writer.print(
                \\<button class="px-5 py-2.5 rounded-lg bg-blue-500 hover:bg-blue-600 transition-colors font-medium shadow-lg shadow-blue-500/20" hx-post="/api/increment" hx-swap="outerHTML" hx-target="this">Count: {d}</button>
            , .{global_count});
            return true;
        }

        if (std.mem.eql(u8, handler_key, "api:health")) {
            try writer.writeAll("{\"status\":\"ok\",\"orm\":\"sqlite\",\"uptime\":");
            try writer.print("{d}", .{self.uptime()});
            try writer.writeAll("}");
            return true;
        }

        if (std.mem.eql(u8, handler_key, "api:users-list")) {
            // Use the ORM to fetch all users from SQLite
            var db_mut = self.database;
            const users = db_mut.findAll(models.User, "users", alloc) catch {
                try writer.writeAll("{\"error\":\"failed to query users\"}");
                return true;
            };
            defer alloc.free(users);

            try writer.writeAll("[");
            for (users, 0..) |user, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"id\":{d},\"email\":\"{s}\",\"handle\":\"{s}\"}}", .{ user.id, user.email, user.handle });
            }
            try writer.writeAll("]");
            return true;
        }

        if (std.mem.eql(u8, handler_key, "api:users-create")) {
            const UserCreate = struct {
                email: []const u8,
                handle: []const u8,
            };

            const parsed = std.json.parseFromSlice(UserCreate, alloc, body, .{ .ignore_unknown_fields = true }) catch {
                try writer.writeAll("{\"error\":\"invalid json payload\",\"expected\":{\"email\":\"string\",\"handle\":\"string\"}}");
                return true;
            };
            defer parsed.deinit();

            const payload = parsed.value;
            if (payload.email.len < 5 or !std.mem.containsAtLeast(u8, payload.email, 1, "@")) {
                try writer.writeAll("{\"error\":\"validation failed\",\"field\":\"email\",\"message\":\"invalid email format\"}");
                return true;
            }

            var db_mut = self.database;
            const user_count = db_mut.count("users") catch 0;
            const new_id = user_count + 1;

            db_mut.insert(models.User, "users", .{
                .id = new_id,
                .email = payload.email,
                .handle = payload.handle,
                .bio = null,
            }) catch {
                try writer.writeAll("{\"error\":\"database insert failed\"}");
                return true;
            };

            try writer.print("{{\"status\":\"success\",\"id\":{d},\"email\":\"{s}\"}}", .{ new_id, payload.email });
            return true;
        }

        if (std.mem.eql(u8, handler_key, "api:internal-schema")) {
            var db_mut = self.database;
            if (db_mut != .sqlite) {
                try writer.writeAll("{\"error\":\"introspection only supported on sqlite\"}");
                return true;
            }

            const columns = db_mut.sqlite.getTableSchema("users") catch {
                try writer.writeAll("{\"error\":\"failed to introspect users table\"}");
                return true;
            };
            defer alloc.free(columns);

            try writer.writeAll("{\"table\":\"users\",\"columns\":[");
            for (columns, 0..) |col, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"name\":\"{s}\",\"type\":\"{s}\",\"pk\":{s}}}", .{ 
                    col.name, 
                    col.type, 
                    if (col.pk) "true" else "false" 
                });
            }
            try writer.writeAll("]}");
            return true;
        }

        return false;
    }
};

var global_count: i32 = 0;

// ── Main ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize signals system
    signals.setGlobalAllocator(alloc);

    // ── Zero-Config Agentic DB Init ─────────────────────────────────────

    var db_client = try db.Client.initAuto(alloc);
    
    // 2. Sync Schemas (Zero-Config Agentic ORM)
    try db_client.syncSchema(models.User, "users");
    try db_client.syncSchema(models.Post, "posts");

    const app_ctx = AppContext{
        .name = "PalStack Hub Edition",
        .version = "0.1.0",
        .title = "PalStack Hub",
        .database = db_client,
        .start_time = std.time.timestamp(),
    };

    // ── Create server ───────────────────────────────────────────────────

    var server = try zs.Server(AppContext).init(alloc, .{
        .port = 8080,
        .cors = .{
            .origins = "*",
            .credentials = false,
        },
        .cache = .{
            .max_entries = 1000,
        },
        .public_dir = "showcase/public",
    }, app_ctx);
    defer server.deinit();

    // ── Register routes ─────────────────────────────────────────────────

    // Auto-generated routes from .psx pages
    try routes.initRoutes(&server);

    // API routes
    try server.api("GET", "/api/health", "api:health");
    try server.api("GET", "/api/users", "api:users-list");
    try server.api("GET", "/api/users/{id}", "api:users-get");
    try server.api("POST", "/api/users", "api:users-create");
    try server.api("DELETE", "/api/users/{id}", "api:users-delete");
    try server.api("POST", "/api/increment", "api:increment");
    try server.api("GET", "/api/internal/schema", "api:internal-schema");

    // Mount static assets
    try server.static("/assets/*path", "static:assets");

    // ── Start server ────────────────────────────────────────────────────

    std.debug.print(
        \\
        \\  PalStack Hub Edition
        \\  ====================
        \\
        \\  Routes registered:
        \\    Pages:  {d}
        \\    APIs:   {d}
        \\
        \\  Features demonstrated:
        \\    ✓ Typed application context (AppContext)
        \\    ✓ Radix trie router (turboapi-core derived)
        \\    ✓ Handler classification (static, noargs, simple, model, page)
        \\    ✓ Page routes with SSR/SSG modes
        \\    ✓ Zero-overhead CORS (pre-rendered headers)
        \\    ✓ Bounded response caching
        \\    ✓ Reactive signals (Signal, Memo, Effect)
        \\    ✓ Zero-Config Agentic ORM (SQLite + Postgres)
        \\
        \\  Starting server...
        \\
    , .{ server.router.page_count, server.router.api_count });

    // Demonstrate signals
    const count = try signals.Signal(i32).create(alloc, "demo-counter", 0, 0);
    defer alloc.destroy(count);

    std.debug.print("  Signal demo: count = {d}\n", .{count.get()});
    count.set(42);
    std.debug.print("  Signal demo: count = {d} (after set)\n\n", .{count.get()});

    // Start serving
    try server.start();
}
