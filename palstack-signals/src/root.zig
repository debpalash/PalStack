// ZigStack Signals — Root module.

pub const signals = @import("signals.zig");
pub const store = @import("store.zig");

pub const Signal = signals.Signal;
pub const Memo = signals.Memo;
pub const Effect = signals.Effect;

pub const Store = store.Store;
pub const PatchOp = store.PatchOp;
pub const PatchBuffer = store.PatchBuffer;
pub const reconcile = store.reconcile;

pub const setGlobalAllocator = signals.setGlobalAllocator;
pub const setRenderScheduler = signals.setRenderScheduler;
pub const collectComponentState = signals.collectComponentState;
