vim9script

import autoload 'notifier.vim'

# ── Classes & Core Types ─────────────────────────────────────────────────────
export class Connection
	static var host2shell: dict<string> = g:conduit_host2shell
	static var fallback_shell: string = g:conduit_fallback_shell
	static var null_connection: Connection

	var host: string
	var port: number
	var profile_key: string
	var ssh_options: list<string>
	var listener_job: job
	var sock_ready: bool
	var term_bufnr: dict<number> # Set of connected terms

	def new(host: string, port: number, listener_job: job, sock_ready: bool, ssh_options: list<string> = [])
		this.host = host
		this.port = port
		this.ssh_options = copy(ssh_options)
		this.profile_key = GetConnectionsDictKeyFrom(host, port, this.ssh_options)
		this.listener_job = listener_job 
		this.sock_ready = sock_ready
		this.term_bufnr = {}
	enddef

	def ConnectedTerms(): number
		return len(this.term_bufnr)
	enddef

	def ConduitShell(): string
		return get(Connection.host2shell, this.host, Connection.fallback_shell)
	enddef

	def GetSshOptions(): list<string>
		return copy(this.ssh_options)
	enddef

	def GetProfileKey(): string
		return this.profile_key
	enddef

	def ConduitOpen(): bool
		system(GetSshCommandString(this, ['-O', 'check', '-S', this.GetConduitControlPath()]))
		return v:shell_error == 0
	enddef

	def ConduitClosed(): bool
		return !this.ConduitOpen()
	enddef

	def IsManuallyControlledMultiplexing(): bool
		for line in systemlist(GetSshCommandString(this, ['-G']))
			if line =~ '^controlpath ' | return false | endif
		endfor

		return true
	enddef

	def GetConduitControlPersist(): string
		const default = g:conduit_default_control_persist

		if !this.IsManuallyControlledMultiplexing()
			# If there is an ssh config file to use, check if there is a
			# control persist setting specified there
			for line in systemlist(GetSshCommandString(this, ['-G']))
				if line =~ '^controlpersist '
					return line[len('controlpersist ') : ] 
				endif
			endfor

			# No control persist specified in ssh config, use default
			return default
		endif
		return default
	enddef

	def GetConduitControlPath(): string
		if this.port > 0
			return $'/tmp/.vim-conduit-connection-{this.host}-{this.port}{GetProfileSuffix(this.ssh_options)}.sock'
		endif
		return $'/tmp/.vim-conduit-connection-{this.host}{GetProfileSuffix(this.ssh_options)}.sock'
	enddef

	def Disconnect()
		for job in this.GetTermJobs()
			job_stop(job)
		endfor
		MaybeCleanup(this)
	enddef

	def GetTermJobs(): list<job>
		var term_jobs: list<job> = []
		for bufnr in keys(this.term_bufnr)
			term_jobs->add(term_getjob(this.term_bufnr[bufnr]))
		endfor
		return term_jobs
	enddef

	def RemoveTermByBufNr(bufnr: number)
		if this.term_bufnr->has_key(bufnr)
			this.term_bufnr->remove(bufnr)
			MaybeCleanup(this)
		endif
	enddef

	def AddTermByBufNr(bufnr: number)
		if this.term_bufnr->has_key(bufnr) | return | endif

		this.term_bufnr[bufnr] = bufnr

		# Watch the terminal's job so we can cleanup when it exits
		var term_job = term_getjob(bufnr)
		if job_status(term_job) == 'run'
			job_setoptions(term_job, {exit_cb: (_, _code) => {

				# Print a nice little ConduitOpen job finishing messsage
				timer_start(
					10, (_) => {
						# Force vim to finish processing the terminal state
						term_wait(bufnr)

						# Switch to normal mode
						setbufvar(bufnr, '&buftype', '')

						# Set finish text
						setbufvar(bufnr, "&modifiable", true)
						appendbufline(bufnr, "$", "===============")

						var line = this.host
						if this.port > 0
							line ..= $":{this.port}"
						endif
						appendbufline(bufnr, "$", "✓ Thanks for using conduit.vim!")
						setbufvar(bufnr, "&modifiable", false)
						setbufvar(bufnr, "&modified", false)
					}
				)

				this.RemoveTermByBufNr(bufnr)
			}})
		endif

	enddef

	def SetListenerJob(job: job)
		this.listener_job = job
	enddef

	def SetSockReady()
		this.sock_ready = true
	enddef

	def SetSockNotReady()
		this.sock_ready = false
	enddef

	def GetLocalReverseTunnelSocketPath(): string
		if this.port > 0
			return $'/tmp/.vim-conduit-{getpid()}-{this.host}p{this.port}{GetProfileSuffix(this.ssh_options)}.sock'
		endif
		return $'/tmp/.vim-conduit-{getpid()}-{this.host}{GetProfileSuffix(this.ssh_options)}.sock'
	enddef

	def GetRemoteReverseTunnelSocketPath(): string
		if this.port > 0
			return $'/tmp/.vim-conduit-{getpid()}-{this.host}p{this.port}{GetProfileSuffix(this.ssh_options)}.sock'
		endif
		return $'/tmp/.vim-conduit-{getpid()}-{this.host}{GetProfileSuffix(this.ssh_options)}.sock'
	enddef

	def GetRemoteRCPath(): string
		if this.port > 0
			return $'/tmp/.vim-conduit-rc-{getpid()}-{this.host}p{this.port}{GetProfileSuffix(this.ssh_options)}.sh'
		endif
		return $'/tmp/.vim-conduit-rc-{getpid()}-{this.host}{GetProfileSuffix(this.ssh_options)}.sh'
	enddef
endclass

export enum OpType
	Get,
	Put
endenum

export class Op
	var type: OpType
	var conn_key: string
	var port: number
	var job: job
	var local_file: string
	var remote_file: string

	static def From(type: OpType, conn: Connection, j: job, local_file: string, remote_file: string): Op
		return Op.new(type, conn.GetProfileKey(), conn.port, j, local_file, remote_file)
	enddef

	def new(type: OpType, conn_key: string, port: number, j: job, local_file: string, remote_file: string)
		this.type = type
		this.conn_key = conn_key
		this.port = port
		this.job = j
		this.local_file = local_file
		this.remote_file = remote_file
	enddef

	def SetJob(job: job)
		this.job = job
	enddef
endclass

# ── Connection & State Management ────────────────────────────────────────────

# Stores profile key -> Connections
var connections: dict<Connection> = {}

def GetConnectionsDictKey(conn: Connection): string
	return conn.GetProfileKey()
enddef

def GetEffectiveSshOptions(host: string, ssh_options: list<string>): list<string>
	var options = copy(get(g:conduit_host2sshoptions, host, []))
	if !empty(ssh_options)
		options->extend(ssh_options)
	endif
	return options
enddef

