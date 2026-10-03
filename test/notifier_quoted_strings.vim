set rtp^=.
let g:notifier_maxwidth = 8
let g:notifier_carousel_interval = 50
let g:notifier_carousel_end_pause = 0
let g:conduit_notifier_n_rotations_before_auto_dismiss = 100
for quote in ['"', "'"]
  let n = notifier#Send('X ‹' . quote . repeat('a', 12) . quote . '› Y')
  for frame in range(30)
    let b = winbufnr(n)
    let text = getbufline(b, 1)[0]
    let props = filter(prop_list(1, {'bufnr': b}), 'v:val.type ==# "notify_string"')
    for i in range(strchars(text))
      let char = strcharpart(text, i, 1)
      let col = byteidx(text, i) + 1
      let covered = !empty(filter(copy(props), 'v:val.col <= col && col < v:val.col + v:val.length'))
      call assert_equal(char ==# 'a' || char ==# quote, covered, string([quote, frame, text, i]))
    endfor
    sleep 55m
  endfor
  call notifier#Dismiss(n)
endfor
if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
