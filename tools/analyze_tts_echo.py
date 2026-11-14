import sys, wave, numpy as np

def read_wav(path):
    with wave.open(path, 'rb') as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        data = w.readframes(n)
    if sw != 2:
        raise SystemExit('need s16 wav: %s' % path)
    x = np.frombuffer(data, dtype='<i2').astype(np.float32) / 32768.0
    if ch == 2:
        x = x.reshape(-1, 2).mean(axis=1)
    return x, sr

def resample(x, sr, target=16000):
    if sr == target:
        return x.astype(np.float32)
    n = int(round(len(x) * target / float(sr)))
    if sr > target:
        w = int(round(sr / float(target)))
        if w > 1:
            x = np.convolve(x, np.ones(w, dtype=np.float32) / w, mode='same')
    idx = np.linspace(0, len(x) - 1, n)
    return np.interp(idx, np.arange(len(x)), x).astype(np.float32)

def find_peak(mic, ref):
    mic = mic - mic.mean(); ref = ref - ref.mean()
    M, L = len(mic), len(ref)
    nfft = 1 << (M + L - 1).bit_length()
    C = np.fft.irfft(np.fft.rfft(mic, nfft) * np.conj(np.fft.rfft(ref, nfft)), nfft)
    valid = C[:M - L + 1]  # positive lags only
    k = int(np.argmax(np.abs(valid)))
    seg = mic[k:k + L]
    denom = float(np.dot(ref, ref))
    gain = float(np.dot(seg, ref) / denom) if denom > 0 else 0.0
    seg_e = float(np.dot(seg, seg))
    corr = gain * np.sqrt(denom / seg_e) if seg_e > 0 else 0.0
    return k, corr, gain

def top_peaks(mic, ref, n=5):
    mic = mic - mic.mean(); ref = ref - ref.mean()
    M, L = len(mic), len(ref)
    nfft = 1 << (M + L - 1).bit_length()
    C = np.abs(np.fft.irfft(np.fft.rfft(mic, nfft) * np.conj(np.fft.rfft(ref, nfft)), nfft)[:M - L + 1])
    peaks = []
    Cc = C.copy()
    for _ in range(n):
        k = int(np.argmax(Cc))
        if Cc[k] <= 0:
            break
        peaks.append(k)
        lo, hi = max(0, k - L // 2), min(len(Cc), k + L // 2 + 1)
        Cc[lo:hi] = 0
    out = []
    denom = float(np.dot(ref, ref))
    for k in peaks:
        seg = mic[k:k + L]
        gain = float(np.dot(seg, ref) / denom) if denom > 0 else 0.0
        seg_e = float(np.dot(seg, seg))
        corr = gain * np.sqrt(denom / seg_e) if seg_e > 0 else 0.0
        erl = 20 * np.log10(abs(gain)) if gain != 0 else -999
        out.append((k, corr, gain, erl))
    return out

def selftest():
    sr = 16000
    rng = np.random.default_rng(1)
    ref = rng.normal(0, 0.1, sr * 3).astype(np.float32)
    mic = rng.normal(0, 0.001, sr * 20).astype(np.float32)
    mic[sr * 7:sr * 10] += 0.05 * ref
    k, corr, gain = find_peak(mic, ref)
    print('selftest peak lag=%.3fs corr=%.4f gain=%.4f (expect ~7.0s, 0.05)' % (k / sr, corr, gain))
    print('top:', [(round(x[0] / sr, 2), round(x[1], 3), round(x[2], 4), round(x[3], 1)) for x in top_peaks(mic, ref)])

if __name__ == '__main__':
    if '--selftest' in sys.argv:
        selftest(); sys.exit(0)
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--tts', required=True)
    ap.add_argument('--mic', required=True)
    ap.add_argument('--top', type=int, default=5)
    a = ap.parse_args()
    ref, sr1 = read_wav(a.tts); ref = resample(ref, sr1)
    mic, sr2 = read_wav(a.mic); mic = resample(mic, sr2)
    print('[echo] tts=%s sr=%d -> %d samples (%.2fs)' % (a.tts, sr1, len(ref), len(ref)/16000.0))
    print('[echo] mic=%s sr=%d -> %d samples (%.2fs)' % (a.mic, sr2, len(mic), len(mic)/16000.0))
    for k, corr, gain, erl in top_peaks(mic, ref, a.top):
        print('[peak] t=%.2fs corr=%+.4f gain=%+.4f erl=%+.1f dB' % (k/16000.0, corr, gain, erl))