def GetProfileSuffix(ssh_options: list<string>): string
	if empty(ssh_options)
		return ''
	endif

	const digest = sha256(join(ssh_options, "\x1f"))
	return $'-{digest[: 11]}'
enddef

def GetConnectionsDictKeyFrom(host: string, port: number, ssh_options: list<string> = []): string
	const suffix = GetProfileSuffix(ssh_options)
	if port > 0
		return $'{host}:{port}{suffix}'
	endif
	return $'{host}{suffix}'
enddef

def MaybeAddEmptyConnection(host: string, port: number, ssh_options: list<string> = []): Connection
	const effective_ssh_options = GetEffectiveSshOptions(host, ssh_options)
	const key = GetConnectionsDictKeyFrom(host, port, effective_ssh_options)

	if has_key(connections, key)
		const conn = connections[key]
		return connections[key]
	endif

	const conn = Connection.new(host, port, null_job, false, effective_ssh_options)
	connections[key] = conn
	return conn
enddef

def ShellJoin(args: list<string>): string
	var quoted: list<string> = []
	for arg in args
		quoted->add(shellescape(arg))
	endfor
	return quoted->join(' ')
enddef

def GetPortArgs(conn: Connection, scp: bool = false): list<string>
	if conn.port > 0
		return [scp ? '-P' : '-p', string(conn.port)]
	endif
	return []
enddef

def GetSshArgs(conn: Connection): list<string>
	var args = ['ssh']
	args->extend(conn.GetSshOptions())
	args->extend(GetPortArgs(conn))
	return args
enddef

def GetScpArgs(conn: Connection): list<string>
	var args: list<string> = []
	args->extend(conn.GetSshOptions())
	args->extend(GetPortArgs(conn, true))
	return args
enddef

def GetSshCommandArgs(conn: Connection, head_args: list<string>, tail_args: list<string> = []): list<string>
	var args = GetSshArgs(conn)
	args->extend(head_args)
	args->add(conn.host)
	args->extend(tail_args)
	return args
enddef

def GetSshCommandString(conn: Connection, head_args: list<string>, tail_args: list<string> = []): string
	return ShellJoin(GetSshCommandArgs(conn, head_args, tail_args))
enddef

const ssh_opts_with_value = [
	'B', 'b', 'c', 'D', 'E', 'F', 'I', 'i', 'J', 'l', 'L', 'm', 'O', 'o',
	'p', 'Q', 'R', 'S', 'W', 'w',
]

def ParseConduitOpenArgs(args: string): dict<any>
	var tokens = split(args)
	if empty(tokens)
		throw 'missing host'
	endif

	var ssh_options: list<string> = []
	var idx = 0
	while idx < len(tokens) && tokens[idx] =~# '^++'
		var token = tokens[idx][2 : ]
		if empty(token)
			throw 'invalid ssh option'
		endif

		if token =~# '^--'
			idx += 1
			break
		endif

		const eq_idx = stridx(token, '=')
		if eq_idx >= 0
			const flag = token[: eq_idx - 1]
			const val = token[eq_idx + 1 : ]
			if empty(flag) || empty(val)
				throw 'invalid ssh option'
			endif
			ssh_options->extend([$'-{flag}', val])
			idx += 1
			continue
		endif

		if index(ssh_opts_with_value, token) >= 0
			if idx + 1 >= len(tokens)
				throw $'ssh option ++{token} requires a value'
			endif
			ssh_options->extend([$'-{token}', tokens[idx + 1]])
			idx += 2
			continue
		endif

		ssh_options->add($'-{token}')
		idx += 1
	endwhile

	if idx >= len(tokens)
		throw 'missing host'
	endif

	var host = tokens[idx]
	var port = -1
	if host =~ ':'
		const host_parts = host->split(':')
		port = str2nr(host_parts[1])
		host = host_parts[0]
	endif

	if port == 0
		throw 'invalid port'
	endif

	return {
		host: host,
		port: port,
		ssh_options: ssh_options,
	}
enddef

def ResolveConnectionKey(name: string): string
	if has_key(connections, name)
		return name
	endif

	var matches: list<string> = []
	for [key, conn] in items(connections)
		if conn.host ==# name || stridx(key, name) == 0
			matches->add(key)
		endif
	endfor

	if len(matches) == 1
		return matches[0]
	endif

	if len(matches) > 1
		Warn($'Ambiguous connection "{name}"; use the completed profile key instead')
	endif

	return ''
enddef

def GetPortStringOption(conn: Connection, scp: bool=false): string
	if conn.port > 0
		return $'{scp ? '-P' : '-p'} {conn.port}'
	endif
	return ''
enddef

# ── Local Listener & Dispatcher ──────────────────────────────────────────────

# socat binds a Unix socket and prints each received message to stdout.
# `fork` lets it handle multiple sequential connections (one per lvim call).
def EnsureListener(conn: Connection): bool
	if job_status(conn.listener_job) == 'run'
		return true
	endif

	const sock_path = conn.GetLocalReverseTunnelSocketPath()

	# Clean up any stale socket from a previous crashed session
	if getftype(sock_path) == 'socket'
		delete(sock_path)
	endif

	var cmd: list<string>
	if executable('socat')
		cmd = ['socat', 'UNIX-LISTEN:' .. sock_path .. ',fork,reuseaddr', '-']
	elseif executable('python3') || executable('python')
		var py = executable('python3') ? 'python3' : 'python'
		# Bind a Unix socket, accept connections in a loop, print each
		# received message to stdout for the vim job to read.
		var script = 
			'import socket, sys; ' ..
			's = socket.socket(socket.AF_UNIX); ' ..
			's.bind("' .. sock_path .. '"); ' ..
			's.listen(); ' ..
			"\n" ..
			'while True:\n' ..
			'    c, _ = s.accept()\n' ..
			'    sys.stdout.write(c.makefile().read())\n' ..
			'    sys.stdout.flush()\n' ..
			'    c.close()\n'
		cmd = [py, '-c', script]
	else
		Warn('Neither socat nor python found - please install one to use conduit.vim')
		return false
	endif

	conn.SetListenerJob(job_start(cmd, {
		out_cb:   (_, line) => OnLine(conn, line),
		err_cb:   (_, _line) => null,
		exit_cb:  (_, _code) => null,
		out_mode: 'nl',
	}))

	if job_status(conn.listener_job) != 'run'
		Warn('Failed to start listener')
		return false
	endif

	conn.SetSockReady()
	return true
enddef

const open_file_ops = [
	"split", "sp",
	"vsplit", "vsp", "vert split", "vertical split",
	"tabe", "tabedit", "tabnew", "tab split", "tab sp", "tab vsplit", "tab vert split", "tab vertical split", "tab vsp",
]

