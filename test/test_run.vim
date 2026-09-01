set rtp^=.
set rtp^=./test/fixtures
let g:conduit_use_popup = v:false
let g:conduit_run_auto_open_quickfix = v:false
let $CONDUIT_TEST_UPLOAD = tempname()
let $CONDUIT_TEST_RSYNC = tempname()
let $CONDUIT_TEST_SCP = tempname()
runtime plugin/conduit.vim

let open_parsed = conduit#ParseConduitOpenArgs('++nodeploy ++hidden testhost')
call assert_equal(v:true, open_parsed.nodeploy)
call assert_equal({'hidden': ''}, open_parsed.term_options)
call assert_equal([], open_parsed.ssh_options)

let deploying_open = conduit#ParseConduitOpenArgs('testhost')
call assert_equal(v:false, deploying_open.nodeploy)

call assert_true(index(
	\ conduit#ConduitCompl('++nod', 'Conduit open ++nod', strlen('Conduit open ++nod') + 1),
	\ '++nodeploy',
	\ ) >= 0)

messages clear
Conduit deploy ++nodeploy testhost
call assert_match('++nodeploy is only valid with Conduit open', execute('messages'))
messages clear

let parsed = conduit#ParseConduitRunArgs(
	\ '++cwd=/srv/my\ app dev printf x | sed s/x/y/',
	\ v:false,
	\ )
call assert_equal('/srv/my app', parsed.cwd)
call assert_equal('dev', parsed.connection)
call assert_equal('printf x | sed s/x/y/', parsed.command)
call assert_equal(v:false, parsed.loclist)

let loclist_parsed = conduit#ParseConduitRunArgs(
	\ '++loclist ++cwd=/srv dev make',
	\ v:false,
	\ )
call assert_equal(v:true, loclist_parsed.loclist)
call assert_equal('/srv', loclist_parsed.cwd)
call assert_equal('make', loclist_parsed.command)

let efm_parsed = conduit#ParseConduitRunArgs(
	\ '++errorformat=myalias dev make',
	\ v:false,
	\ )
call assert_equal('myalias', efm_parsed.errorformat)
call assert_equal('make', efm_parsed.command)

" The `=` is optional; ++cwd and ++errorformat also accept a space-separated
" value.
let space_parsed = conduit#ParseConduitRunArgs(
	\ '++cwd /srv/my\ app ++errorformat myalias dev printf x | sed s/x/y/',
	\ v:false,
	\ )
call assert_equal('/srv/my app', space_parsed.cwd)
call assert_equal('myalias', space_parsed.errorformat)
call assert_equal('dev', space_parsed.connection)
call assert_equal('printf x | sed s/x/y/', space_parsed.command)

let alias_after_connection = conduit#ParseConduitRunArgs(
	\ 'dev ++alias launch_job one two\ words',
	\ v:false,
	\ )
call assert_equal('dev', alias_after_connection.connection)
call assert_equal('launch_job', alias_after_connection.alias)
call assert_equal(['one', 'two words'], alias_after_connection.alias_args)

let alias_before_connection = conduit#ParseConduitRunArgs(
	\ '++alias launch_job one two\ words ++ dev',
	\ v:false,
	\ )
call assert_equal(alias_after_connection, alias_before_connection)
call assert_equal(
	\ alias_after_connection,
	\ conduit#ParseConduitRunArgs('++alias launch_job one two\ words -- dev', v:false),
	\ )

let rerun = conduit#ParseConduitRunArgs('dev', v:true)
call assert_equal(
	\ {'connection': 'dev', 'command': '', 'cwd': '', 'loclist': v:false, 'errorformat': ''},
	\ rerun,
	\ )

try
	call conduit#ParseConduitRunArgs('++loclist ++loclist dev echo ok', v:false)
	call assert_report('repeated ++loclist was accepted')
catch
	call assert_match('C013:', v:exception)
endtry

try
	call conduit#ParseConduitRunArgs('++errorformat=a ++errorformat=b dev echo ok', v:false)
	call assert_report('repeated ++errorformat was accepted')
