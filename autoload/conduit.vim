vim9script

import autoload 'notifier.vim'
import autoload 'error.vim'

# ── Utility Helpers ──────────────────────────────────────────────────────────

def GetSuccessTimeout(): number
	const default = 5000
	const timeout = get(g:, 'conduit_success_timeout', default)
	if type(timeout) != v:t_number
		echoerr "expected g:conduit_success_timeout to be a number"
		return default
	endif
	return timeout
enddef

def GetFailureTimeout(): number
	const default = 5000
	const timeout = get(g:, 'conduit_failure_timeout', default)
	if type(timeout) != v:t_number
		echoerr "expected g:conduit_failure_timeout to be a number"
		return default
	endif
	return timeout
enddef

def UseRsync(): bool
	const use_rsync = get(g:, 'conduit_use_rsync', executable('rsync'))

	if use_rsync && !executable('rsync')
		const msg = error.Error.RsyncScpUnavailable.Format(
			'rsync unavailable, set "g:conduit_use_rsync=0" to switch to scp'
		)
		notifier.Send($'‹×› {msg}')
		echoerr msg
		return false
	endif

	return use_rsync
enddef

# ── Constants ────────────────────────────────────────────────────────────────

const avaliable_shells = ['zsh', 'bash', 'sh']

const modifiers = [
	"tab",
	"vert", "vertical",
	"hor", "horizontal",
	"lefta", "leftabove",
	"abo", "aboveleft",
	"rightb", "rightbelow",
	"bel", "belowright",
	"to", "topleft",
	"bo", "botright",
]

const open_file_ops = [
	"split", "sp",
	"vsplit", "vsp", "vert", "vertical",
	"tabe", "tabedit", "tabnew", "tab",
	"arga", "argadd",
	"arge", "argedit",
]

# All supported `lvim` ops
const all_ops = ["put", "get", "mget", "mput"]->extend(open_file_ops)->extend(modifiers)

# ── Classes & Core Types ─────────────────────────────────────────────────────
abstract class ConduitOption
	var takes_value: bool
	var long: string = ''

	def ShortName(): string
		return ''
	enddef

	def IsForwarding(): bool
		return false
	enddef

	def Is(other: ConduitOption): bool
		return this is other
	enddef

	abstract def Apply(ssh_options: list<string>, term_options: dict<any>, value: string)
	abstract def MissingValueError(): error.Error
endclass

class SshOption extends ConduitOption
	var short: string
	var is_forwarding: bool

	def new(short: string, long: string = '', takes_value: bool = true, is_forwarding: bool = false)
		this.short = short
		this.long = long
		this.takes_value = takes_value
		this.is_forwarding = is_forwarding
	enddef

	def ShortName(): string
		return this.short
	enddef

	def IsForwarding(): bool
		return this.is_forwarding
	enddef

	def Apply(ssh_options: list<string>, term_options: dict<any>, value: string)
		ssh_options->extend(this.takes_value ? [$'-{this.short}', value] : [$'-{this.short}'])
	enddef

	def MissingValueError(): error.Error
		return error.Error.SshOptionRequiresValue
	enddef
endclass

class TermOption extends ConduitOption
	def new(long: string, takes_value: bool = false)
		this.long = long
		this.takes_value = takes_value
	enddef

	def Apply(ssh_options: list<string>, term_options: dict<any>, value: string)
		term_options[this.long] = value
	enddef

	def MissingValueError(): error.Error
		return error.Error.TermOptionRequiresValue
	enddef
endclass

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

	def ParseShellName(): string
		return fnamemodify(this.ConduitShell(), ':t')
	enddef

	def ShellAvailable(): bool
		const shell = this.ParseShellName()
		if empty(shell) | return false | endif
		return !empty(filter(deepcopy(avaliable_shells), (_, sh) => shell ==# sh))
	enddef

	def ConduitShellStartupCmd(remote_rc: string, echoerr: bool = false): list<string>
		const shell = this.ParseShellName()
		if shell ==# 'zsh'
			const base = fnamemodify(remote_rc, ':h')
			return [$'ZDOTDIR={base}', shell]
		elseif shell ==# 'bash' || shell ==# 'sh'
			return [shell, '--rcfile', remote_rc, '-i']
		else
			if echoerr
				echoerr error.Error.UnsupportedShell.Format($'unsupported shell {shell}')
			endif
			return []
		endif
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

	def GetSshConfigControlPath(): string
		for line in systemlist(GetSshCommandString(this, ['-G']))
			if line =~# '^controlpath '
				return line[len('controlpath ') : ]
			endif
		endfor

		return ''
	enddef

	def IsManuallyControlledMultiplexing(): bool
		return empty(this.GetSshConfigControlPath())
	enddef

	def GetConduitControlPersist(): string
		const default = g:conduit_default_control_persist

		if !empty(this.GetSshConfigControlPath())
			# If there is an ssh config file to use, check if there is a
			# control persist setting specified there
			for line in systemlist(GetSshCommandString(this, ['-G']))
				if line =~# '^controlpersist '
					return line[len('controlpersist ') : ] 
				endif
			endfor

			# No control persist specified in ssh config, use default
			return default
		endif
		return default
	enddef

	def GetConduitControlPath(): string
		const controlpath = this.GetSshConfigControlPath()
		if !empty(controlpath)
			return controlpath
		endif

		const control_options = GetNonForwardingSshOptions(this)
		if this.port > 0
			return $'/tmp/.vim-conduit-connection-{this.host}-{this.port}{GetProfileSuffix(control_options)}.sock'
		endif
		return $'/tmp/.vim-conduit-connection-{this.host}{GetProfileSuffix(control_options)}.sock'
	enddef

	def GetConnectTimeout(): number
		return get(g:, 'conduit_connect_timeout', 10)
	enddef

	def GetConnectionAttempts(): number
		return get(g:, 'conduit_connection_attempts', 1)
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

						const bufhidden = get(g:, 'conduit_bufhidden', 'wipe')
						if !empty(bufhidden)
							setbufvar(bufnr, '&bufhidden', bufhidden)
						endif 
					}
				)

				this.RemoveTermByBufNr(bufnr)
			}})
		endif

	enddef

	def SetListenerJob(job: job)
		this.listener_job = job
	enddef

	def GetSockReady(): bool
		return this.sock_ready
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

# Everything needed to (re)start a run: the command, where it ran, its
# errorformat, and which list it targets. Captured on every run so `Conduit!
# run` can replay the previous invocation verbatim.
class RunSpec
	var command: string
	var cwd: string
	var efm: string
	# Whether the run targets a location list. The owning window is
	# deliberately not stored: a rerun resolves it afresh, so it never points
	# at a window that has since been closed or reused.
	var use_loclist: bool

	def new(command: string, cwd: string, efm: string, use_loclist: bool = false)
		this.command = command
		this.cwd = cwd
		this.efm = efm
		this.use_loclist = use_loclist
	enddef
endclass

# Coalesce the normalize pass across bursts of output: a command emitting
# thousands of lines triggers a bounded number of rewrites, not one per line.
const run_normalize_delay = 50

# Owns where a run's parsed output lands and when its deferred normalize pass
# runs. Every setqflist()/getqflist() call for a run goes through here, so the
# task itself never names a list API. Wraps whichever of the quickfix or
# location list APIs applies, so RunTask can stay agnostic to which one it is
# writing.
class RunListSink
	# When true the run feeds the location list of `winid`; otherwise it feeds
	# the quickfix list and `winid` is unused. A location list is addressed by
	# window, and setloclist() reads window 0 as "the current window", so the
	# mode needs its own flag rather than a sentinel winid.
	var use_loclist: bool
	var winid: number
	var id: number
	var efm: string
	# Number of leading items a previous normalize pass already rewrote;
	# everything below it needs no second look.
	var normalized: number
	# Pending normalize timer, or -1 when none is armed.
	var timer: number

	def new(efm: string, use_loclist: bool = false, winid: number = 0)
		this.use_loclist = use_loclist
		this.winid = winid
		this.id = 0
		this.efm = efm
		this.normalized = 0
		this.timer = -1
	enddef

	# A location list is owned by its window and is freed when that window
	# closes, while the job feeding it keeps running. Quickfix has no such
	# owner, so it is always alive. Every write goes through this check, so no
	# caller has to remember it.
	def IsAlive(): bool
		return !this.use_loclist || !empty(getwininfo(this.winid))
	enddef

	# Common write path for both list kinds; a no-op once IsAlive() is false.
	def Set(action: string, what: dict<any>)
		if !this.IsAlive() | return | endif
		if this.use_loclist
			setloclist(this.winid, [], action, what)
		else
			setqflist([], action, what)
		endif
	enddef

	# Common read path for both list kinds; returns {} once IsAlive() is false.
	def Get(what: dict<any>): dict<any>
		if !this.IsAlive() | return {} | endif
		return this.use_loclist
			? getloclist(this.winid, what)
			: getqflist(what)
	enddef

	# Push a fresh list and adopt its id, so later writes keep targeting this
	# task's list even once it is no longer the current one.
	def Create(title: string, context: dict<any>)
		this.Set(' ', {title: title, context: context})
		this.id = get(this.Get({id: 0}), 'id', 0)
	enddef

	# "nr" comes back as 0 once the list has been freed — or once the owning
	# window is gone — which is how callers tell a late pass not to write.
	def Read(): dict<any>
		const empty_list = {items: [], nr: 0, title: ''}
		if this.id <= 0 | return empty_list | endif
		const result = this.Get({id: this.id, items: 0, nr: 0, title: 0})
		return empty(result) ? empty_list : result
	enddef

	# For a location list this also requires standing in the owning window:
	# auto-opening someone else's list under a window they are not looking at
	# would be a surprise, and :lwindow only acts on the current window.
	def IsCurrent(): bool
		if this.id <= 0 || !this.IsAlive() | return false | endif
		if this.use_loclist && win_getid() != this.winid | return false | endif
		return get(this.Get({id: 0}), 'id', 0) == this.id
	enddef

	# Only reached when IsCurrent() holds, so the owning window is current.
	def Open()
		if this.use_loclist
			silent! lwindow
		else
			silent! cwindow
		endif
	enddef

	def OpenCommand(): string
		return this.use_loclist ? ':lopen' : ':copen'
	enddef

	# Parses `lines` against this run's efm and appends the resulting entries.
	def Append(lines: list<string>)
		this.Set('a', {id: this.id, lines: lines, efm: this.efm})
	enddef

	# Wholesale-replaces the list's items, e.g. after rewriting entries to
	# point at remote-backed buffers.
	def Replace(items: list<dict<any>>, title: string, context: dict<any>)
		this.Set('r', {
			id: this.id,
			items: items,
			title: title,
			context: context,
		})
	enddef

	# Sets the final title/context once a run has ended, without touching items.
	def Finish(title: string, context: dict<any>)
		this.Set('a', {id: this.id, title: title, context: context})
	enddef

	def SetContext(context: dict<any>)
		this.Set('a', {id: this.id, context: context})
	enddef

	def SetNormalized(count: number)
		this.normalized = count
	enddef

	# Arms the coalesced normalize pass; a timer already pending is left alone
	# so a burst of output only schedules one rewrite.
	def Schedule(Pass: func)
		if this.timer >= 0 | return | endif
		this.timer = timer_start(run_normalize_delay, (_) => Pass())
	enddef

	# Cancels any pending normalize pass, e.g. when the task is finishing and
	# is about to do one last synchronous rewrite itself.
	def Disarm()
		if this.timer >= 0
			timer_stop(this.timer)
			this.timer = -1
		endif
	enddef
endclass

