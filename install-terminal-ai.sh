#!/usr/bin/env bash
# install-terminal-ai.sh
#
# Instala e configura:
#   - Ollama
#   - serviço Ollama (systemd no Linux, LaunchAgent no macOS)
#   - modelo padrão: Qwen-0.5B-Coder-El-Terminalo Q8 GGUF ("terminal")
#   - modelo developer (-d): Qwen2.5-Coder-0.5B-Instruct Q4_K_M ("terminal-dev")
#   - modelo generalist (-g): google/gemma-3-270m-it Q4_K_M ("terminal-gen")
#   - modelo function-calling (-f): FunctionGemma 270M Q4_K_M ("terminal-fn")
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

# Modelo "developer" (-d): otimizado para geração de código/comandos.
MODEL_NAME_DEV="${MODEL_NAME_DEV:-${MODEL_NAME}-dev}"
MODEL_REPO_DEV="Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF"
MODEL_FILE_DEV="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
MODEL_URL_DEV="https://huggingface.co/${MODEL_REPO_DEV}/resolve/main/${MODEL_FILE_DEV}?download=true"

# Modelo "generalist" (-g): modelo compacto de propósito geral do Google.
MODEL_NAME_GEN="${MODEL_NAME_GEN:-${MODEL_NAME}-gen}"
MODEL_REPO_GEN="unsloth/gemma-3-270m-it-GGUF"
MODEL_FILE_GEN="gemma-3-270m-it-Q4_K_M.gguf"
MODEL_URL_GEN="https://huggingface.co/${MODEL_REPO_GEN}/resolve/main/${MODEL_FILE_GEN}?download=true"

# Modelo "function-calling" (-f): FunctionGemma, especializado em chamadas de função/tools.
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
    local file="$1" url="$2" label="$3"

    mkdir -p "$INSTALL_DIR"

    if [[ -s "$INSTALL_DIR/$file" ]]; then
        ok "GGUF já existe: $INSTALL_DIR/$file"
        return
    fi

    info "Baixando ${label} (${file})..."
    curl -fL --retry 3 --retry-delay 2 \
        --progress-bar \
        "$url" \
        -o "$INSTALL_DIR/$file.part"

    mv "$INSTALL_DIR/$file.part" "$INSTALL_DIR/$file"
    ok "${label} baixado."
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

    SYSTEM_PROMPT="You are a shell command generator. OS: ${os_prompt}, Shell: ${shell_prompt}. Output ONLY the command. Never wrap commands in markdown fences."
}

# create_modelfile <arquivo .gguf> <caminho do Modelfile> <template: chatml|gemma>
create_modelfile() {
    local file="$1" modelfile_path="$2" template="$3"

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

SYSTEM """${SYSTEM_PROMPT}"""
EOF
            ;;
        gemma)
            # Gemma não possui papel "system" próprio: o conteúdo é embutido no
            # primeiro turno do usuário, seguindo a convenção usada pela comunidade
            # em Modelfiles do Ollama para a família Gemma.
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

SYSTEM """${SYSTEM_PROMPT}"""
EOF
            ;;
        *)
            die "Template de Modelfile desconhecido: ${template}"
            ;;
    esac

    ok "Modelfile criado em $modelfile_path"
}

# register_model <nome no Ollama> <caminho do Modelfile>
register_model() {
    local name="$1" modelfile_path="$2"

    info "Registrando modelo '${name}' no Ollama..."
    (
        cd "$(dirname "$modelfile_path")"
        ollama create "$name" -f "$(basename "$modelfile_path")"
    )
    ok "Modelo '${name}' registrado."
}