catch
	call assert_match('C013:', v:exception)
endtry

try
	call conduit#ParseConduitRunArgs('++loclist=x dev echo ok', v:false)
	call assert_report('++loclist=x was accepted')
catch
	call assert_match('C013:', v:exception)
endtry

try
	call conduit#ParseConduitRunArgs('++cwd', v:false)
	call assert_report('valueless trailing ++cwd was accepted')
catch
	call assert_match('C013:', v:exception)
endtry

try
	call conduit#ParseConduitRunArgs('++bogus dev echo ok', v:false)
	call assert_report('unknown run option was accepted')
catch
	call assert_match('C013:', v:exception)
endtry
try
	call conduit#ParseConduitRunArgs('dev echo ok', v:true)
	call assert_report('bang run command was accepted')
catch
	call assert_match('C014:', v:exception)
endtry

call assert_equal(
	\ ['++cwd=', '++loclist', '++errorformat=', '++alias'],
	\ conduit#ConduitCompl('', 'Conduit run ', strlen('Conduit run ') + 1),
	\ )
call assert_equal(
	\ ['get', 'put', 'run', '*'],
	\ conduit#ConduitCompl('', 'Conduit stop ', strlen('Conduit stop ') + 1),
	\ )

Conduit deploy testhost
sleep 500m

let g:conduit_run_alias = {
	\ 'launch_job': {
	\   'alias': 'echo $0; echo $1:4:oops; echo DONE:$2',
	\   'nargs': 2,
	\   'errorfmt': '%f:%l:%m',
	\ },
	\ 'optional': {'alias': 'echo OPTIONAL:${1}', 'nargs': '?'},
	\ 'many': {'alias': 'echo MANY:$1:$2', 'nargs': '*'},
	\ 'pipeline': {'alias': 'printf x | sed s/x/y/', 'nargs': 0},
	\ 'compiled': {
	\   'alias': 'echo FIXTURE:$1:8:bad',
	\   'nargs': '+',
	\   'compiler': 'conduittest',
	\ },
	\ }
Conduit run testhost ++alias launch_job alias.c two\ words
sleep 500m
let run_alias_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(0, run_alias_qf.context.exit_code)
call assert_equal('launch_job', run_alias_qf.items[0].text)
call assert_equal('alias.c', run_alias_qf.items[1].module)
call assert_equal(4, run_alias_qf.items[1].lnum)
call assert_equal('DONE:two words', run_alias_qf.items[-1].text)

Conduit run testhost ++alias optional
sleep 500m
call assert_equal('OPTIONAL:', getqflist({'items': 0}).items[-1].text)
Conduit run ++alias many left right -- testhost
sleep 500m
call assert_equal('MANY:left:right', getqflist({'items': 0}).items[-1].text)
Conduit run testhost ++alias pipeline
sleep 500m
call assert_equal('y', getqflist({'items': 0}).items[-1].text)

Conduit run ++alias compiled compiled.c -- testhost
sleep 500m
let compiled_alias_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(1, compiled_alias_qf.items[0].valid)
call assert_equal('compiled.c', compiled_alias_qf.items[0].module)
call assert_equal(8, compiled_alias_qf.items[0].lnum)

messages clear
Conduit run testhost ++alias launch_job only-one
call assert_match('C007:.*expects 2 arguments, got 1', execute('messages'))
messages clear
Conduit run testhost ++alias missing
call assert_match('C004:.*alias "missing" does not exist', execute('messages'))
messages clear
let g:conduit_run_alias.bad_efm = {
	\ 'alias': 'echo bad', 'nargs': 0,
	\ 'errorfmt': '%m', 'compiler': 'conduittest',
	\ }
Conduit run testhost ++alias bad_efm
call assert_match('C004:.*cannot specify both errorfmt and compiler', execute('messages'))
messages clear

Conduit run ++cwd=/tmp testhost echo main.c:3:2: error: boom
sleep 500m

