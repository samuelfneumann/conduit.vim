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

" Start an interactive SSH terminal in a hidden buffer, useful for `:Conduit run`
:Conduit open ++hidden user@example.com

" Reuse the RC file deployed by an earlier open in this Vim instance
:Conduit open ++nodeploy user@example.com

" `:Conduit open` works with modifiers and bar!
:tab Conduit open user@example.com
:topleft Conduit open user@example.com
:bo vert Conduit open user@example.com
:tabnew | Conduit open +J user@example1.com user@example2.com

" Deploy the remote environment without opening a terminal
:Conduit deploy user@example.com

" Run a command remotely and stream diagnostics into quickfix
:Conduit run ++cwd=/srv/app user@example.com make test

" Override 'errorformat' for this run only
:Conduit run ++errorformat=gcc user@example.com make test

" Run a configured alias (the connection may precede ++alias instead)
:Conduit run ++alias launch_job input.json ++ user@example.com

" Pipelines use Vim's escaped bar syntax
:Conduit run user@example.com pytest \| tee /tmp/test.log

" Rerun the last completed task for this connection
:Conduit! run user@example.com

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
:Conduit stop run user@example.com '*'

" Clean up or force-close a connection
:Conduit exit user@example.com
:Conduit disconnect user@example.com
```

`open` and `deploy` accept short-form options with `+` and long-form options with `++`; the option itself determines whether it configures SSH or Vim's terminal. See [SSH Options](#ssh-options) below. Conduit reads your SSH config. You can replace each `user@example.com` above with an SSH alias defined in your SSH config, for example `:Conduit open ALIAS` or `:Conduit exit ALIAS`. `:help :Conduit` provides a more detailed explanation of `:Conduit` usage.

`++nodeploy` skips uploading the generated RC file and uses the file left by an
earlier `:Conduit open` for the same connection profile. Use a normal open
first. The file is temporary and may be removed when the last Conduit terminal
for that profile closes, or when Vim exits.

### Remote tasks and quickfix

`:Conduit run [++cwd=DIR] [++errorformat=EFM] CONNECTION COMMAND` executes
`COMMAND` through the existing multiplexed SSH connection. Standard output and
standard error are merged in order and added live to a new quickfix list using
the local `'errorformat'` value captured when the task starts. Relative
diagnostic paths are resolved against the actual remote working directory, and
quickfix jumps open the file through the exact Conduit profile that ran the
task. Plain output lines that resolve to real remote files are also made
jumpable, which makes commands such as `ls`, `find`, and `git ls-files` useful

Run options may appear before or after `CONNECTION`; Conduit continues parsing
recognized options until ordinary command text begins. Use `++` or `--` to run
a remote command whose first token would otherwise be recognized as an option.
directly from quickfix. Other output remains visible as non-jumpable quickfix
text.

Run aliases are configured in `g:conduit_run_alias` and invoked with
`:Conduit run CONNECTION ++alias NAME ARGS...`. Because alias arguments are
variadic, putting the connection last requires an explicit option terminator:
`:Conduit run ++alias NAME ARGS... ++ CONNECTION` (or `-- CONNECTION`). Each
alias entry has an `alias` command string and a Vim-style `nargs` value (a
non-negative number, `+`, `*`, or `?`). It may also have either `errorformat` or
`compiler`, but not both. Positional `$0`, `$1`, ... substitutions follow shell
conventions, with `$0` naming the alias. Separate commands with `;`; `|` keeps
its normal remote-shell pipeline meaning.

As with other value-taking long options, the alias name may be attached with
`=`: `:Conduit run CONNECTION ++alias=NAME ARGS...`.

Alias arguments are variadic, but a recognized run option ends the argument
list. This makes `CONNECTION ++alias NAME ARGS... ++cwd=DIR` equivalent to
`++cwd=DIR CONNECTION ++alias NAME ARGS...`. Use `++` or `--` after the alias
arguments when the connection has not yet been supplied.

When `++cwd` is omitted, Conduit uses the directory of the current remote
buffer if it belongs to the selected connection. Otherwise, the task starts in
the remote login home. Options use Conduit's Vim-style `+` convention and must
come before the connection; everything after the connection is untouched
remote shell text. As elsewhere in Conduit, the `=` is optional — `++cwd DIR`
and `++errorformat EFM` work as well as the `=`-joined form.

`++errorformat=EFM` overrides `'errorformat'` for this run only. `EFM` is
resolved as, in order: a key in `g:conduit_errorformat` (a dictionary mapping
your own aliases to `'errorformat'` strings); a `:compiler` plugin named `EFM`,
whose `'errorformat'` Conduit borrows without disturbing the invoking window's
own compiler state; or, failing both, `EFM` itself taken as a literal
`'errorformat'` string.

Use `:Conduit! run CONNECTION` to rerun that connection's last completed task.
The bang belongs to `:Conduit`, as required by Ex command syntax;
`:Conduit run!` is not supported. Active runs can be cancelled with
`:Conduit stop run CONNECTION PATTERN`; `*` matches every run on the
connection.


### The `lvim` command

The `lvim` function is injected into your remote shell automatically.

```bash
# Basic editing
$ lvim file.txt           # Opens in a horizontal split (default)
$ lvim vsplit file.txt    # Opens in a vertical split
$ lvim tabe file.txt      # Opens in a new tab
$ lvim open report.pdf    # Opens in the local system default application