def OnLine(conn: Connection, line: string)
	var op_path = trim(line)->split(g:conduit_sep)

	var op: string
	var paths: list<string>
	if len(op_path) == 1
		throw $"error: expected 'op:path' format, got {line}"
	endif

	op = op_path[0]
	paths = op_path[1 : ]

	if empty(paths) | return | endif

	if index(open_file_ops, op) > -1
		var i = 0
		for path in paths
			# timer_start(0, (_) => OpenFile(conn, op, path))
			OpenFile(conn, op, path)
		endfor
	elseif op == "get"
		if len(paths) == 1 || empty(paths[1])
			RsyncFile(conn, true, paths[0], getcwd())
		elseif len(paths) == 2
			RsyncFile(conn, true, paths[0], paths[1])
		else
			throw $"error: get expects 1 or 2 arguments, got {len(paths)}"
		endif
	elseif op == "put"
		var local_file = expand(paths[0])

		const PutWarn = () => Warn($"Could not find file {local_file}")

		if !filereadable(local_file) && !isdirectory(local_file) # Cannot find path, try fuzzy finding it
			# Create fuzzy search string
			var fuzzy_pattern = MakeAnchoredFuzzy(local_file)

			var find_cmd: string
			if executable('fd') || executable('fdfind')
				const exec = executable('fd') ? 'fd' : 'fdfind'
				find_cmd = $'{exec} --max-depth {g:conduit_put_max_depth} --full-path --ignore-case --path-separator / "{fuzzy_pattern}" .'
			elseif executable('find')
				# For standard find, we use -ipath with wildcards
				var find_pattern = $'*{local_file.split("")->join("*")}*'
				find_cmd = $'find . -maxdepth {g:conduit_put_max_depth} -ipath "{fuzzy_pattern}"'
			endif

			if empty(find_cmd) | PutWarn() | return | endif

			var matches: list<string> = systemlist(find_cmd)
			if v:shell_error != 0 | PutWarn() | return | endif

			if len(matches) == 1
				local_file = matches[0]
			elseif len(matches) == 0
				PutWarn()
				return
			else # Multiple matches
				# Present the user with a list to choose
				var remote_file = len(paths) < 1 ? "" : paths[1]

				if g:conduit_use_popup
					FilteredMenu(
						matches,
						(selected) => {
							RsyncFile(conn, false, remote_file, selected)
						},
						"Select Files to Upload"
					)
				else
					MultiChoicePrompt(
						matches,
						(selected) => {
							RsyncFile(conn, false, remote_file, selected)
						},
						"Select Files to Upload"
					)
				endif

				return
			endif
		endif

		if len(paths) == 1 || empty(paths[1])
			RsyncFile(conn, false, "", local_file)
		elseif len(paths) == 2
			RsyncFile(conn, false, paths[1], local_file)
		else
			throw $"error: put expects 1 or 2 arguments, got {len(paths)}"
		endif
	else
		throw $"error: invalid operation {op}"
	endif
enddef

# ── Remote File Operations ───────────────────────────────────────────────────

def OpenFile(conn: Connection, op: string, remote_path: string)
	var host = conn.host

    var target: string

    if !empty(host)
        # scp:// requires double-slash before an absolute path
        var abs = remote_path =~# '^/' ? remote_path : ('/' .. remote_path)
        target = 'scp://' .. host .. '/' .. abs # // separates host from path
    else
        target = remote_path
    endif

	if g:conduit_verbose | echom $"Conduit(vim/{op}):" op target | endif

	try
		# Conduit owns the control socket path for each connection profile, so
		# netrw must always be pointed at the profile-specific socket.
		var scp_cmd_parts = [
			'scp',
			'-q',
			'-o', $'ControlPath={conn.GetConduitControlPath()}',
		]
		scp_cmd_parts->extend(GetScpArgs(conn))
		const scp_cmd = ShellJoin(scp_cmd_parts)
		
		const reset_netrw_scp_cmd = exists("g:netrw_scp_cmd")
		var netrw_scp_cmd_before = 'scp -q'
		if reset_netrw_scp_cmd
			# Store the old netrw scp command
			netrw_scp_cmd_before = g:netrw_scp_cmd
		endif

		g:netrw_scp_cmd = scp_cmd
		execute op .. ' ' .. fnameescape(target)

		if reset_netrw_scp_cmd
			# Reset netrw scp command if needed
			g:netrw_scp_cmd = netrw_scp_cmd_before

			const bufnr = bufnr(fnameescape(target))
			setbufvar(bufnr, "scp_cmd", scp_cmd)
			setbufvar(bufnr, "netrw_scp_cmd_before", netrw_scp_cmd_before)

			augroup ConduitUpdateNetrwControlPath
				autocmd BufWritePre <buffer> g:netrw_scp_cmd = b:scp_cmd
				autocmd BufWritePost <buffer> g:netrw_scp_cmd = b:netrw_scp_cmd_before
			augroup END
		endif
    catch
        Warn('Failed to open ' .. target .. ' (error: ' .. v:exception .. ')')
    endtry

enddef

