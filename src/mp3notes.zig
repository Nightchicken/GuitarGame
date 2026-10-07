//! mp3notes: decode an MP3 and transcribe it (bpm, beats, key, chords, drum hits and
//! pitched notes per instrument role). Every function allocates without freeing, so pass an arena.
//!
//! The Layer III decoder is a port of minimp3 (https://github.com/lieff/minimp3, CC0).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// MP3 decoder
// ============================================================================

const MAX_FREE_FORMAT_FRAME_SIZE = 2304;
const MAX_FRAME_SYNC_MATCHES = 10;
const MAX_L3_FRAME_PAYLOAD_BYTES = MAX_FREE_FORMAT_FRAME_SIZE;
const MAX_BITRESERVOIR_BYTES = 511;
const SHORT_BLOCK_TYPE = 2;
const STOP_BLOCK_TYPE = 3;
const HDR_SIZE = 4;
const MAX_SCFI = 44;
const MAX_SAMPLES_PER_FRAME = 1152 * 2;

fn hdr_is_mono(h: []const u8) bool {
    return (h[3] & 0xC0) == 0xC0;
}
fn hdr_is_ms_stereo(h: []const u8) bool {
    return (h[3] & 0xE0) == 0x60;
}
fn hdr_is_free_format(h: []const u8) bool {
    return (h[2] & 0xF0) == 0;
}
fn hdr_is_crc(h: []const u8) bool {
    return (h[1] & 1) == 0;
}
fn hdr_test_padding(h: []const u8) bool {
    return (h[2] & 0x2) != 0;
}
fn hdr_test_mpeg1(h: []const u8) bool {
    return (h[1] & 0x8) != 0;
}
fn hdr_test_not_mpeg25(h: []const u8) bool {
    return (h[1] & 0x10) != 0;
}
fn hdr_test_i_stereo(h: []const u8) bool {
    return (h[3] & 0x10) != 0;
}
fn hdr_test_ms_stereo(h: []const u8) bool {
    return (h[3] & 0x20) != 0;
}
fn hdr_layer(h: []const u8) u8 {
    return (h[1] >> 1) & 3;
}
fn hdr_bitrate_idx(h: []const u8) u8 {
    return h[2] >> 4;
}
fn hdr_sample_rate_idx(h: []const u8) u8 {
    return (h[2] >> 2) & 3;
}
fn hdr_my_sample_rate(h: []const u8) u8 {
    return hdr_sample_rate_idx(h) + (((h[1] >> 3) & 1) + ((h[1] >> 4) & 1)) * 3;
}
fn hdr_is_frame576(h: []const u8) bool {
    return (h[1] & 14) == 2;
}
fn hdr_is_layer1(h: []const u8) bool {
    return (h[1] & 6) == 6;
}

fn hdr_valid(h: []const u8) bool {
    return h[0] == 0xff and
        ((h[1] & 0xF0) == 0xf0 or (h[1] & 0xFE) == 0xe2) and
        hdr_layer(h) != 0 and hdr_bitrate_idx(h) != 15 and hdr_sample_rate_idx(h) != 3;
}

fn hdr_compare(h1: []const u8, h2: []const u8) bool {
    return hdr_valid(h2) and
        ((h1[1] ^ h2[1]) & 0xFE) == 0 and
        ((h1[2] ^ h2[2]) & 0x0C) == 0 and
        hdr_is_free_format(h1) == hdr_is_free_format(h2);
}

fn hdr_bitrate_kbps(h: []const u8) u32 {
    return 2 * @as(u32, HALFRATE[@intFromBool(hdr_test_mpeg1(h))][hdr_layer(h) - 1][hdr_bitrate_idx(h)]);
}

fn hdr_sample_rate_hz(h: []const u8) u32 {
    const hz = [3]u32{ 44100, 48000, 32000 };
    return hz[hdr_sample_rate_idx(h)] >> @intFromBool(!hdr_test_mpeg1(h)) >> @intFromBool(!hdr_test_not_mpeg25(h));
}

fn hdr_frame_samples(h: []const u8) usize {
    return if (hdr_is_layer1(h)) 384 else @as(usize, 1152) >> @intFromBool(hdr_is_frame576(h));
}

fn hdr_frame_bytes(h: []const u8, free_format_size: usize) usize {
    var frame_bytes = hdr_frame_samples(h) * hdr_bitrate_kbps(h) * 125 / hdr_sample_rate_hz(h);
    if (hdr_is_layer1(h)) frame_bytes &= ~@as(usize, 3);
    return if (frame_bytes != 0) frame_bytes else free_format_size;
}

fn hdr_padding(h: []const u8) usize {
    return if (hdr_test_padding(h)) (if (hdr_is_layer1(h)) @as(usize, 4) else 1) else 0;
}

const BitStream = struct {
    buf: []const u8,
    pos: usize = 0,
    limit: usize,

    fn init(data: []const u8) BitStream {
        return .{ .buf = data, .limit = data.len * 8 };
    }

    fn get_bits(bs: *BitStream, n: u32) u32 {
        const s: u32 = @intCast(bs.pos & 7);
        var shl: i32 = @intCast(n + s);
        var p = bs.pos >> 3;
        bs.pos += n;
        if (bs.pos > bs.limit) return 0;
        var next: u32 = bs.buf[p] & (@as(u32, 255) >> @intCast(s));
        p += 1;
        var cache: u32 = 0;
        shl -= 8;
        while (shl > 0) : (shl -= 8) {
            cache |= next << @intCast(shl);
            next = bs.buf[p];
            p += 1;
        }
        return cache | (next >> @intCast(-shl));
    }
};

const GrInfo = struct {
    sfbtab: []const u8 = &.{},
    part_23_length: u16 = 0,
    big_values: u16 = 0,
    scalefac_compress: u16 = 0,
    global_gain: u8 = 0,
    block_type: u8 = 0,
    mixed_block_flag: u8 = 0,
    n_long_sfb: u8 = 0,
    n_short_sfb: u8 = 0,
    table_select: [3]u8 = .{ 0, 0, 0 },
    region_count: [3]u8 = .{ 0, 0, 0 },
    subblock_gain: [3]u8 = .{ 0, 0, 0 },
    preflag: u8 = 0,
    scalefac_scale: u8 = 0,
    count1_table: u8 = 0,
    scfsi: u8 = 0,
};

const FrameInfo = struct {
    frame_bytes: usize = 0,
    frame_offset: usize = 0,
    channels: usize = 0,
    hz: u32 = 0,
    layer: u8 = 0,
    bitrate_kbps: u32 = 0,
};

fn l3_read_side_info(bs: *BitStream, gr: []GrInfo, hdr: []const u8) i32 {
    const mpeg1 = hdr_test_mpeg1(hdr);
    var tables: u32 = 0;
    var scfsi: u32 = 0;
    var main_data_begin: i32 = 0;
    var part_23_sum: usize = 0;
    var sr_idx: usize = hdr_my_sample_rate(hdr);
    if (sr_idx != 0) sr_idx -= 1;
    var gr_count: u32 = if (hdr_is_mono(hdr)) 1 else 2;

    if (mpeg1) {
        gr_count *= 2;
        main_data_begin = @intCast(bs.get_bits(9));
        scfsi = bs.get_bits(7 + gr_count);
    } else {
        main_data_begin = @intCast(bs.get_bits(8 + gr_count) >> @intCast(gr_count));
    }

    for (0..gr_count) |gi| {
        const g = &gr[gi];
        if (hdr_is_mono(hdr)) scfsi <<= 4;
        g.part_23_length = @intCast(bs.get_bits(12));
        part_23_sum += g.part_23_length;
        g.big_values = @intCast(bs.get_bits(9));
        if (g.big_values > 288) return -1;
        g.global_gain = @intCast(bs.get_bits(8));
        g.scalefac_compress = @intCast(bs.get_bits(if (mpeg1) 4 else 9));
        g.sfbtab = &SCF_LONG[sr_idx];
        g.n_long_sfb = 22;
        g.n_short_sfb = 0;
        if (bs.get_bits(1) != 0) {
            g.block_type = @intCast(bs.get_bits(2));
            if (g.block_type == 0) return -1;
            g.mixed_block_flag = @intCast(bs.get_bits(1));
            g.region_count[0] = 7;
            g.region_count[1] = 255;
            g.region_count[2] = 255;
            if (g.block_type == SHORT_BLOCK_TYPE) {
                scfsi &= 0x0F0F;
                if (g.mixed_block_flag == 0) {
                    g.region_count[0] = 8;
                    g.sfbtab = &SCF_SHORT[sr_idx];
                    g.n_long_sfb = 0;
                    g.n_short_sfb = 39;
                } else {
                    g.sfbtab = SCF_MIXED[sr_idx];
                    g.n_long_sfb = if (mpeg1) 8 else 6;
                    g.n_short_sfb = 30;
                }
            }
            tables = bs.get_bits(10) << 5;
            g.subblock_gain[0] = @intCast(bs.get_bits(3));
            g.subblock_gain[1] = @intCast(bs.get_bits(3));
            g.subblock_gain[2] = @intCast(bs.get_bits(3));
        } else {
            g.block_type = 0;
            g.mixed_block_flag = 0;
            tables = bs.get_bits(15);
            g.region_count[0] = @intCast(bs.get_bits(4));
            g.region_count[1] = @intCast(bs.get_bits(3));
            g.region_count[2] = 255;
        }
        g.table_select[0] = @intCast(tables >> 10);
        g.table_select[1] = @intCast((tables >> 5) & 31);
        g.table_select[2] = @intCast(tables & 31);
        g.preflag = if (mpeg1) @intCast(bs.get_bits(1)) else @intFromBool(g.scalefac_compress >= 500);
        g.scalefac_scale = @intCast(bs.get_bits(1));
        g.count1_table = @intCast(bs.get_bits(1));
        g.scfsi = @intCast((scfsi >> 12) & 15);
        scfsi <<= 4;
    }

    if (part_23_sum + bs.pos > bs.limit + @as(usize, @intCast(main_data_begin)) * 8) return -1;
    return main_data_begin;
}

fn l3_read_scalefactors(scf: []u8, ist_pos: []u8, scf_size: []const u8, scf_count: []const u8, bs: *BitStream, scfsi_in: i32) void {
    var scfsi = scfsi_in;
    var off: usize = 0;
    var i: usize = 0;
    while (i < 4 and scf_count[i] != 0) : ({
        i += 1;
        scfsi *%= 2;
    }) {
        const cnt: usize = scf_count[i];
        if (scfsi & 8 != 0) {
            @memcpy(scf[off..][0..cnt], ist_pos[off..][0..cnt]);
        } else {
            const bits = scf_size[i];
            if (bits == 0) {
                @memset(scf[off..][0..cnt], 0);
                @memset(ist_pos[off..][0..cnt], 0);
            } else {
                const max_scf: i32 = if (scfsi < 0) (@as(i32, 1) << @intCast(bits)) - 1 else -1;
                for (0..cnt) |k| {
                    const s: i32 = @intCast(bs.get_bits(bits));
                    ist_pos[off + k] = if (s == max_scf) 255 else @intCast(s);
                    scf[off + k] = @intCast(s);
                }
            }
        }
        off += cnt;
    }
    scf[off] = 0;
    scf[off + 1] = 0;
    scf[off + 2] = 0;
}

fn l3_ldexp_q2(y_in: f32, exp_in: i32) f32 {
    var y = y_in;
    var exp_q2 = exp_in;
    while (true) {
        const e = @min(30 * 4, exp_q2);
        const mul: f32 = @floatFromInt(@as(i32, 1 << 30) >> @intCast(e >> 2));
        y *= EXPFRAC[@intCast(e & 3)] * mul;
        exp_q2 -= e;
        if (exp_q2 <= 0) break;
    }
    return y;
}

fn l3_decode_scalefactors(hdr: []const u8, ist_pos: []u8, bs: *BitStream, gr: *const GrInfo, scf: []f32, ch: usize) void {
    const row = @as(usize, @intFromBool(gr.n_short_sfb != 0)) + @intFromBool(gr.n_long_sfb == 0);
    var scf_partition: []const u8 = &SCF_PARTITIONS[row];
    var scf_size: [4]u8 = undefined;
    var iscf: [40]u8 = undefined;
    const scf_shift: u5 = @intCast(gr.scalefac_scale + 1);
    var scfsi: i32 = gr.scfsi;

    if (hdr_test_mpeg1(hdr)) {
        const part = SCFC_DECODE[gr.scalefac_compress];
        scf_size[0] = part >> 2;
        scf_size[1] = part >> 2;
        scf_size[2] = part & 3;
        scf_size[3] = part & 3;
    } else {
        const ist: u32 = @intFromBool(hdr_test_i_stereo(hdr) and ch != 0);
        var sfc: i32 = @intCast(gr.scalefac_compress >> @intCast(ist));
        var k: usize = ist * 3 * 4;
        while (sfc >= 0) {
            var modprod: i32 = 1;
            var i: usize = 4;
            while (i > 0) {
                i -= 1;
                const m: i32 = MOD[k + i];
                scf_size[i] = @intCast(@rem(@divTrunc(sfc, modprod), m));
                modprod *= m;
            }
            sfc -= modprod;
            k += 4;
        }
        scf_partition = scf_partition[k..];
        scfsi = -16;
    }
    l3_read_scalefactors(&iscf, ist_pos, &scf_size, scf_partition, bs, scfsi);

    const n_long: usize = gr.n_long_sfb;
    if (gr.n_short_sfb != 0) {
        const sh: u3 = @intCast(3 - @as(u32, scf_shift));
        var i: usize = 0;
        while (i < gr.n_short_sfb) : (i += 3) {
            iscf[n_long + i + 0] += gr.subblock_gain[0] << sh;
            iscf[n_long + i + 1] += gr.subblock_gain[1] << sh;
            iscf[n_long + i + 2] += gr.subblock_gain[2] << sh;
        }
    } else if (gr.preflag != 0) {
        for (0..10) |i| iscf[11 + i] += PREAMP[i];
    }

    const gain_exp: i32 = @as(i32, gr.global_gain) - 4 - 210 - @as(i32, if (hdr_is_ms_stereo(hdr)) 2 else 0);
    const gain = l3_ldexp_q2(@floatFromInt(1 << (MAX_SCFI / 4)), MAX_SCFI - gain_exp);
    for (0..n_long + gr.n_short_sfb) |i| {
        scf[i] = l3_ldexp_q2(gain, @as(i32, iscf[i]) << scf_shift);
    }
}

fn l3_pow43(x_in: i32) f32 {
    var x = x_in;
    var mult: f32 = 256;
    if (x < 129) return POW43[@intCast(16 + x)];
    if (x < 1024) {
        mult = 16;
        x <<= 3;
    }
    const sign = (2 * x) & 64;
    const frac = @as(f32, @floatFromInt((x & 63) - sign)) / @as(f32, @floatFromInt((x & ~@as(i32, 63)) + sign));
    return POW43[@intCast(16 + ((x + sign) >> 6))] * (1 + frac * ((4.0 / 3.0) + frac * (2.0 / 9.0))) * mult;
}

