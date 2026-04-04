const std = @import("std");
const ts = @import("tree_sitter");
const ts_zx = @import("tree_sitter_zx");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    
    var arena = std.heap.ArenaAllocator.init(gpa_state.allocator());
    defer arena.deinit();
    
    const alloc = arena.allocator();

    var args = try std.process.argsWithAllocator(alloc);

    _ = args.next(); // exe
    const in_dir = args.next() orelse return error.MissingInput;
    const out_dir = args.next() orelse return error.MissingOutput;
    const public_dir = args.next() orelse return error.MissingPublicInput;

    std.fs.cwd().makeDir(out_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    
    // Create assets subdirectory in the cache
    const out_assets_dir = try std.fs.path.join(alloc, &.{ out_dir, "assets" });
    defer alloc.free(out_assets_dir);
    std.fs.cwd().makeDir(out_assets_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var parser = ts.Parser.create();
    defer parser.destroy();
    
    // Ziex grammar
    const lang = ts_zx.language();
    try parser.setLanguage(@ptrCast(lang));

    var dir = std.fs.cwd().openDir(in_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var routes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer routes.deinit(alloc);

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".psx")) {
            const in_path = try std.fs.path.join(alloc, &.{ in_dir, entry.path });
            defer alloc.free(in_path);

            const file_content = try std.fs.cwd().readFileAlloc(alloc, in_path, 1024 * 1024);
            defer alloc.free(file_content);

            const tree_opt = parser.parseString(file_content, null);
            if (tree_opt == null) continue;
            const tree = tree_opt.?;
            defer tree.destroy();

            const root_node = tree.rootNode();
            
            const out_name = try std.mem.replaceOwned(u8, alloc, entry.basename, ".psx", ".zig");
            defer alloc.free(out_name);
            
            const out_path = try std.fs.path.join(alloc, &.{ out_dir, out_name });
            defer alloc.free(out_path);
            
            var f = try std.fs.cwd().createFile(out_path, .{});
            
            try f.writeAll("const std = @import(\"std\");\nconst signals = @import(\"palstack-signals\");\n\n");
            
            // Extract custom components manually for the MVP AST mapping
            var line_it = std.mem.splitScalar(u8, file_content, '\n');
            while (line_it.next()) |line| {
                if (std.mem.indexOf(u8, line, "import {") != null and std.mem.indexOf(u8, line, "palstack") == null) {
                    if (std.mem.indexOf(u8, line, "} from")) |end_brace| {
                        const start_brace = std.mem.indexOf(u8, line, "{") orelse 0;
                        if (start_brace < end_brace) {
                            const comp_str = std.mem.trim(u8, line[start_brace + 1 .. end_brace], " \t");
                            const import_line = try std.fmt.allocPrint(alloc, "const {s} = @import(\"{s}.zig\");\n", .{comp_str, comp_str});
                            try f.writeAll(import_line);
                            alloc.free(import_line);
                        }
                    }
                } // Fallback to AST transpiler
            }

            try f.writeAll("\npub fn render(alloc: std.mem.Allocator, writer: anytype, this: anytype) !void {\n");
            try walkNode(alloc, f, root_node, file_content);
            try f.writeAll("}\n");
            f.close();

            // Track route
            const route_mod = try alloc.dupe(u8, entry.path[0 .. entry.path.len - 4]);
            try routes.append(alloc, route_mod);
            std.debug.print("[Transpiler] Compiled {s} -> {s}\n", .{ entry.path, out_path });
        }
    }

    // Asset Bundling Pipeline
    var public_dir_obj = std.fs.cwd().openDir(public_dir, .{ .iterate = true }) catch null;
    if (public_dir_obj) |*pd_ptr| {
        var pd = pd_ptr.*;
        if (pd.walk(alloc)) |*p_walker_ptr| {
            var p_walker = p_walker_ptr.*;
            
            const assets_zig_path = try std.fs.path.join(alloc, &.{ out_dir, "assets.zig" });
            var af = try std.fs.cwd().createFile(assets_zig_path, .{});
            
            try af.writeAll("const std = @import(\"std\");\n\n");
            try af.writeAll("pub const Asset = struct { path: []const u8, data: []const u8 };\n\n");
            try af.writeAll("pub const embedded_assets = [_]Asset{\n");

            while (p_walker.next() catch null) |p_entry| {
                if (p_entry.kind == .file) {
                    const src_p = try std.fs.path.join(alloc, &.{ public_dir, p_entry.path });
                    const dest_p = try std.fs.path.join(alloc, &.{ out_assets_dir, p_entry.path });
                    
                    if (std.fs.path.dirname(dest_p)) |parent_dir| {
                        std.fs.cwd().makePath(parent_dir) catch {};
                    }
                    
                    std.fs.cwd().copyFile(src_p, std.fs.cwd(), dest_p, .{}) catch continue;
                    
                    const em = try std.fmt.allocPrint(alloc, "    .{{ .path = \"/assets/{s}\", .data = @embedFile(\"assets/{s}\") }},\n", .{ p_entry.path, p_entry.path });
                    try af.writeAll(em);
                    alloc.free(em);
                    alloc.free(src_p);
                    alloc.free(dest_p);
                }
            }
            
            try af.writeAll("};\n");
            af.close();
        } else |_| {}
        pd.close();
    }

    // Generate routes.zig in same dir
    const routes_path = try std.fs.path.join(alloc, &.{ out_dir, "routes.zig" });
    var rf = try std.fs.cwd().createFile(routes_path, .{});
    defer rf.close();

    try rf.writeAll("const std = @import(\"std\");\n\n");
    for (routes.items, 0..) |path, i| {
        const imp = try std.fmt.allocPrint(alloc, "const comp_{d} = @import(\"{s}.zig\");\n", .{i, path});
        try rf.writeAll(imp);
        alloc.free(imp);
    }
    
    try rf.writeAll("\npub fn initRoutes(server: anytype) !void {\n");
    for (routes.items) |path| {
        var base_path = path;
        if (std.mem.eql(u8, path, "index")) {
            base_path = "/";
        } else {
            // Need to fix / but keep basic mapping
            if (path[0] != '/') {
                const lp = try std.fmt.allocPrint(alloc, "    try server.page(\"/{s}\", \"page:{s}\", .ssr);\n", .{path, path});
                try rf.writeAll(lp);
                alloc.free(lp);
                continue;
            }
        }
        const lp2 = try std.fmt.allocPrint(alloc, "    try server.page(\"{s}\", \"page:{s}\", .ssr);\n", .{base_path, path});
        try rf.writeAll(lp2);
        alloc.free(lp2);
    }
    try rf.writeAll("}\n\n");
    
    try rf.writeAll("pub fn renderPage(alloc: std.mem.Allocator, writer: anytype, handler_key: []const u8, props: anytype) !void {\n");
    for (routes.items, 0..) |path, i| {
        const rp = try std.fmt.allocPrint(alloc, "    if (std.mem.eql(u8, handler_key, \"page:{s}\")) {{ try comp_{d}.render(alloc, writer, props); return; }}\n", .{path, i});
        try rf.writeAll(rp);
        alloc.free(rp);
    }
    try rf.writeAll("    return error.RouteNotFound;\n}\n");
}