def RsyncFile(conn: Connection, get: bool, remote_path: string, local_path: string)
	const host = conn.host
	const op = get ? 'get' : 'put'

	var scp_cmd: list<string>
	var notif_prefix: string
	var notif_suffix: string
	if get
		notif_prefix = "get"
		notif_suffix = $"{host}:{remote_path} → {local_path}"

		if executable('rsync')
			var rsh_args = GetSshArgs(conn)
			rsh_args->extend(['-S', conn.GetConduitControlPath()])
			var rsh_cmd = ShellJoin(rsh_args)

			scp_cmd = [
				"rsync",
				"-az",
				"--info=progress2",
				"--rsh",
				rsh_cmd,
				$"{host}:{remote_path}",
				local_path,
			]
		elseif executable('scp')
			scp_cmd = [
				'scp', 
				'-q',
				$'-o ControlPath={conn.GetConduitControlPath()}',
				'-r',
			]
			scp_cmd->extend(GetScpArgs(conn))
			scp_cmd->extend([$'{host}:{remote_path}', local_path])
		else
			throw "error rsync or scp not available"
		endif

	else # put
		notif_prefix = "put"
		notif_suffix = $"{local_path} → {host}:{remote_path}"

		if executable('rsync')
			var rsh_args = GetSshArgs(conn)
			rsh_args->extend(['-S', conn.GetConduitControlPath()])
			var rsh_cmd = ShellJoin(rsh_args)

			scp_cmd = [
				"rsync",
				"-az",
				"--info=progress2",
				"--inplace",
				"--rsh",
				rsh_cmd,
				local_path,
				$"{host}:{remote_path}",
			]
		elseif executable('scp')
			scp_cmd = [
				'scp', 
				'-q',
				$'-o ControlPath={conn.GetConduitControlPath()}',
				'-r',
			]
			scp_cmd->extend(GetScpArgs(conn))
			scp_cmd->extend([local_path, $'{host}:{remote_path}'])
		else
			throw "error rsync or scp not available"
		endif
	endif

	if g:conduit_verbose && !empty(scp_cmd) | echom $"Conduit(sh/{op}):" scp_cmd->join(' ') | endif

	const notif = notifier.StartProgress($'{notif_prefix} [0.00 KB/s] {notif_suffix}')

	# Debounce time for updating progress bar
	const debounce = 0.750 # seconds
	var last_run = reltime()

	var scp_op: Op
	var scp_ops = get ? g:conduit_get_ops : g:conduit_put_ops

	var current = 0
	var pbar_msg: string
	const j = job_start(
		scp_cmd, {
		out_io: "pipe",
		out_mode: "raw",
		out_cb: (_, msg) => {
			# Debounce
			const seconds_since_last_run = reltime(last_run)->reltimefloat()
			if seconds_since_last_run < debounce | return | endif
			last_run = reltime()

			var latest: string
			var percent: number
			var speed: string
			if executable('rsync') 
				[latest, percent, speed] = ParseRsync(msg)
			else
				[latest, percent, speed] = ParseScp(msg)
			endif

			if g:conduit_verbose && !empty(latest) | echom $'Conduit({op}):' latest | endif

			# Update progress bar
			if percent > 0 && !empty(speed)
				pbar_msg = $'{notif_prefix} [{speed}] {notif_suffix}'
				notifier.UpdateProgress(
					notif,
					percent,
					100, 
					pbar_msg,
				)
			endif
		},
		exit_cb: (_, code) => {
			if code == 0
				# Briefly show the full, final progress bar and success
				# message, then dismiss
				notifier.UpdateProgress(notif, 100, 100, $"✓ {notif_prefix} [success] {notif_suffix}")
				timer_start(3000, (_) => notifier.Dismiss(notif))
			else
				notifier.Modify(notif, $"× {notif_prefix} [failed (error: {code})] {notif_suffix}")
				timer_start(5000, (_) => notifier.Dismiss(notif))
			endif

			# Remove the completed op from the list of stored operations
			const idx = scp_ops->index(scp_op)
			if idx != -1 | scp_ops->remove(idx) | endif
		}}
	)

	scp_op = Op.From(get ? OpType.Get : OpType.Put, conn, j, local_path, remote_path)
	if job_status(j) ==# 'run' | scp_ops->add(scp_op) | endif
enddef

const all_ops = [
	"put", "get", "split", "sp",
	"vsplit", "vsp", "vert split", "vertical split",
	"tabe", "tabedit", "tabnew", "tab split", "tab sp", "tab vsplit", "tab vert split", "tab vertical split", "tab vsp",
]

def DeployRcfile(conn: Connection, OnSuccess: func(): void, OnErr: func(): void): job
	const quoted_joined_file_ops = mapnew(all_ops, (_, v) => $'"{v}"')->join('|')

    var rc_lines = [
        '# injected by conduit.vim, safe to delete',
        'declare -A rcfiles',
        'rcfiles["bash"]="$HOME/.bashrc"',
        'rcfiles["zsh"]="$HOME/.zshrc"',
        'export VIMSOCK=' .. conn.GetRemoteReverseTunnelSocketPath(),
        '_lvim_send() {',
        '  if command -v socat > /dev/null 2>&1; then',
        '    printf "%s\n" "$1" | socat - UNIX-CONNECT:"$VIMSOCK"',
        '  elif command -v python3 > /dev/null 2>&1; then',
        '    python3 -c "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall((sys.argv[2]+chr(10)).encode());s.close()" "$VIMSOCK" "$1"',
        '  elif command -v python > /dev/null 2>&1; then',
        '    python -c "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall((sys.argv[2]+chr(10)).encode());s.close()" "$VIMSOCK" "$1"',
        '  else',
        "    echo 'lvim: needs socat or python on the remote server' >&2",
        '    return 1',
        '  fi',
        '}',
        'lvim() {',
        $'  local op="{g:conduit_default_split}"',
        '  case "$1" in',
		$'    {quoted_joined_file_ops}) op="$1"; shift ;;',
        '  esac',
        '  if [ "$#" -eq 0 ]; then',
        $"    echo 'Usage: lvim [{quoted_joined_file_ops}] <file> [files...]' >&2",
        '    return 1',
        '  fi',
        '  local msg="$op"',
		'  if [ "$op" == "put" ]; then',
		'    if (( $# >= 2 )); then',
		$'      msg="$msg{g:conduit_sep}$1{g:conduit_sep}$(realpath "$2")"',
		'    else',
        $'      msg="$msg{g:conduit_sep}$1{g:conduit_sep}$(pwd)"',
		'    fi',
		'  else',
        '    for f in "$@"; do',
        $'      msg="$msg{g:conduit_sep}$(realpath "$f")"',
        '    done',
		'  fi',
        # '  echo "lvim $msg"', # For testing
        '  _lvim_send "$msg"',
        '}',
        "source ${rcfiles[$(basename $SHELL)]}",
        g:conduit_overwrite_vim ? 'alias vim=lvim; alias _vim="/usr/bin/env vim"' : '',
        "echo '[conduit] lvim() ready - usage: lvim [op] file1 [file2...]'",
        g:conduit_overwrite_vim ? "echo '[conduit] vim aliased to lvim', access vim with '_vim'" : '',
    ]
    var local_rc = tempname()
    writefile(rc_lines, local_rc)

    const remote_rc = conn.GetRemoteRCPath()

    var job_out: job
    if executable('rsync')
		var rsh_args = GetSshArgs(conn)
		rsh_args->extend(['-S', conn.GetConduitControlPath()])
        job_out = job_start(
            [
				'rsync',
				'--rsh',
				ShellJoin(rsh_args),
				'--perms',
				'--chmod',
				'700',
				local_rc,
				conn.host .. ':' .. remote_rc,
			],
            {
                exit_cb: (job, status) => {
                    if status == 0
                        OnSuccess()
                    else
                        OnErr()
                    endif
                    # delete(local_rc)
                }
            }
        )
    else
        var scp_cmd = ['scp', '-q', '-S', conn.GetConduitControlPath()]
        scp_cmd->extend(GetScpArgs(conn))
        scp_cmd->extend([local_rc, conn.host .. ':' .. remote_rc])
        job_out = job_start(
            scp_cmd,
            {
                exit_cb: (_, status) => {
                    if status != 0
                        OnErr()
                        delete(local_rc)
                        return
                    endif

					const ExitCb = (_, chmod_status) => {
						if chmod_status == 0
							OnSuccess()
						else
							OnErr()
						endif
						delete(local_rc)
					}

                    job_start(
                        GetSshCommandArgs(conn, ['-S', conn.GetConduitControlPath()], ['chmod', '700', remote_rc]),
                        { exit_cb: ExitCb }
                    )
                }
            }
        )
    endif

    return job_out
enddef