const HuffBits = struct {
    buf: []const u8,
    next: usize,
    cache: u32,
    sh: i32,

    inline fn peek(self: *const HuffBits, n: u32) u32 {
        return @intCast(@as(u64, self.cache) >> @intCast(32 - n));
    }
    inline fn flush(self: *HuffBits, n: u32) void {
        self.cache = self.cache << @intCast(n);
        self.sh += @intCast(n);
    }
    inline fn check(self: *HuffBits) void {
        while (self.sh >= 0) {
            self.cache |= @as(u32, self.buf[self.next]) << @intCast(self.sh);
            self.next += 1;
            self.sh -= 8;
        }
    }
    inline fn sign_bit(self: *const HuffBits) u32 {
        return self.cache >> 31;
    }
    fn pos(self: *const HuffBits) i64 {
        return @as(i64, @intCast(self.next)) * 8 - 24 + self.sh;
    }
};

fn l3_huffman(dst: []f32, bs: *BitStream, full_buf: []const u8, gr: *const GrInfo, scf: []const f32, layer3gr_limit: usize) void {
    var one: f32 = 0;
    var ireg: usize = 0;
    var big_val_cnt: i32 = gr.big_values;
    const sfb = gr.sfbtab;
    var sfb_i: usize = 0;
    var scf_i: usize = 0;
    var di: usize = 0;
    const start = bs.pos / 8;
    var hb = HuffBits{
        .buf = full_buf,
        .next = start + 4,
        .cache = std.mem.readInt(u32, full_buf[start..][0..4], .big) << @intCast(bs.pos & 7),
        .sh = @as(i32, @intCast(bs.pos & 7)) - 8,
    };

    while (big_val_cnt > 0) {
        const tab_num = gr.table_select[ireg];
        var sfb_cnt: i32 = gr.region_count[ireg];
        ireg += 1;
        const codebook = TABS[@intCast(TABINDEX[tab_num])..];
        const linbits: u32 = LINBITS[tab_num];
        while (true) {
            const np: i32 = sfb[sfb_i] / 2;
            sfb_i += 1;
            var pairs = @min(big_val_cnt, np);
            one = scf[scf_i];
            scf_i += 1;
            while (pairs > 0) : (pairs -= 1) {
                var w: u32 = 5;
                var leaf: i32 = codebook[hb.peek(w)];
                while (leaf < 0) {
                    hb.flush(w);
                    w = @intCast(leaf & 7);
                    leaf = codebook[@intCast(@as(i32, @intCast(hb.peek(w))) - (leaf >> 3))];
                }
                hb.flush(@intCast(leaf >> 8));

                for (0..2) |_| {
                    var lsb: i32 = leaf & 0x0F;
                    if (linbits != 0 and lsb == 15) {
                        lsb += @intCast(hb.peek(linbits));
                        hb.flush(linbits);
                        hb.check();
                        dst[di] = one * l3_pow43(lsb) * @as(f32, if (hb.sign_bit() != 0) -1 else 1);
                    } else {
                        dst[di] = POW43[@intCast(16 + lsb - 16 * @as(i32, @intCast(hb.sign_bit())))] * one;
                    }
                    hb.flush(if (lsb != 0) 1 else 0);
                    di += 1;
                    leaf >>= 4;
                }
                hb.check();
            }
            big_val_cnt -= np;
            if (big_val_cnt <= 0) break;
            sfb_cnt -= 1;
            if (sfb_cnt < 0) break;
        }
    }

    var np: i32 = 1 - big_val_cnt;
    const codebook_count1: []const u8 = if (gr.count1_table != 0) &TAB33 else &TAB32;
    outer: while (true) : (di += 4) {
        var leaf: u32 = codebook_count1[hb.peek(4)];
        if (leaf & 8 == 0) {
            const extra: u32 = @intCast(@as(u64, hb.cache << 4) >> @intCast(32 - (leaf & 3)));
            leaf = codebook_count1[(leaf >> 3) + extra];
        }
        hb.flush(leaf & 7);
        if (hb.pos() > @as(i64, @intCast(layer3gr_limit))) break;

        for (0..2) |half| {
            np -= 1;
            if (np == 0) {
                np = sfb[sfb_i] / 2;
                sfb_i += 1;
                if (np == 0) break :outer;
                one = scf[scf_i];
                scf_i += 1;
            }
            for (0..2) |q| {
                const s = half * 2 + q;
                if (leaf & (@as(u32, 128) >> @intCast(s)) != 0) {
                    dst[di + s] = if (hb.sign_bit() != 0) -one else one;
                    hb.flush(1);
                }
            }
        }
        hb.check();
    }

    bs.pos = layer3gr_limit;
}

fn l3_midside_stereo(buf: []f32, off: usize, n: usize) void {
    for (off..off + n) |i| {
        const a = buf[i];
        const b = buf[i + 576];
        buf[i] = a + b;
        buf[i + 576] = a - b;
    }
}

fn l3_intensity_stereo_band(buf: []f32, off: usize, n: usize, kl: f32, kr: f32) void {
    for (off..off + n) |i| {
        buf[i + 576] = buf[i] * kr;
        buf[i] = buf[i] * kl;
    }
}

fn l3_stereo_top_band(right: []const f32, sfb: []const u8, nbands: usize, max_band: *[3]i32) void {
    max_band.* = .{ -1, -1, -1 };
    var off: usize = 0;
    for (0..nbands) |i| {
        var k: usize = 0;
        while (k < sfb[i]) : (k += 2) {
            if (right[off + k] != 0 or right[off + k + 1] != 0) {
                max_band[i % 3] = @intCast(i);
                break;
            }
        }
        off += sfb[i];
    }
}

fn l3_stereo_process(buf: []f32, ist_pos: []const u8, sfb: []const u8, hdr: []const u8, max_band: [3]i32, mpeg2_sh: u32) void {
    const max_pos: u32 = if (hdr_test_mpeg1(hdr)) 7 else 64;
    var off: usize = 0;
    var i: usize = 0;
    while (sfb[i] != 0) : (i += 1) {
        const ipos: u32 = ist_pos[i];
        if (@as(i32, @intCast(i)) > max_band[i % 3] and ipos < max_pos) {
            const s: f32 = if (hdr_test_ms_stereo(hdr)) 1.41421356 else 1;
            var kl: f32 = undefined;
            var kr: f32 = undefined;
            if (hdr_test_mpeg1(hdr)) {
                kl = PAN[2 * ipos];
                kr = PAN[2 * ipos + 1];
            } else {
                kl = 1;
                kr = l3_ldexp_q2(1, @intCast(((ipos + 1) >> 1) << @intCast(mpeg2_sh)));
                if (ipos & 1 != 0) {
                    kl = kr;
                    kr = 1;
                }
            }
            l3_intensity_stereo_band(buf, off, sfb[i], kl * s, kr * s);
        } else if (hdr_test_ms_stereo(hdr)) {
            l3_midside_stereo(buf, off, sfb[i]);
        }
        off += sfb[i];
    }
}

fn l3_intensity_stereo(buf: []f32, ist_pos: []u8, gr: []const GrInfo, hdr: []const u8) void {
    var max_band: [3]i32 = undefined;
    const n_sfb: usize = @as(usize, gr[0].n_long_sfb) + gr[0].n_short_sfb;
    const max_blocks: usize = if (gr[0].n_short_sfb != 0) 3 else 1;

    l3_stereo_top_band(buf[576..], gr[0].sfbtab, n_sfb, &max_band);
    if (gr[0].n_long_sfb != 0) {
        const m = @max(@max(max_band[0], max_band[1]), max_band[2]);
        max_band = .{ m, m, m };
    }
    for (0..max_blocks) |i| {
        const default_pos: u8 = if (hdr_test_mpeg1(hdr)) 3 else 0;
        const itop = n_sfb - max_blocks + i;
        const prev = itop - max_blocks;
        ist_pos[itop] = if (max_band[i] >= @as(i32, @intCast(prev))) default_pos else ist_pos[prev];
    }
    l3_stereo_process(buf, ist_pos, gr[0].sfbtab, hdr, max_band, gr[1].scalefac_compress & 1);
}

fn l3_reorder(grbuf: []f32, sfb: []const u8) void {
    var scratch: [576]f32 = undefined;
    var src: usize = 0;
    var dst: usize = 0;
    var si: usize = 0;
    while (sfb[si] != 0) : (si += 3) {
        const len: usize = sfb[si];
        for (0..len) |_| {
            scratch[dst] = grbuf[src];
            scratch[dst + 1] = grbuf[src + len];
            scratch[dst + 2] = grbuf[src + 2 * len];
            dst += 3;
            src += 1;
        }
        src += 2 * len;
    }
    @memcpy(grbuf[0..dst], scratch[0..dst]);
}

fn l3_antialias(grbuf: []f32, nbands_in: i32) void {
    var nb = nbands_in;
    var off: usize = 0;
    while (nb > 0) : ({
        nb -= 1;
        off += 18;
    }) {
        for (0..8) |i| {
            const u = grbuf[off + 18 + i];
            const d = grbuf[off + 17 - i];
            grbuf[off + 18 + i] = u * AA[0][i] - d * AA[1][i];
            grbuf[off + 17 - i] = u * AA[1][i] + d * AA[0][i];
        }
    }
}

fn l3_dct3_9(y: *[9]f32) void {
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8];
    var t0 = s0 + s6 * 0.5;
    s0 -= s6;
    var t4 = (s4 + s2) * 0.93969262;
    var t2 = (s8 + s2) * 0.76604444;
    s6 = (s4 - s8) * 0.17364818;
    s4 += s8 - s2;

    s2 = s0 - s4 * 0.5;
    y[4] = s4 + s0;
    s8 = t0 - t2 + s6;
    s0 = t0 - t4 + t2;
    s4 = t0 + t4 - s6;

    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7];

    s3 *= 0.86602540;
    t0 = (s5 + s1) * 0.98480775;
    t4 = (s5 - s7) * 0.34202014;
    t2 = (s1 + s7) * 0.64278761;
    s1 = (s1 - s5 - s7) * 0.86602540;

    s5 = t0 - s3 - t2;
    s7 = t4 - s3 - t0;
    s3 = t4 + s3 - t2;

    y[0] = s4 - s7;
    y[1] = s2 + s1;
    y[2] = s0 - s3;
    y[3] = s8 + s5;
    y[5] = s8 - s5;
    y[6] = s0 + s3;
    y[7] = s2 - s1;
    y[8] = s4 + s7;
}

fn l3_imdct36(grbuf: []f32, overlap: []f32, window: *const [18]f32, nbands: usize) void {
    for (0..nbands) |j| {
        const g = j * 18;
        const o = j * 9;
        var co: [9]f32 = undefined;
        var si: [9]f32 = undefined;
        co[0] = -grbuf[g];
        si[0] = grbuf[g + 17];
        for (0..4) |i| {
            si[8 - 2 * i] = grbuf[g + 4 * i + 1] - grbuf[g + 4 * i + 2];
            co[1 + 2 * i] = grbuf[g + 4 * i + 1] + grbuf[g + 4 * i + 2];
            si[7 - 2 * i] = grbuf[g + 4 * i + 4] - grbuf[g + 4 * i + 3];
            co[2 + 2 * i] = -(grbuf[g + 4 * i + 3] + grbuf[g + 4 * i + 4]);
        }
        l3_dct3_9(&co);
        l3_dct3_9(&si);
        si[1] = -si[1];
        si[3] = -si[3];
        si[5] = -si[5];
        si[7] = -si[7];
        for (0..9) |i| {
            const ovl = overlap[o + i];
            const sum = co[i] * TWID9[9 + i] + si[i] * TWID9[i];
            overlap[o + i] = co[i] * TWID9[i] - si[i] * TWID9[9 + i];
            grbuf[g + i] = ovl * window[i] - sum * window[9 + i];
            grbuf[g + 17 - i] = ovl * window[9 + i] + sum * window[i];
        }
    }
}

fn l3_idct3(x0: f32, x1: f32, x2: f32, dst: *[3]f32) void {
    const m1 = x1 * 0.86602540;
    const a1 = x0 - x2 * 0.5;
    dst[1] = x0 + x2;
    dst[0] = a1 + m1;
    dst[2] = a1 - m1;
}

fn l3_imdct12(x: []const f32, dst: []f32, ov: []f32) void {
    var co: [3]f32 = undefined;
    var si: [3]f32 = undefined;
    l3_idct3(-x[0], x[6] + x[3], x[12] + x[9], &co);
    l3_idct3(x[15], x[12] - x[9], x[6] - x[3], &si);
    si[1] = -si[1];
    for (0..3) |i| {
        const ovl = ov[i];
        const sum = co[i] * TWID3[3 + i] + si[i] * TWID3[i];
        ov[i] = co[i] * TWID3[i] - si[i] * TWID3[3 + i];
        dst[i] = ovl * TWID3[2 - i] - sum * TWID3[5 - i];
        dst[5 - i] = ovl * TWID3[5 - i] + sum * TWID3[2 - i];
    }
}

fn l3_imdct_short(grbuf: []f32, overlap: []f32, nbands: usize) void {
    for (0..nbands) |b| {
        const g = b * 18;
        const o = b * 9;
        var tmp: [18]f32 = undefined;
        @memcpy(&tmp, grbuf[g..][0..18]);
        @memcpy(grbuf[g..][0..6], overlap[o..][0..6]);
        l3_imdct12(tmp[0..], grbuf[g + 6 ..][0..6], overlap[o + 6 ..][0..3]);
        l3_imdct12(tmp[1..], grbuf[g + 12 ..][0..6], overlap[o + 6 ..][0..3]);
        l3_imdct12(tmp[2..], overlap[o..][0..6], overlap[o + 6 ..][0..3]);
    }
}

fn l3_change_sign(grbuf: []f32) void {
    var b: usize = 1;
    while (b < 32) : (b += 2) {
        var i: usize = 1;
        while (i < 18) : (i += 2) grbuf[b * 18 + i] = -grbuf[b * 18 + i];
    }
}

fn l3_imdct_gr(grbuf: []f32, overlap: []f32, block_type: u8, n_long_bands: usize) void {
    if (n_long_bands != 0) l3_imdct36(grbuf, overlap, &MDCT_WINDOW[0], n_long_bands);
    const g = 18 * n_long_bands;
    const o = 9 * n_long_bands;
    if (block_type == SHORT_BLOCK_TYPE) {
        l3_imdct_short(grbuf[g..], overlap[o..], 32 - n_long_bands);
    } else {
        l3_imdct36(grbuf[g..], overlap[o..], &MDCT_WINDOW[@intFromBool(block_type == STOP_BLOCK_TYPE)], 32 - n_long_bands);
    }
}