# A single in-flight (or just-finished) `:Conduit run` invocation: the ssh
# job driving it, the quickfix/location list it feeds via `sink`, and enough
# state to report/rerun it once the job exits.
class RunTask
	var id: number
	var conn_key: string
	var job: job
	var command: string
	# The cwd the caller requested (may be empty); use resolved_cwd once known.
	var requested_cwd: string
	# The cwd the remote command actually ran in, learned from the printf
	# marker the job prints before running the command. Empty until then.
	var resolved_cwd: string
	var efm: string
	var sink: RunListSink
	var notif: number
	var line_count: number
	var cancelled: bool

	def new(
		id: number,
		conn_key: string,
		command: string,
		requested_cwd: string,
		efm: string,
		sink: RunListSink,
		notif: number,
	)
		this.id = id
		this.conn_key = conn_key
		this.job = null_job
		this.command = command
		this.requested_cwd = requested_cwd
		this.resolved_cwd = ''
		this.efm = efm
		this.sink = sink
		this.notif = notif
		this.line_count = 0
		this.cancelled = false
	enddef

	def SetJob(j: job)
		this.job = j
	enddef

	def SetResolvedCwd(cwd: string)
		this.resolved_cwd = cwd
	enddef

	def AddLine()
		this.line_count += 1
	enddef

	# Marks the task as user-cancelled so FinishRunTask() reports "stopped"
	# rather than treating the job's exit code as a failure.
	def Cancel()
		this.cancelled = true
	enddef
endclass

# ── Connection & State Management ────────────────────────────────────────────

# List of all Conduit SSH options
const ssh_option_specs: list<SshOption> = [
	SshOption.new('B', 'bindinterface'),
	SshOption.new('b', 'bindaddress'),
	SshOption.new('c', 'cipher'),
	SshOption.new('D', 'dynamicforward', true, true),
	SshOption.new('E', 'logfile'),
	SshOption.new('F', 'config'),
	SshOption.new('I', 'pkcs11'),
	SshOption.new('i', 'identity'),
	SshOption.new('J', 'proxyjump'),
	SshOption.new('l', 'login'),
	SshOption.new('L', 'localforward', true, true),
	SshOption.new('m', 'mac'),
	SshOption.new('o', 'option'),
	SshOption.new('p', 'port'),
	SshOption.new('Q', 'query'),
	SshOption.new('R', 'remoteforward', true, true),
	SshOption.new('w', 'tunnel', true, true),
]

# List of all Conduit terminal options
const term_option_specs: list<TermOption> = [
	TermOption.new('vertical'),
	TermOption.new('close'),
	TermOption.new('noclose'),
	TermOption.new('curwin'),
	TermOption.new('open'),
	TermOption.new('hidden'),
	TermOption.new('norestore'),
	TermOption.new('shell'),
	TermOption.new('rows', true),
	TermOption.new('cols', true),
	TermOption.new('eof', true),
	TermOption.new('api', true),
	TermOption.new('kill', true),
	TermOption.new('opencmd', true),
]

# Stores all ConduitOptions
var all_option_specs: list<ConduitOption> = []
all_option_specs->extend(ssh_option_specs)
all_option_specs->extend(term_option_specs)

# Stores short/long option text -> ConduitOption
var opts_by_short: dict<ConduitOption> = {}
var opts_by_long: dict<ConduitOption> = {}
for spec in all_option_specs
	if !empty(spec.long) | opts_by_long[spec.long] = spec | endif
	const short = spec.ShortName()
	if !empty(short) | opts_by_short[short] = spec | endif
endfor

# Stores profile key -> Connections
var connections: dict<Connection> = {}
var run_tasks: list<RunTask> = []
var last_runs: dict<RunSpec> = {}
var remote_buffers: dict<number> = {}
var next_run_id = 1

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

# Splits a connection's ssh_options into [forwarding, non-forwarding],
# keeping value-taking options paired with their value.
def SplitForwardingSshOptions(ssh_options: list<string>): tuple<list<string>, list<string>>
	var forwarding: list<string> = []
	var other: list<string> = []
	var i = 0
	while i < len(ssh_options)
		const opt = ssh_options[i]
		const flag = opt[1 :]
		const spec: ConduitOption = get(opts_by_short, flag, null_object)
		const is_forwarding = spec isnot null_object && spec.IsForwarding()
		var dest = is_forwarding ? forwarding : other
		if spec isnot null_object && spec.takes_value
			dest->extend(ssh_options[i : i + 1])
			i += 2
		else
			dest->add(opt)
			i += 1
		endif
	endwhile
	return (forwarding, other)
enddef

def GetNonForwardingSshOptions(conn: Connection): list<string>
	const [_, other] = SplitForwardingSshOptions(conn.GetSshOptions())
	return other
enddef

def GetForwardingSshOptions(conn: Connection): list<string>
	const [forwarding, _] = SplitForwardingSshOptions(conn.GetSshOptions())
	return forwarding
enddef

# `include_forwarding` should only be true for the one new ssh session meant
# to carry the user's tunnel/forward options (the interactive terminal, or
# the deploy-only persistent tunnel).
def GetSshArgs(conn: Connection, include_forwarding: bool = false): list<string>
	var args = ['ssh']
	args->extend(include_forwarding ? conn.GetSshOptions() : GetNonForwardingSshOptions(conn))
	args->extend(GetPortArgs(conn))
	return args
enddef

def GetScpArgs(conn: Connection): list<string>
	var args: list<string> = []
	args->extend(GetNonForwardingSshOptions(conn))
	args->extend(GetPortArgs(conn, true))
	return args
enddef

def GetSshCommandArgs(conn: Connection, head_args: list<string>, tail_args: list<string> = [], include_forwarding: bool = false): list<string>
	var args = GetSshArgs(conn, include_forwarding)
	args->extend(head_args)
	args->add(conn.host)
	args->extend(tail_args)
	return args
enddef

def GetSshCommandString(conn: Connection, head_args: list<string>, tail_args: list<string> = []): string
	return ShellJoin(GetSshCommandArgs(conn, head_args, tail_args))
enddef

def ParseTermOptions(opts: dict<any>): dict<any>
	var new_opts = {}
	for key in keys(opts)
		if key == 'rows' || key == 'cols'
			new_opts[$'term_{key}'] = str2nr(opts[key])
		elseif key == 'opencmd'
			new_opts['term_opencmd'] = opts[key]
		elseif key == 'eof'
			new_opts['eof_chars'] = opts[key]
		elseif key == 'kill' || key == 'api'
			new_opts[$'term_{key}'] = opts[key]
		elseif key == 'vertical' || key == 'curwin' || key == 'hidden' || key == 'norestore'
			new_opts[key] = true
		elseif key == 'close' || key == 'noclose' || key == 'open'
			new_opts['term_finish'] = key
		endif
	endfor

	return new_opts
enddef

def ParseConduitOpenArgs(args: string): dict<any>
	var tokens = split(args)
	if empty(tokens)
		throw error.Error.MissingHost.Format('missing host')
	endif

	var ssh_options: list<string> = []
	var term_options: dict<any> = {}
	var idx = 0
	# `+x` and `++name` select short- and long-form syntax respectively; the
	# resolved option determines whether it configures ssh or Vim's terminal.
	# SSH options therefore accept long aliases such as `++port` and `++proxyjump`.
	# A bare `++` or `--` (alone) ends option-parsing.
	while idx < len(tokens) && tokens[idx] =~# '^\(+\|--\)'
		var raw_token = tokens[idx]

		if raw_token =~# '^\(++\|--\)$' # ++/-- indicate end of options
			idx += 1
			break
		endif

		const is_long = raw_token =~# '^++'
		const prefix_len = is_long ? 2 : 1
		var token = raw_token[prefix_len : ]

		if empty(token)
			throw error.Error.InvalidConduitOption.Format("invalid conduit option")
		endif

		const eq_idx = stridx(token, '=')
		const has_eq = eq_idx >= 0
		const name = has_eq ? token[: eq_idx - 1] : token
		const inline_val = has_eq ? token[eq_idx + 1 :] : ''

		if empty(name) || (has_eq && empty(inline_val))
			throw error.Error.InvalidConduitOption.Format($'invalid conduit option "{raw_token}"')
		endif

		if !is_long && len(name) != 1
			throw error.Error.InvalidSshOption.Format(
				$'short option "+{name}" must be a single character; use "++{name}" for long-form options'
			)
		elseif is_long && len(name) == 1
			throw error.Error.InvalidConduitOption.Format(
				$'long-form option "++{name}" must not be a single character; use "+{name}" for short options'
			)
		endif

		const lookup = is_long ? opts_by_long : opts_by_short
		const spec: ConduitOption = get(lookup, name, null_object)
		if spec is null_object
			throw error.Error.InvalidConduitOption.Format($'option {raw_token} is unknown')
		endif

		if has_eq
			if !spec.takes_value
				throw error.Error.InvalidConduitOption.Format($'invalid conduit option "{raw_token}"')
			endif
			spec.Apply(ssh_options, term_options, inline_val)
			idx += 1
			continue
		endif

		if spec.takes_value
			if idx + 1 >= len(tokens)
				throw spec.MissingValueError().Format(
					$'option {raw_token} requires a value'
				)
			endif
			spec.Apply(ssh_options, term_options, tokens[idx + 1])
			idx += 2
			continue
		endif

		spec.Apply(ssh_options, term_options, '')
		idx += 1
	endwhile

	if idx >= len(tokens)
		throw error.Error.MissingHost.Format('missing host')
	endif

	var host = tokens[idx]
	var port = -1
	if host =~ ':'
		const host_parts = host->split(':')
		port = str2nr(host_parts[1])
		host = host_parts[0]
	endif

	if port == 0
		throw error.Error.InvalidPort.Format('invalid port')
	endif

	return {
		host: host,
		port: port,
		ssh_options: ssh_options,
		term_options: term_options,
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

def PathSep(): string
   return has('win32') ? '\' : '/'
enddef

def ExpandLocalGlob(pattern: string): list<string>
	if empty(pattern)
		return []
	endif

	return glob(pattern, false, true)
enddef

# Takes a list of ops, paths, and/or '--' and splits it, returning a list of
# ops and a list of paths separately.
def ParseOpsAndPaths(op_path: list<string>): tuple<list<string>, list<string>>
	var ops: list<string> = []
	var paths: list<string>

	const opind = index(op_path, '--') 
	if opind > 0
		ops = op_path[ : opind - 1]
		paths = op_path[opind + 1 : ]
	else
		# Loop through arguments, consuming ops until the first non-op argument
		var ind = 0
		for _op in op_path
			if index(all_ops, _op) >= 0 | ind += 1 | endif
		endfor

		if ind > 0 
			ops = op_path[ : ind - 1] 
		else
			throw error.Error.NoOpsSpecified.Format('no ops specified')
		endif 
		paths = op_path[ind : ]
	endif

	# Validate that all provided ops are supported
	for op in ops
		if index(all_ops, op) < 0
			throw error.Error.InvalidOp.Format($"invalid operation {op}")
		endif
	endfor

	return (ops, paths)
enddef

def OnLine(conn: Connection, line: string)
	var op_path = trim(line)->split(g:conduit_sep)
	if len(op_path) == 1
		const s = g:conduit_sep
		throw error.Error.InvalidOpPathFormat.Format(
			$"expected 'op1{s}op2{s}...{s}path1{s}path2{s}...' format, got {line}"
		)
	endif

	var [ops, paths] = ParseOpsAndPaths(op_path)
	if empty(paths) | return | endif

	if len(ops) == 1 && ops[0] == "get"
		if len(paths) == 1 || empty(paths[1])
			RsyncFile(conn, true, paths[0], getcwd())
		elseif len(paths) == 2
			const save_path = isabsolutepath(paths[1]) 
				? paths[1] 
				: getcwd() .. PathSep() .. paths[1]
			RsyncFile(conn, true, paths[0], save_path)
		else
			throw error.Error.InvalidNumberOfArguments.Format(
				$"'get' expects 1 or 2 arguments, got {len(paths)}"
			)
		endif
	elseif len(ops) == 1 && ops[0] == "put"
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
							RsyncFile(conn, false, selected, remote_file)
						},
						"Select Files to Upload"
					)
				else
					MultiChoicePrompt(
						matches,
						(selected) => {
							RsyncFile(conn, false, selected, remote_file)
						},
						"Select Files to Upload"
					)
				endif

				return
			endif
		endif

		if len(paths) == 1 || empty(paths[1])
			RsyncFile(conn, false, local_file, "")
		elseif len(paths) == 2
			RsyncFile(conn, false, local_file, paths[1])
		else
			throw error.Error.InvalidNumberOfArguments.Format(
				$"'put' expects 1 or 2 arguments, got {len(paths)}"
			)
		endif
	elseif len(ops) == 1 && ops[0] == "mget"
		const remote_files = filter(deepcopy(paths), (_, v) => !empty(v))
		if !empty(remote_files)
			RsyncFiles(conn, true, remote_files, getcwd())
		endif
	elseif len(ops) == 1 && ops[0] == "mput"
		if empty(paths)
			throw error.Error.InvalidNumberOfArguments.Format(
				$"'mput' expects at least 1 argument"
			)
		endif

		const remote_path = len(paths) > 1 ? paths[1] : ""
		const local_files = ExpandLocalGlob(paths[0])
		if empty(local_files)
			Warn($"Could not find file {paths[0]}")
			return
		endif

		RsyncFiles(conn, false, local_files, remote_path)
	elseif !empty(ops)
		var i = 0
		for path in paths
			OpenFile(conn, ops, path)
		endfor
	else
		throw error.Error.InvalidOp.Format($"invalid operation {ops}")
	endif
