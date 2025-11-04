const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const QoiError = error{ OutOfMemory, ReadFailed, Invalid, EndOfStream };

const magicBytes: [4]u8 = .{ 'q', 'o', 'i', 'f' };
const endingBytes: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1 };

const Header = extern struct {
    magic: [4]u8,
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,

    pub fn decode(data: []const u8) Header {
        assert(data.len >= 14);

        var self: Header = undefined;
        @memcpy(&self.magic, data[0..4]);
        self.width = mem.readInt(u32, data[4..8], .big);
        self.height = mem.readInt(u32, data[8..12], .big);
        self.channels = data[12];
        self.colorspace = data[13];
        return self;
    }

    pub fn isValid(self: *const Header) bool {
        return mem.eql(u8, &self.magic, &magicBytes) and
            (self.channels == 3 or self.channels == 4) and
            (self.colorspace == 0 or self.colorspace == 1);
    }
};

const Op = enum(u8) {
    RGB = 0xFE,
    RGBA = 0xFF,
    Index = 0x00,
    Diff = 0x40,
    Luma = 0x80,
    Run = 0xC0,
    _,
};

pub const Pixel = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn decode(data: []const u8) Pixel {
        assert(data.len == 3 or data.len == 4);
        var result = Pixel{
            .r = data[0],
            .g = data[1],
            .b = data[2],
        };

        if (data.len == 4) {
            result.a = data[3];
        }

        return result;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    pixel_index: u64 = 0,
    current_op: u8,
    last_pixel: Pixel = .{},
    pixel_table: [64]Pixel,
    image: *Image,

    pub fn allPixelsWritten(self: *const State) bool {
        return self.pixel_index >= (self.image.pixelCount());
    }

    pub fn getOp(self: *const State) Op {
        switch (self.current_op) {
            @intFromEnum(Op.RGB) => return Op.RGB,
            @intFromEnum(Op.RGBA) => return Op.RGBA,
            else => return @enumFromInt(self.current_op & 0xC0),
        }
    }

    pub fn writePixel(self: *State, pixel: Pixel) !void {
        if (self.allPixelsWritten()) return error.Invalid;

        self.image.pixels[self.pixel_index] = pixel;
        self.pixel_index += 1;
        self.last_pixel = pixel;
        self.pixel_table[indexHash(pixel)] = pixel;
    }

    pub fn writePixels(self: *State, count: u8, pixel: Pixel) !void {
        if ((self.pixel_index + count) > self.image.pixelCount()) return error.Invalid;
        for (0..count) |_| {
            self.image.pixels[self.pixel_index] = pixel;
            self.pixel_index += 1;
        }
        self.last_pixel = pixel;
        self.pixel_table[indexHash(pixel)] = pixel;
    }
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []Pixel,
    channels: u8,
    colorspace: u8,

    pub fn pixelCount(self: *const Image) u64 {
        return self.width * self.height;
    }

    pub fn free(self: *const Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub fn decode(allocator: std.mem.Allocator, reader: *std.Io.Reader) QoiError!Image {
    const header = Header.decode(reader.take(14) catch return error.Invalid);
    if (!header.isValid()) return error.Invalid;

    var image = Image{
        .width = header.width,
        .height = header.height,
        .channels = header.channels,
        .colorspace = header.colorspace,
        .pixels = try allocator.alloc(Pixel, header.width * header.height),
    };
    errdefer image.free(allocator);
    @memset(image.pixels, .{});

    var state = State{
        .allocator = allocator,
        .current_op = undefined,
        .image = &image,
        .pixel_table = undefined,
    };
    @memset(&state.pixel_table, .{ .a = 255 });

    while (!state.allPixelsWritten() or
        !std.mem.eql(
            u8,
            reader.peek(8) catch return error.Invalid,
            &endingBytes,
        ))
    {
        state.current_op = reader.takeByte() catch return error.Invalid;
        switch (state.getOp()) {
            .RGB => {
                const pixel = Pixel.decode(reader.take(3) catch return error.Invalid);
                try state.writePixel(pixel);
            },
            .RGBA => {
                const pixel = Pixel.decode(reader.take(4) catch return error.Invalid);
                try state.writePixel(pixel);
            },
            .Index => {
                const index = state.current_op & 0x3F;
                try state.writePixel(state.pixel_table[index]);
            },
            .Diff => {
                const dr = (state.current_op >> 4) & 0x03;
                const dg = (state.current_op >> 2) & 0x03;
                const db = (state.current_op >> 0) & 0x03;

                const pixel = Pixel{
                    .r = state.last_pixel.r +% dr -% 2,
                    .g = state.last_pixel.g +% dg -% 2,
                    .b = state.last_pixel.b +% db -% 2,
                    .a = state.last_pixel.a,
                };
                try state.writePixel(pixel);
            },
            .Luma => {
                const dg: i8 = @as(i8, @intCast(state.current_op & 0x3F)) - 32;
                const data = reader.takeByte() catch return error.Invalid;
                const drdg = @as(i8, @intCast((data >> 4) & 0x0F)) - 8;
                const dbdg = @as(i8, @intCast((data >> 0) & 0x0F)) - 8;
                const dr = drdg + dg;
                const db = dbdg + dg;
                const pixel = Pixel{
                    .r = state.last_pixel.r +% @as(u8, @bitCast(dr)),
                    .g = state.last_pixel.g +% @as(u8, @bitCast(dg)),
                    .b = state.last_pixel.b +% @as(u8, @bitCast(db)),
                    .a = state.last_pixel.a,
                };
                try state.writePixel(pixel);
            },
            .Run => {
                const run_length = (state.current_op & 0x3F) + 1;
                try state.writePixels(run_length, state.last_pixel);
            },
            _ => return error.Invalid,
        }
    }
    return image;
}

fn indexHash(pa: Pixel) u8 {
    const r: u32 = pa.r;
    const g: u32 = pa.g;
    const b: u32 = pa.b;
    const a: u32 = pa.a;
    return @intCast((r * 3 + g * 5 + b * 7 + a * 11) % 64);
}

test "index hash" {
    const p: Pixel = .{ .r = 25, .g = 30, .b = 244, .a = 212 };
    try std.testing.expect(indexHash(p) == 41);
}

test "decode" {
    const input = try std.fs.cwd().openFile("assets/silksong.qoi", .{ .mode = .read_only });
    defer input.close();
    var input_buf: [1024]u8 = undefined;
    var reader = input.reader(&input_buf);

    const output = try std.fs.cwd().createFile("assets/silksong.ppm", .{});
    defer output.close();
    var output_buf: [1024]u8 = undefined;
    var writer = output.writer(&output_buf);

    const sample_data: [14]u8 = .{
        0x71,
        0x6f,
        0x69,
        0x66,
        0x00,
        0x00,
        0x07,
        0x80,
        0x00,
        0x00,
        0x04,
        0x38,
        0x03,
        0x00,
    };

    const readBytes = Header.decode(&sample_data);
    const readFile = Header.decode(try reader.interface.peek(14));

    // std.debug.print("read from bytes: {x}\n", .{mem.asBytes(&readBytes)});
    // std.debug.print("                 {}\n", .{readBytes});
    // std.debug.print("read from file:  {x}\n", .{mem.asBytes(&readFile)});
    // std.debug.print("                 {}\n", .{readFile});

    try std.testing.expect(readBytes.isValid());
    try std.testing.expect(readBytes.width == 1920 and readBytes.height == 1080);
    try std.testing.expect(readFile.isValid());
    try std.testing.expect(readFile.width == 1920 and readFile.height == 1080);
    try std.testing.expect(std.meta.eql(readBytes, readFile));

    const image = try decode(std.testing.allocator, &reader.interface);
    defer image.free(std.testing.allocator);

    try writer.interface.print("P3\n{} {}\n255\n", .{ image.width, image.height });
    for (0..image.pixelCount()) |i| {
        const p = image.pixels[i];
        try writer.interface.print("{} {} {}\n", .{ p.r, p.g, p.b });
    }
}
