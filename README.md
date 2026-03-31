# conduit.vim

**Conduit** is a Vim 9 plugin that creates a high-speed "conduit" between your local Vim instance and remote SSH sessions. It allows you to treat a remote terminal as an extension of your local editor, enabling seamless file opening, background transfers, and shared state without leaving your terminal.

## Key Features

- **`lvim` Remote Command**: Open remote files in your local Vim instance with a single command from the SSH shell.
- **Background Transfers**: `get` and `put` files between local and remote environments with real-time progress bars in Vim popup windows.
- **SSH Multiplexing**: Automatically manages SSH ControlMaster sockets for lightning-fast subsequent connections.
- **Fuzzy Uploads**: If you try to `put` a file that doesn't exist locally, Conduit will fuzzy search your local project and offer matches.
- **Vim 9 Native**: Written entirely in Vim9script for performance and modern integration.

## Installation

Using Vim 9's built-in package manager:

```bash
mkdir -p ~/.vim/pack/plugins/start
cd ~/.vim/pack/plugins/start
git clone https://github.com/youruser/conduit.vim.git
```

Then, in Vim:
```vim
:helptags ~/.vim/pack/plugins/start/conduit.vim/doc
```

## Dependencies & Requirements

### Local Requirements (Your Machine)
- **Vim 9.1+** compiled with `+job`, `+channel`, `+popupwin`, and `+reltime`.
- **SSH Client**: Standard OpenSSH client.
- **Listener**: Either `socat` (recommended) or `python3`.
- **Transfers**: `rsync` (recommended for progress/speed) or `scp`.
- **Fuzzy Search**: `fd` (or `fdfind`) is recommended for fast local file lookups, otherwise `find` is used.

### Remote Requirements (The Server)
- **Shell**: `bash` or `zsh`.
- **Communication**: Either `socat` or `python3` (used by `lvim` to talk back to Vim).
- **Transfers**: `rsync` or `scp`.
- **SSH Configuration**: The server's `sshd_config` must allow Unix domain socket forwarding (this is usually the default, but requires `AllowStreamLocalForwarding yes` if it was disabled).

## Quick Start

1. **Connect**: Run `:ConduitOpen user@remote-host` in Vim.
2. **Edit**: In the resulting terminal, type `lvim path/to/file.txt`. The file opens in your local Vim.
3. **Fetch (Remote -> Local)**: Type `lvim get remote_file.txt` to copy a file from the server to your local machine.
4. **Send (Local -> Remote)**: Type `lvim put local_file.txt` to copy a file from your local machine to the server.

### Example Usage

```bash
# Run ":ConduitOpen HOST" in vim

# Open a file in a vertical split
$ lvim vsplit config.yaml

# Send a script from your local machine to the server and run it
$ lvim put ~/scripts/deploy.sh
$ ./deploy.sh

# Fetch a log file from the server to your local machine for analysis
$ lvim get /var/log/nginx/error.log
```

## Vim Aliasing

By default (`g:conduit_overwrite_vim = 1`), Conduit transparently aliases the `vim` command on the remote host to `lvim`. 

When you run `:ConduitOpen HOST`, Conduit generates a temporary shell script on the remote server. This script:
1. Defines the `lvim` function.
2. Sets up the environment for the reverse tunnel.
3. Adds `alias vim=lvim` to your current shell session.
4. Adds `alias _vim="/usr/bin/env vim"` so you can still access the "real" Vim on the server if needed.

This alias only exists within the shell session opened by Conduit and does not modify your remote `.bashrc` or `.zshrc`. 

## Configuration

```vim
" Set the default split mode (split, vsplit, tabe)
let g:conduit_default_split = 'vsplit'

" Use popup menus for fuzzy file selection
let g:conduit_use_popup = 1

" Disable aliasing 'vim' to 'lvim' on the remote
let g:conduit_overwrite_vim = 0
```

See `:help conduit` for full documentation.
