#!/usr/bin/env bash
# install-terminal-ai.sh
#
# Installs and configures:
#   - Ollama
#   - Ollama service (systemd on Linux, LaunchAgent on macOS)
#   - default model ("terminal", shell commands), chosen from the hardware:
#       * AMD/NVIDIA GPU with >= 8 GB VRAM: qwen2.5-coder:7b-instruct
#       * otherwise: Qwen-0.5B-Coder-El-Terminalo Q8 GGUF
#   - developer model (-d): Qwen2.5-Coder-0.5B-Instruct Q4_K_M ("terminal-dev")
#   - generalist model (-g, "terminal-gen"), chosen from the hardware:
#       * AMD/NVIDIA GPU with >= 8 GB VRAM: qwen3.5:4b-q4_K_M
#       * otherwise: meta-llama/Llama-3.2-1B-Instruct Q4_K_M
#     Re-running the installer re-detects the hardware and updates both.
#   - function-calling model (-f): FunctionGemma 270M Q4_K_M ("terminal-fn")
#   - ~/.local/bin/ai command
#   - ai() function in ~/.bashrc or ~/.zshrc
#
# Platforms:
#   macOS, WSL, Ubuntu, Fedora, CentOS, AlmaLinux, Omarchy/Arch Linux
#
# Usage:
#   chmod +x install-terminal-ai.sh
#   ./install-terminal-ai.sh
#
#   ./install-terminal-ai.sh --remove   # completely removes what was installed
#
# Optional variables:
#   MODEL_NAME=terminal ./install-terminal-ai.sh
#   INSTALL_DIR="$HOME/.local/share/terminal-ai" ./install-terminal-ai.sh
#   HW_PROFILE=cpu ./install-terminal-ai.sh      # auto (default) | gpu | cpu
#   GPU_MIN_VRAM_MB=7680 NUM_CTX=32768 ./install-terminal-ai.sh
#
# Every model uses the same context window: NUM_CTX (default 32768 = 32k).
#
set -Eeuo pipefail

MODEL_NAME="${MODEL_NAME:-terminal}"

# Context window (tokens) for every model, on both profiles. 32k is within
# the native context of all of them.
NUM_CTX="${NUM_CTX:-32768}"
MODEL_REPO="albinab/Qwen-0.5B-Coder-El-Terminalo"
MODEL_FILE="Qwen-0.5B-Coder-El-Terminalo-q8.gguf"
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}?download=true"

# "developer" model (-d): optimized for code/command generation.
MODEL_NAME_DEV="${MODEL_NAME_DEV:-${MODEL_NAME}-dev}"
MODEL_REPO_DEV="Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF"
MODEL_FILE_DEV="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
MODEL_URL_DEV="https://huggingface.co/${MODEL_REPO_DEV}/resolve/main/${MODEL_FILE_DEV}?download=true"

# "generalist" model (-g): Meta's compact general-purpose model, with
# official multilingual support (including Portuguese).
MODEL_NAME_GEN="${MODEL_NAME_GEN:-${MODEL_NAME}-gen}"
MODEL_REPO_GEN="bartowski/Llama-3.2-1B-Instruct-GGUF"
MODEL_FILE_GEN="Llama-3.2-1B-Instruct-Q4_K_M.gguf"
MODEL_URL_GEN="https://huggingface.co/${MODEL_REPO_GEN}/resolve/main/${MODEL_FILE_GEN}?download=true"

# "function-calling" model (-f): FunctionGemma, specialized in function/tool calls.
MODEL_NAME_FN="${MODEL_NAME_FN:-${MODEL_NAME}-fn}"
MODEL_REPO_FN="unsloth/functiongemma-270m-it-GGUF"
MODEL_FILE_FN="functiongemma-270m-it-Q4_K_M.gguf"
MODEL_URL_FN="https://huggingface.co/${MODEL_REPO_FN}/resolve/main/${MODEL_FILE_FN}?download=true"

# GPU profile: when an AMD or NVIDIA GPU with enough VRAM is detected, two
# models are upgraded to larger Ollama library models:
#   - default ("terminal", shell commands): Qwen2.5-Coder-7B-Instruct
#   - generalist ("terminal-gen", -g):      Qwen3.5-4B
# The developer (-d) and function-calling (-f) models stay the same.
GPU_CODER_MODEL="${GPU_CODER_MODEL:-qwen2.5-coder:7b-instruct}"
GPU_CODER_DESC="${GPU_CODER_DESC:-Qwen2.5-Coder-7B-Instruct Q4_K_M}"
GPU_GEN_MODEL="${GPU_GEN_MODEL:-qwen3.5:4b-q4_K_M}"
GPU_GEN_DESC="${GPU_GEN_DESC:-Qwen3.5-4B Q4_K_M}"
# VRAM left free for the desktop/other apps when deciding whether models
# fit together; the 'ai' command unloads models to stay within the rest.
GPU_VRAM_RESERVE_MB="${GPU_VRAM_RESERVE_MB:-768}"
# Cards sold as "8 GB" report slightly less than 8192 MiB (the driver/firmware
# reserves part of it), so the threshold leaves some slack.
GPU_MIN_VRAM_MB="${GPU_MIN_VRAM_MB:-7680}"
# auto = detect hardware on every run; gpu / cpu = force a profile.
HW_PROFILE="${HW_PROFILE:-auto}"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/terminal-ai}"
HARNESS_DIR="${INSTALL_DIR}/harness"
PROFILE_FILE="${INSTALL_DIR}/profile"
# Memory each model actually used, learned by the 'ai' command from
# 'ollama ps'. Reset on every install run, since the models may change.
MEMORY_FILE="${INSTALL_DIR}/memory"
BIN_DIR="${HOME}/.local/bin"
AI_BIN="${BIN_DIR}/ai"

# Filled by detect_gpu / select_profile / install_*_model.
GPU_VENDOR=""
GPU_NAME=""
GPU_VRAM_MB=0
PROFILE=""
PREV_PROFILE=""
PREV_OWNED_BASE_MODELS=""
DEFAULT_MODEL_DESC=""
DEFAULT_MODEL_NO_THINK=0
GEN_MODEL_DESC=""
GEN_MODEL_NO_THINK=0
# Initial memory estimates (MiB) per model role, used by 'ai' until it has
# measured the real value.
MEM_MB_DEFAULT=0
MEM_MB_GEN=0
OWNED_BASE_MODELS=""

OS_FAMILY=""
DISTRO=""
IS_WSL=0
SHELL_NAME=""
RC_FILE=""
SUDO=""

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

setup_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
    elif have sudo; then
        SUDO="sudo"
    else
        SUDO=""
    fi
}

detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS_FAMILY="macos"
        DISTRO="macos"
    elif [[ "$(uname -s)" == "Linux" ]]; then
        OS_FAMILY="linux"

        if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null ||
           [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
            IS_WSL=1
        fi

        if [[ -r /etc/os-release ]]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            DISTRO="${ID:-linux}"
        else
            DISTRO="linux"
        fi

        # Omarchy may report as Arch; this check makes the result explicit.
        if have omarchy || [[ -d "$HOME/.local/share/omarchy" ]] ||
           grep -qi 'omarchy' /etc/os-release 2>/dev/null; then
            DISTRO="omarchy"
        fi
    else
        die "Unsupported system: $(uname -s)"
    fi

    case "${SHELL:-}" in
        */zsh)  SHELL_NAME="zsh";  RC_FILE="$HOME/.zshrc" ;;
        */bash) SHELL_NAME="bash"; RC_FILE="$HOME/.bashrc" ;;
        *)
            if [[ "$OS_FAMILY" == "macos" ]]; then
                SHELL_NAME="zsh"; RC_FILE="$HOME/.zshrc"
            else
                SHELL_NAME="bash"; RC_FILE="$HOME/.bashrc"
            fi
            ;;
    esac

    if [[ "$IS_WSL" -eq 1 ]]; then
        info "System: ${DISTRO} / WSL"
    else
        info "System: ${DISTRO}"
    fi
    info "Shell: ${SHELL_NAME} (${RC_FILE})"
    info "Context window for every model: ${NUM_CTX} tokens"
}

