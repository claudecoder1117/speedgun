"""
Doppler Speed Gun — DSP prototype.

Proves the physics we need for the iPhone app:
  1. Emit a 20 kHz carrier from the phone speaker.
  2. Microphone picks up (a) strong direct-path bleedthrough at f0,
     and (b) a weak reflection from the target, Doppler-shifted by
     f_reflected = f0 * (c + v) / (c - v)  for a target approaching at v m/s.
  3. FFT the captured block, notch out the carrier, peak-pick in the
     expected sideband window, invert the Doppler formula to get v.

Run:  python3 doppler_prototype.py
Output: console table + doppler_prototype.png
"""

import matplotlib
matplotlib.use("Agg")  # headless — we save a PNG

import numpy as np
import matplotlib.pyplot as plt

# ---- physics ----------------------------------------------------------------
C_AIR = 343.0        # m/s, speed of sound at ~20 C
# Carrier choice: 48 kHz sample rate => 24 kHz Nyquist. Upshifted reflections
# must stay below 24 kHz to avoid aliasing. At f0=20 kHz, a 90 mph target shifts
# to ~25.3 kHz and aliases. f0=18 kHz gives us 6 kHz of headroom -> ~110 mph max,
# while staying at the edge of most adults' hearing.
F0 = 18_000.0
SR = 48_000          # Hz, iPhone default mic sample rate
DURATION = 1.0       # s, integration window for this proof (iOS app will use ~100 ms)
MPS_TO_MPH = 2.23694

rng = np.random.default_rng(0)


def synth_signal(speed_mps, *, sr=SR, f0=F0, duration=DURATION,
                 direct_amp=1.0, reflect_amp=0.05, noise_amp=0.01):
    """Synthetic mic capture: carrier bleedthrough + shifted reflection + white noise."""
    t = np.arange(int(sr * duration)) / sr
    f_reflected = f0 * (C_AIR + speed_mps) / (C_AIR - speed_mps)
    direct    = direct_amp  * np.cos(2 * np.pi * f0 * t)
    reflected = reflect_amp * np.cos(2 * np.pi * f_reflected * t)
    noise     = noise_amp   * rng.standard_normal(len(t))
    return t, direct + reflected + noise


def estimate_speed(sig, *, sr=SR, f0=F0, carrier_notch_hz=20.0, search_bw_hz=6000.0):
    """Peak-pick the Doppler sideband above the carrier; invert Doppler for v."""
    N = len(sig)
    # Blackman-Harris-ish (np.blackman) kills sidelobes from the 20x-stronger carrier.
    spectrum = np.fft.rfft(sig * np.blackman(N))
    freqs = np.fft.rfftfreq(N, d=1 / sr)
    mag = np.abs(spectrum)

    # Search window: carrier + notch_guard ... carrier + max_bandwidth.
    # Only looking at positive side for now (approaching targets); prod app searches both.
    search = (freqs > f0 + carrier_notch_hz) & (freqs < f0 + search_bw_hz)
    if not search.any():
        return 0.0, freqs, mag
    peak_freq = freqs[np.argmax(np.where(search, mag, 0))]
    # exact inverse: peak = f0 (c+v)/(c-v)  =>  v = c (peak - f0) / (peak + f0)
    v_est = C_AIR * (peak_freq - f0) / (peak_freq + f0)
    return v_est, freqs, mag


# ---- tests ------------------------------------------------------------------

def mph(v):  # convenience
    return v * MPS_TO_MPH


def run_case_sweep():
    cases = [
        ("walking",            1.5),
        ("jogging",            3.0),
        ("sprinting",          9.0),
        ("bike",              10.0),
        ("city car (30 mph)", 13.4),
        ("fastball 60 mph",   26.8),
        ("fastball 90 mph",   40.2),
        ("slapshot 100 mph",  44.7),
    ]
    print(f"{'case':22s} {'true':>11s} {'est':>11s} {'err (mph)':>12s}")
    print("-" * 58)
    results = []
    for name, v in cases:
        _, sig = synth_signal(v)
        v_est, *_ = estimate_speed(sig)
        err = mph(v_est - v)
        results.append((name, v, v_est, err))
        print(f"{name:22s} {mph(v):8.1f}mph {mph(v_est):8.1f}mph {err:+12.2f}")
    return results


