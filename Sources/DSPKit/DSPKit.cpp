#include "DSPKit.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

#include "signalsmith-stretch.h"

// MARK: - Pitch shifter (Signalsmith Stretch)

struct DSPPitch {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    std::vector<float> inL, inR;
    int maxFrames;
    std::atomic<float> target{0};
    std::atomic<float> tonalityHz{8000};
    std::atomic<int> formants{0};
    std::atomic<float> formantBaseHz{200};
    std::atomic<int> qualityVersion{1};
    int appliedQuality = 0;
    float current = 0;
    double sampleRate = 48000;
    bool active = false;
};

DSPPitch *dsp_pitch_create(double sampleRate, int maxFrames) {
    auto *p = new DSPPitch();
    p->maxFrames = std::max(64, maxFrames);
    p->sampleRate = sampleRate;
    p->stretch.presetDefault(2, (float)sampleRate);
    p->inL.assign(p->maxFrames, 0);
    p->inR.assign(p->maxFrames, 0);
    return p;
}

void dsp_pitch_destroy(DSPPitch *p) { delete p; }
void dsp_pitch_set_semitones(DSPPitch *p, float s) { p->target.store(s); }

void dsp_pitch_set_quality(DSPPitch *p, float tonalityHz, int formantCompensation, float formantBaseHz) {
    p->tonalityHz.store(std::max(0.0f, tonalityHz));
    p->formants.store(formantCompensation ? 1 : 0);
    p->formantBaseHz.store(std::max(0.0f, formantBaseHz));
    p->qualityVersion.fetch_add(1);
}
float dsp_pitch_get_semitones(const DSPPitch *p) { return p->target.load(); }

int dsp_pitch_latency(const DSPPitch *p) {
    return p->active ? (int)(p->stretch.inputLatency() + p->stretch.outputLatency()) : 0;
}

void dsp_pitch_process(DSPPitch *p, float *left, float *right, int frames) {
    float t = p->target.load();
    if (std::fabs(t) < 0.01f) { // bypass: exact passthrough, no latency
        if (p->active) { p->active = false; p->stretch.reset(); }
        return;
    }
    if (!p->active) { p->active = true; p->stretch.reset(); }
    int qv = p->qualityVersion.load();
    if (t != p->current || qv != p->appliedQuality) {
        p->current = t;
        p->appliedQuality = qv;
        float tonality = p->tonalityHz.load();
        p->stretch.setTransposeSemitones(t, tonality > 0 ? (float)(tonality / p->sampleRate) : 0.0f);
        bool formants = p->formants.load() != 0;
        p->stretch.setFormantSemitones(0, formants); // compensate: keep formants where they were
        float base = p->formantBaseHz.load();
        p->stretch.setFormantBase(formants && base > 0 ? (float)(base / p->sampleRate) : 0.0f);
    }

    int done = 0;
    while (done < frames) {
        int n = std::min(frames - done, p->maxFrames);
        std::copy(left + done, left + done + n, p->inL.data());
        std::copy(right + done, right + done + n, p->inR.data());
        float *in[2] = {p->inL.data(), p->inR.data()};
        float *out[2] = {left + done, right + done};
        p->stretch.process(in, n, out, n); // same length in/out = pitch only
        done += n;
    }
}

// MARK: - Dattorro plate reverb

namespace {

/// Power-of-two ring buffer. get(d) = sample pushed d steps ago (call before push).
struct Line {
    std::vector<float> b;
    int mask = 0, pos = 0;
    void init(int maxDelay) {
        int s = 1;
        while (s < maxDelay + 4) s <<= 1;
        b.assign(s, 0.0f);
        mask = s - 1;
        pos = 0;
    }
    void clear() { std::fill(b.begin(), b.end(), 0.0f); }
    float get(int d) const { return b[(pos - d) & mask]; }
    float getFrac(float d) const {
        int i = (int)d;
        float f = d - (float)i;
        return get(i) * (1.0f - f) + get(i + 1) * f;
    }
    void push(float x) { b[pos & mask] = x; pos++; }
};

/// Lattice allpass: v = x - g·v[n-N], y = g·v + v[n-N].
inline float allpass(Line &l, float n, float g, float x) {
    float d = l.getFrac(n);
    float v = x - g * d;
    l.push(v);
    return d + g * v;
}

} // namespace

