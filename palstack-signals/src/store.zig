// ZigStack Store — Deep reactive state with patch tracking.
//
// Inspired by Solid v2's createStore/createDeepProxy/createProjection:
//   - Server: Mutations produce a patch log (PatchOp) for delta streaming
//   - Client: Mutations trigger component re-render
//
// Unlike Solid's JS Proxy-based deep tracking, we use explicit path-based
// mutations since Zig has no runtime proxy mechanism. This is actually
// an advantage — every mutation is statically typed and visible at compile time.
//
// Usage:
// ```zig
// const UserStore = Store(struct {
//     name: []const u8,
//     age: u32,
//     posts: []const Post,
// });
//
// var store = try UserStore.create(alloc, "my-component", 0, .{
//     .name = "Alice",
//     .age = 30,
//     .posts = &.{},
// });
//
// store.set(.name, "Bob");       // Patch: [["name"], "Bob"]
// store.set(.age, 31);           // Patch: [["age"], 31]
// const patches = store.flushPatches(); // Consume for streaming
// ```

const std = @import("std");
const builtin = @import("builtin");
const signals = @import("signals.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ── Patch Operations ────────────────────────────────────────────────────────

/// A single mutation operation for delta streaming to the client.
/// Matches Solid v2's PatchOp format: [path] | [path, value] | [path, value, insert]
pub const PatchOp = struct {
    /// Property path from root, e.g. ["users", "0", "name"]
    path: []const []const u8,
    /// The new value (serialized). Null for deletes.
    value: ?[]const u8,
    /// Operation type.
    op: Op,

    pub const Op = enum(u2) {
        /// Delete the value at path.
        delete,
        /// Set the value at path.
        set,
        /// Insert value at array index (path).
        insert,
    };
};

/// A fixed-capacity patch buffer. Avoids allocation for typical mutation batches.
pub const PatchBuffer = struct {
    const MAX_PATCHES = 64;
    const MAX_PATH_DEPTH = 8;

    items: [MAX_PATCHES]PatchOp = undefined,
    len: usize = 0,

    /// Record a set operation.
    pub fn recordSet(self: *PatchBuffer, path: []const []const u8, value: []const u8) void {
        if (self.len >= MAX_PATCHES) return;
        self.items[self.len] = .{ .path = path, .value = value, .op = .set };
        self.len += 1;
    }

    /// Record a delete operation.
    pub fn recordDelete(self: *PatchBuffer, path: []const []const u8) void {
        if (self.len >= MAX_PATCHES) return;
        self.items[self.len] = .{ .path = path, .value = null, .op = .delete };
        self.len += 1;
    }

    /// Record an insert operation (array splice).
    pub fn recordInsert(self: *PatchBuffer, path: []const []const u8, value: []const u8) void {
        if (self.len >= MAX_PATCHES) return;
        self.items[self.len] = .{ .path = path, .value = value, .op = .insert };
        self.len += 1;
    }

    /// Get all pending patches and reset.
    pub fn flush(self: *PatchBuffer) []const PatchOp {
        const result = self.items[0..self.len];
        self.len = 0;
        return result;
    }

    /// Check if there are pending patches.
    pub fn hasPending(self: *const PatchBuffer) bool {
        return self.len > 0;
    }
};

// ── Store(T) — Deep reactive state container ────────────────────────────────

/// A reactive store for structured data. Equivalent to Solid v2's createStore.
///
/// Tracks mutations as PatchOps for delta streaming (SSR → client).
/// On the client, mutations also trigger component re-render.
pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        value: T,
        component_id: []const u8,
        slot: u32,
        patches: PatchBuffer,
        /// Whether to record patches (enabled on server for streaming).
        record_patches: bool,

        pub fn create(
            alloc: std.mem.Allocator,
            component_id: []const u8,
            slot: u32,
            initial: T,
        ) !*Self {
            if (is_wasm) {
                // Client: persist across re-renders
                const key = signals.StateKey{ .component_id = component_id, .slot = slot };
                _ = key;
                // TODO: integrate with signal state_store for WASM persistence
            }

            const store = try alloc.create(Self);
            store.* = .{
                .value = initial,
                .component_id = component_id,
                .slot = slot,
                .patches = .{},
                .record_patches = !is_wasm, // Record patches on server for SSR streaming
            };
            return store;
        }

        /// Get the current snapshot.
        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        /// Get a reference to the value (for reading nested fields).
        pub inline fn ref(self: *Self) *T {
            return &self.value;
        }

        /// Set a field by comptime field name.
        /// Records a patch and triggers re-render on client.
        pub fn set(self: *Self, comptime field: std.meta.FieldEnum(T), value: std.meta.FieldType(T, field)) void {
            @field(self.value, @tagName(field)) = value;

            if (self.record_patches) {
                // TODO: serialize value to JSON for patch recording
                self.patches.recordSet(&.{@tagName(field)}, "");
            }

            if (is_wasm) {
                signals.scheduleRender(self.component_id);
            }
        }

        /// Replace the entire store value.
        pub fn replace(self: *Self, new_value: T) void {
            self.value = new_value;
            if (is_wasm) {
                signals.scheduleRender(self.component_id);
            }
        }

        /// Mutate via a callback function (like Solid's store setter).
        pub fn mutate(self: *Self, mutator: *const fn (*T) void) void {
            mutator(&self.value);
            if (is_wasm) {
                signals.scheduleRender(self.component_id);
            }
        }

        /// Flush all pending patches (for SSR streaming).
        pub fn flushPatches(self: *Self) []const PatchOp {
            return self.patches.flush();
        }

        /// Check if there are unsent patches.
        pub fn hasPendingPatches(self: *const Self) bool {
            return self.patches.hasPending();
        }
    };
}

