#!/usr/bin/env bash
set -euo pipefail

service="comfyui"
run_install_scripts=0

usage() {
    cat <<'EOF'
Usage: scripts/update-comfyui-custom-nodes.sh [options]

Updates all Git-based ComfyUI custom nodes and installs their requirements
inside the running Compose container.

Options:
  --service NAME          Compose service name (default: comfyui)
  --with-install-scripts  Also run each custom node's install.py
  -h, --help              Show this help
EOF
}

while (($#)); do
    case "$1" in
        --service)
            service="${2:?missing service name}"
            shift 2
            ;;
        --with-install-scripts)
            run_install_scripts=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$(docker compose ps --status running --quiet "$service")" ]]; then
    echo "Compose service '$service' is not running." >&2
    echo "Start it first with: docker compose up -d $service" >&2
    exit 1
fi

docker compose exec -T "$service" bash -s -- "$run_install_scripts" <<'CONTAINER_SCRIPT'
set -euo pipefail

run_install_scripts="${1:-0}"
nodes_root="/opt/ComfyUI/custom_nodes"

if [[ ! -d "$nodes_root" ]]; then
    echo "Custom nodes directory not found: $nodes_root" >&2
    exit 1
fi

echo "Updating custom nodes..."
while IFS= read -r -d '' git_dir; do
    repo="${git_dir%/.git}"
    echo
    echo "==> $(basename "$repo")"
    git -C "$repo" pull --ff-only
done < <(
    find "$nodes_root" -mindepth 2 -maxdepth 2 -type d -name .git -print0 |
        sort -z
)

if python -m pip --version >/dev/null 2>&1; then
    package_manager="pip"
elif command -v uv >/dev/null 2>&1; then
    package_manager="uv"
else
    echo "Neither 'python -m pip' nor 'uv' is available." >&2
    echo "Install pip or uv in the image before running this script." >&2
    exit 1
fi

install_packages() {
    if [[ "$package_manager" == "pip" ]]; then
        python -m pip install "$@"
    else
        uv pip install --python "$(command -v python)" "$@"
    fi
}

check_packages() {
    if [[ "$package_manager" == "pip" ]]; then
        python -m pip check
    else
        uv pip check --python "$(command -v python)"
    fi
}

echo
echo "Installing custom-node requirements..."
while IFS= read -r -d '' requirements; do
    echo
    echo "==> $requirements"
    install_packages --no-cache-dir -r "$requirements"
done < <(
    find "$nodes_root" -mindepth 2 -maxdepth 3 \
        -type f -name requirements.txt -print0 |
        sort -z
)

if [[ "$run_install_scripts" == "1" ]]; then
    echo
    echo "Running custom-node install.py scripts..."
    while IFS= read -r -d '' installer; do
        echo
        echo "==> $installer"
        (
            cd "$(dirname "$installer")"
            python "$installer"
        )
    done < <(
        find "$nodes_root" -mindepth 2 -maxdepth 2 \
            -type f -name install.py -print0 |
            sort -z
    )
fi

echo
echo "Dependency check:"
check_packages || true

echo
echo "Custom nodes are updated. Restart ComfyUI:"
echo "  docker compose restart comfyui"
CONTAINER_SCRIPT
