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

# Spinner State Tracking
var spinner_frames: list<string>
if has('multi_byte')
	spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
else
	spinner_frames = ['/', '-', '\', '|']
endif

enum NotificationKind
	Spinner,
	Progress,
	Basic,
endenum

class NotificationOptions
	var prefix: string = ""
	var subprefix: string = ""
	var has_prefix: bool = false
	var has_subprefix: bool = false
	var popup_opts: dict<any> = {}

	def new(opts: dict<any> = {})
		this.popup_opts = copy(opts)
		if has_key(this.popup_opts, 'prefix')
			this.prefix = this.popup_opts.prefix
			this.has_prefix = true
			this.popup_opts->remove('prefix')
		endif
		if has_key(this.popup_opts, 'subprefix')
			this.subprefix = this.popup_opts.subprefix
			this.has_subprefix = true
			this.popup_opts->remove('subprefix')
		endif
	enddef

	def PopupOptions(): dict<any>
		return copy(this.popup_opts)
	enddef

	def SetPersistent()
		this.popup_opts.persistent = true
	enddef
endclass

abstract class Notification
	var winid: number
	var msg: string
	var prefix: string
	var subprefix: string
	const kind: NotificationKind

	def SetMessage(msg: string)
		this.msg = msg
	enddef

	def SetPrefix(prefix: string)
		this.prefix = prefix
	enddef

	def SetSubPrefix(subprefix: string)
		this.subprefix = subprefix
	enddef

	def PrefixText(): string
		var parts: list<string> = []
		if !empty(this.prefix) | parts->add(this.prefix) | endif
		if !empty(this.subprefix) | parts->add(this.subprefix) | endif
		if empty(parts) | return "" | endif
		return parts->join(" ") .. " "
	enddef

	def SetWinID(winid: number)
		this.winid = winid
	enddef

	def Kind(): NotificationKind
		return this.kind
	enddef

	def Stop()
	enddef

	abstract def Message(): string
	abstract def FixedPrefix(): string
	abstract def Formatted(): string
	abstract def Frame(): string
	abstract def FrameOff()
	abstract def FrameOn()
	abstract def Update(opts: dict<any>)
endclass

class Progress extends Notification
	static const pbar_filled: string = pbar_filled
	static const pbar_empty: string = pbar_empty
	static const width: number = pbar_width

	var p: float
	var show_frame: bool = true

	def new(winid: number, msg: string, prefix: string = "", subprefix: string = "")
		this.winid = winid
		this.msg = msg
		this.prefix = prefix
		this.subprefix = subprefix
		this.p = 0.0
		this.kind = NotificationKind.Progress
	enddef

	def Message(): string
		return this.msg
	enddef

	def FixedPrefix(): string
		const frame = this.Frame()
		return empty(frame) ? this.PrefixText() : frame .. "  " .. this.PrefixText()
	enddef

	def Formatted(): string
		return this.FixedPrefix() .. this.Message()
	enddef

	def Frame(): string
		if !this.show_frame
			return ""
		endif

		const filled_len = float2nr(trunc(this.p * Progress.width))
		const empty_len = Progress.width - filled_len
		return repeat(pbar_filled, filled_len) .. repeat(pbar_empty, empty_len)
	enddef

	def FrameOff()
		this.show_frame = false
	enddef

	def FrameOn()
		this.show_frame = true
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
	var show_frame: bool = true

	def new(winid: number, msg: string, prefix: string = "", subprefix: string = "")
		this.winid = winid
		this.msg = msg
		this.prefix = prefix
		this.subprefix = subprefix
		this.i = 0
		this.timer_id = this.Spin()
		this.kind = NotificationKind.Spinner
	enddef

	def Spin(): number
		return timer_start(100, (t) => AnimateSpinner(this, t), {repeat: -1})
	enddef

	def Message(): string
		return this.msg
	enddef

	def FixedPrefix(): string
		const frame = this.Frame()
		return empty(frame) ? this.PrefixText() : frame .. " " .. this.PrefixText()
	enddef

	def Formatted(): string
		return this.FixedPrefix() .. this.Message()
	enddef

	def Frame(): string
		return this.show_frame ? Spinner.frames[this.i] : ""
	enddef

	def FrameOff()
		this.show_frame = false
	enddef

	def FrameOn()
		this.show_frame = true
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
	var show_frame: bool = false

	def new(winid: number, msg: string, prefix: string = "", subprefix: string = "")
		this.winid = winid
		this.msg = msg
		this.prefix = prefix
		this.subprefix = subprefix
		this.kind = NotificationKind.Basic
	enddef

	def Message(): string
		return this.msg
	enddef

	def FrameOff()
	enddef

	def FrameOn()
	enddef

	def Frame(): string
		return ""
	enddef

	def FixedPrefix(): string
		return this.PrefixText()
	enddef

	def Formatted(): string
		return this.FixedPrefix() .. this.Message()
	enddef

	def Update(opts: dict<any>)
	enddef
endclass

class NotificationManager
	static const Instance = NotificationManager.new()

	var active_spinners: dict<Spinner>
	var active_pbars: dict<Progress>
	var active_basic: dict<Basic>
	var active_notifs: list<number> = []

	# History Tracking
	var history: list<string> = []
	var notif_texts: dict<string> = {} # winid (string) -> latest message text
	const time_format = "%H:%M:%S"
	var history_limit: number = 100

	def new()
	enddef
	
	def UpdateLatestMessage(winid: number, msg: string)
		const id_str = string(winid)
		this.notif_texts[id_str] = msg
	enddef

	def LogHistory(winid: number)
		const id_str = string(winid)
        const time_str = strftime(this.time_format)
        add(this.history, printf("[%s] %s", time_str, this.notif_texts[id_str]))

        # Keep history to a maximum of `history_limit` entries to save memory
        if len(this.history) > this.history_limit
            remove(this.history, 0)
        endif
	enddef

	def GetHistory(): list<string>
		return this.history->deepcopy()
	enddef

	def Register(notif: Notification)
		const id_str = string(notif.winid)
		if index(this.active_notifs, notif.winid) == -1
			add(this.active_notifs, notif.winid)
		endif

		if notif.Kind() == NotificationKind.Spinner
			this.active_spinners[id_str] = <Spinner>notif
		elseif notif.Kind() == NotificationKind.Progress
			this.active_pbars[id_str] = <Progress>notif
		elseif notif.Kind() == NotificationKind.Basic
			this.active_basic[id_str] = <Basic>notif
		endif
	enddef

	def GetNotificationBy(winid: number): Notification
		const id_str = string(winid)
		if has_key(this.active_spinners, id_str)
			return this.active_spinners[id_str]
		elseif has_key(this.active_pbars, id_str)
			return this.active_pbars[id_str]
		elseif has_key(this.active_basic, id_str)
			return this.active_basic[id_str]
		endif

		throw error.Error.InvalidNotificationId.Format(
			$"no notification with id {winid}"
		)
	enddef

	def InCache(winid: number, cache: dict<Notification>): bool
		const id_str = string(winid)
		return has_key(cache, id_str)
	enddef

	def IsActiveSpinnerBy(winid: number): bool
		return this.InCache(winid, this.active_spinners)
	enddef

	def IsActiveProgressBy(winid: number): bool
		return this.InCache(winid, this.active_pbars)
	enddef

	def IsActiveBasicBy(winid: number): bool
		return this.InCache(winid, this.active_basic)
	enddef

	def IsActiveBy(winid: number): bool
		return this.IsActiveSpinnerBy(winid) 
			|| this.IsActiveProgressBy(winid)
			|| this.IsActiveBasicBy(winid)
	enddef

	def IsActive(notif: Notification): bool
		return this.IsActiveBy(notif.winid)
	enddef

	def GetActive(): list<number>
		return this.active_notifs->deepcopy()
	enddef

	def RemoveBy(winid: number)
		const id_str = string(winid)
		const idx = index(this.active_notifs, winid)
		if idx > -1
			remove(this.active_notifs, idx)
		endif

		if has_key(this.active_spinners, id_str)
			remove(this.active_spinners, id_str)
		elseif has_key(this.active_pbars, id_str)
			remove(this.active_pbars, id_str)
		elseif has_key(this.active_basic, id_str)
			remove(this.active_basic, id_str)
		endif

		if has_key(this.notif_texts, id_str)
			this.notif_texts->remove(id_str)
		endif
	enddef

	def DismissBy(winid: number)
		const id_str = string(winid)
		if this.IsActiveBy(winid)
			popup_close(winid)
			this.RemoveBy(winid)
		endif
	enddef

	def Dismiss(notif: Notification)
		if this.IsActive(notif)
			popup_close(notif.winid)
			this.RemoveBy(notif.winid)
		endif
	enddef

	def DismissAll()
		for notif in values(this.active_spinners)
			this.Dismiss(notif)
		endfor
		for notif in values(this.active_pbars)
			this.Dismiss(notif)
		endfor
		for notif in values(this.active_basic)
			this.Dismiss(notif)
		endfor
	enddef

	def UpdatePositions()
		var current_line = 0
		var is_bottom = position =~# '^bottom'

		if is_bottom
			current_line = &lines - &cmdheight - 1
		else
			current_line = &showtabline > 0 ? 2 : 1
		endif

		for winid in this.active_notifs
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
endclass

# ── Highlight Groups & Text Properties ───────────────────────────────────
hi def link NotifyRightArrow Function
hi def link NotifySuccess String
hi def link NotifyError Error
hi def link NotifyWarning WarningMsg
hi def link NotifyInfo Question
hi def link NotifyPrefix Identifier
hi def link NotifySubPrefix Type
hi def link NotifyProgressBar Function
hi def link NotifySpinner PreCondit
hi def link NotifyMessage Normal

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
InitProp("notify_prefix", "NotifyPrefix")
InitProp("notify_subprefix", "NotifySubPrefix")
InitProp("notify_progress_bar", "NotifyProgressBar")
InitProp("notify_spinner", "NotifySpinner")
InitProp("notify_message", "NotifyMessage")

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

def AddFrameHighlight(winid: number, bufnr: number, linenr: number, text: string)
	if !NotificationManager.Instance.IsActiveBy(winid)
		return
	endif

	const notif = NotificationManager.Instance.GetNotificationBy(winid)
	const frame_len = strcharlen(notif.Frame())
	if frame_len == 0
		return
	endif

	var prop_type = ""
	if notif.Kind() == NotificationKind.Progress
		prop_type = "notify_progress_bar"
	elseif notif.Kind() == NotificationKind.Spinner
		prop_type = "notify_spinner"
	endif

	AddHighlightChars(bufnr, linenr, text, 0, min([frame_len, strcharlen(text)]), prop_type)
enddef

def AddMessageHighlight(winid: number, bufnr: number, linenr: number, text: string)
	if !NotificationManager.Instance.IsActiveBy(winid)
		return
	endif

	const notif = NotificationManager.Instance.GetNotificationBy(winid)
	const start_char = strcharlen(notif.FixedPrefix())
	AddHighlightChars(bufnr, linenr, text, start_char, strcharlen(text), "notify_message")
enddef

def AddPrefixHighlights(winid: number, bufnr: number, linenr: number, text: string)
	if !NotificationManager.Instance.IsActiveBy(winid)
		return
	endif

	const notif = NotificationManager.Instance.GetNotificationBy(winid)
	const text_len = strcharlen(text)
	var start_char = strcharlen(notif.FixedPrefix()) - strcharlen(notif.PrefixText())

	if !empty(notif.prefix)
		const end_char = start_char + strcharlen(notif.prefix)
		AddHighlightChars(bufnr, linenr, text, start_char, min([end_char, text_len]), "notify_prefix")
		start_char = end_char + 1
	endif

	if !empty(notif.subprefix)
		const end_char = start_char + strcharlen(notif.subprefix)
		AddHighlightChars(bufnr, linenr, text, start_char, min([end_char, text_len]), "notify_subprefix")
	endif
enddef

abstract class NotificationTextStrategy
	def Wrap(): bool
		return false
	enddef

	def CanAnimate(msg: string, fixed_prefix: string = ''): bool
		return false
	enddef

	def Start(winid: number, msg: string, fixed_prefix: string = '')
	enddef

	def Stop(winid: number)
	enddef

	abstract def Render(msg: string, fixed_prefix: string = ''): string
endclass

class WrapNotificationTextStrategy extends NotificationTextStrategy
	def Wrap(): bool
		return true
	enddef

	def Render(msg: string, fixed_prefix: string = ''): string
		return fixed_prefix .. msg
	enddef
endclass

class TruncateNotificationTextStrategy extends NotificationTextStrategy
	def Render(msg: string, fixed_prefix: string = ''): string
		const text = fixed_prefix .. msg
		if strcharlen(text) <= GetMaxWidth()
			return text
		endif

		const width = GetMaxWidth()
		if has('multi_byte')
			return strcharpart(text, 0, width - 1) .. "…"
		elseif width > 3
			return strcharpart(text, 0, width - 3) .. "..."
		endif
		return strcharpart(text, 0, width)
	enddef
endclass

class CarouselNotificationTextStrategy extends NotificationTextStrategy
	var active: dict<number> = {}
	var msgs: dict<string> = {}
	var prefixes: dict<string> = {}
	var idxs: dict<number> = {}

	def CanAnimate(msg: string, fixed_prefix: string = ''): bool
		return strcharlen(fixed_prefix .. msg) > GetMaxWidth()
	enddef

	def CycleLen(msg: string): number
		return strcharlen(msg) + 3
	enddef

	def Frame(msg: string, idx: number, fixed_prefix: string = ''): string
		const width = GetMaxWidth()
		const body_width = width - strcharlen(fixed_prefix)
		if width <= 0 || strcharlen(fixed_prefix .. msg) <= width
			return fixed_prefix .. msg
		elseif body_width <= 0
			return strcharpart(fixed_prefix, 0, width)
		endif

		const gap = '   '
		const cycle_len = this.CycleLen(msg)
		const start = idx % cycle_len
		const tape = msg .. gap .. msg
		var frame = strcharpart(tape, start, body_width)
		const missing = body_width - strcharlen(frame)
		if missing > 0
			frame ..= strcharpart(tape, 0, missing)
		endif
		return fixed_prefix .. frame
	enddef

	def Render(msg: string, fixed_prefix: string = ''): string
		return this.Frame(msg, 0, fixed_prefix)
	enddef

	def Start(winid: number, msg: string, fixed_prefix: string = '')
		const id_str = string(winid)
		this.msgs[id_str] = msg
		this.prefixes[id_str] = fixed_prefix
		if !has_key(this.idxs, id_str) | this.idxs[id_str] = 0 | endif

		if !has_key(this.active, id_str)
			this.active[id_str] = timer_start(
				GetCarouselInterval(),
				(t) => AnimateCarousel(winid, t),
				{repeat: -1}
			)
		endif
	enddef

	def Stop(winid: number)
		const id_str = string(winid)
		if has_key(this.active, id_str)
			timer_stop(this.active[id_str])
			remove(this.active, id_str)
		endif
		if has_key(this.msgs, id_str) | remove(this.msgs, id_str) | endif
		if has_key(this.prefixes, id_str) | remove(this.prefixes, id_str) | endif
		if has_key(this.idxs, id_str) | remove(this.idxs, id_str) | endif
	enddef

	def Animate(winid: number, timer_id: number)
		const id_str = string(winid)
		if !NotificationManager.Instance.IsActiveBy(winid) || !has_key(this.msgs, id_str)
			timer_stop(timer_id)
			return
		endif

		this.idxs[id_str] = (this.idxs[id_str] + 1) % this.CycleLen(this.msgs[id_str])
		popup_settext(
			winid,
			this.Frame(
				this.msgs[id_str],
				this.idxs[id_str],
				get(this.prefixes, id_str, '')
			)
		)
		ApplyHighlight(winid)
	enddef
endclass

const wrap_text_strategy = WrapNotificationTextStrategy.new()
const truncate_text_strategy = TruncateNotificationTextStrategy.new()
const carousel_text_strategy = CarouselNotificationTextStrategy.new()

def GetTextStrategy(): NotificationTextStrategy
	const overflow = GetOverflowMode()
	if overflow ==# 'wrap'
		return wrap_text_strategy
	elseif overflow ==# 'carousel'
		return carousel_text_strategy
	endif
	return truncate_text_strategy
enddef

def StopTextRendering(winid: number)
	wrap_text_strategy.Stop(winid)
	truncate_text_strategy.Stop(winid)
	carousel_text_strategy.Stop(winid)
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

	const strategy = GetTextStrategy()
	if strategy.CanAnimate(in_msg, fixed_prefix)
		strategy.Start(winid, in_msg, fixed_prefix)
		popup_settext(winid, strategy.Render(in_msg, fixed_prefix))
		ApplyHighlight(winid)
	else
		StopTextRendering(winid)
		popup_settext(winid, strategy.Render(in_msg, fixed_prefix))
		ApplyHighlight(winid)
	endif

	if update_history
		const msg = fixed_prefix .. in_msg
		NotificationManager.Instance.UpdateLatestMessage(winid, msg)
	endif
	if update_positions
		NotificationManager.Instance.UpdatePositions()
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

	AddMessageHighlight(winid, bufnr, linenr, text)
	AddFrameHighlight(winid, bufnr, linenr, text)
	AddPrefixHighlights(winid, bufnr, linenr, text)

    # Find the FIRST occurrence of any of the target symbols.
    # In ASCII mode, we are more restrictive to avoid highlighting characters in words.
    var pattern = has('multi_byte') ? '[✓×!?→]' : '\v%(^|[ ])\zs(\=|x|!|\?|-\>)\ze%([ ]|$)'
    var match_info = matchstrpos(text, pattern)
    var start_byte = match_info[1]
    var end_byte = match_info[2]

    # If no special character is found, only prefix highlights apply.
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

def OnPopupClose(winid: number, result: any)
	# Clean up timer if this notification is carouseling
	StopTextRendering(winid)

    # Remove from active list and restack
	const is_active = NotificationManager.Instance.IsActiveBy(winid)
    if is_active
		NotificationManager.Instance.LogHistory(winid)
		NotificationManager.Instance.GetNotificationBy(winid).Stop()
		NotificationManager.Instance.RemoveBy(winid)
		NotificationManager.Instance.UpdatePositions()
    endif
enddef

def AnimateSpinner(spinner: Spinner, timer_id: number)
    if !NotificationManager.Instance.IsActiveBy(spinner.winid)
		spinner.Stop()
        return
    endif
    
	# Do not update history for intermediate animation frames.
	spinner.Update({})
    SetDisplayText(spinner.winid, spinner.Message(), false, false, spinner.FixedPrefix())
enddef

def AnimateCarousel(winid: number, timer_id: number)
	carousel_text_strategy.Animate(winid, timer_id)
enddef

def CreatePopup(in_msg: string, opts: NotificationOptions): number
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
		wrap: GetTextStrategy().Wrap(),
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
    
    extend(default_opts, opts.PopupOptions())

	var msg = GetTextStrategy().Render(in_msg)

    var winid: number
    if default_opts.persistent
        # Use popup_create for persistent popups that don't close on keypress
        winid = popup_create(msg, default_opts)
    else
        # Use popup_notification for ephemeral messages that close on keypress
        winid = popup_notification(msg, default_opts)
    endif

    return winid
enddef

# ── Public API ───────────────────────────────────────────────────────────

export def Send(in_msg: string, opts: dict<any> = {}): number
	const notif_opts = NotificationOptions.new(opts)
	const winid = CreatePopup(in_msg, notif_opts)
	const notif = Basic.new(
		winid,
		in_msg,
		notif_opts.prefix,
		notif_opts.subprefix,
	)
	NotificationManager.Instance.Register(notif)
	SetDisplayText(winid, notif.Message(), true, false, notif.FixedPrefix())
	NotificationManager.Instance.UpdatePositions()
	return winid
enddef

export def Modify(winid: number, in_msg: string, opts: dict<any> = {})
    if win_gettype(winid) == 'popup'
		const notif_opts = NotificationOptions.new(opts)
		final notif = NotificationManager.Instance.GetNotificationBy(winid)
		notif.SetMessage(in_msg)

		if has_key(opts, 'frame') 
			if opts.frame
				notif.FrameOn()
			else
				notif.FrameOff()
			endif
		endif
		if notif_opts.has_prefix
			notif.SetPrefix(notif_opts.prefix)
		endif
		if notif_opts.has_subprefix
			notif.SetSubPrefix(notif_opts.subprefix)
		endif

		SetDisplayText(winid, notif.Message(), true, true, notif.FixedPrefix())
    endif
enddef

export def Dismiss(winid: number, after: number = 0): number
	if after == 0
		NotificationManager.Instance.DismissBy(winid)
		return -1
	else
		return timer_start(after, (_) => NotificationManager.Instance.DismissBy(winid))
	endif
enddef

export def DismissAll()
	NotificationManager.Instance.DismissAll()
enddef

export def StartLoading(msg: string, opts: dict<any> = {}): number
	var notif_opts = NotificationOptions.new(opts)
	notif_opts.SetPersistent()
    var winid = CreatePopup(msg, notif_opts)
	var spinner = Spinner.new(
		winid,
		msg,
		notif_opts.prefix,
		notif_opts.subprefix,
	)
    
	NotificationManager.Instance.Register(spinner)
	SetDisplayText(winid, spinner.Message(), true, false, spinner.FixedPrefix())
	NotificationManager.Instance.UpdatePositions()
    
    return winid
enddef

export def StopLoading(
	winid: number,
	final_msg: string = "",
	frame: bool=false,
	after: number = 0,
): number
    if final_msg != ""
		Modify(winid, final_msg, {frame: frame})
	endif

	return Dismiss(winid, after)
enddef

export def UpdateLoading(winid: number, new_msg: string)
    # Check if this popup is actually an active spinner
	if NotificationManager.Instance.IsActiveSpinnerBy(winid)
        # Update the base message in our tracker
		var spinner = <Spinner>NotificationManager.Instance.GetNotificationBy(winid)
		spinner.SetMessage(new_msg)
        SetDisplayText(spinner.winid, spinner.Message(), true, true, spinner.FixedPrefix())
    endif
enddef

export def StartProgress(msg: string, opts: dict<any> = {}): number
	var notif_opts = NotificationOptions.new(opts)
	var bar = Progress.new(
		-1,
		msg,
		notif_opts.prefix,
		notif_opts.subprefix,
	)
    
	notif_opts.SetPersistent()
    bar.SetWinID(CreatePopup(bar.Formatted(), notif_opts))

	NotificationManager.Instance.Register(bar)
	SetDisplayText(bar.winid, bar.Message(), true, false, bar.FixedPrefix())
	NotificationManager.Instance.UpdatePositions()
	return bar.winid
enddef

export def UpdateProgress(
	winid: number,
	current: number,
	total: number,
	msg: string = "",
	opts: dict<any> = {},
)
	if !NotificationManager.Instance.IsActiveProgressBy(winid)
		return
	endif

	final pbar = <Progress>NotificationManager.Instance.GetNotificationBy(winid)

    var percentage = 0.0
    if total > 0 | percentage = (current + 0.0) / (total + 0.0) | endif
    if percentage > 1.0 | percentage = 1.0 | endif
	if percentage < 0.0 | percentage = 0.0 | endif

	pbar.Update({percentage: percentage})
	if msg != "" | pbar.SetMessage(msg) | endif
	const notif_opts = NotificationOptions.new(opts)
	if notif_opts.has_prefix
		pbar.SetPrefix(notif_opts.prefix)
	endif
	if notif_opts.has_subprefix
		pbar.SetSubPrefix(notif_opts.subprefix)
	endif
	SetDisplayText(pbar.winid, pbar.Message(), true, true, pbar.FixedPrefix())
enddef

# Opens a scratch buffer displaying past notifications
export def ShowHistory()
    if empty(NotificationManager.Instance.GetHistory())
        echo "No notifications in history."
        return
    endif
    
    # Open a 10-line split at the bottom
    execute('botright :10new')
    setlocal buftype=nofile bufhidden=wipe noswapfile
    setline(1, NotificationManager.Instance.GetHistory())

	for l in range(line("$"))
		ApplyHighlight(win_getid(), l + 1)
	endfor
    
    # Highlight the timestamps
    syntax match NotifyTime /^\[\d\d:\d\d:\d\d\]/
    hi def link NotifyTime Comment
    
    # Press 'q' to quickly close the history buffer
    nnoremap <buffer> <silent> q :bwipeout<CR>
enddef
