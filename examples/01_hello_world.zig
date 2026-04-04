// PalStack Example 01: Hello World
//
// The minimal PalStack application. A single server with one route.
//
// Build: zig build-exe examples/01_hello_world.zig
//        (requires palstack-server and palstack-core as dependencies)

const std = @import("std");

// In a real PalStack project, these would be module imports via build.zig:
//   const zs = @import("palstack-server");
//
// This file demonstrates the PATTERN — to actually compile it,
// hook it up via build.zig with the proper module paths.

pub fn main() !void {
    std.debug.print(
        \\
        \\  PalStack — Hello World Example
        \\  ===============================
        \\
        \\  This example demonstrates the minimal PalStack setup:
        \\
        \\    1. Create an AppContext struct (your app's state)
        \\    2. Initialize a Server with a config
        \\    3. Register routes
        \\    4. Call server.start()
        \\
        \\  Code pattern:
        \\
        \\    const AppContext = struct {
        \\        name: []const u8,
        \\    };
        \\
        \\    var server = try zs.Server(AppContext).init(alloc, .{
        \\        .port = 8080,
        \\    }, .{ .name = "My App" });
        \\    defer server.deinit();
        \\
        \\    try server.api("GET", "/hello", "api:hello");
        \\    try server.start();
        \\
        \\  That's it. Single binary. Zero dependencies.
        \\
    , .{});
}