enddef

# ── Remote File Operations ───────────────────────────────────────────────────

# Builds the scp invocation netrw should use for `conn`'s control socket.
# Factored out of OpenFile() so ConduitRemoteReadCmd()/WriteCmd() can shell
# out through the same connection without going through netrw at all.
def GetNetrwScpCmd(conn: Connection): string
	const parts = [
		'scp',
		'-q',
		'-o', $'ControlPath={conn.GetConduitControlPath()}',
	]->extend(GetScpArgs(conn))
	return ShellJoin(parts)
enddef

def GetNetrwRsyncCmd(conn: Connection): string
	var rsh_args = GetSshArgs(conn, false)
	rsh_args->extend(['-S', conn.GetConduitControlPath()])
	const parts = ['rsync', '-az', '-q', '--rsh', ShellJoin(rsh_args)]
	return ShellJoin(parts)
enddef

# Builds the netrw-style `scp://host/path` URL used to name a buffer opened
# via `lvim`/OpenFile, so netrw's own scp handling can locate it.
def GetScpTarget(conn: Connection, remote_path: string): string
	const abs = remote_path =~# '^/' ? remote_path : '/' .. remote_path
	return 'scp://' .. conn.host .. '/' .. abs
enddef

# Builds the netrw-style `rsync://HOST/PATH` URL used to name a buffer opened
# via `lvim`/OpenFile, so netrw can locate and open it.
def GetRsyncTarget(conn: Connection, remote_path: string): string
	const abs = remote_path =~# '^/' ? remote_path : '/' .. remote_path
	return $'rsync://' .. conn.host .. '/' .. abs
enddef

# Restores g:netrw_scp_cmd to what it was (or unsets it) after OpenFile()
# temporarily points it at Conduit's control-socket-backed scp.
def RestoreNetrwScpCmd(existed: bool, before: string)
	if existed
		g:netrw_scp_cmd = before
	elseif exists('g:netrw_scp_cmd')
		unlet g:netrw_scp_cmd
	endif
enddef

# Restores g:netrw_rsync_cmd to what it was (or unsets it) after OpenFile()
# temporarily points it at Conduit's control-socket-backed rsync.
def RestoreNetrwRsyncCmd(existed: bool, before: string)
	if existed
		g:netrw_rsync_cmd = before
	elseif exists('g:netrw_rsync_cmd')
		unlet g:netrw_rsync_cmd
	endif
enddef

# Restores g:netrw_rsync_sep to what it was (or unsets it) after OpenFile()
# temporarily points it at Conduit's control-socket-backed rsync.
def RestoreNetrwRsyncSep(existed: bool, before: string)
	if existed
		g:netrw_rsync_sep = before
	elseif exists('g:netrw_rsync_sep')
		unlet g:netrw_rsync_sep
	endif
enddef

# Tags `bufnr` with the connection profile and remote path it is backed by,
# so ConduitRemoteReadCmd()/WriteCmd() and run's quickfix promotion can later
# resolve which connection and file the buffer belongs to.
def SetRemoteBufferMetadata(bufnr: number, conn: Connection, remote_path: string)
	setbufvar(bufnr, 'conduit_profile_key', conn.GetProfileKey())
	setbufvar(bufnr, 'conduit_remote_path', remote_path)
enddef

# Returns the (lazily created) buffer backing `remote_path` on `conn`, keyed
# by connection profile + path so the same remote file always reuses one
# buffer. Named as a content hash (rather than the scp:// URL OpenFile()
# uses) since these buffers are only ever reached by jumping from a run's
# quickfix entries, never opened directly by the user.
def RemoteBufferFor(conn: Connection, remote_path: string): number
	const path = simplify(remote_path)
	const registry_key = conn.GetProfileKey() .. "\x1f" .. path
	if remote_buffers->has_key(registry_key) && bufexists(remote_buffers[registry_key])
		return remote_buffers[registry_key]
	endif

	const name = 'conduit-file://' .. sha256(registry_key)
	const bufnr = bufadd(name)
	SetRemoteBufferMetadata(bufnr, conn, path)
	remote_buffers[registry_key] = bufnr
	return bufnr
enddef

# Resolves the current buffer's Conduit connection, for use inside the
# BufReadCmd/BufWriteCmd autocmds registered on conduit-file:// buffers.
def GetRemoteBufferConnection(): Connection
	const key = getbufvar(bufnr(), 'conduit_profile_key', '')
	if empty(key) || !connections->has_key(key)
		throw error.Error.Misc.Format('remote buffer has no Conduit connection')
	endif
	return connections[key]
enddef

# BufReadCmd for conduit-file:// buffers: scp's the remote path down to a
# temp file over the buffer's connection profile and loads it in place,
# preserving trailing-EOL state so ConduitRemoteWriteCmd() can round-trip it.
export def ConduitRemoteReadCmd()
	var local_file = ''
	try
		const conn = GetRemoteBufferConnection()
		if conn.ConduitClosed()
			throw error.Error.Misc.Format($'connection "{conn.GetProfileKey()}" is not active')
		endif

		const remote_path = getbufvar(bufnr(), 'conduit_remote_path', '')
		local_file = tempname()
		var scp_cmd = [
			'scp',
			'-q',
			'-o', $'ControlPath={conn.GetConduitControlPath()}',
		]
		scp_cmd->extend(GetScpArgs(conn))
		scp_cmd->extend([$'{conn.host}:{remote_path}', local_file])
		system(ShellJoin(scp_cmd))
		if v:shell_error != 0
			throw error.Error.Misc.Format($'scp exited with error {v:shell_error}')
		endif

		var lines = readfile(local_file, 'b')
		const has_final_eol = !empty(lines) && lines[-1] ==# ''
		if has_final_eol | lines->remove(-1) | endif
		setlocal modifiable
		if empty(lines)
			setline(1, '')
		else
			setline(1, lines)
		endif
		if line('$') > max([1, len(lines)])
			deletebufline(bufnr(), max([1, len(lines)]) + 1, '$')
		endif
		setlocal buftype=acwrite
		setlocal noswapfile
		if has_final_eol | setlocal endofline | else | setlocal noendofline | endif
		setlocal nomodified
		execute 'doautocmd <nomodeline> filetypedetect BufRead '
			.. fnameescape(remote_path)
		execute 'doautocmd <nomodeline> BufReadPost ' .. fnameescape(remote_path)
	catch
		Warn($'Failed to read remote file (error: {v:exception})')
	finally
		if !empty(local_file) | delete(local_file) | endif
	endtry
enddef

# BufWriteCmd for conduit-file:// buffers: writes the buffer to a temp file
# and scp's it back up over the buffer's connection profile, restoring the
# buffer's modified state on failure.
export def ConduitRemoteWriteCmd()
	const was_modified = &modified
	var local_file = ''
	try
		const conn = GetRemoteBufferConnection()
		if conn.ConduitClosed()
			throw error.Error.Misc.Format($'connection "{conn.GetProfileKey()}" is not active')
		endif

		const remote_path = getbufvar(bufnr(), 'conduit_remote_path', '')
		local_file = tempname()
		writefile(getline(1, '$'), local_file, &endofline ? '' : 'b')
		var scp_cmd = [
			'scp',
			'-q',
			'-o', $'ControlPath={conn.GetConduitControlPath()}',
		]
		scp_cmd->extend(GetScpArgs(conn))
		scp_cmd->extend([local_file, $'{conn.host}:{remote_path}'])
		system(ShellJoin(scp_cmd))
		if v:shell_error != 0
			throw error.Error.Misc.Format($'scp exited with error {v:shell_error}')
		endif
		setlocal nomodified
		execute 'doautocmd <nomodeline> BufWritePost ' .. fnameescape(remote_path)
	catch
		if was_modified | setlocal modified | endif
		Warn($'Failed to write remote file (error: {v:exception})')
	finally
		if !empty(local_file) | delete(local_file) | endif
	endtry
enddef

# Builds the netrw-style `scp://HOST/PATH` URL used to name a buffer opened
# via `lvim`/OpenFile, so netrw can locate and open it.
def GetScpTarget(conn: Connection, remote_path: string): string
	const abs = remote_path =~# '^/' ? remote_path : '/' .. remote_path
	return $'scp://' .. conn.host .. '/' .. abs
enddef

# Builds the netrw-style `rsync://HOST/PATH` URL used to name a buffer opened
# via `lvim`/OpenFile, so netrw can locate and open it.
def GetRsyncTarget(conn: Connection, remote_path: string): string
	const abs = remote_path =~# '^/' ? remote_path : '/' .. remote_path
	return $'rsync://' .. conn.host .. '/' .. abs
enddef

# Restores g:netrw_scp_cmd to what it was (or unsets it) after OpenFile()
# temporarily points it at Conduit's control-socket-backed scp.
def RestoreNetrwScpCmd(existed: bool, before: string)
	if existed
		g:netrw_scp_cmd = before
	elseif exists('g:netrw_scp_cmd')
		unlet g:netrw_scp_cmd
	endif
enddef

# Restores g:netrw_rsync_cmd to what it was (or unsets it) after OpenFile()
# temporarily points it at Conduit's control-socket-backed rsync.
def RestoreNetrwRsyncCmd(existed: bool, before: string)
	if existed
		g:netrw_rsync_cmd = before
	elseif exists('g:netrw_rsync_cmd')
		unlet g:netrw_rsync_cmd
	endif
enddef

