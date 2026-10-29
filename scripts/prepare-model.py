#!/usr/bin/env python3
"""Download a pinned local model. Inference never calls this script."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

MODEL = "mlx-community/Qwen3.5-4B-4bit"
REVISION = "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c"
ROOT = Path(__file__).resolve().parents[1] / ".models" / "Qwen3.5-4B-4bit"
FILES = {"config.json", "model.safetensors", "model.safetensors.index.json",
         "tokenizer.json", "tokenizer_config.json", "vocab.json", "chat_template.jinja"}
if "--speech" in sys.argv:
    MODEL = "mlx-community/Qwen3-ASR-1.7B-8bit"
    REVISION = "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
    ROOT = ROOT.parent / "Qwen3-ASR-1.7B-8bit"
    FILES = {"config.json", "model.safetensors", "model.safetensors.index.json",
             "tokenizer_config.json", "vocab.json", "merges.txt", "chat_template.json",
             "preprocessor_config.json", "generation_config.json"}
ROOT.mkdir(parents=True, exist_ok=True)
with urllib.request.urlopen(f"https://huggingface.co/api/models/{MODEL}/revision/{REVISION}?blobs=true") as response:
    metadata = json.load(response)
for item in metadata["siblings"]:
    name = item["rfilename"]
    if name not in FILES:
        continue
    target = ROOT / name
    expected_size = item["size"]
    sha256 = item.get("lfs", {}).get("sha256")
    if not target.exists() or target.stat().st_size != expected_size:
        temporary = target.with_suffix(target.suffix + ".partial")
        print(f"Downloading {name} ({expected_size:,} bytes)", flush=True)
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--continue-at", "-",
                        "--output", str(temporary),
                        f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{name}"], check=True)
        if temporary.stat().st_size != expected_size:
            raise RuntimeError(f"Wrong file size: {temporary}")
        temporary.rename(target)
    if sha256:
        with target.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != sha256:
            raise RuntimeError(f"SHA-256 mismatch: {target}")
    print(f"Verified {name}", flush=True)
print(f"Ready: {ROOT}", flush=True)