def ParseScp(msg: string): tuple<string, number, string>
    # scp often sends multiple updates in one buffer via carriage returns
    var parts = split(msg, "\r")
    if empty(parts)
        return ("", -1, "")
    endif

    var latest = trim(parts[-1])

    # Regex Breakdown for scp:
    # \s\+([0-9]\+)%          -> Percentage (Group 1)
    # \s\+[0-9.]\+[kKMG]\?B   -> Total transferred (ignored in this tuple)
    # \s\+\([0-9.]\+[kKMG]\?B/s\) -> Transfer Speed (Group 2)
    # \s\+[0-9:]\+\s\+ETA     -> Time remaining (ignored)
    
    var pattern = '\s\+\(\d\+\)%\s\+[0-9.]\+[kKMG]\?B\s\+\([0-9.]\+[kKMG]\?B/s\)'
    var m = matchlist(latest, pattern)

    if !empty(m)
        var percent_str = m[1]
        var speed = m[2]
        var current = str2nr(percent_str)

        return (latest, current, speed)
    endif
    
    # If no match, return the raw string and a -1 signal
    return (latest, -1, "")
enddef

def ParseRsync(msg: string): tuple<string, number, string>
	# Parse rsync progress information
	var parts = split(msg, "\r")
	if empty(parts) 
		return ("", -1, "") 
	endif

	var latest = trim(parts[-1])

	# Regex Breakdown:
	# \s*\([0-9,.]\+\)\s\+      -> Total Size (with optional commas/dots)
	# \([0-9]\+%\)\s\+          -> Percentage (digits + %)
	# \([0-9.]\+[kKMG]\?B/s\)   -> Speed (digits.digits + optional unit + B/s)
	var pattern = '\s*\([0-9,.]\+\)\s\+\([0-9]\+%\)\s\+\([0-9.]\+[kKMG]\?B/s\)'
	var m = matchlist(latest, pattern)

	if !empty(m)
		const percent = m[2]
		const speed = m[3]

		# Convert the percentage to an integer
		var current = -1
		if percent =~ '^\d\+%'
			current = str2nr(percent[: -2])
		else
			return (latest, current, "")
		endif

		return (latest, current, speed)
	endif
	
	return (latest, -1, "")
enddef

# ── UI & User Interaction ────────────────────────────────────────────────────

def FilteredMenu(items: list<string>, OnSelect: func(string), header: string="")
    var search_str = ''
    var filtered_list = items

    def UpdateHighlights(winid: number)
        win_execute(winid, 'clearmatches()')
        if empty(search_str) | return | endif
        for i in range(1, len(filtered_list))
            var start_idx = match(filtered_list[i - 1], $'\c{search_str}')
            if start_idx != -1
                var len_match = len(matchstr(filtered_list[i - 1], $'\c{search_str}'))
                win_execute(winid, $'matchaddpos("Search", [[{i}, {start_idx + 1}, {len_match}]])')
            endif
        endfor
    enddef

    def Refresh(winid: number)
        var bufnr = winbufnr(winid)
        setbufline(bufnr, 1, [''])
        deletebufline(bufnr, 1, '$')
        if !empty(filtered_list)
            setbufline(bufnr, 1, filtered_list)
            UpdateHighlights(winid)
        else
            setbufline(bufnr, 1, '  -- No matches --')
            win_execute(winid, 'clearmatches()')
        endif
    enddef

    var MyFilter = (winid: number, key: string): bool => {
        var changed = false
        var cur_line = line('.', winid)
        var last_line = len(filtered_list)

        if key == "\<Esc>"
            popup_close(winid, -1)
            return true
        elseif key == "\<CR>" || key == "\<C-y>"
            var choice = (cur_line > 0 && cur_line <= last_line) ? filtered_list[cur_line - 1] : ""
			OnSelect(expand(choice))
            return true
        elseif key == "\<C-n>" || key == "\<Down>"
            var target = (cur_line >= last_line) ? 1 : cur_line + 1
            win_execute(winid, $':{target}')
            return true
        elseif key == "\<C-p>" || key == "\<Up>"
            var target = (cur_line <= 1) ? last_line : cur_line - 1
            win_execute(winid, $':{target}')
            return true
        elseif key == "\<BS>" || key == "\<C-h>" || key == "\<Del>"
            if len(search_str) > 0
                search_str = search_str[ : -2]
                changed = true
            endif
        elseif key =~ '^\p$'
            search_str ..= key
            changed = true
        else
            return popup_filter_menu(winid, key)
        endif

        if changed
            filtered_list = filter(copy(items), (_, val) => val =~? search_str)
            Refresh(winid)
            popup_setoptions(winid, {title: $' Search: {search_str} '})
        endif
        return true
    }

    popup_menu(filtered_list, {
        title: $' {header} ',
        filter: MyFilter,
        pos: 'botleft',
        line: 'cursor-1',
        col: 'cursor',
        padding: [0, 1, 0, 1],
        borderchars: g:conduit_borderchars,
        border: [1, 1, 1, 1, 1, 1, 1, 1],
        width: &columns - 10,
        maxheight: 10,
        scrollbar: true,
    })
enddef

def MultiChoicePrompt(items: list<string>, OnSelect: func(string), header: string="")
    # Print the header
	if !empty(header)
		echohl Title
		echon header
		echohl clear
	endif

	# Print the available files to select
	echon "\n"
    for i in range(len(items))
        # Using echon and \n to be more explicit about line breaks
        echon $'{i + 1}: '
		if getftype(items[i]) ==# "file"
			echohl File
		elseif getftype(items[i]) ==# "dir"
			echohl Directory
		else
			echohl Normal
		endif

        echon items[i]
		echohl clear
		echon "\n"
    endfor

    # Prompt for input
	echohl Question
    var user_input = input('Select files (comma-separated or search string): ')
	echohl clear

    if empty(user_input)
        redraw | echo "Cancelled."
        return
    endif

    # Process the tokens
    var tokens = split(user_input, '[, ]\+')
    var selected_items: list<string> = []

    for token in tokens
        if token =~ '^\d\+$'
            var idx = str2nr(token) - 1
            if idx >= 0 && idx < len(items)
                add(selected_items, items[idx])
            endif
        else
			echom "×"
            var matches = filter(copy(items), (_, val) => val =~? token)
            if !empty(matches)
                if index(selected_items, matches[0]) == -1
                    add(selected_items, matches[0])
                endif
            endif
        endif
    endfor

    # Final cleanup and execution
    redraw # Clears the list and prompt from the screen
    if !empty(selected_items)
		for item in selected_items | OnSelect(expand(item)) | endfor
    else
        echoerr "No valid matches found for: " .. user_input
    endif
enddef

# Converts 'ab/cde/fgh' -> 'a[^/]*b/c[^/]*d[^/]*e/f[^/]*g[^/]h' for fuzzy
# searching
def MakeAnchoredFuzzy(input: string): string
    var segments = input->split('/')
    var regex_segments = []

    for seg in segments
        if empty(seg) | continue | endif
        # For each segment, allow any char EXCEPT a slash between letters
        var fuzzy_seg = seg->split('\zs')->join('[^/]*')
        add(regex_segments, fuzzy_seg)
    endfor

    # Join with literal slashes and wrap in wildcards for the start/end
    return $'.*{join(regex_segments, "/")}.*'