# Restores g:netrw_rsync_sep to what it was (or unsets it) after OpenFile()
# temporarily points it at Conduit's control-socket-backed rsync.
def RestoreNetrwRsyncSep(existed: bool, before: string)
	if existed
		g:netrw_rsync_sep = before
	elseif exists('g:netrw_rsync_sep')
		unlet g:netrw_rsync_sep
	endif
enddef

# Tags `bufnr` with the connection profile and remote path it is backed by,
# so ConduitRemoteReadCmd()/WriteCmd() and run's quickfix promotion can later
# resolve which connection and file the buffer belongs to.
def SetRemoteBufferMetadata(bufnr: number, conn: Connection, remote_path: string)
	setbufvar(bufnr, 'conduit_profile_key', conn.GetProfileKey())
	setbufvar(bufnr, 'conduit_remote_path', remote_path)
enddef

# BufWriteCmd for conduit-file:// buffers: writes the buffer to a temp file
# and scp's it back up over the buffer's connection profile, restoring the
# buffer's modified state on failure.
export def ConduitRemoteWriteCmd()
	const was_modified = &modified
	var local_file = ''
	try
		const conn = GetRemoteBufferConnection()
		if conn.ConduitClosed()
			throw error.Error.Misc.Format($'connection "{conn.GetProfileKey()}" is not active')
		endif

		const remote_path = getbufvar(bufnr(), 'conduit_remote_path', '')
		local_file = tempname()
		writefile(getline(1, '$'), local_file, &endofline ? '' : 'b')
		var scp_cmd = [
			'scp',
			'-q',
			'-o', $'ControlPath={conn.GetConduitControlPath()}',
		]
		scp_cmd->extend(GetScpArgs(conn))
		scp_cmd->extend([local_file, $'{conn.host}:{remote_path}'])
		system(ShellJoin(scp_cmd))
		if v:shell_error != 0
			throw error.Error.Misc.Format($'scp exited with error {v:shell_error}')
		endif
		setlocal nomodified
		execute 'doautocmd <nomodeline> BufWritePost ' .. fnameescape(remote_path)
	catch
		if was_modified | setlocal modified | endif
		Warn($'Failed to write remote file (error: {v:exception})')
	finally
		if !empty(local_file) | delete(local_file) | endif
	endtry
enddef

def OpenFileScp(conn: Connection, op: string, abs: string, target: string)
	# Conduit owns the control socket path for each connection profile, so
	# netrw must always be pointed at the profile-specific socket.
	const scp_cmd = GetNetrwScpCmd(conn)
	
	const reset_netrw_scp_cmd = exists("g:netrw_scp_cmd")
	var netrw_scp_cmd_before = 'scp -q'
	if reset_netrw_scp_cmd
		# Store the old netrw scp command
		netrw_scp_cmd_before = g:netrw_scp_cmd
	endif

	g:netrw_scp_cmd = scp_cmd
	try
		execute op .. ' ' .. fnameescape(target)
	catch /E492/
		throw error.Error.InvalidOp.Format(
			$'could not run "execute {op} {fnameescape(target)}"'
		)
	finally
		RestoreNetrwScpCmd(reset_netrw_scp_cmd, netrw_scp_cmd_before)
	endtry

	const remote_bufnr = bufnr(target)
	if remote_bufnr > 0
		SetRemoteBufferMetadata(remote_bufnr, conn, abs)

		# Setup autocommands for hooking into and resetting netrw's scp
		# variables on write
		setbufvar(remote_bufnr, "scp_cmd", scp_cmd)
		setbufvar(remote_bufnr, "netrw_scp_cmd_before", netrw_scp_cmd_before)
		augroup ConduitUpdateNetrwControlPath
			autocmd BufWritePre <buffer> g:netrw_scp_cmd = b:scp_cmd
			autocmd BufWritePost <buffer> g:netrw_scp_cmd = b:netrw_scp_cmd_before
		augroup END
	endif
enddef

def OpenFileRsync(conn: Connection, op: string, abs: string, target: string)
	# Conduit owns the control socket path for each connection profile, so
	# netrw must always be pointed at the profile-specific socket.
	const rsync_cmd = GetNetrwRsyncCmd(conn)
	const rsync_sep = ':'

	# Store the old rsync command so that we can restore it later
	const reset_netrw_rsync_cmd = exists("g:netrw_rsync_cmd")
	var netrw_rsync_cmd_before = 'rsync -q'
	if reset_netrw_rsync_cmd
		# Store the old netrw rsync command
		netrw_rsync_cmd_before = g:netrw_rsync_cmd
	endif

	# Store the old rsync separator so that we can restore it later
	const reset_netrw_rsync_sep = exists("g:netrw_rsync_sep")
	var netrw_rsync_sep_before = '/'
	if reset_netrw_rsync_sep
		# Store the old netrw rsync sep
		netrw_rsync_sep_before = g:netrw_rsync_sep
	endif

	g:netrw_rsync_cmd = rsync_cmd
	g:netrw_rsync_sep = rsync_sep
	try
		execute op .. ' ' .. fnameescape(target)
	catch /E492/
		throw error.Error.InvalidOp.Format(
			$'could not run "execute {op} {fnameescape(target)}"'
		)
	finally
		RestoreNetrwRsyncCmd(reset_netrw_rsync_cmd, netrw_rsync_cmd_before)
		RestoreNetrwRsyncSep(reset_netrw_rsync_sep, netrw_rsync_sep_before)
	endtry

	const remote_bufnr = bufnr(target)
	if remote_bufnr > 0
		SetRemoteBufferMetadata(remote_bufnr, conn, abs)

		# Setup autocommands for hooking into and resetting netrw's rsync
		# variables on write
		setbufvar(remote_bufnr, "rsync_cmd", rsync_cmd)
		setbufvar(remote_bufnr, "netrw_rsync_cmd_before", netrw_rsync_cmd_before)
		setbufvar(remote_bufnr, "rsync_sep", rsync_sep)
		setbufvar(remote_bufnr, "netrw_rsync_sep_before", netrw_rsync_sep_before)
		augroup ConduitUpdateNetrwControlPath
			autocmd BufWritePre <buffer> g:netrw_rsync_cmd = b:rsync_cmd
			autocmd BufWritePost <buffer> g:netrw_rsync_cmd = b:netrw_rsync_cmd_before
			autocmd BufWritePre <buffer> g:netrw_rsync_sep = b:rsync_sep
			autocmd BufWritePost <buffer> g:netrw_rsync_sep = b:netrw_rsync_sep_before
		augroup END
	endif
enddef

def OpenFile(conn: Connection, oper: list<string>, remote_path: string)
	const op = oper->join(' ')
	const abs = remote_path =~# '^/' ? remote_path : '/' .. remote_path

	var target: string
	try
		if UseRsync()
			target = empty(conn.host) ? remote_path : GetRsyncTarget(conn, abs)
			OpenFileRsync(conn, op, abs, target)
		else
			target = empty(conn.host) ? remote_path : GetScpTarget(conn, abs)
			OpenFileScp(conn, op, abs, target)
		endif

		if g:conduit_verbose | echom $"Conduit(vim/{op}):" op target | endif
    catch
        Warn('Failed to open ' .. target .. ' (error: ' .. v:exception .. ')')
    endtry

enddef

# Computes the local pathname to show in a notification
def GetLocalPathForNotification(path: string, _basename: string): string
	const basename = isdirectory(path) ? $'/{_basename}' : ''

	if !get(g:, 'conduit_notifications_use_relative_local_paths', false)
		if isdirectory(path) 
			return (fnamemodify(path, ':p') .. basename[1 :])
		endif
		return fnamemodify(path, ':p')
	endif

	if path ==# getcwd() 
		return '.' .. basename
	endif
	return './' .. fnamemodify(path, ':.') .. basename
enddef

def StartTransferJob(conn: Connection, get: bool, op: string, scp_cmd: list<string>, notif_suffix: string, local_file: string, remote_file: string)

	if g:conduit_verbose && !empty(scp_cmd) | echom $"Conduit(sh/{op}):" scp_cmd->join(' ') | endif

	const display_op = $'[{op}]'
	const notif = notifier.StartProgress(
		notif_suffix,
		{prefix: display_op, subprefix: '[0.00 KB/s]'},
	)

	# Throttle time for updating progress bar
	const throttle = 1.250 # seconds
	var last_run = reltime()

	var scp_op: Op
	var scp_ops = get ? g:conduit_get_ops : g:conduit_put_ops

	var err_msgs: list<string> = []
	const j = job_start(
		scp_cmd, {
		out_io: "pipe",
		out_mode: "raw",
		err_cb: (_, msg) => {
			err_msgs->add(msg)
		},
		out_cb: (_, msg) => {
			# Throttle
			const seconds_since_last_run = reltime(last_run)->reltimefloat()
			if seconds_since_last_run < throttle | return | endif
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
				notifier.UpdateProgress(
					notif,
					percent,
					100, 
					notif_suffix,
					{subprefix: $'[{speed}]'},
				)
			endif
		},
		exit_cb: (_, code) => {
			if code == 0
				# Briefly show the full, final progress bar and success
				# message, then dismiss
				notifier.UpdateProgress(
					notif,
					100,
					100,
					$"‹✓› {notif_suffix}",
					{subprefix: '[success]'},
				)
				notifier.Dismiss(notif, GetSuccessTimeout())
			else
				notifier.Modify(
					notif,
					$"‹×› {err_msgs->join(' ‹|› ')}",
					{subprefix: $'[failed (error: {code})]'},
				)
				notifier.Dismiss(notif, GetFailureTimeout())
			endif

			# Remove the completed op from the list of stored operations
			const idx = scp_ops->index(scp_op)
			if idx != -1 | scp_ops->remove(idx) | endif
		}}
	)

	scp_op = Op.From(get ? OpType.Get : OpType.Put, conn, j, local_file, remote_file)
	if job_status(j) ==# 'run' | scp_ops->add(scp_op) | endif
enddef

def BuildGetCommand(
	conn: Connection, paths: list<string>, target_path: string,
): list<string>
	const host = conn.host
	var get_cmd: list<string> = []
	if UseRsync()
		var rsh_args = GetSshArgs(conn)
		rsh_args->extend(['-S', conn.GetConduitControlPath()])
		var rsh_cmd = ShellJoin(rsh_args)

		get_cmd = [
			"rsync",
			"-az",
			"--info=progress2",
			"--rsh",
			rsh_cmd,
		]
		for remote_path in paths
			get_cmd->add($"{host}:{remote_path}")
		endfor
		get_cmd->add(target_path)
	elseif executable('scp')
		get_cmd = [
			'scp',
			'-q',
			$'-o ControlPath={conn.GetConduitControlPath()}',
			'-r',
		]
		get_cmd->extend(GetScpArgs(conn))
		for remote_path in paths
			get_cmd->add($'{host}:{remote_path}')
		endfor
		get_cmd->add(target_path)
	else
		throw error.Error.RsyncScpUnavailable.Format(
			"rsync or scp not available"
		)
	endif
	return get_cmd
enddef

def BuildPutCommand(
	conn: Connection, paths: list<string>, target_path: string,
): list<string>
	const host = conn.host
	var put_cmd: list<string> = []
	if UseRsync()
		var rsh_args = GetSshArgs(conn)
		rsh_args->extend(['-S', conn.GetConduitControlPath()])
		var rsh_cmd = ShellJoin(rsh_args)

		put_cmd = [
			"rsync",
			"-az",
			"--info=progress2",
			"--inplace",
			"--rsh",
			rsh_cmd,
		]
		put_cmd->extend(paths)
		put_cmd->add($"{host}:{target_path}")
	elseif executable('scp')
		put_cmd = [
			'scp',
			'-q',
			$'-o ControlPath={conn.GetConduitControlPath()}',
			'-r',
		]
		put_cmd->extend(GetScpArgs(conn))
		put_cmd->extend(paths)
		put_cmd->add($'{host}:{target_path}')
	else
		throw error.Error.RsyncScpUnavailable.Format(
			"rsync or scp not available"
		)
	endif
	return put_cmd
