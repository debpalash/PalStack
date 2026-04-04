# ⚡ ZigStack

> A next-generation fullstack framework fusing the reactive brilliance of **Solid v2**, the raw HTTP throughput of **TurboAPI**, and the compile-time JSX-to-Zig magic of **Ziex**.

---

## Architecture

ZigStack is structured as three composable Zig packages:

```
zigstack/
├── zigstack-core/      # Shared primitives (router, CORS, cache, validator)
├── zigstack-signals/   # Reactive state (Signal, Memo, Effect, Store)
├── zigstack-server/    # HTTP server (thread pool, handler dispatch, SSR)
└── example/            # Demo application
```

### What comes from where

| Feature | Source | Enhancement |
|---|---|---|
| **Radix trie router** | turboapi-core | + route metadata (page/API/asset), handler classification, SSR config |
| **Zero-overhead CORS** | TurboAPI | Extracted to standalone module with header injection validation |
| **Response caching** | TurboAPI | + TTL expiry, static/dynamic tiers, bounded entries |
| **JSON validation** | TurboAPI dhi_validator | + **compile-time schema generation** from Zig structs |
| **Signal / Memo / Effect** | Solid v2 concepts | Zig-native implementation with component-level reactivity |
| **Store with patches** | Solid v2 createStore/createDeepProxy | Compile-time typed field mutations, patch buffer for SSR→client streaming |
| **Server(AppCtx)** | Ziex Server(H) | + TurboAPI's thread pool, handler classification dispatch |
| **File-system routing** | Ziex | Compile-time route generation from pages/ directory |
| **JSX-in-Zig (.zx)** | Ziex transpiler | Planned: + template hoisting, hydration markers |

### Design Decisions

**Why not Solid's fine-grained reactivity in Zig?**

Solid v2 tracks individual signal reads at the DOM binding level — the component function never re-runs. This requires JavaScript Proxies and direct DOM API access, neither of which exist in WASM. Instead, ZigStack adopts Solid's **concept taxonomy** (Signal, Memo, Effect, Store) with Ziex's **execution model** (component-level re-render). Zig's compile-time guarantees eliminate many runtime overhead concerns that make Solid's approach necessary in JS.

**Why TurboAPI's router over httpz?**

TurboAPI's radix trie is more optimized: compressed prefix nodes, priority-based child ordering, O(1) method dispatch via enum indexing into 8 separate tries, and zero-alloc stack-based `RouteParams`. All preserved and extended with fullstack route metadata.

**Why compile-time schema validation?**

TurboAPI parses JSON schema descriptors at runtime (sent from Python). ZigStack uses `comptime` reflection to auto-generate schemas directly from Zig struct types — the type IS the validation spec, with zero runtime cost for schema construction.

---

## Quick Start

```zig
const std = @import("std");
const core = @import("zigstack-core");
const signals = @import("zigstack-signals");
const zs = @import("zigstack-server");

const App = struct { db: *Database };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    
    var server = try zs.Server(App).init(alloc, .{
        .port = 8080,
        .cors = .{ .origins = "*" },
    }, .{ .db = &db });
    defer server.deinit();

    // Page routes (SSR)
    try server.page("/", "page:index", .ssr);
    try server.page("/blog/{slug}", "page:blog-post", .ssr);
    
    // API routes
    try server.api("GET", "/api/users", "api:users");
    try server.api("POST", "/api/users", "api:users-create");
    
    try server.start();
}
```

## Reactive State

```zig
const signals = @import("zigstack-signals");

// Signal — basic reactive state
const count = try signals.Signal(i32).create(alloc, "counter", 0, 0);
count.set(count.get() + 1);  // triggers re-render on client

// Memo — derived computation
const doubled = try signals.Memo(i32).create(alloc, computeDouble, count, 0);

// Store — structured state with patch tracking
const UserStore = signals.Store(struct { name: []const u8, age: u32 });
const user = try UserStore.create(alloc, "user-card", 0, .{ .name = "Alice", .age = 30 });
user.set(.name, "Bob");  // records patch for SSR streaming
```

## Validated API Routes

```zig
const Validator = @import("zigstack-core").Validator;

const CreateUser = struct {
    name: []const u8,
    email: []const u8,
    age: ?u32,
};

// Schema auto-generated at compile time from struct
const schema = comptime Validator.schemaFromType(CreateUser, "CreateUser");

// Validate incoming JSON before handler
switch (Validator.validateJson(alloc, body, &schema)) {
    .ok => {}, // proceed
    .err => |e| return ctx.validationError(e),
}
```

---

## Build & Test

```bash
# Run all tests
zig build test

# Build and run example
zig build example

# Cross-compile for Linux
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
```

## Performance Targets

| Metric | Target | Source |
|---|---|---|
| API requests/sec (JSON) | >140,000 | TurboAPI baseline |
| Static response latency | <5μs | Pre-rendered, single writeAll |
| SSR page render | <1ms | Streaming, async boundaries |
| Binary size | <5MB | Single executable, no runtime |
| Memory per connection | <16KB | Stack-based buffers |

---

## Roadmap

- [x] Phase 1: Core infrastructure (router, CORS, cache, server)
- [x] Phase 2: Reactive runtime (Signal, Memo, Effect, Store)
- [ ] Phase 3: Frontend compiler (ZX transpiler integration)
- [x] Phase 4: API layer (handler classification, validation)
- [ ] Phase 5: DX tooling (CLI, hot-reload, introspection)
- [ ] Phase 6: Deployment (Docker, WASM edge, static export)

## License

MIT
