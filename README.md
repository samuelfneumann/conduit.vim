# conduit.vim

**Conduit** is a Vim 9 plugin that creates a high-speed, multiplexed SSH "conduit" between your local Vim instance and remote SSH sessions. It transforms your remote SSH connection in the Vim terminal into a first-class extension of your local Vim instance. Run `vim FILE` on the remote SSH server and watch the file magically open in your local Vim instance.

**Quick Start**:
* Open Vim on your local machine.
* Run `:Conduit open HOST`. A Vim terminal opens up with an SSH connection to `HOST`.
* Run `vim file` in the spawned Vim terminal and watch as the file on the remote SSH server magically open in your local vim instance.
* Save the file with `:w` and watch as your local changes magically transfer to the SSH server.

Unlike other methods like mounting via SSHFS or using netrw directly, Conduit focuses on a **push-pull, shell-driven workflow**, while keeping all file operations and progress tracking integrated into your Vim UI.

## 🚀 Why Conduit?

- **Zero-Latency Navigation**: You browse files in the remote shell (where it's fastest) and "teleport" them to your local Vim only when you need to edit.
- **Background Operations**: Large file transfers happen in the background via `rsync` or `scp`. You can keep working while a progress bar in a Vim popup window shows the status.
- **Multiplexed Speed**: It automatically manages SSH `ControlMaster` sockets. Your first connection might take a second; every subsequent file open or transfer is near-instant.
- **No Configuration Overhead**: It deploys its own environment to the remote server on-the-fly. No need to install plugins or edit `.bashrc` on every server you touch.

## 🛠 How it Works (The "Conduit")

1. **The Tunnel**: When you run `:Conduit open`, Vim starts a local listener (using `socat` or `python`) and establishes an SSH reverse tunnel that maps a remote Unix socket to your local listener.
2. **The Injector**: Conduit generates a specialized shell script and uploads it to the remote `/tmp`. This script defines the `lvim` command.
3. **The Signal**: When you type `lvim file.txt` on the server, it sends a small packet through the Unix socket.
4. **The Action**: Your local Vim receives the signal and decides what to do:
   - **Edit**: Opens the file using `scp://` using the *already open* SSH control socket for speed.
   - **Transfer**: Spawns a background `rsync` or `scp` job and creates a popup to track progress.

## 📦 Installation

Requires **Vim 9.1+** with `+job`, `+popupwin`, and `+reltime`.

```bash
mkdir -p ~/.vim/pack/plugins/start
cd ~/.vim/pack/plugins/start
git clone https://github.com/youruser/conduit.vim.git
```

Update your help tags:
```vim
:helptags ~/.vim/pack/plugins/start/conduit.vim/doc
```

Then, read the docs:
```vim
:help conduit
```

## 📋 Requirements

| Feature | Local (Your Machine) | Remote (The Server) |
| :--- | :--- | :--- |
| **Core** | Vim 9.1+, OpenSSH | `bash` or `zsh` |
| **Tunnel** | `socat` or `python3` | `socat` or `python3` |
| **Transfer** | `rsync` (faster) or `scp` | `rsync` or `scp` |
| **Fuzzy** | `fd` or `find` | N/A |

> **Note**: Your SSH server must allow Unix socket forwarding (default in OpenSSH). If you hit issues, ensure `AllowStreamLocalForwarding yes` is in the remote `/etc/ssh/sshd_config`.

## 📖 Deep Dive: Usage

### The `:Conduit` command

`:Conduit` is the general Vim command interface. It always takes an `op`, like
`:Conduit op`.

```vim
" Start an interactive SSH terminal and deploy lvim/vim aliases
:Conduit open user@example.com

" `:Conduit open` works with modifiers and bar!
:tab Conduit open user@example.com
:topleft Conduit open user@example.com
:bo vert Conduit open user@example.com
:tabnew | Conduit open +J user@example1.com user@example2.com

" Deploy the remote environment without opening a terminal
:Conduit deploy user@example.com

" Copy the source command for an existing connection to your system clipboard.
" If you use `:Conduit deploy user@example.com` then manually SSH, you can run
" this command on the remote shell to activate the lvim/vim aliases.
:Conduit source user@example.com

" Show notification history
:Conduit notifications history

" Dismiss active notification
:Conduit notifications dismiss

" Stop a transfer for a connection
:Conduit stop get user@example.com '*.log'
:Conduit stop put user@example.com '*.log'

" Clean up or force-close a connection
:Conduit exit user@example.com
:Conduit disconnect user@example.com
```

`open` and `deploy` accept short-form options with `+` and long-form options with `++`; the option itself determines whether it configures SSH or Vim's terminal. See [SSH Options](#ssh-options) below. Conduit reads your SSH config. You can replace each `user@example.com` above with an SSH alias defined in your SSH config, for example `:Conduit open ALIAS` or `:Conduit exit ALIAS`. `:help :Conduit` provides a more detailed explanation of `:Conduit` usage.


### The `lvim` command

The `lvim` function is injected into your remote shell automatically.

```bash
# Basic editing
$ lvim file.txt           # Opens in a horizontal split (default)
$ lvim vsplit file.txt    # Opens in a vertical split
$ lvim tabe file.txt      # Opens in a new tab

# Bulk operations
$ lvim *.py               # Opens all matching files locally
$ lvim mget '*.log'       # Download all matching remote files
$ lvim mput 'src/*.py'    # Upload matching local files to remote CWD

# File Transfers
$ lvim get log.txt        # "Fetch": Remote -> Local CWD
$ lvim put script.sh      # "Send":  Local -> Remote CWD
```

By default, Conduit aliases `vim` to `lvim` on the remote shell, so all the commands above work just as well by replacing `lvim` with `vim`. You can disable this by setting `g:conduit_overwrite_vim = 0`.

### SSH Options

`:Conduit open` and `:Conduit deploy` accept SSH flags before the destination
host using either a registered one-character short form (`+X`) or long form
(`++name`). Both forms are validated, and unregistered option names are
rejected. For example, these jump-host forms are equivalent:

```vim
:Conduit open +J user1@host1 user2@host2
:Conduit open ++proxyjump user1@host1 user2@host2
```

That maps to `ssh -J user1@host1 user2@host2`.

Conduit keys each connection by host, port, and the effective SSH options
used to open it. Repeating `:Conduit open` for the same host+port+options just
multiplexes through the existing SSH ControlMaster (no re-authentication, even
under MFA) and attaches another terminal to it. Only when the effective SSH
options actually differ — e.g. a different jump host — does Conduit track it
as a separate profile, keyed like `user@host:22-1a2b3c4d5e6f`. Use that key for
`:Conduit exit`, `:Conduit disconnect`, `:Conduit source`, and `:Conduit stop`.

#### Forwarding flags (`+L`/`+R`/`+D`/`+w`)

Most `+` SSH options (like `+J`, `+i`, `+p`) are threaded through every SSH
call Conduit makes for a connection — the shared ControlMaster, the reverse
tunnel, file transfers, cleanup, everything.

Forwarding flags are the exception: `+L`, `+R`, `+D`, and `+w` are only applied
to the *one new SSH session* your `:Conduit open`/`deploy` call creates (the
interactive terminal, or the deploy-only background tunnel) — not to the shared
ControlMaster's own setup, connectivity checks, or `scp`/`rsync` file
transfers. This is deliberate:

- The ControlMaster stays a plain, reusable connection, so opening a tunnel
  once doesn't leave it dangling on every future command for that connection.
  Forwarding options do not affect either a configured ControlPath or
  Conduit's fallback ControlPath; the fallback remains keyed by the
  non-forwarding SSH options so different forwards reuse the same authenticated
  master.
- Each `:Conduit open`/`deploy` call can carry its own distinct forward
  without conflicting with another session's, since ssh multiplexes them as
  independent sessions on top of the same authenticated master:
  ```vim
  :Conduit open +R=8080:localhost:80 host
  :Conduit open +R=9090:localhost:90 host   " a second, independent tunnel
  ```
- `scp` doesn't understand `-L`/`-R` the way `ssh` does (`-R` means something
  else entirely for `scp`), so file transfers never see these flags.