fn dct_ii(grbuf: []f32, n: usize) void {
    for (0..n) |k| {
        var t: [4][8]f32 = undefined;
        for (0..8) |i| {
            const x0 = grbuf[k + i * 18];
            const x1 = grbuf[k + (15 - i) * 18];
            const x2 = grbuf[k + (16 + i) * 18];
            const x3 = grbuf[k + (31 - i) * 18];
            const t0 = x0 + x3;
            const t1 = x1 + x2;
            const t2 = (x1 - x2) * SEC[3 * i + 0];
            const t3 = (x0 - x3) * SEC[3 * i + 1];
            t[0][i] = t0 + t1;
            t[1][i] = (t0 - t1) * SEC[3 * i + 2];
            t[2][i] = t3 + t2;
            t[3][i] = (t3 - t2) * SEC[3 * i + 2];
        }
        for (0..4) |r| {
            const x = &t[r];
            var x0 = x[0];
            var x1 = x[1];
            var x2 = x[2];
            var x3 = x[3];
            var x4 = x[4];
            var x5 = x[5];
            var x6 = x[6];
            var x7 = x[7];
            var xt = x0 - x7;
            x0 += x7;
            x7 = x1 - x6;
            x1 += x6;
            x6 = x2 - x5;
            x2 += x5;
            x5 = x3 - x4;
            x3 += x4;
            x4 = x0 - x3;
            x0 += x3;
            x3 = x1 - x2;
            x1 += x2;
            x[0] = x0 + x1;
            x[4] = (x0 - x1) * 0.70710677;
            x5 = x5 + x6;
            x6 = (x6 + x7) * 0.70710677;
            x7 = x7 + xt;
            x3 = (x3 + x4) * 0.70710677;
            x5 -= x7 * 0.198912367;
            x7 += x5 * 0.382683432;
            x5 -= x7 * 0.198912367;
            x0 = xt - x6;
            xt += x6;
            x[1] = (xt + x7) * 0.50979561;
            x[2] = (x4 + x3) * 0.54119611;
            x[3] = (x0 - x5) * 0.60134488;
            x[5] = (x0 + x5) * 0.89997619;
            x[6] = (x4 - x3) * 1.30656302;
            x[7] = (xt - x7) * 2.56291556;
        }
        var y = k;
        for (0..7) |i| {
            grbuf[y + 0 * 18] = t[0][i];
            grbuf[y + 1 * 18] = t[2][i] + t[3][i] + t[3][i + 1];
            grbuf[y + 2 * 18] = t[1][i] + t[1][i + 1];
            grbuf[y + 3 * 18] = t[2][i + 1] + t[3][i] + t[3][i + 1];
            y += 4 * 18;
        }
        grbuf[y + 0 * 18] = t[0][7];
        grbuf[y + 1 * 18] = t[2][7] + t[3][7];
        grbuf[y + 2 * 18] = t[1][7];
        grbuf[y + 3 * 18] = t[3][7];
    }
}

const PCM_SCALE: f32 = 1.0 / 32768.0;

fn synth_pair(pcm: []f32, p: usize, nch: usize, z: []const f32, zo: usize) void {
    var a: f32 = (z[zo + 14 * 64] - z[zo]) * 29;
    a += (z[zo + 1 * 64] + z[zo + 13 * 64]) * 213;
    a += (z[zo + 12 * 64] - z[zo + 2 * 64]) * 459;
    a += (z[zo + 3 * 64] + z[zo + 11 * 64]) * 2037;
    a += (z[zo + 10 * 64] - z[zo + 4 * 64]) * 5153;
    a += (z[zo + 5 * 64] + z[zo + 9 * 64]) * 6574;
    a += (z[zo + 8 * 64] - z[zo + 6 * 64]) * 37489;
    a += z[zo + 7 * 64] * 75038;
    pcm[p] = a * PCM_SCALE;

    const z2 = zo + 2;
    a = z[z2 + 14 * 64] * 104;
    a += z[z2 + 12 * 64] * 1567;
    a += z[z2 + 10 * 64] * 9727;
    a += z[z2 + 8 * 64] * 64019;
    a += z[z2 + 6 * 64] * -9975;
    a += z[z2 + 4 * 64] * -45;
    a += z[z2 + 2 * 64] * 146;
    a += z[z2 + 0 * 64] * -5;
    pcm[p + 16 * nch] = a * PCM_SCALE;
}

fn synth(grbuf: []const f32, xl: usize, pcm: []f32, dstl: usize, nch: usize, lins: []f32, lo: usize) void {
    const xr = xl + 576 * (nch - 1);
    const dstr = dstl + (nch - 1);
    const zlin = lo + 15 * 64;

    lins[zlin + 4 * 15] = grbuf[xl + 18 * 16];
    lins[zlin + 4 * 15 + 1] = grbuf[xr + 18 * 16];
    lins[zlin + 4 * 15 + 2] = grbuf[xl];
    lins[zlin + 4 * 15 + 3] = grbuf[xr];

    lins[zlin + 4 * 31] = grbuf[xl + 1 + 18 * 16];
    lins[zlin + 4 * 31 + 1] = grbuf[xr + 1 + 18 * 16];
    lins[zlin + 4 * 31 + 2] = grbuf[xl + 1];
    lins[zlin + 4 * 31 + 3] = grbuf[xr + 1];

    synth_pair(pcm, dstr, nch, lins, lo + 4 * 15 + 1);
    synth_pair(pcm, dstr + 32 * nch, nch, lins, lo + 4 * 15 + 64 + 1);
    synth_pair(pcm, dstl, nch, lins, lo + 4 * 15);
    synth_pair(pcm, dstl + 32 * nch, nch, lins, lo + 4 * 15 + 64);

    var wi: usize = 0;
    var ii: usize = 15;
    while (ii > 0) {
        ii -= 1;
        const i = ii;
        var a: [4]f32 = undefined;
        var b: [4]f32 = undefined;

        lins[zlin + 4 * i] = grbuf[xl + 18 * (31 - i)];
        lins[zlin + 4 * i + 1] = grbuf[xr + 18 * (31 - i)];
        lins[zlin + 4 * i + 2] = grbuf[xl + 1 + 18 * (31 - i)];
        lins[zlin + 4 * i + 3] = grbuf[xr + 1 + 18 * (31 - i)];
        lins[zlin + 4 * (i + 16)] = grbuf[xl + 1 + 18 * (1 + i)];
        lins[zlin + 4 * (i + 16) + 1] = grbuf[xr + 1 + 18 * (1 + i)];
        lins[zlin + 4 * i - 64 + 2] = grbuf[xl + 18 * (1 + i)];
        lins[zlin + 4 * i - 64 + 3] = grbuf[xr + 18 * (1 + i)];

        for (0..8) |k| {
            const w0 = WIN[wi];
            const w1 = WIN[wi + 1];
            wi += 2;
            const vz = zlin + 4 * i - k * 64;
            const vy = zlin + 4 * i - (15 - k) * 64;
            for (0..4) |j| {
                const bz = lins[vz + j] * w1 + lins[vy + j] * w0;
                const az = if (k & 1 == 1) lins[vy + j] * w1 - lins[vz + j] * w0 else lins[vz + j] * w0 - lins[vy + j] * w1;
                if (k == 0) {
                    b[j] = bz;
                    a[j] = az;
                } else {
                    b[j] += bz;
                    a[j] += az;
                }
            }
        }

        pcm[dstr + (15 - i) * nch] = a[1] * PCM_SCALE;
        pcm[dstr + (17 + i) * nch] = b[1] * PCM_SCALE;
        pcm[dstl + (15 - i) * nch] = a[0] * PCM_SCALE;
        pcm[dstl + (17 + i) * nch] = b[0] * PCM_SCALE;
        pcm[dstr + (47 - i) * nch] = a[3] * PCM_SCALE;
        pcm[dstr + (49 + i) * nch] = b[3] * PCM_SCALE;
        pcm[dstl + (47 - i) * nch] = a[2] * PCM_SCALE;
        pcm[dstl + (49 + i) * nch] = b[2] * PCM_SCALE;
    }
}

fn synth_granule(qmf_state: []f32, grbuf: []f32, nbands: usize, nch: usize, pcm: []f32, pcm_off: usize, lins: []f32) void {
    for (0..nch) |ch| dct_ii(grbuf[576 * ch ..], nbands);
    @memcpy(lins[0 .. 15 * 64], qmf_state[0 .. 15 * 64]);
    var i: usize = 0;
    while (i < nbands) : (i += 2) {
        synth(grbuf, i, pcm, pcm_off + 32 * nch * i, nch, lins, i * 64);
    }
    if (nch == 1) {
        var k: usize = 0;
        while (k < 15 * 64) : (k += 2) qmf_state[k] = lins[nbands * 64 + k];
    } else {
        @memcpy(qmf_state[0 .. 15 * 64], lins[nbands * 64 ..][0 .. 15 * 64]);
    }
}

fn match_frame(hdr: []const u8, frame_bytes: usize) bool {
    var i: usize = 0;
    for (0..MAX_FRAME_SYNC_MATCHES) |nmatch| {
        i += hdr_frame_bytes(hdr[i..], frame_bytes) + hdr_padding(hdr[i..]);
        if (i + HDR_SIZE > hdr.len) return nmatch > 0;
        if (!hdr_compare(hdr, hdr[i..])) return false;
    }
    return true;
}

fn find_frame(mp3: []const u8, free_format_bytes: *usize, ptr_frame_bytes: *usize) usize {
    var i: usize = 0;
    while (i + HDR_SIZE < mp3.len) : (i += 1) {
        const h = mp3[i..];
        if (!hdr_valid(h)) continue;
        var frame_bytes = hdr_frame_bytes(h, free_format_bytes.*);
        var frame_and_padding = frame_bytes + hdr_padding(h);

        var k: usize = HDR_SIZE;
        while (frame_bytes == 0 and k < MAX_FREE_FORMAT_FRAME_SIZE and i + 2 * k + HDR_SIZE < mp3.len) : (k += 1) {
            if (hdr_compare(h, h[k..])) {
                const fb = k - hdr_padding(h);
                const nextfb = fb + hdr_padding(h[k..]);
                if (i + k + nextfb + HDR_SIZE > mp3.len or !hdr_compare(h, h[k + nextfb ..])) continue;
                frame_and_padding = k;
                frame_bytes = fb;
                free_format_bytes.* = fb;
            }
        }
        if ((frame_bytes != 0 and i + frame_and_padding <= mp3.len and match_frame(h, frame_bytes)) or
            (i == 0 and frame_and_padding == mp3.len))
        {
            ptr_frame_bytes.* = frame_and_padding;
            return i;
        }
        free_format_bytes.* = 0;
    }
    ptr_frame_bytes.* = 0;
    return mp3.len;
}

const Decoder = struct {
    mdct_overlap: [2][9 * 32]f32 = @splat(@splat(0)),
    qmf_state: [15 * 2 * 32]f32 = @splat(0),
    reserv: usize = 0,
    free_format_bytes: usize = 0,
    header: [4]u8 = .{ 0, 0, 0, 0 },
    reserv_buf: [MAX_BITRESERVOIR_BYTES]u8 = @splat(0),

    bs: BitStream = .{ .buf = &.{}, .limit = 0 },
    maindata: [MAX_BITRESERVOIR_BYTES + MAX_L3_FRAME_PAYLOAD_BYTES + 64]u8 = @splat(0),
    gr_info: [4]GrInfo = @splat(.{}),
    grbuf: [2 * 576]f32 = @splat(0),
    scf: [40]f32 = @splat(0),
    syn: [33 * 64]f32 = @splat(0),
    ist_pos: [2][39]u8 = @splat(@splat(0)),

    fn reset(self: *Decoder) void {
        self.mdct_overlap = @splat(@splat(0));
        self.qmf_state = @splat(0);
        self.reserv = 0;
        self.free_format_bytes = 0;
        self.header = .{ 0, 0, 0, 0 };
    }

    fn save_reservoir(self: *Decoder) void {
        var pos: usize = (self.bs.pos + 7) / 8;
        const limit_bytes = self.bs.limit / 8;
        if (pos >= limit_bytes) {
            self.reserv = 0;
            return;
        }
        var remains = limit_bytes - pos;
        if (remains > MAX_BITRESERVOIR_BYTES) {
            pos += remains - MAX_BITRESERVOIR_BYTES;
            remains = MAX_BITRESERVOIR_BYTES;
        }
        std.mem.copyForwards(u8, self.reserv_buf[0..remains], self.maindata[pos..][0..remains]);
        self.reserv = remains;
    }

    fn restore_reservoir(self: *Decoder, bs: *const BitStream, main_data_begin: usize) bool {
        const frame_bytes = (bs.limit - bs.pos) / 8;
        const bytes_have = @min(self.reserv, main_data_begin);
        const from = if (self.reserv > main_data_begin) self.reserv - main_data_begin else 0;
        @memcpy(self.maindata[0..bytes_have], self.reserv_buf[from..][0..bytes_have]);
        @memcpy(self.maindata[bytes_have..][0..frame_bytes], bs.buf[bs.pos / 8 ..][0..frame_bytes]);
        self.bs = BitStream.init(self.maindata[0 .. bytes_have + frame_bytes]);
        return self.reserv >= main_data_begin;
    }

    fn l3_decode(self: *Decoder, nch: usize, gr_base: usize) void {
        const hdr: []const u8 = &self.header;
        for (0..nch) |ch| {
            const gr = &self.gr_info[gr_base + ch];
            const limit = self.bs.pos + gr.part_23_length;
            l3_decode_scalefactors(hdr, &self.ist_pos[ch], &self.bs, gr, &self.scf, ch);
            l3_huffman(self.grbuf[ch * 576 ..][0..576], &self.bs, &self.maindata, gr, &self.scf, limit);
        }

        if (hdr_test_i_stereo(hdr)) {
            l3_intensity_stereo(&self.grbuf, &self.ist_pos[1], self.gr_info[gr_base..], hdr);
        } else if (hdr_is_ms_stereo(hdr)) {
            l3_midside_stereo(&self.grbuf, 0, 576);
        }

        for (0..nch) |ch| {
            const gr = &self.gr_info[gr_base + ch];
            var aa_bands: i32 = 31;
            const n_long_bands: usize = @as(usize, if (gr.mixed_block_flag != 0) 2 else 0) << @intFromBool(hdr_my_sample_rate(hdr) == 2);
            const buf = self.grbuf[ch * 576 ..][0..576];
            if (gr.n_short_sfb != 0) {
                aa_bands = @as(i32, @intCast(n_long_bands)) - 1;
                l3_reorder(buf[n_long_bands * 18 ..], gr.sfbtab[gr.n_long_sfb..]);
            }
            l3_antialias(buf, aa_bands);
            l3_imdct_gr(buf, &self.mdct_overlap[ch], gr.block_type, n_long_bands);
            l3_change_sign(buf);
        }
    }

    /// Decodes one frame into interleaved `pcm`; returns samples per channel (0 if skipped).
    fn decode_frame(self: *Decoder, mp3: []const u8, pcm: []f32, info: *FrameInfo) usize {
        var i: usize = 0;
        var frame_size: usize = 0;

        if (mp3.len > 4 and self.header[0] == 0xff and hdr_compare(&self.header, mp3)) {
            frame_size = hdr_frame_bytes(mp3, self.free_format_bytes) + hdr_padding(mp3);
            if (frame_size != mp3.len and (frame_size + HDR_SIZE > mp3.len or !hdr_compare(mp3, mp3[frame_size..]))) {
                frame_size = 0;
            }
        }
        if (frame_size == 0) {
            self.reset();
            i = find_frame(mp3, &self.free_format_bytes, &frame_size);
            if (frame_size == 0 or i + frame_size > mp3.len) {
                info.frame_bytes = i;
                return 0;
            }
        }

        const hdr = mp3[i..];
        @memcpy(&self.header, hdr[0..4]);
        info.* = .{
            .frame_bytes = i + frame_size,
            .frame_offset = i,
            .channels = if (hdr_is_mono(hdr)) 1 else 2,
            .hz = hdr_sample_rate_hz(hdr),
            .layer = 4 - hdr_layer(hdr),
            .bitrate_kbps = hdr_bitrate_kbps(hdr),
        };
        if (info.layer != 3) return 0;

        var bs_frame = BitStream.init(hdr[HDR_SIZE..frame_size]);
        if (hdr_is_crc(hdr)) _ = bs_frame.get_bits(16);

        const main_data_begin = l3_read_side_info(&bs_frame, &self.gr_info, hdr);
        if (main_data_begin < 0 or bs_frame.pos > bs_frame.limit) {
            self.header[0] = 0;
            return 0;
        }
        const nch = info.channels;
        const success = self.restore_reservoir(&bs_frame, @intCast(main_data_begin));
        if (success) {
            const ngr: usize = if (hdr_test_mpeg1(hdr)) 2 else 1;
            for (0..ngr) |igr| {
                @memset(&self.grbuf, 0);
                self.l3_decode(nch, igr * nch);
                synth_granule(&self.qmf_state, &self.grbuf, 18, nch, pcm, igr * 576 * nch, &self.syn);
            }
        }
        self.save_reservoir();
        return if (success) hdr_frame_samples(&self.header) else 0;
    }
};