install_linux_requirements() {
    local distro="$DISTRO"

    case "$distro" in
        ubuntu|debian|linuxmint|pop)
            $SUDO apt-get update
            $SUDO apt-get install -y curl ca-certificates
            ;;
        fedora)
            $SUDO dnf install -y curl ca-certificates
            ;;
        centos|rhel|rocky|almalinux)
            if have dnf; then
                $SUDO dnf install -y curl ca-certificates
            else
                $SUDO yum install -y curl ca-certificates
            fi
            ;;
        omarchy|arch|endeavouros|manjaro)
            $SUDO pacman -Sy --needed --noconfirm curl ca-certificates
            ;;
        *)
            warn "Distribution '$distro' not recognized for automatic dependency installation."
            have curl || die "Install 'curl' manually and run this script again."
            ;;
    esac
}

install_macos_requirements() {
    if ! have curl; then
        die "curl not found. Install the macOS Command Line Tools."
    fi
}

install_ollama() {
    if have ollama; then
        ok "Ollama already installed: $(ollama --version 2>/dev/null || true)"
        return
    fi

    info "Installing Ollama..."

    # Current official installer for macOS/Linux.
    curl -fsSL https://ollama.com/install.sh | sh

    # Some installers place the binary somewhere that only shows up in a new shell.
    hash -r 2>/dev/null || true

    if ! have ollama; then
        for p in /usr/local/bin/ollama /usr/bin/ollama "$HOME/.local/bin/ollama"; do
            if [[ -x "$p" ]]; then
                export PATH="$(dirname "$p"):$PATH"
                break
            fi
        done
    fi

    have ollama || die "Ollama was installed, but the 'ollama' command was not found in PATH."
    ok "Ollama installed."
}

configure_linux_service() {
    local ollama_bin
    ollama_bin="$(command -v ollama)"

    if have systemctl && [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
        info "Configuring Ollama as a systemd service..."

        # The official installer usually creates this service.
        # If it doesn't exist, we create a minimal one.
        if ! systemctl cat ollama.service >/dev/null 2>&1; then
            local service_user
            service_user="${USER}"

            $SUDO tee /etc/systemd/system/ollama.service >/dev/null <<EOF
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${ollama_bin} serve
User=${service_user}
Group=$(id -gn)
Restart=always
RestartSec=3
Environment="HOME=${HOME}"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin"

[Install]
WantedBy=multi-user.target
EOF
        fi

        $SUDO systemctl daemon-reload
        $SUDO systemctl enable --now ollama
        ok "Ollama service active and enabled on boot."
        return
    fi

    if [[ "$IS_WSL" -eq 1 ]]; then
        warn "WSL without systemd active. Configuring Ollama to start when the WSL distro boots."

        # Modern WSL versions support a boot command in /etc/wsl.conf.
        # This preserves the file and only adds [boot] when it doesn't already have a command=.
        if [[ -w /etc/wsl.conf ]] || [[ -n "$SUDO" ]]; then
            if ! grep -qE '^[[:space:]]*command[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
                if ! grep -qE '^[[:space:]]*\[boot\][[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
                    printf '\n[boot]\n' | $SUDO tee -a /etc/wsl.conf >/dev/null
                fi
                printf 'command=%s serve >/var/log/ollama.log 2>&1 &\n' "$ollama_bin" |
                    $SUDO tee -a /etc/wsl.conf >/dev/null
                ok "Ollama configured to start on WSL distro boot."
            else
                warn "/etc/wsl.conf already has a [boot] command. It was not overwritten."
                warn "Enable systemd in WSL or add manually: ${ollama_bin} serve"
            fi
        fi

        # Also start it in this session.
        if ! curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
            nohup "$ollama_bin" serve >"$HOME/.ollama-serve.log" 2>&1 &
        fi
        return
    fi

    warn "systemd is not active. Creating a shell fallback to start Ollama on demand."
}

configure_macos_service() {
    local ollama_bin plist
    ollama_bin="$(command -v ollama)"
    plist="$HOME/Library/LaunchAgents/com.terminal-ai.ollama.plist"

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

    # If the user already uses Ollama.app or Homebrew services, avoid creating a duplicate service.
    if launchctl list 2>/dev/null | grep -qE 'ollama|com\.ollama'; then
        ok "An Ollama service is already registered in launchd."
        return
    fi

    info "Creating Ollama LaunchAgent..."

    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.terminal-ai.ollama</string>

    <key>ProgramArguments</key>
    <array>
        <string>${ollama_bin}</string>
        <string>serve</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/ollama.log</string>

    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/ollama-error.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin</string>
    </dict>
</dict>
</plist>
EOF

    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    launchctl enable "gui/$(id -u)/com.terminal-ai.ollama" >/dev/null 2>&1 || true

    ok "LaunchAgent created. Ollama will start automatically on macOS login."
}

wait_for_ollama() {
    info "Waiting for the Ollama server..."

    for _ in {1..30}; do
        if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
            ok "Ollama server responding on 127.0.0.1:11434."
            return
        fi
        sleep 1
    done

    # Last-resort fallback on systems without a service manager.
    if ! pgrep -f '[o]llama serve' >/dev/null 2>&1; then
        nohup "$(command -v ollama)" serve >"$HOME/.ollama-serve.log" 2>&1 &
        sleep 2
    fi

    curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 ||
        die "The Ollama server did not respond. Check the service logs."
}

download_model() {
    local file="$1" url="$2" label="$3"

    mkdir -p "$INSTALL_DIR"

    if [[ -s "$INSTALL_DIR/$file" ]]; then
        ok "GGUF already exists: $INSTALL_DIR/$file"
        return
    fi

    info "Downloading ${label} (${file})..."
    curl -fL --retry 3 --retry-delay 2 \
        --progress-bar \
        "$url" \
        -o "$INSTALL_DIR/$file.part"

    mv "$INSTALL_DIR/$file.part" "$INSTALL_DIR/$file"
    ok "${label} downloaded."
}

compute_system_prompt() {
    local os_prompt shell_prompt

    if [[ "$OS_FAMILY" == "macos" ]]; then
        os_prompt="macos"
        shell_prompt="zsh"
    else
        os_prompt="linux"
        shell_prompt="$SHELL_NAME"
    fi

    # Used by the default, developer (-d) and function-calling (-f) models,
    # which only ever produce a shell command.
    SYSTEM_PROMPT_SHELL="You are a shell command generator. OS: ${os_prompt}, Shell: ${shell_prompt}. Output ONLY the command. Never wrap commands in markdown fences."

    # Used by the generalist model (-g), which answers questions directly
    # instead of generating shell commands.
    SYSTEM_PROMPT_GENERAL="You are a helpful, concise general-purpose assistant. Answer the user's question directly in plain text. Do not output a shell command unless the user explicitly asks you to."
}

# create_modelfile <gguf file> <Modelfile path> <template: chatml|gemma> <system prompt>
create_modelfile() {
    local file="$1" modelfile_path="$2" template="$3" system_prompt="$4"

    case "$template" in
        chatml)
            cat >"$modelfile_path" <<EOF
FROM ./${file}

TEMPLATE """<|im_start|>system
{{ .System }}<|im_end|>
<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
"""

PARAMETER stop "<|im_start|>"
PARAMETER stop "<|im_end|>"
PARAMETER num_ctx ${NUM_CTX}
PARAMETER temperature 0.1
PARAMETER top_p 0.9

SYSTEM """${system_prompt}"""
EOF
            ;;
        gemma)
            # Gemma has no dedicated "system" role: the content is embedded in
            # the first user turn, following the convention used by the community
            # in Ollama Modelfiles for the Gemma family.
            cat >"$modelfile_path" <<EOF
FROM ./${file}

TEMPLATE """<start_of_turn>user
{{ .System }}

{{ .Prompt }}<end_of_turn>
<start_of_turn>model
"""

PARAMETER stop "<start_of_turn>"
PARAMETER stop "<end_of_turn>"
PARAMETER num_ctx ${NUM_CTX}
PARAMETER temperature 0.1
PARAMETER top_p 0.9

