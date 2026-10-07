const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

pub const SAMPLE_RATE = 22050;
const HOP = 512;
const FPS: f32 = @as(f32, SAMPLE_RATE) / HOP;
const SHORT_N = 2048;
const SHORT_BINS = SHORT_N / 2 + 1;
const LONG_N = 8192;
const LONG_BINS = LONG_N / 2 + 1;
const HPSS_HALF = 8;
const LOG_GAIN = 1000.0;

const MIDI_LO = 24;
const MIDI_HI = 96;
const PITCHES = MIDI_HI - MIDI_LO + 1;
const HARMONICS = 6;
const HARMONIC_DECAY = 0.8;
const FUND_RATIO = 0.2;
const BASS_FUND_RATIO = 0.1;
const BASS_OCTAVE_RATIO = 0.5;
const BASS_LO = 28;
const BASS_HI = 47;
const MEL_LO = BASS_HI + 1;
const BASS_THR = 0.4;
const MEL_THR = 0.3;
const VOICE_RATIO = 0.5;
const MAX_VOICES = 3;
const MIN_NOTE_FRAMES = 4;
const GAP_FRAMES = 2;
const SPLIT_RISE = 1.4;
const BEAT_TIGHTNESS = 100.0;
const DRUM_PERC_RATIO = 1.0;

const DrumBand = struct { name: []const u8, midi: u8, lo: f32, hi: f32 };
const DRUM_BANDS = [_]DrumBand{
    .{ .name = "kick", .midi = 36, .lo = 30, .hi = 120 },
    .{ .name = "snare", .midi = 38, .lo = 1500, .hi = 4500 },
    .{ .name = "hihat", .midi = 42, .lo = 7000, .hi = 10500 },
};

pub const Note = struct {
    start: f32,
    end: f32,
    pitch: u8,
    velocity: f32,
};

pub const Kind = enum { percussion, pitched };

pub const Instrument = struct {
    name: []const u8,
    kind: Kind,
    energyShare: f32,
    activeRatio: f32,
    notes: []Note,
};

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    duration: f32,
    bpm: f32,
    beatOffset: f32,
    beatCount: usize,
    instruments: []Instrument,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
    }
};

/// Decodes any raylib-supported audio file (mp3/wav/ogg/flac) and analyzes it.
pub fn analyzeFile(gpa: Allocator, path: [:0]const u8) !Analysis {
    var wave = try rl.loadWave(path);
    defer rl.unloadWave(wave);
    rl.waveFormat(&wave, SAMPLE_RATE, 32, 1);
    const samples = rl.loadWaveSamples(wave);
    defer rl.unloadWaveSamples(samples);
    return analyze(gpa, samples);
}

