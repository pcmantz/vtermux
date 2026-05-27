# `vtermux`

Embed and manage multiple named instances of the same terminal application in Emacs.

## Introduction

Thanks to modern LLM-powered development, new terminal applications are being cranked out every day.
One can already embed these in Emacs with terminal emulators like `vterm` or `ghostel`, but
cycling through their generic buffer names gets tedious. `multi-vterm` helps, but it provides only
one terminal per directory, which if you are running multiple applications in a project or directory
(e.g., your preferred shell and LLM agent), then you already have to do some hackery to get that to
work.

Enter `vtermux`. Multiple different TUI and CLI applications can be configured to run with their own
commands, independently of each other. And if that isn't enough, more instances of the same application can be created and labeled. The terminal backend is pluggable — use
`vterm`, `ghostel`, or `term`.

## Installation

``` elisp
(use-package vtermux
  :ensure nil
  :elpaca (vtermux :host nil :repo "~/git/vtermux")
  :config
  ;; shells
  (vtermux-define bash)
  (vtermux-define zsh)

  ;; dev tools
  (vtermux-define pitchfork :args "tui")
  (vtermux-define claude)
  (vtermux-define opencode :args "-m")

  ;; ops tools
  (vtermux-define btop :backend ghostel)
  (vtermux-define htop))
```

## Configuration

### Global options

| Custom variable | Default | Description |
|---|---|---|
| `vtermux-backend` | auto (`vterm`→`ghostel`→`term`, first installed) | Terminal backend: `vterm`, `ghostel`, or `term`. |
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
| `:bind` | `nil` | Key sequence string (e.g., `"C-c b"`) defining a global keybinding for this app. |
| `:dispatch` | auto (first unused letter from NAME) | Override the auto-detected dispatch key for `vtermux-run`. A character (e.g., `?b`). |
| `:backend` | `vtermux-backend` | Terminal backend override: `vterm`, `ghostel`, or `term`. |
| `:directory` | `vtermux-command-directory` | Directory resolution override for this definition only — see [Directory resolution](#directory-resolution). |

### Generated customization variables

Each definition also creates `defcustom` / `defvar` symbols so you can change
settings after definition or via `customize`:

- `NAME-program`
- `NAME-buffer-name`
- `NAME-args`
- `NAME-backend`
- `NAME-command-directory`

## Usage

### Commands

Each `vtermux-define` call generates five interactive commands.
Additionally, `vtermux-run` provides a global single-character launcher
for apps with a dispatch key.

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
| `vtermux-run` | Single-character dispatch. Shows colored keys in the prompt. Press a key to launch immediately. Type `?` for help. |

#### Keybinding generation

When `:bind` is set to a key sequence string, `vtermux-define`
generates a global keybinding:

``` elisp
(vtermux-define btop :bind "C-c b")    ;; C-c b launches btop
(vtermux-define claude :bind "C-c c")  ;; C-c c launches claude
```

The dispatch key for `vtermux-run` is auto-generated from the app name
and can be overridden with `:dispatch`:

``` elisp
(vtermux-define btop :bind "C-c b" :dispatch ?t)  ;; dispatch with t, not b
```

### Backends

`vtermux` supports multiple terminal backends. The default is `vterm`.

| Backend | Dependency | Notes |
|---|---|---|
| `vterm` | `vterm` (C module) | Fast, feature-rich. Requires compilation. Default. |
| `ghostel` | `ghostel` (Rust/libghostty) | Modern, uses Ghostty's library. |
| `term` | built-in | No extra dependencies. Slower, but always available. |

Set the global default:

``` elisp
(setq vtermux-backend 'ghostel)
```

Override per-app with `:backend`:

``` elisp
(vtermux-define btop :backend ghostel)
(vtermux-define bash :backend term)
```

Third-party backends can register via `vtermux-register-backend`:

``` elisp
(vtermux-register-backend 'my-backend
  (lambda (name prog args directory)
    ;; Create a terminal buffer named NAME running PROG with ARGS at DIRECTORY.
    ;; Return the live buffer.
    ...))
```

The create function receives four arguments: the desired buffer name, the
program executable string, the arguments (nil, string, or list of strings),
and the working directory. It must return a live buffer.

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

(vtermux-define btop :bind "C-c b")             ;; C-c b launches btop
(vtermux-define claude :program "claude")       ;; M-x claude
(vtermux-define opencode :program "opencode"    ;; M-x opencode
               :args "-m" :directory :buffer)
(vtermux-define htop :backend ghostel)          ;; uses ghostel instead of vterm
```

- `C-c b` — launches btop in the current project.
- `M-x btop` again — prompts for a label (default "1") to create a second instance.
- `M-x btop-next` / `M-x btop-prev` — cycles through scoped instances.
- `M-x opencode` — runs opencode with `-m` in the current buffer's directory.
- `C-u M-x opencode` — same, but always prompts for the directory.
- `M-x vtermux-run` — single-key launcher showing `vtermux b c o:` with colored keys.