let qf = getqflist({'items': 0, 'context': 0, 'title': 0})
call assert_match('^\[Conduit run testhost\]', qf.title)
call assert_match('(finished, 1 entry)$', qf.title)
call assert_equal('run', qf.context.conduit)
call assert_equal(0, qf.context.exit_code)
call assert_equal('/tmp', qf.context.cwd)
let valid = filter(copy(qf.items), {_, item -> get(item, 'valid', 0)})
call assert_equal(1, len(valid))
call assert_match('^conduit-file://', bufname(valid[0].bufnr))
call assert_equal('main.c', valid[0].module)
call writefile([], $CONDUIT_TEST_RSYNC)
cfirst
call assert_equal('remote fixture', getline(1))
call assert_match('testhost:/tmp/main.c', readfile($CONDUIT_TEST_RSYNC)[-1])
call assert_equal('testhost', b:conduit_profile_key)
call assert_equal('/tmp/main.c', b:conduit_remote_path)
call setline(1, 'updated remotely')
write
call assert_equal(['updated remotely'], readfile($CONDUIT_TEST_UPLOAD))
call assert_match('testhost:/tmp/main.c', readfile($CONDUIT_TEST_RSYNC)[-1])

let g:conduit_use_rsync = v:false
Conduit run ++cwd=/tmp testhost echo scp.c:1:1: error: boom
sleep 500m
call writefile([], $CONDUIT_TEST_SCP)
cfirst
call assert_equal('remote fixture', getline(1))
call assert_match('testhost:/tmp/scp.c', readfile($CONDUIT_TEST_SCP)[-1])
let g:conduit_use_rsync = v:true

let g:conduit_run_auto_open_quickfix = v:true
Conduit! run testhost
sleep 500m
let rerun_qf = getqflist({'context': 0})
call assert_equal('run', rerun_qf.context.conduit)
call assert_equal(0, rerun_qf.context.exit_code)
call assert_equal(1, len(filter(getwininfo(), {_, win -> win.quickfix})))
cclose
let g:conduit_run_auto_open_quickfix = v:false

Conduit run testhost printf x \| sed s/x/y/
sleep 500m
let pipeline_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(0, pipeline_qf.context.exit_code)
call assert_equal('y', pipeline_qf.items[-1].text)

let clickable_file = '/tmp/conduit-run-clickable-test'
call writefile(['clickable'], clickable_file)
Conduit run ++cwd=/tmp testhost echo conduit-run-clickable-test
sleep 500m
let file_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(0, file_qf.context.exit_code)
call assert_equal(1, len(file_qf.items))
call assert_equal(1, file_qf.items[0].valid)
call assert_match('^conduit-file://', bufname(file_qf.items[0].bufnr))
call assert_equal('conduit-run-clickable-test', file_qf.items[0].module)
call assert_equal(0, file_qf.items[0].lnum)
call assert_equal(0, file_qf.items[0].col)
cfirst
call assert_equal('/tmp/conduit-run-clickable-test', b:conduit_remote_path)
call delete(clickable_file)

" ++errorformat=ALIAS resolves through g:conduit_errorformat first.
let g:conduit_errorformat = {'myalias': 'ALIAS:%f:%l:%m'}
Conduit run ++cwd=/tmp ++errorformat=myalias testhost echo ALIAS:alias.c:9:boom
sleep 500m
let alias_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(0, alias_qf.context.exit_code)
call assert_equal(1, len(alias_qf.items))
call assert_equal(1, alias_qf.items[0].valid)
call assert_equal('alias.c', alias_qf.items[0].module)
call assert_equal(9, alias_qf.items[0].lnum)

" ++errorformat=NAME falls back to a compiler plugin of that name, and
" leaves the invoking window's compiler state untouched afterwards.
let g:before_efm = &l:errorformat
let g:before_compiler = get(b:, 'current_compiler', '')
Conduit run ++cwd=/tmp ++errorformat=conduittest testhost echo FIXTURE:fixture.c:4:oops
sleep 500m
let compiler_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(0, compiler_qf.context.exit_code)
call assert_equal(1, len(compiler_qf.items))
call assert_equal(1, compiler_qf.items[0].valid)
call assert_equal('fixture.c', compiler_qf.items[0].module)
call assert_equal(4, compiler_qf.items[0].lnum)
call assert_equal(g:before_efm, &l:errorformat)
call assert_equal(g:before_compiler, get(b:, 'current_compiler', ''))