/// `samples` must be mono at SAMPLE_RATE.
pub fn analyze(gpa: Allocator, samples: []const f32) !Analysis {
    var result = Analysis{
        .arena = .init(gpa),
        .duration = @as(f32, @floatFromInt(samples.len)) / SAMPLE_RATE,
        .bpm = 0,
        .beatOffset = 0,
        .beatCount = 0,
        .instruments = &.{},
    };
    errdefer result.arena.deinit();
    const ra = result.arena.allocator();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const frames = samples.len / HOP + 1;

    // Short STFT + harmonic/percussive separation (median filtering)
    const mag = try sa.alloc(f32, frames * SHORT_BINS);
    var shortFft = try Fft.init(sa, SHORT_N);
    for (0..frames) |f| shortFft.magnitudes(samples, f * HOP, mag[f * SHORT_BINS ..][0..SHORT_BINS]);

    const harm = try sa.alloc(f32, frames * SHORT_BINS);
    var win: [2 * HPSS_HALF + 1]f32 = undefined;
    for (0..SHORT_BINS) |k| {
        for (0..frames) |f| {
            const hi = @min(frames, f + HPSS_HALF + 1);
            var n: usize = 0;
            for (f -| HPSS_HALF..hi) |g| {
                win[n] = mag[g * SHORT_BINS + k];
                n += 1;
            }
            harm[f * SHORT_BINS + k] = median(win[0..n]);
        }
    }

    const fullEnv = try sa.alloc(f32, frames);
    const harmEnv = try sa.alloc(f32, frames);
    var drumEnv: [DRUM_BANDS.len][]f32 = undefined;
    var drumBins: [DRUM_BANDS.len][2]usize = undefined;
    var drumPerc: [DRUM_BANDS.len][]f32 = undefined;
    var drumHarm: [DRUM_BANDS.len][]f32 = undefined;
    for (DRUM_BANDS, 0..) |band, d| {
        drumEnv[d] = try sa.alloc(f32, frames);
        drumPerc[d] = try sa.alloc(f32, frames);
        drumHarm[d] = try sa.alloc(f32, frames);
        drumBins[d] = .{ hzToBin(band.lo, SHORT_N), @min(SHORT_BINS, hzToBin(band.hi, SHORT_N) + 1) };
    }
    var prev = try sa.alloc(f32, 3 * SHORT_BINS);
    var cur = try sa.alloc(f32, 3 * SHORT_BINS);
    @memset(prev, 0);
    const hPow = try sa.alloc(f32, SHORT_BINS);
    const pPow = try sa.alloc(f32, SHORT_BINS);

    var totalPow: f64 = 0;
    var percPow: f64 = 0;
    var bassPow: f64 = 0;
    var melPow: f64 = 0;
    const bassBin = hzToBin(250, SHORT_N);
    const melBin = hzToBin(5000, SHORT_N);

    for (0..frames) |f| {
        const row = mag[f * SHORT_BINS ..][0..SHORT_BINS];
        for (0..SHORT_BINS) |k| {
            const hi = @min(SHORT_BINS, k + HPSS_HALF + 1);
            const lo = k -| HPSS_HALF;
            @memcpy(win[0 .. hi - lo], row[lo..hi]);
            const p = median(win[0 .. hi - lo]);
            const h = harm[f * SHORT_BINS + k];
            const den = h * h + p * p + 1e-12;
            const m = row[k];
            const hm = m * h * h / den;
            const pm = m * p * p / den;
            totalPow += m * m;
            percPow += pm * pm;
            if (k < bassBin) bassPow += hm * hm else if (k < melBin) melPow += hm * hm;
            cur[k] = std.math.log1p(LOG_GAIN * m);
            cur[SHORT_BINS + k] = std.math.log1p(LOG_GAIN * hm);
            cur[2 * SHORT_BINS + k] = std.math.log1p(LOG_GAIN * pm);
            hPow[k] = hm * hm;
            pPow[k] = pm * pm;
        }
        fullEnv[f] = if (f == 0) 0 else flux(cur[0..SHORT_BINS], prev[0..SHORT_BINS]);
        harmEnv[f] = if (f == 0) 0 else flux(cur[SHORT_BINS .. 2 * SHORT_BINS], prev[SHORT_BINS .. 2 * SHORT_BINS]);
        for (0..DRUM_BANDS.len) |d| {
            const r = drumBins[d];
            drumPerc[d][f] = sum(pPow[r[0]..r[1]]);
            drumHarm[d][f] = sum(hPow[r[0]..r[1]]);
            drumEnv[d][f] = if (f == 0) 0 else flux(cur[2 * SHORT_BINS + r[0] .. 2 * SHORT_BINS + r[1]], prev[2 * SHORT_BINS + r[0] .. 2 * SHORT_BINS + r[1]]);
        }
        std.mem.swap([]f32, &prev, &cur);
    }
    const totalPowSafe = @max(totalPow, 1e-12);

    // Tempo + beats
    result.bpm = estimateTempo(fullEnv);
    const beats = try trackBeats(sa, fullEnv, result.bpm);
    result.beatCount = beats.len;
    if (beats.len > 0) result.beatOffset = @as(f32, @floatFromInt(beats[0])) / FPS;

    // Drums from percussive band onsets
    var drumNotes: std.ArrayList(Note) = .empty;
    var refs: [DRUM_BANDS.len]f32 = undefined;
    var maxRef: f32 = 0;
    for (0..DRUM_BANDS.len) |d| {
        refs[d] = try percentile(sa, drumEnv[d], 0.99);
        maxRef = @max(maxRef, refs[d]);
    }
    const drumCover = try sa.alloc(bool, frames);
    @memset(drumCover, false);
    for (DRUM_BANDS, 0..) |band, d| {
        if (refs[d] <= 0 or refs[d] < 0.05 * maxRef) continue;
        const peaks = try pickPeaks(sa, drumEnv[d], refs[d], 0.1);
        for (peaks) |p| {
            const hit = @min(frames, p + 3);
            if (sum(drumPerc[d][p..hit]) < DRUM_PERC_RATIO * sum(drumHarm[d][p..hit])) continue;
            const t = @as(f32, @floatFromInt(p)) / FPS;
            try drumNotes.append(ra, .{ .start = t, .end = t + 0.1, .pitch = band.midi, .velocity = @min(1, drumEnv[d][p] / refs[d]) });
            const coverEnd = @min(frames, p + @as(usize, @intFromFloat(0.5 * FPS)));
            @memset(drumCover[p..coverEnd], true);
        }
    }
    std.mem.sort(Note, drumNotes.items, {}, noteLess);

    // Pitch salience from long STFT (harmonic summation)
    const sal = try sa.alloc(f32, frames * PITCHES);
    var longFft = try Fft.init(sa, LONG_N);
    const lmag = try sa.alloc(f32, LONG_BINS);
    var ranges: [PITCHES][HARMONICS][2]usize = undefined;
    for (0..PITCHES) |p| {
        const f0 = midiToHz(@intCast(p + MIDI_LO));
        for (0..HARMONICS) |h| {
            const fh = f0 * @as(f32, @floatFromInt(h + 1));
            if (fh > SAMPLE_RATE * 0.45) {
                ranges[p][h] = .{ 1, 0 };
                continue;
            }
            ranges[p][h] = .{ hzToBin(fh * 0.9715, LONG_N), hzToBin(fh * 1.0293, LONG_N) };
        }
    }
    var sorted: [PITCHES]f32 = undefined;
    for (0..frames) |f| {
        longFft.magnitudes(samples, f * HOP, lmag);
        const row = sal[f * PITCHES ..][0..PITCHES];
        for (0..PITCHES) |p| {
            var s: f32 = 0;
            var a1: f32 = 0;
            var amax: f32 = 0;
            var w: f32 = 1;
            for (0..HARMONICS) |h| {
                const r = ranges[p][h];
                if (r[0] > r[1]) break;
                var a: f32 = 0;
                for (r[0]..r[1] + 1) |k| a = @max(a, lmag[k]);
                s += w * a;
                if (h == 0) a1 = a;
                amax = @max(amax, a);
                w *= HARMONIC_DECAY;
            }
            const fund: f32 = if (p + MIDI_LO <= BASS_HI) BASS_FUND_RATIO else FUND_RATIO;
            row[p] = if (a1 >= fund * amax) s else 0;
        }
        sorted = row.*;
        const floor = median(&sorted);
        for (row) |*v| v.* = @max(0, v.* - floor);
    }

    const bassRef = try rangeMaxPercentile(sa, sal, frames, BASS_LO, BASS_HI, 0.95);
    const melRef = try rangeMaxPercentile(sa, sal, frames, MEL_LO, MIDI_HI, 0.95);

    // Voice selection: monophonic bass, up to MAX_VOICES melody notes per frame
    const bassAct = try sa.alloc(f32, frames * PITCHES);
    const melAct = try sa.alloc(f32, frames * PITCHES);
    @memset(bassAct, 0);
    @memset(melAct, 0);
    for (0..frames) |f| {
        const row = sal[f * PITCHES ..][0..PITCHES];
        var b = argmax(row, BASS_LO - MIDI_LO, BASS_HI - MIDI_LO);
        if (b >= 12 + BASS_LO - MIDI_LO and row[b - 12] >= BASS_OCTAVE_RATIO * row[b]) b -= 12;
        if (bassRef > 0 and row[b] >= BASS_THR * bassRef) {
            bassAct[f * PITCHES + b] = row[b];
            for ([_]usize{ 12, 19, 24, 28, 31 }) |iv| {
                const q = b + iv;
                if (q >= MEL_LO - MIDI_LO and q < PITCHES and row[q] < row[b]) row[q] = 0;
            }
        }
        var first: f32 = 0;
        for (0..MAX_VOICES) |v| {
            const m = argmax(row, MEL_LO - MIDI_LO, PITCHES - 1);
            const s = row[m];
            if (melRef <= 0 or s < MEL_THR * melRef or s < VOICE_RATIO * first) break;
            if (v == 0) first = s;
            melAct[f * PITCHES + m] = s;
            row[m] = 0;
            if (m > 0) row[m - 1] = 0;
            for ([_]usize{ 1, 12, 19, 24 }) |iv| {
                if (m + iv < PITCHES) row[m + iv] = 0;
            }
        }
    }

    const onsets = try pickPeaks(sa, harmEnv, try percentile(sa, harmEnv, 0.99), 0.07);
    var bassNotes: std.ArrayList(Note) = .empty;
    var melNotes: std.ArrayList(Note) = .empty;
    try extractNotes(ra, &bassNotes, bassAct, frames, BASS_LO, BASS_HI, bassRef, onsets);
    try extractNotes(ra, &melNotes, melAct, frames, MEL_LO, MIDI_HI, melRef, onsets);

    const instruments = try ra.alloc(Instrument, 3);
    instruments[0] = .{
        .name = "drums",
        .kind = .percussion,
        .energyShare = @floatCast(percPow / totalPowSafe),
        .activeRatio = ratioTrue(drumCover),
        .notes = drumNotes.items,
    };
    instruments[1] = .{
        .name = "bass",
        .kind = .pitched,
        .energyShare = @floatCast(bassPow / totalPowSafe),
        .activeRatio = activeRatio(bassAct, frames),
        .notes = bassNotes.items,
    };
    instruments[2] = .{
        .name = "melody",
        .kind = .pitched,
        .energyShare = @floatCast(melPow / totalPowSafe),
        .activeRatio = activeRatio(melAct, frames),
        .notes = melNotes.items,
    };
    result.instruments = instruments;
    return result;
}

