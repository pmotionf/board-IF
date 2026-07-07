//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const soem = @import("soem");

// Functionality that we want for the board
// - Initialize the connection, including connect
// - Read the data
// - Send the data
// - Close the connection
// - Error handling

pub const IoMap = []u8;

pub const ProcessData = struct {
    slaves: []Slave,

    pub const Slave = struct {
        input: Input,
        output: Output,
        pub const Output = struct {
            y: [8]u8,
            ww: [16]u16,
        };

        pub const Input = struct {
            x: [8]u8,
            wr: [16]u16,
            status: u16,
            heartbeat_counter: u16,
        };
    };

    /// Allocate required memory to store process data from ethercat. Caller
    /// must call deinit upon completion.
    pub fn init(gpa: std.mem.Allocator, station_num: usize) std.mem.Allocator.Error!ProcessData {
        var res: ProcessData = undefined;
        res.slaves = try gpa.alloc(Slave, station_num);
        return res;
    }

    pub fn deinit(self: ProcessData, gpa: std.mem.Allocator) void {
        gpa.free(self.slaves);
    }

    /// Update the process data from soem context. Caller must ensure send and
    /// receive process data must be done periodically.
    pub fn update(self: *ProcessData, soem_ctx: soem.ecx_contextt) void {
        const slaves_num: usize = @intCast(soem_ctx.slavecount);
        for (self.slaves, soem_ctx.slavelist[0..slaves_num]) |*slave, source| {
            @memcpy(
                slave.input.x[0..slave.input.x.len],
                source.inputs[0..@sizeOf(@TypeOf(slave.input.x))],
            );
            @memcpy(
                slave.input.wr[0..slave.input.wr.len],
                @as(
                    []u16,
                    @ptrCast(@alignCast(source.inputs[@sizeOf(@TypeOf(slave.input.x)) .. @sizeOf(@TypeOf(slave.input.x)) + @sizeOf(@TypeOf(slave.input.wr))])),
                ),
            );
            @memcpy(
                slave.output.y[0..slave.output.y.len],
                source.outputs[0..@sizeOf(@TypeOf(slave.output.y))],
            );
            @memcpy(
                slave.output.ww[0..slave.output.ww.len],
                @as(
                    []u16,
                    @ptrCast(@alignCast(source.outputs[@sizeOf(@TypeOf(slave.output.y)) .. @sizeOf(@TypeOf(slave.output.y)) + @sizeOf(@TypeOf(slave.output.ww))])),
                ),
            );
        }
    }

    pub const size = @bitSizeOf(Slave.Input) + @bitSizeOf(Slave.Output);
};

/// Initialize the ethercat connection to slaves. After calling this function,
/// user must keep `process()` alive on other thread. Failing to keep
/// `process()` alive may terminate the connection. Caller also must call
/// deinit upon finishing with the connection.
pub fn init(
    gpa: std.mem.Allocator,
    ctx: *soem.ecx_contextt,
    ifname: []const u8,
) !IoMap {
    if (soem.ecx_init(ctx, ifname.ptr) <= 0) {
        return error.SoemInitializationFailed;
    }
    std.log.debug("ecx_init on {s} succeeded", .{ifname});
    errdefer soem.ecx_close(ctx);
    const stations: usize = @intCast(soem.ecx_config_init(ctx));
    if (stations <= 0) {
        return error.NoSlavesFound;
    }
    std.log.debug("Found {} slaves", .{stations});
    // `+ stations` for accomodating mbxstatuslength
    const io_map = try gpa.alloc(u8, stations * ProcessData.size + stations);
    errdefer gpa.free(io_map);
    const size = soem.ecx_config_map_group(
        ctx,
        @ptrCast(@alignCast(io_map)),
        0,
    );
    std.log.debug("IO map allocated", .{});
    const expected_WKC =
        ctx.grouplist[0].outputsWKC * 2 + ctx.grouplist[0].inputsWKC;
    if (size > io_map.len) return error.IoMapOverflow;
    _ = soem.ecx_configdc(ctx);
    // Wait until all slaves are in SAFE_OP state.
    _ = soem.ecx_statecheck(
        ctx,
        0,
        soem.EC_STATE_SAFE_OP,
        soem.EC_TIMEOUTSTATE * 4,
    );
    std.log.debug("All slaves enter safe operational state", .{});
    // Ensure slaves have valid output
    if (soem.ecx_send_processdata(ctx) != expected_WKC and
        soem.ecx_receive_processdata(ctx, soem.EC_TIMEOUTRET) != expected_WKC)
    {
        return error.InvalidWorkCounter;
    }
    std.log.debug("Valid workcounter found", .{});
    // Asks the slaves to be in operational state
    ctx.slavelist[0].state = soem.EC_STATE_OPERATIONAL;
    _ = soem.ecx_writestate(ctx, 0);
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
    std.log.debug("Connected to ethercat", .{});
    return io_map;
}

/// Maintain the connection to the slaves.
pub fn process(io: std.Io, ctx: *soem.ecx_contextt) !void {
    defer {
        if (@errorReturnTrace()) |error_trace| {
            std.debug.dumpErrorReturnTrace(error_trace);
        }
    }
    const expected_WKC =
        ctx.grouplist[0].outputsWKC * 2 + ctx.grouplist[0].inputsWKC;
    while (true) {
        std.log.debug("board_if process", .{});
        try io.checkCancel();
        if (soem.ecx_send_processdata(ctx) != expected_WKC and
            soem.ecx_receive_processdata(ctx, soem.EC_TIMEOUTRET) != expected_WKC)
        {
            return error.InvalidWorkCounter;
        }
    }
}

/// Close the ethercat connection
pub fn deinit(ctx: *soem.ecx_contextt) void {
    soem.ecx_close(ctx);
}
/// Wrapper for SOEM functions that may return error code.
///
/// Usage: `error_handling(ctx, SOEM_FUNCTION_CALL())`;
fn error_handling(ctx: *soem.ecx_contextt, code: c_int) !void {
    if (code == 0) return;
    var err: soem.ec_errort = std.mem.zeroInit(soem.ec_errort, .{});
    if (soem.ecx_poperror(ctx, &err) > 0) {
        const err_code: ErrorCode = @enumFromInt(err.Etype);
        std.log.err("{s}", .{soem.ecx_err2string(err)});
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
            _ => unreachable,
        }
    }
};

const SlaveState = enum(u5) {
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
    // Error or ACK Error
    EC_STATE_ACK_ERROR = 0x10,
};
