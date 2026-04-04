// PalStack Example 02: Reactive Signals
//
// Demonstrates Signal, Memo, and Effect — the reactive primitives
// that power server-side state management in PalStack.
//
// Signals are fine-grained reactive values. When a Signal changes,
// any Memo or Effect that depends on it is automatically invalidated.

const std = @import("std");

// In a real project: const signals = @import("palstack-signals");

pub fn main() !void {
    std.debug.print(
        \\
        \\  PalStack — Reactive Signals Example
        \\  ====================================
        \\
        \\  PalStack provides three reactive primitives:
        \\
        \\  1. Signal(T) — A reactive value container
        \\     const count = try Signal(i32).create(alloc, "count", 0, 0);
        \\     count.set(42);           // update value
        \\     const v = count.get();   // read value (42)
        \\
        \\  2. Memo(T) — A derived/computed value
        \\     const doubled = try Memo(i32).create(alloc, "doubled", 0, struct {
        \\         fn compute() i32 {
        \\             return count.get() * 2;
        \\         }
        \\     }.compute);
        \\     // doubled.get() == 84 (auto-computed from count)
        \\
        \\  3. Effect — Side-effect that runs when dependencies change
        \\     const logger = try Effect.create(alloc, "log-effect", 0, struct {
        \\         fn run() void {
        \\             std.debug.print("Count changed: {d}\n", .{count.get()});
        \\         }
        \\     }.run);
        \\
        \\  Signals integrate with HTMX for surgical DOM updates:
        \\     - Server renders HTML with signal values
        \\     - HTMX swaps updated fragments when signals change
        \\     - No client-side JS framework needed
        \\
    , .{});
}
