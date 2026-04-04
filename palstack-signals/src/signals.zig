// ZigStack Signals — Reactive primitives for state management.
//
// Inspired by Solid v2's signal concepts, built on Ziex's State(T) execution model.
//
// Design rationale:
//   Solid v2 uses fine-grained reactivity where signal reads are tracked and
//   individual DOM bindings are updated without re-running the component.
//   This requires JS proxies and a DOM API — unavailable in Zig/WASM.
//
//   Instead, we adopt Solid's *concepts* (signals, memos, effects, stores)
//   but use Ziex's *execution model* (component-level re-render + diff).
//   The key insight: Zig's compile-time guarantees eliminate many of the
//   runtime overhead concerns that make Solid's approach necessary in JS.
//
// Architecture:
//   Server (SSR): Pull-based — values computed on read (like Solid v2 server/signals.ts)
//   Client (WASM): Push-based — mutations trigger component re-render (like Ziex reactivity.zig)

const std = @import("std");
const builtin = @import("builtin");

// ── Platform detection ──────────────────────────────────────────────────────

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Global allocator — set by the runtime during initialization.
var _global_alloc: ?std.mem.Allocator = null;

pub fn setGlobalAllocator(alloc: std.mem.Allocator) void {
    _global_alloc = alloc;
}

fn globalAlloc() std.mem.Allocator {
    return _global_alloc orelse std.heap.page_allocator;
}

// ── Render scheduling ───────────────────────────────────────────────────────

/// Function pointer for triggering component re-renders.
/// Set by the client runtime during initialization.
var _schedule_render: ?*const fn (component_id: []const u8) void = null;
var _schedule_render_all: ?*const fn () void = null;

pub fn setRenderScheduler(
    render_fn: *const fn ([]const u8) void,
    render_all_fn: *const fn () void,
) void {
    _schedule_render = render_fn;
    _schedule_render_all = render_all_fn;
}

fn scheduleRender(component_id: []const u8) void {
    if (_schedule_render) |f| {
        f(component_id);
    }
}

// ── Signal(T) — Reactive state primitive ────────────────────────────────────

/// A reactive state container. Equivalent to Solid's `createSignal`.
///
/// Server mode: Plain value read/write (pull-based, no tracking).
/// Client mode: Mutations trigger component re-render via scheduleRender.
///
/// Usage:
/// ```zig
/// const count = try Signal(i32).create(allocator, component_id, 0, 0);
/// const value = count.get();  // Read
/// count.set(value + 1);       // Write + trigger re-render
/// ```
pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        value: T,
        component_id: []const u8,
        slot: u32,

        /// Create a new signal (or retrieve existing one on WASM).
        pub fn create(
            alloc: std.mem.Allocator,
            component_id: []const u8,
            slot: u32,
            initial: T,
        ) !*Self {
            if (is_wasm) {
                // Client: persist across re-renders using global state store
                const key = StateKey{ .component_id = component_id, .slot = slot };
                if (state_store.get(key)) |entry| {
                    return @ptrCast(@alignCast(entry.ptr));
                }

                const sig = try globalAlloc().create(Self);
                sig.* = .{ .value = initial, .component_id = component_id, .slot = slot };
                const id_copy = try globalAlloc().dupe(u8, component_id);
                try state_store.put(globalAlloc(), .{ .component_id = id_copy, .slot = slot }, .{
                    .ptr = @ptrCast(sig),
                    .getJson = &struct {
                        fn f(a: std.mem.Allocator, ptr: *anyopaque) []const u8 {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            return serializeValue(a, T, s.value);
                        }
                    }.f,
                    .applyJson = &struct {
                        fn f(ptr: *anyopaque, json: []const u8) void {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            if (deserializeValue(T, globalAlloc(), json)) |v| {
                                s.value = v;
                                scheduleRender(s.component_id);
                            }
                        }
                    }.f,
                });
                return sig;
            } else {
                // Server SSR: allocate in arena, no persistence needed
                const sig = try alloc.create(Self);
                sig.* = .{ .value = initial, .component_id = component_id, .slot = slot };
                return sig;
            }
        }

        /// Read the current value.
        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        /// Write a new value and trigger re-render (client only).
        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            if (is_wasm) scheduleRender(self.component_id);
        }

        /// Update via transform function and trigger re-render.
        pub fn update(self: *Self, transform: *const fn (T) T) void {
            self.value = transform(self.value);
            if (is_wasm) scheduleRender(self.component_id);
        }
    };
}

