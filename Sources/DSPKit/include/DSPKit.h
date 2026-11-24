// DSPKit — real-time audio effects for SoundAmp (C interface, C++ inside).
//
//  * Pitch shifter: Signalsmith Stretch (MIT) used as a pure pitch shifter.
//  * Plate reverb: Jon Dattorro's 1997 "Effect Design Part 1" plate (Griesinger
//    style), written from the paper.
//
// All process functions are real-time safe: no allocation, no locks. Parameter
// setters may be called from any thread; values are picked up on the next block.
// Buffers are planar stereo, processed in place.
#ifndef DSPKIT_H
#define DSPKIT_H

#ifdef __cplusplus
extern "C" {
#endif

// MARK: Pitch shifter

typedef struct DSPPitch DSPPitch;

/// `maxFrames`: largest block that will be passed to dsp_pitch_process.
DSPPitch *dsp_pitch_create(double sampleRate, int maxFrames);
void dsp_pitch_destroy(DSPPitch *p);
/// Semitones (fractional ok). 0 = bypass (no latency, bit-exact).
void dsp_pitch_set_semitones(DSPPitch *p, float semitones);
/// Tonality limit in Hz (0 = off): above it, timbre is preserved more (less
/// "chipmunk"). Formant compensation keeps a voice's character when shifting;
/// formantBaseHz ≈ the voice's fundamental (100 low … 400 high).
void dsp_pitch_set_quality(DSPPitch *p, float tonalityHz, int formantCompensation, float formantBaseHz);
float dsp_pitch_get_semitones(const DSPPitch *p);
/// Total latency in frames while shifting.
int dsp_pitch_latency(const DSPPitch *p);
void dsp_pitch_process(DSPPitch *p, float *left, float *right, int frames);

// MARK: Plate reverb

typedef struct DSPPlate DSPPlate;

DSPPlate *dsp_plate_create(double sampleRate);
void dsp_plate_destroy(DSPPlate *r);
/// mix 0…1 (0 = dry only), decay 0…0.99 (tail length), damping 0…1 (1 = darkest),
/// predelay in ms (0…200), size 0.5…1.5 (scales the tank).
void dsp_plate_set(DSPPlate *r, float mix, float decay, float damping, float predelayMs, float size);
/// Enabled = processing; disabled = passthrough (tail is cut).
void dsp_plate_set_enabled(DSPPlate *r, int enabled);
void dsp_plate_reset(DSPPlate *r);
void dsp_plate_process(DSPPlate *r, float *left, float *right, int frames);

// MARK: "Next door" wall

typedef struct DSPWall DSPWall;

/// The sound of a party behind a wall: steep low-pass (wall transmission loss),
/// a little bass thump, stereo collapsing toward mono, makeup gain.
DSPWall *dsp_wall_create(double sampleRate);
void dsp_wall_destroy(DSPWall *w);
/// amount 0…1 (more = thicker wall: cutoff ~20 kHz → ~180 Hz). Disabled = passthrough.
void dsp_wall_set(DSPWall *w, int enabled, float amount);
void dsp_wall_process(DSPWall *w, float *left, float *right, int frames);

#ifdef __cplusplus
}
#endif

#endif