pub const Audio = struct {
    /// Interleaved samples, `channels` per frame.
    pcm: []f32,
    channels: usize,
    rate: u32,
    bitrate_kbps: u32,
};

fn id3v2_size(data: []const u8) usize {
    if (data.len < 10 or !std.mem.eql(u8, data[0..3], "ID3")) return 0;
    const size = (@as(usize, data[6] & 0x7f) << 21) | (@as(usize, data[7] & 0x7f) << 14) |
        (@as(usize, data[8] & 0x7f) << 7) | (data[9] & 0x7f);
    const footer: usize = if (data[5] & 0x10 != 0) 10 else 0;
    return @min(data.len, 10 + size + footer);
}

/// Encoder delay from the LAME extension of a Xing/Info frame, or null if this is an audio frame.
fn xing_delay(frame: []const u8) ?usize {
    const scan = frame[0..@min(frame.len, 64)];
    const x = std.mem.indexOf(u8, scan, "Xing") orelse std.mem.indexOf(u8, scan, "Info") orelse return null;
    if (x + 8 > frame.len) return 0;
    const flags = std.mem.readInt(u32, frame[x + 4 ..][0..4], .big);
    var off = x + 8;
    if (flags & 1 != 0) off += 4;
    if (flags & 2 != 0) off += 4;
    if (flags & 4 != 0) off += 100;
    if (flags & 8 != 0) off += 4;
    if (off + 24 > frame.len or frame[off] == 0) return 0;
    return (@as(usize, frame[off + 21]) << 4) | (frame[off + 22] >> 4);
}

pub fn decode_mp3(a: Allocator, data_in: []const u8) !Audio {
    var data = data_in[id3v2_size(data_in)..];
    if (data.len >= 128 and std.mem.eql(u8, data[data.len - 128 ..][0..3], "TAG")) data = data[0 .. data.len - 128];

    const dec = try a.create(Decoder);
    dec.* = .{};
    var out: std.ArrayList(f32) = .empty;
    var pcm: [MAX_SAMPLES_PER_FRAME]f32 = undefined;
    var info: FrameInfo = .{};
    var channels: usize = 0;
    var rate: u32 = 0;
    var bitrate: u32 = 0;
    var skip: usize = 0;
    var first = true;
    var pos: usize = 0;

    while (pos < data.len) {
        const n = dec.decode_frame(data[pos..], &pcm, &info);
        if (info.frame_bytes == 0) break;
        const frame = data[pos + info.frame_offset .. pos + info.frame_bytes];
        pos += info.frame_bytes;
        if (n == 0) continue;
        if (first) {
            first = false;
            channels = info.channels;
            rate = info.hz;
            bitrate = info.bitrate_kbps;
            if (xing_delay(frame)) |delay| {
                skip = if (delay > 0) delay + 529 else 0;
                continue;
            }
        }
        for (0..n) |s| {
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            const l = pcm[s * info.channels];
            const r = pcm[s * info.channels + info.channels - 1];
            if (channels == 2) {
                try out.append(a, l);
                try out.append(a, r);
            } else {
                try out.append(a, (l + r) * 0.5);
            }
        }
    }
    if (channels == 0) return error.NoMp3Frames;
    const seconds = @as(f64, @floatFromInt(out.items.len / channels)) / @as(f64, @floatFromInt(rate));
    if (seconds > 0) bitrate = @intFromFloat(@round(@as(f64, @floatFromInt(data.len)) * 8 / seconds / 1000));
    return .{ .pcm = try out.toOwnedSlice(a), .channels = channels, .rate = rate, .bitrate_kbps = bitrate };
}

pub fn write_wav(io: std.Io, path: []const u8, audio: Audio) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [16384]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    const ch: u32 = @intCast(audio.channels);
    const data_bytes: u32 = @intCast(audio.pcm.len * 2);
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_bytes, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, @intCast(ch), .little);
    try w.writeInt(u32, audio.rate, .little);
    try w.writeInt(u32, audio.rate * ch * 2, .little);
    try w.writeInt(u16, @intCast(ch * 2), .little);
    try w.writeInt(u16, 16, .little);
    try w.writeAll("data");
    try w.writeInt(u32, data_bytes, .little);
    for (audio.pcm) |s| {
        const v: i16 = @intFromFloat(std.math.clamp(@round(s * 32768.0), -32768.0, 32767.0));
        try w.writeInt(i16, v, .little);
    }
    try w.flush();
}

// ============================================================================
// Analysis
// ============================================================================

const TARGET_RATE = 22050;
const HOP = 512;
const N_ONSET = 1024;
const N_PITCH = 4096;
const N_BASS = 8192;
const MIN_WINDOWS = 4;
const PITCH_MAX_HZ = 5000.0;
const BASS_MAX_HZ = 800.0;
const HPSS_HALF = 8;
const LOG_GAIN = 1000.0;

const MIDI_LO = 28;
const MIDI_HI = 96;
const BASS_HI = 47;
const PITCHED_LO = 48;
const HARMONICS = 8;
const HARMONIC_DECAY = 0.8;
const PITCH_TOL_SEMIS = 0.3;
const FUND_RATIO = 0.25;
const MAX_VOICES = 4;
const CANCEL_GAIN = 0.15;
const CANCEL_WIDEN = 1;
const VOICE_ABS = 0.5;
const VOICE_REL = 0.7;
const BASS_ABS = 0.4;
const MIN_NOTE_FRAMES = 4;
const GAP_FRAMES = 2;
const SPLIT_RISE = 1.5;
const NOTE_ONSET_DELTA = 0.5;
const BASS_ONSET_LO = 40.0;
const BASS_ONSET_HI = 300.0;
const MID_ONSET_LO = 200.0;
const MID_ONSET_HI = 5000.0;
const BASS_SNAP_FRAMES = 6;
const MID_SNAP_FRAMES = 3;

pub const TEMPO_MIN = 60.0;
pub const TEMPO_MAX = 200.0;
const TEMPO_PRIOR_BPM = 120.0;
const TEMPO_PRIOR_OCTAVES = 0.6;
const TEMPO_HINT_OCTAVES = 0.25;
const BEAT_TIGHTNESS = 100.0;

const DRUM_DELTA = 1.2;
const DRUM_MIN_GAP = 3;
pub const DrumBand = struct { name: []const u8, lo: f32, hi: f32 };
pub const DRUM_BANDS = [_]DrumBand{
    .{ .name = "kick", .lo = 40, .hi = 120 },
    .{ .name = "snare", .lo = 1500, .hi = 5000 },
    .{ .name = "hihat", .lo = 7000, .hi = 11000 },
};

const Fft = struct {
    n: usize,
    bits: u5,
    cos: []f32,
    sin: []f32,
    window: []f32,
    re: []f32,
    im: []f32,
    scale: f32,

    fn init(a: Allocator, n: usize) !Fft {
        const self = Fft{
            .n = n,
            .bits = @intCast(std.math.log2_int(usize, n)),
            .cos = try a.alloc(f32, n / 2),
            .sin = try a.alloc(f32, n / 2),
            .window = try a.alloc(f32, n),
            .re = try a.alloc(f32, n),
            .im = try a.alloc(f32, n),
            .scale = 4.0 / @as(f32, @floatFromInt(n)),
        };
        const nf: f32 = @floatFromInt(n);
        for (0..n / 2) |k| {
            const ang = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / nf;
            self.cos[k] = @cos(ang);
            self.sin[k] = @sin(ang);
        }
        for (0..n) |i| self.window[i] = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) / nf);
        return self;
    }

    /// Hann-windowed frame centered on `center`; fills `out` with magnitudes (sine amplitude scale).
    fn magnitudes(self: *Fft, x: []const f32, center: usize, out: []f32) void {
        const n = self.n;
        const start = @as(isize, @intCast(center)) - @as(isize, @intCast(n / 2));
        for (0..n) |i| {
            const idx = start + @as(isize, @intCast(i));
            const v = if (idx >= 0 and idx < x.len) x[@intCast(idx)] else 0;
            const r = @bitReverse(@as(u32, @intCast(i))) >> (31 - self.bits + 1);
            self.re[r] = v * self.window[i];
            self.im[r] = 0;
        }
        var size: usize = 2;
        while (size <= n) : (size *= 2) {
            const half = size / 2;
            const step = n / size;
            var s: usize = 0;
            while (s < n) : (s += size) {
                for (0..half) |k| {
                    const wr = self.cos[k * step];
                    const wi = -self.sin[k * step];
                    const ia = s + k;
                    const ib = ia + half;
                    const tr = self.re[ib] * wr - self.im[ib] * wi;
                    const ti = self.re[ib] * wi + self.im[ib] * wr;
                    self.re[ib] = self.re[ia] - tr;
                    self.im[ib] = self.im[ia] - ti;
                    self.re[ia] += tr;
                    self.im[ia] += ti;
                }
            }
        }
        for (out, 0..) |*o, k| o.* = @sqrt(self.re[k] * self.re[k] + self.im[k] * self.im[k]) * self.scale;
    }
};

const Spec = struct {
    frames: usize,
    bins: usize,
    n: usize,
    data: []f32,

    fn row(self: Spec, t: usize) []f32 {
        return self.data[t * self.bins ..][0..self.bins];
    }
};

fn stft(a: Allocator, x: []const f32, n: usize, max_hz: f32, rate: f32) !Spec {
    const frames = x.len / HOP + 1;
    const max_bin: usize = @intFromFloat(@ceil(max_hz * @as(f32, @floatFromInt(n)) / rate));
    const bins = @min(n / 2 + 1, max_bin + 1);
    var fft = try Fft.init(a, n);
    const full = try a.alloc(f32, n / 2 + 1);
    const spec = Spec{ .frames = frames, .bins = bins, .n = n, .data = try a.alloc(f32, frames * bins) };
    for (0..frames) |t| {
        fft.magnitudes(x, t * HOP, full);
        @memcpy(spec.row(t), full[0..bins]);
    }
    return spec;
}

fn sliding_median(src: []const f32, dst: []f32, half: usize, win: []f32) void {
    const n = src.len;
    const w = 2 * half + 1;
    const at = struct {
        fn f(s: []const f32, j: isize) f32 {
            return s[@intCast(std.math.clamp(j, 0, @as(isize, @intCast(s.len - 1))))];
        }
    }.f;
    for (0..w) |k| win[k] = at(src, @as(isize, @intCast(k)) - @as(isize, @intCast(half)));
    std.mem.sort(f32, win[0..w], {}, std.sort.asc(f32));
    for (0..n) |i| {
        dst[i] = win[half];
        if (i + 1 >= n) break;
        const out_v = at(src, @as(isize, @intCast(i)) - @as(isize, @intCast(half)));
        const in_v = at(src, @as(isize, @intCast(i + 1 + half)));
        var r: usize = 0;
        while (win[r] != out_v) r += 1;
        while (r + 1 < w) : (r += 1) win[r] = win[r + 1];
        var p: usize = w - 1;
        while (p > 0 and win[p - 1] > in_v) : (p -= 1) win[p] = win[p - 1];
        win[p] = in_v;
    }
}

/// Median-filtering harmonic/percussive separation (soft masks).
fn hpss(a: Allocator, s: Spec) !struct { harm: Spec, perc: Spec } {
    var harm = s;
    var perc = s;
    harm.data = try a.alloc(f32, s.data.len);
    perc.data = try a.alloc(f32, s.data.len);
    const col = try a.alloc(f32, s.frames);
    const med = try a.alloc(f32, s.frames);
    var win: [2 * HPSS_HALF + 1]f32 = undefined;

    for (0..s.bins) |k| {
        for (0..s.frames) |t| col[t] = s.data[t * s.bins + k];
        sliding_median(col, med, HPSS_HALF, &win);
        for (0..s.frames) |t| harm.data[t * s.bins + k] = med[t];
    }
    for (0..s.frames) |t| sliding_median(s.row(t), perc.row(t), HPSS_HALF, &win);

    for (s.data, harm.data, perc.data) |x, *h, *p| {
        const h2 = h.* * h.*;
        const p2 = p.* * p.*;
        const m = h2 / (h2 + p2 + 1e-20);
        h.* = x * m;
        p.* = x * (1 - m);
    }
    return .{ .harm = harm, .perc = perc };
}

fn max_of(xs: []const f32) f32 {
    var m: f32 = 0;
    for (xs) |x| m = @max(m, x);
    return m;
}

fn percentile(a: Allocator, xs: []const f32, q: f32) !f32 {
    var tmp: std.ArrayList(f32) = .empty;
    defer tmp.deinit(a);
    for (xs) |x| if (x > 0) try tmp.append(a, x);
    if (tmp.items.len == 0) return 0;
    std.mem.sort(f32, tmp.items, {}, std.sort.asc(f32));
    const idx: usize = @intFromFloat(q * @as(f32, @floatFromInt(tmp.items.len - 1)));
    return tmp.items[idx];
}