struct DSPPlate {
    double sr;
    float scale = 1; // sr / 29761 (paper's rate)
    // input
    Line pre, ap1, ap2, ap3, ap4;
    float bwState = 0;
    // tank, left half: modulated AP 672 → delay 4453 → damp → AP 1800 → delay 3720
    Line lAP1, lDel1, lAP2, lDel2;
    // right half: modulated AP 908 → delay 4217 → damp → AP 2656 → delay 3163
    Line rAP1, rDel1, rAP2, rDel2;
    float lDamp = 0, rDamp = 0, lOut = 0, rOut = 0;
    double lfo = 0;

    std::atomic<float> mixA{0.3f}, decayA{0.85f}, dampingA{0.5f}, predelayA{20.0f}, sizeA{1.0f};
    std::atomic<int> enabledA{0};
    bool wasEnabled = false;

    // current lengths (samples, at sr) for the active size
    float n[12];
};

namespace {
// Paper delay lengths at 29761 Hz.
const float kIn[4] = {142, 107, 379, 277};
const float kTank[8] = {672, 4453, 1800, 3720, 908, 4217, 2656, 3163};
const float kMaxSize = 1.5f;
const float kExcursion = 16; // samples @ 29761 Hz

inline int tapOf(float paperSamples, float k) { return std::max(1, (int)(paperSamples * k)); }
} // namespace

DSPPlate *dsp_plate_create(double sampleRate) {
    auto *r = new DSPPlate();
    r->sr = sampleRate;
    r->scale = (float)(sampleRate / 29761.0);
    float m = r->scale * kMaxSize;
    r->pre.init((int)(0.2 * sampleRate) + 4);
    Line *ins[4] = {&r->ap1, &r->ap2, &r->ap3, &r->ap4};
    for (int i = 0; i < 4; i++) ins[i]->init((int)(kIn[i] * m) + 4);
    Line *tank[8] = {&r->lAP1, &r->lDel1, &r->lAP2, &r->lDel2, &r->rAP1, &r->rDel1, &r->rAP2, &r->rDel2};
    for (int i = 0; i < 8; i++) tank[i]->init((int)((kTank[i] + kExcursion + 2) * m) + 4);
    return r;
}

void dsp_plate_destroy(DSPPlate *r) { delete r; }

void dsp_plate_set(DSPPlate *r, float mix, float decay, float damping, float predelayMs, float size) {
    r->mixA.store(std::clamp(mix, 0.0f, 1.0f));
    r->decayA.store(std::clamp(decay, 0.0f, 0.99f));
    r->dampingA.store(std::clamp(damping, 0.0f, 1.0f));
    r->predelayA.store(std::clamp(predelayMs, 0.0f, 200.0f));
    r->sizeA.store(std::clamp(size, 0.5f, kMaxSize));
}

void dsp_plate_set_enabled(DSPPlate *r, int enabled) { r->enabledA.store(enabled ? 1 : 0); }

void dsp_plate_reset(DSPPlate *r) {
    Line *all[13] = {&r->pre, &r->ap1, &r->ap2, &r->ap3, &r->ap4, &r->lAP1, &r->lDel1, &r->lAP2, &r->lDel2,
                     &r->rAP1, &r->rDel1, &r->rAP2, &r->rDel2};
    for (auto *l : all) l->clear();
    r->bwState = r->lDamp = r->rDamp = r->lOut = r->rOut = 0;
}

