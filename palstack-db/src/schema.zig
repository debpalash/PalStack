const std = @import("std");
const root = @import("root.zig");

// Maps Zig types to SQL Column types based on the Dialect
pub fn getSqlType(comptime T: type, dialect: root.Dialect) []const u8 {
    return switch (@typeInfo(T)) {
        .int => "INTEGER",
        .float => "REAL",
        .bool => "BOOLEAN",
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8) "TEXT" else "BLOB",
            else => @compileError("Unsupported pointer type in schema"),
        },
        .optional => |opt_info| getSqlType(opt_info.child, dialect),
        else => @compileError("Unsupported type in schema: " ++ @typeName(T)),
    };
}

pub fn generateCreateTable(comptime T: type, table_name: []const u8, dialect: root.Dialect, alloc: std.mem.Allocator) ![:0]const u8 {
    var query: std.ArrayListUnmanaged(u8) = .empty;
    errdefer query.deinit(alloc);

    try query.writer(alloc).print("CREATE TABLE IF NOT EXISTS {s} (\n", .{table_name});

    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const sql_type = getSqlType(field.type, dialect);
        const is_primary = std.mem.eql(u8, field.name, "id");
        const pk_suffix = if (is_primary) " PRIMARY KEY" else "";
        
        const is_optional = @typeInfo(field.type) == .optional;
        const null_suffix = if (!is_optional and !is_primary) " NOT NULL" else "";

        const comma = if (i == fields.len - 1) "" else ",";
        
        try query.writer(alloc).print("    {s} {s}{s}{s}{s}\n", .{ field.name, sql_type, pk_suffix, null_suffix, comma });
    }

    try query.writer(alloc).print(");", .{});
    return query.toOwnedSliceSentinel(alloc, 0);
}

test "generate CREATE TABLE from struct" {
    const User = struct {
        id: i32,
        username: []const u8,
        active: bool,
    };
    
    const alloc = std.testing.allocator;
    const sql = try generateCreateTable(User, "users", .SQLite, alloc);
    defer alloc.free(sql);
    
    try std.testing.expect(std.mem.startsWith(u8, sql, "CREATE TABLE IF NOT EXISTS users"));
}
