// PalStack Example 04: REST API
//
// Demonstrates building a full CRUD API with PalStack.
// Routes are registered with method + path + handler key,
// and the AppContext dispatches them to your logic.

const std = @import("std");

// In a real project:
//   const zs = @import("palstack-server");
//   const db = @import("palstack-db");

pub fn main() !void {
    std.debug.print(
        \\
        \\  PalStack — REST API Example
        \\  ============================
        \\
        \\  Step 1: Register routes in main()
        \\  ─────────────────────────────────
        \\
        \\    try server.api("GET",    "/api/users",      "api:users-list");
        \\    try server.api("GET",    "/api/users/{id}", "api:users-get");
        \\    try server.api("POST",   "/api/users",      "api:users-create");
        \\    try server.api("DELETE", "/api/users/{id}", "api:users-delete");
        \\    try server.api("GET",    "/api/health",     "api:health");
        \\
        \\  Step 2: Handle in AppContext.handleApi()
        \\  ────────────────────────────────────────
        \\
        \\    pub fn handleApi(self: *const AppContext, alloc: Allocator,
        \\                     writer: anytype, key: []const u8) !bool {
        \\
        \\        if (std.mem.eql(u8, key, "api:users-list")) {
        \\            var db_mut = self.database;
        \\            const users = try db_mut.findAll(User, "users", alloc);
        \\            defer alloc.free(users);
        \\
        \\            try writer.writeAll("[");
        \\            for (users, 0..) |user, i| {
        \\                if (i > 0) try writer.writeAll(",");
        \\                try writer.print(
        \\                    "{{\"id\":{d},\"email\":\"{s}\"}}",
        \\                    .{ user.id, user.email },
        \\                );
        \\            }
        \\            try writer.writeAll("]");
        \\            return true;
        \\        }
        \\
        \\        if (std.mem.eql(u8, key, "api:users-create")) {
        \\            var db_mut = self.database;
        \\            try db_mut.insert(User, "users", .{
        \\                .id = @intCast(try db_mut.count("users") + 1),
        \\                .email = "new@user.dev",
        \\                .handle = "new_user",
        \\            });
        \\            try writer.writeAll("{\"created\":true}");
        \\            return true;
        \\        }
        \\
        \\        return false; // not handled
        \\    }
        \\
        \\  Key features:
        \\    ✓ Radix trie router with path parameters ({id})
        \\    ✓ Pre-rendered CORS headers (zero per-request overhead)
        \\    ✓ Bounded response caching for hot routes
        \\    ✓ Automatic JSON content type for API responses
        \\    ✓ Handler classification for optimal dispatch
        \\
    , .{});
}