SYSTEM """${system_prompt}"""
EOF
            ;;
        llama3)
            cat >"$modelfile_path" <<EOF
FROM ./${file}

TEMPLATE """<|start_header_id|>system<|end_header_id|>

{{ .System }}<|eot_id|><|start_header_id|>user<|end_header_id|>

{{ .Prompt }}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

"""

PARAMETER stop "<|start_header_id|>"
PARAMETER stop "<|eot_id|>"
PARAMETER num_ctx ${NUM_CTX}
PARAMETER temperature 0.1
PARAMETER top_p 0.9

SYSTEM """${system_prompt}"""
EOF
            ;;
        *)
            die "Unknown Modelfile template: ${template}"
            ;;
    esac

    ok "Modelfile created at $modelfile_path"
}

# register_model <name in Ollama> <Modelfile path>
register_model() {
    local name="$1" modelfile_path="$2"

    info "Registering model '${name}' in Ollama..."
    (
        cd "$(dirname "$modelfile_path")"
        ollama create "$name" -f "$(basename "$modelfile_path")"
    )
    ok "Model '${name}' registered."
}

# model_exists <name>: true if the model is present in Ollama.
model_exists() {
    have ollama || return 1
    local name="$1"
    # Ollama lists library models as "name:tag" and local ones as "name:latest".
    [[ "$name" == *:* ]] || name="${name}:latest"
    ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qxF "$name"
}

# mb_to_gb <MiB>: prints the value in GB with one decimal place.
mb_to_gb() {
    awk -v mb="$1" 'BEGIN { printf "%.1f", mb / 1024 }'
}

# detect_gpu: finds the AMD or NVIDIA GPU with the most VRAM and fills
# GPU_VENDOR, GPU_NAME and GPU_VRAM_MB (0 when nothing is found).
detect_gpu() {
    GPU_VENDOR=""
    GPU_NAME=""
    GPU_VRAM_MB=0

    local name mb smi=""

    # NVIDIA (Linux, WSL). On WSL the binary lives in /usr/lib/wsl/lib and is
    # not always in PATH.
    if have nvidia-smi; then
        smi="nvidia-smi"
    elif [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
        smi="/usr/lib/wsl/lib/nvidia-smi"
    fi

    if [[ -n "$smi" ]]; then
        while IFS=',' read -r name mb; do
            mb="${mb//[^0-9]/}"
            [[ -n "$mb" ]] || continue
            if (( mb > GPU_VRAM_MB )); then
                GPU_VENDOR="NVIDIA"
                GPU_NAME="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                GPU_VRAM_MB="$mb"
            fi
        done < <("$smi" --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
    fi

    # AMD (Linux): the amdgpu driver exposes the VRAM size in sysfs, which
    # works with or without ROCm tools installed.
    if [[ "$OS_FAMILY" == "linux" ]]; then
        local card dev bytes slot
        for card in /sys/class/drm/card[0-9]*; do
            [[ "$(basename "$card")" == *-* ]] && continue   # connectors (card1-DP-1, ...)
            dev="$card/device"
            [[ "$(cat "$dev/vendor" 2>/dev/null)" == "0x1002" ]] || continue
            bytes="$(cat "$dev/mem_info_vram_total" 2>/dev/null || true)"
            [[ "$bytes" =~ ^[0-9]+$ ]] || continue
            mb=$(( bytes / 1048576 ))
            if (( mb > GPU_VRAM_MB )); then
                name="AMD GPU"
                if have lspci; then
                    slot="$(basename "$(readlink -f "$dev")")"
                    name="$(lspci -s "$slot" 2>/dev/null | head -n1 |
                        sed -E -e 's/^[^ ]+ [^:]+: //' \
                               -e 's/Advanced Micro Devices, Inc\. \[AMD\/ATI\] //' \
                               -e 's/ \(rev [0-9a-f]+\)$//' || true)"
                    [[ -n "$name" ]] || name="AMD GPU"
                fi
                GPU_VENDOR="AMD"
                GPU_NAME="$name"
                GPU_VRAM_MB="$mb"
            fi
        done
    fi
}

# read_previous_profile: loads what the last install run recorded, so a re-run
# can report changes and clean up a base model it no longer needs.
read_previous_profile() {
    PREV_PROFILE=""
    PREV_OWNED_BASE_MODELS=""
    [[ -r "$PROFILE_FILE" ]] || return 0
    PREV_PROFILE="$(sed -n 's/^PROFILE=//p' "$PROFILE_FILE" | head -n1)"
    # OWNED_BASE_MODEL (singular) is the key written by older versions.
    PREV_OWNED_BASE_MODELS="$(sed -n -e 's/^OWNED_BASE_MODELS=//p' -e 's/^OWNED_BASE_MODEL=//p' "$PROFILE_FILE" |
        head -n1 | sed -e "s/^'//" -e "s/'$//" -e 's/\\ / /g')"
}

# list_has <space-separated list> <item>
list_has() {
    [[ " $1 " == *" $2 "* ]]
}

select_profile() {
    read_previous_profile
    detect_gpu

    if (( GPU_VRAM_MB > 0 )); then
        info "GPU detected: ${GPU_VENDOR} ${GPU_NAME} ($(mb_to_gb "$GPU_VRAM_MB") GB VRAM)"
    else
        info "No dedicated AMD/NVIDIA GPU detected."
    fi

    case "$HW_PROFILE" in
        gpu|cpu)
            PROFILE="$HW_PROFILE"
            info "Hardware profile forced via HW_PROFILE: ${PROFILE}"
            ;;
        auto)
            if (( GPU_VRAM_MB >= GPU_MIN_VRAM_MB )); then
                PROFILE="gpu"
                info "Profile: gpu (VRAM >= $(mb_to_gb "$GPU_MIN_VRAM_MB") GB) -> default: ${GPU_CODER_MODEL}, -g: ${GPU_GEN_MODEL}."
            else
                PROFILE="cpu"
                info "Profile: cpu -> default: Qwen-0.5B-Coder-El-Terminalo, -g: Llama-3.2-1B-Instruct."
            fi
            ;;
        *)
            die "Invalid HW_PROFILE '${HW_PROFILE}' (use auto, gpu or cpu)."
            ;;
    esac

    if [[ -n "$PREV_PROFILE" && "$PREV_PROFILE" != "$PROFILE" ]]; then
        info "Hardware profile changed since the last install: ${PREV_PROFILE} -> ${PROFILE}. Updating the models."
    fi
}

OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_DROPIN="${OLLAMA_DROPIN_DIR}/terminal-ai.conf"

has_systemd() {
    have systemctl && [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]
}

# install_gpu_backend: Arch-family distros package Ollama's GPU runtimes
# separately from the CPU-only "ollama" package. Without them the GPU profile
# would silently run on the CPU. (The official installer used on other
# distros already bundles CUDA/ROCm.)
install_gpu_backend() {
    [[ "$OS_FAMILY" == "linux" ]] || return 0
    have pacman || return 0
    pacman -Qq ollama >/dev/null 2>&1 || return 0

    local pkg=""
    case "$GPU_VENDOR" in
        NVIDIA) pkg="ollama-cuda" ;;
        # Vulkan (RADV) also covers consumer RDNA cards that ROCm does not
        # officially support (e.g. RX 6600 / gfx1032).
        AMD)    pkg="ollama-vulkan" ;;
        *)      return 0 ;;
    esac

    if pacman -Qq "$pkg" >/dev/null 2>&1; then
        ok "Ollama GPU backend already installed: ${pkg}"
        return 0
    fi

    info "Installing Ollama GPU backend for ${GPU_VENDOR}: ${pkg}..."
    if $SUDO pacman -S --needed --noconfirm "$pkg"; then
        ok "${pkg} installed."
    else
        warn "Could not install ${pkg}; the model will run on the CPU."
    fi
}

