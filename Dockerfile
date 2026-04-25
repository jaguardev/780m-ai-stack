ARG ROCM_DOWNLOADS_URL=https://rocm.nightlies.amd.com/v2/gfx110X-all/
ARG ROCM_VERSION=7.13.0a20260416
ARG GPU_ARCH=gfx1103
ARG TORCH_VERSION=2.11.0+rocm7.13.0a20260416
ARG TORCHVISION_VERSION=0.26.0+rocm7.13.0a20260416
ARG TORCHAUDIO_VERSION=2.11.0+rocm7.13.0a20260416
ARG TRITON_VERSION=3.6.0+rocm7.13.0a20260416

FROM ubuntu:26.04 as rocm-devel

ARG ROCM_DOWNLOADS_URL
ARG ROCM_VERSION

RUN apt update && apt install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    cmake \
    libgfortran5 \
    libatomic1 \
    libquadmath0 \
    python3-venv \
    python3-pip \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

ENV VIRTUAL_ENV=/root/.venv
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python3 -m venv $VIRTUAL_ENV

ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN pip install --no-cache-dir --index-url ${ROCM_DOWNLOADS_URL} "rocm[libraries,devel]==${ROCM_VERSION}"
RUN rocm-sdk init

ENV ROCM_PATH=/root/.venv/lib/python3.14/site-packages/_rocm_sdk_devel
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/lib/:$LD_LIBRARY_PATH
ENV PATH=$ROCM_PATH/lib/llvm/bin:$ROCM_PATH/bin:$PATH


FROM ubuntu:26.04 as rocm

RUN apt update && apt install -y --no-install-recommends \
    ca-certificates \
    libgfortran5 \
    libatomic1 \
    libquadmath0 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=rocm-devel /root/.venv/lib/python3.14/site-packages/_rocm_sdk_core/. /opt/rocm/
COPY --from=rocm-devel /root/.venv/lib/python3.14/site-packages/_rocm_sdk_libraries_gfx110X_all/lib/. /opt/rocm/lib/
COPY --from=rocm-devel /root/.venv/lib/python3.14/site-packages/_rocm_sdk_libraries_gfx110X_all/share/. /opt/rocm/share/

ENV ROCM_PATH=/opt/rocm
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/lib/:$LD_LIBRARY_PATH
ENV PATH=$ROCM_PATH/lib/llvm/bin:$ROCM_PATH/bin:$PATH


FROM rocm-devel as ollama-builder

ARG GPU_ARCH

RUN apt update && apt install -y --no-install-recommends \
    ca-certificates \
    git \
    golang-go \
    ninja-build \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

RUN git clone https://github.com/ollama/ollama.git /root/ollama

WORKDIR /root/ollama

RUN cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=$ROCM_PATH \
    -DCMAKE_HIP_PLATFORM=amd \
    -DGPU_TARGETS=${GPU_ARCH} \
    -DGGML_HIP=ON \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_INSTALL_RPATH=$ROCM_PATH/lib:$ROCM_PATH/lib/rocm_sysdeps/lib

RUN cmake --build build --config Release

RUN go build -o ollama .


FROM rocm as ollama

COPY --from=ollama-builder /root/ollama/ollama /usr/local/bin/ollama
COPY --from=ollama-builder /root/ollama/build/lib/ollama /usr/local/lib/ollama

ENV LD_LIBRARY_PATH=/usr/local/lib/ollama:$LD_LIBRARY_PATH

ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434
ENTRYPOINT ["/usr/local/bin/ollama"]
CMD ["serve"]


FROM rocm-devel as pytorch

ARG ROCM_DOWNLOADS_URL
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCHAUDIO_VERSION
ARG TRITON_VERSION

RUN apt update && apt install -y --no-install-recommends \
    git \
    python3-venv \
    python3-pip \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    packaging \
    wheel

RUN pip install --no-cache-dir \
    --index-url ${ROCM_DOWNLOADS_URL} \
    torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} triton==${TRITON_VERSION}

RUN git clone --recursive -b main_perf https://github.com/ROCm/flash-attention.git /tmp/flash-attention \
    && mkdir -p /tmp/wheels \
    && python -m pip wheel --no-build-isolation --no-deps /tmp/flash-attention/third_party/aiter -w /tmp/wheels \
    && FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE MAX_JOBS=4 \
       python -m pip wheel --no-build-isolation --no-deps /tmp/flash-attention -w /tmp/wheels \
    && python -m pip install --no-cache-dir --no-index --find-links=/tmp/wheels --no-deps amd-aiter \
    && python -m pip install --no-cache-dir --no-index --find-links=/tmp/wheels --no-deps flash-attn \
    && rm -rf /tmp/flash-attention /tmp/wheels

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

ENV PYTORCH_TUNABLEOP_ENABLED=1
ENV PYTORCH_TUNABLEOP_TUNING=0
ENV COMFYUI_ENABLE_MIOPEN=1
ENV MIOPEN_FIND_MODE=2
ENV MIOPEN_FIND_ENFORCE=1
ENV FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE"
ENV TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
ENV AMD_LOG_LEVEL=0      
ENV TORCH_CUDNN_ENABLED=0
ENV AMD_SERIALIZE_KERNEL=0
ENV HSA_ENABLE_SDMA=0
ENV HSA_USE_SVM=0
ENV PYTORCH_HIP_ALLOC_CONF=backend:native,garbage_collection_threshold:0.7,max_split_size_mb:256,expandable_segments:True

EXPOSE 8188

CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
