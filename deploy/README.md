# Running vlaserve in a container

The server (GPU, torch, LeRobot: ~8-10 GB) goes in the container. The robot computer installs
only the client (`pip install vlaserve`, ~80 MB, no torch) and talks HTTP to it.

```
robot PC                           GPU box / Jetson
pip install vlaserve      HTTP    docker run mtbui2010/vlaserve
PolicyClient, ChunkExecutor  ──►   serve <model>       ◄── HF cache / checkpoint dir (mounted)
```

## Get it

```bash
docker pull mtbui2010/vlaserve:latest     # Docker Hub; tags: latest, gpu-cu128, vX.Y.Z, vX.Y.Z-gpu-cu128
```

Documentation: https://mtbui2010.github.io/vlaserve/ · source: https://github.com/mtbui2010/vlaserve

## Build from source

```bash
docker build -f deploy/Dockerfile -t vlaserve:gpu-cu128 .
# Host driver older than CUDA 12.8 (driver < 570)?
docker build -f deploy/Dockerfile --build-arg TORCH_CUDA=cu126 -t vlaserve:gpu-cu126 .
```

## Run

```bash
# A model from the HF cache (the same cache LeRobot and huggingface-cli use)
docker run -d --gpus all -p 11450:11450 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  --name vlaserve mtbui2010/vlaserve:latest \
  serve --host 0.0.0.0 pi05-libero

# A local training output: mount it and serve the path
docker run -d --gpus all -p 11450:11450 \
  -v /data/runs/my_run/checkpoints/last/pretrained_model:/models/my_run:ro \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  mtbui2010/vlaserve:latest serve --host 0.0.0.0 /models/my_run
```

- **The HF cache mount is needed even for local checkpoints:** the tokenizer (e.g.
  `google/paligemma-3b-pt-224` for pi0/pi0.5) is fetched by name.
- **Offline / air-gapped:** add `-e HF_HUB_OFFLINE=1`; everything must already be in the cache.
- **Pick a GPU:** `--gpus '"device=3"'`.
- **Startup takes minutes** (pi0.5 ~2.5 min from a local disk, more from NFS). The healthcheck
  allows 10 min; `docker ps` shows `(health: starting)` until the model is in memory.
- **Port exposure:** `--host 0.0.0.0` is needed inside the container. Publish the port only on a
  trusted network (`-p 127.0.0.1:11450:11450` to keep it local): anyone who reaches it can move the robot.
- **Several models:** `serve --host 0.0.0.0 model-a model-b`, or load later with
  `POST /v1/models/load`.

Your own aliases: mount a registry file and point to it,
`-v ~/.config/vlaserve:/root/.config/vlaserve:ro`.

## Verify an image

```bash
docker run --rm --gpus '"device=3"' -e HF_HUB_OFFLINE=1 \
  -v /mnt/nas/huggingface:/root/.cache/huggingface \
  --entrypoint python mtbui2010/vlaserve:latest -m pytest -m gpu -q tests/test_gpu_parity.py
```

## Not done yet

- Jetson images (Orin = JetPack 6, Thor = JetPack 7) need NVIDIA's L4T PyTorch base for each
  JetPack, and LeRobot's aarch64 dependencies are untested. Build on the device.
- No image is published to a registry yet.