fn log_compress(a: Allocator, s: Spec) !Spec {
    var out = s;
    out.data = try a.alloc(f32, s.data.len);
    const g = LOG_GAIN / @max(max_of(s.data), 1e-12);
    for (s.data, out.data) |x, *o| o.* = @log(1 + g * x);
    return out;
}

fn hz_to_bin(hz: f32, n: usize, rate: f32) f32 {
    return hz * @as(f32, @floatFromInt(n)) / rate;
}

fn midi_hz(p: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (p - 69.0) / 12.0);
}

// ---------------------------------------------------------------- tempo / beats

fn onset_envelope(a: Allocator, logspec: Spec) ![]f32 {
    const env = try a.alloc(f32, logspec.frames);
    env[0] = 0;
    for (1..logspec.frames) |t| {
        const cur = logspec.row(t);
        const prev = logspec.row(t - 1);
        var sum: f32 = 0;
        for (cur, prev) |c, p| sum += @max(0, c - p);
        env[t] = sum;
    }
    const smooth = try a.alloc(f32, env.len);
    const half: usize = 8;
    for (0..env.len) |t| {
        const lo = t -| half;
        const hi = @min(env.len, t + half + 1);
        var m: f32 = 0;
        for (env[lo..hi]) |v| m += v;
        m /= @floatFromInt(hi - lo);
        smooth[t] = @max(0, env[t] - m);
    }
    const peak = max_of(smooth);
    if (peak > 0) for (smooth) |*v| {
        v.* /= peak;
    };
    return smooth;
}

fn sample_at(xs: []const f32, pos: f32) f32 {
    const i: usize = @intFromFloat(pos);
    if (i + 1 >= xs.len) return 0;
    const f = pos - @as(f32, @floatFromInt(i));
    return xs[i] * (1 - f) + xs[i + 1] * f;
}

fn autocorr_at(env: []const f32, lag: f32) f32 {
    var sum: f32 = 0;
    const span: usize = @intFromFloat(@ceil(lag));
    if (span + 1 >= env.len) return 0;
    for (0..env.len - span - 1) |t| sum += env[t] * sample_at(env, @as(f32, @floatFromInt(t)) + lag);
    return sum / @as(f32, @floatFromInt(env.len - span));
}

pub const TempoPrior = struct { center: f32, octaves: f32 };

pub fn tempo_prior(bpm_hint: ?f32) TempoPrior {
    return if (bpm_hint) |h|
        .{ .center = h, .octaves = TEMPO_HINT_OCTAVES }
    else
        .{ .center = TEMPO_PRIOR_BPM, .octaves = TEMPO_PRIOR_OCTAVES };
}

fn estimate_tempo(env: []const f32, fps: f32, prior_cfg: TempoPrior) f32 {
    var best_bpm: f32 = prior_cfg.center;
    var best: f32 = -1;
    var bpm: f32 = TEMPO_MIN;
    while (bpm <= TEMPO_MAX) : (bpm += 0.5) {
        const lag = fps * 60.0 / bpm;
        const prior = @exp(-0.5 * std.math.pow(f32, @log2(bpm / prior_cfg.center) / prior_cfg.octaves, 2));
        const score = autocorr_at(env, lag) * prior;
        if (score > best) {
            best = score;
            best_bpm = bpm;
        }
    }
    return best_bpm;
}

/// Precise tempo from a least-squares line through the tracked beat times.
fn beat_grid_bpm(a: Allocator, beats: []const f32) !?f32 {
    if (beats.len < 8) return null;
    const ibi = try a.alloc(f32, beats.len - 1);
    for (ibi, 0..) |*d, i| d.* = beats[i + 1] - beats[i];
    const med = try percentile(a, ibi, 0.5);
    if (med <= 0) return null;
    const n: f64 = @floatFromInt(beats.len);
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var x: f64 = 0;
    for (beats, 0..) |t, i| {
        if (i > 0) x += @max(1, @round(ibi[i - 1] / med));
        sx += x;
        sy += t;
        sxx += x * x;
        sxy += x * t;
    }
    const slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    return if (slope > 0) @floatCast(60.0 / slope) else null;
}

/// Dynamic-programming beat tracker (Ellis 2007); returns beat frame indices.
fn track_beats(a: Allocator, env: []const f32, fps: f32, bpm: f32) ![]usize {
    const period = fps * 60.0 / bpm;
    const n = env.len;
    const score = try a.alloc(f32, n);
    const back = try a.alloc(isize, n);
    const lo_off: usize = @intFromFloat(@round(period / 2));
    const hi_off: usize = @intFromFloat(@round(period * 2));
    for (0..n) |t| {
        var best: f32 = -std.math.inf(f32);
        var arg: isize = -1;
        if (t > lo_off) {
            var tau = t -| hi_off;
            while (tau + lo_off <= t) : (tau += 1) {
                const d = @as(f32, @floatFromInt(t - tau)) / period;
                const v = score[tau] - BEAT_TIGHTNESS * std.math.pow(f32, @log(d), 2);
                if (v > best) {
                    best = v;
                    arg = @intCast(tau);
                }
            }
        }
        score[t] = env[t] + if (arg >= 0) @max(best, 0) else 0;
        back[t] = if (arg >= 0 and best > 0) arg else -1;
    }
    const tail: usize = @intFromFloat(@round(period));
    var last: usize = n - 1;
    var best: f32 = -1;
    for (n -| tail..n) |t| if (score[t] > best) {
        best = score[t];
        last = t;
    };
    var beats: std.ArrayList(usize) = .empty;
    var cur: isize = @intCast(last);
    while (cur >= 0) : (cur = back[@intCast(cur)]) try beats.append(a, @intCast(cur));
    std.mem.reverse(usize, beats.items);

    // Drop weak leading/trailing beats (silence before/after the music).
    const items = beats.items;
    var mean: f32 = 0;
    for (items) |b| mean += env[b];
    mean /= @floatFromInt(@max(items.len, 1));
    var s: usize = 0;
    var e: usize = items.len;
    while (s < e and env[items[s]] < 0.2 * mean) s += 1;
    while (e > s and env[items[e - 1]] < 0.2 * mean) e -= 1;
    return items[s..e];
}

// ---------------------------------------------------------------- drums

pub const Hit = struct { time: f32, velocity: f32 };

const Peak = struct { frame: usize, strength: f32 };

/// Spectral-flux onset peaks within a frequency band; strength is relative to the 99th percentile.
fn band_onsets(a: Allocator, log_spec: Spec, lo_hz: f32, hi_hz: f32, rate: f32, delta: f32) ![]Peak {
    const n = log_spec.frames;
    const lo: usize = @intFromFloat(@floor(hz_to_bin(lo_hz, log_spec.n, rate)));
    const hi: usize = @min(log_spec.bins, @as(usize, @intFromFloat(@ceil(hz_to_bin(hi_hz, log_spec.n, rate)))) + 1);
    if (lo + 1 >= hi) return &.{};
    const odf = try a.alloc(f32, n);
    odf[0] = 0;
    for (1..n) |t| {
        const cur = log_spec.row(t)[lo..hi];
        const prev = log_spec.row(t - 1)[lo..hi];
        var sum: f32 = 0;
        for (cur, prev) |c, p| sum += @max(0, c - p);
        odf[t] = sum / @as(f32, @floatFromInt(hi - lo));
    }
    var mean: f32 = 0;
    for (odf) |v| mean += v;
    mean /= @floatFromInt(n);
    var variance: f32 = 0;
    for (odf) |v| variance += (v - mean) * (v - mean);
    const sd = @sqrt(variance / @as(f32, @floatFromInt(n)));
    const ref = @max(try percentile(a, odf, 0.99), 1e-9);

    var peaks: std.ArrayList(Peak) = .empty;
    var last: usize = 0;
    const win: usize = 16;
    for (2..n -| 2) |t| {
        const v = odf[t];
        if (v < odf[t - 1] or v < odf[t - 2] or v <= odf[t + 1] or v <= odf[t + 2]) continue;
        const l = t -| win;
        const r = @min(n, t + win + 1);
        var local: f32 = 0;
        for (odf[l..r]) |x| local += x;
        local /= @floatFromInt(r - l);
        if (v < local + delta * sd) continue;
        if (peaks.items.len > 0 and t - last < DRUM_MIN_GAP) continue;
        last = t;
        try peaks.append(a, .{ .frame = t, .strength = @min(1.0, v / ref) });
    }
    return peaks.items;
}

fn detect_drums(a: Allocator, perc_log: Spec, band: DrumBand, rate: f32, fps: f32) ![]Hit {
    const peaks = try band_onsets(a, perc_log, band.lo, band.hi, rate, DRUM_DELTA);
    const hits = try a.alloc(Hit, peaks.len);
    for (peaks, hits) |p, *h| h.* = .{ .time = @as(f32, @floatFromInt(p.frame)) / fps, .velocity = p.strength };
    return hits;
}

fn onset_mask(a: Allocator, peaks: []const Peak, frames: usize) ![]bool {
    const mask = try a.alloc(bool, frames);
    @memset(mask, false);
    for (peaks) |p| if (p.frame < frames) {
        mask[p.frame] = true;
    };
    return mask;
}

// ---------------------------------------------------------------- pitch

const PitchTable = struct {
    const NP = MIDI_HI - MIDI_LO + 1;
    lo: [NP][HARMONICS]u16,
    hi: [NP][HARMONICS]u16,
    nh: [NP]u8,

    fn build(n: usize, rate: f32, bins: usize) PitchTable {
        var t: PitchTable = undefined;
        const tol_ratio = std.math.pow(f32, 2.0, PITCH_TOL_SEMIS / 12.0) - 1;
        for (0..NP) |pi| {
            const f0 = midi_hz(@floatFromInt(MIDI_LO + pi));
            var nh: u8 = 0;
            for (0..HARMONICS) |h| {
                const c = hz_to_bin(f0 * @as(f32, @floatFromInt(h + 1)), n, rate);
                const tol = @max(0.5, c * tol_ratio);
                const lo = @ceil(c - tol);
                const hi = @floor(c + tol);
                if (hi >= @as(f32, @floatFromInt(bins - 1))) break;
                t.lo[pi][h] = @intFromFloat(@max(1, lo));
                t.hi[pi][h] = @intFromFloat(@max(lo, hi));
                nh += 1;
            }
            t.nh[pi] = nh;
        }
        return t;
    }

    fn partial(t: *const PitchTable, row: []const f32, pi: usize, h: usize) f32 {
        var m: f32 = 0;
        for (t.lo[pi][h]..@as(usize, t.hi[pi][h]) + 1) |k| m = @max(m, row[k]);
        return m;
    }

    /// Weighted harmonic sum; 0 when the fundamental is too weak to be a real note.
    fn salience(t: *const PitchTable, row: []const f32, pi: usize, fund_ratio: f32) f32 {
        if (t.nh[pi] < 2) return 0;
        var sum: f32 = 0;
        var w: f32 = 1;
        var strongest: f32 = 0;
        const fund = t.partial(row, pi, 0);
        for (0..t.nh[pi]) |h| {
            const v = t.partial(row, pi, h);
            strongest = @max(strongest, v);
            sum += w * v;
            w *= HARMONIC_DECAY;
        }
        if (fund < fund_ratio * strongest) return 0;
        return sum;
    }

    /// Attenuates a pitch's partials, widened to cover the Hann window's main lobe.
    fn cancel(t: *const PitchTable, row: []f32, pi: usize) void {
        for (0..t.nh[pi]) |h| {
            const lo = @as(usize, t.lo[pi][h]) -| CANCEL_WIDEN;
            const hi = @min(row.len, @as(usize, t.hi[pi][h]) + CANCEL_WIDEN + 1);
            for (lo..hi) |k| row[k] *= CANCEL_GAIN;
        }
    }
};

const Voice = struct { pitch: u8 = 0, sal: f32 = 0 };

pub const Note = struct {
    start: f32,
    end: f32,
    pitch: u8,
    velocity: f32,
};

fn less_note(_: void, x: Note, y: Note) bool {
    return if (x.start != y.start) x.start < y.start else x.pitch < y.pitch;
}

const NoteOnsets = struct {
    mask: []const bool,
    /// How many frames after a detected pitch start to look for the real attack (long FFT windows see notes early).
    snap: usize,
};

/// Turns a per-frame pitch track (0 = silent) into notes, splitting repeated notes at onsets.
fn track_notes(a: Allocator, out: *std.ArrayList(Note), pitch: []const u8, sal: []const f32, ref: f32, fps: f32, onsets: NoteOnsets) !void {
    const n = pitch.len;
    var t: usize = 0;
    while (t < n) {
        if (pitch[t] == 0) {
            t += 1;
            continue;
        }
        const p = pitch[t];
        var start = t;
        for (t..@min(n, t + onsets.snap + 1)) |u| if (onsets.mask[u] and pitch[u] == p) {
            start = u;
            break;
        };
        var end = start;
        var sum = sal[start];
        var count: usize = 1;
        var gap: usize = 0;
        var u = start + 1;
        while (u < n) : (u += 1) {
            if (pitch[u] == p) {
                const attack = onsets.mask[u] or (pitch[u - 1] == p and sal[u] > SPLIT_RISE * sal[u - 1]);
                if (attack and u - start >= MIN_NOTE_FRAMES) break;
                end = u;
                sum += sal[u];
                count += 1;
                gap = 0;
            } else {
                gap += 1;
                if (gap > GAP_FRAMES) break;
            }
        }
        if (end - start + 1 >= MIN_NOTE_FRAMES) {
            try out.append(a, .{
                .start = @as(f32, @floatFromInt(start)) / fps,
                .end = @as(f32, @floatFromInt(end + 1)) / fps,
                .pitch = p,
                .velocity = @min(1.0, sum / @as(f32, @floatFromInt(count)) / ref),
            });
        }
        t = end + 1;
    }
}

fn smooth_track(pitch: []u8) void {
    if (pitch.len < 3) return;
    for (1..pitch.len - 1) |t| {
        if (pitch[t - 1] == pitch[t + 1] and pitch[t] != pitch[t - 1] and pitch[t - 1] != 0) pitch[t] = pitch[t - 1];
    }
}

const PitchedResult = struct { bass: []Note, melody: []Note, harmony: []Note };

