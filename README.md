# conduit.vim

**Conduit** is a Vim 9 plugin that creates a high-speed, multiplexed SSH "conduit" between your local Vim instance and remote SSH sessions. It transforms your remote SSH connection in the Vim terminal into a first-class extension of your local Vim instance. Run `vim FILE` on the remote SSH server and watch the file magically open in your local Vim instance.

**Quick Start**:
* Open Vim on your local machine.
* Run `:ConduitOpen HOST`. A Vim terminal opens up with an SSH connection to `HOST`.
* Run `vim file` in the spawned Vim terminal and watch as the file on the remote SSH server magically open in your local vim instance.
* Save the file with `:w` and watch as your local changes magically transfer to the SSH server.

Unlike other methods like mounting via SSHFS or using netrw directly, Conduit focuses on a **push-pull, shell-driven workflow**, while keeping all file operations and progress tracking integrated into your Vim UI.

## 🚀 Why Conduit?

- **Zero-Latency Navigation**: You browse files in the remote shell (where it's fastest) and "teleport" them to your local Vim only when you need to edit.
- **Background Operations**: Large file transfers happen in the background via `rsync` or `scp`. You can keep working while a progress bar in a Vim popup window shows the status.
- **Multiplexed Speed**: It automatically manages SSH `ControlMaster` sockets. Your first connection might take a second; every subsequent file open or transfer is near-instant.
- **No Configuration Overhead**: It deploys its own environment to the remote server on-the-fly. No need to install plugins or edit `.bashrc` on every server you touch.

## 🛠 How it Works (The "Conduit")

1. **The Tunnel**: When you run `:ConduitOpen`, Vim starts a local listener (using `socat` or `python`) and establishes an SSH reverse tunnel that maps a remote Unix socket to your local listener.
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

## 📋 Requirements

| Feature | Local (Your Machine) | Remote (The Server) |
| :--- | :--- | :--- |
| **Core** | Vim 9.1+, OpenSSH | `bash` or `zsh` |
| **Tunnel** | `socat` or `python3` | `socat` or `python3` |
| **Transfer** | `rsync` (faster) or `scp` | `rsync` or `scp` |
| **Fuzzy** | `fd` or `find` | N/A |

> **Note**: Your SSH server must allow Unix socket forwarding (default in OpenSSH). If you hit issues, ensure `AllowStreamLocalForwarding yes` is in the remote `/etc/ssh/sshd_config`.

## 📖 Deep Dive: Usage

### The `lvim` command

The `lvim` function is injected into your remote shell automatically.

```bash
# Basic editing
$ lvim file.txt           # Opens in a horizontal split (default)
$ lvim vsplit file.txt    # Opens in a vertical split
$ lvim tabe file.txt      # Opens in a new tab

# Bulk operations
$ lvim *.py               # Opens all matching files locally

# File Transfers
$ lvim get log.txt        # "Fetch": Remote -> Local CWD
$ lvim put script.sh      # "Send":  Local -> Remote CWD
```

### SSH Options on `ConduitOpen`

`ConduitOpen` accepts SSH flags before the destination host using a `++`
prefix. The most useful case is jump hosts:

```vim
:ConduitOpen ++J user1@host1 user2@host2
```

That maps to `ssh -J user1@host1 user2@host2` and is threaded through the
control master, reverse tunnel, file transfer, and cleanup commands.

When you open more than one profile for the same host, Conduit tracks each one
with a profile key like `user@host:22-1a2b3c4d5e6f`. Use that key for
`:Conduit exit`, `:Conduit disconnect`, `:Conduit source`, and `:Conduit stop`.

### Advanced Fuzzy Uploads (`put`)

If you run `lvim put my-local-file.txt` but that file isn't in your local directory, Conduit will:
1. Fuzzy search your local project (up to `g:conduit_put_max_depth`).
2. If one match is found, it uploads it immediately.
3. If multiple matches are found, it opens a menu in Vim for you to choose which one(s) to send.

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
let g:notifier_wrap = 0 " Truncate long messages with ... or … if has('multi_byte')
```

## 🔍 Troubleshooting

- **"Connection Refused" on `lvim`**: Usually means the SSH reverse tunnel failed to bind. Check if a stale socket exists in `/tmp/.vim-conduit-...` on the remote. Conduit tries to clean these up, but a hard crash might leave them behind. Try running `ConduitExit HOST` to close the SSH ControlMaster.
- **No Progress Bars**: Ensure you have `rsync` installed locally. While `scp` works, it provides less granular progress information to Vim.
- **Netrw Errors**: Conduit uses Vim's built-in `netrw` for the actual editing. If you have `let g:loaded_netrwPlugin = 1` in your config, Conduit's edit functionality **will** break.

---
*See `:help conduit` for the full manual.*
