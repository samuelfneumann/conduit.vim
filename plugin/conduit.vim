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
g:conduit_borderchars = get(g:, 'conduit_borderchars', has('multi_byte')
    ? ['─', '│', '─', '│', '╭', '╮', '╯', '╰']
    : ['-', '|', '-', '|', '+', '+', '+', '+'])

g:conduit_put_ops = []
g:conduit_get_ops = []

import autoload 'conduit.vim'

# ── Commands ─────────────────────────────────────────────────────────────────

command! -bang -bar -nargs=+ -complete=customlist,conduit.ConduitCompl  Conduit conduit.ConduitCmd(false, !empty(expand("<bang>")), <q-mods>, <f-args>)
command! -bang -bar -nargs=+ -complete=customlist,conduit.ConduitHostCompl ConduitOpen conduit.ConduitOpenCmd(false, !empty(expand("<bang>")), <q-mods>, <q-args>)
command! -bar -nargs=+ -complete=customlist,conduit.ConduitHostCompl ConduitDeploy conduit.ConduitOpenCmd(true, false, '', <q-args>)
command! -bar -nargs=1 -complete=customlist,conduit.ConduitActiveCompl ConduitExit conduit.ConduitExitCmd(<q-args>)
command! -bar -nargs=1 -complete=customlist,conduit.ConduitActiveCompl ConduitDisconnect conduit.ConduitDisconnectCmd(<q-args>)
command! -bar -nargs=1 -complete=customlist,conduit.ConduitActiveCompl ConduitCopySource conduit.ConduitCopySourceCmd(<q-args>)
command! -bar ConduitNotifications conduit.ShowHistory()
command! -bar -nargs=+ ConduitStopGet conduit.ConduitStopCmd("get", <f-args>)
command! -bar -nargs=+ ConduitStopPut conduit.ConduitStopCmd("put", <f-args>)

# ── Lifecycle & Integration ──────────────────────────────────────────────────
augroup SshOpen
    autocmd!
    autocmd VimLeave * conduit.MaybeCleanup(conduit.Connection.null_connection, true, true)
    autocmd BufReadCmd conduit://* call conduit.SshOpenCmd(false, true, '', bufname("%")[len("conduit://") : ])
augroup END

export def g:ConduitStatus(): string
	return conduit.ConduitStatus()
enddef