pub fn writeReport(io: std.Io, a: *const Analysis, source: []const u8, outPath: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, outPath, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.print("source={s}\nduration={d:.2}\nbpm={d:.2}\nbps={d:.4}\nbeat_offset={d:.3}\nbeats={d}\ninstruments={d}\n", .{
        source, a.duration, a.bpm, a.bpm / 60.0, a.beatOffset, a.beatCount, a.instruments.len,
    });
    var nameBuf: [8]u8 = undefined;
    var nameBuf2: [8]u8 = undefined;
    for (a.instruments) |inst| {
        try w.print("\n[{s}]\ntype={s}\nenergy_share={d:.3}\nactive_ratio={d:.3}\nnote_count={d}\n", .{
            inst.name, @tagName(inst.kind), inst.energyShare, inst.activeRatio, inst.notes.len,
        });
        if (inst.kind == .pitched and inst.notes.len > 0) {
            var lo: u8 = 255;
            var hi: u8 = 0;
            for (inst.notes) |n| {
                lo = @min(lo, n.pitch);
                hi = @max(hi, n.pitch);
            }
            try w.print("range={s}-{s}\n", .{ noteName(&nameBuf, inst.kind, lo), noteName(&nameBuf2, inst.kind, hi) });
        }
        for (inst.notes) |n| {
            try w.print("note={d:.3},{d:.3},{d},{s},{d:.2}\n", .{ n.start, n.end, n.pitch, noteName(&nameBuf, inst.kind, n.pitch), n.velocity });
        }
    }
    try w.flush();
}

