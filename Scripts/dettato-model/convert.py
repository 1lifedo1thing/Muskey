# Converts the transcriber network of Dettato (kobimusic/dettato, Apache-2.0) for the app, checks it against PyTorch on a
# window of a real song, and zips it for hosting. Run it through `make dettato-model AUDIO=song.wav` (16 kHz mono).
#
# Core ML runs the network's bidirectional GRUs about five times slower than Accelerate does, so the network is cut at its
# three GRUs into four Core ML models, and the GRUs' weights go into gru.bin for the app to run between them:
#   Part1: spectrogram (1, 9, 800, 288) -> next (1, 368, 200, 88), sequence (88, 200, 368) for the first GRU
#   Part2, Part3: x (the next of the part before), the GRU's output (88, 200, 384) -> next, the sequence for the next GRU
#   Part4: x, the last GRU's output, spectrogram -> maps (1, 6, 400, 88), the logits of the six heads
# gru.bin holds, for each GRU, the forward then the backward direction's weight_ih (576 x 368), weight_hh (576 x 192),
# bias_ih and bias_hh (576 each), as little-endian float32, with the gates in PyTorch's order r, z, n.
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

import coremltools as ct
import numpy as np
import soundfile as sf
import torch
from huggingface_hub import hf_hub_download
from safetensors.torch import load_file

from dettato.transcriber.model import LaneGRU, LaneNet, PitchMix

# The commit of the weights on Hugging Face that the hosted zip was made from.
REVISION = "a0d1e354d282c4ed458b83b287065587979b053e"
audio_path, out = sys.argv[1], pathlib.Path(sys.argv[2])
folder = out / "Dettato"
shutil.rmtree(folder, ignore_errors=True)
folder.mkdir(parents=True)
config = json.load(open(hf_hub_download("kobimusic/dettato", "config.json", revision=REVISION)))
net = LaneNet(**config["model"])
net.load_state_dict(load_file(hf_hub_download("kobimusic/dettato", "model.safetensors", revision=REVISION)))
net.eval()
# The parts read the network's weights from outside, so the trace holds them as constants, which can't require gradients.
net.requires_grad_(False)
(folder / "config.json").write_text(json.dumps(config, indent=1))

# The pitch mixing of each block as one matrix per channel, made once: Core ML has no einsum of this shape.
for module in net.modules():
    if isinstance(module, PitchMix):
        matrix = torch.einsum("ck,kij->cij", module.taps.detach(), module.S).transpose(1, 2).contiguous()
        module.register_buffer("matrix", matrix, persistent=False)
        module.forward = (lambda m: (lambda x: torch.matmul(x, m.matrix)))(module)

layers = list(net.layers)
cuts = [i for i, layer in enumerate(layers) if isinstance(layer, LaneGRU)]
assert len(cuts) == 3 and cuts[-1] == len(layers) - 1, cuts


def sequence(x, gru):
    batch, channels, frames, lanes = x.shape
    return gru.ln(x.permute(0, 3, 2, 1).reshape(batch * lanes, frames, channels))


def merge(x, output, gru):
    batch, channels, frames, lanes = x.shape
    return x + gru.out(output).view(batch, lanes, frames, channels).permute(0, 3, 2, 1)


def stem(spectrogram):
    return net.stem(spectrogram)[:, :, :, :net.n_lanes]


class First(torch.nn.Module):
    def forward(self, spectrogram):
        h = net.down(stem(spectrogram))
        for layer in layers[:cuts[0]]:
            h = layer(h)
        return h, sequence(h, layers[cuts[0]])


class Middle(torch.nn.Module):
    def __init__(self, part):
        super().__init__()
        self.part = part

    def forward(self, x, output):
        h = merge(x, output, layers[cuts[self.part]])
        for layer in layers[cuts[self.part] + 1:cuts[self.part + 1]]:
            h = layer(h)
        return h, sequence(h, layers[cuts[self.part + 1]])


class Last(torch.nn.Module):
    def forward(self, x, output, spectrogram):
        h = merge(x, output, layers[cuts[-1]])
        skip = stem(spectrogram)
        h = net.up_norm(h.repeat_interleave(2, dim=2)[:, :, :skip.shape[2]] + skip)
        for layer in net.refine:
            h = layer(h)
        return net.head(h[:, :, :, :88])


