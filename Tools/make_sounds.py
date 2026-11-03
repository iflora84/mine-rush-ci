"""Synthesizes Mine Rush's sound effects and music loop into App/Sounds.

Usage: python Tools/make_sounds.py App/Sounds
"""
import os
import sys
import wave

import numpy as np

RATE = 44100
rng = np.random.default_rng(7)


def t(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def env(n, attack=0.004, decay=8.0):
    x = np.arange(n) / RATE
    a = np.clip(x / attack, 0, 1)
    return a * np.exp(-x * decay)


def pluck(freq, seconds=0.5, decay=7.0, bright=0.35):
    x = t(seconds)
    tone = np.sin(2 * np.pi * freq * x) + bright * np.sin(2 * np.pi * 2 * freq * x) + 0.12 * np.sin(2 * np.pi * 3 * freq * x)
    return tone * env(len(x), decay=decay)


def sweep(f0, f1, seconds):
    x = t(seconds)
    freq = np.geomspace(f0, f1, len(x))
    return np.sin(2 * np.pi * np.cumsum(freq) / RATE)


def lowpass(sig, alpha):
    out = np.empty_like(sig)
    acc = 0.0
    for i, v in enumerate(sig):
        acc += alpha * (v - acc)
        out[i] = acc
    return out


def mix(*parts):
    n = max(len(p) for _, p in parts)
    out = np.zeros(n)
    for offset, p in parts:
        start = int(offset * RATE)
        end = min(n, start + len(p))
        out[start:end] += p[: end - start]
    return out


def save(path, sig, peak=0.85):
    sig = sig / (np.max(np.abs(sig)) or 1) * peak
    data = (sig * 32767).astype('<i2').tobytes()
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)


def note(semitones_from_a4):
    return 440.0 * 2 ** (semitones_from_a4 / 12)


def build(out):
    os.makedirs(out, exist_ok=True)

    # Dig: a soft crunchy thump.
    n = int(RATE * 0.12)
    crunch = lowpass(rng.uniform(-1, 1, n), 0.25) * env(n, decay=40)
    thump = sweep(180, 70, 0.12) * env(n, decay=30)
    save(os.path.join(out, 'dig.wav'), crunch * 0.6 + thump, peak=0.6)

    # Flag: two rising plucks. Unflag: one falling.
    save(os.path.join(out, 'flag.wav'), mix((0, pluck(note(3), 0.18, 22)), (0.06, pluck(note(10), 0.2, 18))), peak=0.55)
    save(os.path.join(out, 'unflag.wav'), mix((0, pluck(note(10), 0.15, 25)), (0.05, pluck(note(3), 0.16, 25))), peak=0.45)

    # Coin: bright two-note chime.
    save(os.path.join(out, 'coin.wav'), mix((0, pluck(note(14), 0.25, 14, 0.6)), (0.07, pluck(note(19), 0.35, 10, 0.6))), peak=0.5)

    # Scan: rising sweep with a shimmer.
    x = t(0.45)
    scan = sweep(500, 1400, 0.45) * (0.6 + 0.4 * np.sin(2 * np.pi * 18 * x)) * env(len(x), attack=0.03, decay=5)
    save(os.path.join(out, 'scan.wav'), scan, peak=0.45)

    # Shield: metallic clang.
    x = t(0.5)
    clang = sum(np.sin(2 * np.pi * f * x) * a for f, a in ((620, 1), (1240 * 1.01, 0.5), (1860 * 1.03, 0.3)))
    save(os.path.join(out, 'shield.wav'), clang * env(len(x), decay=9), peak=0.5)

    # Boom: noisy burst plus a falling rumble.
    n = int(RATE * 0.9)
    noise = lowpass(rng.uniform(-1, 1, n), 0.12) * env(n, attack=0.002, decay=5)
    rumble = sweep(120, 35, 0.9) * env(n, attack=0.002, decay=3.5)
    save(os.path.join(out, 'boom.wav'), noise * 0.9 + rumble, peak=0.9)

    # Win: happy arpeggio (C major) with a final chord.
    notes = [3, 7, 10, 15]
    parts = [(i * 0.09, pluck(note(n), 0.5, 6)) for i, n in enumerate(notes)]
    parts += [(0.42, pluck(note(n), 0.9, 3.5) * 0.6) for n in (3, 7, 10, 15)]
    save(os.path.join(out, 'win.wav'), mix(*parts), peak=0.7)

    # Music: 16 seconds at 120 bpm, pentatonic plucks over a soft bass. Tails wrap to loop cleanly.
    beat = 0.5
    bars = 8
    length = int(RATE * beat * 4 * bars)
    music = np.zeros(length)
    scale = [3, 5, 7, 10, 12, 15, 17, 19]  # C major pentatonic-ish, relative to A4
    melody_rng = np.random.default_rng(11)
    chords = [3, -2, 0, -4] * 2  # C, G, A, F roots (relative to A4)

    def add(offset_s, sig):
        start = int(offset_s * RATE)
        for i in range(len(sig)):
            music[(start + i) % length] += sig[i]

    for bar in range(bars):
        root = chords[bar]
        bar_start = bar * 4 * beat
        add(bar_start, pluck(note(root - 24), 1.8, 2.2, 0.15) * 0.5)
        add(bar_start + 2 * beat, pluck(note(root - 24 + 7), 1.0, 2.5, 0.15) * 0.35)
        for step in range(8):
            if melody_rng.random() < 0.62:
                n = scale[melody_rng.integers(len(scale))]
                add(bar_start + step * beat / 2, pluck(note(n), 0.6, 6.5, 0.25) * 0.28)
    save(os.path.join(out, 'music.wav'), music, peak=0.5)


if __name__ == '__main__':
    build(sys.argv[1])
    print('ok')
