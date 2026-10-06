set rtp^=.
let g:notifier_maxwidth = 8
let g:notifier_carousel_interval = 50

function! HistoryLines()
  call notifier#ShowHistory()
  let lines = getline(1, '$')
  bwipeout!
  return lines
endfunction

let notification = notifier#Send('full notification text', {'prefix': 'initial'})
let initial = HistoryLines()
call assert_equal(1, len(initial))
call assert_match('initial full notification text$', initial[0])
call notifier#Modify(notification, 'updated full text', {'prefix': 'changed', 'subprefix': 'detail'})
let updated = HistoryLines()
call assert_equal(1, len(updated))
call assert_equal(strpart(initial[0], 0, 10), strpart(updated[0], 0, 10))
call assert_match('changed detail updated full text$', updated[0])
call notifier#Dismiss(notification, 0, v:true)
call assert_equal(updated, HistoryLines())

let spinner = notifier#StartLoading('loading full text')
let before_animation = HistoryLines()
sleep 250m
call assert_equal(before_animation, HistoryLines())
call notifier#UpdateLoading(spinner, 'new loading text')
call assert_match('new loading text$', HistoryLines()[-1])
call notifier#StopLoading(spinner, 'finished text')
call assert_match('finished text$', HistoryLines()[-1])

let progress = notifier#StartProgress('progress full text')
call notifier#UpdateProgress(progress, 50, 100, 'halfway text', {'subprefix': '50%'})
call assert_match('50% halfway text$', HistoryLines()[-1])
call notifier#Dismiss(progress, 0, v:true)
call assert_equal(3, len(HistoryLines()))

" Retention stays bounded, including when an evicted active entry changes.
let oldest = notifier#Send('oldest')
for i in range(101)
  let id = notifier#Send('entry ' . i)
  call notifier#Dismiss(id, 0, v:true)
endfor
call notifier#Modify(oldest, 'evicted update')
let retained = HistoryLines()
call assert_equal(100, len(retained))
call assert_match('entry 1$', retained[0])
call assert_match('entry 100$', retained[-1])
call notifier#Dismiss(oldest, 0, v:true)
call assert_equal(retained, HistoryLines())

if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
