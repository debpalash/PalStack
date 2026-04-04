const std = @import("std");
const builtin = @import("builtin");

/// Postgres Database Dialect (WASM PGlite Bridge)
pub const Postgres = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Postgres {
        return Postgres{ .alloc = alloc };
    }

    pub fn deinit(self: *Postgres) void {
        _ = self;
    }

    pub fn exec(self: *Postgres, sql: [*:0]const u8) !void {
        _ = self;
        if (comptime builtin.cpu.arch.isWasm()) {
            wasm_exec_pglite(sql);
        } else {
            std.log.info("[PG Stub] {s}", .{sql});
        }
    }

    const wasm_exec_pglite = if (builtin.cpu.arch.isWasm())
        @extern(*const fn ([*:0]const u8) callconv(.c) void, .{ .name = "wasm_exec_pglite" })
    else
        undefined;
};