pub fn noteName(buf: []u8, kind: Kind, midi: u8) []const u8 {
    if (kind == .percussion) {
        for (DRUM_BANDS) |band| if (band.midi == midi) return band.name;
        return "drum";
    }
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[midi % 12], @as(i32, midi / 12) - 1 }) catch "?";
}

const Fft = struct {
    n: usize,
    bits: u5,
    cos: []f32,
    sin: []f32,
    window: []f32,
    re: []f32,
    im: []f32,

    fn init(a: Allocator, n: usize) !Fft {
        const self = Fft{
            .n = n,
            .bits = @intCast(std.math.log2_int(usize, n)),
            .cos = try a.alloc(f32, n / 2),
            .sin = try a.alloc(f32, n / 2),
            .window = try a.alloc(f32, n),
            .re = try a.alloc(f32, n),
            .im = try a.alloc(f32, n),
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

    /// Hann-windowed frame centered on `center`; `out` gets n/2+1 magnitudes scaled to sine amplitude.
    fn magnitudes(self: *Fft, samples: []const f32, center: usize, out: []f32) void {
        const n = self.n;
        const start = @as(isize, @intCast(center)) - @as(isize, @intCast(n / 2));
        for (0..n) |i| {
            const idx = start + @as(isize, @intCast(i));
            const x = if (idx >= 0 and idx < samples.len) samples[@intCast(idx)] else 0;
            const r = @bitReverse(@as(u32, @intCast(i))) >> (@as(u5, 31) - self.bits + 1);
            self.re[r] = x * self.window[i];
            self.im[r] = 0;
        }
        var size: usize = 2;
        while (size <= n) : (size *= 2) {
            const half = size / 2;
            const step = n / size;
            var s: usize = 0;
            while (s < n) : (s += size) {
                for (0..half) |j| {
                    const wr = self.cos[j * step];
                    const wi = -self.sin[j * step];
                    const a = s + j;
                    const b = a + half;
                    const tr = self.re[b] * wr - self.im[b] * wi;
                    const ti = self.re[b] * wi + self.im[b] * wr;
                    self.re[b] = self.re[a] - tr;
                    self.im[b] = self.im[a] - ti;
                    self.re[a] += tr;
                    self.im[a] += ti;
                }
            }
        }
        const scale = 4.0 / @as(f32, @floatFromInt(n));
        for (out, 0..) |*o, k| o.* = @sqrt(self.re[k] * self.re[k] + self.im[k] * self.im[k]) * scale;
    }
};

fn midiToHz(m: u8) f32 {
    return 440.0 * std.math.pow(f32, 2, (@as(f32, @floatFromInt(m)) - 69) / 12);
}

fn hzToBin(hz: f32, n: usize) usize {
    return @intFromFloat(@round(hz * @as(f32, @floatFromInt(n)) / SAMPLE_RATE));
}

fn median(buf: []f32) f32 {
    for (1..buf.len) |i| {
        const v = buf[i];
        var j = i;
        while (j > 0 and buf[j - 1] > v) : (j -= 1) buf[j] = buf[j - 1];
        buf[j] = v;
    }
    return buf[buf.len / 2];
}

fn flux(cur: []const f32, prev: []const f32) f32 {
    var s: f32 = 0;
    for (cur, prev) |c, p| s += @max(0, c - p);
    return s;
}

fn sum(v: []const f32) f32 {
    var s: f32 = 0;
    for (v) |x| s += x;
    return s;
}

fn percentile(a: Allocator, values: []const f32, q: f32) !f32 {
    if (values.len == 0) return 0;
    const tmp = try a.dupe(f32, values);
    defer a.free(tmp);
    std.mem.sort(f32, tmp, {}, std.sort.asc(f32));
    return tmp[@intFromFloat(q * @as(f32, @floatFromInt(tmp.len - 1)))];
}

fn rangeMaxPercentile(a: Allocator, sal: []const f32, frames: usize, lo: usize, hi: usize, q: f32) !f32 {
    const maxes = try a.alloc(f32, frames);
    for (0..frames) |f| {
        const row = sal[f * PITCHES ..][0..PITCHES];
        maxes[f] = row[argmax(row, lo - MIDI_LO, hi - MIDI_LO)];
    }
    return percentile(a, maxes, q);
}

fn argmax(row: []const f32, lo: usize, hi: usize) usize {
    var best = lo;
    for (lo..hi + 1) |i| {
        if (row[i] > row[best]) best = i;
    }
    return best;
}

fn noteLess(_: void, a: Note, b: Note) bool {
    return if (a.start == b.start) a.pitch < b.pitch else a.start < b.start;
}

fn ratioTrue(v: []const bool) f32 {
    var n: usize = 0;
    for (v) |b| n += @intFromBool(b);
    return @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(@max(1, v.len)));
}

fn activeRatio(act: []const f32, frames: usize) f32 {
    var n: usize = 0;
    for (0..frames) |f| {
        for (act[f * PITCHES ..][0..PITCHES]) |v| {
            if (v > 0) {
                n += 1;
                break;
            }
        }
    }
    return @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(@max(1, frames)));
}