// ── Reconcile — deep merge utility ──────────────────────────────────────────

/// Deep-merge a new value into an existing struct, field by field.
/// Equivalent to Solid v2's reconcile() utility.
pub fn reconcile(comptime T: type, target: *T, source: T) void {
    inline for (std.meta.fields(T)) |field| {
        @field(target, field.name) = @field(source, field.name);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "store create and read" {
    const alloc = std.testing.allocator;

    const User = struct {
        name: []const u8,
        age: u32,
    };

    const store = try Store(User).create(alloc, "test-comp", 0, .{
        .name = "Alice",
        .age = 30,
    });
    defer alloc.destroy(store);

    try std.testing.expectEqualStrings("Alice", store.get().name);
    try std.testing.expectEqual(@as(u32, 30), store.get().age);
}

test "store set field" {
    const alloc = std.testing.allocator;

    const Counter = struct {
        count: i32,
        label: []const u8,
    };

    const store = try Store(Counter).create(alloc, "test-comp", 0, .{
        .count = 0,
        .label = "clicks",
    });
    defer alloc.destroy(store);

    store.set(.count, 42);
    try std.testing.expectEqual(@as(i32, 42), store.get().count);
    try std.testing.expectEqualStrings("clicks", store.get().label);
}

test "store replace" {
    const alloc = std.testing.allocator;

    const Point = struct { x: f32, y: f32 };

    const store = try Store(Point).create(alloc, "test-comp", 0, .{ .x = 0, .y = 0 });
    defer alloc.destroy(store);

    store.replace(.{ .x = 10.5, .y = 20.3 });
    try std.testing.expectApproxEqAbs(@as(f32, 10.5), store.get().x, 0.01);
}

test "store mutate" {
    const alloc = std.testing.allocator;

    const State = struct { count: i32 };

    const store = try Store(State).create(alloc, "test-comp", 0, .{ .count = 0 });
    defer alloc.destroy(store);

    store.mutate(&struct {
        fn inc(state: *State) void {
            state.count += 1;
        }
    }.inc);

    try std.testing.expectEqual(@as(i32, 1), store.get().count);
}

test "store patch recording" {
    const alloc = std.testing.allocator;

    const Data = struct { name: []const u8, value: i32 };

    const store = try Store(Data).create(alloc, "test-comp", 0, .{
        .name = "test",
        .value = 0,
    });
    defer alloc.destroy(store);

    // On non-WASM (test), patches should be recorded
    if (!is_wasm) {
        store.set(.value, 10);
        store.set(.name, "updated");

        try std.testing.expect(store.hasPendingPatches());

        const patches = store.flushPatches();
        try std.testing.expectEqual(@as(usize, 2), patches.len);
        try std.testing.expect(!store.hasPendingPatches());
    }
}

test "patch buffer overflow" {
    var buf = PatchBuffer{};

    // Fill to capacity
    for (0..PatchBuffer.MAX_PATCHES) |_| {
        buf.recordSet(&.{"field"}, "value");
    }
    try std.testing.expectEqual(PatchBuffer.MAX_PATCHES, buf.len);

    // Overflow — should be silently ignored
    buf.recordSet(&.{"overflow"}, "value");
    try std.testing.expectEqual(PatchBuffer.MAX_PATCHES, buf.len);

    // Flush resets
    _ = buf.flush();
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "reconcile utility" {
    const Config = struct { host: []const u8, port: u16, debug: bool };

    var target = Config{ .host = "localhost", .port = 8080, .debug = false };
    const source = Config{ .host = "0.0.0.0", .port = 9090, .debug = true };

    reconcile(Config, &target, source);

    try std.testing.expectEqualStrings("0.0.0.0", target.host);
    try std.testing.expectEqual(@as(u16, 9090), target.port);
    try std.testing.expect(target.debug);
}
