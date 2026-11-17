"""BS-Roformer in PyTorch, without the STFT: spectrogram frames in, complex masks out. The module names follow the
BS-Roformer-SW checkpoint, so its state dict loads as is. Written for converting the model to Core ML, which runs it
on a fixed number of frames; the STFT and the inverse STFT run in Muskey."""
import math
import torch
import torch.nn as nn
import torch.nn.functional as F


class RMSNorm(nn.Module):
    def __init__(self, dim):
        super().__init__()
        self.scale = dim ** 0.5
        self.gamma = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        # F.normalize with its 1e-12 floor, written out so Core ML gets plain ops.
        norm = torch.sqrt(torch.sum(x * x, dim=-1, keepdim=True)).clamp(min=1e-12)
        return x / norm * self.scale * self.gamma


def rope_tables(n, dim_head=64, base=10000.0):
    freqs = 1.0 / (base ** (torch.arange(0, dim_head, 2).float() / dim_head))
    angles = torch.arange(n).float()[:, None] * freqs[None, :]  # (n, d/2)
    angles = angles.repeat_interleave(2, dim=-1)  # interleaved pairs, like rotary-embedding-torch
    return angles.cos(), angles.sin()


def rotate_pairs(x):
    x = x.unflatten(-1, (-1, 2))
    x1, x2 = x.unbind(-1)
    return torch.stack((-x2, x1), dim=-1).flatten(-2)


class Attention(nn.Module):
    def __init__(self, dim=256, heads=8, dim_head=64):
        super().__init__()
        self.heads = heads
        self.dim_head = dim_head
        self.norm = RMSNorm(dim)
        self.to_qkv = nn.Linear(dim, heads * dim_head * 3, bias=False)
        self.to_gates = nn.Linear(dim, heads)
        self.to_out = nn.Sequential(nn.Linear(heads * dim_head, dim, bias=False), nn.Identity())

    def forward(self, x, cos, sin):
        x = self.norm(x)
        q, k, v = self.to_qkv(x).unflatten(-1, (3, self.heads, self.dim_head)).permute(2, 0, 3, 1, 4)
        q = q * cos + rotate_pairs(q) * sin
        k = k * cos + rotate_pairs(k) * sin
        out = F.scaled_dot_product_attention(q, k, v)
        gates = torch.sigmoid(self.to_gates(x)).transpose(1, 2).unsqueeze(-1)  # (b, h, n, 1)
        out = (out * gates).transpose(1, 2).flatten(-2)
        return self.to_out(out)


class FeedForward(nn.Module):
    def __init__(self, dim=256, mult=4):
        super().__init__()
        self.net = nn.Sequential(RMSNorm(dim), nn.Linear(dim, dim * mult), nn.GELU(), nn.Identity(),
                                 nn.Linear(dim * mult, dim), nn.Identity())

    def forward(self, x):
        return self.net(x)


class Transformer(nn.Module):
    def __init__(self, dim=256):
        super().__init__()
        self.layers = nn.ModuleList([nn.ModuleList([Attention(dim), FeedForward(dim)])])

    def forward(self, x, cos, sin):
        for attn, ff in self.layers:
            x = attn(x, cos, sin) + x
            x = ff(x) + x
        return x


class GLU(nn.Module):
    def forward(self, x):
        a, b = x.chunk(2, dim=-1)
        return a * torch.sigmoid(b)