enddef

def Warn(msg: string)
	if g:conduit_use_popup
		notifier.Send($'× {msg}')
	else
		echohl WarningMsg
		echom msg
		echohl None
	endif
enddef

# ── Command Implementation ───────────────────────────────────────────────────

def OpenConduitControlMaster(conn: Connection): number
	if getftype(conn.GetConduitControlPath()) ==# "socket"
		system(GetSshCommandString(conn, ['-O', 'check', '-S', conn.GetConduitControlPath()]))

		if v:shell_error == 0 | return 0 | endif
		system(GetSshCommandString(conn, ['-O', 'exit', '-S', conn.GetConduitControlPath()]))
	endif

	system(GetSshCommandString(
		conn,
		[
			'-fN',
			'-M',
			'-o', $'ControlPersist={conn.GetConduitControlPersist()}',
			'-S', conn.GetConduitControlPath(),
		]
		))

	return v:shell_error
enddef

export def ConduitOpenCmd(deploy_only: bool, curwin: bool, mods: string, args: string)
	const prefix = deploy_only ? "ConduitDeploy" : "ConduitOpen"

	var notif = notifier.StartLoading($"Connecting")
    # redraw!

    if empty(args)
        Warn($'Usage:  {prefix} [++SSHOPT ...] [user@]host[:port]')
		notifier.Dismiss(notif)
        return
    endif

	var parsed: dict<any>
	try
		parsed = ParseConduitOpenArgs(args)
	catch
		Warn($'Usage:  {prefix} [++SSHOPT ...] [user@]host[:port]')
		notifier.Dismiss(notif)
		return
	endtry

	var host = parsed.host
	var port = parsed.port
	var ssh_options = parsed.ssh_options

	var conn: Connection
	try
		conn = MaybeAddEmptyConnection(host, port, ssh_options)
	catch /E1013/
        Warn($'Usage:  {prefix} [++SSHOPT ...] [user@]host[:port]')
		notifier.Dismiss(notif)
		return
	endtry

	var OpenSession = () => {
		# Use a timer to escape the current callback context (if any)
		# and run the session opening in a clean context.
		timer_start(0, (_) => {
			const open_control_master_err_code = OpenConduitControlMaster(conn)
			if open_control_master_err_code != 0
				notifier.StopLoading(notif, $"× Could not open control master (ssh error: {open_control_master_err_code})")
				timer_start(5000, (__) => notifier.Dismiss(notif))
				return 
			endif

			# Restart notification to update the animation timer's string
			notifier.UpdateLoading(notif, $"Starting listener")
			redraw

			if !EnsureListener(conn)
				notifier.StopLoading(notif, $"× Could not start listener")
				timer_start(5000, (__) => notifier.Dismiss(notif))
				return 
			endif

			var remote_sock = conn.GetRemoteReverseTunnelSocketPath()
			var remote_rc   = conn.GetRemoteRCPath()
			var sock_path = conn.GetLocalReverseTunnelSocketPath()

			notifier.UpdateLoading(notif, $"Deploying rc file")
			redraw
			DeployRcfile(
				conn,
				() => {
					const tunnel  = remote_sock .. ':' .. sock_path

					if deploy_only 
						var ssh_cmd = GetSshCommandArgs(
							conn,
							[
								'-f',
								'-N',
								'-S', conn.GetConduitControlPath(),
								'-o', 'StreamLocalBindUnlink=yes',
								'-o', 'ExitOnForwardFailure=yes',
								'-R', tunnel,
							]
						)

						job_start(
							ssh_cmd, {
							exit_cb: (___, code) => {
								if code == 0
									notifier.StopLoading(notif, $"✓ Success")
									timer_start(2000, (____) => notifier.Dismiss(notif))
									ConduitCopySourceCmd(GetConnectionsDictKey(conn))
								else
									notifier.StopLoading(notif, $"× Failed (error: {code})")
									timer_start(5000, (____) => notifier.Dismiss(notif))
								endif
								redraw
							}}
						)

						return 
					endif

					notifier.UpdateLoading(notif, $"Opening ssh reverse tunnel")
					redraw
					var ssh_cmd = GetSshCommandArgs(
						conn,
						[
							'-t',
							'-S', conn.GetConduitControlPath(),
							'-o', 'StreamLocalBindUnlink=yes',
							'-o', 'ExitOnForwardFailure=yes',
							'-R', tunnel,
						],
						[
							conn.ConduitShell(),
							'--rcfile',
							remote_rc,
							'-i',
						]
					)

					var term_name = 'conduit://' .. conn.GetProfileKey()
					var spawn_cmd: string
					if !curwin
						spawn_cmd = (mods =~ 'tab') ? 'tabnew' : 'split'
					endif
					execute mods .. ' ' .. spawn_cmd .. ' | enew'
					const term_bufnr = term_start(
						ssh_cmd, { term_name: term_name, curwin: true }
					)
					conn.AddTermByBufNr(term_bufnr)

					# User a timer for the success message since the ssh
					# connection is already authenticated, and the previous
					# message will only be shown briefly otherwise
					timer_start(1000, (____) => notifier.StopLoading(notif, $"✓ Success"))
					timer_start(3000, (_____) => notifier.Dismiss(notif))
					redraw
				},
				() => {
					notifier.StopLoading(notif, $"× Failed")
					MaybeCleanup(conn)
					timer_start(5000, (____) => notifier.Dismiss(notif))
					redraw
				},
			) 
		})
	}

	if conn.ConduitOpen() && conn.ConnectedTerms() == 0
		# Restart notification for cleanup step
		notifier.UpdateLoading(notif, $"Cleaning up stale files on remote")
		redraw
		MaybeCleanup(conn, false, false, (success) => {
			if success
				OpenSession()
				redraw
			else
				notifier.StopLoading(notif, $"× Could not clean up stale files on remote, exiting.")
				timer_start(5000, (_) => notifier.Dismiss(notif))
				redraw
			endif
		})
	else
		OpenSession()
		redraw
	endif
enddef

export def ConduitExitCmd(host: string)
	const key = ResolveConnectionKey(host)
	if !empty(key)
		const conn = connections[key]
		if getftype(conn.GetConduitControlPath()) ==# "socket"
			var notif = notifier.StartLoading($"Exiting from {host}")

			# Stop the running terminal job
			for bufnr in keys(conn.term_bufnr)
				const term_job = term_getjob(conn.term_bufnr[bufnr])
				if job_status(term_job) == 'run'
					job_stop(term_job)
				endif
			endfor

			# Perform cleanup
			const success = MaybeCleanup(conn, false, true)

			# Exit the control master socket
			system(GetSshCommandString(conn, ['-O', 'exit', '-S', conn.GetConduitControlPath()]))
			# delete(conn.GetConduitControlPath())

			if success && v:shell_error == 0
				timer_start(500, (_) => notifier.StopLoading(notif, $"✓ Exited from {host}"))
				timer_start(3500, (_) => notifier.Dismiss(notif))
			else
				timer_start(500, (_) => notifier.StopLoading(notif, $"× Could not exit from {host}"))
				timer_start(5500, (_) => notifier.Dismiss(notif))
			endif
		endif
	else
        Warn($'No current control socket for {host}')
	endif