# configure_gpu_service: systemd drop-in that makes the 32k contexts fit in
# VRAM (flash attention + 8-bit KV cache roughly halves the KV cache size) and
# enables the Vulkan backend. Removed again when the profile is cpu.
configure_gpu_service() {
    has_systemd || return 0
    systemctl cat ollama.service >/dev/null 2>&1 || return 0

    local content
    content="# Managed by install-terminal-ai.sh (GPU profile); rewritten/removed on every install run.
[Service]
Environment=\"OLLAMA_FLASH_ATTENTION=1\"
Environment=\"OLLAMA_KV_CACHE_TYPE=q8_0\""
    [[ "$GPU_VENDOR" == "AMD" ]] && content+="
Environment=\"OLLAMA_VULKAN=1\""

    if [[ "$PROFILE" == "gpu" ]]; then
        if [[ "$(cat "$OLLAMA_DROPIN" 2>/dev/null)" == "$content" ]]; then
            ok "Ollama service already tuned for the GPU profile."
            return 0
        fi
        info "Tuning the Ollama service for the GPU profile (${OLLAMA_DROPIN})..."
        $SUDO mkdir -p "$OLLAMA_DROPIN_DIR"
        printf '%s\n' "$content" | $SUDO tee "$OLLAMA_DROPIN" >/dev/null
    else
        [[ -f "$OLLAMA_DROPIN" ]] || return 0
        info "Removing the GPU tuning from the Ollama service..."
        $SUDO rm -f "$OLLAMA_DROPIN"
    fi

    $SUDO systemctl daemon-reload
    $SUDO systemctl restart ollama
    wait_for_ollama
}

# create_library_modelfile <Modelfile path> <library model> <system prompt>
create_library_modelfile() {
    local modelfile_path="$1" base="$2" system_prompt="$3"

    # No TEMPLATE: the chat template (and its stop tokens) is inherited from
    # the Ollama library model.
    cat >"$modelfile_path" <<EOF
FROM ${base}

PARAMETER num_ctx ${NUM_CTX}
PARAMETER temperature 0.1
PARAMETER top_p 0.9

SYSTEM """${system_prompt}"""
EOF

    ok "Modelfile created at $modelfile_path"
}

# pull_base_model <library model>: makes the model available in Ollama.
# Records it in OWNED_BASE_MODELS when this installer pulled it, so it can be
# removed later. Returns non-zero if it is not available.
pull_base_model() {
    local base="$1" already_present=0
    model_exists "$base" && already_present=1

    info "Pulling ${base} from the Ollama library..."
    if ! ollama pull "$base"; then
        if [[ "$already_present" -eq 1 ]]; then
            warn "Could not update ${base}; using the copy already present in Ollama."
        else
            warn "Could not pull ${base}. It may require a newer Ollama version."
            warn "Update Ollama (curl -fsSL https://ollama.com/install.sh | sh) and run this installer again."
            return 1
        fi
    fi

    # Only models this installer pulled itself are removed later.
    if [[ "$already_present" -eq 0 ]] || list_has "$PREV_OWNED_BASE_MODELS" "$base"; then
        list_has "$OWNED_BASE_MODELS" "$base" || OWNED_BASE_MODELS="${OWNED_BASE_MODELS:+$OWNED_BASE_MODELS }$base"
    fi
}

# install_default_model: default model ("terminal", shell commands).
#   gpu: Qwen2.5-Coder-7B-Instruct    cpu: Qwen-0.5B-Coder-El-Terminalo
install_default_model() {
    if [[ "$PROFILE" == "gpu" ]]; then
        if pull_base_model "$GPU_CODER_MODEL"; then
            create_library_modelfile "$INSTALL_DIR/Modelfile" "$GPU_CODER_MODEL" "$SYSTEM_PROMPT_SHELL"
            register_model "$MODEL_NAME" "$INSTALL_DIR/Modelfile"
            DEFAULT_MODEL_DESC="${GPU_CODER_DESC} · GPU"
            DEFAULT_MODEL_NO_THINK=0
            MEM_MB_DEFAULT=6200
            return
        fi
        warn "Falling back to the CPU default model."
    fi

    download_model "$MODEL_FILE" "$MODEL_URL" "Qwen-0.5B-Coder-El-Terminalo (default)"
    create_modelfile "$MODEL_FILE" "$INSTALL_DIR/Modelfile" chatml "$SYSTEM_PROMPT_SHELL"
    register_model "$MODEL_NAME" "$INSTALL_DIR/Modelfile"
    DEFAULT_MODEL_DESC="Qwen-0.5B-Coder-El-Terminalo"
    DEFAULT_MODEL_NO_THINK=0
    MEM_MB_DEFAULT=1100
}

# install_gen_model: generalist model ("terminal-gen", -g).
#   gpu: Qwen3.5-4B    cpu: Llama-3.2-1B-Instruct
install_gen_model() {
    if [[ "$PROFILE" == "gpu" ]]; then
        if pull_base_model "$GPU_GEN_MODEL"; then
            create_library_modelfile "$INSTALL_DIR/Modelfile.gen" "$GPU_GEN_MODEL" "$SYSTEM_PROMPT_GENERAL"
            register_model "$MODEL_NAME_GEN" "$INSTALL_DIR/Modelfile.gen"
            GEN_MODEL_DESC="${GPU_GEN_DESC} · GPU"
            # Thinking-capable: disabled at run time so only the answer prints.
            GEN_MODEL_NO_THINK=1
            MEM_MB_GEN=4400
            return
        fi
        warn "Falling back to the CPU generalist model."
    fi

    download_model "$MODEL_FILE_GEN" "$MODEL_URL_GEN" "Llama-3.2-1B-Instruct (generalist)"
    create_modelfile "$MODEL_FILE_GEN" "$INSTALL_DIR/Modelfile.gen" llama3 "$SYSTEM_PROMPT_GENERAL"
    register_model "$MODEL_NAME_GEN" "$INSTALL_DIR/Modelfile.gen"
    GEN_MODEL_DESC="Llama-3.2-1B-Instruct"
    GEN_MODEL_NO_THINK=0
    MEM_MB_GEN=2000
}

# cleanup_previous_base_models: removes base models that a previous run
# pulled and that the current profile no longer uses (e.g. the GPU went away).
cleanup_previous_base_models() {
    local base
    for base in $PREV_OWNED_BASE_MODELS; do
        list_has "$OWNED_BASE_MODELS" "$base" && continue
        info "Removing base model no longer used: ${base}"
        remove_model "$base"
    done
}

# write_profile: records the hardware profile for the 'ai' command (labels,
# thinking flags, memory budget/estimates) and for the next install run.
# Rewritten on every run; the learned memory sizes are reset too.
write_profile() {
    local budget=""
    [[ "$PROFILE" == "gpu" ]] && (( GPU_VRAM_MB > 0 )) &&
        budget=$(( GPU_VRAM_MB - GPU_VRAM_RESERVE_MB ))

    mkdir -p "$INSTALL_DIR"
    {
        printf '# Generated by install-terminal-ai.sh; rewritten on every install run.\n'
        printf 'PROFILE=%s\n' "$PROFILE"
        printf 'DEFAULT_MODEL_DESC=%q\n' "$DEFAULT_MODEL_DESC"
        printf 'DEFAULT_MODEL_NO_THINK=%s\n' "$DEFAULT_MODEL_NO_THINK"
        printf 'GEN_MODEL_DESC=%q\n' "$GEN_MODEL_DESC"
        printf 'GEN_MODEL_NO_THINK=%s\n' "$GEN_MODEL_NO_THINK"
        printf 'OWNED_BASE_MODELS=%q\n' "$OWNED_BASE_MODELS"
        printf 'GPU=%q\n' "${GPU_VENDOR:+${GPU_VENDOR} ${GPU_NAME} ($(mb_to_gb "$GPU_VRAM_MB") GB VRAM)}"
        printf '# Memory available to the models (MiB): VRAM minus a reserve on the\n'
        printf '# gpu profile; empty = use the free RAM at run time.\n'
        printf 'MEM_BUDGET_MB=%s\n' "$budget"
        printf '# Initial memory estimates per model (MiB), until measured.\n'
        printf 'MEM_MB_default=%s\n' "$MEM_MB_DEFAULT"
        printf 'MEM_MB_developer=%s\n' 1000
        printf 'MEM_MB_generalist=%s\n' "$MEM_MB_GEN"
        printf 'MEM_MB_function=%s\n' 700
    } >"$PROFILE_FILE"
    rm -f "$MEMORY_FILE"
    ok "Hardware profile saved to $PROFILE_FILE"
}

