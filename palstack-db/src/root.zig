const std = @import("std");

pub const sqlite = @import("sqlite.zig");
pub const postgres = @import("postgres.zig");
pub const schema = @import("schema.zig");

// Database Client Wrapper (Selects Postgres vs SQLite automatically)
pub const Client = union(enum) {
    sqlite: sqlite.SQLite,
    postgres: postgres.Postgres,

    pub fn initAuto(alloc: std.mem.Allocator) !Client {
        const builtin = @import("builtin");
        if (comptime builtin.cpu.arch.isWasm()) {
            return Client{ .postgres = try postgres.Postgres.init(alloc) };
        } else {
            return Client{ .sqlite = try sqlite.SQLite.init(alloc, "showcase.db") };
        }
    }

    pub fn syncSchema(self: *Client, comptime T: type, table: [:0]const u8) !void {
        switch (self.*) {
            .sqlite => |*db| try db.syncSchema(T, table),
            .postgres => |*_db| {
                _ = _db;
            },
        }
    }

    pub fn exec(self: *Client, sql: [*:0]const u8) !void {
        switch (self.*) {
            .sqlite => |*db| try db.exec(sql),
            .postgres => |*db| try db.exec(sql),
        }
    }

    pub fn insert(self: *Client, comptime T: type, table: [:0]const u8, value: T) !void {
        switch (self.*) {
            .sqlite => |*db| try db.insert(T, table, value),
            .postgres => |*_db| {
                // PGlite insert would go through JS bridge — not yet implemented
                _ = _db;
            },
        }
    }

    pub fn findAll(self: *Client, comptime T: type, table: [:0]const u8, alloc: std.mem.Allocator) ![]T {
        switch (self.*) {
            .sqlite => |*db| return try db.findAll(T, table, alloc),
            .postgres => |*_db| {
                _ = _db;
                return &.{};
            },
        }
    }

    pub fn deleteById(self: *Client, table: [:0]const u8, id: i32) !void {
        switch (self.*) {
            .sqlite => |*db| try db.deleteById(table, id),
            .postgres => |*_db| {
                _ = _db;
            },
        }
    }

    pub fn count(self: *Client, table: [:0]const u8) !i32 {
        switch (self.*) {
            .sqlite => |*db| return try db.count(table),
            .postgres => |*_db| {
                _ = _db;
                return 0;
            },
        }
    }

    pub fn getDialect(self: *const Client) Dialect {
        return switch (self.*) {
            .sqlite => .SQLite,
            .postgres => .Postgres,
        };
    }
};

// Database configuration struct to standardize options across dialects
pub const DatabaseConfig = struct {
    dialect: Dialect,
    connection_string: []const u8,
};

pub const Dialect = enum {
    SQLite,
    Postgres,
};

// Error set for the database module
pub const DbError = error{
    ConnectionFailed,
    QueryFailed,
    MigrationFailed,
    InvalidSchema,
    NotImplemented,
};