// ── Memo(T) — Computed reactive value ───────────────────────────────────────

/// A computed value that derives from other signals. Equivalent to Solid's `createMemo`.
///
/// The compute function is called:
///   Server: Once on creation (pull-based, like Solid v2 server signals).
///   Client: On every component re-render (since we use component-level reactivity).
///
/// Usage:
/// ```zig
/// const doubled = Memo(i32).create(allocator, struct {
///     fn compute(_: *const anyopaque) i32 {
///         return count.get() * 2;
///     }
/// }.compute, null);
/// const value = doubled.get();
/// ```
pub fn Memo(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        value: T,
        compute_fn: *const fn (*const anyopaque) T,
        context: ?*const anyopaque,
        computed: bool,

        pub fn create(
            alloc: std.mem.Allocator,
            compute_fn: *const fn (*const anyopaque) T,
            context: ?*const anyopaque,
            initial: T,
        ) !*Self {
            const memo = try alloc.create(Self);
            memo.* = .{
                .value = initial,
                .compute_fn = compute_fn,
                .context = context,
                .computed = false,
            };
            return memo;
        }

        /// Get the computed value. Lazy on first read.
        pub fn get(self: *Self) T {
            if (!self.computed) {
                self.recompute();
            }
            return self.value;
        }

        /// Force recomputation (called during re-render).
        pub fn recompute(self: *Self) void {
            const ctx = self.context orelse @as(*const anyopaque, @ptrFromInt(1));
            self.value = self.compute_fn(ctx);
            self.computed = true;
        }

        /// Invalidate so next get() recomputes.
        pub fn invalidate(self: *Self) void {
            self.computed = false;
        }
    };
}

// ── Effect — Side-effect on state change ────────────────────────────────────

/// A side-effect that runs when dependencies change. Equivalent to Solid's `createEffect`.
///
/// On the server, effects are no-ops (matching Solid v2's behavior).
/// On the client, effects run after component render.
///
/// Usage:
/// ```zig
/// const eff = try Effect.create(allocator, struct {
///     fn run(ctx: *const anyopaque) void {
///         const count: *const Signal(i32) = @ptrCast(@alignCast(ctx));
///         log("Count is now: {}", .{count.get()});
///     }
/// }.run, count);
/// ```
pub const Effect = struct {
    const Self = @This();

    run_fn: *const fn (*const anyopaque) void,
    context: *const anyopaque,
    cleanup_fn: ?*const fn (*const anyopaque) void,
    disposed: bool,

    pub fn create(
        alloc: std.mem.Allocator,
        run_fn: *const fn (*const anyopaque) void,
        context: *const anyopaque,
    ) !*Self {
        const eff = try alloc.create(Self);
        eff.* = .{
            .run_fn = run_fn,
            .context = context,
            .cleanup_fn = null,
            .disposed = false,
        };

        // On client, run immediately (Solid v2 behavior)
        if (is_wasm and !eff.disposed) {
            eff.run();
        }

        return eff;
    }

    /// Execute the effect.
    pub fn run(self: *Self) void {
        if (self.disposed) return;
        // Run cleanup from previous execution
        if (self.cleanup_fn) |cleanup| {
            cleanup(self.context);
        }
        self.run_fn(self.context);
    }

    /// Register a cleanup function (runs before next execution or on dispose).
    pub fn onCleanup(self: *Self, cleanup_fn: *const fn (*const anyopaque) void) void {
        self.cleanup_fn = cleanup_fn;
    }

    /// Mark effect as disposed — will not run again.
    pub fn dispose(self: *Self) void {
        if (self.cleanup_fn) |cleanup| {
            cleanup(self.context);
        }
        self.disposed = true;
    }
};

// ── State Store (WASM persistence across re-renders) ────────────────────────