fn transcribe_pitched(a: Allocator, mid_log: Spec, bass_log: Spec, rate: f32, fps: f32, bass_on: NoteOnsets, mid_on: NoteOnsets) !PitchedResult {
    const frames = @min(mid_log.frames, bass_log.frames);
    const mid_tab = PitchTable.build(mid_log.n, rate, mid_log.bins);
    const bass_tab = PitchTable.build(bass_log.n, rate, bass_log.bins);
    const bass_hi_idx = BASS_HI - MIDI_LO;

    const bass_pitch = try a.alloc(u8, frames);
    const bass_sal = try a.alloc(f32, frames);
    const voices = try a.alloc([MAX_VOICES]Voice, frames);
    const work = try a.alloc(f32, mid_log.bins);
    var sal: [PitchTable.NP]f32 = undefined;

    for (0..frames) |t| {
        const brow = bass_log.row(t);
        var bp: usize = 0;
        var bs: f32 = 0;
        for (0..bass_hi_idx + 1) |pi| {
            const s = bass_tab.salience(brow, pi, FUND_RATIO);
            if (s > bs) {
                bs = s;
                bp = pi;
            }
        }
        bass_pitch[t] = if (bs > 0) @intCast(MIDI_LO + bp) else 0;
        bass_sal[t] = bs;

        @memcpy(work, mid_log.row(t));
        if (bs > 0) mid_tab.cancel(work, bp);
        voices[t] = @splat(.{});
        var first: f32 = 0;
        for (0..MAX_VOICES) |v| {
            var best: f32 = 0;
            var arg: usize = 0;
            for (PITCHED_LO - MIDI_LO..PitchTable.NP) |pi| {
                sal[pi] = mid_tab.salience(work, pi, FUND_RATIO);
                if (sal[pi] > best) {
                    best = sal[pi];
                    arg = pi;
                }
            }
            if (best <= 0 or best < VOICE_REL * first) break;
            if (v == 0) first = best;
            voices[t][v] = .{ .pitch = @intCast(MIDI_LO + arg), .sal = best };
            mid_tab.cancel(work, arg);
        }
    }

    const bass_ref = try percentile(a, bass_sal, 0.9);
    for (bass_pitch, bass_sal) |*p, s| if (s < BASS_ABS * bass_ref) {
        p.* = 0;
    };

    const first_sal = try a.alloc(f32, frames);
    for (voices, first_sal) |v, *f| f.* = v[0].sal;
    const voice_ref = try percentile(a, first_sal, 0.9);
    const voice_min = VOICE_ABS * voice_ref;

    const mel_pitch = try a.alloc(u8, frames);
    const mel_sal = try a.alloc(f32, frames);
    for (voices, mel_pitch, mel_sal) |v, *p, *s| {
        const ok = v[0].sal >= voice_min;
        p.* = if (ok) v[0].pitch else 0;
        s.* = if (ok) v[0].sal else 0;
    }

    smooth_track(bass_pitch);
    smooth_track(mel_pitch);

    var bass: std.ArrayList(Note) = .empty;
    var melody: std.ArrayList(Note) = .empty;
    var harmony: std.ArrayList(Note) = .empty;
    try track_notes(a, &bass, bass_pitch, bass_sal, try percentile(a, bass_sal, 0.95), fps, bass_on);
    try track_notes(a, &melody, mel_pitch, mel_sal, try percentile(a, mel_sal, 0.95), fps, mid_on);

    const hp = try a.alloc(u8, frames);
    const hs = try a.alloc(f32, frames);
    for (PITCHED_LO..MIDI_HI + 1) |p| {
        var any = false;
        for (voices, hp, hs) |v, *op, *os| {
            op.* = 0;
            os.* = 0;
            for (v[1..]) |vc| if (vc.pitch == p and vc.sal >= voice_min) {
                op.* = @intCast(p);
                os.* = vc.sal;
                any = true;
            };
        }
        if (!any) continue;
        smooth_track(hp);
        try track_notes(a, &harmony, hp, hs, voice_ref, fps, mid_on);
    }
    std.mem.sort(Note, harmony.items, {}, less_note);
    return .{ .bass = bass.items, .melody = melody.items, .harmony = harmony.items };
}

// ---------------------------------------------------------------- chords / key

const NOTE_NAMES = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
const KEY_MAJOR = [12]f32{ 6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88 };
const KEY_MINOR = [12]f32{ 6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17 };

pub const Chord = struct { start: f32, end: f32, root: u8, minor: bool, none: bool };

fn frame_chroma(row: []const f32, n: usize, rate: f32, out: *[12]f32) void {
    out.* = @splat(0);
    for (row, 0..) |v, k| {
        const hz = @as(f32, @floatFromInt(k)) * rate / @as(f32, @floatFromInt(n));
        if (hz < 60 or hz > 2100) continue;
        const midi = 69 + 12 * @log2(hz / 440.0);
        const pc: usize = @intCast(@mod(@as(i32, @intFromFloat(@round(midi))), 12));
        out[pc] += v;
    }
}

fn pearson(x: [12]f32, y: [12]f32) f32 {
    var mx: f32 = 0;
    var my: f32 = 0;
    for (0..12) |i| {
        mx += x[i];
        my += y[i];
    }
    mx /= 12;
    my /= 12;
    var sxy: f32 = 0;
    var sxx: f32 = 0;
    var syy: f32 = 0;
    for (0..12) |i| {
        sxy += (x[i] - mx) * (y[i] - my);
        sxx += (x[i] - mx) * (x[i] - mx);
        syy += (y[i] - my) * (y[i] - my);
    }
    return sxy / @sqrt(sxx * syy + 1e-12);
}

fn estimate_chords(a: Allocator, mid_log: Spec, rate: f32, beats: []const usize, fps: f32, total: *[12]f32) ![]Chord {
    total.* = @splat(0);
    var raw: std.ArrayList(Chord) = .empty;
    var energies: std.ArrayList(f32) = .empty;
    var c: [12]f32 = undefined;
    var seg: [12]f32 = undefined;
    if (beats.len < 2) return raw.items;
    for (0..beats.len - 1) |b| {
        seg = @splat(0);
        for (beats[b]..beats[b + 1]) |t| {
            if (t >= mid_log.frames) break;
            frame_chroma(mid_log.row(t), mid_log.n, rate, &c);
            for (0..12) |i| seg[i] += c[i];
        }
        var energy: f32 = 0;
        for (0..12) |i| {
            total[i] += seg[i];
            energy += seg[i];
        }
        try energies.append(a, energy);
        var best: f32 = -2;
        var root: u8 = 0;
        var minor = false;
        for (0..12) |r| {
            for ([_]bool{ false, true }) |is_minor| {
                var tpl: [12]f32 = @splat(0);
                tpl[r] = 1;
                tpl[(r + @as(usize, if (is_minor) 3 else 4)) % 12] = 1;
                tpl[(r + 7) % 12] = 1;
                const s = pearson(seg, tpl);
                if (s > best) {
                    best = s;
                    root = @intCast(r);
                    minor = is_minor;
                }
            }
        }
        try raw.append(a, .{
            .start = @as(f32, @floatFromInt(beats[b])) / fps,
            .end = @as(f32, @floatFromInt(beats[b + 1])) / fps,
            .root = root,
            .minor = minor,
            .none = best < 0.3,
        });
    }
    const quiet = 0.1 * try percentile(a, energies.items, 0.5);
    for (raw.items, energies.items) |*ch, e| if (e < quiet) {
        ch.none = true;
    };

    const items = raw.items;
    if (items.len >= 3) {
        for (1..items.len - 1) |i| {
            if (same_chord(items[i - 1], items[i + 1]) and !same_chord(items[i], items[i - 1])) {
                items[i].root = items[i - 1].root;
                items[i].minor = items[i - 1].minor;
                items[i].none = items[i - 1].none;
            }
        }
    }
    var merged: std.ArrayList(Chord) = .empty;
    for (items) |ch| {
        if (merged.items.len > 0 and same_chord(merged.items[merged.items.len - 1], ch)) {
            merged.items[merged.items.len - 1].end = ch.end;
        } else try merged.append(a, ch);
    }
    return merged.items;
}

fn same_chord(x: Chord, y: Chord) bool {
    if (x.none or y.none) return x.none == y.none;
    return x.root == y.root and x.minor == y.minor;
}

fn estimate_key(total: [12]f32) struct { root: usize, minor: bool } {
    var best: f32 = -2;
    var root: usize = 0;
    var minor = false;
    for (0..12) |r| {
        var maj: [12]f32 = undefined;
        var min: [12]f32 = undefined;
        for (0..12) |i| {
            maj[(i + r) % 12] = KEY_MAJOR[i];
            min[(i + r) % 12] = KEY_MINOR[i];
        }
        const sm = pearson(total, maj);
        const sn = pearson(total, min);
        if (sm > best) {
            best = sm;
            root = r;
            minor = false;
        }
        if (sn > best) {
            best = sn;
            root = r;
            minor = true;
        }
    }
    return .{ .root = root, .minor = minor };
}

// ---------------------------------------------------------------- pipeline

fn to_mono(a: Allocator, audio: Audio) ![]f32 {
    const frames = audio.pcm.len / audio.channels;
    const mono = try a.alloc(f32, frames);
    for (mono, 0..) |*m, i| {
        var sum: f32 = 0;
        for (0..audio.channels) |c| sum += audio.pcm[i * audio.channels + c];
        m.* = sum / @as(f32, @floatFromInt(audio.channels));
    }
    return mono;
}

/// Low-pass (windowed sinc) then decimate by an integer factor.
fn downsample(a: Allocator, x: []const f32, factor: usize) ![]f32 {
    if (factor <= 1) return @constCast(x);
    const taps = 64 * factor + 1;
    const h = try a.alloc(f32, taps);
    const fc = 0.45 / @as(f32, @floatFromInt(factor));
    const mid: f32 = @floatFromInt(taps / 2);
    var hsum: f32 = 0;
    for (h, 0..) |*v, i| {
        const m = @as(f32, @floatFromInt(i)) - mid;
        const sinc = if (m == 0) 2 * fc else @sin(2 * std.math.pi * fc * m) / (std.math.pi * m);
        const win = 0.42 - 0.5 * @cos(2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(taps - 1))) +
            0.08 * @cos(4 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(taps - 1)));
        v.* = sinc * win;
        hsum += v.*;
    }
    for (h) |*v| v.* /= hsum;
    const out = try a.alloc(f32, x.len / factor);
    const half = taps / 2;
    for (out, 0..) |*o, j| {
        const c = j * factor;
        var acc: f32 = 0;
        for (h, 0..) |hv, k| {
            const idx = @as(isize, @intCast(c + k)) - @as(isize, @intCast(half));
            if (idx >= 0 and idx < x.len) acc += hv * x[@intCast(idx)];
        }
        o.* = acc;
    }
    return out;
}

pub const Analysis = struct {
    duration: f32,
    bpm: f32,
    beats: []f32,
    key_root: usize,
    key_minor: bool,
    chords: []Chord,
    drums: [DRUM_BANDS.len][]Hit,
    bass: []Note,
    melody: []Note,
    harmony: []Note,
};

pub fn analyze(a: Allocator, audio: Audio, prior: TempoPrior) !Analysis {
    const mono_full = try to_mono(a, audio);
    const factor: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(audio.rate)) / TARGET_RATE))));
    const x = try downsample(a, mono_full, factor);
    // The longest STFT needs several full windows; shorter clips have nothing to analyze.
    if (x.len < N_BASS * MIN_WINDOWS) return error.AudioTooShort;
    const rate = @as(f32, @floatFromInt(audio.rate)) / @as(f32, @floatFromInt(factor));
    const fps = rate / HOP;
    const duration = @as(f32, @floatFromInt(mono_full.len)) / @as(f32, @floatFromInt(audio.rate));

    status("spectrograms", .{});
    const s_onset = try stft(a, x, N_ONSET, rate / 2, rate);
    const s_mid = try stft(a, x, N_PITCH, PITCH_MAX_HZ, rate);
    const s_bass = try stft(a, x, N_BASS, BASS_MAX_HZ, rate);

    status("tempo + beats", .{});
    const env = try onset_envelope(a, try log_compress(a, s_onset));
    const tempo = estimate_tempo(env, fps, prior);
    const beat_frames = try track_beats(a, env, fps, tempo);
    const beats = try a.alloc(f32, beat_frames.len);
    for (beat_frames, beats) |b, *t| t.* = @as(f32, @floatFromInt(b)) / fps;
    const bpm = try beat_grid_bpm(a, beats) orelse tempo;

    status("harmonic/percussive separation", .{});
    const sep_onset = try hpss(a, s_onset);
    const sep_mid = try hpss(a, s_mid);
    const sep_bass = try hpss(a, s_bass);

    status("drums", .{});
    var drums: [DRUM_BANDS.len][]Hit = undefined;
    const perc_log = try log_compress(a, sep_onset.perc);
    for (DRUM_BANDS, 0..) |band, i| drums[i] = try detect_drums(a, perc_log, band, rate, fps);

    status("notes", .{});
    const onset_log = try log_compress(a, s_onset);
    const bass_on = NoteOnsets{
        .mask = try onset_mask(a, try band_onsets(a, onset_log, BASS_ONSET_LO, BASS_ONSET_HI, rate, NOTE_ONSET_DELTA), s_onset.frames),
        .snap = BASS_SNAP_FRAMES,
    };
    const mid_on = NoteOnsets{
        .mask = try onset_mask(a, try band_onsets(a, onset_log, MID_ONSET_LO, MID_ONSET_HI, rate, NOTE_ONSET_DELTA), s_onset.frames),
        .snap = MID_SNAP_FRAMES,
    };
    const mid_log = try log_compress(a, sep_mid.harm);
    const pitched = try transcribe_pitched(a, mid_log, try log_compress(a, sep_bass.harm), rate, fps, bass_on, mid_on);

    status("chords + key", .{});
    var total: [12]f32 = undefined;
    const chords = try estimate_chords(a, mid_log, rate, beat_frames, fps, &total);
    const key = estimate_key(total);

    return .{
        .duration = duration,
        .bpm = bpm,
        .beats = beats,
        .key_root = key.root,
        .key_minor = key.minor,
        .chords = chords,
        .drums = drums,
        .bass = pitched.bass,
        .melody = pitched.melody,
        .harmony = pitched.harmony,
    };
}

pub fn analyze_file(a: Allocator, io: std.Io, path: []const u8, bpm_hint: ?f32) !struct { audio: Audio, analysis: Analysis } {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30));
    const audio = try decode_mp3(a, bytes);
    return .{ .audio = audio, .analysis = try analyze(a, audio, tempo_prior(bpm_hint)) };
}

// ---------------------------------------------------------------- report

pub fn note_name(buf: []u8, midi: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ NOTE_NAMES[midi % 12], @as(i32, midi / 12) - 1 }) catch "?";
}

pub fn active_ratio(notes: []const Note, duration: f32) f32 {
    var sum: f32 = 0;
    for (notes) |n| sum += n.end - n.start;
    return if (duration > 0) @min(1.0, sum / duration) else 0;
}

const MIN_INSTRUMENT_EVENTS = 8;

