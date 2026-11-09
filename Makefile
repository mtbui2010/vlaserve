# Makefile — vlaserve
# `make help` lists every target. Parameters go on the command line: make serve MODEL=pi05-libero GPU=3

# --- Environment (local, non-container targets) ---
CONDA    ?= conda
ENV      ?= vlaserve
ENV_BIN  ?= $(shell $(CONDA) env list 2>/dev/null | awk '$$1=="$(ENV)" {print $$NF}')/bin
# The torch build must match the host driver (this host: CUDA 12.8). PyPI's default is newer.
TORCH_CUDA ?= cu128
TORCH_VERSION ?= 2.10.0
TORCHVISION_VERSION ?= 0.25.0

# --- Defaults for serve / inspect / check / bench ---
MODEL    ?= pi05-libero
PROFILE  ?=
HOST     ?= 127.0.0.1
PORT     ?= 11450
URL      ?= http://127.0.0.1:$(PORT)
# GPU index; empty = all GPUs (docker) / whatever CUDA picks (local).
GPU      ?=
HF_CACHE ?= $(HOME)/.cache/huggingface
OFFLINE  ?= 0

# --- Docker ---
IMAGE     ?= vlaserve:gpu-$(TORCH_CUDA)
CONTAINER ?= vlaserve
# Docker Hub: images are pushed as $(HUB_REPO):<tag> (see push-docker / push-docker-next-version).
DOCKER_HUB_USER ?= mtbui2010
HUB_REPO        ?= $(DOCKER_HUB_USER)/vlaserve
# Version baked into the image label; push-docker-next-version sets it from Docker Hub.
VERSION         ?= $(shell sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
# Optional host directory of checkpoints, mounted read-only at /ckpt; then MODEL=/ckpt/<...>.
CKPT_ROOT ?=
DOCKER_GPUS := $(if $(GPU),'"device=$(GPU)"',all)

LOCAL_ENV := $(if $(GPU),CUDA_VISIBLE_DEVICES=$(GPU)) $(if $(filter 1,$(OFFLINE)),HF_HUB_OFFLINE=1) HF_HOME=$(HF_CACHE)

.PHONY: help env install-client list inspect check serve bench ps load rm reset health \
        test test-gpu docker docker-run docker-logs docker-stop docker-shell docker-test \
        docker-test-gpu docker-save push-docker push-docker-next-version push-docker-readme pypi push-pypi-next-version kaair-eval clean

help: ## Print the list of targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

## --- Setup ---

env: ## Create the conda env ENV=vlaserve with torch (TORCH_CUDA=cu128) + server + tests
	$(CONDA) create -y -n $(ENV) python=3.12
	$(MAKE) --no-print-directory _install ENV_BIN="$$($(CONDA) env list | awk '$$1=="$(ENV)" {print $$NF}')/bin"

_install:
	$(ENV_BIN)/python -m pip install torch==$(TORCH_VERSION) torchvision==$(TORCHVISION_VERSION) \
		--index-url https://download.pytorch.org/whl/$(TORCH_CUDA)
	$(ENV_BIN)/python -m pip install -e '.[server,test]' torch==$(TORCH_VERSION) \
		torchvision==$(TORCHVISION_VERSION) --extra-index-url https://download.pytorch.org/whl/$(TORCH_CUDA)
	$(ENV_BIN)/python -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"

install-client: ## Robot side: install only the light client into the current Python (no torch)
	python -m pip install .

## --- Inspect (no GPU, works with the client-only install) ---

list: ## List model aliases and robot profiles
	$(LOCAL_ENV) $(ENV_BIN)/vlaserve list

inspect: ## Cameras, state/action size, chunk, licence: make inspect MODEL=<alias|repo|path>
	$(LOCAL_ENV) $(ENV_BIN)/vlaserve inspect $(MODEL)

check: ## Robot profile vs policy: make check MODEL=... PROFILE=openarm-bimanual
	@test -n "$(PROFILE)" || { echo "usage: make check MODEL=... PROFILE=<name|file.yaml>"; exit 2; }
	$(LOCAL_ENV) $(ENV_BIN)/vlaserve check $(MODEL) --profile $(PROFILE)

## --- Run locally (conda env) ---

serve: ## Start the server: make serve MODEL=... [GPU=3] [PORT=11450] [HOST=127.0.0.1] [OFFLINE=1]
	$(LOCAL_ENV) $(ENV_BIN)/vlaserve serve --host $(HOST) --port $(PORT) $(MODEL)

bench: ## In-process latency, synthetic inputs: make bench MODEL=... [GPU=3]
	$(LOCAL_ENV) $(ENV_BIN)/vlaserve bench $(MODEL)

## --- Talk to a running server (local or container) ---

health: ## GET /health [URL=http://127.0.0.1:11450]
	@curl -sf $(URL)/health && echo || { echo "no server at $(URL)"; exit 1; }

ps: ## Models loaded in the running server
	@curl -sf $(URL)/v1/models | python3 -c "import json,sys; [print(f\"{m['model']}  {m['device']}  calls={m['calls']}  licence={m['license']}\") for m in json.load(sys.stdin)['models']] or print('(none loaded)')"

load: ## Load a model into the running server: make load MODEL=...
	curl -sf -X POST $(URL)/v1/models/load -H 'content-type: application/json' -d '{"model":"$(MODEL)"}' >/dev/null && echo "loaded $(MODEL)"

rm: ## Unload a model from the running server: make rm MODEL=...
	curl -sf -X POST $(URL)/v1/models/unload -H 'content-type: application/json' -d '{"model":"$(MODEL)"}' && echo

reset: ## Reset a model's episode state: make reset MODEL=...
	curl -sf -X POST $(URL)/v1/models/reset -H 'content-type: application/json' -d '{"model":"$(MODEL)"}' && echo

## --- Tests ---

test: ## Fast tests (no GPU)
	HF_HUB_OFFLINE=1 $(ENV_BIN)/python -m pytest -q

test-gpu: ## Parity vs LeRobot on real checkpoints: make test-gpu GPU=3 [HF_CACHE=/mnt/nas/huggingface]
	$(LOCAL_ENV) HF_HUB_OFFLINE=1 $(ENV_BIN)/python -m pytest -m gpu -s -q tests/test_gpu_parity.py

## --- Docker ---

docker: ## Build the GPU server image IMAGE=vlaserve:gpu-cu128 [TORCH_CUDA=cu126]
	docker build -f deploy/Dockerfile --build-arg TORCH_CUDA=$(TORCH_CUDA) \
		--build-arg TORCH_VERSION=$(TORCH_VERSION) --build-arg TORCHVISION_VERSION=$(TORCHVISION_VERSION) \
		--build-arg VERSION=$(VERSION) -t $(IMAGE) .

docker-run: ## Start the server container: make docker-run MODEL=... [GPU=3] [CKPT_ROOT=/host/ckpts] [PORT] [OFFLINE=1]
	@if docker ps -a --format '{{.Names}}' | grep -qx '$(CONTAINER)'; then \
		echo "container '$(CONTAINER)' exists; run 'make docker-stop' first or set CONTAINER=<name>"; exit 1; fi
	docker run -d --name $(CONTAINER) --gpus $(DOCKER_GPUS) \
		-p $(HOST):$(PORT):11450 \
		-v $(HF_CACHE):/root/.cache/huggingface \
		$(if $(CKPT_ROOT),-v $(CKPT_ROOT):/ckpt:ro) \
		$(if $(wildcard $(HOME)/.config/vlaserve),-v $(HOME)/.config/vlaserve:/root/.config/vlaserve:ro) \
		$(if $(filter 1,$(OFFLINE)),-e HF_HUB_OFFLINE=1) \
		$(IMAGE) serve --host 0.0.0.0 $(MODEL)
	@echo "starting; loading takes 1.5-5 min. Watch: make docker-logs   Ready: make health"

docker-logs: ## Follow the server container's log
	docker logs -f $(CONTAINER)

docker-stop: ## Stop and remove the server container
	-docker stop $(CONTAINER) >/dev/null && docker rm $(CONTAINER) >/dev/null && echo "removed $(CONTAINER)"

docker-shell: ## Shell inside the running server container
	docker exec -it $(CONTAINER) bash

docker-test: ## Fast tests inside the image
	docker run --rm -e HF_HUB_OFFLINE=1 --entrypoint python $(IMAGE) -m pytest -q -p no:warnings tests

docker-test-gpu: ## Parity tests inside the image: make docker-test-gpu GPU=3 [HF_CACHE=/mnt/nas/huggingface]
	docker run --rm --gpus $(DOCKER_GPUS) -e HF_HUB_OFFLINE=1 -v $(HF_CACHE):/root/.cache/huggingface \
		--entrypoint python $(IMAGE) -m pytest -m gpu -s -q -p no:warnings tests/test_gpu_parity.py

docker-save: ## Export the image for another machine: vlaserve-<tag>.tar.gz (~8.5 GB before gzip)
	docker save $(IMAGE) | gzip > $(subst :,-,$(IMAGE)).tar.gz
	@echo "on the other machine: docker load < $(subst :,-,$(IMAGE)).tar.gz"

## --- Docker Hub ---

push-docker: ## Tag the local IMAGE and push it: make push-docker PUSH_VERSION=v0.1.0 [HUB_REPO=user/vlaserve]
	@test -n "$(PUSH_VERSION)" || { echo "push-docker: set PUSH_VERSION=vX.Y.Z"; exit 1; }
	@echo "$(PUSH_VERSION)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "PUSH_VERSION must look like v1.2.3"; exit 1; }
	@echo "=== Tagging $(IMAGE) for $(HUB_REPO) ==="
	docker tag $(IMAGE) $(HUB_REPO):$(PUSH_VERSION)
	docker tag $(IMAGE) $(HUB_REPO):$(PUSH_VERSION)-gpu-$(TORCH_CUDA)
	docker tag $(IMAGE) $(HUB_REPO):gpu-$(TORCH_CUDA)
	docker tag $(IMAGE) $(HUB_REPO):latest
	@echo "=== Pushing (layers already on the Hub are skipped) ==="
	docker push $(HUB_REPO):$(PUSH_VERSION)
	docker push $(HUB_REPO):$(PUSH_VERSION)-gpu-$(TORCH_CUDA)
	docker push $(HUB_REPO):gpu-$(TORCH_CUDA)
	docker push $(HUB_REPO):latest
	@echo "=== Pushed ==="
	@echo "  $(HUB_REPO):$(PUSH_VERSION)  (= $(PUSH_VERSION)-gpu-$(TORCH_CUDA) = gpu-$(TORCH_CUDA) = latest)"
	@echo "  https://hub.docker.com/r/$(HUB_REPO)"

push-docker-next-version: ## Next version from Docker Hub (patch+1; first push = pyproject version), set it in source, build, test, push
	@set -e; \
	echo "=== Querying Docker Hub for $(HUB_REPO) tags ==="; \
	LATEST=$$(curl -s "https://hub.docker.com/v2/repositories/$(HUB_REPO)/tags/?page_size=100" | python3 -c "import sys,json,re; \
	  d=json.load(sys.stdin); tags=[t['name'] for t in d.get('results',[]) if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',t['name'])]; \
	  tags.sort(key=lambda x:[int(n) for n in x[1:].split('.')]); print(tags[-1] if tags else '')"); \
	if [ -z "$$LATEST" ]; then \
	    NEXT="v$(VERSION)"; echo "  no version tag on the Hub yet -> first release $$NEXT (pyproject.toml)"; \
	else \
	    NEXT=$$(echo "$$LATEST" | python3 -c "import sys; v=sys.stdin.read().strip().lstrip('v').split('.'); v[2]=str(int(v[2])+1); print('v'+'.'.join(v))"); \
	    echo "  latest on the Hub: $$LATEST  ->  next: $$NEXT"; \
	fi; \
	VER=$${NEXT#v}; \
	echo "=== Setting version $$VER in pyproject.toml and vlaserve/__init__.py ==="; \
	sed -i "s|^version = \".*\"|version = \"$$VER\"|" pyproject.toml; \
	sed -i "s|^__version__ = \".*\"|__version__ = \"$$VER\"|" vlaserve/__init__.py; \
	echo "=== Building $(IMAGE) ($$NEXT) ==="; \
	$(MAKE) --no-print-directory docker VERSION=$$VER; \
	echo "=== Tests inside the image (a failure stops here, nothing is pushed) ==="; \
	$(MAKE) --no-print-directory docker-test; \
	echo "=== Pushing $$NEXT ==="; \
	$(MAKE) --no-print-directory push-docker PUSH_VERSION=$$NEXT; \
	echo ""; echo "=== Done: $(HUB_REPO):$$NEXT. Commit the version bump (pyproject.toml, vlaserve/__init__.py). ==="

push-docker-readme: ## Publish deploy/README.md as the Docker Hub "Overview" (needs DOCKERHUB_TOKEN)
	@test -n "$(DOCKERHUB_TOKEN)" || { echo "push-docker-readme: set DOCKERHUB_TOKEN (a Docker Hub access token)"; exit 1; }
	@DOCKERHUB_TOKEN='$(DOCKERHUB_TOKEN)' DOCKER_HUB_USER='$(DOCKER_HUB_USER)' HUB_REPO='$(HUB_REPO)' python3 -c "import json, os, urllib.request as u; \
	tok = json.load(u.urlopen(u.Request('https://hub.docker.com/v2/users/login/', data=json.dumps({'username': os.environ['DOCKER_HUB_USER'], 'password': os.environ['DOCKERHUB_TOKEN']}).encode(), headers={'Content-Type': 'application/json'})))['token']; \
	desc = open('deploy/README.md').read(); \
	u.urlopen(u.Request('https://hub.docker.com/v2/repositories/%s/' % os.environ['HUB_REPO'], data=json.dumps({'full_description': desc, 'description': 'Serve trained Vision-Language-Action robot policies locally (LeRobot, GPU).'}).encode(), method='PATCH', headers={'Content-Type': 'application/json', 'Authorization': 'JWT ' + tok})).read(); \
	print('Overview updated (%d chars): https://hub.docker.com/r/' % len(desc) + os.environ['HUB_REPO'])"

## --- PyPI (the client package; the server extra comes with it) ---

# Python used to build and upload (needs nothing but pip; build + twine are installed into it).
PYTHON    ?= $(ENV_BIN)/python
PYPI_PKG  ?= vlaserve
# pypi or testpypi. Upload credentials: PYPI_TOKEN=pypi-... (an API token), or ~/.pypirc.
PYPI_REPO ?= pypi
PYPI_TOKEN ?=

pypi: ## Build + check the package (dist/), then install the wheel into a fresh venv and smoke-test it
	$(PYTHON) -m pip install --quiet --upgrade build twine
	rm -rf dist build *.egg-info
	$(PYTHON) -m build
	$(PYTHON) -m twine check --strict dist/*
	@echo "=== Smoke test: fresh venv, wheel only (the client must not pull torch) ==="
	@set -e; T=$$(mktemp -d); trap 'rm -rf $$T' EXIT; \
	$(PYTHON) -m venv $$T/venv; \
	$$T/venv/bin/pip install --quiet dist/*.whl; \
	$$T/venv/bin/vlaserve --help > /dev/null; \
	$$T/venv/bin/python -c "import vlaserve, vlaserve.client, vlaserve.profiles; print('  import ok, version', vlaserve.__version__)"; \
	if $$T/venv/bin/pip list 2>/dev/null | grep -iqE '^(torch|lerobot) '; then echo "ERROR: the client install pulled torch/lerobot" >&2; exit 1; fi; \
	echo "  no torch, no lerobot: OK"; ls -l dist/

push-pypi-next-version: ## Next version from PyPI (patch+1; first upload = pyproject version), set it in source, build, test, upload
	@set -e; \
	CUR=$$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml); \
	INDEX=$$( [ "$(PYPI_REPO)" = testpypi ] && echo https://test.pypi.org || echo https://pypi.org ); \
	echo "=== Querying $$INDEX for $(PYPI_PKG) (local version $$CUR) ==="; \
	CODE=$$(curl -s -o /tmp/.vlaserve-pypi.json -w '%{http_code}' "$$INDEX/pypi/$(PYPI_PKG)/json"); \
	if [ "$$CODE" = 404 ]; then RELEASED=""; \
	elif [ "$$CODE" = 200 ]; then RELEASED=$$(python3 -c "import json; print(' '.join(json.load(open('/tmp/.vlaserve-pypi.json'))['releases']))"); \
	else echo "ERROR: $$INDEX answered HTTP $$CODE; not guessing a version." >&2; exit 1; fi; \
	NEXT=$$(CUR=$$CUR RELEASED="$$RELEASED" python3 -c "import os; \
	  key = lambda v: [int(n) for n in v.split('.')]; \
	  rel = sorted((v for v in os.environ['RELEASED'].split() if all(p.isdigit() for p in v.split('.'))), key=key); \
	  cur = os.environ['CUR']; \
	  nxt = cur if not rel or key(cur) > key(rel[-1]) else '.'.join(rel[-1].split('.')[:2] + [str(key(rel[-1])[2] + 1)]); \
	  print(nxt)"); \
	echo "  released: $${RELEASED:-none}  ->  uploading $$NEXT"; \
	sed -i "s|^version = \".*\"|version = \"$$NEXT\"|" pyproject.toml; \
	sed -i "s|^__version__ = \".*\"|__version__ = \"$$NEXT\"|" vlaserve/__init__.py; \
	echo "=== Building and testing $$NEXT (a failure stops here, nothing is uploaded) ==="; \
	$(MAKE) --no-print-directory pypi; \
	echo "=== Uploading to $(PYPI_REPO) ==="; \
	if [ -n "$(PYPI_TOKEN)" ]; then \
	    TWINE_USERNAME=__token__ TWINE_PASSWORD='$(PYPI_TOKEN)' $(PYTHON) -m twine upload --non-interactive --repository $(PYPI_REPO) dist/*; \
	elif [ -f $$HOME/.pypirc ]; then \
	    $(PYTHON) -m twine upload --non-interactive --repository $(PYPI_REPO) dist/*; \
	else echo "ERROR: set PYPI_TOKEN=pypi-... (or create ~/.pypirc). Built files are in dist/." >&2; exit 1; fi; \
	echo ""; echo "=== Done: $$INDEX/project/$(PYPI_PKG)/$$NEXT/  Commit the version bump (pyproject.toml, vlaserve/__init__.py). ==="

## --- kaair_sim closed-loop test (see examples/kaair_sim_eval.py) ---

KAAIR_CONTAINER ?= kaair_sim_humble
KAAIR_CKPT ?= smolvla_open_drawer_500_20260924/checkpoints/020000/pretrained_model
KAAIR_TASK ?= task_open_drawer_generic.yaml
KAAIR_RAND ?= randomization.yaml
# --camera-model for the real-texture scene (KAAIR_TASK=task_open_drawer.yaml KAAIR_RAND=randomization_real.yaml)
KAAIR_EXTRA ?=
N   ?= 50
TAG ?= vlaserve_$(shell date +%Y%m%d)

kaair-eval: ## Sim eval via a server with CKPT_ROOT=<kaair checkpoints> [KAAIR_CKPT KAAIR_TASK KAAIR_RAND KAAIR_EXTRA N]
	docker exec $(KAAIR_CONTAINER) mkdir -p /tmp/vlaclient
	docker cp vlaserve $(KAAIR_CONTAINER):/tmp/vlaclient/
	docker cp examples/kaair_sim_eval.py $(KAAIR_CONTAINER):/tmp/vlaclient/
	docker exec $(KAAIR_CONTAINER) /sim/.venv/bin/python -m pip install -q --target /tmp/vlaclient/deps msgpack
	docker exec $(KAAIR_CONTAINER) bash -lc 'cd /sim && PYTHONPATH=/tmp/vlaclient:/tmp/vlaclient/deps \
		/sim/.venv/bin/python /tmp/vlaclient/kaair_sim_eval.py --url $(URL) \
		--server-model /ckpt/$(KAAIR_CKPT) --ckpt /nas/checkpoints/$(KAAIR_CKPT) \
		--task $(KAAIR_TASK) --rand-config $(KAAIR_RAND) $(KAAIR_EXTRA) --tag $(TAG) --videos 0 --n $(N)'
	docker exec $(KAAIR_CONTAINER) rm -rf /tmp/vlaclient

clean: ## Remove caches and build artefacts
	find . -name __pycache__ -prune -exec rm -rf {} +
	rm -rf .pytest_cache *.egg-info build dist logs
