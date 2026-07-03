vim9script

# ── Configuration & State ────────────────────────────────────────────────
g:notifier_maxwidth = get(g:, 'notifier_maxwidth', &columns / 2)
g:notifier_overflow = get(g:, 'notifier_overflow', 'carousel')
g:notifier_carousel_interval = get(g:, 'notifier_carousel_interval', 300)
const pbar_width = min([20, max([3, float2nr(floor(g:notifier_maxwidth / 3))])])

var checkmark: string = has('multi_byte') ? '✓' : '='
var xmark: string = has('multi_byte') ? '×' : 'x'
var right_arrow: string = has('multi_byte') ? '→' : '->'
var pbar_filled: string = has('multi_byte') ? '█' : '#'
var pbar_empty: string = has('multi_byte') ? '▒' : '-'

var border_chars_default: list<string> = has('multi_byte')
    ? ['─', '│', '─', '│', '╭', '╮', '╯', '╰']
    : ['-', '|', '-', '|', '+', '+', '+', '+']
var border_chars: list<string> = get(
	g:, 'conduit_borderchars', border_chars_default
)

export var position: string = "top-right"

var active_notifs: list<number> = []

# Spinner State Tracking
var spinner_frames: list<string>
if has('multi_byte')
	spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
else
	spinner_frames = ['/', '-', '\', '|']
endif
var active_spinners: dict<number> = {} 
var spinner_msgs: dict<string> = {}    
var spinner_idxs: dict<number> = {}    

# Carousel State Tracking
var active_carousels: dict<number> = {}
var carousel_msgs: dict<string> = {}
var carousel_idxs: dict<number> = {}

# History Tracking
var history: list<string> = []
var notif_texts: dict<string> = {} # winid (string) -> latest message text

# ── Highlight Groups & Text Properties ───────────────────────────────────
hi def link NotifyRightArrow Function
hi def link NotifySuccess String
hi def link NotifyError Error
hi def link NotifyWarning WarningMsg
hi def link NotifyInfo Question
hi def link NotifyOp Identifier

def InitProp(name: string, hl_group: string)
    if empty(prop_type_get(name))
        prop_type_add(name, {
            highlight: hl_group,
            combine: false,
            override: true,
        })
    endif
enddef

InitProp("notify_right_arrow", "NotifyRightArrow")
InitProp("notify_success", "NotifySuccess")
InitProp("notify_error", "NotifyError")
InitProp("notify_warning", "NotifyWarning")
InitProp("notify_info", "NotifyInfo")
InitProp("notify_op", "NotifyOp")

# ── Internal Helpers ─────────────────────────────────────────────────────
def AddHighlight(bufnr: number, linenr: number, start_byte: number, end_byte: number, prop_type: string)
	if start_byte == -1 || prop_type == ""
		return
	endif

	# Columns are 1-based in Vim, so we add 1 to start_byte.
	prop_add(linenr, start_byte + 1, {
		length: end_byte - start_byte,
		type: prop_type,
		bufnr: bufnr,
	})
enddef

def GetMaxWidth(): number
	return max([1, !empty(g:notifier_maxwidth) ? float2nr(g:notifier_maxwidth) : &columns])
enddef

def GetOverflowMode(): string
	return g:notifier_overflow
enddef

def GetCarouselInterval(): number
	const interval = get(g:, 'notifier_carousel_interval', 300)
	if type(interval) != v:t_number
		return 300
	endif
	return max([50, interval])
enddef

def CanCarousel(msg: string): bool
	return GetOverflowMode() ==# 'carousel' && strcharlen(msg) > GetMaxWidth()
enddef

def CarouselCycleLen(msg: string): number
	return strcharlen(msg) + 3
enddef

def CarouselFrame(msg: string, idx: number): string
	const width = GetMaxWidth()
	if width <= 0 || strcharlen(msg) <= width
		return msg
	endif

	const gap = '   '
	const cycle_len = CarouselCycleLen(msg)
	const start = idx % cycle_len
	const tape = msg .. gap .. msg
	var frame = strcharpart(tape, start, width)
	const missing = width - strcharlen(frame)
	if missing > 0
		frame ..= strcharpart(tape, 0, missing)
	endif
	return frame
enddef

def FormatMsg(msg: string, include_ellipsis: bool): string
	if GetOverflowMode() ==# 'wrap'
		return msg
	elseif strcharlen(msg) > GetMaxWidth() # truncate
		const width = GetMaxWidth()
		if include_ellipsis && has('multi_byte')
			return strcharpart(msg, 0, width - 1) .. "…"
		elseif include_ellipsis && width > 3
			return strcharpart(msg, 0, width - 3) .. "..."
		else
			return strcharpart(msg, 0, width)
		endif
	endif

	return msg
enddef

def StopCarousel(winid: number)
	const id_str = string(winid)
	if has_key(active_carousels, id_str)
		timer_stop(active_carousels[id_str])
		remove(active_carousels, id_str)
	endif
	if has_key(carousel_msgs, id_str) | remove(carousel_msgs, id_str) | endif
	if has_key(carousel_idxs, id_str) | remove(carousel_idxs, id_str) | endif
enddef

def SetDisplayText(winid: number, in_msg: string, update_history: bool = true, update_positions: bool = true)
	if win_gettype(winid) !=# 'popup'
		return
	endif

	const id_str = string(winid)
	if CanCarousel(in_msg)
		carousel_msgs[id_str] = in_msg
		if !has_key(carousel_idxs, id_str) | carousel_idxs[id_str] = 0 | endif
		popup_settext(winid, CarouselFrame(in_msg, carousel_idxs[id_str]))
		ApplyHighlight(winid)

		if !has_key(active_carousels, id_str)
			active_carousels[id_str] = timer_start(
				GetCarouselInterval(),
				(t) => AnimateCarousel(winid, t),
				{repeat: -1}
			)
		endif
	else
		StopCarousel(winid)
		popup_settext(winid, FormatMsg(in_msg, true))
		ApplyHighlight(winid)
	endif

	if update_history
		notif_texts[id_str] = in_msg
	endif
	if update_positions
		UpdatePositions()
	endif
enddef

def ApplyHighlight(winid: number, linenr: number=1)
    var bufnr = winbufnr(winid)
    if bufnr == -1 | return | endif
	if linenr > line("$", winid) | return | endif

	const text = getbufline(winbufnr(winid), linenr)[0]
	if empty(text) | return | endif

    # Clear any existing highlights on the first line
    prop_clear(linenr, 1, {bufnr: bufnr})

    var op_match = matchstrpos(text, '\[\(get\|put\|mget\|mput\)\]')
	AddHighlight(bufnr, linenr, op_match[1], op_match[2], "notify_op")

    # Find the FIRST occurrence of any of the target symbols.
    # In ASCII mode, we are more restrictive to avoid highlighting characters in words.
    var pattern = has('multi_byte') ? '[✓×!?→]' : '\v%(^|[ ])\zs(\=|x|!|\?|-\>)\ze%([ ]|$)'
    var match_info = matchstrpos(text, pattern)
    var start_byte = match_info[1]
    var end_byte = match_info[2]

    # If no special character is found, only the op highlight applies.
    if start_byte == -1 | return | endif

    var matched_char = match_info[0]
    var prop_type = ""

    if matched_char ==# checkmark
        prop_type = "notify_success"
    elseif matched_char ==# xmark
        prop_type = "notify_error"
    elseif matched_char ==# "!"
        prop_type = "notify_warning"
    elseif matched_char ==# "?"
        prop_type = "notify_info"
    elseif matched_char ==# right_arrow
        prop_type = "notify_right_arrow"
    endif

	AddHighlight(bufnr, linenr, start_byte, end_byte, prop_type)
enddef

def UpdatePositions()
    var current_line = 0
    var is_bottom = position =~# '^bottom'
    
    if is_bottom
        current_line = &lines - &cmdheight - 1
    else
        current_line = &showtabline > 0 ? 2 : 1
    endif

    for winid in active_notifs
        var pos_info = popup_getpos(winid)
        if empty(pos_info) | continue | endif
        
        popup_setoptions(winid, {line: current_line})
        
        if is_bottom
            current_line -= pos_info.height
        else
            current_line += pos_info.height
        endif
    endfor
enddef

def OnPopupClose(winid: number, result: any)
    var id_str = string(winid)

    # 1. Save final text to history
    if has_key(notif_texts, id_str)
        var time_str = strftime("%H:%M:%S")
        add(history, printf("[%s] %s", time_str, notif_texts[id_str]))
        
        # Keep history to a maximum of 100 entries to save memory
        if len(history) > 100
            remove(history, 0)
        endif
        remove(notif_texts, id_str)
    endif

    # 2. Clean up timer if this was a loading spinner
    if has_key(active_spinners, id_str)
        timer_stop(active_spinners[id_str])
        remove(active_spinners, id_str)
        remove(spinner_msgs, id_str)
        remove(spinner_idxs, id_str)
    endif

	# 3. Clean up timer if this notification is carouseling
	StopCarousel(winid)

    # 4. Remove from active list and restack
    var idx = index(active_notifs, winid)
    if idx >= 0
        remove(active_notifs, idx)
        UpdatePositions()
    endif
enddef

def AnimateSpinner(winid: number, timer_id: number)
    var id_str = string(winid)
    if index(active_notifs, winid) == -1
        timer_stop(timer_id)
        return
    endif
    
    var idx = spinner_idxs[id_str]
    var frame = spinner_frames[idx]
    spinner_idxs[id_str] = (idx + 1) % len(spinner_frames)
    
    # Do not update history for intermediate animation frames.
    SetDisplayText(winid, frame .. " " .. spinner_msgs[id_str], false, false)
enddef

def AnimateCarousel(winid: number, timer_id: number)
    var id_str = string(winid)
    if index(active_notifs, winid) == -1 || !has_key(carousel_msgs, id_str)
        timer_stop(timer_id)
        return
    endif

    carousel_idxs[id_str] = (carousel_idxs[id_str] + 1) % CarouselCycleLen(carousel_msgs[id_str])
    popup_settext(winid, CarouselFrame(carousel_msgs[id_str], carousel_idxs[id_str]))
    ApplyHighlight(winid)
enddef

# ── Public API ───────────────────────────────────────────────────────────

export def Send(in_msg: string, opts: dict<any> = {}): number
    var p_line: number
    var p_col: number
    var p_pos: string
    
    if position == 'bottom-right'
        p_pos = 'botright'
        p_line = &lines - &cmdheight - 1
        p_col = &columns
    elseif position == 'top-right'
        p_pos = 'topright'
        p_line = 1
        p_col = &columns
    elseif position == 'bottom-left'
        p_pos = 'botleft'
        p_line = &lines - &cmdheight - 1
        p_col = 1
    else 
        p_pos = 'topleft'
        p_line = 1
        p_col = 1
    endif

    var default_opts = {
        line: p_line,
        col: p_col,
        pos: p_pos,
		wrap: GetOverflowMode() ==# 'wrap',
		maxwidth: GetMaxWidth(),
        highlight: 'Normal',
        padding: [0, 1, 0, 1],
        borderchars: border_chars,
        border: [1, 1, 1, 1, 1, 1, 1, 1],
        tabpage: -1,
        zindex: 100,
        time: 0,
        persistent: false,
        callback: OnPopupClose
    }
    
    extend(default_opts, opts)

	var msg = CanCarousel(in_msg) ? CarouselFrame(in_msg, 0) : FormatMsg(in_msg, true)

    var winid: number
    if default_opts.persistent
        # Use popup_create for persistent popups that don't close on keypress
        winid = popup_create(msg, default_opts)
    else
        # Use popup_notification for ephemeral messages that close on keypress
        winid = popup_notification(msg, default_opts)
    endif

    add(active_notifs, winid)
	SetDisplayText(winid, in_msg, true, false)
    UpdatePositions()
    
    return winid
enddef

export def Modify(winid: number, in_msg: string)
    if win_gettype(winid) == 'popup'
		SetDisplayText(winid, in_msg)
    endif
enddef

export def Dismiss(winid: number)
    if win_gettype(winid) == 'popup'
        popup_close(winid)
    endif
enddef

export def DismissAll()
	for notif in active_notifs
		Dismiss(notif)
	endfor
enddef

export def StartLoading(msg: string, opts: dict<any> = {}): number
    var initial_msg = spinner_frames[0] .. " " .. msg
    
    var loading_opts = extendnew(opts, {persistent: true})
    var winid = Send(initial_msg, loading_opts)
    
    var id_str = string(winid)
    spinner_msgs[id_str] = msg
    spinner_idxs[id_str] = 1
    
    var timer_id = timer_start(100, (t) => AnimateSpinner(winid, t), {repeat: -1})
    active_spinners[id_str] = timer_id
    
    return winid
enddef

export def StopLoading(winid: number, final_msg: string = "")
    var id_str = string(winid)
    if has_key(active_spinners, id_str)
        timer_stop(active_spinners[id_str])
        remove(active_spinners, id_str)
        remove(spinner_msgs, id_str)
        remove(spinner_idxs, id_str)
    endif
    
    if final_msg != ""
        Modify(winid, final_msg)
    else
        Dismiss(winid)
    endif
enddef

export def UpdateLoading(winid: number, new_msg: string)
    var id_str = string(winid)
    
    # Check if this popup is actually an active spinner
    if has_key(spinner_msgs, id_str)
        # Update the base message in our tracker
        spinner_msgs[id_str] = new_msg
        
        # Grab the current frame so the animation doesn't skip a beat
        var current_idx = spinner_idxs[id_str]
        var frame = spinner_frames[current_idx]
        
        # Construct the full string and pass it to Modify() 
        # so that our syntax highlighting logic still applies!
        var full_msg = frame .. " " .. new_msg
        Modify(winid, full_msg)
    endif
enddef

export def StartProgress(msg: string, opts: dict<any> = {}): number
    var empty_bar = repeat(pbar_empty, pbar_width)
    
    var progress_opts = {persistent: true}
    extend(progress_opts, opts)
    return Send(empty_bar .. "  " .. msg, progress_opts)
enddef

export def UpdateProgress(winid: number, current: number, total: number, msg: string = "")
    var percentage = 0.0
    if total > 0 | percentage = (current + 0.0) / (total + 0.0) | endif
    if percentage > 1.0 | percentage = 1.0 | endif
    if percentage < 0.0 | percentage = 0.0 | endif
    
	# We use trunc instead of round so that the bar is only completely filled
	# once we reach 100%. With round, we will fill the bar when we are >= 95%
	# complete
    var filled_len = float2nr(trunc(percentage * pbar_width))
    var empty_len = pbar_width - filled_len
    var bar = repeat(pbar_filled, filled_len) .. repeat(pbar_empty, empty_len)
    
    var full_msg = bar
    if msg != "" | full_msg ..= "  " .. msg | endif
    
    Modify(winid, full_msg)
enddef

# Opens a scratch buffer displaying past notifications
export def ShowHistory()
    if empty(history)
        echo "No notifications in history."
        return
    endif
    
    # Open a 10-line split at the bottom
    execute('botright :10new')
    setlocal buftype=nofile bufhidden=wipe noswapfile
    setline(1, history)

	for l in range(line("$"))
		ApplyHighlight(win_getid(), l + 1)
	endfor
    
    # Optional: Highlight the timestamps
    syntax match NotifyTime /^\[\d\d:\d\d:\d\d\]/
    hi def link NotifyTime Comment
    
    # Press 'q' to quickly close the history buffer
    nnoremap <buffer> <silent> q :bwipeout<CR>
enddef
