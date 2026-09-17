# ai-terminal

Natural-language-to-shell-command generator powered by [Ollama](https://ollama.com) and small local LLMs.

Describe what you want to do in plain English (or any language), and `ai` turns it into a shell command you can review, copy, or run — nothing is executed automatically.

```
$ ai "show the 10 processes using the most memory"

[LLM: terminal (default · Qwen-0.5B-Coder-El-Terminalo)]

ps aux --sort=-%mem | head -n 11

[e] run  [c] copy  [q/Enter] cancel:
```

## Features

- **Fully local** — runs entirely through Ollama, no API keys, no data leaves your machine.
- **Multiple models, one command** — pick the model that best fits your prompt via a flag, no need to change environment variables by hand.
- **Review before you run** — every generated command is shown first; you choose to execute (`e`), copy to the clipboard (`c`), or cancel (`q` / Enter).
- **Shows which LLM answered** — every response prints the model that generated it, so you always know which one produced a given command.
- **Cross-platform installer** — one script sets up Ollama, the systemd service (or LaunchAgent on macOS), the models, and the `ai` shell function.

## Models

The installer downloads and registers four small GGUF models in Ollama. Each one is exposed through a flag on the `ai` command:

| Flag | Purpose            | Model                                          | Ollama name (default)   |
|------|--------------------|-------------------------------------------------|--------------------------|
| _(none)_ | Default            | Qwen-0.5B-Coder-El-Terminalo (Q8)              | `terminal`               |
| `-d` | Developer          | Qwen2.5-Coder-0.5B-Instruct (Q4_K_M)           | `terminal-dev`           |
| `-g` | Generalist         | google/gemma-3-270m-it (Q4_K_M)                | `terminal-gen`           |
| `-f` | Function-calling   | FunctionGemma 270M (Q4_K_M)                    | `terminal-fn`            |

All models are tiny (under ~500 MB each) so they run comfortably on CPU-only machines, laptops, and low-resource environments.

## Requirements

- Linux (Ubuntu, Debian, Fedora, CentOS/RHEL/Rocky/AlmaLinux, Arch/Omarchy/Manjaro/EndeavourOS), WSL, or macOS.
- `curl`.
- `bash` or `zsh`.
- `sudo` (used automatically when not running as root; installs system dependencies and configures the systemd service).
- Internet access to download the models from Hugging Face (roughly 1.5–2 GB in total, across the four models).

## Installation

```bash
git clone <this-repo-url>
cd ai-terminal
chmod +x install-terminal-ai.sh
./install-terminal-ai.sh
```

The installer will:

1. Install OS-level dependencies (`curl`, CA certificates).
2. Install Ollama if it isn't already present.
3. Configure the Ollama service (systemd on Linux, a WSL boot command, or a LaunchAgent on macOS).
4. Wait for the Ollama server to come up.
5. Download all four GGUF models to `~/.local/share/terminal-ai` and register them in Ollama (`ollama create`).
6. Install the `ai` executable to `~/.local/bin/ai`.
7. Add a `PATH` entry, environment variables, and an `ai()` shell function to `~/.bashrc` or `~/.zshrc`.
8. Run a smoke test against each registered model.

After installation, open a new terminal or reload your shell configuration:

```bash
source ~/.bashrc   # or source ~/.zshrc
```

### Optional environment variables (installer)

Set these before running the installer to customize install locations or the base model name:

| Variable       | Default                          | Description                                   |
|----------------|-----------------------------------|------------------------------------------------|
| `MODEL_NAME`   | `terminal`                        | Base name used for all four registered models (`terminal`, `terminal-dev`, `terminal-gen`, `terminal-fn`). |
| `INSTALL_DIR`  | `$HOME/.local/share/terminal-ai`  | Where GGUF files and Modelfiles are stored.    |

```bash
MODEL_NAME=myai INSTALL_DIR="$HOME/.local/share/myai" ./install-terminal-ai.sh
```

## Usage

```
ai "<description of what you want to do>"
ai -d "<description>"   # use the developer model (Qwen2.5-Coder-0.5B-Instruct)
ai -g "<description>"   # use the generalist model (gemma-3-270m-it)
ai -f "<description>"   # use the function-calling model (FunctionGemma 270M)
```

Quotes are optional — `ai list running docker containers` works the same as `ai "list running docker containers"`.

### Examples

```bash
ai "show the 10 processes using the most memory"
ai "list running docker containers"
ai -d "write a python function that sorts a list"
ai -g "explain what an IP address is"
ai -f "find files larger than 1 GB in /var"
```

After a command is generated, you're prompted for an action:

- `e` — execute the command in your current shell.
- `c` — copy the command to the clipboard (`wl-copy`, `xclip`, `xsel`, `pbcopy`, or `clip.exe`, whichever is available).
- `q` or **Enter** — cancel, do nothing.

Every response prints which LLM produced it, e.g. `[LLM: terminal-dev (developer · Qwen2.5-Coder-0.5B-Instruct)]`, so you always know which model answered — no flag prints the default model, and each flag prints its corresponding model.

### Runtime environment variables

These are exported by the installer into your shell rc file and can be overridden per-session:

| Variable                | Used by | Default        |
|--------------------------|---------|----------------|
| `TERMINAL_AI_MODEL`      | default | `terminal`     |
| `TERMINAL_AI_MODEL_DEV`  | `-d`    | `terminal-dev` |
| `TERMINAL_AI_MODEL_GEN`  | `-g`    | `terminal-gen` |
| `TERMINAL_AI_MODEL_FN`   | `-f`    | `terminal-fn`  |

## Uninstalling

```bash
rm -f ~/.local/bin/ai
rm -rf ~/.local/share/terminal-ai
ollama rm terminal terminal-dev terminal-gen terminal-fn
```

Then remove the block delimited by `# >>> terminal-ai >>>` and `# <<< terminal-ai <<<` from your `~/.bashrc` or `~/.zshrc`.

## Safety

`ai` never runs the generated command on its own. You always see the command first and must explicitly choose `e` to execute it.