enddef

def RsyncFile(conn: Connection, get: bool, path: string, target_path: string)
	RsyncFiles(conn, get, [path], target_path)
enddef

def Zip<T>(l1: list<T>, l2: list<T>): list<tuple<T, T>>
	if len(l1) != len(l2)
		throw 'error: l1 and l2 must have the same length'
	endif

	return mapnew(range(len(l1)), (_, i) => (l1[i], l2[i]))
enddef

def RsyncFiles(conn: Connection, get: bool, paths: list<string>, target_path: string)
	if empty(paths)
		return
	endif

	const host = conn.host
	const source_count = len(paths)
	const batch_label = source_count == 1 ? 'file' : 'files'

	var cmd: list<string>
	if get
		cmd = BuildGetCommand(conn, paths, target_path)
	else
		cmd = BuildPutCommand(conn, paths, target_path)
	endif

	var display_paths: list<string>
	if get
		display_paths = paths
	else
		for p in paths
			display_paths->add(GetLocalPathForNotification(p, ""))
		endfor
	endif

	var display_target_path: string
	if get
		const base_path = source_count == 1 ? fnamemodify(paths[0], ':t') : ""
		display_target_path = GetLocalPathForNotification(target_path, base_path)
	else
		display_target_path = target_path
	endif

	const notif_suffix = source_count == 1
		? get
			? $"{host}:{display_paths[0]} ‹→› {display_target_path}"
			: $"{display_paths[0]} ‹→› {host}:{display_target_path}"
		: get
			? $"{source_count} {batch_label} ‹→› {display_target_path}"
			: $"{source_count} {batch_label} ‹→› {host}:{display_target_path}"

	StartTransferJob(
		conn,
		get,
		get ? 'get' : 'put',
		cmd,
		notif_suffix,
		get ? target_path : paths->join(", "),
		get ? paths->join(", ") : target_path,
	)
enddef