void dsp_plate_process(DSPPlate *r, float *left, float *right, int frames) {
    bool enabled = r->enabledA.load() != 0;
    if (!enabled) {
        if (r->wasEnabled) { r->wasEnabled = false; dsp_plate_reset(r); }
        return;
    }
    r->wasEnabled = true;

    const float mix = r->mixA.load(), decay = r->decayA.load();
    const float damping = r->dampingA.load() * 0.85f; // keep a little top end even at max
    const float k = r->scale * r->sizeA.load();
    const int predelay = std::max(1, (int)(r->predelayA.load() * 0.001 * r->sr));
    const float bandwidth = 0.9995f, inDiff1 = 0.75f, inDiff2 = 0.625f;
    const float decDiff1 = 0.70f, decDiff2 = std::clamp(decay + 0.15f, 0.25f, 0.5f);
    const float exc = kExcursion * r->scale;
    const double lfoInc = 2.0 * M_PI * 0.9 / r->sr; // ~0.9 Hz modulation

    // lengths at this size
    const float a1 = kIn[0] * k, a2 = kIn[1] * k, a3 = kIn[2] * k, a4 = kIn[3] * k;
    const float lMod = kTank[0] * k, lD1 = kTank[1] * k, lA2 = kTank[2] * k, lD2 = kTank[3] * k;
    const float rMod = kTank[4] * k, rD1 = kTank[5] * k, rA2 = kTank[6] * k, rD2 = kTank[7] * k;

    // Dry/wet: keep dry loud (slowed + reverb style), add up to +3 dB of wet.
    const float dryGain = 1.0f - 0.5f * mix;
    const float wetGain = 1.4f * mix;

    for (int i = 0; i < frames; i++) {
        float dryL = left[i], dryR = right[i];
        float x = 0.5f * (dryL + dryR);

        // pre-delay + bandwidth lowpass
        float pd = r->pre.get(predelay);
        r->pre.push(x);
        r->bwState += bandwidth * (pd - r->bwState);
        float d = r->bwState;

        // input diffusion
        d = allpass(r->ap1, a1, inDiff1, d);
        d = allpass(r->ap2, a2, inDiff1, d);
        d = allpass(r->ap3, a3, inDiff2, d);
        d = allpass(r->ap4, a4, inDiff2, d);

        // tank (cross-coupled): each half is fed by the other half's previous output
        r->lfo += lfoInc;
        if (r->lfo > 2.0 * M_PI) r->lfo -= 2.0 * M_PI;
        float modL = exc * (float)std::sin(r->lfo), modR = exc * (float)std::cos(r->lfo);

        float lIn = d + decay * r->rOut + 1e-20f;
        float l = allpass(r->lAP1, lMod + modL, -decDiff1, lIn);
        float ld = r->lDel1.get((int)lD1); r->lDel1.push(l);
        r->lDamp = ld * (1.0f - damping) + r->lDamp * damping;
        l = allpass(r->lAP2, lA2, decDiff2, r->lDamp * decay);
        float lo = r->lDel2.get((int)lD2); r->lDel2.push(l);

        float rIn = d + decay * r->lOut + 1e-20f;
        float rr = allpass(r->rAP1, rMod + modR, -decDiff1, rIn);
        float rd = r->rDel1.get((int)rD1); r->rDel1.push(rr);
        r->rDamp = rd * (1.0f - damping) + r->rDamp * damping;
        rr = allpass(r->rAP2, rA2, decDiff2, r->rDamp * decay);
        float ro = r->rDel2.get((int)rD2); r->rDel2.push(rr);

        r->lOut = lo;
        r->rOut = ro;

        // output taps (paper's table, scaled)
        float yl = r->rDel1.get(tapOf(266, k)) + r->rDel1.get(tapOf(2974, k)) - r->rAP2.get(tapOf(1913, k))
                 + r->rDel2.get(tapOf(1996, k)) - r->lDel1.get(tapOf(1990, k)) - r->lAP2.get(tapOf(187, k))
                 - r->lDel2.get(tapOf(1066, k));
        float yr = r->lDel1.get(tapOf(353, k)) + r->lDel1.get(tapOf(3627, k)) - r->lAP2.get(tapOf(1228, k))
                 + r->lDel2.get(tapOf(2673, k)) - r->rDel1.get(tapOf(2111, k)) - r->rAP2.get(tapOf(335, k))
                 - r->rDel2.get(tapOf(121, k));

        left[i] = dryL * dryGain + 0.6f * yl * wetGain;
        right[i] = dryR * dryGain + 0.6f * yr * wetGain;
    }
}

