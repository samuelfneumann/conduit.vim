set rtp^=.
let g:notifier_maxwidth = 8
let g:notifier_carousel_interval = 50
let g:notifier_carousel_end_pause = 1000
let g:conduit_notifier_n_rotations_before_auto_dismiss = 1

" Each concurrent carousel completes its own cycle, including a spinner
" whose frame refreshes repeatedly call the rendering strategy.
let first = notifier#Send('abcdefghi')
let second = notifier#Send('ABCDEFGHIJKLM')
let spinner = notifier#StartLoading('123456789')
for id in [first, second, spinner]
  call notifier#Dismiss(id)
endfor
sleep 400m
for id in [first, second, spinner]
  call assert_equal('popup', win_gettype(id), 'Dismissed before a full cycle')
endfor
call notifier#Modify(first, 'abcdefghi', {'prefix': 'X '})
sleep 650m
for id in [first, second, spinner]
  call assert_true(empty(popup_getpos(id)), 'Must dismiss after one cycle without waiting for the end pause')
endfor
call notifier#DismissAll(v:true)

" Exactly two cycles are required; the initial frame is not a rotation.
let g:notifier_carousel_end_pause = 0
let g:conduit_notifier_n_rotations_before_auto_dismiss = 2
let twice = notifier#Send('abcdefghi')
call notifier#Dismiss(twice)
sleep 900m
call assert_equal('popup', win_gettype(twice), 'Dismissed before two full cycles')
sleep 650m
call assert_true(empty(popup_getpos(twice)), 'Must dismiss after two cycles')
call notifier#DismissAll(v:true)

if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