class BSRoformerMasks(nn.Module):
    def __init__(self, freqs_per_bands, frames, dim=256, depth=12, stems=6, channels=2, mlp_expansion=4):
        super().__init__()
        self.dims = [f * channels * 2 for f in freqs_per_bands]
        self.layers = nn.ModuleList([nn.ModuleList([Transformer(dim), Transformer(dim)]) for _ in range(depth)])
        self.final_norm = RMSNorm(dim)
        self.band_split = nn.Module()
        self.band_split.to_features = nn.ModuleList([nn.Sequential(RMSNorm(d), nn.Linear(d, dim)) for d in self.dims])
        self.mask_estimators = nn.ModuleList()
        for _ in range(stems):
            m = nn.Module()
            m.to_freqs = nn.ModuleList([
                nn.Sequential(nn.Sequential(nn.Linear(dim, dim * mlp_expansion), nn.Tanh(), nn.Linear(dim * mlp_expansion, d * 2)), GLU())
                for d in self.dims
            ])
            self.mask_estimators.append(m)
        self.frames = frames
        cos_t, sin_t = rope_tables(frames)
        cos_f, sin_f = rope_tables(len(self.dims))
        self.register_buffer("cos_t", cos_t, persistent=False)
        self.register_buffer("sin_t", sin_t, persistent=False)
        self.register_buffer("cos_f", cos_f, persistent=False)
        self.register_buffer("sin_f", sin_f, persistent=False)

    def forward(self, spec):
        """spec: (1, frames, freqs * channels * 2), laid out as [freq][channel][real, imaginary].
        Returns the masks of every stem: (1, stems, frames, freqs * channels * 2) in the same layout."""
        # Sizes are fixed here, since Core ML runs the model on one number of frames.
        b, t, f = 1, self.frames, len(self.dims)
        bands = torch.split(spec, self.dims, dim=-1)
        x = torch.stack([to(band) for to, band in zip(self.band_split.to_features, bands)], dim=-2)  # (b, t, f, d)
        for time_t, freq_t in self.layers:
            x = x.permute(0, 2, 1, 3).reshape(b * f, t, -1)
            x = time_t(x, self.cos_t, self.sin_t)
            x = x.reshape(b, f, t, -1).permute(0, 2, 1, 3).reshape(b * t, f, -1)
            x = freq_t(x, self.cos_f, self.sin_f)
            x = x.reshape(b, t, f, -1)
        x = self.final_norm(x)
        masks = []
        for estimator in self.mask_estimators:
            masks.append(torch.cat([mlp(x[..., i, :]) for i, mlp in enumerate(estimator.to_freqs)], dim=-1))
        return torch.stack(masks, dim=1)


def load(ckpt, freqs_per_bands, frames, stems=6, mlp_expansion=4, heads=None):
    """The model of a checkpoint. `heads`, a list of indices, keeps only those mask estimators, in that order."""
    model = BSRoformerMasks(freqs_per_bands, frames, stems=stems, mlp_expansion=mlp_expansion)
    state = torch.load(ckpt, map_location="cpu", weights_only=False)
    state = state.get("state_dict", state)
    state = {k: v for k, v in state.items() if "rotary_embed" not in k}
    missing, unexpected = model.load_state_dict(state, strict=False)
    assert not unexpected, unexpected
    assert not missing, missing
    if heads is not None:
        model.mask_estimators = nn.ModuleList([model.mask_estimators[i] for i in heads])
    return model.eval()


def stft_pack(audio, n_fft=2048, hop=512):
    """audio: (channels, samples) -> (1, frames, freqs * channels * 2) and the complex STFT (channels, freqs, frames)."""
    window = torch.hann_window(n_fft, periodic=True)
    s = torch.stft(audio, n_fft, hop, n_fft, window, center=True, normalized=False, return_complex=True)
    packed = torch.view_as_real(s).permute(2, 1, 0, 3).reshape(1, s.shape[2], -1)  # (frames, freq, channel, 2)
    return packed, s


def unpack_apply(masks, s, length, n_fft=2048, hop=512):
    """masks: (1, stems, frames, freqs * channels * 2) -> audio (stems, channels, length)."""
    stems, frames = masks.shape[1], masks.shape[2]
    channels, freqs = s.shape[0], s.shape[1]
    m = masks[0].reshape(stems, frames, freqs, channels, 2).permute(0, 3, 2, 1, 4)  # (stems, ch, freq, frames, 2)
    m = torch.view_as_complex(m.contiguous())
    out = s[None] * m
    window = torch.hann_window(n_fft, periodic=True)
    audio = torch.istft(out.reshape(stems * channels, freqs, frames), n_fft, hop, n_fft, window, center=True, length=length)
    return audio.reshape(stems, channels, length)
