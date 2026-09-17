#!/usr/bin/env bash
# install-terminal-ai.sh
#
# Instala e configura:
#   - Ollama
#   - serviço Ollama (systemd no Linux, LaunchAgent no macOS)
#   - Qwen-0.5B-Coder-El-Terminalo Q8 GGUF
#   - modelo "terminal" no Ollama
#   - comando ~/.local/bin/ai
#   - função ai() no ~/.bashrc ou ~/.zshrc
#
# Plataformas:
#   macOS, WSL, Ubuntu, Fedora, CentOS, AlmaLinux, Omarchy/Arch Linux
#
# Uso:
#   chmod +x install-terminal-ai.sh
#   ./install-terminal-ai.sh
#
# Variáveis opcionais:
#   MODEL_NAME=terminal ./install-terminal-ai.sh
#   INSTALL_DIR="$HOME/.local/share/terminal-ai" ./install-terminal-ai.sh
#
set -Eeuo pipefail

MODEL_NAME="${MODEL_NAME:-terminal}"
MODEL_REPO="albinab/Qwen-0.5B-Coder-El-Terminalo"
MODEL_FILE="Qwen-0.5B-Coder-El-Terminalo-q8.gguf"
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}?download=true"
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

        # Omarchy pode reportar Arch; esta checagem deixa o resultado explícito.
        if have omarchy || [[ -d "$HOME/.local/share/omarchy" ]] ||
           grep -qi 'omarchy' /etc/os-release 2>/dev/null; then
            DISTRO="omarchy"
        fi
    else
        die "Sistema não suportado: $(uname -s)"
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
        info "Sistema: ${DISTRO} / WSL"
    else
        info "Sistema: ${DISTRO}"
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
            warn "Distribuição '$distro' não reconhecida para instalação automática de dependências."
            have curl || die "Instale 'curl' manualmente e execute novamente."
            ;;
    esac
}

install_macos_requirements() {
    if ! have curl; then
        die "curl não encontrado. Instale as Command Line Tools do macOS."
    fi
}

install_ollama() {
    if have ollama; then
        ok "Ollama já instalado: $(ollama --version 2>/dev/null || true)"
        return
    fi

    info "Instalando Ollama..."

    # Instalador oficial atual para macOS/Linux.
    curl -fsSL https://ollama.com/install.sh | sh

    # Alguns instaladores colocam o binário em local que só aparece num novo shell.
    hash -r 2>/dev/null || true

    if ! have ollama; then
        for p in /usr/local/bin/ollama /usr/bin/ollama "$HOME/.local/bin/ollama"; do
            if [[ -x "$p" ]]; then
                export PATH="$(dirname "$p"):$PATH"
                break
            fi
        done
    fi

    have ollama || die "Ollama foi instalado, mas o comando 'ollama' não foi localizado no PATH."
    ok "Ollama instalado."
}