def run_snr_sweep():
    """Hold reflection weak (0.001 of carrier) and crank noise until it fails."""
    print("\nNoise breakdown @ 20 m/s (45 mph) target, reflect_amp=0.001 (60 dB below carrier):")
    print("-" * 72)
    out = []
    for na in [0.0001, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05]:
        # Average 5 trials per noise level to smooth the random realization.
        ests = []
        for _ in range(5):
            _, sig = synth_signal(20.0, reflect_amp=0.001, noise_amp=na)
            v_est, *_ = estimate_speed(sig)
            ests.append(v_est)
        mean_est = float(np.mean(ests))
        std_est  = float(np.std(ests))
        err = mph(mean_est - 20.0)
        out.append((na, mean_est, std_est))
        # reflect_amp=0.001 -> noise/reflection ratio in dB = 20*log10(na/0.001)
        snr_db = 20 * np.log10(0.001 / na) if na > 0 else 120
        print(f"  noise={na:7.4f}  reflection-to-noise={snr_db:+6.1f} dB  "
              f"est={mph(mean_est):6.1f}±{mph(std_est):4.1f} mph  err={err:+6.2f} mph")
    return out


# ---- plots ------------------------------------------------------------------

def make_plots(cases, snr):
    fig, axes = plt.subplots(1, 3, figsize=(18, 5))

    # (1) Zoomed spectrum, 90 mph fastball case — shows carrier + sideband.
    # Bump reflection amp slightly for visual clarity (estimation tests stay at 0.05).
    # Max-pool into ~600 display buckets so single-bin peaks survive downsampling.
    _, sig = synth_signal(40.2, reflect_amp=0.2, noise_amp=0.005)
    _, freqs, mag = estimate_speed(sig)
    zoom = (freqs > F0 - 500) & (freqs < F0 + 6500)
    zf, zm = freqs[zoom], mag[zoom]
    n_buckets = 600
    step = max(1, len(zf) // n_buckets)
    pooled_f = zf[::step][:n_buckets]
    pooled_m = np.array([zm[i:i + step].max() for i in range(0, len(zm), step)])[:n_buckets]
    mag_db = 20 * np.log10(pooled_m + 1e-12)
    axes[0].plot(pooled_f, mag_db, lw=0.7)
    axes[0].axvline(F0, color="gray", ls="--", label=f"emitted {F0/1000:.0f} kHz")
    f_r = F0 * (C_AIR + 40.2) / (C_AIR - 40.2)
    axes[0].axvline(f_r, color="red", ls="--", label=f"reflected {f_r:.0f} Hz (90 mph)")
    axes[0].set_ylim(-20, 90)
    axes[0].set(xlabel="frequency (Hz)", ylabel="magnitude (dB)",
                title="spectrum near carrier — 90 mph fastball")
    axes[0].legend(); axes[0].grid(alpha=0.3)

    # (2) Recovery across cases.
    trues = [mph(c[1]) for c in cases]
    ests  = [mph(c[2]) for c in cases]
    axes[1].scatter(trues, ests, s=70)
    lim = max(trues) * 1.1
    axes[1].plot([0, lim], [0, lim], "k--", alpha=0.4, label="perfect")
    for name, tv, ev in zip([c[0] for c in cases], trues, ests):
        axes[1].annotate(name, (tv, ev), fontsize=8, xytext=(4, 4),
                         textcoords="offset points")
    axes[1].set(xlabel="true speed (mph)", ylabel="estimated speed (mph)",
                title="recovery across cases")
    axes[1].legend(); axes[1].grid(alpha=0.3)

    # (3) Noise breakdown sweep.
    snrs_db = [20 * np.log10(0.001 / s[0]) for s in snr]
    means   = [mph(s[1]) for s in snr]
    stds    = [mph(s[2]) for s in snr]
    axes[2].errorbar(snrs_db, means, yerr=stds, fmt="o-", capsize=4)
    axes[2].axhline(mph(20), color="red", ls="--", label=f"truth ({mph(20):.0f} mph)")
    axes[2].invert_xaxis()
    axes[2].set(xlabel="reflection-to-noise (dB, higher = cleaner)",
                ylabel="estimated speed (mph)",
                title="breakdown as noise overtakes reflection")
    axes[2].legend(); axes[2].grid(alpha=0.3)

    plt.tight_layout()
    out = "/home/oliver/speedgun/python/doppler_prototype.png"
    plt.savefig(out, dpi=120)
    print(f"\nsaved {out}")


if __name__ == "__main__":
    cases = run_case_sweep()
    snr = run_snr_sweep()
    make_plots(cases, snr)