// MARK: - "Next door" wall

namespace {
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    inline float run(float x) {
        double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return (float)y;
    }
    void lowpass(double f, double q, double sr) {
        double w = 2 * M_PI * f / sr, c = std::cos(w), al = std::sin(w) / (2 * q), a0 = 1 + al;
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0;
    }
    void lowShelf(double f, double gainDB, double sr) {
        double A = std::pow(10, gainDB / 40), w = 2 * M_PI * f / sr, c = std::cos(w), s = std::sin(w);
        double al = s / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * al, a0 = (A + 1) + (A - 1) * c + sq;
        b0 = A * ((A + 1) - (A - 1) * c + sq) / a0;
        b1 = 2 * A * ((A - 1) - (A + 1) * c) / a0;
        b2 = A * ((A + 1) - (A - 1) * c - sq) / a0;
        a1 = -2 * ((A - 1) + (A + 1) * c) / a0;
        a2 = ((A + 1) + (A - 1) * c - sq) / a0;
    }
    void copyCoeffs(const Biquad &o) { b0 = o.b0; b1 = o.b1; b2 = o.b2; a1 = o.a1; a2 = o.a2; }
};
} // namespace

struct DSPWall {
    double sr;
    std::atomic<int> enabledA{0};
    std::atomic<float> amountA{0.7f};
    bool wasEnabled = false;
    float amount = -1; // smoothed value actually in use
    Biquad lp1[2], lp2[2], shelf[2];

    void design(float a) {
        double cutoff = 20000.0 * std::pow(180.0 / 20000.0, (double)a); // log sweep
        cutoff = std::min(cutoff, sr * 0.45);
        Biquad p1, p2, sh;
        p1.lowpass(cutoff, 0.5412, sr); // 4th-order Butterworth = two biquads
        p2.lowpass(cutoff, 1.3066, sr);
        sh.lowShelf(110, 5.0 * a, sr);  // the thump that gets through
        for (int c = 0; c < 2; c++) { lp1[c].copyCoeffs(p1); lp2[c].copyCoeffs(p2); shelf[c].copyCoeffs(sh); }
    }
    void clear() {
        for (int c = 0; c < 2; c++) { lp1[c].z1 = lp1[c].z2 = lp2[c].z1 = lp2[c].z2 = shelf[c].z1 = shelf[c].z2 = 0; }
    }
};

DSPWall *dsp_wall_create(double sampleRate) {
    auto *w = new DSPWall();
    w->sr = sampleRate;
    return w;
}

void dsp_wall_destroy(DSPWall *w) { delete w; }

void dsp_wall_set(DSPWall *w, int enabled, float amount) {
    w->enabledA.store(enabled ? 1 : 0);
    w->amountA.store(std::clamp(amount, 0.0f, 1.0f));
}

void dsp_wall_process(DSPWall *w, float *left, float *right, int frames) {
    if (!w->enabledA.load()) {
        if (w->wasEnabled) { w->wasEnabled = false; w->clear(); w->amount = -1; }
        return;
    }
    w->wasEnabled = true;
    float target = w->amountA.load();
    // Glide toward the target once per block (no zipper noise while dragging).
    float a = w->amount < 0 ? target : w->amount + (target - w->amount) * 0.3f;
    if (std::fabs(a - target) < 0.002f) a = target;
    if (a != w->amount) { w->amount = a; w->design(a); }

    const float width = 1.0f - 0.8f * a;                    // through a wall, stereo smears toward mono
    const float makeup = std::pow(10.0f, (6.0f * a) / 20); // lost highs = quieter; give some back
    for (int i = 0; i < frames; i++) {
        float m = 0.5f * (left[i] + right[i]), s = 0.5f * (left[i] - right[i]) * width;
        float l = m + s, r = m - s;
        l = w->shelf[0].run(w->lp2[0].run(w->lp1[0].run(l)));
        r = w->shelf[1].run(w->lp2[1].run(w->lp1[1].run(r)));
        left[i] = l * makeup;
        right[i] = r * makeup;
    }
}
