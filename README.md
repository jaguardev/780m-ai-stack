# Docker Stack: Ubuntu 25.10 + ROCm nightly + PyTorch + ComfyUI + Ollama + Open WebUI

After experimenting with models, drivers, kernel versions, and other software, I found a reasonably stable and performant setup for AI workloads on my ThinkPad T14 Gen 4 (AMD 7840U, Radeon 780M, 32 GB RAM).

After reaching baseline stability, I found there is still room for performance optimization.

This repository contains what I consider a balanced default profile for general use, but you should still tune it for your own workload and hardware constraints.

A few observations:

The 780M can theoretically do more, but in practice the software stack is the main limiter. Drivers, ROCm, PyTorch, Triton, and ComfyUI are still not optimized to fully utilize this iGPU.

Flash/Sage attention often provides little or no speedup. Triton autotune can take a very long time, and warm-up for multiple parameter combinations takes even longer.

The 780M supports bf16, fp16, int8, and int4.

At the same time, fitting 16-bit models into shared memory without offloading is difficult, and offloading over DDR5/shared bus is slow.

Because of that, FP8 models can become unexpectedly slow. They are often dequantized to FP16 or processed in a software-heavy path.

GGUF helps partially because of mixed tensor quantization. You can fit larger models, but not always gain throughput.

In theory, fully int8/int4 models could improve this significantly, but such models are still less common.

By combining a GGUF VAE with a BF16 `z-image-turbo` model and using ComfyUI flags `--use-sage-attention --disable-smart-memory --reserve-vram 1 --gpu-only`, I got everything to fit into VRAM and reached about 40 seconds for one 720x1280 image. This is my best result so far.

Feel free to continue experimenting with flags (check `Dockerfile` and `docker-compose.yml`) - I will be glad to hear your results and review PRs.
We can also expect support improvements from AMD over time. These images are currently built from ROCm nightly (TheRock).

## 1. Goal

A stack for running local AI on **AMD Radeon 780M (iGPU)** in best-effort mode:

- ComfyUI (image generation)
- Ollama (LLM inference)
- Open WebUI (web interface for Ollama)

## 3. Host Requirements