def gru_numpy(seq, gru):
    """The GRU as the app runs it, in NumPy, to check the equations against PyTorch's."""
    hidden = gru.hidden_size
    outputs = []
    for suffix, reverse in (("", False), ("_reverse", True)):
        w_ih, w_hh = getattr(gru, "weight_ih_l0" + suffix).detach().numpy(), getattr(gru, "weight_hh_l0" + suffix).detach().numpy()
        b_ih, b_hh = getattr(gru, "bias_ih_l0" + suffix).detach().numpy(), getattr(gru, "bias_hh_l0" + suffix).detach().numpy()
        projected = seq @ w_ih.T + b_ih
        h = np.zeros((seq.shape[0], hidden), np.float32)
        result = np.zeros((seq.shape[0], seq.shape[1], hidden), np.float32)
        for t in (range(seq.shape[1] - 1, -1, -1) if reverse else range(seq.shape[1])):
            g = h @ w_hh.T + b_hh
            r = 1 / (1 + np.exp(-(projected[:, t, :hidden] + g[:, :hidden])))
            z = 1 / (1 + np.exp(-(projected[:, t, hidden:2 * hidden] + g[:, hidden:2 * hidden])))
            n = np.tanh(projected[:, t, 2 * hidden:] + r * g[:, 2 * hidden:])
            h = (1 - z) * n + z * h
            result[:, t] = h
        outputs.append(result)
    return np.concatenate(outputs, -1)


audio, rate = sf.read(audio_path, dtype="float32")
assert rate == 16000 and audio.ndim == 1, "the audio must be 16 kHz mono"
start = min(len(audio) - 128000, 60 * 16000)
window = np.ascontiguousarray(audio[start:start + 128000])
convert = dict(minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
with torch.no_grad():
    spectrogram = net.front(torch.from_numpy(window)[None]).contiguous()
    full = torch.sigmoid(torch.stack(list(net(torch.from_numpy(window)[None]).values()), 1)).numpy()

    x, seq = First()(spectrogram)
    parts = [("Part1", First(), (spectrogram,), ["spectrogram"], ["next", "sequence"])]
    for index in range(len(cuts)):
        gru = layers[cuts[index]].gru
        torch_output, _ = gru(seq)
        numpy_output = gru_numpy(seq.numpy(), gru)
        print(f"GRU {index + 1}: NumPy against PyTorch, largest difference {np.abs(numpy_output - torch_output.numpy()).max():.6f}")
        if index < len(cuts) - 1:
            module = Middle(index)
            example = (x, torch_output)
            parts.append((f"Part{index + 2}", module, example, ["x", "output"], ["next", "sequence"]))
            x, seq = module(*example)
        else:
            module = Last()
            example = (x, torch_output, spectrogram)
            parts.append(("Part4", module, example, ["x", "output", "spectrogram"], ["maps"]))
            split = torch.sigmoid(module(*example)).numpy()
    print(f"four parts against the whole network: largest difference {np.abs(split - full).max():.6f}")

    models = {}
    for name, module, example, inputs, outputs in parts:
        traced = torch.jit.trace(module.eval(), example)
        model = ct.convert(traced, inputs=[ct.TensorType(name=n, shape=e.shape, dtype=np.float32) for n, e in zip(inputs, example)],
                           outputs=[ct.TensorType(name=n, dtype=np.float32) for n in outputs], **convert)
        model.short_description = f"Dettato transcriber (kobimusic/dettato, Apache-2.0), {name} of 4"
        model.save(str(folder / f"{name}.mlpackage"))
        models[name] = model

    # The whole chain in Core ML, with the GRUs in NumPy as the app runs them.
    result = models["Part1"].predict({"spectrogram": spectrogram.numpy()})
    for index in range(len(cuts)):
        output = gru_numpy(result["sequence"], layers[cuts[index]].gru)
        if index < len(cuts) - 1:
            result = models[f"Part{index + 2}"].predict({"x": result["next"], "output": output})
        else:
            result = models["Part4"].predict({"x": result["next"], "output": output, "spectrogram": spectrogram.numpy()})
    got = 1 / (1 + np.exp(-result["maps"]))
    print(f"Core ML and NumPy against PyTorch: largest difference of a probability {np.abs(got - full).max():.4f}")
    print(f"onset frames over 0.5: PyTorch {(full[0, 0] > 0.5).sum()}, Core ML {(got[0, 0] > 0.5).sum()}")

    with open(folder / "gru.bin", "wb") as file:
        for cut in cuts:
            gru = layers[cut].gru
            for suffix in ("", "_reverse"):
                for name in ("weight_ih_l0", "weight_hh_l0", "bias_ih_l0", "bias_hh_l0"):
                    file.write(getattr(gru, name + suffix).detach().numpy().astype("<f4").tobytes())

window.tofile(out / "check-window.f32")
spectrogram.numpy().astype(np.float32).tofile(out / "check-spectrogram.f32")
full.astype(np.float32).tofile(out / "check-maps.f32")

archive = out / "Dettato.zip"
archive.unlink(missing_ok=True)
subprocess.run(["ditto", "-c", "-k", "--keepParent", str(folder), str(archive)], check=True)
print(f"{archive}: {archive.stat().st_size} bytes, sha256 {hashlib.sha256(archive.read_bytes()).hexdigest()}")
