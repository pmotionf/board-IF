//! Zig-side declarations for soem_shim.c -- see that file for why this
//! exists. `SM`/`SMtype` must be accessed exclusively through these two
//! functions; translate-c's own offsets for those fields are not
//! trustworthy on this build (confirmed via @offsetOf vs offsetof()).
const soem = @import("soem");

pub const Sm = extern struct {
    addr: [soem.EC_MAXSM]u16,
    length: [soem.EC_MAXSM]u16,
    flags: [soem.EC_MAXSM]u32,
    type: [soem.EC_MAXSM]u8,
};

pub extern fn shim_get_sm(ctx: *soem.ecx_contextt, slave: u16, out: *Sm) void;
pub extern fn shim_set_sm(ctx: *soem.ecx_contextt, slave: u16, idx: u8, addr: u16, length: u16, flags: u32, smtype: u8) void;