- Recent driver stack (I used preview version: https://instinct.docs.amd.com/projects/amdgpu-docs/en/31.10.0-preview/install/detailed-install/package-manager/package-manager-ubuntu.html)
- Linux host with available `/dev/kfd` and `/dev/dri`
- Docker Engine + Docker Compose plugin
- Swap and sufficient system RAM are recommended (can be lower depending on expected workload)
    ```bash
    # swapfile example (32G)
    sudo swapoff /swapfile
    sudo fallocate -l 32G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    swapon --show
    ```
- Kubuntu 25.10 is recommended (I think newer kernel versions helped performance vs 24.4 LTS, though this is not strictly benchmarked; I also just like the newer Plasma release.)
- Kernel parameter tuning (I picked a stable/performance-oriented setup for myself, but there is room for experimentation). Example below allocates about 24 GB RAM for VRAM. On my system, without `amdgpu.mes_kiq=1` and `amdgpu.cwsr_enable=0`, I get freezes/crashes.
    ```ini
    GRUB_CMDLINE_LINUX_DEFAULT='quiet splash amdttm.pages_limit=6291456 amdttm.page_pool_size=6291456 transparent_hugepage=always amdgpu.mes_kiq=1 amdgpu.cwsr_enable=0 amdgpu.noretry=1 amd_iommu=off amdgpu.sg_display=0'
    ```

    ```bash
    sudo mcedit /etc/default/grub
    sudo update-grub
    *restart*
    ```
- Access group setup. udev rules are recommended: https://rocm.docs.amd.com/en/7.11.0-preview/install/rocm.html?fam=radeon&gpu=rx-7700&os=ubuntu&os-version=24.04&i=pip#configure-permissions-for-gpu-access-os-ubuntu-os-debian-os-rhel-os-oracle-linux-os-rocky-linux-os-sles-os-windows-i-pip-i-tar-i-pkgman-os-ubuntu-os-debian-os-rhel-os-rocky-linux-os-oracle-linux-os-sles-os-ubuntu-os-debian-i-pkgman-i-pip-i-tar-os-rhel-os-rocky-linux-os-oracle-linux-os-sles-i-pkgman-i-pip-i-tar-os-windows-fam-ryzen-os-ubuntu-os-rhel-os-version-10-1-os-version-10-0-os-version-9-7-os-version-9-6-os-version-9-4-os-version-8-10-os-sles-os-rhel-os-version-10-1-os-version-10-0-os-version-9-7-os-version-9-6-os-version-9-4-os-version-8-10-os-sles-i-pkgman-os-oracle-linux-os-rhel-os-version-10-1-os-version-10-0-os-version-9-7-os-version-9-6-os-version-9-4-os-version-8-10-os-oracle-linux-os-rocky-linux-os-version-10-1-os-version-10-0-os-version-9-7-os-version-9-6-os-version-9-4-os-version-8-10-os-ubuntu-os-debian-os-rhel-os-oracle-linux-os-rocky-linux-os-sles-i-pkgman-i-pip-i-tar-os-ubuntu-os-debian-os-rhel-os-oracle-linux-os-rocky-linux-os-sles-i-pip-os-ubuntu-os-version-24-04-os-version-22-04-os-debian-os-version-13-os-rhel-os-oracle-linux-os-rocky-linux-os-version-10-1-os-version-10-0-os-version-9-7-os-version-9-6-os-version-8-os-sles-os-version-16-0-os-version-15-7-os-windows-os-ubuntu-os-debian-os-rhel-os-oracle-linux-os-rocky-linux-os-sles
- For Ollama on host, only the binary is needed:
    ```bash
    wget https://ollama.com/download/ollama-linux-amd64.tar.zst
    sudo tar --zstd -x -C /opt/ollama
    sudo ln /opt/ollama/bin/ollama /usr/local/bin/ollama
    ```

    After starting the container, you can pull models and use them:

    ```bash
    ollama pull hf.co/mradermacher/Forgotten-Safeword-12B-v4.0-i1-GGUF:Q4_K_M
    ```

## 5. Launch

```bash
docker compose up -d comfyui
```

```bash
docker compose up -d open-webui
```

Stop:

```bash
docker compose stop comfyui ollama open-webui
```

## 6. Access

- ComfyUI: `http://localhost:8188`
- Ollama: `http://localhost:11434`
- Open WebUI: `http://localhost:8080`

## 7. Persistent Data

Data is stored in local bind-mount directories:

- `./volumes/comfyui/models`
- `./volumes/comfyui/input`
- `./volumes/comfyui/output`
- `./volumes/comfyui/custom_nodes`
- `./volumes/comfyui/user`
- `./volumes/ollama`
- `./volumes/open-webui`

Additional internal directories `/root/.venv` and `/root/.triton` are declared through `VOLUME` in `Dockerfile`.

This means Docker stores them separately from project bind mounts.
They are removed by `docker compose down -v`.


## 9. Verification After Launch

```bash
docker compose ps
docker logs comfyui --tail 100
docker logs ollama --tail 100
docker logs open-webui --tail 100
```

## 10. Sources

- ROCm docs: https://rocm.docs.amd.com/
- ComfyUI: https://github.com/comfyanonymous/ComfyUI
- ComfyUI-Manager: https://github.com/ltdrdata/ComfyUI-Manager
- Ollama: https://hub.docker.com/r/ollama/ollama
- Open WebUI: https://github.com/open-webui/open-webui

# Installing ComfyUI-Manager

After first launch, when all `VOLUME` paths are bound locally on host:

```bash
docker compose up -d comfyui
cd ./volumes/comfyui/custom_nodes
sudo git clone https://github.com/ltdrdata/ComfyUI-Manager
docker compose restart comfyui
```

# ComfyUI Launch Parameters

I have several templates:

Balanced variant. Uses offloading to RAM.
```
    command:
      - python
      - main.py
      - --use-sage-attention
      - --lowvram
      - --listen
      - 0.0.0.0
      - --port
      - "8188"
```

(Default) More aggressive variant. Keeps CLIP and model in VRAM while VAE works on CPU.
```
"python", "main.py", "--use-sage-attention", "--gpu-only", "--cpu-vae", "--listen", "0.0.0.0", "--port", "8188"
```

Most aggressive and fastest variant. Disables offloading and runs everything on GPU.
```
"python", "main.py", "--use-sage-attention", "--disable-smart-memory", "--reserve-vram", "1", "--gpu-only", "--listen", "0.0.0.0", "--port", "8188"
```
