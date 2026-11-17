# Converts a BS-RoFormer checkpoint to the Core ML model that Muskey downloads, for a fixed number of frames, checks
# it against PyTorch, and zips it for hosting. Run it through `make stems-model` or `make winds-model`.
# Arguments: the checkpoint, its YAML config, the output folder, the package name, and optionally the heads to keep,
# comma-separated names from the config's instruments (every head when left out).
import sys, time, yaml, subprocess, hashlib, pathlib, numpy as np, torch, coremltools as ct
import bsr_torch

ckpt, config, out, name = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4]
frames = 388  # about 4.5 seconds, the window that Muskey separates
cfg = yaml.unsafe_load(open(config))
instruments = cfg["training"]["instruments"]
heads = [instruments.index(h) for h in sys.argv[5].split(",")] if len(sys.argv) > 5 else None
model = bsr_torch.load(ckpt, cfg["model"]["freqs_per_bands"], frames, stems=len(instruments),
                       mlp_expansion=cfg["model"].get("mlp_expansion_factor", 4), heads=heads)
print(f"heads: {', '.join(instruments[i] for i in heads) if heads else ', '.join(instruments)}")
# Any spectrogram traces the same graph; a quiet random one also checks the masks against PyTorch.
torch.manual_seed(0)
example = torch.randn(1, frames, sum(cfg["model"]["freqs_per_bands"]) * 4) * 0.1
started = time.time()
traced = torch.jit.trace(model, example)
mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="spec", shape=example.shape, dtype=np.float32)],
                     outputs=[ct.TensorType(name="masks", dtype=np.float32)],
                     minimum_deployment_target=ct.target.macOS15,
                     compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
print(f"converted in {time.time() - started:.0f}s")
mlmodel.short_description = f"{name} stem masks"
out.mkdir(parents=True, exist_ok=True)
package = out / f"{name}-{frames}.mlpackage"
mlmodel.save(str(package))
with torch.no_grad():
    reference = model(example).numpy()
masks = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_GPU).predict({"spec": example.numpy()})["masks"]
error = np.sum((masks - reference) ** 2) / np.sum(reference ** 2)
print(f"masks {10 * np.log10(1 / max(error, 1e-20)):.1f} dB above the difference from PyTorch")
archive = out / f"{package.name}.zip"
archive.unlink(missing_ok=True)
subprocess.run(["ditto", "-c", "-k", "--keepParent", package.name, archive.name], cwd=out, check=True)
print(f"{archive}: {archive.stat().st_size} bytes, sha256 {hashlib.sha256(archive.read_bytes()).hexdigest()}")