pub fn write_report(io: std.Io, path: []const u8, source: []const u8, audio: Audio, r: Analysis) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    var nb1: [8]u8 = undefined;
    var nb2: [8]u8 = undefined;

    const Pitched = struct { name: []const u8, role: []const u8, notes: []const Note };
    const pitched = [_]Pitched{
        .{ .name = "bass", .role = "bass line (lowest pitched voice, E1-B2)", .notes = r.bass },
        .{ .name = "melody", .role = "lead line (strongest pitched voice: vocals / lead guitar / solo)", .notes = r.melody },
        .{ .name = "harmony", .role = "accompaniment (remaining voices: rhythm guitar / keys / pads)", .notes = r.harmony },
    };

    try w.print("# mp3notes transcription\n", .{});
    try w.print("source={s}\nsample_rate={d}\nchannels={d}\nbitrate_kbps={d}\n", .{ source, audio.rate, audio.channels, audio.bitrate_kbps });
    try w.print("duration={d:.3}\nbpm={d:.2}\nbeat_offset={d:.3}\nbeats={d}\n", .{
        r.duration, r.bpm, if (r.beats.len > 0) r.beats[0] else 0, r.beats.len,
    });
    try w.print("key={s} {s}\n", .{ NOTE_NAMES[r.key_root], if (r.key_minor) "minor" else "major" });

    try w.print("instruments=", .{});
    var first = true;
    for (DRUM_BANDS, r.drums) |band, hits| if (hits.len >= MIN_INSTRUMENT_EVENTS) {
        try w.print("{s}{s}", .{ if (first) "" else ",", band.name });
        first = false;
    };
    for (pitched) |p| if (p.notes.len >= MIN_INSTRUMENT_EVENTS) {
        try w.print("{s}{s}", .{ if (first) "" else ",", p.name });
        first = false;
    };
    try w.print("\n", .{});

    try w.print("\n[beats]\n# time (s)\n", .{});
    for (r.beats) |b| try w.print("beat={d:.3}\n", .{b});

    try w.print("\n[chords]\n# start,end,chord\n", .{});
    for (r.chords) |c| {
        if (c.none) {
            try w.print("chord={d:.3},{d:.3},N\n", .{ c.start, c.end });
        } else {
            try w.print("chord={d:.3},{d:.3},{s}{s}\n", .{ c.start, c.end, NOTE_NAMES[c.root], if (c.minor) "m" else "" });
        }
    }

    for (DRUM_BANDS, r.drums) |band, hits| {
        try w.print("\n[{s}]\ntype=percussion\nband_hz={d:.0}-{d:.0}\nhit_count={d}\n# time,velocity\n", .{ band.name, band.lo, band.hi, hits.len });
        for (hits) |h| try w.print("hit={d:.3},{d:.2}\n", .{ h.time, h.velocity });
    }

    for (pitched) |p| {
        try w.print("\n[{s}]\ntype=pitched\nrole={s}\nnote_count={d}\nactive_ratio={d:.3}\n", .{ p.name, p.role, p.notes.len, active_ratio(p.notes, r.duration) });
        if (p.notes.len > 0) {
            var lo: u8 = 255;
            var hi: u8 = 0;
            for (p.notes) |n| {
                lo = @min(lo, n.pitch);
                hi = @max(hi, n.pitch);
            }
            try w.print("range={s}-{s}\n", .{ note_name(&nb1, lo), note_name(&nb2, hi) });
        }
        try w.print("# start,end,midi,name,velocity\n", .{});
        for (p.notes) |n| {
            try w.print("note={d:.3},{d:.3},{d},{s},{d:.2}\n", .{ n.start, n.end, n.pitch, note_name(&nb1, n.pitch), n.velocity });
        }
    }
    try w.flush();
}

fn status(comptime what: []const u8, args: anytype) void {
    std.debug.print("  " ++ what ++ "...\n", args);
}