" Otherwise, ++errorformat is parsed as a literal 'errorformat' string.
Conduit run ++cwd=/tmp ++errorformat=%f#%l#%m testhost echo literal.c#6#bad
sleep 500m
let literal_qf = getqflist({'items': 0, 'context': 0})
call assert_equal(0, literal_qf.context.exit_code)
call assert_equal(1, len(literal_qf.items))
call assert_equal(1, literal_qf.items[0].valid)
call assert_equal('literal.c', literal_qf.items[0].module)
call assert_equal(6, literal_qf.items[0].lnum)

" ++loclist targets the invoking window's location list, not the quickfix list.
let qf_id_before = getqflist({'id': 0}).id
let run_winid = win_getid()
Conduit run ++loclist ++cwd=/tmp testhost echo loc.c:7:3: error: nope
sleep 500m
let loc = getloclist(run_winid, {'items': 0, 'context': 0, 'title': 0})
call assert_equal('run', loc.context.conduit)
call assert_equal(0, loc.context.exit_code)
call assert_match('(finished, 1 entry)$', loc.title)
call assert_equal(1, len(loc.items))
call assert_equal('loc.c', loc.items[0].module)
call assert_equal(7, loc.items[0].lnum)
call assert_equal(qf_id_before, getqflist({'id': 0}).id)

" Auto-open uses :lwindow, so the window that opens is a location window.
let g:conduit_run_auto_open_quickfix = v:true
Conduit run ++loclist ++cwd=/tmp testhost echo opened.c:2:1: error: y
sleep 500m
call assert_equal(1, len(filter(getwininfo(), {_, w -> w.loclist})))
call assert_equal(0, len(filter(getwininfo(), {_, w -> w.quickfix && !w.loclist})))
lclose
let g:conduit_run_auto_open_quickfix = v:false

" A rerun stays on the location list, resolving the window afresh.
Conduit! run testhost
sleep 500m
let rerun_loc = getloclist(run_winid, {'items': 0, 'context': 0})
call assert_equal(0, rerun_loc.context.exit_code)
call assert_equal(1, len(rerun_loc.items))
call assert_equal(qf_id_before, getqflist({'id': 0}).id)

" A quickfix window cannot own a location list, so the run falls back.
copen
call assert_equal(1, getwininfo(win_getid())[0].quickfix)
Conduit run ++loclist ++cwd=/tmp testhost echo fallback.c:1:1: error: x
sleep 500m
let fallback_qf = getqflist({'context': 0, 'title': 0})
call assert_equal('run', fallback_qf.context.conduit)
call assert_match('fallback.c', fallback_qf.title)
cclose

" Closing the owning window mid-run frees the location list; the task must
" finish without writing to it.
messages clear
new
let doomed_winid = win_getid()
Conduit run ++loclist testhost sleep 1
sleep 200m
close
sleep 1500m
call assert_equal([], getwininfo(doomed_winid))
call assert_notmatch('E\d\+:', execute('messages'))

Conduit run testhost sleep 5
sleep 100m
Conduit stop run testhost *
sleep 300m
let stopped_qf = getqflist({'context': 0, 'title': 0})
call assert_equal(-1, stopped_qf.context.exit_code)
call assert_match('(stopped, 0 entries)$', stopped_qf.title)

" ++nodeploy opens the session without uploading a replacement RC file.
call writefile([], $CONDUIT_TEST_RSYNC)
Conduit open ++nodeploy ++hidden testhost
sleep 500m
call assert_equal([], readfile($CONDUIT_TEST_RSYNC))

if !empty(v:errors)
	call writefile(v:errors, '/dev/stderr')
	cquit
endif
call delete($CONDUIT_TEST_UPLOAD)
call delete($CONDUIT_TEST_RSYNC)
call delete($CONDUIT_TEST_SCP)
qa!