/// Normalized local-maximum peak picking (librosa-style onset_detect).
fn pickPeaks(a: Allocator, env: []const f32, ref: f32, delta: f32) ![]usize {
    var peaks: std.ArrayList(usize) = .empty;
    if (ref <= 0) return peaks.items;
    var last: ?usize = null;
    for (0..env.len) |f| {
        const v = env[f] / ref;
        var isMax = true;
        for (f -| 3..@min(env.len, f + 4)) |g| {
            if (env[g] / ref > v) isMax = false;
        }
        if (!isMax) continue;
        const lo = f -| 10;
        const hi = @min(env.len, f + 6);
        var avg: f32 = 0;
        for (lo..hi) |g| avg += env[g] / ref;
        avg /= @floatFromInt(hi - lo);
        if (v < avg + delta) continue;
        if (last) |l| if (f - l <= 3) continue;
        try peaks.append(a, f);
        last = f;
    }
    return peaks.items;
}

/// Autocorrelation of the onset envelope weighted toward 120 BPM.
fn estimateTempo(env: []const f32) f32 {
    const lagMin: usize = @intFromFloat(@floor(FPS * 60 / 240));
    const lagMax: usize = @intFromFloat(@ceil(FPS * 60 / 40));
    if (env.len <= lagMax * 2) return 120;
    var mean: f32 = 0;
    for (env) |v| mean += v;
    mean /= @floatFromInt(env.len);

    var scores: [128]f32 = @splat(0);
    var best = lagMin;
    for (lagMin..lagMax + 1) |lag| {
        var s: f32 = 0;
        for (0..env.len - lag) |t| s += (env[t] - mean) * (env[t + lag] - mean);
        s /= @floatFromInt(env.len - lag);
        const bpm = 60 * FPS / @as(f32, @floatFromInt(lag));
        const oct = std.math.log2(bpm / 120);
        scores[lag] = s * @exp(-0.5 * oct * oct);
        if (scores[lag] > scores[best]) best = lag;
    }
    var lag: f32 = @floatFromInt(best);
    if (best > lagMin and best < lagMax) {
        const l = scores[best - 1];
        const c = scores[best];
        const r = scores[best + 1];
        const den = l - 2 * c + r;
        if (den < 0) lag += 0.5 * (l - r) / den;
    }
    return 60 * FPS / lag;
}