def DeployRcfile(conn: Connection, OnSuccess: func(): void, OnErr: func(number): void): job
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
        '_is_conduit_op() {',
        '  case "$1" in',
		$'    {quoted_joined_file_ops}) return 0 ;;',
        '    *) return 1 ;;',
        '  esac',
        '}',
        'lvim() {',
        '  # Find -- if present',
        '  local dash_dash_idx=-1',
        '  for ((i=1; i<=$#; i++)); do',
        '    if [ ' .. '"${!i}"' .. ' = "--" ]; then',
        '      dash_dash_idx=$i',
        '      break',
        '    fi',
        '  done',
        '',
        '  # Consume operations from the start',
        '  local -a consumed_ops=()',
        '  if [ $dash_dash_idx -gt 0 ]; then',
        '    # Everything before -- are ops',
        '    for ((i=1; i<dash_dash_idx; i++)); do',
        '      consumed_ops+=(' .. '"${!i}"' .. ')',
        '    done',
        '    # Remove everything up to and including --',
        '    for ((i=0; i<dash_dash_idx; i++)); do',
        '      shift',
        '    done',
        '  else',
        '    # Consume ops until we hit the first non-op',
        '    while [ $# -gt 0 ]; do',
        '      if _is_conduit_op "$1"; then',
        '        consumed_ops+=("$1")',
        '        shift',
        '      else',
        '        break',
        '      fi',
        '    done',
        '  fi',
        '',
        '  if [ "$#" -eq 0 ]; then',
        $"    echo 'Usage: lvim [{quoted_joined_file_ops}] <file> [files...]' >&2",
        '    return 1',
        '  fi',
        '',
        '  # Build message: ops first, then op-specific path encoding',
        '  local msg=""',
        '  if [ ' .. '${#consumed_ops[@]}' .. ' -gt 0 ]; then',
        '    msg=' .. '"${consumed_ops[0]}"',
        '    for ((i=1; i<' .. '${#consumed_ops[@]}' .. '; i++)); do',
        '      msg="$msg' .. $'{g:conduit_sep}' .. '${consumed_ops[$i]}"',
        '    done',
        '  else',
        $'    msg="{g:conduit_default_split}"',
        '  fi',
        '',
        '  # Add -- separator if it was present in original args',
        '  if [ $dash_dash_idx -gt 0 ]; then',
        $'    msg="$msg{g:conduit_sep}--"',
        '  fi',
        '',
        '  case " ${consumed_ops[*]} " in',
        '    *" put "*)',
        '      if [ "$#" -ge 2 ]; then',
        $'        msg="$msg{g:conduit_sep}$1{g:conduit_sep}$(realpath "$2")"',
        '      else',
        $'        msg="$msg{g:conduit_sep}$1{g:conduit_sep}$(pwd)/"',
        '      fi',
        '      ;;',
        '    *" get "*)',
        '      if [ "$#" -ge 2 ]; then',
        $'        msg="$msg{g:conduit_sep}$(realpath "$1"){g:conduit_sep}$2"',
        '      else',
        $'        msg="$msg{g:conduit_sep}$(realpath "$1"){g:conduit_sep}"',
        '      fi',
        '      ;;',
        '    *" mget "*)',
        '      for arg in "$@"; do',
        $'        msg="$msg{g:conduit_sep}$(realpath "$arg")"',
        '      done',
        '      ;;',
        '    *" mput "*)',
        $'      msg="$msg{g:conduit_sep}$1{g:conduit_sep}$(pwd)"',
        '      ;;',
        '    *)',
        '      for arg in "$@"; do',
        $'        msg="$msg{g:conduit_sep}$(realpath "$arg")"',
        '      done',
        '      ;;',
        '  esac',
        '',
        '',
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
                        OnErr(status)
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
                        OnErr(status)
                        delete(local_rc)
                        return
                    endif

					const ExitCb = (_, chmod_status) => {
						if chmod_status == 0
							OnSuccess()
						else
							OnErr(status)
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
		notifier.Send($'‹×› {msg}')
	else
		echohl NotifyWarning
		echom msg
		echohl None
	endif
enddef

def EchoSuccess(msgs: list<string>)
	if empty(msgs) | return | endif

	echohl NotifySuccess
	for msg in msgs | echom msg | endfor
	echohl clear
enddef

def EchoError(msgs: list<string>)
	if empty(msgs) | return | endif

	echohl NotifyError
	for msg in msgs | echom msg | endfor
	echohl clear
enddef

# ── Remote Task Runner ───────────────────────────────────────────────────────

# Reads one whitespace-delimited token from `raw` starting at `start`,
# skipping leading whitespace and un-escaping `\<char>` so a run command can
# contain literal spaces (e.g. `++cwd`, then a path with a backslash-escaped
# space). Returns the token and the position just past it.
def NextRunToken(raw: string, start: number): tuple<string, number>
	var pos = start
	while pos < strlen(raw) && raw[pos] =~# '\s'
		pos += 1
	endwhile

	var token = ''
	while pos < strlen(raw) && raw[pos] !~# '\s'
		if raw[pos] ==# '\' && pos + 1 < strlen(raw)
			token ..= raw[pos + 1]
			pos += 2
		else
			token ..= raw[pos]
			pos += 1
		endif
	endwhile
	return (token, pos)
enddef

# Parses the argument string of `:Conduit[!] run` into
# {connection, command, cwd, loclist, errorformat}. With `bang`, `raw` is
# just a connection key (reruns reuse the previous command/cwd/efm verbatim
# and reject any trailing text); otherwise it is
# `[++cwd=...] [++loclist] [++errorformat=...] connection command...`.
export def ParseConduitRunArgs(raw: string, bang: bool): dict<any>
	var pos = 0
	var cwd = ''
	var loclist = false
	var errorformat = ''
	var token: string
	[token, pos] = NextRunToken(raw, pos)

	if bang
		if empty(token) || token =~# '^+'
			throw error.Error.InvalidConduitOption.Format(
				'Usage: Conduit! run [connection-key]',
			)
		endif
		var trailing: string
		[trailing, pos] = NextRunToken(raw, pos)
		if !empty(trailing)
			throw error.Error.InvalidConduitCommand.Format(
				'Conduit! run only accepts a connection key',
			)
		endif
		return {connection: token, command: '', cwd: '', loclist: false, errorformat: ''}
	endif

	while token =~# '^+'
		if token !~# '^++'
			throw error.Error.InvalidConduitOption.Format(
				$'option "{token}" is unknown',
			)
		endif

		const opt = token[2 :]
		const eq_idx = stridx(opt, '=')
		const has_eq = eq_idx >= 0
		const name = has_eq ? opt[: eq_idx - 1] : opt

		if name ==# 'cwd'
			var value: string
			if has_eq
				value = opt[eq_idx + 1 :]
			else
				[value, pos] = NextRunToken(raw, pos)
			endif
			if !empty(cwd) || empty(value)
				throw error.Error.InvalidConduitOption.Format(
					'++cwd requires one non-empty value',
				)
			endif
			cwd = value
		elseif name ==# 'loclist'
			if has_eq
				throw error.Error.InvalidConduitOption.Format(
					'++loclist does not take a value',
				)
			endif
			if loclist
				throw error.Error.InvalidConduitOption.Format(
					'++loclist may only be given once',
				)
			endif
			loclist = true
		elseif name ==# 'errorformat'
			var value: string
			if has_eq
				value = opt[eq_idx + 1 :]
			else
				[value, pos] = NextRunToken(raw, pos)
			endif
			if !empty(errorformat) || empty(value)
				throw error.Error.InvalidConduitOption.Format(
					'++errorformat requires one non-empty value',
				)
			endif
			errorformat = value
		else
			throw error.Error.InvalidConduitOption.Format(
				$'option "{token}" is unknown',
			)
		endif
		[token, pos] = NextRunToken(raw, pos)
	endwhile

	if empty(token)
		throw error.Error.MissingHost.Format('missing connection key')
	endif

	const command = trim(strpart(raw, pos))
	if empty(command)
		throw error.Error.InvalidExecuteCommand.Format('missing remote command')
	endif

	return {
		connection: token,
		command: command,
		cwd: cwd,
		loclist: loclist,
		errorformat: errorformat,
	}
enddef

# Default cwd for a run with no explicit ++cwd: the directory of the
# current buffer's remote file, if it's a conduit-file:// buffer on this
# same connection; otherwise empty (the remote shell's own default).
def CurrentRemoteCwd(conn: Connection): string
	const bufnr = bufnr()
	if getbufvar(bufnr, 'conduit_profile_key', '') !=# conn.GetProfileKey()
		return ''
	endif
	const remote_path = getbufvar(bufnr, 'conduit_remote_path', '')
	return empty(remote_path) ? '' : fnamemodify(remote_path, ':h')
enddef

def RunTaskTitle(conn_key: string, command: string): string
	return $'[Conduit run {conn_key}] {command}'
enddef

# Context stored on the run's quickfix/location list so tooling (and a
# human reading `:echo getqflist({context: 0})`) can identify which task,
# connection, command, and cwd an entry came from. `exit_code` defaults to
# a sentinel meaning "still running".
def RunTaskContext(task: RunTask, exit_code: number = -999): dict<any>
	return {
		conduit: 'run',
		task_id: task.id,
		connection: task.conn_key,
		command: task.command,
		cwd: empty(task.resolved_cwd) ? task.requested_cwd : task.resolved_cwd,
		exit_code: exit_code,
	}
enddef

# Remote buffers are named after a hash, so the quickfix window would show
# 78 characters of "conduit-file://<sha256>" where the path belongs. "module"
# overrides that column without disturbing the buffer the entry jumps to.
def RunDisplayPath(task: RunTask, remote_path: string): string
	const root = substitute(task.resolved_cwd, '/\+$', '', '')
	if empty(root) | return remote_path | endif
	const prefix = root .. '/'
	if stridx(remote_path, prefix) != 0 | return remote_path | endif
	const relative = strpart(remote_path, strlen(prefix))
	return empty(relative) ? remote_path : relative
enddef

# Rewrites quickfix entries whose errorformat-parsed "filename" names a
# plain file the run's own working directory (a local path, from the run's
# perspective on the remote host) rather than a real local buffer: points
# each such entry at a lazily-created remote-backed buffer instead, so
# jumping to it opens the actual remote file over Conduit's connection.
# Only rewrites entries this sink hasn't already normalized, tracked via
# task.sink.normalized, so a long-running task doesn't re-walk old entries.
def NormalizeRunQuickfix(task: RunTask)
	task.sink.Disarm()
	if empty(task.resolved_cwd) || !connections->has_key(task.conn_key)
		return
	endif

	const qf = task.sink.Read()
	if qf.nr == 0 | return | endif
	var items: list<dict<any>> = deepcopy(qf.items)
	var changed = false
	# Items below the sink's watermark were rewritten by an earlier pass, so a
	# run producing n lines walks each item once overall, not once per line.
	for i in range(task.sink.normalized, len(items) - 1)
		var item = items[i]
		const item_bufnr = get(item, 'bufnr', 0)
		if item_bufnr <= 0 | continue | endif
		const name = bufname(item_bufnr)
		if empty(name) || name =~# '^conduit-file://' || name =~# '^\a\+://'
			continue
		endif

		const remote_path = name =~# '^/'
			? simplify(name)
			: simplify(task.resolved_cwd .. '/' .. name)
		item.bufnr = RemoteBufferFor(connections[task.conn_key], remote_path)
		item.module = RunDisplayPath(task, remote_path)
		if item->has_key('filename') | item->remove('filename') | endif
		changed = true
	endfor
	task.sink.SetNormalized(len(items))

	if changed
		task.sink.Replace(items, qf.title, RunTaskContext(task))
	endif
enddef

# Arms the coalesced NormalizeRunQuickfix() pass for this task, once its
# resolved_cwd is known (nothing to normalize against before then).
def ScheduleNormalizeRunQuickfix(task: RunTask)
	if empty(task.resolved_cwd) | return | endif
	task.sink.Schedule(() => NormalizeRunQuickfix(task))
enddef

# After a run finishes, upgrades plain-text quickfix lines (output the
# errorformat didn't parse into a filename/position) that happen to name an
# existing remote file into valid, jumpable entries pointing at that file.
# Runs one batched remote `[ -f ... ]` check per up-to-200 candidates rather
# than one ssh round-trip per line.
def PromoteRunFileEntries(task: RunTask)
	if empty(task.resolved_cwd) || !connections->has_key(task.conn_key)
		return
	endif

	const qf = task.sink.Read()
	var items: list<dict<any>> = deepcopy(qf.items)
	if empty(items) | return | endif
	var item_paths: dict<string> = {}
	var checks: list<string> = []
	for i in range(len(items))
		const item = items[i]
		if get(item, 'valid', 0) || get(item, 'bufnr', 0) > 0
			continue
		endif

		const text = trim(get(item, 'text', ''))
		if empty(text) || strlen(text) > 4096 || text =~# '[\r\n]'
			continue
		endif
		const remote_path = text =~# '^/'
			? simplify(text)
			: simplify(task.resolved_cwd .. '/' .. text)
		item_paths[string(i)] = remote_path
		checks->add(
			$'[ -f {shellescape(remote_path)} ] && printf "%s\n" {shellescape(string(i))}',
		)
	endfor
	if empty(checks) | return | endif

	const conn = connections[task.conn_key]
	var existing: list<string> = []
	var batch_start = 0
	while batch_start < len(checks)
		const batch_end = min([batch_start + 199, len(checks) - 1])
		existing->extend(systemlist(GetSshCommandString(
			conn,
			['-S', conn.GetConduitControlPath()],
			[': CONDUIT_FILE_CHECK; ' .. checks[batch_start : batch_end]->join('; ')],
		)))
		batch_start = batch_end + 1
	endwhile
	var changed = false
	for index_text in existing
		const index = str2nr(index_text)
		const key = string(index)
		if !item_paths->has_key(key) || index < 0 || index >= len(items)
			continue
		endif
		items[index].bufnr = RemoteBufferFor(conn, item_paths[key])
		items[index].module = RunDisplayPath(task, item_paths[key])
		# Leave lnum/col at 0. The output named a file, not a position in it,
		# so a synthetic "|1 col 1|" would only add noise; Vim still jumps to
		# the file and leaves the cursor wherever it last was.
		items[index].valid = 1
		changed = true
	endfor

	if changed
		task.sink.Replace(items, qf.title, RunTaskContext(task))
	endif
enddef

# Appends one line of run output as a quickfix/location list entry.
def AppendRunOutput(task: RunTask, line: string)
	task.AddLine()
	task.sink.Append([line])
	ScheduleNormalizeRunQuickfix(task)
enddef

# Sentinel prefix StartRunTask() has the remote shell print, tagged with the
# task id so OnRunLine() can recognize its own marker line even if the
# command's own output happens to contain similar bytes.
def RunControlPrefix(task: RunTask): string
	return $"\x1eCONDUIT_CWD_{task.id}:"
enddef

# out_cb for a run's job: recognizes and strips the resolved-cwd marker line
# StartRunTask() has the remote shell emit before running the command
# (everything after it on that line is real output and still gets
# appended), and otherwise appends the line as ordinary output.
def OnRunLine(task: RunTask, line: string)
	const prefix = RunControlPrefix(task)
	const start = stridx(line, prefix)
	const finish = stridx(line, "\x1f")
	if start >= 0 && finish > start
		task.SetResolvedCwd(strpart(
			line,
			start + strlen(prefix),
			finish - start - strlen(prefix),
		))
		ScheduleNormalizeRunQuickfix(task)
		const remainder = strpart(line, finish + 1)
		if !empty(remainder) | AppendRunOutput(task, remainder) | endif
		return
	endif
	AppendRunOutput(task, line)
enddef

# Whether a finished run should auto-open its quickfix/location list,
# per g:conduit_run_auto_open_quickfix (default true).
def RunAutoOpenQuickfix(): bool
	const value = get(g:, 'conduit_run_auto_open_quickfix', true)
	if type(value) != v:t_bool
		Warn('g:conduit_run_auto_open_quickfix must be a boolean; using true')
		return true
	endif
	return value
enddef

# exit_cb for a run's job: records it for `Conduit! run`, does the final
# (synchronous) file-entry promotion and quickfix normalization passes, then
# reports the outcome via notification and folds it into the list's title.
def FinishRunTask(task: RunTask, code: number)
	const idx = run_tasks->index(task)
	if idx >= 0 | run_tasks->remove(idx) | endif

	# Drop any coalesced pass; the flush below covers the remaining items and
	# PromoteRunFileEntries() blocks on SSH, which would let a timer fire
	# midway through its rewrite.
	task.sink.Disarm()
	last_runs[task.conn_key] = RunSpec.new(
		task.command,
		empty(task.resolved_cwd) ? task.requested_cwd : task.resolved_cwd,
		task.efm,
		task.sink.use_loclist,
	)
	PromoteRunFileEntries(task)
	NormalizeRunQuickfix(task)
	const qf = task.sink.Read()
	const entry_count = len(qf.items)
	const valid_count = qf.items
		->copy()
		->filter((_, item) => get(item, 'valid', 0))
		->len()
	const can_open = RunAutoOpenQuickfix() && task.sink.IsCurrent()
	if can_open
		task.sink.Open()
	endif

	var state: string
	var outcome: string
	var timeout: number
	if task.cancelled || code == -1
		state = 'stopped'
		outcome = 'stopped'
		timeout = GetFailureTimeout()
	elseif code == 0
		state = 'finished'
		outcome = 'finished'
		timeout = GetSuccessTimeout()
	else
		state = $'failed (error: {code})'
		outcome = $'exit {code}'
		timeout = GetFailureTimeout()
	endif

	var entry_label = entry_count == 1 ? 'entry' : 'entries'
	const list_label = task.sink.use_loclist ? 'location' : 'quickfix'
	var msg: string
	if !task.sink.IsAlive()
		# The window that owned the location list was closed mid-run, taking
		# the list with it. Say so rather than reporting zero entries.
		msg = $'{task.command}: {state}; location list window closed'
	else
		msg = $'{task.command}: {state}; {entry_count} {list_label} {entry_label}'
		if valid_count != entry_count
			msg ..= $' ({valid_count} jumpable)'
		endif
		if task.line_count > 0 && !can_open
			msg ..= $' in list #{qf.nr} ({task.sink.OpenCommand()})'
		endif
	endif
	notifier.StopLoading(
		task.notif,
		(task.cancelled || code != 0 ? '‹×› ' : '‹✓› ') .. msg,
		false,
		timeout,
	)

	# Fold the outcome into the title so it survives in the list's
	# statusline once the notification has timed out.
	var title = RunTaskTitle(task.conn_key, task.command)
		.. $' ({outcome}, {entry_count} {entry_label}'
	if valid_count != entry_count
		title ..= $', {valid_count} jumpable'
	endif
	title ..= ')'
	task.sink.Finish(title, RunTaskContext(task, code))
	redraw
enddef

# Builds the `cd` remote-shell fragment for a run's requested cwd: bare `cd`
# (to $HOME) for empty/`~`, an explicit `$HOME/...` expansion for `~/...`
# (the remote shell may not be interactive enough to expand `~` itself),
# and a plain quoted `cd --` otherwise.
def RemoteCdCommand(cwd: string): string
	if empty(cwd) || cwd ==# '~'
		return 'cd'
	elseif stridx(cwd, '~/') == 0
		return 'cd -- "$HOME"/' .. shellescape(cwd[2 : ])
	endif
	return 'cd -- ' .. shellescape(cwd)
enddef

# Resolve the window a location-list run attaches to, at the moment the task
# starts. Reruns therefore follow the window you are standing in rather than
# the one the original run used, which may since have closed.
def ResolveRunTarget(spec: RunSpec): RunListSink
	if !spec.use_loclist | return RunListSink.new(spec.efm) | endif

	const winid = win_getid()
	const info = getwininfo(winid)
	if !empty(info) && (info[0].terminal || info[0].quickfix)
		Warn('++loclist needs a normal window; using the quickfix list')
		return RunListSink.new(spec.efm)
	endif
	return RunListSink.new(spec.efm, true, winid)
enddef

# Starts a run of `spec` over `conn`: creates its list sink and RunTask,
# then launches the remote command via ssh. The remote shell is asked to
# `cd` to the requested directory, print a resolved-cwd marker (see
# RunControlPrefix()) so the task learns its actual cwd even when none was
# requested, and only then run the command, so output and cwd resolution
# arrive over the same job/pipe in a well-defined order.
def StartRunTask(conn: Connection, spec: RunSpec)
	const id = next_run_id
	next_run_id += 1
	const sink = ResolveRunTarget(spec)
	sink.Create(RunTaskTitle(conn.GetProfileKey(), spec.command), {
		conduit: 'run',
		task_id: id,
		connection: conn.GetProfileKey(),
		command: spec.command,
		cwd: spec.cwd,
	})
	const notif = notifier.StartLoading(
		spec.command,
		{prefix: '[run]', subprefix: $'[{conn.GetProfileKey()}]'},
	)
	const task = RunTask.new(
		id,
		conn.GetProfileKey(),
		spec.command,
		spec.cwd,
		spec.efm,
		sink,
		notif,
	)

	const printf_cmd = "printf '\\036CONDUIT_CWD_" .. id
		.. ":%s\\037\\n' \"$PWD\""
	const remote_cmd = RemoteCdCommand(spec.cwd)
		.. ' && ' .. printf_cmd
		.. ' && { ' .. spec.command .. '; }'
	if g:conduit_verbose | echom 'Conduit(sh/run):' remote_cmd | endif

	task.SetJob(job_start(
		GetSshCommandArgs(
			conn,
			['-S', conn.GetConduitControlPath()],
			[remote_cmd],
		),
		{
			out_io: 'pipe',
			out_mode: 'nl',
			err_io: 'out',
			out_cb: (_, line: string) => OnRunLine(task, line),
			exit_cb: (_, code) => FinishRunTask(task, code),
		},
	))
	if job_status(task.job) ==# 'fail'
		notifier.StopLoading(
			notif,
			$'‹×› Could not start remote task on {conn.GetProfileKey()}',
			false,
			GetFailureTimeout(),
		)
		task.sink.SetContext(RunTaskContext(task, -2))
	else
		run_tasks->add(task)
	endif
enddef

# `EFM` is resolved in three steps: a user alias in g:conduit_errorformat, a
# compiler plugin of that name (whose errorformat is grabbed without leaking
# its buffer-local state past this call), or otherwise EFM itself, taken as a
# literal 'errorformat' string.
def ResolveRunErrorFormat(EFM: string): string
	if g:conduit_errorformat->has_key(EFM)
		return g:conduit_errorformat[EFM]
	endif

	if empty(globpath(&runtimepath, 'compiler/' .. EFM .. '.vim'))
		return EFM
	endif

	const original_compiler = get(b:, 'current_compiler', '')
	const original_efm = &l:errorformat
	execute 'compiler ' .. EFM
	const efm = &l:errorformat

	if empty(original_compiler)
		unlet! b:current_compiler
	else
		b:current_compiler = original_compiler
	endif
	&l:errorformat = original_efm

	return efm
enddef

# Entry point for `:Conduit[!] run`: parses `raw`, resolves the target
# connection, and either replays the last run for that connection (bang,
# refusing if a matching task is already in flight) or starts a fresh one.
export def ConduitRunCmd(bang: bool, raw: string)
	var parsed: dict<any>
	try
		parsed = ParseConduitRunArgs(raw, bang)
	catch
		Warn(v:exception)
		return
	endtry

	const key = ResolveConnectionKey(parsed.connection)
	if empty(key)
		Warn($'No active connection "{parsed.connection}"')
		return
	endif
	const conn = connections[key]
	if conn.ConduitClosed()
		Warn($'Connection "{key}" is not active')
		return
	endif

	if bang
		if !last_runs->has_key(key)
			Warn($'No previous run for "{key}"')
			return
		endif
		const previous = last_runs[key]
		for task in run_tasks
			if task.conn_key ==# key
					&& task.command ==# previous.command
					&& (task.resolved_cwd ==# previous.cwd
						|| task.requested_cwd ==# previous.cwd)
				Warn($'That task is already running on "{key}"')
				return
			endif
		endfor
		StartRunTask(conn, RunSpec.new(
			previous.command,
			previous.cwd,
			previous.efm,
			previous.use_loclist,
		))
		return
	endif

	const cwd = empty(parsed.cwd) ? CurrentRemoteCwd(conn) : parsed.cwd
	const efm = empty(parsed.errorformat)
		? &errorformat
		: ResolveRunErrorFormat(parsed.errorformat)
	StartRunTask(conn, RunSpec.new(
		parsed.command,
		cwd,
		efm,
		parsed.loclist,
	))
enddef

# ── Command Implementation ───────────────────────────────────────────────────

def OpenConduitControlMaster(conn: Connection, Callback: func(number, string): void)
	const control_path = conn.GetConduitControlPath()

	if getftype(control_path) ==# "socket"
		system(GetSshCommandString(conn, ['-O', 'check', '-S', control_path]))

		if v:shell_error == 0
			Callback(0, '')
			return
		endif
		system(GetSshCommandString(conn, ['-O', 'exit', '-S', control_path]))

		if conn.IsManuallyControlledMultiplexing() && getftype(control_path) ==# "socket"
			delete(control_path)
		endif
	endif

	var term_bufnr = -1
	var shown = false
	var err_msgs: list<string>
	term_bufnr = term_start(GetSshCommandArgs(
		conn,
		[
			'-fN',
			'-M',
			'-o', $'ControlPersist={conn.GetConduitControlPersist()}',
			'-o', $'ConnectTimeout={conn.GetConnectTimeout()}',
			'-o', $'ConnectionAttempts={conn.GetConnectionAttempts()}',
			'-o', 'BatchMode=no',
			'-S', control_path,
		]
	), {
		term_finish: 'open',
		term_name: $'ConduitAuthentication[{conn.host}]',
		hidden: true,
		out_cb: (_, msg: string) => {
			if !shown && bufexists(term_bufnr)
				shown = true
				execute 'sbuffer ' .. term_bufnr
			endif
		},
		err_cb: (_, msg: string) => {
			err_msgs->add(msg->trim())
		},
		exit_cb: (_, code) => {
			var msg: string
			if code == -1
				msg = 'Authentication cancelled'
			elseif code == 0
				msg = 'Authentication successful'
				EchoSuccess(err_msgs)
			else
				msg = $'Authentication failed (error: {code}): {err_msgs->join(' ‹|› ')}'
				EchoError(err_msgs)
			endif
			Callback(code, msg)

            if bufexists(term_bufnr)
                execute $'bwipeout! {term_bufnr}'
            endif
		},
	})
enddef

export def ConduitOpenCmd(deploy_only: bool, curwin: bool, mods: string, args: string)
	var win_to_use = win_getid()
	const prefix = deploy_only ? "ConduitDeploy" : "ConduitOpen"

	var notif = notifier.StartLoading($"Connecting")
    # redraw!

    if empty(args)
        Warn($'Usage:  {prefix} [+SHORTOPT|++LONGOPT ...] [user@]host[:port]')
		notifier.Dismiss(notif)
        return
    endif

	var parsed: dict<any>
	try
		parsed = ParseConduitOpenArgs(args)
	catch
		Warn(v:exception)
		notifier.Dismiss(notif)
		return
	endtry

	var host = parsed.host
	var port = parsed.port
	var ssh_options = parsed.ssh_options
	var term_options = ParseTermOptions(parsed.term_options)

	var conn: Connection
	try
		conn = MaybeAddEmptyConnection(host, port, ssh_options)
	catch /E1013/
        Warn($'Usage:  {prefix} [+SHORTOPT|++LONGOPT ...] [user@]host[:port]')
		notifier.Dismiss(notif)
		return
	endtry

	if !conn.ShellAvailable()
		notifier.Dismiss(notif)
		notifier.Dismiss(
			notifier.Send(
				$"Conduit does not support '{conn.ConduitShell()}'",
				{prefix: "‹×› Unsupported shell"}
			),
			GetFailureTimeout(),
		)
		return
	endif


	var OpenSession = () => {
		OpenConduitControlMaster(conn, (open_control_master_err_code, ssh_error) => {
			if open_control_master_err_code != 0
				const msg = empty(ssh_error)
					? $"ssh exited with error {open_control_master_err_code}"
					: ssh_error->split("\n")->join(" ‹|› ")

				notifier.Dismiss(notif)
				notifier.Dismiss(
					notifier.Send(
						msg,
						{prefix: "‹×› Failed to start ssh", subprefix: $"(error: {open_control_master_err_code})"},
					), 
					GetFailureTimeout(),
				)

				redraw
				return
			endif

			# Restart notification to update the animation timer's string
			notifier.UpdateLoading(notif, $"Starting listener")
			redraw

			if !EnsureListener(conn)
				notifier.StopLoading(
					notif,
					$"‹×› Could not start listener",
					false,
					GetFailureTimeout(),
				)
				return 
			endif

			var remote_sock = conn.GetRemoteReverseTunnelSocketPath()
			var remote_rc   = conn.GetRemoteRCPath()
			var sock_path = conn.GetLocalReverseTunnelSocketPath()

			const shell_startup_cmd = conn.ConduitShellStartupCmd(remote_rc)
			if empty(shell_startup_cmd) 
				notifier.Dismiss(notif)
				notifier.Dismiss(
					notifier.Send(
						$"Conduit does not support '{conn.ConduitShell()}'",
						{prefix: "‹×› Unsupported shell"}
					),
					GetFailureTimeout(),
				)
				return
			endif

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
							],
							[],
							true,
						)

						job_start(
							ssh_cmd, {
							exit_cb: (___, code) => {
								if code == 0
									notifier.StopLoading(
										notif,
										$"‹✓› Success",
										false,
										GetSuccessTimeout()
									)
									ConduitCopySourceCmd(GetConnectionsDictKey(conn))
								else
									notifier.StopLoading(
										notif,
										$"‹×› Failed (error: {code})",
										false,
										GetFailureTimeout(),
									)
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
						shell_startup_cmd,
						true,
					)

					var term_name = 'conduit://' .. conn.GetProfileKey()
					const nterms = conn.ConnectedTerms()
					if nterms > 0 
						term_name ..= $"[{nterms}]" 
					endif

					const hidden = term_options->get('hidden', false)
					if !hidden
						var spawn_cmd: string
						if !curwin 
							if !term_options->get('curwin', false)
								spawn_cmd = (mods =~ 'tab') ? 'tabnew' : 'split'
							endif
							execute mods .. ' ' .. spawn_cmd .. ' | enew'
							win_to_use = win_getid()
						endif
					endif

					const currwin = win_getid()
					if win_gotoid(win_to_use)
						const term_bufnr = term_start(
							ssh_cmd,
							term_options->extend({ term_name: term_name, curwin: !hidden })
						)

						win_gotoid(currwin)
						conn.AddTermByBufNr(term_bufnr)
					else
						throw error.Error.CouldNotOpenTerm.Format(
							$'could not open terminal in window {win_to_use}'
						)
					endif

					# User a timer for the success message since the ssh
					# connection is already authenticated, and the previous
					# message will only be shown briefly otherwise
					timer_start(500, (_) => { 
						notifier.StopLoading(
							notif, $"‹✓› Success", false, GetSuccessTimeout(),
						)
					})
					redraw
				},
				(code) => {
					notifier.StopLoading(
						notif, $"‹×› Failed (error: {code})", false, GetFailureTimeout(),
					)
					MaybeCleanup(conn)
					redraw
				},
			)
		})
	}

	if conn.GetSockReady() && conn.ConduitOpen() && conn.ConnectedTerms() == 0
		# Restart notification for cleanup step
		notifier.UpdateLoading(notif, $"Cleaning up stale files on remote")
		redraw
		MaybeCleanup(conn, false, false, (success) => {
			if success
				OpenSession()
				redraw
			else
				notifier.StopLoading(
					notif,
					$"‹×› Could not clean up stale files on remote, exiting.",
					false,
					GetFailureTimeout(),
				)
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

			ConduitStopCmd('run', [key, '*'])

			# Stop the running terminal job
			for bufnr in keys(conn.term_bufnr)
				const term_job = term_getjob(conn.term_bufnr[bufnr])
				if job_status(term_job) == 'run'
					job_stop(term_job)
				endif
			endfor

			# Perform cleanup
			const success = MaybeCleanup(conn, false, true)

			# Do not forcibly exit a shared control master here. Multiple Vim
			# instances can reuse the same ControlMaster, so closing it from one
			# session would break the others. Let ControlPersist or an explicit
			# SSH shutdown handle the master lifetime.
			if success
				notifier.StopLoading(
					notif, $"‹✓› Exited from {host}", false, GetSuccessTimeout(),
				)
			else
				notifier.StopLoading(
					notif, $"‹×› Could not exit from {host}", false, GetFailureTimeout(),
				)
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

	if type ==# 'run' || type ==# '*'
		var i = len(run_tasks) - 1
		while i >= 0
			const task = run_tasks[i]
			if task.conn_key ==# key
				const search_over = [task.command, task.resolved_cwd]
				if iden ==# '*' || !empty(matchfuzzy(search_over, iden))
					task.Cancel()
					if job_status(task.job) ==# 'run' | job_stop(task.job) | endif
				endif
			endif
			i -= 1
		endwhile
		if type ==# 'run' | return | endif
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
		ConduitStopCmd('run', [key, '*'])
		connections[key].Disconnect()
		notifier.StopLoading(
			notif, $"‹✓› Disconnected from {host}", false, GetSuccessTimeout(),
		)
		notifier.Dismiss(notif, GetSuccessTimeout())
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

export def ConduitSocketCmd(host: string)
	const key = ResolveConnectionKey(host)
	if empty(key)
		Warn($'No host "{host}"')
		return
	endif

	const conn = connections[key]
	if get(g:, 'conduit_echo_socket', false)
		echom $'[socket] {key} → {conn.GetConduitControlPath()}'
	else
		notifier.Send($'{key} ‹→› {conn.GetConduitControlPath()}', {prefix: '[socket]'})
	endif
enddef

export def ConduitNotificationCmd(cmd: string)
	if cmd ==# "history"
		notifier.ShowHistory()
	elseif cmd ==# "dismiss"
		notifier.DismissAll()
	endif
enddef

# ── Vim Command Interface ────────────────────────────────────────────────────

# Entry point for the `:Conduit` command. `run` gets its own arg-parsing
# (it accepts a free-form remote command, which doesn't fit the space-split
# args every other subcommand uses) and is dispatched here before falling
# through to ConduitCmdList() for everything else.
export def ConduitDispatch(
	deploy_only: bool,
	bang: bool,
	mods: string,
	raw_args: string,
	args: list<string>,
)
	if !empty(args) && args[0] ==# 'run'
		const run_args = substitute(
			raw_args,
			'^\s*run\%(\s\+\|$\)',
			'',
			'',
		)
		ConduitRunCmd(bang, run_args)
		return
	endif
	ConduitCmdList(deploy_only, bang, mods, args)
enddef

export def ConduitCmd(deploy_only: bool, bang: bool, mods: string, ...args: list<string>)
	ConduitCmdList(deploy_only, bang, mods, args)
enddef

def ConduitCmdList(deploy_only: bool, bang: bool, mods: string, args: list<string>)
	if empty(args) | return | endif

	const curwin = bang || index(args, '++curwin') > 0

	const cmd = args[0]
	var cmd_args = ""
	if len(args) > 1
		cmd_args = args[1 :]->join(" ")
	endif

	if cmd ==# "open" # :Conduit open HOST
		if len(args) < 2
			echoerr "Usage:  Conduit open [+SHORTOPT|++LONGOPT ...] [user@]host[:port]"
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
			echoerr "Usage:  Conduit deploy [+SHORTOPT|++LONGOPT ...] [user@]host[:port]"
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
		ConduitNotificationCmd(args[1])

	elseif cmd ==# "socket" # :Conduit socket HOST
		if len(args) != 2
			echoerr "Usage:  Conduit socket [connection-key]"
		else
			ConduitSocketCmd(args[1])
		endif

	elseif cmd ==# "stop" # :Conduit stop OP HOST PATTERN
		if len(args) != 4
			echoerr "Usage:  Conduit stop op [connection-key] pattern"
		else
			ConduitStopCmd(args[1], args[2 :])
		endif
	else
		echoerr error.Error.InvalidConduitCommand.Format(
			"invalid conduit command"
		)
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
	if empty(pattern) | return options | endif
    return matchfuzzy(options, pattern)
enddef

export def ConduitNotificationComplHelper(current_cmd: string, pattern: string): list<string>
    var options = ['history', 'dismiss']
	if empty(pattern) | return options | endif
    return matchfuzzy(options, pattern)
enddef

export def ConduitHostCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    var current_cmd = GetCurrentCmd(CmdLine, CursorPos)
	return ConduitHostComplHelper(current_cmd, ArgLead)
enddef

export def ConduitActiveComplHelper(current_cmd: string, pattern: string): list<string>
    var options = keys(connections)
	if empty(pattern) | return options | endif
    return matchfuzzy(options, pattern)
enddef

export def ConduitActiveCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    var current_cmd = GetCurrentCmd(CmdLine, CursorPos)
	return ConduitActiveComplHelper(current_cmd, ArgLead)
enddef

def MaybeRemoveOptions(CmdLine: string, suggestions: list<string>): list<string>
	const no_opts = CmdLine =~# '\s\(++\|--\)\s'
	if no_opts
		return filter(copy(suggestions), (_, v) => v !~ '^+')
	endif
	return suggestions
enddef

export def ConduitOptsCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
	const completed_last = CmdLine =~# '\s$'
	var specified_opts = CmdLine
		->split()[: completed_last ? -1 : -2]  # Don't filter currently typed option
		->filter((_, v) => v =~# '^+' && !empty(v))
		->map((_, v) => substitute(substitute(v, '^++\?', '', 'g'), '=.*$', '', 'g'))

	var options = deepcopy(all_option_specs)->filter(
		(_, v) => index(specified_opts, v.ShortName()) < 0 && index(specified_opts, v.long) < 0
	)

	var short_opts = copy(options)
		->filter((_, spec) => spec.takes_value)
		->map((_, spec) => spec.ShortName() .. '=')
	var long_opts = options
		->mapnew((_, spec) => spec.long .. (spec.takes_value ? '=' : ''))

	var suggestions: list<string>
	if empty(ArgLead)
		suggestions = ['+', '++']
	elseif ArgLead =~# '^++[a-zA-Z0-9=]\+'
		suggestions = mapnew(matchfuzzy(long_opts, ArgLead[2 : ]), (_, v) => '++' .. v)
	elseif ArgLead =~# '^+[a-zA-Z=]\+'
		suggestions = mapnew(matchfuzzy(short_opts, ArgLead[1 : ]), (_, v) => '+' .. v)
			->extend(mapnew(matchfuzzy(long_opts, ArgLead[1 : ]), (_, v) => '++' .. v))
	elseif ArgLead =~# '^+$'
		suggestions = ['+', '++']
			+ mapnew(short_opts, (_, v) => '+' .. v)
			+ mapnew(long_opts, (_, v) => '++' .. v)
	elseif ArgLead =~# '^++$'
		suggestions = ['++']
			+ mapnew(long_opts, (_, v) => '++' .. v)
	endif

	return MaybeRemoveOptions(CmdLine, suggestions)
enddef

export def ConduitHostAndOptionCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    var current_cmd = GetCurrentCmd(CmdLine, CursorPos)
	return ConduitOptsCompl(ArgLead, CmdLine, CursorPos) + ConduitHostCompl(ArgLead, CmdLine, CursorPos)
enddef

export def ConduitCompl(ArgLead: string, CmdLine: string, CursorPos: number): list<string>
    const current_cmd = GetCurrentCmd(CmdLine, CursorPos)
    var parts = split(current_cmd)

	# Extract the Conduit command
	var cmd: string = ""
	if len(parts) > 1
		if index(modifiers, parts[0]) >= 0
			# Remove initial modifier from the Conduit command
			parts = parts[1 : ]
		endif
		cmd = parts[1]
	endif

    # Completing the sub-command (e.g., "Conduit op")
	const mods = '\(' .. modifiers->join('\|') .. '\)\? \?'
    if current_cmd =~ $'^{mods}Conduit!\? \+\S*$'
        var options = ["open", "run", "exit", "deploy", "disconnect", "source", "notifications", "stop", "socket"]
		if empty(ArgLead) | return options | endif
        return matchfuzzy(options, ArgLead)

    elseif cmd ==# "open"
		return ConduitHostAndOptionCompl(ArgLead, CmdLine, CursorPos)
    elseif  cmd ==# "deploy"
		return ConduitHostComplHelper(current_cmd, ArgLead)
    elseif  cmd ==# "notifications"
		return ConduitNotificationComplHelper(current_cmd, ArgLead)
	elseif cmd ==# 'run'
		var run_parts = len(parts) > 2 ? parts[2 : ] : []
		const ends_in_space = current_cmd =~# '\s$'
		var completed = copy(run_parts)
		if !ends_in_space && !empty(completed)
			completed->remove(-1)
		endif
		for value in completed
			if value !~# '^+' | return [] | endif
		endfor

		var opts = ['cwd', 'loclist', 'errorformat']
		var specified = CmdLine
			->split()
			->filter((_, v) => v =~# '^+' && !empty(v))
			->map((_, v) => substitute(substitute(v, '^++\?', '', 'g'), '=.*$', '', 'g'))

		# Only grab non-specified suggestions, and format as `++OPT=`
		opts = opts
			->filter((_, v) => index(specified, v) < 0)
			->map((_, v) => index(['cwd', 'errorformat'], v) >= 0 ? $'++{v}=' : '++' .. v)

		var suggestions = opts + keys(connections)

		if empty(ArgLead) | return suggestions | endif
		return matchfuzzy(suggestions, ArgLead)

    # Completing the second argument for the other sub-commands.
	elseif current_cmd =~ $'^{mods}Conduit!\? \+\S\+ \+\S*$'
        if len(parts) >= 2
			if cmd ==# "stop"
				return ["get", "put", "run", "*"]
            else
				const prefix = "Conduit" .. ToTitleCase(cmd)
				const host = len(parts) >= 3 ? parts[2] : "" # Fixed index: parts[2] is the host
				return ConduitActiveComplHelper(prefix .. ' ' .. host, ArgLead)
            endif
        endif

	# Completing the third argument (e.g., "Conduit stop put myho")
    elseif current_cmd =~ $'^{mods}Conduit!\? \+\S\+ \+\S\+ \+\S*$' 
		if cmd ==# "stop" # `Conduit stop put host`
			const prefix = "Conduit" .. ToTitleCase(cmd)
			const host = len(parts) >= 4 ? parts[3] : ""
			return ConduitActiveComplHelper(prefix .. ' ' .. host, ArgLead)
		endif

	# Completing the fourth argument (e.g., "Conduit stop get myhost iden")
    elseif current_cmd =~ $'^{mods}Conduit!\? \+\S\+ \+\S\+ \+\S\+ \+\S*$' 
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

			if op_type ==# 'run'
				for task in run_tasks
					if task.conn_key !=# host | continue | endif
					files->add(task.command)
					if !empty(task.resolved_cwd) | files->add(task.resolved_cwd) | endif
				endfor
				if !empty(files) | files->add('*') | endif
				return empty(ArgLead) ? files : matchfuzzy(files, ArgLead)
			endif

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
		throw error.Error.Misc.Format(
			'must specify connection when `all` is false'
		)
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
			c.SetSockNotReady()
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
