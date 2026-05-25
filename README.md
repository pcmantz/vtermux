# `vtermux`

Embed and manage multiple named instances of the same terminal application in Emacs.

## Introduction

Thanks to modern LLM-powered development, new terminal applications are being cranked out every day.
One can already embed these in Emacs with `vterm` and `multi-vterm`, but cycling through `vterm
<1>`, `vterm <2>`, and `vterm <3>` gets really tedious. `multi-vterm` helps, but it provides only
one terminal per directory, which if you are running multiple applications in a project or directory
(e.g., your preferred shell and LLM agent), then you already have to do some hackery to get that to
work.

Enter `vtermux`. Multiple different TUI and CLI applications can be configured to run with their own
commands, independently of each other. And if that isn't enough, more instances of the same application can be created and labeled.

## Installation

``` elisp
(use-package vtermux
  :ensure nil
  :elpaca (vtermux :host nil :repo "~/git/vtermux")
  :after vterm
  :config
  ;; shells
  (vtermux-define bash)
  (vtermux-define zsh)

  ;; dev tools
  (vtermux-define pitchfork :args "tui")
  (vtermux-define claude)
  (vtermux-define opencode :args "-m")

  ;; ops tools
  (vtermux-define btop)
  (vtermux-define htop))
```

## Configuration

### Global options

| Custom variable | Default | Description |
|---|---|---|
| `vtermux-kill-buffer-on-exit` | `t` | Kill the buffer when the underlying process exits. Set to `nil` to keep dead buffers. |
| `vtermux-command-directory` | `:project` | Directory resolution method — see [Directory resolution](#directory-resolution). |

### Per-definition options

Pass keyword arguments to `vtermux-define`:

``` elisp
(vtermux-define claude
  :program "claude"
  :buffer-name "claude"
  :args "-m"
  :directory :project)
```

| Keyword | Default | Description |
|---|---|---|
| `:program` | `symbol-name` of NAME | Executable to run. |
| `:buffer-name` | `symbol-name` of NAME | Base name for generated buffers. |
| `:args` | `nil` | Command-line arguments passed to the program. Can be a string or a list of strings. |
| `:key` | `nil` | Single-character shortcut for `vtermux-run`. |
| `:directory` | `vtermux-command-directory` | Directory resolution override for this definition only — see [Directory resolution](#directory-resolution). |

### Generated customization variables

Each definition also creates `defcustom` / `defvar` symbols so you can change
settings after definition or via `customize`:

- `NAME-program`
- `NAME-buffer-name`
- `NAME-args`
- `NAME-command-directory`

## Usage

### Commands

Each `vtermux-define` call generates five interactive commands.
Additionally, `vtermux-run` provides a global single-character launcher
for apps registered with a `:key`.

#### Per-app Commands

| Command | Description |
|---|---|
| `NAME` | Launch an instance. If none exist, creates one. If any exist, prompts for a label (defaults to the first unused number). |
| `NAME-new` | Always create a new instance. Always prompts for a label. |
| `NAME-select` | Pick any live instance via `completing-read`. |
| `NAME-next` | Cycle forward through instances in the current scope. |
| `NAME-prev` | Cycle backward through instances in the current scope. |

`NAME-next` and `NAME-prev` accept a numeric prefix argument to skip that many buffers.

#### Global Launcher

| Command | Description |
|---|---|
| `vtermux-run` | Single-character dispatch. Apps with a `:key` appear in the prompt. Press `?` for help. |

### Directory resolution

The working directory for a terminal instance is resolved in one of three ways:

| Method | Description |
|---|---|
| `:project` | Use `project-root` of the current project (default). |
| `:buffer` | Use `default-directory` of the current buffer. |
| `:prompt` | Always prompt for a directory. |

- The global default is set by `vtermux-command-directory`.
- Per-definition overrides use the `:directory` keyword.
- Prepend `\\[universal-argument]` (`C-u`) to any command to force a prompt.
- On resolution failure (e.g., no project), falls back to prompting.

### Buffer naming

```
*<bufname> - <directory>*             unnamed instance
*<bufname> - <directory> (<label>)*   labeled instance
```

Labels default to the next unused positive integer (matching tmux-style
behavior), but you can enter any string.

### Example workflow

``` elisp
(require 'vtermux)

(vtermux-define btop)                          ;; M-x btop, btop-next, etc.
(vtermux-define claude :program "claude")      ;; M-x claude
(vtermux-define opencode :program "opencode"   ;; M-x opencode
               :args "-m" :directory :buffer)
```

- `M-x btop` — launches btop in the current project.
- `M-x btop` again — prompts for a label (default "1") to create a second instance.
- `M-x btop-next` / `M-x btop-prev` — cycles through scoped instances.
- `M-x opencode` — runs opencode with `-m` in the current buffer's directory.
- `C-u M-x opencode` — same, but always prompts for the directory.