create_ai_command() {
    mkdir -p "$BIN_DIR"

    cat >"$AI_BIN" <<'AI_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_NAME="${TERMINAL_AI_MODEL:-terminal}"
MODEL_LABEL="${MODEL_NAME} (padrão · Qwen-0.5B-Coder-El-Terminalo)"

usage() {
    cat <<'EOF'
Uso:
  ai "descrição do comando"
  ai descrição do comando
  ai -d "descrição do comando"   # modelo developer: Qwen2.5-Coder-0.5B-Instruct
  ai -g "descrição do comando"   # modelo generalist: gemma-3-270m-it
  ai -f "descrição do comando"   # modelo function-calling: FunctionGemma 270M

Exemplo:
  ai "mostrar os 10 processos que mais usam memória"
  ai -d "escrever uma função em python que ordena uma lista"

Após gerar o comando:
  e = executar
  c = copiar
  q = cancelar
  ENTER = cancelar

Variáveis:
  TERMINAL_AI_MODEL      (padrão,          padrão: terminal)
  TERMINAL_AI_MODEL_DEV  (-d, developer,   padrão: terminal-dev)
  TERMINAL_AI_MODEL_GEN  (-g, generalist,  padrão: terminal-gen)
  TERMINAL_AI_MODEL_FN   (-f, function,    padrão: terminal-fn)
EOF
}

[[ $# -gt 0 ]] || { usage; exit 1; }

while getopts ":dgfh" OPT; do
    case "$OPT" in
        d)
            MODEL_NAME="${TERMINAL_AI_MODEL_DEV:-terminal-dev}"
            MODEL_LABEL="${MODEL_NAME} (developer · Qwen2.5-Coder-0.5B-Instruct)"
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
            printf 'Opção inválida: -%s\n\n' "$OPTARG" >&2
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

printf '\n\033[2m[LLM: %s]\033[0m\n' "$MODEL_LABEL"
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

    # Remove linhas em branco finais para não acumular espaço a cada reinstalação.
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

    ok "Função ai() adicionada em $RC_FILE"
}

smoke_test() {
    local name="$1" label="$2"
    local result

    info "Testando o modelo '${name}' (${label})..."
    result="$(ollama run "$name" "OS: linux. Shell: bash. Request: list running docker containers" 2>/dev/null || true)"

    if [[ -n "$result" ]]; then
        printf '\nTeste do modelo (%s):\n  %s\n\n' "$label" "$result"
    else
        warn "O modelo '${name}' foi instalado, mas o teste não retornou conteúdo."
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

    download_model "$MODEL_FILE" "$MODEL_URL" "Qwen-0.5B-Coder-El-Terminalo (padrão)"
    create_modelfile "$MODEL_FILE" "$INSTALL_DIR/Modelfile" chatml
    register_model "$MODEL_NAME" "$INSTALL_DIR/Modelfile"

    download_model "$MODEL_FILE_DEV" "$MODEL_URL_DEV" "Qwen2.5-Coder-0.5B-Instruct (developer)"
    create_modelfile "$MODEL_FILE_DEV" "$INSTALL_DIR/Modelfile.dev" chatml
    register_model "$MODEL_NAME_DEV" "$INSTALL_DIR/Modelfile.dev"

    download_model "$MODEL_FILE_GEN" "$MODEL_URL_GEN" "gemma-3-270m-it (generalist)"
    create_modelfile "$MODEL_FILE_GEN" "$INSTALL_DIR/Modelfile.gen" gemma
    register_model "$MODEL_NAME_GEN" "$INSTALL_DIR/Modelfile.gen"

    download_model "$MODEL_FILE_FN" "$MODEL_URL_FN" "FunctionGemma 270M (function-calling)"
    create_modelfile "$MODEL_FILE_FN" "$INSTALL_DIR/Modelfile.fn" gemma
    register_model "$MODEL_NAME_FN" "$INSTALL_DIR/Modelfile.fn"

    create_ai_command
    configure_shell

    smoke_test "$MODEL_NAME" "padrão"
    smoke_test "$MODEL_NAME_DEV" "developer"
    smoke_test "$MODEL_NAME_GEN" "generalist"
    smoke_test "$MODEL_NAME_FN" "function-calling"

    cat <<EOF

Instalação concluída.

Abra um novo terminal ou execute:

    source "$RC_FILE"

Exemplos:

    ai "mostrar os 10 processos que mais consomem memória"
    ai "mostrar containers docker em execução"
    ai -d "escrever uma função em python que ordena uma lista"
    ai -g "explicar o que é um endereço IP"
    ai -f "encontrar arquivos maiores que 1 GB em /var"

Modelos:
    ${MODEL_NAME}      (padrão          · Qwen-0.5B-Coder-El-Terminalo)
    ${MODEL_NAME_DEV}  (-d, developer   · Qwen2.5-Coder-0.5B-Instruct)
    ${MODEL_NAME_GEN}  (-g, generalist  · gemma-3-270m-it)
    ${MODEL_NAME_FN}   (-f, function    · FunctionGemma 270M)

Arquivos:
    ${INSTALL_DIR}/${MODEL_FILE}
    ${INSTALL_DIR}/${MODEL_FILE_DEV}
    ${INSTALL_DIR}/${MODEL_FILE_GEN}
    ${INSTALL_DIR}/${MODEL_FILE_FN}
    ${INSTALL_DIR}/Modelfile{,.dev,.gen,.fn}
    ${AI_BIN}

Cada resposta do comando 'ai' exibe qual LLM foi usado para gerá-la.

O comando gerado NÃO é executado automaticamente.
Você precisa escolher [e] para executá-lo.

EOF
}

main "$@"
