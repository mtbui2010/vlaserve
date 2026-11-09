# vlaserve GPU server image, x86-64.
#
#   docker build -f deploy/Dockerfile -t vlaserve:gpu-cu128 .
#   docker run -d --gpus all -p 11450:11450 \
#       -v ~/.cache/huggingface:/root/.cache/huggingface \
#       --name vlaserve vlaserve:gpu-cu128 serve --host 0.0.0.0 pi05-libero
#
# No weights in the image: checkpoints come from the mounted HF cache or a mounted directory.
#
# CUDA comes from the torch wheel (cu128: CUDA 12.8 + cuDNN as pip packages); the driver comes
# from the host through the NVIDIA container runtime. The host driver must support CUDA >= 12.8
# (driver >= 570). An older driver fails at the first GPU call; rebuild with TORCH_CUDA=cu126.

FROM python:3.12-slim-bookworm

ARG TORCH_CUDA=cu128
ARG TORCH_VERSION=2.10.0
ARG TORCHVISION_VERSION=0.25.0
ARG VERSION=dev

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/root/.cache/huggingface

# libgl/glib: OpenCV, imported transitively by LeRobot.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

# torch first, from the CUDA-specific index only. Installed later through PyPI, LeRobot would pull
# the newest torch build, whose CUDA may be newer than the host driver supports.
RUN pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} \
        --index-url https://download.pytorch.org/whl/${TORCH_CUDA} \
 && printf 'torch==%s\ntorchvision==%s\n' ${TORCH_VERSION} ${TORCHVISION_VERSION} > /etc/pip-constraints.txt

WORKDIR /opt/vlaserve
COPY pyproject.toml README.md ./
COPY vlaserve ./vlaserve
COPY tests ./tests
RUN pip install -c /etc/pip-constraints.txt ".[server,test]" \
 && python -c "import torch; assert torch.__version__.startswith('${TORCH_VERSION}'), torch.__version__" \
 && python -c "import lerobot.policies.pi05, lerobot.policies.smolvla, vlaserve.server" \
 && vlaserve list > /dev/null

LABEL org.opencontainers.image.title="vlaserve" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.source="https://github.com/mtbui2010/vlaserve" \
      org.opencontainers.image.documentation="https://mtbui2010.github.io/vlaserve/" \
      org.opencontainers.image.licenses="Apache-2.0"

VOLUME ["/root/.cache/huggingface"]
EXPOSE 11450

# Loading pi0.5 takes 2-5 min; /health answers only once preloaded models are in memory.
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
    CMD python -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:11450/health', timeout=4)" || exit 1

ENTRYPOINT ["vlaserve"]
CMD ["serve", "--host", "0.0.0.0"]
