# ai-terminal

![ai-terminal demo: three examples using the default, developer (-d) and generalist (-g) models](assets/demo.gif)

Natural-language-to-shell-command generator powered by [Ollama](https://ollama.com) and small local LLMs.

Describe what you want to do in plain English (or any language), and `ai` turns it into a shell command you can review, copy, or run — nothing is executed automatically.

```bash
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
- **Hardware-aware** — with an AMD or NVIDIA GPU with 8 GB+ of VRAM, terminal commands use Qwen2.5-Coder-7B-Instruct and `-g` uses Qwen3.5-4B. Re-run the installer at any time to re-detect the hardware and update the models.
- **Automatic model swapping** — when the requested model doesn't fit in memory next to the ones already loaded, `ai` unloads the others first.

## Models

The installer registers four models in Ollama (the CPU profile below; see [GPU profile](#gpu-profile) for what changes with a GPU). Each one is exposed through a flag on the `ai` command:

| Flag | Purpose            | Model                                          | Ollama name (default)   |
|------|--------------------|-------------------------------------------------|--------------------------|
| _(none)_ | Default            | Qwen-0.5B-Coder-El-Terminalo (Q8)              | `terminal`               |
| `-d` | Developer          | Qwen2.5-Coder-0.5B-Instruct (Q4_K_M)           | `terminal-dev`           |
| `-g` | Generalist         | meta-llama/Llama-3.2-1B-Instruct (Q4_K_M)      | `terminal-gen`           |
| `-f` | Function-calling   | FunctionGemma 270M (Q4_K_M)                    | `terminal-fn`            |

Every model runs with a **32k context window** (`num_ctx 32768`), on both profiles; change it with the `NUM_CTX` installer variable.

All models are small enough to run comfortably on CPU-only machines, laptops, and low-resource environments (the generalist model is the largest, at ~800 MB).

### GPU profile

On every run, the installer detects the hardware (`nvidia-smi` for NVIDIA, including WSL; the `amdgpu` sysfs entries for AMD on Linux). If it finds an AMD or NVIDIA GPU with **8 GB of VRAM or more**, two models are upgraded to larger models from the Ollama library:

| Flag     | Purpose              | CPU profile (default)              | GPU profile (≥ 8 GB VRAM)                                    |
|----------|----------------------|------------------------------------|--------------------------------------------------------------|
| _(none)_ | Terminal commands    | Qwen-0.5B-Coder-El-Terminalo (Q8)  | Qwen2.5-Coder-7B-Instruct (`qwen2.5-coder:7b-instruct`, ~4.7 GB) |
| `-g`     | Generalist           | Llama-3.2-1B-Instruct (Q4_K_M)     | Qwen3.5-4B (`qwen3.5:4b-q4_K_M`, ~3.3 GB, thinking disabled) |
| `-d`     | Developer            | Qwen2.5-Coder-0.5B-Instruct        | _(same)_                                                     |
| `-f`     | Function-calling     | FunctionGemma 270M                 | _(same)_                                                     |

With the GPU profile the installer also:

- installs Ollama's GPU backend on Arch/Omarchy, where it is packaged separately (`ollama-cuda` for NVIDIA, `ollama-vulkan` for AMD). The official installer used on other distros already bundles it;
- adds a systemd drop-in (`/etc/systemd/system/ollama.service.d/terminal-ai.conf`) with flash attention and an 8-bit KV cache, so the 32k contexts take less VRAM (plus `OLLAMA_VULKAN=1` on AMD).

The installer is safe to run repeatedly: every run re-detects the hardware and switches the models, the drop-in, and the labels shown by `ai` to match (e.g. after adding or removing a GPU). Library models the installer pulled and no longer needs are removed. If a model can't be pulled (for example, Ollama is too old), that model falls back to its CPU version. The detected profile is recorded in `~/.local/share/terminal-ai/profile`.

### Model swapping

On an 8 GB card the 7B coder (~6 GB) and Qwen3.5-4B (~4.3 GB), both with 32k context, don't fit in VRAM together. Before each request, `ai` checks whether the requested model fits next to the models already loaded (VRAM minus a reserve of `GPU_VRAM_RESERVE_MB` on the GPU profile, free RAM on the CPU profile). If it doesn't, `ai` unloads its other models (`ollama stop`), largest first, until it fits, and prints which one it unloaded:

```
[Not enough memory for terminal-gen: unloading terminal:latest (5.6 GB)]
```

The first decisions use the installer's estimates. After each run, `ai` records how much memory the model really used (from `ollama ps`) in `~/.local/share/terminal-ai/memory` and uses that from then on. Models that don't belong to terminal-ai are never unloaded, but their memory is counted.

## Requirements

- Linux (Ubuntu, Debian, Fedora, CentOS/RHEL/Rocky/AlmaLinux, Arch/Omarchy/Manjaro/EndeavourOS), WSL, or macOS.
- `curl`.
- `bash` or `zsh`.
- `sudo` (used automatically when not running as root; installs system dependencies and configures the systemd service).
- Internet access to download the models from Hugging Face (roughly 2–2.5 GB in total, across the four models), plus ~8 GB from the Ollama library with the GPU profile.

## Installation

### Quick install

Downloads the installer script and runs it directly, without cloning the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/Giuliano-sn/ai-terminal/main/install-terminal-ai.sh | bash
```

### Manual install

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
5. Detect the GPU and pick the hardware profile (see [GPU profile](#gpu-profile)); with the GPU profile, install the GPU backend if needed and pull `qwen2.5-coder:7b-instruct` and `qwen3.5:4b-q4_K_M`.
6. Download the GGUF models to `~/.local/share/terminal-ai` and register them in Ollama (`ollama create`).
7. Create the per-model harness files under `~/.local/share/terminal-ai/harness` (skipped if they already exist).
8. Install the `ai` executable to `~/.local/bin/ai`.
9. Add a `PATH` entry, environment variables, and an `ai()` shell function to `~/.bashrc` or `~/.zshrc`.
10. Run a smoke test against each registered model.

After installation, open a new terminal or reload your shell configuration:

```bash
source ~/.bashrc   # or source ~/.zshrc
```

### Uninstall

```bash
./install-terminal-ai.sh --remove
```

This removes everything the installer created:

1. The four registered models (`ollama rm`), plus the GPU profile's library models if the installer pulled them.
2. The `~/.local/share/terminal-ai` directory (GGUF files, Modelfiles, and harness files).
3. The `~/.local/bin/ai` executable.
4. The managed block in `~/.bashrc` and `~/.zshrc`.
5. The GPU tuning drop-in for the Ollama service, if present.

Ollama itself is left installed, since it may be used by other applications — the command prints the steps to remove it too, if you want to.

### Optional environment variables (installer)

Set these before running the installer to customize install locations or the base model name:

| Variable       | Default                          | Description                                   |
|----------------|-----------------------------------|------------------------------------------------|
| `MODEL_NAME`   | `terminal`                        | Base name used for all four registered models (`terminal`, `terminal-dev`, `terminal-gen`, `terminal-fn`). |
| `INSTALL_DIR`  | `$HOME/.local/share/terminal-ai`  | Where GGUF files and Modelfiles are stored.    |
| `NUM_CTX`      | `32768`                           | Context window (tokens) of every model, on both profiles. |
| `HW_PROFILE`   | `auto`                            | `auto` detects the hardware; `gpu` or `cpu` forces a profile. |
| `GPU_CODER_MODEL` | `qwen2.5-coder:7b-instruct`    | Library model for terminal commands (default model) with the GPU profile. |
| `GPU_GEN_MODEL` | `qwen3.5:4b-q4_K_M`              | Library model for `-g` with the GPU profile. |
| `GPU_VRAM_RESERVE_MB` | `768`                      | VRAM left for the desktop when deciding whether models fit together. |
| `GPU_MIN_VRAM_MB` | `7680`                         | Minimum VRAM for the GPU profile. 8 GB cards report slightly less than 8192 MiB, hence the slack. |

```bash
MODEL_NAME=myai INSTALL_DIR="$HOME/.local/share/myai" ./install-terminal-ai.sh
HW_PROFILE=cpu ./install-terminal-ai.sh   # keep the small CPU model even with a GPU
```

## Usage

```bash
ai "<description of what you want to do>"   # default model (El-Terminalo, or Qwen2.5-Coder-7B with a GPU)
ai -d "<description>"   # use the developer model (Qwen2.5-Coder-0.5B-Instruct)
ai -g "<description>"   # use the generalist model (Llama-3.2-1B, or Qwen3.5-4B with a GPU)
ai -f "<description>"   # use the function-calling model (FunctionGemma 270M)
ai -H [-d|-g|-f]         # edit that model's harness file in $EDITOR/$VISUAL
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

- `e` — execute the command in your current shell (not offered with `-g`, since the generalist model answers in plain text instead of generating a command).
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
| `TERMINAL_AI_HARNESS_DIR`| harness folder | `~/.local/share/terminal-ai/harness` |

## Harness (custom instructions)

Each model has its own small, plain-text **harness file** — extra instructions that get appended to every prompt sent to that model, on top of the OS/shell/directory context and the language directive `ai` already adds automatically.

| File           | Used by |
|----------------|---------|
| `default.txt`  | default model |
| `developer.txt`| `-d` |
| `generalist.txt`| `-g` |
| `function.txt` | `-f` |

They live in `~/.local/share/terminal-ai/harness/` (or `$TERMINAL_AI_HARNESS_DIR` if set) and are created with sensible starter content on install — they are never overwritten on a reinstall, so your edits are safe.

Rules:
- Lines starting with `#` are treated as comments and ignored.
- Every other line is appended, in order, to the end of the prompt (after the request), so keep instructions short and specific — e.g. "Never use `sudo`." or "Prefer `awk` over `sed` for column extraction."

Edit a harness file with the built-in flag. On [Omarchy](https://omarchy.org/) it opens through `omarchy launch editor` (your configured default editor); elsewhere it opens `$VISUAL`, falling back to `$EDITOR`, falling back to `vi`:

```bash
ai -H         # edit the default model's harness
ai -H -d      # edit the developer model's harness
ai -H -g      # edit the generalist model's harness
ai -H -f      # edit the function-calling model's harness
```

Or edit the files directly — they're plain text:

```bash
"${EDITOR:-vi}" ~/.local/share/terminal-ai/harness/generalist.txt
```

## Safety

`ai` never runs the generated command on its own. You always see the command first and must explicitly choose `e` to execute it.
