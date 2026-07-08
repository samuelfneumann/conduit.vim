vim9script

import autoload 'error.vim'

# ── Configuration & State ────────────────────────────────────────────────
g:notifier_maxwidth = get(g:, 'notifier_maxwidth', &columns / 2)
g:notifier_overflow = get(g:, 'notifier_overflow', 'carousel')
g:notifier_carousel_interval = get(g:, 'notifier_carousel_interval', 100)
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

abstract class Notification
	var winid: number
	var msg: string

	def SetMessage(msg: string)
		this.msg = msg
	enddef

	def SetWinID(winid: number)
		this.winid = winid
	enddef

	abstract def Message(): string
	abstract def Formatted(): string
	abstract def Frame(): string
	abstract def Update(opts: dict<any>)
endclass

class Progress extends Notification
	static const pbar_filled: string = pbar_filled
	static const pbar_empty: string = pbar_empty
	static const width: number = pbar_width

	var p: float

	def new(winid: number, msg: string)
		this.winid = winid
		this.msg = msg
		this.p = 0.0
	enddef

	def Message(): string
		return this.msg
	enddef

	def Formatted(): string
		return this.Frame() .. '  ' .. this.Message()
	enddef

	def Frame(): string
		const filled_len = float2nr(trunc(this.p * Progress.width))
		const empty_len = Progress.width - filled_len
		return repeat(pbar_filled, filled_len) .. repeat(pbar_empty, empty_len)
	enddef

	def Update(opts: dict<any>)
		if !has_key(opts, 'percentage')
			throw error.Error.MissingNotifierOptionKey.Format(
				"missing key 'percentage'",
			)
		endif
		this.p = opts.percentage
	enddef
endclass

class Spinner extends Notification
	static const frames = spinner_frames
	const timer_id: number
	var i: number

	def new(winid: number, msg: string)
		this.winid = winid
		this.msg = msg
		this.i = 0
		this.timer_id = this.Spin()
	enddef

	def Spin(): number
		return timer_start(100, (t) => AnimateSpinner(this, t), {repeat: -1})
	enddef

	def Message(): string
		return this.msg
	enddef

	def Formatted(): string
		return this.Frame() .. ' ' .. this.Message()
	enddef

	def Frame(): string
		return Spinner.frames[this.i]
	enddef

	def Update(opts: dict<any>)
		this.i = (this.i + 1) % len(Spinner.frames)
	enddef

	def Stop()
		if this.timer_id > -1
			timer_stop(this.timer_id)
		endif
	enddef
endclass

class Basic extends Notification
	def new(winid: number, msg: string)
		this.winid = winid
		this.msg = msg
	enddef

	def Message(): string
		return this.msg
	enddef

	def Frame(): string
		return ""
	enddef

	def Formatted(): string
		return this.Message()
	enddef

	def Update(opts: dict<any>)
	enddef
endclass

var active_spinners: dict<Spinner> = {} 
var active_pbars: dict<Progress> = {} 

# Carousel State Tracking
var active_carousels: dict<number> = {}
var carousel_msgs: dict<string> = {}
var carousel_prefixes: dict<string> = {}
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

def AddHighlightChars(bufnr: number, linenr: number, text: string, start_char: number, end_char: number, prop_type: string)
	if start_char < 0 || end_char <= start_char || prop_type == ""
		return
	endif

	const start_byte = byteidx(text, start_char)
	const end_byte = byteidx(text, end_char)
	if start_byte == -1 || end_byte == -1
		return
	endif
	AddHighlight(bufnr, linenr, start_byte, end_byte, prop_type)
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

def CanCarousel(msg: string, fixed_prefix: string = ''): bool
	return GetOverflowMode() ==# 'carousel'
		&& strcharlen(fixed_prefix .. msg) > GetMaxWidth()
enddef

def CarouselCycleLen(msg: string): number
	return strcharlen(msg) + 3
enddef

def CarouselFrame(msg: string, idx: number, fixed_prefix: string = ''): string
	const width = GetMaxWidth()
	const body_width = width - strcharlen(fixed_prefix)
	if width <= 0 || strcharlen(fixed_prefix .. msg) <= width
		return fixed_prefix .. msg
	elseif body_width <= 0
		return strcharpart(fixed_prefix, 0, width)
	endif

	const gap = '   '
	const cycle_len = CarouselCycleLen(msg)
	const start = idx % cycle_len
	const tape = msg .. gap .. msg
	var frame = strcharpart(tape, start, body_width)
	const missing = body_width - strcharlen(frame)
	if missing > 0
		frame ..= strcharpart(tape, 0, missing)
	endif
	return fixed_prefix .. frame
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
	if has_key(carousel_prefixes, id_str) | remove(carousel_prefixes, id_str) | endif
	if has_key(carousel_idxs, id_str) | remove(carousel_idxs, id_str) | endif
enddef

