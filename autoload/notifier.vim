vim9script

# ── Configuration & State ────────────────────────────────────────────────
g:notifier_maxwidth = &columns / 2
g:notifier_wrap = true
const pbar_width = min([20, max([3, float2nr(floor(g:notifier_maxwidth / 3))])])

export var position: string = "top-right"

var active_notifs: list<number> = []

# Spinner State Tracking
var spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
var active_spinners: dict<number> = {} 
var spinner_msgs: dict<string> = {}    
var spinner_idxs: dict<number> = {}    

# History Tracking
var history: list<string> = []
var notif_texts: dict<string> = {} # winid (string) -> latest message text

# ── Highlight Groups & Text Properties ───────────────────────────────────
hi def link NotifyRightArrow Function
hi def link NotifySuccess String
hi def link NotifyError Error
hi def link NotifyWarning WarningMsg
hi def link NotifyInfo Question

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

# ── Internal Helpers ─────────────────────────────────────────────────────
def FormatMsg(msg: string, include_ellipsis: bool): string
	if g:notifier_wrap
		return msg
	elseif strcharlen(msg) > g:notifier_maxwidth # truncate
		if include_ellipsis && has('multi_byte')
			return msg[ : g:notifier_maxwidth - 2] .. "…"
		elseif include_ellipsis
			return msg[ : g:notifier_maxwidth - 4] .. "..."
		else
			return msg[ : g:notifier_maxwidth - 1]
		endif
	endif

	return msg
enddef

def ApplyHighlight(winid: number, text: string)
    var bufnr = winbufnr(winid)
    if bufnr == -1 || empty(text) | return | endif

    # Clear any existing highlights on the first line
    prop_clear(1, 1, {bufnr: bufnr})

    # Find the FIRST occurrence of any of the target symbols
    var match_info = matchstrpos(text, '[✓×!?→]')
    var start_byte = match_info[1]
    var end_byte = match_info[2]

    # If no special character is found, we just exit
    if start_byte == -1
        return
    endif

    var matched_char = match_info[0]
    var prop_type = ""

    if matched_char ==# "✓"
        prop_type = "notify_success"
    elseif matched_char ==# "×"
        prop_type = "notify_error"
    elseif matched_char ==# "!"
        prop_type = "notify_warning"
    elseif matched_char ==# "?"
        prop_type = "notify_info"
    elseif matched_char ==# "→"
        prop_type = "notify_right_arrow"
    endif

    if prop_type != ""
        # Columns are 1-based in Vim, so we add 1 to start_byte
        prop_add(1, start_byte + 1, { 
            length: end_byte - start_byte, 
            type: prop_type,
            bufnr: bufnr
        })
    endif
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

    # 3. Remove from active list and restack
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
    
    var full_msg = FormatMsg(frame .. " " .. spinner_msgs[id_str], true)
    # Use popup_settext directly here so we don't spam the history log 
    # with intermediate animation frames via Modify()
    popup_settext(winid, full_msg)
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
		wrap: true,
		maxwidth: !empty(g:notifier_maxwidth) ? g:notifier_maxwidth : &columns,
        highlight: 'Normal',
        padding: [0, 1, 0, 1],
        borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        border: [1, 1, 1, 1, 1, 1, 1, 1],
        tabpage: -1,
        zindex: 100,
        time: 0,
        persistent: false,
        callback: OnPopupClose
    }
    
    extend(default_opts, opts)

	var msg = FormatMsg(in_msg, true)

    var winid: number
    if default_opts.persistent
        # Use popup_create for persistent popups that don't close on keypress
        winid = popup_create(msg, default_opts)
    else
        # Use popup_notification for ephemeral messages that close on keypress
        winid = popup_notification(msg, default_opts)
    endif
    ApplyHighlight(winid, msg)
    
    # Track the latest message for the history log
    notif_texts[string(winid)] = in_msg
    
    add(active_notifs, winid)
    UpdatePositions()
    
    return winid
enddef

export def Modify(winid: number, in_msg: string)
    if win_gettype(winid) == 'popup'

		var msg = FormatMsg(in_msg, true)

        popup_settext(winid, msg)
        ApplyHighlight(winid, msg)
        notif_texts[string(winid)] = in_msg # Update the history tracker
        UpdatePositions() 
    endif
enddef

export def Dismiss(winid: number)
    if win_gettype(winid) == 'popup'
        popup_close(winid)
    endif
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
    var empty_bar = repeat('▒', pbar_width)
    
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
	# once we reach 100%. With round, we will fill the bar when we are ≥95%
	# complete
    var filled_len = float2nr(trunc(percentage * pbar_width))
    var empty_len = pbar_width - filled_len
    var bar = repeat('█', filled_len) .. repeat('▒', empty_len)
    
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
    
    # Optional: Highlight the timestamps
    syntax match NotifyTime /^\[\d\d:\d\d:\d\d\]/
    hi def link NotifyTime Comment
    
    # Press 'q' to quickly close the history buffer
    nnoremap <buffer> <silent> q :bwipeout<CR>
enddef
