//! 注册全部 query 的数据库类型。

const engine = @import("db/engine.zig");
pub const inputs = @import("base/inputs.zig");

pub const Db = engine.Engine(&.{
    inputs.FileText,
});
