// PalStack Example 03: Agentic ORM
//
// Demonstrates the Zero-Config database: define a Zig struct,
// get a table. Insert, query, and delete — all type-safe.
//
// This is the core "agentic" feature: AI agents can define
// data models as plain structs and immediately have persistence.

const std = @import("std");

// In a real project:
//   const db = @import("palstack-db");

pub fn main() !void {
    std.debug.print(
        \\
        \\  PalStack — Agentic ORM Example
        \\  ===============================
        \\
        \\  Step 1: Define your model as a plain Zig struct
        \\  ─────────────────────────────────────────────────
        \\
        \\    // db/models.zig
        \\    pub const User = struct {
        \\        id: i32,
        \\        email: []const u8,
        \\        handle: []const u8,
        \\    };
        \\
        \\    pub const Post = struct {
        \\        id: i32,
        \\        title: []const u8,
        \\        content: ?[]const u8,   // nullable
        \\        published: bool,
        \\    };
        \\
        \\  Step 2: Initialize and sync schemas (zero config)
        \\  ─────────────────────────────────────────────────
        \\
        \\    var client = try db.Client.initAuto(alloc);
        \\    const dialect = client.getDialect(); // .SQLite or .Postgres
        \\
        \\    // Auto-generates CREATE TABLE IF NOT EXISTS
        \\    const sql = try db.schema.generateCreateTable(User, "users", dialect, alloc);
        \\    try client.exec(sql);
        \\
        \\  Step 3: CRUD operations
        \\  ─────────────────────────────────────────────────
        \\
        \\    // INSERT — pass a struct instance
        \\    try client.insert(User, "users", .{
        \\        .id = 1,
        \\        .email = "agent@palstack.dev",
        \\        .handle = "pal_agent",
        \\    });
        \\
        \\    // SELECT ALL — returns []User
        \\    const users = try client.findAll(User, "users", alloc);
        \\    for (users) |user| {
        \\        std.debug.print("User: {s} ({s})\n", .{ user.handle, user.email });
        \\    }
        \\
        \\    // DELETE by id
        \\    try client.deleteById("users", 1);
        \\
        \\    // COUNT
        \\    const n = try client.count("users");
        \\    std.debug.print("Total users: {d}\n", .{n});
        \\
        \\  Key features:
        \\    ✓ Comptime schema generation from Zig structs
        \\    ✓ SQLite for native, PGlite for browser WASM
        \\    ✓ Type-safe insert/select with automatic binding
        \\    ✓ Optional fields mapped to SQL NULL
        \\    ✓ Zero SQL strings in application code
        \\
    , .{});
}