/// Dynamic-programming beat tracker (Ellis 2007).
fn trackBeats(a: Allocator, env: []const f32, bpm: f32) ![]usize {
    const period = 60 * FPS / bpm;
    var mean: f32 = 0;
    for (env) |v| mean += v;
    mean /= @floatFromInt(@max(1, env.len));
    var variance: f32 = 0;
    for (env) |v| variance += (v - mean) * (v - mean);
    const sd = @max(1e-6, @sqrt(variance / @as(f32, @floatFromInt(@max(1, env.len)))));

    const score = try a.alloc(f32, env.len);
    const back = try a.alloc(isize, env.len);
    const maxBack: usize = @intFromFloat(@round(2 * period));
    const minBack: usize = @max(1, @as(usize, @intFromFloat(@round(period / 2))));
    for (0..env.len) |t| {
        var bestVal: f32 = -std.math.inf(f32);
        var bestIdx: isize = -1;
        if (t >= minBack) {
            for (t -| maxBack..t - minBack + 1) |tau| {
                const r = @log(@as(f32, @floatFromInt(t - tau)) / period);
                const v = score[tau] - BEAT_TIGHTNESS * r * r;
                if (v > bestVal) {
                    bestVal = v;
                    bestIdx = @intCast(tau);
                }
            }
        }
        if (bestVal > 0) {
            score[t] = env[t] / sd + bestVal;
            back[t] = bestIdx;
        } else {
            score[t] = env[t] / sd;
            back[t] = -1;
        }
    }

    var beats: std.ArrayList(usize) = .empty;
    if (env.len == 0) return beats.items;
    const tail = env.len -| @as(usize, @intFromFloat(@ceil(period)));
    var t: isize = @intCast(argmax(score, tail, env.len - 1));
    while (t >= 0) : (t = back[@intCast(t)]) try beats.append(a, @intCast(t));
    std.mem.reverse(usize, beats.items);

    // Drop beats placed in leading silence
    var envMax: f32 = 0;
    for (env) |v| envMax = @max(envMax, v);
    var firstLoud: usize = 0;
    while (firstLoud < env.len and env[firstLoud] < 0.1 * envMax) firstLoud += 1;
    var skip: usize = 0;
    while (skip < beats.items.len and beats.items[skip] + 2 < firstLoud) skip += 1;
    return beats.items[skip..];
}