# write_harness_file <path> <starter content>: creates the harness file with
# starter content only if it doesn't already exist, so a reinstall never
# overwrites the user's edits.
write_harness_file() {
    local path="$1" content="$2"
    [[ -f "$path" ]] && return 0
    printf '%s\n' "$content" >"$path"
}

create_harness_files() {
    mkdir -p "$HARNESS_DIR"

    write_harness_file "$HARNESS_DIR/default.txt" \
"# Harness for the default model (shell commands).
# Extra instructions appended to every prompt sent to this model.
# Lines starting with '#' are ignored. Edit freely, or run: ai -H
Prefer commands available in a standard POSIX/GNU environment."

    write_harness_file "$HARNESS_DIR/developer.txt" \
"# Harness for the developer model (-d, Qwen2.5-Coder-0.5B-Instruct).
# Extra instructions appended to every prompt sent to this model.
# Lines starting with '#' are ignored. Edit freely, or run: ai -H -d
When writing code, prefer clear, idiomatic, minimal solutions."

    write_harness_file "$HARNESS_DIR/generalist.txt" \
"# Harness for the generalist model (-g).
# Extra instructions appended to every prompt sent to this model.
# Lines starting with '#' are ignored. Edit freely, or run: ai -H -g
Be concise and answer only what was asked."

    write_harness_file "$HARNESS_DIR/function.txt" \
"# Harness for the function-calling model (-f, FunctionGemma 270M).
# Extra instructions appended to every prompt sent to this model.
# Lines starting with '#' are ignored. Edit freely, or run: ai -H -f
Prefer commands available in a standard POSIX/GNU environment."

    ok "Harness files ready at $HARNESS_DIR"
}

create_ai_command() {
    mkdir -p "$BIN_DIR"

    cat >"$AI_BIN" <<'AI_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_NAME="${TERMINAL_AI_MODEL:-terminal}"
HARNESS_DIR="${TERMINAL_AI_HARNESS_DIR:-$HOME/.local/share/terminal-ai/harness}"

# Hardware profile written by the installer (re-detected on every install
# run): which models back "terminal" / "terminal-gen", and the memory
# budget/estimates used to decide when to swap models in and out of memory.
DEFAULT_MODEL_DESC="Qwen-0.5B-Coder-El-Terminalo"
DEFAULT_MODEL_NO_THINK=0
GEN_MODEL_DESC="Llama-3.2-1B-Instruct"
GEN_MODEL_NO_THINK=0
MEM_BUDGET_MB=""
TERMINAL_AI_DIR="$(dirname "$HARNESS_DIR")"
PROFILE_FILE="$TERMINAL_AI_DIR/profile"
MEMORY_FILE="$TERMINAL_AI_DIR/memory"
if [[ -r "$PROFILE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$PROFILE_FILE"
fi

MODEL_LABEL="${MODEL_NAME} (default · ${DEFAULT_MODEL_DESC})"
# Thinking-capable models (GPU profile) would print their reasoning before
# the command; it is disabled for them.
NO_THINK="$DEFAULT_MODEL_NO_THINK"
HARNESS_NAME="default"
IS_DEV=0
IS_GEN=0
EDIT_HARNESS=0

usage() {
    cat <<EOF
Usage:
  ai "description of the command"     # default model: ${DEFAULT_MODEL_DESC}
  ai description of the command
  ai -d "description of the command"   # developer model: Qwen2.5-Coder-0.5B-Instruct
  ai -g "description of the command"   # generalist model: ${GEN_MODEL_DESC}
  ai -f "description of the command"   # function-calling model: FunctionGemma 270M
  ai -H [-d|-g|-f]                     # edit the harness file for that model (\$VISUAL/\$EDITOR, or Omarchy's editor)

Example:
  ai "show the 10 processes using the most memory"
  ai -d "write a python function that sorts a list"
  ai -H -g                             # edit the generalist model's harness

After the output is generated:
  e = execute (not available with -g, which answers in plain text)
  c = copy
  q = cancel
  ENTER = cancel

With -d, choosing [e] first detects the generated code's language and, if a
matching interpreter/compiler is installed, writes it to a temporary file and
runs it that way instead of as a shell command.

Harness:
  Each model has an editable text file with extra instructions appended to
  every prompt sent to it (lines starting with '#' are ignored). Edit with
  -H, or directly under: ${HARNESS_DIR}
  On Omarchy, -H opens the file via "omarchy launch editor" (the user's
  configured default editor); elsewhere it uses \$VISUAL, \$EDITOR, or vi.

Variables:
  TERMINAL_AI_MODEL         (default,          default: terminal)
  TERMINAL_AI_MODEL_DEV     (-d, developer,    default: terminal-dev)
  TERMINAL_AI_MODEL_GEN     (-g, generalist,   default: terminal-gen)
  TERMINAL_AI_MODEL_FN      (-f, function,     default: terminal-fn)
  TERMINAL_AI_HARNESS_DIR   (harness folder,   default: ~/.local/share/terminal-ai/harness)
EOF
}

# detect_language <code>: prints one of
#   python javascript ruby php c cpp java go rust shell
detect_language() {
    local code="$1" shebang

    shebang="$(printf '%s\n' "$code" | head -n1)"
    case "$shebang" in
        '#!'*python*) printf 'python\n'; return ;;
        '#!'*node*)   printf 'javascript\n'; return ;;
        '#!'*ruby*)   printf 'ruby\n'; return ;;
        '#!'*php*)    printf 'php\n'; return ;;
        '#!'*sh)      printf 'shell\n'; return ;;
        '#!'*bash)    printf 'shell\n'; return ;;
    esac

    if printf '%s' "$code" | grep -qE '<\?php'; then
        printf 'php\n'; return
    fi
    if printf '%s' "$code" | grep -qE '\bpackage[[:space:]]+main\b' &&
       printf '%s' "$code" | grep -qE '\bfunc[[:space:]]+main[[:space:]]*\('; then
        printf 'go\n'; return
    fi
    if printf '%s' "$code" | grep -qE '\bfn[[:space:]]+main[[:space:]]*\(' &&
       printf '%s' "$code" | grep -qE 'println!|let[[:space:]]+mut'; then
        printf 'rust\n'; return
    fi
    if printf '%s' "$code" | grep -qE '\bpublic[[:space:]]+class[[:space:]]+[A-Za-z_]' ||
       printf '%s' "$code" | grep -qE '\bpublic[[:space:]]+static[[:space:]]+void[[:space:]]+main\b'; then
        printf 'java\n'; return
    fi
    if printf '%s' "$code" | grep -qE '#include[[:space:]]*<iostream>' ||
       printf '%s' "$code" | grep -qE '\bstd::'; then
        printf 'cpp\n'; return
    fi
    if printf '%s' "$code" | grep -qE '#include[[:space:]]*<[a-z./]+\.h>' ||
       printf '%s' "$code" | grep -qE '\bint[[:space:]]+main[[:space:]]*\('; then
        printf 'c\n'; return
    fi
    if printf '%s' "$code" | grep -qE '\bdef[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(.*\)[[:space:]]*:' ||
       printf '%s' "$code" | grep -qE '^[[:space:]]*(import|from)[[:space:]]+[A-Za-z_.]+' ||
       printf '%s' "$code" | grep -qE '^[[:space:]]*print\(.*\)[[:space:]]*$'; then
        printf 'python\n'; return
    fi
    if printf '%s' "$code" | grep -qE '\brequire[[:space:]]+["'"'"']' ||
       printf '%s' "$code" | grep -qE '\bputs[[:space:]]'; then
        printf 'ruby\n'; return
    fi
    if printf '%s' "$code" | grep -qE '\bconsole\.log[[:space:]]*\(' ||
       printf '%s' "$code" | grep -qE '\b(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=' ||
       printf '%s' "$code" | grep -qE '=>' ||
       printf '%s' "$code" | grep -qE '\bfunction[[:space:]]*[A-Za-z_]*[[:space:]]*\('; then
        printf 'javascript\n'; return
    fi

    printf 'shell\n'
}

