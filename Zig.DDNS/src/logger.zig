const zzig = @import("zzig");

pub const Level = zzig.Logger.Level;
pub const setLevel = zzig.Logger.setLevel;
pub const enableThreadSafe = zzig.Logger.enableThreadSafe;
pub const disableThreadSafe = zzig.Logger.disableThreadSafe;
pub const isThreadSafe = zzig.Logger.isThreadSafe;
pub const debug = zzig.Logger.debug;
pub const info = zzig.Logger.info;
pub const warn = zzig.Logger.warn;
pub const err = zzig.Logger.err;
pub const print = zzig.Logger.print;
pub const always = zzig.Logger.always;
