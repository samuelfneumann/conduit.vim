set rtp^=.
let g:conduit_use_popup = v:false
let g:conduit_run_auto_open_quickfix = v:false
let $CONDUIT_TEST_UPLOAD = tempname()
runtime plugin/conduit.vim

let parsed = conduit#ParseConduitRunArgs(
	\ '++cwd=/srv/my\ app dev printf x | sed s/x/y/',
	\ v:false,
	\ )
call assert_equal('/srv/my app', parsed.cwd)
call assert_equal('dev', parsed.connection)
call assert_equal('printf x | sed s/x/y/', parsed.command)

let rerun = conduit#ParseConduitRunArgs('dev', v:true)
call assert_equal({'connection': 'dev', 'command': '', 'cwd': ''}, rerun)

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
	\ ['++cwd='],
	\ conduit#ConduitCompl('', 'Conduit run ', strlen('Conduit run ') + 1),
	\ )
call assert_equal(
	\ ['get', 'put', 'run', '*'],
	\ conduit#ConduitCompl('', 'Conduit stop ', strlen('Conduit stop ') + 1),
	\ )

Conduit deploy testhost
sleep 500m
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
cfirst
call assert_equal('remote fixture', getline(1))
call assert_equal('testhost', b:conduit_profile_key)
call assert_equal('/tmp/main.c', b:conduit_remote_path)
call setline(1, 'updated remotely')
write
call assert_equal(['updated remotely'], readfile($CONDUIT_TEST_UPLOAD))

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

Conduit run testhost sleep 5
sleep 100m
Conduit stop run testhost *
sleep 300m
let stopped_qf = getqflist({'context': 0, 'title': 0})
call assert_equal(-1, stopped_qf.context.exit_code)
call assert_match('(stopped, 0 entries)$', stopped_qf.title)

if !empty(v:errors)
	call writefile(v:errors, '/dev/stderr')
	cquit
endif
call delete($CONDUIT_TEST_UPLOAD)
qa!