missing_interpreter_msg() {
    printf '\033[1;31m%s\033[0m\n' \
        "Install the interpreter or compiler in your environment before running programming language commands." >&2
}

# run_dev_code <code>: for the developer model, detect the language and run
# it with the matching interpreter/compiler from a temporary file, falling
# back to running it as a shell command when no language is recognized.
run_dev_code() {
    local code="$1" lang tmp_dir

    lang="$(detect_language "$code")"

    if [[ "$lang" == "shell" ]]; then
        printf '\033[1;33mExecuting:\033[0m %s\n' "$code"
        "${SHELL:-/bin/bash}" -lc "$code"
        return
    fi

    printf '\033[2m[Detected language: %s]\033[0m\n' "$lang"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    case "$lang" in
        python)
            if command -v python3 >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/script.py"
                python3 "$tmp_dir/script.py"
            elif command -v python >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/script.py"
                python "$tmp_dir/script.py"
            else
                missing_interpreter_msg
            fi
            ;;
        javascript)
            if command -v node >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/script.js"
                node "$tmp_dir/script.js"
            else
                missing_interpreter_msg
            fi
            ;;
        ruby)
            if command -v ruby >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/script.rb"
                ruby "$tmp_dir/script.rb"
            else
                missing_interpreter_msg
            fi
            ;;
        php)
            if command -v php >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/script.php"
                php "$tmp_dir/script.php"
            else
                missing_interpreter_msg
            fi
            ;;
        c)
            local cc_bin=""
            command -v gcc >/dev/null 2>&1 && cc_bin="gcc"
            [[ -n "$cc_bin" ]] || { command -v cc >/dev/null 2>&1 && cc_bin="cc"; }
            if [[ -n "$cc_bin" ]]; then
                printf '%s\n' "$code" >"$tmp_dir/prog.c"
                if "$cc_bin" "$tmp_dir/prog.c" -o "$tmp_dir/prog"; then
                    "$tmp_dir/prog"
                fi
            else
                missing_interpreter_msg
            fi
            ;;
        cpp)
            local cxx_bin=""
            command -v g++ >/dev/null 2>&1 && cxx_bin="g++"
            [[ -n "$cxx_bin" ]] || { command -v clang++ >/dev/null 2>&1 && cxx_bin="clang++"; }
            if [[ -n "$cxx_bin" ]]; then
                printf '%s\n' "$code" >"$tmp_dir/prog.cpp"
                if "$cxx_bin" "$tmp_dir/prog.cpp" -o "$tmp_dir/prog"; then
                    "$tmp_dir/prog"
                fi
            else
                missing_interpreter_msg
            fi
            ;;
        java)
            if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
                local classname
                classname="$(printf '%s' "$code" |
                    grep -oE 'public[[:space:]]+class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' |
                    awk '{print $NF}' | head -n1)"
                [[ -n "$classname" ]] || classname="Main"
                printf '%s\n' "$code" >"$tmp_dir/${classname}.java"
                if (cd "$tmp_dir" && javac "${classname}.java"); then
                    (cd "$tmp_dir" && java "$classname")
                fi
            else
                missing_interpreter_msg
            fi
            ;;
        go)
            if command -v go >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/main.go"
                go run "$tmp_dir/main.go"
            else
                missing_interpreter_msg
            fi
            ;;
        rust)
            if command -v rustc >/dev/null 2>&1; then
                printf '%s\n' "$code" >"$tmp_dir/main.rs"
                if rustc "$tmp_dir/main.rs" -o "$tmp_dir/main" 2>/dev/null; then
                    "$tmp_dir/main"
                fi
            else
                missing_interpreter_msg
            fi
            ;;
    esac
}

[[ $# -gt 0 ]] || { usage; exit 1; }

while getopts ":dgfhH" OPT; do
    case "$OPT" in
        d)
            MODEL_NAME="${TERMINAL_AI_MODEL_DEV:-terminal-dev}"
            MODEL_LABEL="${MODEL_NAME} (developer · Qwen2.5-Coder-0.5B-Instruct)"
            HARNESS_NAME="developer"
            IS_DEV=1
            NO_THINK=0
            ;;
        g)
            MODEL_NAME="${TERMINAL_AI_MODEL_GEN:-terminal-gen}"
            MODEL_LABEL="${MODEL_NAME} (generalist · ${GEN_MODEL_DESC})"
            HARNESS_NAME="generalist"
            IS_GEN=1
            NO_THINK="$GEN_MODEL_NO_THINK"
            ;;
        f)
            MODEL_NAME="${TERMINAL_AI_MODEL_FN:-terminal-fn}"
            MODEL_LABEL="${MODEL_NAME} (function-calling · FunctionGemma 270M)"
            HARNESS_NAME="function"
            NO_THINK=0
            ;;
        h)
            usage
            exit 0
            ;;
        H)
            EDIT_HARNESS=1
            ;;
        \?)
            printf 'Invalid option: -%s\n\n' "$OPTARG" >&2
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [[ "$EDIT_HARNESS" -eq 1 ]]; then
    mkdir -p "$HARNESS_DIR"
    HARNESS_FILE="$HARNESS_DIR/${HARNESS_NAME}.txt"
    [[ -f "$HARNESS_FILE" ]] || : >"$HARNESS_FILE"
    if command -v omarchy >/dev/null 2>&1; then
        # Omarchy 4+: use the unified CLI instead of calling the legacy
        # omarchy-launch-editor binary directly.
        omarchy launch editor "$HARNESS_FILE"
    else
        "${VISUAL:-${EDITOR:-vi}}" "$HARNESS_FILE"
    fi
    exit 0
fi

[[ $# -gt 0 ]] || { usage; exit 1; }

# detect_system_language: maps the OS locale (LC_ALL/LC_MESSAGES/LANG) to a
# language name, so the model can be told to answer in it.
detect_system_language() {
    local loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US}}}"
    local code="${loc%%.*}"
    code="${code%%_*}"
    case "$code" in
        pt) printf 'Portuguese' ;;
        es) printf 'Spanish' ;;
        fr) printf 'French' ;;
        de) printf 'German' ;;
        it) printf 'Italian' ;;
        ja) printf 'Japanese' ;;
        zh) printf 'Chinese' ;;
        ru) printf 'Russian' ;;
        ko) printf 'Korean' ;;
        nl) printf 'Dutch' ;;
        pl) printf 'Polish' ;;
        tr) printf 'Turkish' ;;
        ar) printf 'Arabic' ;;
        hi) printf 'Hindi' ;;
        *)  printf 'English' ;;
    esac
}

# read_harness <name>: prints the harness file's content for that model,
# comment lines (starting with '#') stripped and collapsed to one line, or
# nothing if the file is missing/empty.
read_harness() {
    local file="$HARNESS_DIR/$1.txt"
    [[ -s "$file" ]] || return 0
    grep -v '^[[:space:]]*#' "$file" | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

QUERY="$*"
OS_NAME="linux"
[[ "$(uname -s)" == "Darwin" ]] && OS_NAME="macos"

SHELL_NAME="$(basename "${SHELL:-bash}")"
CWD="$PWD"
SYSTEM_LANGUAGE="$(detect_system_language)"
HARNESS_TEXT="$(read_harness "$HARNESS_NAME")"

# Directives are appended AFTER "Request:" on purpose: these small models
# tend to just echo an instruction back instead of following it when it
# comes before the request.
PROMPT="OS: ${OS_NAME}. Shell: ${SHELL_NAME}. Current directory: ${CWD}. Request: ${QUERY}. Respond in ${SYSTEM_LANGUAGE}.${HARNESS_TEXT:+ ${HARNESS_TEXT}}"

# --- Memory management -----------------------------------------------------
# When the requested model does not fit in memory (VRAM on the gpu profile,
# free RAM otherwise) next to the models already loaded, terminal-ai's other
# models are unloaded first, largest first, so the switch between the
# default model and -d / -g / -f never spills onto the CPU or fails.

# canonical_name <model>: Ollama lists local models as name:latest.
canonical_name() {
    case "$1" in
        *:*) printf '%s' "$1" ;;
        *)   printf '%s:latest' "$1" ;;
    esac
}