fn walkNode(alloc: std.mem.Allocator, f: std.fs.File, node: ts.Node, src: []const u8) !void {
    _ = node;
    
    // Naive string extraction for the PSX demo
    const start_idx = std.mem.indexOf(u8, src, "return (") orelse return;
    const end_idx = std.mem.lastIndexOf(u8, src, ");") orelse return;
    
    // Extract everything between `() {` and `return (`
    const fn_start = std.mem.indexOf(u8, src, "() {") orelse 0;
    if (fn_start < start_idx and fn_start > 0) {
        const top_logic = src[fn_start + 4 .. start_idx];
        var top_lines = std.mem.splitScalar(u8, top_logic, '\n');
        while (top_lines.next()) |line| {
            // Write the line verbatim to zig, as long as it's not a syntax error
            // Assuming the psx file contains valid zig syntax for setup
            try f.writeAll(line);
            try f.writeAll("\n");
        }
    }

    if (start_idx < end_idx) {
        const body = src[start_idx + 8 .. end_idx];
        
        // Simple brace substitution for the demo
        var i: usize = 0;
        var in_brace = false;
        var text_start = i;
        var brace_start: usize = 0;
        
        while (i < body.len) : (i += 1) {
            if (body[i] == '{') {
                if (!in_brace) {
                    // Check for {{ (Literal {)
                    if (i + 1 < body.len and body[i + 1] == '{') {
                         if (i > text_start) {
                             try f.writeAll("    try writer.writeAll(&[_]u8{ ");
                             for (body[text_start .. i]) |c| {
                                 var buf: [16]u8 = undefined;
                                 try f.writeAll(try std.fmt.bufPrint(&buf, "{d},", .{c}));
                             }
                             try f.writeAll(" });\n");
                         }
                         try f.writeAll("    try writer.writeAll(\"{\");\n");
                         i += 1;
                         text_start = i + 1;
                         continue;
                    }
                    if (i > text_start) {
                        try f.writeAll("    try writer.writeAll(&[_]u8{ ");
                        for (body[text_start..i]) |c| {
                            var buf: [16]u8 = undefined;
                            try f.writeAll(try std.fmt.bufPrint(&buf, "{d},", .{c}));
                        }
                        try f.writeAll(" });\n");
                    }
                    in_brace = true;
                    brace_start = i + 1;
                }
            } else if (body[i] == '<' and !in_brace) {
                if (i + 1 < body.len and std.ascii.isUpper(body[i + 1])) {
                    if (i > text_start) {
                        try f.writeAll("    try writer.writeAll(&[_]u8{ ");
                        for (body[text_start..i]) |c| {
                            var buf: [16]u8 = undefined;
                            try f.writeAll(try std.fmt.bufPrint(&buf, "{d},", .{c}));
                        }
                        try f.writeAll(" });\n");
                    }
                    
                    var comp_end = i + 1;
                    while (comp_end < body.len and (std.ascii.isAlphanumeric(body[comp_end]) or body[comp_end] == '.')) {
                        comp_end += 1;
                    }
                    
                    const comp_name = body[i + 1 .. comp_end];
                    
                    var tag_end = comp_end;
                    while (tag_end < body.len and body[tag_end] != '>') {
                        tag_end += 1;
                    }
                    
                    if (tag_end < body.len and body[tag_end] == '>') {
                        const call_line = try std.fmt.allocPrint(alloc, "    try {s}.render(alloc, writer, .{{}}); // TODO: Add prop parsing in V3\n", .{comp_name});
                        try f.writeAll(call_line);
                        alloc.free(call_line);
                        
                        i = tag_end;
                        text_start = i + 1;
                    }
                }
            } else if (body[i] == '}') {
                if (in_brace) {
                    const expr = std.mem.trim(u8, body[brace_start..i], " \n\r\t");
                    const expr_line = try std.fmt.allocPrint(alloc, "    try writer.print(\"{{any}}\", .{{{s}}});\n", .{ expr });
                    try f.writeAll(expr_line);
                    alloc.free(expr_line);
                    in_brace = false;
                    text_start = i + 1;
                } else if (i + 1 < body.len and body[i + 1] == '}') {
                    // Literal }
                    if (i > text_start) {
                         try f.writeAll("    try writer.writeAll(&[_]u8{ ");
                         for (body[text_start .. i]) |c| {
                             var buf: [16]u8 = undefined;
                             try f.writeAll(try std.fmt.bufPrint(&buf, "{d},", .{c}));
                         }
                         try f.writeAll(" });\n");
                    }
                    try f.writeAll("    try writer.writeAll(\"}\");\n");
                    i += 1;
                    text_start = i + 1;
                }
            }
        }
        
        if (text_start < body.len) {
            try f.writeAll("    try writer.writeAll(&[_]u8{ ");
            for (body[text_start..]) |c| {
                var buf: [16]u8 = undefined;
                try f.writeAll(try std.fmt.bufPrint(&buf, "{d},", .{c}));
            }
            try f.writeAll(" });\n");
        }
    }
}