// ============================================================================
// Decoder tables (from minimp3)
// ============================================================================
const HALFRATE = [2][3][15]u8{
    .{ .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 }, .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 }, .{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128 } },
    .{ .{ 0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160 }, .{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192 }, .{ 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224 } },
};
const SCF_LONG = [8][23]u8{ .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0 }, .{ 12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2, 0 }, .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0 }, .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36, 0 }, .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0 }, .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158, 0 }, .{ 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192, 0 }, .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26, 0 } };
const SCF_SHORT = [8][40]u8{ .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0 }, .{ 8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2, 2, 2, 2, 2, 2, 26, 26, 26, 0 }, .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42, 42, 18, 18, 18, 0 }, .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44, 44, 44, 12, 12, 12, 0 }, .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0 }, .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22, 30, 30, 30, 56, 56, 56, 0 }, .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20, 26, 26, 26, 66, 66, 66, 0 }, .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34, 42, 42, 42, 12, 12, 12, 0 } };
const SCF_MIXED = [8][]const u8{ &.{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0 }, &.{ 12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2, 2, 2, 2, 2, 2, 26, 26, 26, 0 }, &.{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42, 42, 18, 18, 18, 0 }, &.{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44, 44, 44, 12, 12, 12, 0 }, &.{ 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0 }, &.{ 4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22, 30, 30, 30, 56, 56, 56, 0 }, &.{ 4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20, 26, 26, 26, 66, 66, 66, 0 }, &.{ 4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34, 42, 42, 42, 12, 12, 12, 0 } };
const SCF_PARTITIONS = [3][28]u8{ .{ 6, 5, 5, 5, 6, 5, 5, 5, 6, 5, 7, 3, 11, 10, 0, 0, 7, 7, 7, 0, 6, 6, 6, 3, 8, 8, 5, 0 }, .{ 8, 9, 6, 12, 6, 9, 9, 9, 6, 9, 12, 6, 15, 18, 0, 0, 6, 15, 12, 0, 6, 12, 9, 6, 6, 18, 9, 0 }, .{ 9, 9, 6, 12, 9, 9, 9, 9, 9, 9, 12, 6, 18, 18, 0, 0, 12, 12, 12, 0, 12, 9, 9, 6, 15, 12, 9, 0 } };
const SCFC_DECODE = [_]u8{ 0, 1, 2, 3, 12, 5, 6, 7, 9, 10, 11, 13, 14, 15, 18, 19 };
const MOD = [_]u8{ 5, 5, 4, 4, 5, 5, 4, 1, 4, 3, 1, 1, 5, 6, 6, 1, 4, 4, 4, 1, 4, 3, 1, 1 };
const PREAMP = [_]u8{ 1, 1, 1, 1, 2, 2, 3, 3, 3, 2 };
const EXPFRAC = [_]f32{ 9.31322575e-10, 7.83145814e-10, 6.58544508e-10, 5.53767716e-10 };
const POW43 = [_]f32{ 0, -1, -2.519842, -4.326749, -6.349604, -8.549880, -10.902724, -13.390518, -16.000000, -18.720754, -21.544347, -24.463781, -27.473142, -30.567351, -33.741992, -36.993181, 0, 1, 2.519842, 4.326749, 6.349604, 8.549880, 10.902724, 13.390518, 16.000000, 18.720754, 21.544347, 24.463781, 27.473142, 30.567351, 33.741992, 36.993181, 40.317474, 43.711787, 47.173345, 50.699631, 54.288352, 57.937408, 61.644865, 65.408941, 69.227979, 73.100443, 77.024898, 81.000000, 85.024491, 89.097188, 93.216975, 97.382800, 101.593667, 105.848633, 110.146801, 114.487321, 118.869381, 123.292209, 127.755065, 132.257246, 136.798076, 141.376907, 145.993119, 150.646117, 155.335327, 160.060199, 164.820202, 169.614826, 174.443577, 179.305980, 184.201575, 189.129918, 194.090580, 199.083145, 204.107210, 209.162385, 214.248292, 219.364564, 224.510845, 229.686789, 234.892058, 240.126328, 245.389280, 250.680604, 256.000000, 261.347174, 266.721841, 272.123723, 277.552547, 283.008049, 288.489971, 293.998060, 299.532071, 305.091761, 310.676898, 316.287249, 321.922592, 327.582707, 333.267377, 338.976394, 344.709550, 350.466646, 356.247482, 362.051866, 367.879608, 373.730522, 379.604427, 385.501143, 391.420496, 397.362314, 403.326427, 409.312672, 415.320884, 421.350905, 427.402579, 433.475750, 439.570269, 445.685987, 451.822757, 457.980436, 464.158883, 470.357960, 476.577530, 482.817459, 489.077615, 495.357868, 501.658090, 507.978156, 514.317941, 520.677324, 527.056184, 533.454404, 539.871867, 546.308458, 552.764065, 559.238575, 565.731879, 572.243870, 578.774440, 585.323483, 591.890898, 598.476581, 605.080431, 611.702349, 618.342238, 625.000000, 631.675540, 638.368763, 645.079578 };
const TABS = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 785, 785, 785, 785, 784, 784, 784, 784, 513, 513, 513, 513, 513, 513, 513, 513, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -255, 1313, 1298, 1282, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 290, 288, -255, 1313, 1298, 1282, 769, 769, 769, 769, 529, 529, 529, 529, 529, 529, 529, 529, 528, 528, 528, 528, 528, 528, 528, 528, 512, 512, 512, 512, 512, 512, 512, 512, 290, 288, -253, -318, -351, -367, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 819, 818, 547, 547, 275, 275, 275, 275, 561, 560, 515, 546, 289, 274, 288, 258, -254, -287, 1329, 1299, 1314, 1312, 1057, 1057, 1042, 1042, 1026, 1026, 784, 784, 784, 784, 529, 529, 529, 529, 529, 529, 529, 529, 769, 769, 769, 769, 768, 768, 768, 768, 563, 560, 306, 306, 291, 259, -252, -413, -477, -542, 1298, -575, 1041, 1041, 784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -383, -399, 1107, 1092, 1106, 1061, 849, 849, 789, 789, 1104, 1091, 773, 773, 1076, 1075, 341, 340, 325, 309, 834, 804, 577, 577, 532, 532, 516, 516, 832, 818, 803, 816, 561, 561, 531, 531, 515, 546, 289, 289, 288, 258, -252, -429, -493, -559, 1057, 1057, 1042, 1042, 529, 529, 529, 529, 529, 529, 529, 529, 784, 784, 784, 784, 769, 769, 769, 769, 512, 512, 512, 512, 512, 512, 512, 512, -382, 1077, -415, 1106, 1061, 1104, 849, 849, 789, 789, 1091, 1076, 1029, 1075, 834, 834, 597, 581, 340, 340, 339, 324, 804, 833, 532, 532, 832, 772, 818, 803, 817, 787, 816, 771, 290, 290, 290, 290, 288, 258, -253, -349, -414, -447, -463, 1329, 1299, -479, 1314, 1312, 1057, 1057, 1042, 1042, 1026, 1026, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 768, 768, 768, 768, -319, 851, 821, -335, 836, 850, 805, 849, 341, 340, 325, 336, 533, 533, 579, 579, 564, 564, 773, 832, 578, 548, 563, 516, 321, 276, 306, 291, 304, 259, -251, -572, -733, -830, -863, -879, 1041, 1041, 784, 784, 784, 784, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -511, -527, -543, 1396, 1351, 1381, 1366, 1395, 1335, 1380, -559, 1334, 1138, 1138, 1063, 1063, 1350, 1392, 1031, 1031, 1062, 1062, 1364, 1363, 1120, 1120, 1333, 1348, 881, 881, 881, 881, 375, 374, 359, 373, 343, 358, 341, 325, 791, 791, 1123, 1122, -703, 1105, 1045, -719, 865, 865, 790, 790, 774, 774, 1104, 1029, 338, 293, 323, 308, -799, -815, 833, 788, 772, 818, 803, 816, 322, 292, 307, 320, 561, 531, 515, 546, 289, 274, 288, 258, -251, -525, -605, -685, -765, -831, -846, 1298, 1057, 1057, 1312, 1282, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, 512, 512, 512, 512, 512, 512, 512, 512, 1399, 1398, 1383, 1367, 1382, 1396, 1351, -511, 1381, 1366, 1139, 1139, 1079, 1079, 1124, 1124, 1364, 1349, 1363, 1333, 882, 882, 882, 882, 807, 807, 807, 807, 1094, 1094, 1136, 1136, 373, 341, 535, 535, 881, 775, 867, 822, 774, -591, 324, 338, -671, 849, 550, 550, 866, 864, 609, 609, 293, 336, 534, 534, 789, 835, 773, -751, 834, 804, 308, 307, 833, 788, 832, 772, 562, 562, 547, 547, 305, 275, 560, 515, 290, 290, -252, -397, -477, -557, -622, -653, -719, -735, -750, 1329, 1299, 1314, 1057, 1057, 1042, 1042, 1312, 1282, 1024, 1024, 785, 785, 785, 785, 784, 784, 784, 784, 769, 769, 769, 769, -383, 1127, 1141, 1111, 1126, 1140, 1095, 1110, 869, 869, 883, 883, 1079, 1109, 882, 882, 375, 374, 807, 868, 838, 881, 791, -463, 867, 822, 368, 263, 852, 837, 836, -543, 610, 610, 550, 550, 352, 336, 534, 534, 865, 774, 851, 821, 850, 805, 593, 533, 579, 564, 773, 832, 578, 578, 548, 548, 577, 577, 307, 276, 306, 291, 516, 560, 259, 259, -250, -2107, -2507, -2764, -2909, -2974, -3007, -3023, 1041, 1041, 1040, 1040, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -767, -1052, -1213, -1277, -1358, -1405, -1469, -1535, -1550, -1582, -1614, -1647, -1662, -1694, -1726, -1759, -1774, -1807, -1822, -1854, -1886, 1565, -1919, -1935, -1951, -1967, 1731, 1730, 1580, 1717, -1983, 1729, 1564, -1999, 1548, -2015, -2031, 1715, 1595, -2047, 1714, -2063, 1610, -2079, 1609, -2095, 1323, 1323, 1457, 1457, 1307, 1307, 1712, 1547, 1641, 1700, 1699, 1594, 1685, 1625, 1442, 1442, 1322, 1322, -780, -973, -910, 1279, 1278, 1277, 1262, 1276, 1261, 1275, 1215, 1260, 1229, -959, 974, 974, 989, 989, -943, 735, 478, 478, 495, 463, 506, 414, -1039, 1003, 958, 1017, 927, 942, 987, 957, 431, 476, 1272, 1167, 1228, -1183, 1256, -1199, 895, 895, 941, 941, 1242, 1227, 1212, 1135, 1014, 1014, 490, 489, 503, 487, 910, 1013, 985, 925, 863, 894, 970, 955, 1012, 847, -1343, 831, 755, 755, 984, 909, 428, 366, 754, 559, -1391, 752, 486, 457, 924, 997, 698, 698, 983, 893, 740, 740, 908, 877, 739, 739, 667, 667, 953, 938, 497, 287, 271, 271, 683, 606, 590, 712, 726, 574, 302, 302, 738, 736, 481, 286, 526, 725, 605, 711, 636, 724, 696, 651, 589, 681, 666, 710, 364, 467, 573, 695, 466, 466, 301, 465, 379, 379, 709, 604, 665, 679, 316, 316, 634, 633, 436, 436, 464, 269, 424, 394, 452, 332, 438, 363, 347, 408, 393, 448, 331, 422, 362, 407, 392, 421, 346, 406, 391, 376, 375, 359, 1441, 1306, -2367, 1290, -2383, 1337, -2399, -2415, 1426, 1321, -2431, 1411, 1336, -2447, -2463, -2479, 1169, 1169, 1049, 1049, 1424, 1289, 1412, 1352, 1319, -2495, 1154, 1154, 1064, 1064, 1153, 1153, 416, 390, 360, 404, 403, 389, 344, 374, 373, 343, 358, 372, 327, 357, 342, 311, 356, 326, 1395, 1394, 1137, 1137, 1047, 1047, 1365, 1392, 1287, 1379, 1334, 1364, 1349, 1378, 1318, 1363, 792, 792, 792, 792, 1152, 1152, 1032, 1032, 1121, 1121, 1046, 1046, 1120, 1120, 1030, 1030, -2895, 1106, 1061, 1104, 849, 849, 789, 789, 1091, 1076, 1029, 1090, 1060, 1075, 833, 833, 309, 324, 532, 532, 832, 772, 818, 803, 561, 561, 531, 560, 515, 546, 289, 274, 288, 258, -250, -1179, -1579, -1836, -1996, -2124, -2253, -2333, -2413, -2477, -2542, -2574, -2607, -2622, -2655, 1314, 1313, 1298, 1312, 1282, 785, 785, 785, 785, 1040, 1040, 1025, 1025, 768, 768, 768, 768, -766, -798, -830, -862, -895, -911, -927, -943, -959, -975, -991, -1007, -1023, -1039, -1055, -1070, 1724, 1647, -1103, -1119, 1631, 1767, 1662, 1738, 1708, 1723, -1135, 1780, 1615, 1779, 1599, 1677, 1646, 1778, 1583, -1151, 1777, 1567, 1737, 1692, 1765, 1722, 1707, 1630, 1751, 1661, 1764, 1614, 1736, 1676, 1763, 1750, 1645, 1598, 1721, 1691, 1762, 1706, 1582, 1761, 1566, -1167, 1749, 1629, 767, 766, 751, 765, 494, 494, 735, 764, 719, 749, 734, 763, 447, 447, 748, 718, 477, 506, 431, 491, 446, 476, 461, 505, 415, 430, 475, 445, 504, 399, 460, 489, 414, 503, 383, 474, 429, 459, 502, 502, 746, 752, 488, 398, 501, 473, 413, 472, 486, 271, 480, 270, -1439, -1455, 1357, -1471, -1487, -1503, 1341, 1325, -1519, 1489, 1463, 1403, 1309, -1535, 1372, 1448, 1418, 1476, 1356, 1462, 1387, -1551, 1475, 1340, 1447, 1402, 1386, -1567, 1068, 1068, 1474, 1461, 455, 380, 468, 440, 395, 425, 410, 454, 364, 467, 466, 464, 453, 269, 409, 448, 268, 432, 1371, 1473, 1432, 1417, 1308, 1460, 1355, 1446, 1459, 1431, 1083, 1083, 1401, 1416, 1458, 1445, 1067, 1067, 1370, 1457, 1051, 1051, 1291, 1430, 1385, 1444, 1354, 1415, 1400, 1443, 1082, 1082, 1173, 1113, 1186, 1066, 1185, 1050, -1967, 1158, 1128, 1172, 1097, 1171, 1081, -1983, 1157, 1112, 416, 266, 375, 400, 1170, 1142, 1127, 1065, 793, 793, 1169, 1033, 1156, 1096, 1141, 1111, 1155, 1080, 1126, 1140, 898, 898, 808, 808, 897, 897, 792, 792, 1095, 1152, 1032, 1125, 1110, 1139, 1079, 1124, 882, 807, 838, 881, 853, 791, -2319, 867, 368, 263, 822, 852, 837, 866, 806, 865, -2399, 851, 352, 262, 534, 534, 821, 836, 594, 594, 549, 549, 593, 593, 533, 533, 848, 773, 579, 579, 564, 578, 548, 563, 276, 276, 577, 576, 306, 291, 516, 560, 305, 305, 275, 259, -251, -892, -2058, -2620, -2828, -2957, -3023, -3039, 1041, 1041, 1040, 1040, 769, 769, 769, 769, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, -511, -527, -543, -559, 1530, -575, -591, 1528, 1527, 1407, 1526, 1391, 1023, 1023, 1023, 1023, 1525, 1375, 1268, 1268, 1103, 1103, 1087, 1087, 1039, 1039, 1523, -604, 815, 815, 815, 815, 510, 495, 509, 479, 508, 463, 507, 447, 431, 505, 415, 399, -734, -782, 1262, -815, 1259, 1244, -831, 1258, 1228, -847, -863, 1196, -879, 1253, 987, 987, 748, -767, 493, 493, 462, 477, 414, 414, 686, 669, 478, 446, 461, 445, 474, 429, 487, 458, 412, 471, 1266, 1264, 1009, 1009, 799, 799, -1019, -1276, -1452, -1581, -1677, -1757, -1821, -1886, -1933, -1997, 1257, 1257, 1483, 1468, 1512, 1422, 1497, 1406, 1467, 1496, 1421, 1510, 1134, 1134, 1225, 1225, 1466, 1451, 1374, 1405, 1252, 1252, 1358, 1480, 1164, 1164, 1251, 1251, 1238, 1238, 1389, 1465, -1407, 1054, 1101, -1423, 1207, -1439, 830, 830, 1248, 1038, 1237, 1117, 1223, 1148, 1236, 1208, 411, 426, 395, 410, 379, 269, 1193, 1222, 1132, 1235, 1221, 1116, 976, 976, 1192, 1162, 1177, 1220, 1131, 1191, 963, 963, -1647, 961, 780, -1663, 558, 558, 994, 993, 437, 408, 393, 407, 829, 978, 813, 797, 947, -1743, 721, 721, 377, 392, 844, 950, 828, 890, 706, 706, 812, 859, 796, 960, 948, 843, 934, 874, 571, 571, -1919, 690, 555, 689, 421, 346, 539, 539, 944, 779, 918, 873, 932, 842, 903, 888, 570, 570, 931, 917, 674, 674, -2575, 1562, -2591, 1609, -2607, 1654, 1322, 1322, 1441, 1441, 1696, 1546, 1683, 1593, 1669, 1624, 1426, 1426, 1321, 1321, 1639, 1680, 1425, 1425, 1305, 1305, 1545, 1668, 1608, 1623, 1667, 1592, 1638, 1666, 1320, 1320, 1652, 1607, 1409, 1409, 1304, 1304, 1288, 1288, 1664, 1637, 1395, 1395, 1335, 1335, 1622, 1636, 1394, 1394, 1319, 1319, 1606, 1621, 1392, 1392, 1137, 1137, 1137, 1137, 345, 390, 360, 375, 404, 373, 1047, -2751, -2767, -2783, 1062, 1121, 1046, -2799, 1077, -2815, 1106, 1061, 789, 789, 1105, 1104, 263, 355, 310, 340, 325, 354, 352, 262, 339, 324, 1091, 1076, 1029, 1090, 1060, 1075, 833, 833, 788, 788, 1088, 1028, 818, 818, 803, 803, 561, 561, 531, 531, 816, 771, 546, 546, 289, 274, 288, 258, -253, -317, -381, -446, -478, -509, 1279, 1279, -811, -1179, -1451, -1756, -1900, -2028, -2189, -2253, -2333, -2414, -2445, -2511, -2526, 1313, 1298, -2559, 1041, 1041, 1040, 1040, 1025, 1025, 1024, 1024, 1022, 1007, 1021, 991, 1020, 975, 1019, 959, 687, 687, 1018, 1017, 671, 671, 655, 655, 1016, 1015, 639, 639, 758, 758, 623, 623, 757, 607, 756, 591, 755, 575, 754, 559, 543, 543, 1009, 783, -575, -621, -685, -749, 496, -590, 750, 749, 734, 748, 974, 989, 1003, 958, 988, 973, 1002, 942, 987, 957, 972, 1001, 926, 986, 941, 971, 956, 1000, 910, 985, 925, 999, 894, 970, -1071, -1087, -1102, 1390, -1135, 1436, 1509, 1451, 1374, -1151, 1405, 1358, 1480, 1420, -1167, 1507, 1494, 1389, 1342, 1465, 1435, 1450, 1326, 1505, 1310, 1493, 1373, 1479, 1404, 1492, 1464, 1419, 428, 443, 472, 397, 736, 526, 464, 464, 486, 457, 442, 471, 484, 482, 1357, 1449, 1434, 1478, 1388, 1491, 1341, 1490, 1325, 1489, 1463, 1403, 1309, 1477, 1372, 1448, 1418, 1433, 1476, 1356, 1462, 1387, -1439, 1475, 1340, 1447, 1402, 1474, 1324, 1461, 1371, 1473, 269, 448, 1432, 1417, 1308, 1460, -1711, 1459, -1727, 1441, 1099, 1099, 1446, 1386, 1431, 1401, -1743, 1289, 1083, 1083, 1160, 1160, 1458, 1445, 1067, 1067, 1370, 1457, 1307, 1430, 1129, 1129, 1098, 1098, 268, 432, 267, 416, 266, 400, -1887, 1144, 1187, 1082, 1173, 1113, 1186, 1066, 1050, 1158, 1128, 1143, 1172, 1097, 1171, 1081, 420, 391, 1157, 1112, 1170, 1142, 1127, 1065, 1169, 1049, 1156, 1096, 1141, 1111, 1155, 1080, 1126, 1154, 1064, 1153, 1140, 1095, 1048, -2159, 1125, 1110, 1137, -2175, 823, 823, 1139, 1138, 807, 807, 384, 264, 368, 263, 868, 838, 853, 791, 867, 822, 852, 837, 866, 806, 865, 790, -2319, 851, 821, 836, 352, 262, 850, 805, 849, -2399, 533, 533, 835, 820, 336, 261, 578, 548, 563, 577, 532, 532, 832, 772, 562, 562, 547, 547, 305, 275, 560, 515, 290, 290, 288, 258 };
const TAB32 = [_]u8{ 130, 162, 193, 209, 44, 28, 76, 140, 9, 9, 9, 9, 9, 9, 9, 9, 190, 254, 222, 238, 126, 94, 157, 157, 109, 61, 173, 205 };
const TAB33 = [_]u8{ 252, 236, 220, 204, 188, 172, 156, 140, 124, 108, 92, 76, 60, 44, 28, 12 };
const TABINDEX = [_]i16{ 0, 32, 64, 98, 0, 132, 180, 218, 292, 364, 426, 538, 648, 746, 0, 1126, 1460, 1460, 1460, 1460, 1460, 1460, 1460, 1460, 1842, 1842, 1842, 1842, 1842, 1842, 1842, 1842 };
const LINBITS = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 6, 8, 10, 13, 4, 5, 6, 7, 8, 9, 11, 13 };
const PAN = [_]f32{ 0, 1, 0.21132487, 0.78867513, 0.36602540, 0.63397460, 0.5, 0.5, 0.63397460, 0.36602540, 0.78867513, 0.21132487, 1, 0 };
const AA = [2][8]f32{ .{ 0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316 }, .{ 0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997 } };
const TWID9 = [_]f32{ 0.73727734, 0.79335334, 0.84339145, 0.88701083, 0.92387953, 0.95371695, 0.97629601, 0.99144486, 0.99904822, 0.67559021, 0.60876143, 0.53729961, 0.46174861, 0.38268343, 0.30070580, 0.21643961, 0.13052619, 0.04361938 };
const TWID3 = [_]f32{ 0.79335334, 0.92387953, 0.99144486, 0.60876143, 0.38268343, 0.13052619 };
const MDCT_WINDOW = [2][18]f32{ .{ 0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953, 0.88701083, 0.84339145, 0.79335334, 0.73727734, 0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343, 0.46174861, 0.53729961, 0.60876143, 0.67559021 }, .{ 1, 1, 1, 1, 1, 1, 0.99144486, 0.92387953, 0.79335334, 0, 0, 0, 0, 0, 0, 0.13052619, 0.38268343, 0.60876143 } };
const SEC = [_]f32{ 10.19000816, 0.50060302, 0.50241929, 3.40760851, 0.50547093, 0.52249861, 2.05778098, 0.51544732, 0.56694406, 1.48416460, 0.53104258, 0.64682180, 1.16943991, 0.55310392, 0.78815460, 0.97256821, 0.58293498, 1.06067765, 0.83934963, 0.62250412, 1.72244716, 0.74453628, 0.67480832, 5.10114861 };
const WIN = [_]f32{ -1, 26, -31, 208, 218, 401, -519, 2063, 2000, 4788, -5517, 7134, 5959, 35640, -39336, 74992, -1, 24, -35, 202, 222, 347, -581, 2080, 1952, 4425, -5879, 7640, 5288, 33791, -41176, 74856, -1, 21, -38, 196, 225, 294, -645, 2087, 1893, 4063, -6237, 8092, 4561, 31947, -43006, 74630, -1, 19, -41, 190, 227, 244, -711, 2085, 1822, 3705, -6589, 8492, 3776, 30112, -44821, 74313, -1, 17, -45, 183, 228, 197, -779, 2075, 1739, 3351, -6935, 8840, 2935, 28289, -46617, 73908, -1, 16, -49, 176, 228, 153, -848, 2057, 1644, 3004, -7271, 9139, 2037, 26482, -48390, 73415, -2, 14, -53, 169, 227, 111, -919, 2032, 1535, 2663, -7597, 9389, 1082, 24694, -50137, 72835, -2, 13, -58, 161, 224, 72, -991, 2001, 1414, 2330, -7910, 9592, 70, 22929, -51853, 72169, -2, 11, -63, 154, 221, 36, -1064, 1962, 1280, 2006, -8209, 9750, -998, 21189, -53534, 71420, -2, 10, -68, 147, 215, 2, -1137, 1919, 1131, 1692, -8491, 9863, -2122, 19478, -55178, 70590, -3, 9, -73, 139, 208, -29, -1210, 1870, 970, 1388, -8755, 9935, -3300, 17799, -56778, 69679, -3, 8, -79, 132, 200, -57, -1283, 1817, 794, 1095, -8998, 9966, -4533, 16155, -58333, 68692, -4, 7, -85, 125, 189, -83, -1356, 1759, 605, 814, -9219, 9959, -5818, 14548, -59838, 67629, -4, 7, -91, 117, 177, -106, -1428, 1698, 402, 545, -9416, 9916, -7154, 12980, -61289, 66494, -5, 6, -97, 111, 163, -127, -1498, 1634, 185, 288, -9585, 9838, -8540, 11455, -62684, 65290 };