OUR_MODELS=" $(canonical_name "${TERMINAL_AI_MODEL:-terminal}") $(canonical_name "${TERMINAL_AI_MODEL_DEV:-terminal-dev}") $(canonical_name "${TERMINAL_AI_MODEL_GEN:-terminal-gen}") $(canonical_name "${TERMINAL_AI_MODEL_FN:-terminal-fn}") "

# loaded_models: prints "<name> <MiB>" for every model loaded in Ollama.
loaded_models() {
    ollama ps 2>/dev/null | awk 'NR > 1 && NF >= 4 {
        v = $3; u = $4; mib = 0
        if (u == "GB") mib = v * 1e9 / 1048576
        else if (u == "MB") mib = v * 1e6 / 1048576
        else if (u == "KB") mib = v * 1e3 / 1048576
        printf "%s %d\n", $1, mib
    }'
}

# model_mem_mb <role>: memory the model used last time (measured), or the
# installer's estimate until it has been measured.
model_mem_mb() {
    local role="$1" v="" var
    if [[ -r "$MEMORY_FILE" ]]; then
        v="$(sed -n "s/^${role}=//p" "$MEMORY_FILE" | tail -n1)"
    fi
    if [[ -z "$v" ]]; then
        var="MEM_MB_${role}"
        v="${!var:-0}"
    fi
    printf '%s' "${v:-0}"
}

# free_memory_mb <MiB used by loaded models>: memory still available for a
# new model, or nothing when it cannot be determined.
free_memory_mb() {
    local used="$1"
    if [[ -n "$MEM_BUDGET_MB" ]]; then
        printf '%s' $(( MEM_BUDGET_MB - used ))
    elif [[ -r /proc/meminfo ]]; then
        awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo
    fi
}

wait_unloaded() {
    local name="$1" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        loaded_models | awk '{print $1}' | grep -qxF "$name" || return 0
        sleep 0.5
    done
}

ensure_memory() {
    local target need loaded name mb used=0 free
    target="$(canonical_name "$MODEL_NAME")"
    need="$(model_mem_mb "$HARNESS_NAME")"
    [[ "$need" =~ ^[0-9]+$ ]] || return 0
    (( need > 0 )) || return 0

    loaded="$(loaded_models)"
    [[ -n "$loaded" ]] || return 0

    while read -r name mb; do
        [[ -n "$name" ]] || continue
        [[ "$name" == "$target" ]] && return 0   # already in memory
        used=$(( used + mb ))
    done <<<"$loaded"

    free="$(free_memory_mb "$used")"
    [[ "$free" =~ ^-?[0-9]+$ ]] || return 0
    (( need > free )) || return 0

    while read -r name mb; do
        [[ "$OUR_MODELS" == *" $name "* ]] || continue
        printf '\033[2m[Not enough memory for %s: unloading %s (%s GB)]\033[0m\n' \
            "$MODEL_NAME" "$name" "$(awk -v m="$mb" 'BEGIN { printf "%.1f", m / 1024 }')" >&2
        ollama stop "$name" >/dev/null 2>&1 || continue
        wait_unloaded "$name"
        free=$(( free + mb ))
        if (( need <= free )); then
            break
        fi
    done < <(printf '%s\n' "$loaded" | sort -k2,2nr)
}

# remember_model_memory: stores how much memory the model really took, so the
# next decision uses the measured value instead of the estimate.
remember_model_memory() {
    local target mb
    [[ -d "$TERMINAL_AI_DIR" ]] || return 0
    target="$(canonical_name "$MODEL_NAME")"
    mb="$(loaded_models | awk -v t="$target" '$1 == t { print $2 }')"
    [[ "$mb" =~ ^[0-9]+$ ]] || return 0
    (( mb > 0 )) || return 0
    {
        if [[ -r "$MEMORY_FILE" ]]; then
            grep -v "^${HARNESS_NAME}=" "$MEMORY_FILE" || true
        fi
        printf '%s=%s\n' "$HARNESS_NAME" "$mb"
    } >"$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
}

run_model() {
    if [[ "$NO_THINK" -eq 1 ]]; then
        ollama run --think=false "$MODEL_NAME" "$PROMPT"
    else
        ollama run "$MODEL_NAME" "$PROMPT"
    fi
}

ensure_memory || true

# strip CR, occasional fences, and blank lines at the edges
CMD="$(
    run_model |
    tr -d '\r' |
    sed -e '/^[[:space:]]*```/d' \
        -e '/^[[:space:]]*$/d'
)"

remember_model_memory || true

if [[ -z "$CMD" ]]; then
    printf 'No command was generated.\n' >&2
    exit 2
fi

printf '\n\033[2m[LLM: %s]\033[0m\n' "$MODEL_LABEL"
printf '\n\033[1;36m%s\033[0m\n\n' "$CMD"
if [[ "$IS_GEN" -eq 1 ]]; then
    printf '[c] copy  [q/Enter] cancel: '
else
    printf '[e] execute  [c] copy  [q/Enter] cancel: '
fi
IFS= read -r -n 1 ACTION || true
printf '\n'

case "${ACTION:-}" in
    e|E)
        if [[ "$IS_GEN" -eq 1 ]]; then
            printf 'Invalid option.\n'
        elif [[ "$IS_DEV" -eq 1 ]]; then
            run_dev_code "$CMD"
        else
            printf '\033[1;33mExecuting:\033[0m %s\n' "$CMD"
            # Runs in the current shell chosen by the user.
            "${SHELL:-/bin/bash}" -lc "$CMD"
        fi
        ;;
    c|C)
        if command -v wl-copy >/dev/null 2>&1; then
            printf '%s' "$CMD" | wl-copy
        elif command -v xclip >/dev/null 2>&1; then
            printf '%s' "$CMD" | xclip -selection clipboard
        elif command -v xsel >/dev/null 2>&1; then
            printf '%s' "$CMD" | xsel --clipboard --input
        elif command -v pbcopy >/dev/null 2>&1; then
            printf '%s' "$CMD" | pbcopy
        elif command -v clip.exe >/dev/null 2>&1; then
            printf '%s' "$CMD" | clip.exe
        else
            printf 'No clipboard utility found.\n' >&2
            exit 3
        fi
        printf 'Copied to clipboard.\n'
        ;;
    *)
        printf 'Cancelled.\n'
        ;;
esac
AI_SCRIPT

    chmod +x "$AI_BIN"
    ok "Command created: $AI_BIN"
}

TERMINAL_AI_BLOCK_BEGIN="# >>> terminal-ai >>>"
TERMINAL_AI_BLOCK_END="# <<< terminal-ai <<<"

# strip_terminal_ai_block <rc file>: removes the terminal-ai managed block, if present.
strip_terminal_ai_block() {
    local rc_file="$1"

    [[ -f "$rc_file" ]] || return 0
    grep -Fq "$TERMINAL_AI_BLOCK_BEGIN" "$rc_file" || return 0

    awk -v b="$TERMINAL_AI_BLOCK_BEGIN" -v e="$TERMINAL_AI_BLOCK_END" '
        $0 == b {skip=1; next}
        $0 == e {skip=0; next}
        !skip {print}
    ' "$rc_file" >"${rc_file}.tmp"
    mv "${rc_file}.tmp" "$rc_file"
}

