set rtp^=.
let g:notifier_maxwidth = 500
" Expose the private helper in an isolated copy without adding a public API.
let test_runtime = tempname()
call mkdir(test_runtime . '/autoload', 'p')
let source = readfile('autoload/conduit.vim')
call map(source, 'substitute(v:val, "^def StartSystemOpener(", "export def StartSystemOpener(", "")')
call writefile(source, test_runtime . '/autoload/conduit.vim')
execute 'set rtp^=' . fnameescape(test_runtime)
runtime plugin/conduit.vim
call conduit#ParseConduitOpenArgs('testhost')
let StartOpener = function('conduit#StartSystemOpener')
let viewer_dir = tempname()
call mkdir(viewer_dir)
call writefile(['#!/bin/sh', 'printf "viewer could not decode image\n" >&2', 'exit 7'], viewer_dir . '/xdg-open')
call setfperm(viewer_dir . '/xdg-open', 'rwx------')
let saved_path = $PATH
let $PATH = viewer_dir . ':' . $PATH
try
  let viewer = StartOpener('/tmp/example.png', '/remote/example.png')
  sleep 300m
  call assert_equal('dead', job_status(viewer))
  let warnings = map(popup_list(), 'join(getbufline(winbufnr(v:val), 1, "$"), " ")')
  call assert_equal(1, len(warnings))
  call assert_match('/remote/example.png.*exit 7.*viewer could not decode image', join(warnings))
  call notifier#DismissAll(v:true)

  " Exit failures without stderr still report the exit code.
  call writefile(['#!/bin/sh', 'exit 3'], viewer_dir . '/xdg-open')
  let viewer = StartOpener('/tmp/example.png', '/remote/example.png')
  sleep 300m
  let warnings = map(popup_list(), 'join(getbufline(winbufnr(v:val), 1, "$"), " ")')
  call assert_equal(1, len(warnings))
  call assert_match('/remote/example.png.*exit 3', join(warnings))
  call notifier#DismissAll(v:true)

  " Successful viewers may write diagnostics without producing a warning.
  call writefile(['#!/bin/sh', 'printf "diagnostic\n" >&2', 'exit 0'], viewer_dir . '/xdg-open')
  let viewer = StartOpener('/tmp/example.png', '/remote/example.png')
  sleep 300m
  call assert_equal([], popup_list())
finally
  let $PATH = saved_path
  call delete(viewer_dir, 'rf')
  call delete(test_runtime, 'rf')
endtry
if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
