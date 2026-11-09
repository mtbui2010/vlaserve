# Command line and Makefile

## `vlaserve`

| command | needs | does |
|---|---|---|
| `vlaserve list` | client install | aliases and bundled robot profiles |
| `vlaserve inspect MODEL` | client install | spec + licence as JSON, from metadata only |
| `vlaserve check MODEL --profile P` | client install | exit 0 if compatible, 1 with the list of problems |
| `vlaserve serve [MODEL ...] [--host] [--port 11450] [--device cuda]` | server install | start the server, preloading models |
| `vlaserve bench MODEL [-n 20] [--warmup 3] [--device]` | server install | in-process latency with synthetic inputs |

`MODEL` is an alias, a local checkpoint directory, or an HF repo id. Environment variables:
`HF_HOME` / `HF_HUB_OFFLINE` (Hugging Face cache), `VLASERVE_REGISTRY` (path of your registry
file), `CUDA_VISIBLE_DEVICES`.

## `make`

`make help` prints every target. Parameters go on the command line.

| group | targets | common parameters |
|---|---|---|
| setup | `env`, `install-client` | `ENV=vlaserve`, `TORCH_CUDA=cu128` |
| inspect | `list`, `inspect`, `check` | `MODEL`, `PROFILE`, `HF_CACHE`, `OFFLINE=1` |
| run locally | `serve`, `bench` | `MODEL`, `GPU`, `PORT`, `HOST` |
| running server | `health`, `ps`, `load`, `rm`, `reset` | `MODEL`, `URL` |
| tests | `test`, `test-gpu` | `GPU`, `HF_CACHE` |
| container | `docker`, `docker-run`, `docker-logs`, `docker-stop`, `docker-shell`, `docker-test`, `docker-test-gpu`, `docker-save` | `IMAGE`, `CONTAINER`, `MODEL`, `GPU`, `CKPT_ROOT`, `OFFLINE` |
| Docker Hub | `push-docker-next-version`, `push-docker`, `push-docker-readme` | `HUB_REPO`, `PUSH_VERSION`, `DOCKERHUB_TOKEN` |
| PyPI | `pypi` (build + smoke test, no upload), `push-pypi-next-version` | `PYPI_TOKEN`, `PYPI_REPO=testpypi` |
| simulation | `kaair-eval` | `KAAIR_CKPT`, `N`, `TAG` |
| misc | `clean`, `help` | — |

Typical session:

```bash
make docker
make docker-run GPU=3 CKPT_ROOT=/data/checkpoints MODEL=/ckpt/my_run/pretrained_model
make health && make ps
make docker-stop
```