def AddCarouselOpHighlight(winid: number, bufnr: number, linenr: number, text: string): bool
	const id_str = string(winid)
	if !has_key(carousel_msgs, id_str)
		return false
	endif

	const msg = carousel_msgs[id_str]
	const prefix = get(carousel_prefixes, id_str, '')
	const body_width = GetMaxWidth() - strcharlen(prefix)
	if body_width <= 0
		return false
	endif

	const msg_len = strcharlen(msg)
	const gap_len = 3
	const cycle_len = msg_len + gap_len
	const frame_start = carousel_idxs[id_str] % cycle_len
	const frame_end = frame_start + body_width
	var found = false

	var search_start = 0
	while search_start >= 0
		const op_match = matchstrpos(msg, '\[\(get\|put\|mget\|mput\)\]', search_start)
		if op_match[1] == -1
			break
		endif

		const op_start = strcharlen(strpart(msg, 0, op_match[1]))
		const op_end = strcharlen(strpart(msg, 0, op_match[2]))
		for offset in [0, cycle_len]
			const shifted_start = op_start + offset
			const shifted_end = op_end + offset
			const visible_start = max([shifted_start, frame_start])
			const visible_end = min([shifted_end, frame_end])
			if visible_start < visible_end
				AddHighlightChars(
					bufnr,
					linenr,
					text,
					strcharlen(prefix) + visible_start - frame_start,
					strcharlen(prefix) + visible_end - frame_start,
					"notify_op"
				)
				found = true
			endif
		endfor

		search_start = op_match[2]
	endwhile

	return found
enddef

def SetDisplayText(
	winid: number,
	in_msg: string,
	update_history: bool = true,
	update_positions: bool = true,
	fixed_prefix: string = '',
)
	if win_gettype(winid) !=# 'popup'
		return
	endif

	const id_str = string(winid)
	if CanCarousel(in_msg, fixed_prefix)
		carousel_msgs[id_str] = in_msg
		carousel_prefixes[id_str] = fixed_prefix
		if !has_key(carousel_idxs, id_str) | carousel_idxs[id_str] = 0 | endif
		popup_settext(
			winid,
			CarouselFrame(in_msg, carousel_idxs[id_str], fixed_prefix)
		)
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
		popup_settext(winid, FormatMsg(fixed_prefix .. in_msg, true))
		ApplyHighlight(winid)
	endif

	if update_history
		notif_texts[id_str] = fixed_prefix .. in_msg
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

    if !AddCarouselOpHighlight(winid, bufnr, linenr, text)
		var op_match = matchstrpos(text, '\[\(get\|put\|mget\|mput\)\]')
		AddHighlight(bufnr, linenr, op_match[1], op_match[2], "notify_op")
	endif

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
        active_spinners[id_str].Stop()
        remove(active_spinners, id_str)
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

def AnimateSpinner(spinner: Spinner, timer_id: number)
    var id_str = string(spinner.winid)
    if index(active_notifs, spinner.winid) == -1
        timer_stop(spinner.timer_id)
        return
    endif
    
    # Do not update history for intermediate animation frames.
	spinner.Update({})
    SetDisplayText(spinner.winid, spinner.Message(), false, false, spinner.Frame() .. " ")
enddef

def AnimateCarousel(winid: number, timer_id: number)
    var id_str = string(winid)
    if index(active_notifs, winid) == -1 || !has_key(carousel_msgs, id_str)
        timer_stop(timer_id)
        return
    endif

    carousel_idxs[id_str] = (carousel_idxs[id_str] + 1) % CarouselCycleLen(carousel_msgs[id_str])
    popup_settext(
		winid,
		CarouselFrame(
			carousel_msgs[id_str],
			carousel_idxs[id_str],
			get(carousel_prefixes, id_str, '')
		)
	)
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
    var loading_opts = extendnew(opts, {persistent: true})
    var winid = Send(msg, loading_opts)
	var spinner = Spinner.new(winid, msg)

	SetDisplayText(winid, spinner.Message(), true, false, spinner.Frame() .. " ")
    
    var id_str = string(spinner.winid)
    active_spinners[id_str] = spinner
    
    return winid
enddef

export def StopLoading(winid: number, final_msg: string = "")
    var id_str = string(winid)
    if has_key(active_spinners, id_str)
		var spinner = active_spinners[id_str]
		spinner.Stop()
        remove(active_spinners, id_str)
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
    if has_key(active_spinners, id_str)
        # Update the base message in our tracker
		var spinner = active_spinners[id_str]
		spinner.SetMessage(new_msg)
        
        # Construct the full string and pass it to Modify() 
        # so that our syntax highlighting logic still applies!
        SetDisplayText(spinner.winid, spinner.Message(), true, true, spinner.Frame() .. " ")
    endif
enddef

export def StartProgress(msg: string, opts: dict<any> = {}): number
	var bar = Progress.new(-1, msg)
    
    var progress_opts = {persistent: true}
    extend(progress_opts, opts)
    bar.SetWinID(Send(bar.Frame() .. "  " .. msg, progress_opts))

	const id_str = string(bar.winid)
	active_pbars[id_str] = bar

	SetDisplayText(bar.winid, bar.Message(), true, false, bar.Frame() .. "  ")
	return bar.winid
enddef

export def UpdateProgress(winid: number, current: number, total: number, msg: string = "")
	const id_str = string(winid)
	if !has_key(active_pbars, id_str)
		return
	endif

	final pbar = active_pbars[id_str]

    var percentage = 0.0
    if total > 0 | percentage = (current + 0.0) / (total + 0.0) | endif
    if percentage > 1.0 | percentage = 1.0 | endif
    if percentage < 0.0 | percentage = 0.0 | endif

	pbar.Update({percentage: percentage})

    if msg != ""
		SetDisplayText(pbar.winid, pbar.Message(), true, true, pbar.Frame() .. "  ")
	else
		Modify(winid, pbar.Frame())
	endif
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