configure_shell() {
    touch "$RC_FILE"

    local begin="$TERMINAL_AI_BLOCK_BEGIN"
    local end="$TERMINAL_AI_BLOCK_END"

    # Remove old block to keep the installation idempotent.
    strip_terminal_ai_block "$RC_FILE"

    # Remove trailing blank lines so they don't pile up on every reinstall.
    awk '
        { lines[NR] = $0 }
        END {
            n = NR
            while (n > 0 && lines[n] == "") n--
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$RC_FILE" >"${RC_FILE}.tmp"
    mv "${RC_FILE}.tmp" "$RC_FILE"

    cat >>"$RC_FILE" <<EOF

${begin}
export PATH="\$HOME/.local/bin:\$PATH"
export TERMINAL_AI_MODEL="${MODEL_NAME}"
export TERMINAL_AI_MODEL_DEV="${MODEL_NAME_DEV}"
export TERMINAL_AI_MODEL_GEN="${MODEL_NAME_GEN}"
export TERMINAL_AI_MODEL_FN="${MODEL_NAME_FN}"
export TERMINAL_AI_HARNESS_DIR="${HARNESS_DIR}"

ai() {
    command "\$HOME/.local/bin/ai" "\$@"
}
${end}
EOF

    ok "ai() function added to $RC_FILE"
}

# smoke_test <name> <label> [no-think: 0|1]
smoke_test() {
    local name="$1" label="$2" no_think="${3:-0}"
    local result prompt="OS: linux. Shell: bash. Request: list running docker containers"

    info "Testing model '${name}' (${label})..."
    if [[ "$no_think" -eq 1 ]]; then
        result="$(ollama run --think=false "$name" "$prompt" 2>/dev/null || true)"
    else
        result="$(ollama run "$name" "$prompt" 2>/dev/null || true)"
    fi

    if [[ -n "$result" ]]; then
        printf '\nModel test (%s):\n  %s\n\n' "$label" "$result"
    else
        warn "Model '${name}' was installed, but the test returned no content."
    fi

    # Unload it right away so the next test doesn't compete for memory.
    ollama stop "$name" >/dev/null 2>&1 || true
}

remove_model() {
    local name="$1"

    have ollama || return 0

    if model_exists "$name"; then
        if ollama rm "$name" >/dev/null 2>&1; then
            ok "Model '${name}' removed."
        else
            warn "Failed to remove model '${name}'."
        fi
    fi
}

remove_all() {
    printf '\n=== Removing Terminal AI ===\n\n'

    setup_sudo
    detect_os

    remove_model "$MODEL_NAME"
    remove_model "$MODEL_NAME_DEV"
    remove_model "$MODEL_NAME_GEN"
    remove_model "$MODEL_NAME_FN"

    # Base models pulled by the GPU profile (only those this installer pulled).
    read_previous_profile
    local base
    for base in $PREV_OWNED_BASE_MODELS; do
        remove_model "$base"
    done

    if [[ -f "$OLLAMA_DROPIN" ]]; then
        $SUDO rm -f "$OLLAMA_DROPIN"
        if has_systemd; then
            $SUDO systemctl daemon-reload
            $SUDO systemctl try-restart ollama || true
        fi
        ok "GPU tuning removed from the Ollama service: $OLLAMA_DROPIN"
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        ok "Directory removed: $INSTALL_DIR"
    else
        info "Directory not found: $INSTALL_DIR"
    fi

    if [[ -f "$AI_BIN" ]]; then
        rm -f "$AI_BIN"
        ok "Command removed: $AI_BIN"
    else
        info "Command not found: $AI_BIN"
    fi

    # Strip the managed block from both rc files, regardless of the shell
    # currently in use, in case it was installed under a different shell.
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && grep -Fq "$TERMINAL_AI_BLOCK_BEGIN" "$rc" 2>/dev/null; then
            strip_terminal_ai_block "$rc"
            ok "Configuration removed from $rc"
        fi
    done

    cat <<EOF

Removal complete.

Ollama itself was NOT removed, since it may be used by other applications.
To remove it completely as well:

EOF

    if [[ "$OS_FAMILY" == "macos" ]]; then
        cat <<EOF
    launchctl bootout "gui/\$(id -u)" "\$HOME/Library/LaunchAgents/com.terminal-ai.ollama.plist" 2>/dev/null
    rm -f "\$HOME/Library/LaunchAgents/com.terminal-ai.ollama.plist"
    rm -rf ~/.ollama
    # If installed via the official app/installer, also remove /Applications/Ollama.app
    # and the 'ollama' binary/service it created.

EOF
    else
        cat <<EOF
    sudo systemctl disable --now ollama 2>/dev/null
    sudo rm -f /etc/systemd/system/ollama.service
    sudo rm -f "\$(command -v ollama)"
    rm -rf ~/.ollama

EOF
    fi

    printf 'Open a new terminal for the changes to take effect.\n\n'
}

main() {
    printf '\n=== Terminal AI installer ===\n\n'

    setup_sudo
    detect_os
    select_profile

    if [[ "$OS_FAMILY" == "macos" ]]; then
        install_macos_requirements
    else
        install_linux_requirements
    fi

    install_ollama

    if [[ "$OS_FAMILY" == "macos" ]]; then
        configure_macos_service
    else
        configure_linux_service
    fi

    wait_for_ollama
    compute_system_prompt

    [[ "$PROFILE" == "gpu" ]] && install_gpu_backend
    install_default_model
    install_gen_model
    configure_gpu_service
    cleanup_previous_base_models
    write_profile

    download_model "$MODEL_FILE_DEV" "$MODEL_URL_DEV" "Qwen2.5-Coder-0.5B-Instruct (developer)"
    create_modelfile "$MODEL_FILE_DEV" "$INSTALL_DIR/Modelfile.dev" chatml "$SYSTEM_PROMPT_SHELL"
    register_model "$MODEL_NAME_DEV" "$INSTALL_DIR/Modelfile.dev"

    download_model "$MODEL_FILE_FN" "$MODEL_URL_FN" "FunctionGemma 270M (function-calling)"
    create_modelfile "$MODEL_FILE_FN" "$INSTALL_DIR/Modelfile.fn" gemma "$SYSTEM_PROMPT_SHELL"
    register_model "$MODEL_NAME_FN" "$INSTALL_DIR/Modelfile.fn"

    create_harness_files
    create_ai_command
    configure_shell

    smoke_test "$MODEL_NAME" "default" "$DEFAULT_MODEL_NO_THINK"
    smoke_test "$MODEL_NAME_DEV" "developer"
    smoke_test "$MODEL_NAME_GEN" "generalist" "$GEN_MODEL_NO_THINK"
    smoke_test "$MODEL_NAME_FN" "function-calling"

    cat <<EOF

Installation complete.

Open a new terminal or run:

    source "$RC_FILE"

Examples:

    ai "show the 10 processes using the most memory"
    ai "list running docker containers"
    ai -d "write a python function that sorts a list"
    ai -g "explain what an IP address is"
    ai -f "find files larger than 1 GB in /var"
    ai -H -g                            # edit the generalist model's harness

Hardware profile: ${PROFILE}${GPU_VENDOR:+ (${GPU_VENDOR} ${GPU_NAME}, $(mb_to_gb "$GPU_VRAM_MB") GB VRAM)}
Run this installer again at any time to re-detect the hardware and update
the models (e.g. after installing or removing a GPU).

When the models don't fit in memory together, 'ai' unloads the others
before loading the one requested (default, -d, -g or -f).

Models:
    ${MODEL_NAME}      (default         · ${DEFAULT_MODEL_DESC})
    ${MODEL_NAME_DEV}  (-d, developer   · Qwen2.5-Coder-0.5B-Instruct)
    ${MODEL_NAME_GEN}  (-g, generalist  · ${GEN_MODEL_DESC})
    ${MODEL_NAME_FN}   (-f, function    · FunctionGemma 270M)

Files:
    ${PROFILE_FILE}
    ${INSTALL_DIR}/${MODEL_FILE_DEV}
    ${INSTALL_DIR}/${MODEL_FILE_FN}
    ${INSTALL_DIR}/Modelfile{,.dev,.gen,.fn}
    ${HARNESS_DIR}/{default,developer,generalist,function}.txt
    ${AI_BIN}

Every response from the 'ai' command shows which LLM generated it.

The generated command is NOT executed automatically.
You need to choose [e] to run it.

EOF
}

case "${1:-}" in
    --remove|--uninstall)
        remove_all
        ;;
    *)
        main "$@"
        ;;
esac
