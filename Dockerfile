FROM ubuntu:26.04 as rocm

RUN apt update && apt install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    cmake \
    libgfortran5 \
    gfortran \
    libatomic1 \
    libquadmath \
    python3.13 \
    python3.13-venv \
    python3-pip \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

VOLUME [ "/root/.venv" ]

ENV VIRTUAL_ENV=/root/.venv
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python3 -m venv $VIRTUAL_ENV

ENV PATH="$VIRTUAL_ENV/bin:$PATH"

ARG ROCM_DOWNLOADS_URL=https://rocm.nightlies.amd.com/v2/gfx110X-all/
ENV ROCM_DOWNLOADS_URL=${ROCM_DOWNLOADS_URL}

RUN pip install --no-cache-dir --index-url ${ROCM_DOWNLOADS_URL} "rocm[libraries,devel]"


FROM rocm as pytorch

VOLUME [ "/root/.triton" ]

RUN apt update && apt install -y --no-install-recommends \
    git \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    packaging \
    setuptools \
    wheel

RUN pip install --no-cache-dir \
    --index-url ${ROCM_DOWNLOADS_URL} \
    torch torchvision torchaudio triton

RUN git clone -b main_perf https://github.com/ROCm/flash-attention.git \
    && cd flash-attention \
    && FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE MAX_JOBS=4 python setup.py install \
    && cd .. \
    && rm -rf flash-attention

RUN pip install --no-cache-dir \
    https://github.com/guinmoon/SageAttention-Rocm7/releases/download/v1.0.6_rocm7/sageattention-1.0.6-py3-none-any.whl


FROM pytorch as comfyui

RUN apt update && apt install -y --no-install-recommends \
    python3-dev \
    libxcb1 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI

WORKDIR /opt/ComfyUI

RUN pip install --no-cache-dir -r requirements.txt

# this manager does not work well. will install it from github release instead.
# RUN pip install --no-cache-dir -r manager_requirements.txt

# ENV HSA_OVERRIDE_GFX_VERSION=11.0.1
# ENV TRITON_ROCM_AMD_TARGET=gfx1101
# ENV FLASH_ATTENTION_TRITON_AMD_AUTOTUNE=TRUE
# ENV PYTORCH_TUNABLEOP_ENABLED=1
ENV FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
ENV TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
ENV MIOPEN_FIND_MODE=2
ENV AMD_SERIALIZE_KERNEL=0
ENV AMD_LOG_LEVEL=0
ENV TORCH_CUDNN_ENABLED=0
ENV PYTORCH_HIP_ALLOC_CONF=garbage_collection_threshold:0.8,max_split_size_mb:512

VOLUME [ "/opt/ComfyUI/custom_nodes", "/opt/ComfyUI/models", "/opt/ComfyUI/input", "/opt/ComfyUI/output", "/opt/ComfyUI/user" ]

EXPOSE 8188

# for middle size models i.e. z-image-turbo
# CMD ["python", "main.py", "--use-sage-attention", "--gpu-only", "--cpu-vae", "--listen", "0.0.0.0", "--port", "8188"]

# for small models, i.e. z-image-turbo gguf
# CMD ["python", "main.py", "--use-sage-attention", "--disable-smart-memory", "--reserve-vram", "1", "--gpu-only", "--listen", "0.0.0.0", "--port", "8188"]

# for general case
CMD ["python", "main.py", "--use-sage-attention", "--lowvram", "--listen", "0.0.0.0", "--port", "8188"]
