vim9script

# ── Global Configuration & Defaults ──────────────────────────────────────────
 
var border_chars: list<string> = has('multi_byte')
    ? ['─', '│', '─', '│', '╭', '╮', '╯', '╰']
    : ['-', '|', '-', '|', '+', '+', '+', '+']
g:conduit_borderchars = get(g:, 'conduit_borderchars', border_chars)
g:conduit_put_max_depth = get(g:, 'conduit_put_max_depth', 5)
g:conduit_use_popup = get(g:, 'conduit_use_popup', false)
g:conduit_sep = get(g:, 'conduit_sep', ":::")
g:conduit_verbose = get(g:, 'conduit_verbose', false)
g:conduit_default_split = get(g:, 'conduit_default_split', "split")
g:conduit_overwrite_vim = get(g:, 'conduit_overwrite_vim', true)
g:conduit_fallback_shell = get(g:, 'conduit_fallback_shell', "bash")
g:conduit_host2shell = get(g:, 'conduit_host2shell', {})
g:conduit_default_control_persist = get(g:, 'conduit_default_control_persist', "60m")
g:conduit_host2sshoptions = get(g:, 'conduit_host2sshoptions', {})

g:conduit_put_ops = []
g:conduit_get_ops = []

import autoload 'conduit.vim'

# ── Commands ─────────────────────────────────────────────────────────────────

def EchoDeprecated(msg: string)
	echohl WarningMsg
	echo msg
	echohl clear
enddef

command! -bang -bar -nargs=+ -complete=customlist,conduit.ConduitCompl  Conduit conduit.ConduitCmd(false, !empty(expand("<bang>")), <q-mods>, <f-args>)

command! -bang -bar -nargs=+ -complete=customlist,conduit.ConduitHostAndOptionCompl ConduitOpen {
	EchoDeprecated(":ConduitOpen is deprecated and will be removed in a future version of Conduit. Use `:Conduit open`") 
	conduit.ConduitOpenCmd(false, !empty(expand("<bang>")), <q-mods>, <q-args>)
}
command! -bar -nargs=+ -complete=customlist,conduit.ConduitHostCompl ConduitDeploy {
	EchoDeprecated(":ConduitDeploy is deprecated and will be removed in a future version of Conduit. Use `:Conduit deploy`") 
	conduit.ConduitOpenCmd(true, false, '', <q-args>)
}

command! -bar -nargs=1 -complete=customlist,conduit.ConduitActiveCompl ConduitExit {
	EchoDeprecated(":ConduitExit is deprecated and will be removed in a future version of Conduit. Use `:Conduit exit`") 
	conduit.ConduitExitCmd(<q-args>)
}
command! -bar -nargs=1 -complete=customlist,conduit.ConduitActiveCompl ConduitDisconnect {
	EchoDeprecated(":ConduitDisconnect is deprecated and will be removed in a future version of Conduit. Use `:Conduit disconnect`") 
	conduit.ConduitDisconnectCmd(<q-args>)
}

command! -bar -nargs=1 -complete=customlist,conduit.ConduitActiveCompl ConduitCopySource {
	EchoDeprecated(":ConduitSource is deprecated and will be removed in a future version of Conduit. Use `:Conduit source`") 
	conduit.ConduitCopySourceCmd(<q-args>)
}

command! -bar ConduitNotifications {
	EchoDeprecated(":ConduitNotifications is deprecated and will be removed in a future version of Conduit. Use `:Conduit notifications`") 
	conduit.ShowHistory()
}

command! -bar -nargs=+ ConduitStopGet {
	EchoDeprecated(":ConduitStopGet is deprecated and will be removed in a future version of Conduit. Use `:Conduit stop get`") 
	conduit.ConduitStopCmd("get", <f-args>)
}

command! -bar -nargs=+ ConduitStopPut {
	EchoDeprecated(":ConduitStopPut is deprecated and will be removed in a future version of Conduit. Use `:Conduit stop put`") 
	conduit.ConduitStopCmd("put", <f-args>)
}

# ── Lifecycle & Integration ──────────────────────────────────────────────────
augroup ConduitOpen
    autocmd!
    autocmd VimLeave * conduit.MaybeCleanup(conduit.Connection.null_connection, true, true)
    autocmd BufReadCmd conduit://* call conduit.ConduitOpenCmd(false, true, '', bufname("%")[len("conduit://") : ])
augroup END

export def g:ConduitStatus(): string
	return conduit.ConduitStatus()
enddef