enddef

export def ConduitStopCmd(type: string, args: list<string>)
	if empty(args) | return | endif
	var key = ResolveConnectionKey(args[0])
	var iden = (len(args) > 1) ? args[1] : ""
	if empty(key)
		Warn($'No current control socket for {args[0]}')
		return
	endif

	var ops: list<Op>
	if type ==# "get"
		ops = g:conduit_get_ops
	elseif type ==# "put"
		ops = g:conduit_put_ops
	elseif type ==# "*"
		ops = []->extend(g:conduit_put_ops)->extend(g:conduit_get_ops)
	else
		Warn($'Cannot stop unknown operation {type}')
		return
	endif

	var i = len(ops) - 1
	while i >= 0
		const op = ops[i]
		if op.conn_key ==# key
			var stop = false
			if empty(iden) || iden == "*"
				stop = true
			else
				const search_over: list<string> = [op.local_file, op.remote_file]
				if !empty(matchfuzzy(search_over, iden))
					stop = true
				endif
			endif

			if stop
				if job_status(op.job) ==# 'run' | job_stop(op.job) | endif
				ops->remove(i)
			endif
		endif
		i -= 1
	endwhile
enddef

export def ConduitDisconnectCmd(host: string)
	const key = ResolveConnectionKey(host)
	if !empty(key)
		const notif = notifier.StartLoading($"Disconnecting from {host}")
		connections[key].Disconnect()
		notifier.StopLoading(notif, $"✓ Disconnected from {host}")
		timer_start(3000, (_) => notifier.Dismiss(notif))
	else
        Warn($'No host "{host}"')
	endif
enddef

export def ConduitCopySourceCmd(host: string)
	const key = ResolveConnectionKey(host)
	if !empty(key)
		const conn = connections[key]
		const source_cmd = $"source {conn.GetRemoteRCPath()}"
		echom $"run: {source_cmd}" 
		@+ = source_cmd
	else
        Warn($'No host "{host}"')
	endif
enddef

export def ShowHistory()
	notifier.ShowHistory()
enddef

# ── Vim Command Interface ────────────────────────────────────────────────────

export def ConduitCmd(deploy_only: bool, curwin: bool, mods: string, ...args: list<string>)
	if empty(args) | return | endif

	const cmd = args[0]
	var cmd_args = ""
	if len(args) > 1
		cmd_args = args[1 :]->join(" ")
	endif

	if cmd ==# "open" # :Conduit open HOST
		if len(args) < 2
			echoerr "Usage:  Conduit open [++SSHOPT ...] [user@]host[:port]"
		else
			ConduitOpenCmd(deploy_only, curwin, mods, cmd_args)
		endif

	elseif cmd ==# "exit" # :Conduit exit HOST
		if len(args) != 2
			echoerr "Usage:  Conduit exit [connection-key]"
		else
			ConduitExitCmd(cmd_args)
		endif

	elseif cmd ==# "deploy" # :Conduit deploy HOST
		if len(args) < 2
			echoerr "Usage:  Conduit deploy [++SSHOPT ...] [user@]host[:port]"
		else
			ConduitOpenCmd(true, false, '', cmd_args)
		endif

	elseif cmd ==# "disconnect" # :Conduit disconnect HOST
		if len(args) != 2
			echoerr "Usage:  Conduit disconnect [connection-key]"
		else
			ConduitDisconnectCmd(args[1])
		endif

	elseif cmd ==# "source" # :Conduit source HOST
		if len(args) != 2
			echoerr "Usage:  Conduit source [connection-key]"
		else
			ConduitCopySourceCmd(cmd_args)
		endif

	elseif cmd ==# "notifications" # :Conduit notifications
		notifier.ShowHistory()

	elseif cmd ==# "stop" # :Conduit stop OP HOST PATTERN
		if len(args) != 4
			echoerr "Usage:  Conduit stop op [connection-key] pattern"
		else
			ConduitStopCmd(args[1], args[2 :])
		endif
	else
		echoerr $"error: unknown command {cmd}"
	endif
enddef

# ── Completion Logic ─────────────────────────────────────────────────────────

def ExtractConduitConfig(path: string = '~/.ssh/config'): list<string>
    var full_path = expand(path)
    if !filereadable(full_path) | return [] | endif

    # Use a Dictionary to store { alias: connection_string }
    # This automatically handles duplicates (last one wins)
    var unique_hosts: dict<string> = {}
    var lines = readfile(full_path)

    var current_aliases: list<string> = []
    var hostname = ''
    var user = $USER
    var port = '22'
    var host_active = false

    var FlushEntry = () => {
        if host_active && !empty(current_aliases) && hostname != ''
            var connection = printf("%s@%s:%s", user, hostname, port)
            for alias in current_aliases
                if alias != '*'
                    unique_hosts[alias] = connection
                endif
            endfor
        endif
    }

    for line in lines
        var clean_line = line->trim()->substitute('#.*', '', '')
        if clean_line == '' | continue | endif

        var parts = split(clean_line, '\s\+')
        if len(parts) < 2 | continue | endif

        var key = parts[0]->tolower()
        var val = parts[1]

        if key == 'host'
            FlushEntry()
            current_aliases = parts[1 : ]
            hostname = ''
            host_active = true
        elseif key == 'hostname'
            hostname = val
        elseif key == 'user'
            user = val
        elseif key == 'port'
            port = val
        elseif key == 'include'
            # Recursively merge results from included files
            var included_results = ExtractConduitConfig(val)
            # included_results is a flat list [alias, conn, alias, conn]
            # We map it back into our dictionary
            for i in range(0, len(included_results) - 1, 2)
                unique_hosts[included_results[i]] = included_results[i + 1]
            endfor
        endif
    endfor

    FlushEntry()

    # Convert dictionary back to a flat list
    var final_list = []
    for [alias, conn] in items(unique_hosts)
        add(final_list, alias)
        add(final_list, conn)
    endfor

    return sort(final_list)
enddef

# Helper to get the string relative to the last pipe
def GetCurrentCmd(CmdLine: string, CursorPos: number): string
    # Slice the line up to the cursor, then split by '|'
    var parts = split(CmdLine[: CursorPos - 1], '|')
    # Return the last segment, trimmed of leading whitespace
    return empty(parts) ? "" : substitute(parts[-1], '^\s*', '', '')
enddef