configure_linux_service() {
    local ollama_bin
    ollama_bin="$(command -v ollama)"

    if have systemctl && [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
        info "Configurando Ollama como serviço systemd..."

        # O instalador oficial normalmente cria este serviço.
        # Se não existir, criamos um serviço mínimo.
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
        ok "Serviço Ollama ativo e habilitado no boot."
        return
    fi

    if [[ "$IS_WSL" -eq 1 ]]; then
        warn "WSL sem systemd ativo. Configurando início do Ollama quando a distro WSL iniciar."

        # /etc/wsl.conf suporta comando de boot nas versões modernas do WSL.
        # Preserva o arquivo e adiciona [boot] apenas quando ele ainda não possui command=.
        if [[ -w /etc/wsl.conf ]] || [[ -n "$SUDO" ]]; then
            if ! grep -qE '^[[:space:]]*command[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
                if ! grep -qE '^[[:space:]]*\[boot\][[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
                    printf '\n[boot]\n' | $SUDO tee -a /etc/wsl.conf >/dev/null
                fi
                printf 'command=%s serve >/var/log/ollama.log 2>&1 &\n' "$ollama_bin" |
                    $SUDO tee -a /etc/wsl.conf >/dev/null
                ok "Ollama configurado no boot da distro WSL."
            else
                warn "/etc/wsl.conf já possui um comando [boot]. Não foi sobrescrito."
                warn "Ative systemd no WSL ou incorpore manualmente: ${ollama_bin} serve"
            fi
        fi

        # Inicia nesta sessão também.
        if ! curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
            nohup "$ollama_bin" serve >"$HOME/.ollama-serve.log" 2>&1 &
        fi
        return
    fi

    warn "systemd não está ativo. Criando fallback no shell para iniciar Ollama sob demanda."
}

configure_macos_service() {
    local ollama_bin plist
    ollama_bin="$(command -v ollama)"
    plist="$HOME/Library/LaunchAgents/com.terminal-ai.ollama.plist"

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

    # Se o usuário usa Ollama.app ou Homebrew services, evite criar serviço duplicado.
    if launchctl list 2>/dev/null | grep -qE 'ollama|com\.ollama'; then
        ok "Já existe um serviço Ollama registrado no launchd."
        return
    fi

    info "Criando LaunchAgent do Ollama..."

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

    ok "LaunchAgent criado. Ollama iniciará automaticamente no login do macOS."
}

wait_for_ollama() {
    info "Aguardando o servidor Ollama..."

    for _ in {1..30}; do
        if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
            ok "Servidor Ollama respondendo em 127.0.0.1:11434."
            return
        fi
        sleep 1
    done

    # Último fallback em sistemas sem gerenciador de serviço.
    if ! pgrep -f '[o]llama serve' >/dev/null 2>&1; then
        nohup "$(command -v ollama)" serve >"$HOME/.ollama-serve.log" 2>&1 &
        sleep 2
    fi

    curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 ||
        die "O servidor Ollama não respondeu. Veja os logs do serviço."
}

download_model() {
    mkdir -p "$INSTALL_DIR"

    if [[ -s "$INSTALL_DIR/$MODEL_FILE" ]]; then
        ok "GGUF já existe: $INSTALL_DIR/$MODEL_FILE"
        return
    fi

    info "Baixando ${MODEL_FILE} (~500 MB)..."
    curl -fL --retry 3 --retry-delay 2 \
        --progress-bar \
        "$MODEL_URL" \
        -o "$INSTALL_DIR/$MODEL_FILE.part"

    mv "$INSTALL_DIR/$MODEL_FILE.part" "$INSTALL_DIR/$MODEL_FILE"
    ok "Modelo baixado."
}

create_modelfile() {
    local os_prompt shell_prompt

    if [[ "$OS_FAMILY" == "macos" ]]; then
        os_prompt="macos"
        shell_prompt="zsh"
    else
        os_prompt="linux"
        shell_prompt="$SHELL_NAME"
    fi

    cat >"$INSTALL_DIR/Modelfile" <<EOF
FROM ./${MODEL_FILE}

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

SYSTEM """You are a shell command generator. OS: ${os_prompt}, Shell: ${shell_prompt}. Output ONLY the command. Never wrap commands in markdown fences."""
EOF

    ok "Modelfile criado em $INSTALL_DIR/Modelfile"
}

register_model() {
    info "Registrando modelo '${MODEL_NAME}' no Ollama..."
    (
        cd "$INSTALL_DIR"
        ollama create "$MODEL_NAME" -f Modelfile
    )
    ok "Modelo '${MODEL_NAME}' registrado."
}

create_ai_command() {
    mkdir -p "$BIN_DIR"

    cat >"$AI_BIN" <<'AI_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_NAME="${TERMINAL_AI_MODEL:-terminal}"

usage() {
    cat <<'EOF'
Uso:
  ai "descrição do comando"
  ai descrição do comando

Exemplo:
  ai "mostrar os 10 processos que mais usam memória"

Após gerar o comando:
  e = executar
  c = copiar
  q = cancelar
  ENTER = cancelar

Variáveis:
  TERMINAL_AI_MODEL=terminal
EOF
}

[[ $# -gt 0 ]] || { usage; exit 1; }

QUERY="$*"
OS_NAME="linux"
[[ "$(uname -s)" == "Darwin" ]] && OS_NAME="macos"

SHELL_NAME="$(basename "${SHELL:-bash}")"
CWD="$PWD"

PROMPT="OS: ${OS_NAME}. Shell: ${SHELL_NAME}. Current directory: ${CWD}. Request: ${QUERY}"

# remove CR, fences ocasionais e linhas vazias nas extremidades
CMD="$(
    ollama run "$MODEL_NAME" "$PROMPT" |
    tr -d '\r' |
    sed -e '/^[[:space:]]*```/d' \
        -e '/^[[:space:]]*$/d'
)"

if [[ -z "$CMD" ]]; then
    printf 'Nenhum comando foi gerado.\n' >&2
    exit 2
fi

printf '\n\033[1;36m%s\033[0m\n\n' "$CMD"
printf '[e] executar  [c] copiar  [q/Enter] cancelar: '
IFS= read -r -n 1 ACTION || true
printf '\n'

case "${ACTION:-}" in
    e|E)
        printf '\033[1;33mExecutando:\033[0m %s\n' "$CMD"
        # Executa no shell atual escolhido pelo usuário.
        "${SHELL:-/bin/bash}" -lc "$CMD"
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
            printf 'Nenhum utilitário de clipboard encontrado.\n' >&2
            exit 3
        fi
        printf 'Copiado para o clipboard.\n'
        ;;
    *)
        printf 'Cancelado.\n'
        ;;
esac
AI_SCRIPT

    chmod +x "$AI_BIN"
    ok "Comando criado: $AI_BIN"
}