const StateKey = struct {
    component_id: []const u8,
    slot: u32,

    const Context = struct {
        pub fn hash(_: Context, k: StateKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.component_id);
            h.update(std.mem.asBytes(&k.slot));
            return h.final();
        }
        pub fn eql(_: Context, a: StateKey, b: StateKey) bool {
            return a.slot == b.slot and std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

const StateEntry = struct {
    ptr: *anyopaque,
    getJson: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) []const u8,
    applyJson: *const fn (ptr: *anyopaque, json: []const u8) void,
};

var state_store = std.HashMapUnmanaged(
    StateKey,
    StateEntry,
    StateKey.Context,
    std.hash_map.default_max_load_percentage,
){};

/// Collect all state entries for a component (used by event handlers for server round-trips).
pub fn collectComponentState(
    alloc: std.mem.Allocator,
    component_id: []const u8,
    state_count: u32,
) []StateEntry {
    if (!is_wasm) return &.{};

    var list = std.ArrayList(StateEntry).init(alloc);
    for (0..state_count) |i| {
        const slot = (1 << 20) + @as(u32, @intCast(i));
        const key = StateKey{ .component_id = component_id, .slot = slot };
        if (state_store.get(key)) |entry| {
            list.append(entry) catch {};
        }
    }
    return list.toOwnedSlice() catch &.{};
}

// ── Serialization helpers ───────────────────────────────────────────────────

fn serializeValue(alloc: std.mem.Allocator, comptime T: type, value: T) []const u8 {
    _ = alloc;
    _ = value;
    return "null"; // TODO: implement JSON serialization via zxon
}

fn deserializeValue(comptime T: type, alloc: std.mem.Allocator, json: []const u8) ?T {
    _ = alloc;
    _ = json;
    return null; // TODO: implement JSON deserialization via zxon
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "signal create and read" {
    const alloc = std.testing.allocator;
    const count = try Signal(i32).create(alloc, "test-component", 0, 42);
    defer alloc.destroy(count);

    try std.testing.expectEqual(@as(i32, 42), count.get());
}

test "signal set" {
    const alloc = std.testing.allocator;
    const count = try Signal(i32).create(alloc, "test-component", 0, 0);
    defer alloc.destroy(count);

    count.set(10);
    try std.testing.expectEqual(@as(i32, 10), count.get());
}

test "signal update with transform" {
    const alloc = std.testing.allocator;
    const count = try Signal(i32).create(alloc, "test-component", 0, 5);
    defer alloc.destroy(count);

    count.update(&struct {
        fn inc(x: i32) i32 {
            return x + 1;
        }
    }.inc);
    try std.testing.expectEqual(@as(i32, 6), count.get());
}

test "memo lazy computation" {
    const alloc = std.testing.allocator;

    var base_value: i32 = 10;
    const memo = try Memo(i32).create(alloc, &struct {
        fn compute(ctx: *const anyopaque) i32 {
            const val: *const i32 = @ptrCast(@alignCast(ctx));
            return val.* * 2;
        }
    }.compute, @ptrCast(&base_value), 0);
    defer alloc.destroy(memo);

    // First read triggers computation
    try std.testing.expectEqual(@as(i32, 20), memo.get());

    // Already computed — returns cached
    try std.testing.expectEqual(@as(i32, 20), memo.get());

    // After invalidation, recomputes
    base_value = 25;
    memo.invalidate();
    try std.testing.expectEqual(@as(i32, 50), memo.get());
}

test "effect creation and disposal" {
    const alloc = std.testing.allocator;
    var run_count: u32 = 0;

    const eff = try Effect.create(alloc, &struct {
        fn run(ctx: *const anyopaque) void {
            const count: *u32 = @constCast(@ptrCast(@alignCast(ctx)));
            count.* += 1;
        }
    }.run, @ptrCast(&run_count));
    defer alloc.destroy(eff);

    // On server (non-WASM), effect doesn't auto-run
    if (!is_wasm) {
        try std.testing.expectEqual(@as(u32, 0), run_count);
    }

    // Manual run
    eff.run();
    try std.testing.expectEqual(@as(u32, 1), run_count);

    // Dispose prevents further runs
    eff.dispose();
    eff.run();
    try std.testing.expectEqual(@as(u32, 1), run_count); // Still 1
}
