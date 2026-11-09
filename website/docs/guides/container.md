# Run it in a container

The server needs PyTorch, CUDA libraries and LeRobot: about 8.5 GB that must match each other and
the GPU driver. The container ships that combination already tested, so the host only needs
Docker and an NVIDIA driver.

## Get the image

```bash
docker pull mtbui2010/vlaserve:latest        # from Docker Hub (≈ 8.5 GB)
```

| tag | what |
|---|---|
| `latest`, `gpu-cu128` | newest release, CUDA 12.8 build |
| `vX.Y.Z`, `vX.Y.Z-gpu-cu128` | a fixed release — pin this in production |

Or build it from source:

```bash
make docker                          # → vlaserve:gpu-cu128 (local)
make docker TORCH_CUDA=cu126         # host driver older than 570
make docker-test                     # fast tests inside the image
```

`make docker-run` uses the local build; add `IMAGE=mtbui2010/vlaserve:latest` to run the
published one.

The image uses `python:3.12-slim` as base, not `nvidia/cuda`: the CUDA and cuDNN libraries come
inside the torch wheel, and the driver is injected by the NVIDIA runtime at `docker run`.
**No model weights are baked in.**

## Run

```bash
make docker-run MODEL=<name or path> [GPU=3] [CKPT_ROOT=/host/checkpoints] [PORT=11450] [OFFLINE=1]
```

which runs, for example:

```bash
docker run -d --name vlaserve --gpus '"device=3"' -p 127.0.0.1:11450:11450 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -v /mnt/nas/lerobot_shared/kaair_sim/checkpoints:/ckpt:ro \
  mtbui2010/vlaserve:latest serve --host 0.0.0.0 \
  /ckpt/smolvla_open_drawer_500_20260924/checkpoints/020000/pretrained_model
```

| Part | Why |
|---|---|
| `--gpus '"device=3"'` | pick a GPU; on a shared machine check `nvidia-smi` first |
| `-p 127.0.0.1:11450:11450` | only this machine can call it. Drop `127.0.0.1:` to let a robot on the LAN connect — anyone who reaches the port can move the robot |
| `-v ~/.cache/huggingface:…` | **always needed**, even for local checkpoints: tokenizers (PaliGemma, SmolVLM2) are fetched by name |
| `-v …:/ckpt:ro` | your checkpoints, read-only. The model name is then the path **inside** the container (`/ckpt/...`) |
| `--host 0.0.0.0` | required inside a container |
| `-e HF_HUB_OFFLINE=1` (`OFFLINE=1`) | no internet; everything must already be in the cache |

## Watch it start

```bash
make docker-logs        # wait for: "loaded <model> on cuda in 98.7s"
make health
make ps
```

`docker ps` shows `(health: starting)` until the model is in memory; the healthcheck allows ten
minutes.

## Manage models without restarting

```bash
make load  MODEL=lerobot/pi05_libero_finetuned
make rm    MODEL=lerobot/pi05_libero_finetuned
make reset MODEL=...                       # start of a new episode
make docker-shell                          # then: vlaserve inspect /ckpt/...
make docker-stop
```

## Another machine

`docker pull mtbui2010/vlaserve:latest`. Without internet access, copy the image by hand:

```bash
make docker-save                           # → vlaserve-gpu-cu128.tar.gz
docker load < vlaserve-gpu-cu128.tar.gz   # on the other machine
```

## Publishing a new version (maintainers)

```bash
docker login                               # once
make push-docker-next-version
```

Reads the newest `vX.Y.Z` tag on Docker Hub, bumps the patch number (the first release uses the
version in `pyproject.toml`), writes it into `pyproject.toml` and `vlaserve/__init__.py`, builds
the image with that version as a label, runs the tests inside it — a failure stops before
anything is pushed — and pushes `vX.Y.Z`, `vX.Y.Z-gpu-cu128`, `gpu-cu128` and `latest`. Commit
the version bump afterwards. `make push-docker PUSH_VERSION=vX.Y.Z` pushes an image you already
built; `make push-docker-readme DOCKERHUB_TOKEN=…` publishes `deploy/README.md` as the Docker Hub
overview.

The client package goes to PyPI the same way: `make push-pypi-next-version PYPI_TOKEN=pypi-…`
(next version from PyPI, build, `twine check`, install the wheel into a fresh venv and check it
imports without torch, then upload). `make pypi` does everything except the upload.

## Verify an image end to end

```bash
make docker-test-gpu GPU=3 HF_CACHE=/mnt/nas/huggingface
```

runs the [parity tests](../how-it-works/correctness.md) inside the image: each served chunk
must equal the chunk LeRobot's own policy server produces, bit for bit.

!!! warning "Jetson"
    The image is x86-64 only. Jetson Orin (JetPack 6) and Thor (JetPack 7) need NVIDIA's L4T
    PyTorch base for each JetPack version; see [Deploying to hardware](../learn/08-deployment.md).