configure_shell() {
    touch "$RC_FILE"

    local begin="# >>> terminal-ai >>>"
    local end="# <<< terminal-ai <<<"

    # Remove bloco antigo para manter instalação idempotente.
    if grep -Fq "$begin" "$RC_FILE"; then
        awk -v b="$begin" -v e="$end" '
            $0 == b {skip=1; next}
            $0 == e {skip=0; next}
            !skip {print}
        ' "$RC_FILE" >"${RC_FILE}.tmp"
        mv "${RC_FILE}.tmp" "$RC_FILE"
    fi

    cat >>"$RC_FILE" <<EOF

${begin}
export PATH="\$HOME/.local/bin:\$PATH"
export TERMINAL_AI_MODEL="${MODEL_NAME}"

ai() {
    command "\$HOME/.local/bin/ai" "\$@"
}
${end}
EOF

    ok "Função ai() adicionada em $RC_FILE"
}

smoke_test() {
    info "Testando o modelo..."
    local result
    result="$(ollama run "$MODEL_NAME" "OS: linux. Shell: bash. Request: list running docker containers" 2>/dev/null || true)"

    if [[ -n "$result" ]]; then
        printf '\nTeste do modelo:\n  %s\n\n' "$result"
    else
        warn "O modelo foi instalado, mas o teste não retornou conteúdo."
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
    download_model
    create_modelfile
    register_model
    create_ai_command
    configure_shell
    smoke_test

    cat <<EOF

Instalação concluída.

Abra um novo terminal ou execute:

    source "$RC_FILE"

Exemplos:

    ai "mostrar os 10 processos que mais consomem memória"
    ai "mostrar containers docker em execução"
    ai "qual processo está usando a porta 8080"
    ai "encontrar arquivos maiores que 1 GB em /var"

Modelo:
    ${MODEL_NAME}

Arquivos:
    ${INSTALL_DIR}/${MODEL_FILE}
    ${INSTALL_DIR}/Modelfile
    ${AI_BIN}

O comando gerado NÃO é executado automaticamente.
Você precisa escolher [e] para executá-lo.

EOF
}

main "$@"