`+w` requests tunnel-device forwarding and receives the same session-only
scoping as the port-forwarding flags.

OpenSSH's `-W` stdio forwarding is not supported because it disables the remote
command and terminal that Conduit requires.

### Advanced Fuzzy Uploads (`put`)

If you run `lvim put my-local-file.txt` but that file isn't in your local directory, Conduit will:
1. Fuzzy search your local project (up to `g:conduit_put_max_depth`).
2. If one match is found, it uploads it immediately.
3. If multiple matches are found, it opens a menu in Vim for you to choose which one(s) to send.

`lvim put` uploads to the remote shell's current directory when you omit the
second argument.

`lvim mput` skips fuzzy matching and uploads every local file that matches the
glob you pass in. Quote the glob so the remote shell does not expand it first.
If you do not pass a second argument, Conduit uses the remote shell's current
directory.

## ⚙️ Advanced Configuration

### Customizing the Remote Shell
If you use a non-standard shell path on certain hosts:
```vim
g:conduit_host2shell = {
    \ 'production-server': '/usr/local/bin/zsh',
    \ 'legacy-box': '/bin/sh'
\ }
```

### Multiplexing Persistence
Control how long the SSH master socket stays open in the background:
```vim
let g:conduit_default_control_persist = '4h'
```

### Notifier Styling
```vim
let g:notifier_maxwidth = 60
let g:notifier_overflow = 'carousel' " Or: 'wrap', 'truncate'
let g:notifier_carousel_interval = 300 " Carousel animation frame speed in ms
let g:notifier_carousel_end_pause = 2 " Seconds
```

Notification prefixes use `NotifyPrefix` and `NotifySubPrefix` highlight groups
and stay fixed while carousel message text scrolls.

## 🔍 Troubleshooting

- **"Connection Refused" on `lvim`**: Usually means the SSH reverse tunnel failed to bind. Check if a stale socket exists in `/tmp/.vim-conduit-...` on the remote. Conduit tries to clean these up, but a hard crash might leave them behind. Try running `:Conduit exit HOST` to close the SSH ControlMaster.
- **No Progress Bars**: Ensure you have `rsync` installed locally. While `scp` works, it provides less granular progress information to Vim.
- **Netrw Errors**: Conduit uses Vim's built-in `netrw` for the actual editing. If you have `let g:loaded_netrwPlugin = 1` in your config, Conduit's edit functionality **will** break.

---
*See `:help conduit` for the full manual.*