# Bulk operations
$ lvim *.py               # Opens all matching files locally
$ lvim mget '*.log'       # Download all matching remote files
$ lvim mput 'src/*.py'    # Upload matching local files to remote CWD

# File Transfers
$ lvim get log.txt        # "Fetch": Remote -> Local CWD
$ lvim put script.sh      # "Send":  Local -> Remote CWD
```

By default, Conduit aliases `vim` to `lvim` on the remote shell, so all the commands above work just as well by replacing `lvim` with `vim`. You can disable this by setting `g:conduit_overwrite_vim = 0`.

`lvim open` downloads one remote file to a temporary local file before opening
it. Conduit removes that temporary file when Vim exits.

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
`:Conduit exit`, `:Conduit disconnect`, `:Conduit source`, `:Conduit stop`,
etc.

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

### Remote task quickfix

By default Conduit runs `:cwindow` when a remote task completes. Disable this
to leave focus unchanged and receive a notification pointing to the populated
quickfix list:

```vim
let g:conduit_run_auto_open_quickfix = false
```

Give short aliases to `'errorformat'` strings for use with `++errorformat=`:

```vim
let g:conduit_errorformat = {
    \ 'django': '%A  File "%f", line %l, in %.%#',
\ }
```

### Notifier Styling
```vim
let g:notifier_maxwidth = 60
let g:notifier_overflow = 'carousel' " Or: 'wrap', 'truncate'
let g:notifier_carousel_interval = 300 " Carousel animation frame speed in ms
let g:notifier_carousel_end_pause = 2 " Seconds
```

## Testing

Run the headless Vim integration suite with:

```bash
test/run.sh
```

Notification prefixes use `NotifyPrefix` and `NotifySubPrefix` highlight groups
and stay fixed while carousel message text scrolls.

## 🔍 Troubleshooting

- **"Connection Refused" on `lvim`**: Usually means the SSH reverse tunnel failed to bind. Check if a stale socket exists in `/tmp/.vim-conduit-...` on the remote. Conduit tries to clean these up, but a hard crash might leave them behind. Try running `:Conduit exit HOST` to close the SSH ControlMaster.
- **No Progress Bars**: Ensure you have `rsync` installed locally. While `scp` works, it provides less granular progress information to Vim.
- **Netrw Errors**: Conduit uses Vim's built-in `netrw` for the actual editing. If you have `let g:loaded_netrwPlugin = 1` in your config, Conduit's edit functionality **will** break.

---
*See `:help conduit` for the full manual.*