fn extractNotes(a: Allocator, list: *std.ArrayList(Note), act: []const f32, frames: usize, lo: u8, hi: u8, ref: f32, onsets: []const usize) !void {
    const refSafe = @max(ref, 1e-9);
    for (lo..hi + 1) |pitch| {
        const p = pitch - MIDI_LO;
        var f: usize = 0;
        while (f < frames) {
            if (act[f * PITCHES + p] == 0) {
                f += 1;
                continue;
            }
            const start = f;
            var end = f;
            var gap: usize = 0;
            var g = f;
            while (g < frames) : (g += 1) {
                if (act[g * PITCHES + p] > 0) {
                    end = g;
                    gap = 0;
                } else {
                    gap += 1;
                    if (gap > GAP_FRAMES) break;
                }
            }

            // Split repeated notes at onsets where this pitch's salience jumps
            var segStart = start;
            var oi = lowerBound(onsets, start + MIN_NOTE_FRAMES);
            while (oi < onsets.len and onsets[oi] + MIN_NOTE_FRAMES <= end + 1) : (oi += 1) {
                const o = onsets[oi];
                if (o < segStart + MIN_NOTE_FRAMES) continue;
                var before: f32 = std.math.inf(f32);
                for (o - 3..o) |k| before = @min(before, act[k * PITCHES + p]);
                var after: f32 = 0;
                for (o..@min(frames, o + 4)) |k| after = @max(after, act[k * PITCHES + p]);
                if (after > SPLIT_RISE * before) {
                    try emitNote(a, list, act, p, segStart, o - 1, refSafe);
                    segStart = o;
                }
            }
            try emitNote(a, list, act, p, segStart, end, refSafe);
            f = end + 1;
        }
    }
    std.mem.sort(Note, list.items, {}, noteLess);
}

fn emitNote(a: Allocator, list: *std.ArrayList(Note), act: []const f32, p: usize, s: usize, e: usize, ref: f32) !void {
    if (e + 1 - s < MIN_NOTE_FRAMES) return;
    var peak: f32 = 0;
    for (s..e + 1) |k| peak = @max(peak, act[k * PITCHES + p]);
    try list.append(a, .{
        .start = @as(f32, @floatFromInt(s)) / FPS,
        .end = @as(f32, @floatFromInt(e + 1)) / FPS,
        .pitch = @intCast(p + MIDI_LO),
        .velocity = @min(1, peak / ref),
    });
}

fn lowerBound(items: []const usize, x: usize) usize {
    var lo: usize = 0;
    var hi = items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (items[mid] < x) lo = mid + 1 else hi = mid;
    }
    return lo;
}
