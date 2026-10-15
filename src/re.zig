//! The regex engine behind `-E`: regex.zig (the default; a Pike VM, linear
//! time), or PCRE2 when built with `zig build -Dpcre2` (pcre2.zig; JIT,
//! fuller syntax, backtracking with a bound). Both have the same
//! interface, and both sit behind the same SIMD literal prefilter.

const build_options = @import("build_options");

pub const pcre2 = build_options.pcre2;
const engine = if (pcre2) @import("pcre2.zig") else @import("regex.zig");

pub const Regex = engine.Regex;
pub const Vm = engine.Vm;
pub const Error = engine.Error;
pub const findValues = engine.findValues;
pub const matches = engine.matches;
pub const span = engine.span;

/// Did a value reach PCRE2's match limit? Its result is unknown, so the
/// search of its file has failed. Never with regex.zig.
pub fn limitHit(vm: *const Vm) bool {
    return if (pcre2) vm.limit_hit else false;
}

/// PCRE2's explanation of why the last compile failed, if it has one.
pub fn lastError() ?[]const u8 {
    if (!pcre2) return null;
    return engine.last_error[0..engine.last_error_len];
}
