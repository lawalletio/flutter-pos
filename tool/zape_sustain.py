"""Split the "sapeee" cue into intro / seamless loop / release for the held ZAPE button.

The loop is a phase-vocoder freeze of the steady part of the "e": every FFT bin
keeps advancing at its measured frequency (so the voice keeps its buzz) plus a
little jitter. Phases are nudged to land back on their start after one loop, so
the loop repeats with no seam.

    python3 -m pip install numpy scipy
    python3 tool/zape_sustain.py
"""
import numpy as np
from scipy.io import wavfile
from scipy.ndimage import uniform_filter1d

SRC = 'assets/sounds/paid_bananero.wav'
OUT = 'assets/sounds/zape_{}.wav'
E_START, E_END = 0.94, 1.20  # steady part of the "e", seconds
RELEASE_AT = 1.16            # where the natural ending is taken from
LOOP_SECONDS = 2.0
N, HOP, JITTER, AGC = 4096, 512, 0.35, 0.6
FADE_IN = 0.06               # intro -> loop crossfade, seconds

sr, x = wavfile.read(SRC)
x = x.astype(float) / 32768
mono = x.mean(1)
a, b = int(E_START * sr), int(E_END * sr)
rng = np.random.default_rng(11)
win = np.hanning(N)


def rms(v):
    return np.sqrt((v ** 2).mean() + 1e-12)


# Average magnitude per channel, and each bin's true frequency from two close frames.
mag = [np.mean([np.abs(np.fft.rfft(x[i:i + N, c] * win)) for i in range(a, b - N, N // 8)], 0)
       for c in (0, 1)]
c0 = int(1.06 * sr)
X1 = np.fft.rfft(mono[c0:c0 + N] * win)
X2 = np.fft.rfft(mono[c0 + HOP:c0 + HOP + N] * win)
k = np.arange(N // 2 + 1)
expect = 2 * np.pi * k * HOP / N
omega = (expect + np.angle(np.exp(1j * (np.angle(X2) - np.angle(X1) - expect)))) / HOP

# Circular overlap-add: frame K would sit on frame 0 with the same phase.
K = round(LOOP_SECONDS * sr / HOP)
L = K * HOP
jit = rng.normal(0, JITTER, (K, len(k)))
jit -= jit.mean(0)                                     # the random walk returns home
drift = K * omega * HOP
nudge = np.angle(np.exp(-1j * drift)) / K              # <= pi/K rad per frame
loop = np.zeros((L, 2))
norm = np.zeros(L)
ph = np.angle(X1)
for j in range(K):
    e = np.exp(1j * ph)
    idx = (j * HOP + np.arange(N)) % L
    for c in (0, 1):
        np.add.at(loop[:, c], idx, np.fft.irfft(mag[c] * e, N) * win)
    np.add.at(norm, idx, win ** 2)
    ph = ph + omega * HOP + nudge + jit[j]
loop /= norm[:, None]

# Same loudness as the real "e", with the slow wobble mostly flattened.
target = rms(mono[a:b])
loop *= target / rms(loop.mean(1))
env = np.sqrt(uniform_filter1d(loop.mean(1) ** 2, int(0.04 * sr), mode='wrap')) + 1e-6
loop *= ((target / env) ** AGC)[:, None]

# Intro ends by fading into the loop's last samples, so loop[0] follows on seamlessly.
f = int(FADE_IN * sr)
w = np.sin(np.linspace(0, 1, f)[:, None] * np.pi / 2)
intro = x[:a].copy()
intro[-f:] = intro[-f:] * np.sqrt(1 - w ** 2) + loop[-f:] * w
release = x[int(RELEASE_AT * sr):]
release = release[:np.nonzero(np.abs(release).max(1) > 1e-4)[0][-1] + 1]

peak = max(np.abs(p).max() for p in (intro, loop, release))
assert peak < 1, f'clips at {peak:.2f}'
step = np.median(np.abs(np.diff(loop.mean(1))))
seam = abs(loop[0].mean() - loop[-1].mean())
assert seam < 4 * step, f'loop seam {seam:.4f} vs typical step {step:.4f}'

for name, part in (('intro', intro), ('loop', loop), ('release', release)):
    wavfile.write(OUT.format(name), sr, (part * 32767).astype(np.int16))
    print(f'{name:8s} {len(part) / sr:.3f}s')
print(f'seam {seam:.4f}, typical step {step:.4f}')
