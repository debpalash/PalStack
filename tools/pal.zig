const std = @import("std");
const net = std.net;

var global_clients: std.ArrayListUnmanaged(net.Server.Connection) = .empty;
var clients_mutex: std.Thread.Mutex = .{};
var global_alloc: std.mem.Allocator = undefined;

// The embedded SSE Server thread
fn startSseServer() !void {
    const address = try net.Address.parseIp4("127.0.0.1", 3001);
    var server = try address.listen(.{ .reuse_address = true });
    
    while (true) {
        if (server.accept()) |conn| {
            // Read basic GET request
            var buf: [1024]u8 = undefined;
            _ = conn.stream.read(&buf) catch {
                conn.stream.close();
                continue;
            };
            
            // Upgrade to Server-Sent-Events
            const response = 
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Cache-Control: no-cache\r\n" ++
                "Connection: keep-alive\r\n" ++
                "Access-Control-Allow-Origin: *\r\n\r\n";
            
            conn.stream.writeAll(response) catch {
                conn.stream.close();
                continue;
            };
            
            clients_mutex.lock();
            global_clients.append(global_alloc, conn) catch {
                conn.stream.close();
            };
            clients_mutex.unlock();
        } else |err| {
            std.debug.print("SSE Server accept error: {}\n", .{err});
        }
    }
}

// Broadcast reload signal to all active browsers
fn broadcastReload() void {
    clients_mutex.lock();
    defer clients_mutex.unlock();
    
    var valid_clients: std.ArrayListUnmanaged(net.Server.Connection) = .empty;
    
    for (global_clients.items) |conn| {
        if (conn.stream.writeAll("data: reload\n\n")) |_| {
            valid_clients.append(global_alloc, conn) catch {};
        } else |_| {
            conn.stream.close();
        }
    }
    
    global_clients.deinit(global_alloc);
    global_clients = valid_clients;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    global_alloc = alloc;



    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next(); // skip exe
    const cmd = args.next() orelse {
        std.debug.print("Usage: pal <dev|build>\n", .{});
        return;
    };

    if (std.mem.eql(u8, cmd, "dev")) {
        std.debug.print("🚀 Booting PalStack Native Dev Engine...\n", .{});
        
        // Boot SSE HMR Thread
        _ = try std.Thread.spawn(.{}, startSseServer, .{});
        std.debug.print("📡 Native HMR Server ready at http://localhost:3001/hmr\n", .{});
        
        // 1. Ensure Tailwind CLI is available (Standalone binary)
        const tailwind_bin = "tools/tailwindcss";
        if (std.fs.cwd().access(tailwind_bin, .{}) == error.FileNotFound) {
            std.debug.print("📥 Downloading Tailwind Standalone CLI (Zero-dependency Mode)...\n", .{});
            
            const arch = if (comptime @import("builtin").cpu.arch == .aarch64) "macos-arm64" else "macos-x64";
            const url = try std.fmt.allocPrint(alloc, "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-{s}", .{arch});
            defer alloc.free(url);

            var curl_proc = std.process.Child.init(&.{ "curl", "-L", "-o", tailwind_bin, url }, alloc);
            _ = try curl_proc.spawnAndWait();
            
            var chmod_proc = std.process.Child.init(&.{ "chmod", "+x", tailwind_bin }, alloc);
            _ = try chmod_proc.spawnAndWait();
            std.debug.print("✅ Tailwind Standalone CLI ready.\n", .{});
        }

        // 2. Boot Tailwind Ghost Process (using standalone CLI)
        var tailwind_proc = std.process.Child.init(&.{ "./" ++ tailwind_bin, "-i", "showcase/public/input.css", "-o", "showcase/public/styles.css", "--watch" }, alloc);
        tailwind_proc.spawn() catch |err| {
            std.debug.print("⚠️ Tailwind Ghost Process failed to start: {}.\n", .{err});
        };
        std.debug.print("🌬️  Tailwind Standalone CLI spawned natively\n", .{});

        var active_server: ?std.process.Child = null;

        var last_modified: i128 = 0;
        var first_boot = true;
        
        while (true) {
            var curr_mod: i128 = 0;
            
            // Scan showcase/pages recursively
            if (std.fs.cwd().openDir("showcase/pages", .{ .iterate = true })) |*dir_ptr| {
                var dir_val = dir_ptr.*;
                var it = dir_val.iterate();
                while (it.next() catch null) |entry| {
                    if (std.mem.endsWith(u8, entry.name, ".psx")) {
                        if (dir_val.statFile(entry.name) catch null) |stat| {
                            if (stat.mtime > curr_mod) {
                                curr_mod = stat.mtime;
                            }
                        }
                    }
                }
                dir_val.close();
            } else |_| {}
            
            // Scan showcase/public for css changes
            if (std.fs.cwd().openDir("showcase/public", .{ .iterate = true })) |*dir_ptr| {
                var dir_val = dir_ptr.*;
                var it = dir_val.iterate();
                while (it.next() catch null) |entry| {
                    if (std.mem.endsWith(u8, entry.name, ".css")) {
                        if (dir_val.statFile(entry.name) catch null) |stat| {
                            if (stat.mtime > curr_mod) {
                                curr_mod = stat.mtime;
                            }
                        }
                    }
                }
                dir_val.close();
            } else |_| {}

            if (first_boot or (curr_mod > last_modified and last_modified != 0)) {
                if (!first_boot) std.debug.print("🔥 Change detected! Recompiling Zig...\n", .{});
                
                // 1. Kill old server
                if (active_server) |*proc| {
                    _ = proc.kill() catch {};
                    _ = proc.wait() catch {};
                }
                
                // 2. Transpile and build
                var build_proc = std.process.Child.init(&.{ "zig", "build", "showcase" }, alloc);
                const build_status = build_proc.spawnAndWait() catch |err| {
                    std.debug.print("❌ Zig Process Error: {}\n", .{err});
                    continue;
                };
                
                var success = false;
                switch (build_status) {
                    .Exited => |code| if (code == 0) { success = true; },
                    else => {},
                }
                
                if (success) {
                    // 3. Start new server
                    var new_server = std.process.Child.init(&.{ "./zig-out/bin/palstack-showcase" }, alloc);
                    new_server.spawn() catch |err| {
                        std.debug.print("❌ Failed to start PalStack target: {}\n", .{err});
                    };
                    active_server = new_server;
                    std.debug.print("✨ Engine Rebuilt + Restarted.\n", .{});
                    
                    if (!first_boot) broadcastReload();
                } else {
                    std.debug.print("❌ Compilation Failed! Waiting for changes...\n", .{});
                }
                
                last_modified = curr_mod;
                first_boot = false;
            }
            
            // If we initialize empty, set last_modified so we don't spam
            if (last_modified == 0) last_modified = curr_mod;

            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
    }
}
