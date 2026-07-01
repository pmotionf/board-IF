//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const soem = @import("soem");

// Functionality that we want for the board
// - Initialize the connection, including connect
// - Read the data
// - Send the data
// - Close the connection
// - Error handling

const max_stations = 64;
var io_map: [max_stations * @bitSizeOf(ProcessData)]u8 = undefined;

pub const ProcessData = extern struct {
    output: extern struct {
        y: u64,
        ww: u256,
    },
    input: extern struct {
        x: u64,
        wr: u256,
        status: u16,
        heartbeat_counter: u16,
    },
};

/// Initialize the ethercat connection to slaves and maintain its operational
/// state. This function is intended to be called by Zig Group/Select interface
/// to support cancelation. To close the connection, cancel the thread.
pub fn process(ctx: *soem.ecx_contextt, ifname: []const u8) !void {
    error_handling(ctx, soem.ecx_init(ctx, ifname));
    defer soem.ecx_close(ctx);
    const size = soem.ecx_config_map_group(ctx, &io_map, 0);
    const expected_WKC =
        ctx.grouplist[0].outputsWKC * 2 + ctx.grouplist[0].inputsWKC;
    if (size > max_stations) return error.StationNumberOverflow;
    _ = soem.ecx_configdc(ctx);
    // Wait until all slaves are in SAFE_OP state.
    while (@as(
        SlaveState,
        @enumFromInt(soem.ecx_readstate(ctx)),
    ) == SlaveState.EC_STATE_SAFE_OP) {}
    std.log.info("All slaves enter safe operational state", .{});
    // Ensure slaves have valid output
    if (soem.ecx_send_processdata(ctx) != expected_WKC and
        soem.ecx_receive_processdata(ctx, soem.EC_TIMEOUTRET) != expected_WKC)
    {
        return error.InvalidWorkCounter;
    }
    // Asks the slaves to be in operational state
    ctx.slavelist[0].state = @intFromEnum(SlaveState.EC_STATE_OPERATIONAL);
    soem.ecx_writestate(ctx, 0);
    while (@as(
        SlaveState,
        @enumFromInt(soem.ecx_readstate(ctx)),
    ) == SlaveState.EC_STATE_OPERATIONAL) {
        if (soem.ecx_send_processdata(ctx) != expected_WKC and
            soem.ecx_receive_processdata(ctx, soem.EC_TIMEOUTRET) != expected_WKC)
        {
            return error.InvalidWorkCounter;
        }
    }
    while (true) {
        if (soem.ecx_send_processdata(ctx) != expected_WKC and
            soem.ecx_receive_processdata(ctx, soem.EC_TIMEOUTRET) != expected_WKC)
        {
            return error.InvalidWorkCounter;
        }
    }
}

/// Wait until all slaves state enter the requested state
fn waitState(
    ctx: *soem.ecx_contextt,
    req_state: SlaveState,
) void {
    while (@as(
        SlaveState,
        @enumFromInt(soem.ecx_readstate(ctx)),
    ) == req_state) {}
}

/// Wrapper for SOEM functions that may return error code.
///
/// Usage: `error_handling(ctx, SOEM_FUNCTION_CALL())`;
fn error_handling(ctx: *soem.ecx_contextt, code: usize) !void {
    if (code == 0) return;
    var err: soem.ec_errort = std.mem.zeroInit(soem.ec_errort, .{});
    if (soem.ecx_poperror(ctx, &err) > 0) {
        const err_code: ErrorCode = @enumFromInt(err.Etype);
        soem.ecx_err2string(err);
        try err_code.throwError();
    } else return error.PopErrorFailed;
}

const ErrorCode = enum(u8) {
    EC_ERR_TYPE_SDO_ERROR = 0,
    EC_ERR_TYPE_EMERGENCY = 1,
    EC_ERR_TYPE_PACKET_ERROR = 3,
    EC_ERR_TYPE_SDOINFO_ERROR = 4,
    EC_ERR_TYPE_FOE_ERROR = 5,
    EC_ERR_TYPE_FOE_BUF2SMALL = 6,
    EC_ERR_TYPE_FOE_PACKETNUMBER = 7,
    EC_ERR_TYPE_SOE_ERROR = 8,
    EC_ERR_TYPE_MBX_ERROR = 9,
    EC_ERR_TYPE_FOE_FILE_NOTFOUND = 10,
    EC_ERR_TYPE_EOE_INVALID_RX_DATA = 11,
    _,

    fn throwError(err: ErrorCode) !void {
        switch (err) {
            .EC_ERR_TYPE_SDO_ERROR => return error.SDOError,
            .EC_ERR_TYPE_EMERGENCY => return error.Emergency,
            .EC_ERR_TYPE_PACKET_ERROR => return error.PacketError,
            .EC_ERR_TYPE_SDOINFO_ERROR => return error.SDOInfoError,
            .EC_ERR_TYPE_FOE_ERROR => return error.FOEError,
            .EC_ERR_TYPE_FOE_BUF2SMALL => return error.FOEBufTooSmall,
            .EC_ERR_TYPE_FOE_PACKETNUMBER => return error.FOEPacketNumber,
            .EC_ERR_TYPE_SOE_ERROR => return error.SOEError,
            .EC_ERR_TYPE_MBX_ERROR => return error.MBXError,
            .EC_ERR_TYPE_FOE_FILE_NOTFOUND => return error.FOEFileNotFound,
            .EC_ERR_TYPE_EOE_INVALID_RX_DATA => return error.InvalidRxData,
        }
    }
};

const SlaveState = enum(u16) {
    /// No valid state.
    EC_STATE_NONE = 0x00,
    /// Init state
    EC_STATE_INIT = 0x01,
    /// Pre-operational.
    EC_STATE_PRE_OP = 0x02,
    /// Boot state
    EC_STATE_BOOT = 0x03,
    /// Safe-operational.
    EC_STATE_SAFE_OP = 0x04,
    /// Operational
    EC_STATE_OPERATIONAL = 0x08,
};
