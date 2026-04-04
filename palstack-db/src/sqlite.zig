const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ColumnInfo = struct {
    name: []const u8,
    type: []const u8,
    notnull: bool,
    pk: bool,
};

pub const SQLite = struct {
    db: ?*c.sqlite3,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, path: [*c]const u8) !SQLite {
        var db_handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &db_handle) != c.SQLITE_OK) {
            if (db_handle != null) {
                _ = c.sqlite3_close(db_handle);
            }
            return error.ConnectionFailed;
        }
        return SQLite{ .db = db_handle, .alloc = alloc };
    }

    pub fn deinit(self: *SQLite) void {
        _ = c.sqlite3_close(self.db);
    }

    /// Sync schema: Create table or ALTER TABLE to add missing columns.
    pub fn syncSchema(self: *SQLite, comptime T: type, table: [:0]const u8) !void {
        const current_columns = self.getTableSchema(table) catch |err| {
            if (err == error.TableNotFound) {
                // Table doesn't exist, create it
                var sql_buf: [2048]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&sql_buf);
                const w = fbs.writer();

                try w.print("CREATE TABLE {s} (", .{table});
                const fields = @typeInfo(T).@"struct".fields;
                inline for (fields, 0..) |field, i| {
                    if (i > 0) try w.writeAll(", ");
                    const sqlite_type = try self.getSqliteType(field.type);
                    try w.print("{s} {s}", .{ field.name, sqlite_type });
                    if (std.mem.eql(u8, field.name, "id")) {
                        try w.writeAll(" PRIMARY KEY");
                    }
                }
                try w.writeAll(");");
                try w.writeByte(0);
                return self.exec(@ptrCast(&sql_buf));
            }
            return err;
        };
        defer self.alloc.free(current_columns);

        // Table exists, check for missing columns
        const fields = @typeInfo(T).@"struct".fields;
        inline for (fields) |field| {
            var found = false;
            for (current_columns) |col| {
                if (std.mem.eql(u8, col.name, field.name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                // ALTER TABLE table ADD COLUMN ...
                std.debug.print("[ORM] Adding column {s} to {s}\n", .{ field.name, table });
                var sql_buf: [512]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&sql_buf);
                const w = fbs.writer();
                const sqlite_type = try self.getSqliteType(field.type);
                try w.print("ALTER TABLE {s} ADD COLUMN {s} {s};", .{ table, field.name, sqlite_type });
                try w.writeByte(0);
                try self.exec(@ptrCast(&sql_buf));
            }
        }
    }

    pub fn getTableSchema(self: *SQLite, table: [:0]const u8) ![]ColumnInfo {
        var sql_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        try fbs.writer().print("PRAGMA table_info({s});", .{table});
        try fbs.writer().writeByte(0);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, @ptrCast(&sql_buf), -1, &stmt, null) != c.SQLITE_OK) {
            return error.QueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var columns = std.ArrayListUnmanaged(ColumnInfo).empty;
        errdefer {
            for (columns.items) |col| self.alloc.free(col.name);
            columns.deinit(self.alloc);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = c.sqlite3_column_text(stmt, 1);
            const type_name = c.sqlite3_column_text(stmt, 2);
            const notnull = c.sqlite3_column_int(stmt, 3) != 0;
            const pk = c.sqlite3_column_int(stmt, 5) != 0;

            try columns.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, std.mem.span(name)),
                .type = try self.alloc.dupe(u8, std.mem.span(type_name)),
                .notnull = notnull,
                .pk = pk,
            });
        }

        if (columns.items.len == 0) return error.TableNotFound;
        return try columns.toOwnedSlice(self.alloc);
    }

    fn getSqliteType(self: *SQLite, comptime T: type) anyerror![]const u8 {
        return switch (@typeInfo(T)) {
            .int => "INTEGER",
            .bool => "INTEGER",
            .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8) "TEXT" else "BLOB",
            .optional => |opt_info| try self.getSqliteType(opt_info.child),
            else => "BLOB",
        };
    }

    /// Execute raw SQL (CREATE TABLE, etc.)
    pub fn exec(self: *SQLite, sql: [*c]const u8) !void {
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql, null, null, &err_msg) != c.SQLITE_OK) {
            std.debug.print("SQLite execute failed: {s}\n", .{err_msg});
            c.sqlite3_free(err_msg);
            return error.QueryFailed;
        }
    }

    /// Insert a struct value into a table. 
    /// Generates: INSERT INTO <table> (field1, field2, ...) VALUES (?, ?, ...)
    pub fn insert(self: *SQLite, comptime T: type, table: [:0]const u8, value: T) !void {
        const fields = @typeInfo(T).@"struct".fields;

        // Build: INSERT INTO table (f1, f2, ...) VALUES (?, ?, ...)
        var sql_buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        const w = fbs.writer();

        try w.print("INSERT INTO {s} (", .{table});
        inline for (fields, 0..) |field, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(field.name);
        }
        try w.writeAll(") VALUES (");
        inline for (fields, 0..) |_, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("?");
        }
        try w.writeAll(");");
        try w.writeByte(0); // null-terminate

        const sql_ptr: [*c]const u8 = @ptrCast(&sql_buf);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.QueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind values
        comptime var bind_idx: c_int = 1;
        inline for (fields) |field| {
            const val = @field(value, field.name);
            try self.bindValue(stmt.?, bind_idx, field.type, val);
            bind_idx += 1;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.QueryFailed;
        }
    }

    /// Select all rows from a table, returning a slice of T.
    /// Caller owns the returned slice and must free it.
    pub fn findAll(self: *SQLite, comptime T: type, table: [:0]const u8, alloc: std.mem.Allocator) ![]T {
        var sql_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        try fbs.writer().print("SELECT * FROM {s};", .{table});
        try fbs.writer().writeByte(0);

        const sql_ptr: [*c]const u8 = @ptrCast(&sql_buf);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.QueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var results: std.ArrayListUnmanaged(T) = .empty;
        errdefer results.deinit(alloc);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var row: T = undefined;
            const fields = @typeInfo(T).@"struct".fields;
            comptime var col: c_int = 0;
            inline for (fields) |field| {
                @field(row, field.name) = try self.readColumn(field.type, stmt.?, col, alloc);
                col += 1;
            }
            try results.append(alloc, row);
        }

        return results.toOwnedSlice(alloc);
    }

    /// Delete a row by integer id.
    pub fn deleteById(self: *SQLite, table: [:0]const u8, id: i32) !void {
        var sql_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        try fbs.writer().print("DELETE FROM {s} WHERE id = ?;", .{table});
        try fbs.writer().writeByte(0);

        const sql_ptr: [*c]const u8 = @ptrCast(&sql_buf);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.QueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int(stmt, 1, @as(c_int, id));

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.QueryFailed;
        }
    }

    /// Count rows in a table.
    pub fn count(self: *SQLite, table: [:0]const u8) !i32 {
        var sql_buf: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        try fbs.writer().print("SELECT COUNT(*) FROM {s};", .{table});
        try fbs.writer().writeByte(0);

        const sql_ptr: [*c]const u8 = @ptrCast(&sql_buf);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.QueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return c.sqlite3_column_int(stmt, 0);
        }
        return 0;
    }

    // ── Internal helpers ────────────────────────────────────────────────

    fn bindValue(self: *SQLite, stmt: *c.sqlite3_stmt, idx: c_int, comptime T: type, val: T) !void {
        switch (@typeInfo(T)) {
            .int => _ = c.sqlite3_bind_int(stmt, idx, @as(c_int, @intCast(val))),
            .bool => _ = c.sqlite3_bind_int(stmt, idx, if (val) @as(c_int, 1) else @as(c_int, 0)),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    _ = c.sqlite3_bind_text(stmt, idx, @ptrCast(val.ptr), @intCast(val.len), null);
                }
            },
            .optional => {
                if (val) |v| {
                    try self.bindValue(stmt, idx, @typeInfo(T).optional.child, v);
                } else {
                    _ = c.sqlite3_bind_null(stmt, idx);
                }
            },
            else => {},
        }
    }

    fn readColumn(self: *SQLite, comptime T: type, stmt: *c.sqlite3_stmt, col: c_int, alloc: std.mem.Allocator) !T {
        switch (@typeInfo(T)) {
            .int => return @intCast(c.sqlite3_column_int(stmt, col)),
            .bool => return c.sqlite3_column_int(stmt, col) != 0,
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    const text = c.sqlite3_column_text(stmt, col);
                    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
                    if (text) |t| {
                        const src = @as([*]const u8, @ptrCast(t))[0..len];
                        return try alloc.dupe(u8, src);
                    }
                    return try alloc.dupe(u8, "");
                }
                return error.QueryFailed;
            },
            .optional => |opt_info| {
                if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) {
                    return null;
                }
                return try self.readColumn(opt_info.child, stmt, col, alloc);
            },
            else => return error.QueryFailed,
        }
    }
};
