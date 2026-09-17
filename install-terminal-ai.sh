#!/usr/bin/env bash
# install-terminal-ai.sh
#
# Installs and configures:
#   - Ollama
#   - Ollama service (systemd on Linux, LaunchAgent on macOS)
#   - default model: Qwen-0.5B-Coder-El-Terminalo Q8 GGUF ("terminal")
#   - developer model (-d): Qwen2.5-Coder-0.5B-Instruct Q4_K_M ("terminal-dev")
#   - generalist model (-g): google/gemma-3-270m-it Q4_K_M ("terminal-gen")
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
# Optional variables:
#   MODEL_NAME=terminal ./install-terminal-ai.sh
#   INSTALL_DIR="$HOME/.local/share/terminal-ai" ./install-terminal-ai.sh
#
set -Eeuo pipefail

MODEL_NAME="${MODEL_NAME:-terminal}"
MODEL_REPO="albinab/Qwen-0.5B-Coder-El-Terminalo"
MODEL_FILE="Qwen-0.5B-Coder-El-Terminalo-q8.gguf"
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}?download=true"

# "developer" model (-d): optimized for code/command generation.
MODEL_NAME_DEV="${MODEL_NAME_DEV:-${MODEL_NAME}-dev}"
MODEL_REPO_DEV="Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF"
MODEL_FILE_DEV="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
MODEL_URL_DEV="https://huggingface.co/${MODEL_REPO_DEV}/resolve/main/${MODEL_FILE_DEV}?download=true"

# "generalist" model (-g): Google's compact general-purpose model.
MODEL_NAME_GEN="${MODEL_NAME_GEN:-${MODEL_NAME}-gen}"
MODEL_REPO_GEN="unsloth/gemma-3-270m-it-GGUF"
MODEL_FILE_GEN="gemma-3-270m-it-Q4_K_M.gguf"
MODEL_URL_GEN="https://huggingface.co/${MODEL_REPO_GEN}/resolve/main/${MODEL_FILE_GEN}?download=true"

# "function-calling" model (-f): FunctionGemma, specialized in function/tool calls.
MODEL_NAME_FN="${MODEL_NAME_FN:-${MODEL_NAME}-fn}"
MODEL_REPO_FN="unsloth/functiongemma-270m-it-GGUF"
MODEL_FILE_FN="functiongemma-270m-it-Q4_K_M.gguf"
MODEL_URL_FN="https://huggingface.co/${MODEL_REPO_FN}/resolve/main/${MODEL_FILE_FN}?download=true"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/terminal-ai}"
BIN_DIR="${HOME}/.local/bin"
AI_BIN="${BIN_DIR}/ai"

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

create_ai_command() {
    mkdir -p "$BIN_DIR"

    cat >"$AI_BIN" <<'AI_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_NAME="${TERMINAL_AI_MODEL:-terminal}"
MODEL_LABEL="${MODEL_NAME} (default · Qwen-0.5B-Coder-El-Terminalo)"
IS_DEV=0

usage() {
    cat <<'EOF'
Usage:
  ai "description of the command"
  ai description of the command
  ai -d "description of the command"   # developer model: Qwen2.5-Coder-0.5B-Instruct
  ai -g "description of the command"   # generalist model: gemma-3-270m-it
  ai -f "description of the command"   # function-calling model: FunctionGemma 270M

Example:
  ai "show the 10 processes using the most memory"
  ai -d "write a python function that sorts a list"

After the command is generated:
  e = execute
  c = copy
  q = cancel
  ENTER = cancel

With -d, choosing [e] first detects the generated code's language and, if a
matching interpreter/compiler is installed, writes it to a temporary file and
runs it that way instead of as a shell command.

Variables:
  TERMINAL_AI_MODEL      (default,          default: terminal)
  TERMINAL_AI_MODEL_DEV  (-d, developer,    default: terminal-dev)
  TERMINAL_AI_MODEL_GEN  (-g, generalist,   default: terminal-gen)
  TERMINAL_AI_MODEL_FN   (-f, function,     default: terminal-fn)
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

while getopts ":dgfh" OPT; do
    case "$OPT" in
        d)
            MODEL_NAME="${TERMINAL_AI_MODEL_DEV:-terminal-dev}"
            MODEL_LABEL="${MODEL_NAME} (developer · Qwen2.5-Coder-0.5B-Instruct)"
            IS_DEV=1
            ;;
        g)
            MODEL_NAME="${TERMINAL_AI_MODEL_GEN:-terminal-gen}"
            MODEL_LABEL="${MODEL_NAME} (generalist · gemma-3-270m-it)"
            ;;
        f)
            MODEL_NAME="${TERMINAL_AI_MODEL_FN:-terminal-fn}"
            MODEL_LABEL="${MODEL_NAME} (function-calling · FunctionGemma 270M)"
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            printf 'Invalid option: -%s\n\n' "$OPTARG" >&2
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -gt 0 ]] || { usage; exit 1; }

QUERY="$*"
OS_NAME="linux"
[[ "$(uname -s)" == "Darwin" ]] && OS_NAME="macos"

