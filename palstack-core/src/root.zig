// ZigStack Core — Shared foundation library.
//
// This module re-exports all core primitives used by the server,
// the compiler, and the client runtime.

pub const router = @import("router.zig");
pub const cors = @import("cors.zig");
pub const cache = @import("cache.zig");
pub const http = @import("http.zig");
pub const validator = @import("validator.zig");
pub const style = @import("style.zig");

pub const Router = router.Router;
pub const RouteMatch = router.RouteMatch;
pub const RouteParams = router.RouteParams;
pub const Method = router.Method;
pub const RouteMeta = router.RouteMeta;
pub const HandlerClass = router.HandlerClass;
pub const RenderMode = router.RenderMode;

pub const Cors = cors.Cors;
pub const CorsConfig = cors.CorsConfig;

pub const ResponseCache = cache.ResponseCache;
pub const CacheConfig = cache.CacheConfig;

pub const Validator = validator;
pub const ModelSchema = validator.ModelSchema;
pub const FieldConstraint = validator.FieldConstraint;

// ── Version ─────────────────────────────────────────────────────────────────

pub const version = "0.1.0";

test {
    _ = router;
    _ = cors;
    _ = cache;
    _ = validator;
}
