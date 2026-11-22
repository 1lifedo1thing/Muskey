# Converts the CTC model that fits lyrics onto the vocals (facebook/omniASR-CTC-300M, Apache-2.0) for the app, checks it
# against PyTorch on a window of real vocals, and zips it for hosting. Run it through
# `make aligner-model AUDIO=vocals.wav` (16 kHz mono, at least 30 seconds, with singing in it).
#
# The model reads 30 seconds of audio that has zero mean and unit variance, and writes for each 20 ms the
# log-probability of every character it knows, 1499 rows of 9812. labels.json lists the characters in the order of the
# columns. The first one, <s>, is the CTC blank.
#
# The weights are kept as 8-bit numbers, which halves the download. The check at the end prints how far that and the
# half-precision arithmetic move the letters from PyTorch's.
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import soundfile as sf
import torch

import omnilingual_asr  # noqa: F401, registers the model cards with fairseq2
from fairseq2.data.tokenizers.hub import load_tokenizer
from fairseq2.models.hub import load_model
from fairseq2.nn.batch_layout import BatchLayout

CARD, TOKENIZER = "omniASR_CTC_300M", "omniASR_tokenizer_v1"
WINDOW = 480000
audio_path, out = sys.argv[1], pathlib.Path(sys.argv[2])
folder = out / "Aligner"
shutil.rmtree(folder, ignore_errors=True)
folder.mkdir(parents=True)

net = load_model(CARD, device=torch.device("cpu"), dtype=torch.float32).eval()
net.requires_grad_(False)
tokenizer = load_tokenizer(TOKENIZER)
labels = [tokenizer._model.index_to_token(i) for i in range(tokenizer.vocab_info.size)]
(folder / "labels.json").write_text(json.dumps(labels, ensure_ascii=False))
# The licence asks that a copy of it and a note of what was changed go with the weights.
(folder / "NOTICE.txt").write_text(
    "omniASR-CTC-300M, Copyright 2025 (c) Meta Platforms, Inc. and affiliates.\n"
    "Licensed under the Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0\n"
    "From https://github.com/facebookresearch/omnilingual-asr\n\n"
    "Changes: converted to Core ML for windows of 30 seconds, with half-precision arithmetic, 8-bit weights and a\n"
    "log-softmax over the characters at the end.\n")


class Reader(torch.nn.Module):
    def forward(self, audio):
        layout = BatchLayout(audio.shape, seq_lens=[audio.shape[1]])
        features, layout, _ = net.encoder_frontend.extract_features(audio, layout)
        features, _ = net.encoder_frontend.process_features(features, layout, None)
        return torch.log_softmax(net.final_proj(net.encoder(features, layout)), -1)


audio, rate = sf.read(audio_path, dtype="float32")
assert rate == 16000 and audio.ndim == 1 and len(audio) >= WINDOW, "the audio must be 16 kHz mono and at least 30 seconds long"
# The loudest window of the file, so the check runs on singing and not on a quiet intro.
starts = range(0, len(audio) - WINDOW + 1, 160000)
start = max(starts, key=lambda s: float(np.square(audio[s:s + WINDOW]).mean()))
window = audio[start:start + WINDOW]
window = ((window - window.mean()) / (window.std() + 1e-7)).astype(np.float32)
example = torch.from_numpy(window)[None]

with torch.no_grad():
    reader = Reader().eval()
    reference = reader(example).numpy()
    traced = torch.jit.trace(reader, example)
    model = ct.convert(traced, inputs=[ct.TensorType(name="audio", shape=example.shape, dtype=np.float32)],
                       outputs=[ct.TensorType(name="letters", dtype=np.float32)], minimum_deployment_target=ct.target.macOS15,
                       compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    quantizer = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=2048)
    model = cto.linear_quantize_weights(model, cto.OptimizationConfig(global_config=quantizer))
model.short_description = "Reads sung words for timing lyrics (facebook/omniASR-CTC-300M, Apache-2.0)"
model.save(str(folder / "Aligner.mlpackage"))


def spell(letters):
    ids = letters[0].argmax(-1)
    return "".join(labels[i] for k, i in enumerate(ids) if i != 0 and (k == 0 or ids[k - 1] != i))


print("PyTorch:", spell(reference))
for name, units in (("CPU", ct.ComputeUnit.CPU_ONLY), ("GPU", ct.ComputeUnit.CPU_AND_GPU), ("Neural Engine", ct.ComputeUnit.CPU_AND_NE)):
    loaded = ct.models.MLModel(str(folder / "Aligner.mlpackage"), compute_units=units)
    got = loaded.predict({"audio": window[None]})["letters"]
    same = (got[0].argmax(-1) == reference[0].argmax(-1)).mean()
    # The difference that matters is in the letters that are likely, since the unlikely ones never join a path.
    likely = reference > -5
    print(f"{name}: same best letter in {same * 100:.1f}% of frames, largest difference of a likely log-probability "
          f"{np.abs(got - reference)[likely].max():.3f}, spells: {spell(got)}")

window.tofile(out / "check-window.f32")
archive = out / "Aligner.zip"
archive.unlink(missing_ok=True)
subprocess.run(["ditto", "-c", "-k", "--keepParent", str(folder), str(archive)], check=True)
print(f"{archive}: {archive.stat().st_size} bytes, sha256 {hashlib.sha256(archive.read_bytes()).hexdigest()}")