def ToTitleCase(input: string): string
  return substitute(input, '\<\(\w\)\(\w*\)\>', '\u\1\L\2', 'g')
enddef

export def ConduitHostComplHelper(current_cmd: string, pattern: string): list<string>
    var options = ExtractConduitConfig()
    return filter(options, (_, val) => val =~ '^' .. pattern)
enddef

export def ConduitHostCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    if ArgLead =~# '^++'
        return []
    endif
    var current_cmd = GetCurrentCmd(CmdLine, CursorPos)
	return ConduitHostComplHelper(current_cmd, ArgLead)
enddef

export def ConduitActiveComplHelper(current_cmd: string, pattern: string): list<string>
    var options = keys(connections)
    return filter(options, (_, val) => val =~ pattern)
enddef

export def ConduitActiveCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    var current_cmd = GetCurrentCmd(CmdLine, CursorPos)
	return ConduitActiveComplHelper(current_cmd, ArgLead)
enddef

export def ConduitCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    const current_cmd = GetCurrentCmd(CmdLine, CursorPos)
    const parts = split(current_cmd)
	const cmd = len(parts) > 1 ? parts[1] : ""

    # Completing the sub-command (e.g., "Conduit op")
    if current_cmd =~ '^Conduit!\? \+\S*$'
        var options = ["open", "exit", "deploy", "disconnect", "source", "notifications", "stop"]
        return filter(options, (_, val) => val =~ '^' .. ArgLead)

    # Completing the host argument for open/deploy.
    elseif cmd ==# "open" || cmd ==# "deploy"
		if ArgLead =~# '^++'
			return []
		endif
		return ConduitHostComplHelper(current_cmd, ArgLead)

    # Completing the second argument for the other sub-commands.
    elseif current_cmd =~ '^Conduit!\? \+\S\+ \+\S*$'
        if len(parts) >= 2
			if cmd ==# "stop"
				return ["get", "put", "*"]
            else
				const prefix = "Conduit" .. ToTitleCase(cmd)
				const host = len(parts) >= 3 ? parts[2] : "" # Fixed index: parts[2] is the host
				return ConduitActiveComplHelper(prefix .. ' ' .. host, ArgLead)
            endif
        endif

	# Completing the third argument (e.g., "Conduit stop put myho")
    elseif current_cmd =~ '^Conduit!\? \+\S\+ \+\S\+ \+\S*$' 
		if cmd ==# "stop" # `Conduit stop put host`
			const prefix = "Conduit" .. ToTitleCase(cmd)
			const host = len(parts) >= 4 ? parts[3] : ""
			return ConduitActiveComplHelper(prefix .. ' ' .. host, ArgLead)
		endif

	# Completing the fourth argument (e.g., "Conduit stop get myhost iden")
    elseif current_cmd =~ '^Conduit!\? \+\S\+ \+\S\+ \+\S\+ \+\S*$' 
		if cmd ==# "stop"
			# First, check if there are any active hosts
			const prefix = "Conduit" .. ToTitleCase(cmd)
			const host = len(parts) >= 4 ? parts[3] : ""
			const active = !empty(ConduitActiveComplHelper(prefix .. ' ' .. host, ArgLead))

			# If no active hosts, don't return any files
			if !active | return [] | endif

			# Go through each operation, if it is an operation on the selected
			# host, add the local/remote files from the operation to the
			# completion items
			var files: list<string> = []
			const op_type = parts[2]

			var ops: list<Op>
			if op_type ==# "get"
				ops = g:conduit_get_ops
			elseif op_type ==# "put"
				ops = g:conduit_put_ops
			elseif op_type ==# "*"
				ops = []->extend(g:conduit_put_ops)->extend(g:conduit_get_ops)
			else
				return []
			endif

			for op in ops
				if op.conn_key !=# host | continue | endif
				files->add(op.local_file)
				files->add(op.remote_file)
			endfor

			if !empty(files) | files->add('*') | endif
			return files
		endif

    endif

    return []
enddef

# ── Lifecycle & Integration ──────────────────────────────────────────────────

export def MaybeCleanup(conn: Connection, all: bool = false, force: bool = false, Callback: func(bool): void = null_function): bool
	if conn == null && !all
		throw 'error: must specify connection when `all` is false'
	elseif conn == null
		if Callback != null | Callback(true) | endif
		return true
	endif

	var connections_to_clean: list<Connection> = [conn]
	if all | connections_to_clean = values(connections) | endif

	var success = true
	for c in connections_to_clean
		if !force && c.ConnectedTerms() > 0
			# Don't cleanup if there are terminals still connected
			continue
		endif

		# Close the listener job and cleanup sockets and files if no ConduitOpen
		# terminals exist. We keep the ssh control master connection socket
		# (not the reverse tunnel) so future ConduitOpen commands are fast.
		if job_status(c.listener_job) == 'run'
			# Cleanup job listener
			job_stop(c.listener_job)
		endif

		const local_sock = c.GetLocalReverseTunnelSocketPath()
		if getftype(local_sock) == 'socket'
			# Cleanup local reverse tunnel socket
			delete(local_sock)
		endif

		if c.ConduitOpen()
			# Remove the rc file and reverse tunnel socket on the server if we
			# can still connect to it.

			const remote_rc = c.GetRemoteRCPath()
			const remote_sock = c.GetRemoteReverseTunnelSocketPath()
			const tunnel = remote_sock .. ':' .. local_sock

			# If all is true, we are in VimLeave, so do it sync
			if all
				system(GetSshCommandString(c, ['-S', c.GetConduitControlPath(), '-O', 'cancel', '-R', tunnel]))
				const control_master_error = v:shell_error
				system(GetSshCommandString(c, ['-S', c.GetConduitControlPath()], ['rm', '-f', remote_rc, remote_sock]))
				const remote_cleanup_error = v:shell_error
				success = success && (control_master_error == 0) && (remote_cleanup_error == 0)
				if Callback != null | Callback(success) | endif
			else
				# Async cleanup via a background job
				job_start(
					GetSshCommandArgs(c, ['-S', c.GetConduitControlPath(), '-O', 'cancel', '-R', tunnel]),
					{
						exit_cb: (_, cancel_code) => {
							if cancel_code != 0
								if Callback != null | Callback(false) | endif
								return
							endif

							const ExitCb = (_, rm_code) => {
								if Callback != null  | Callback(rm_code == 0) | endif 
							}

							job_start(
								GetSshCommandArgs(c, ['-S', c.GetConduitControlPath()], ['rm', '-f', remote_rc, remote_sock]),
								{exit_cb: ExitCb},
							)
						}
					}
				)
			endif
		else
			if Callback != null | Callback(true) | endif
		endif
	endfor
	return success
enddef

export def ConduitStatus(): string
	for conn in values(connections)
		if job_status(conn.listener_job) == 'run'
			return '[ssh]'
		endif
	endfor
	return ''
enddef
