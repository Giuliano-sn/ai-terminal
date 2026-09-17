# VHS tape for assets/demo.gif — regenerate with: vhs assets/demo.tape
# Requires: vhs (https://github.com/charmbracelet/vhs), and `ai` installed
# and on PATH with all four models already registered/warm in Ollama.

Output assets/demo.gif

Require ai

Set Shell "bash"
Set FontSize 16
Set FontFamily "JetBrainsMono Nerd Font"
Set Width 900
Set Height 480
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 40ms

Hide
Type `export PS1='$ '` Enter
Type "clear" Enter
Sleep 500ms
Show

# Default model: shell command generation
Type `ai "show the 10 processes using the most memory"`
Enter
Wait+Screen@20s /cancel:/
Sleep 2s
Type "q"
Enter
Sleep 800ms
Hide
Type "clear" Enter
Sleep 500ms
Show

# Developer model (-d): code generation
Type `ai -d "write a python function that sorts a list"`
Enter
Wait+Screen@20s /cancel:/
Sleep 2.5s
Type "q"
Enter
Sleep 800ms
Hide
Type "clear" Enter
Sleep 500ms
Show

# Generalist model (-g): non-technical question, answered in the system's
# language (LANG here just demonstrates that; ai reads it from the real
# environment normally, no override needed).
Hide
Type `export LANG=pt_PT.UTF-8` Enter
Show
Type `ai -g "qual a velocidade máxima nas auto-estradas em Portugal?"`
Enter
Wait+Screen@20s /cancel:/
Sleep 2.5s
Type "q"
Enter
Sleep 1.5s