SHELL_NAME="$(basename "${SHELL:-bash}")"
CWD="$PWD"

PROMPT="OS: ${OS_NAME}. Shell: ${SHELL_NAME}. Current directory: ${CWD}. Request: ${QUERY}"

# strip CR, occasional fences, and blank lines at the edges
CMD="$(
    ollama run "$MODEL_NAME" "$PROMPT" |
    tr -d '\r' |
    sed -e '/^[[:space:]]*```/d' \
        -e '/^[[:space:]]*$/d'
)"

if [[ -z "$CMD" ]]; then
    printf 'No command was generated.\n' >&2
    exit 2
fi

printf '\n\033[2m[LLM: %s]\033[0m\n' "$MODEL_LABEL"
printf '\n\033[1;36m%s\033[0m\n\n' "$CMD"
printf '[e] execute  [c] copy  [q/Enter] cancel: '
IFS= read -r -n 1 ACTION || true
printf '\n'

case "${ACTION:-}" in
    e|E)
        if [[ "$IS_DEV" -eq 1 ]]; then
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

configure_shell() {
    touch "$RC_FILE"

    local begin="# >>> terminal-ai >>>"
    local end="# <<< terminal-ai <<<"

    # Remove old block to keep the installation idempotent.
    if grep -Fq "$begin" "$RC_FILE"; then
        awk -v b="$begin" -v e="$end" '
            $0 == b {skip=1; next}
            $0 == e {skip=0; next}
            !skip {print}
        ' "$RC_FILE" >"${RC_FILE}.tmp"
        mv "${RC_FILE}.tmp" "$RC_FILE"
    fi

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

ai() {
    command "\$HOME/.local/bin/ai" "\$@"
}
${end}
EOF

    ok "ai() function added to $RC_FILE"
}

smoke_test() {
    local name="$1" label="$2"
    local result

    info "Testing model '${name}' (${label})..."
    result="$(ollama run "$name" "OS: linux. Shell: bash. Request: list running docker containers" 2>/dev/null || true)"

    if [[ -n "$result" ]]; then
        printf '\nModel test (%s):\n  %s\n\n' "$label" "$result"
    else
        warn "Model '${name}' was installed, but the test returned no content."
    fi
}

main() {
    printf '\n=== Terminal AI / Qwen 0.5B installer ===\n\n'

    setup_sudo
    detect_os

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

    download_model "$MODEL_FILE" "$MODEL_URL" "Qwen-0.5B-Coder-El-Terminalo (default)"
    create_modelfile "$MODEL_FILE" "$INSTALL_DIR/Modelfile" chatml "$SYSTEM_PROMPT_SHELL"
    register_model "$MODEL_NAME" "$INSTALL_DIR/Modelfile"

    download_model "$MODEL_FILE_DEV" "$MODEL_URL_DEV" "Qwen2.5-Coder-0.5B-Instruct (developer)"
    create_modelfile "$MODEL_FILE_DEV" "$INSTALL_DIR/Modelfile.dev" chatml "$SYSTEM_PROMPT_SHELL"
    register_model "$MODEL_NAME_DEV" "$INSTALL_DIR/Modelfile.dev"

    download_model "$MODEL_FILE_GEN" "$MODEL_URL_GEN" "gemma-3-270m-it (generalist)"
    create_modelfile "$MODEL_FILE_GEN" "$INSTALL_DIR/Modelfile.gen" gemma "$SYSTEM_PROMPT_GENERAL"
    register_model "$MODEL_NAME_GEN" "$INSTALL_DIR/Modelfile.gen"

    download_model "$MODEL_FILE_FN" "$MODEL_URL_FN" "FunctionGemma 270M (function-calling)"
    create_modelfile "$MODEL_FILE_FN" "$INSTALL_DIR/Modelfile.fn" gemma "$SYSTEM_PROMPT_SHELL"
    register_model "$MODEL_NAME_FN" "$INSTALL_DIR/Modelfile.fn"

    create_ai_command
    configure_shell

    smoke_test "$MODEL_NAME" "default"
    smoke_test "$MODEL_NAME_DEV" "developer"
    smoke_test "$MODEL_NAME_GEN" "generalist"
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

Models:
    ${MODEL_NAME}      (default         · Qwen-0.5B-Coder-El-Terminalo)
    ${MODEL_NAME_DEV}  (-d, developer   · Qwen2.5-Coder-0.5B-Instruct)
    ${MODEL_NAME_GEN}  (-g, generalist  · gemma-3-270m-it)
    ${MODEL_NAME_FN}   (-f, function    · FunctionGemma 270M)

Files:
    ${INSTALL_DIR}/${MODEL_FILE}
    ${INSTALL_DIR}/${MODEL_FILE_DEV}
    ${INSTALL_DIR}/${MODEL_FILE_GEN}
    ${INSTALL_DIR}/${MODEL_FILE_FN}
    ${INSTALL_DIR}/Modelfile{,.dev,.gen,.fn}
    ${AI_BIN}

Every response from the 'ai' command shows which LLM generated it.

The generated command is NOT executed automatically.
You need to choose [e] to run it.

EOF
}

main "$@"
