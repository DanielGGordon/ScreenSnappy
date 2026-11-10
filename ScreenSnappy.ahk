#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
; ScreenSnappy: fast screenshots with an arrow and a black box, nothing else.
;   PrtSc or Win+Shift+S   drag to capture a region, or click a window
;   Alt+PrtSc              capture the active window
; Every capture and every edit goes on the clipboard straight away.

DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")  ; per-monitor v2: work in real pixels
GdipStartup()
InitTray()

global Wins := Map()  ; hwnd -> Picker or Editor that handles that window's messages
for msg, name in Map(0x0005, "OnSize", 0x000F, "OnPaint", 0x0014, "OnEraseBkgnd", 0x0020, "OnSetCursor"
        , 0x0024, "OnGetMinMaxInfo", 0x0083, "OnNcCalcSize", 0x0084, "OnNcHitTest", 0x0200, "OnMouseMove"
        , 0x0201, "OnLButtonDown", 0x0202, "OnLButtonUp", 0x0205, "OnRButtonUp", 0x020A, "OnMouseWheel"
        , 0x02A3, "OnMouseLeave")
    OnMessage(msg, Dispatch.Bind(name))

ArrowColor := 0xFFE8231F  ; ARGB
ArrowWidth := 6           ; pixels of the captured image
Theme := AppTheme()       ; editor chrome, in Windows' light or dark app mode
Accent := AccentColor()   ; the user's accent colour, ARGB: the overlay's selection frame

$PrintScreen::Picker.Start()
#+s::Picker.Start()
!PrintScreen::CaptureActiveWindow()

#HotIf Picker.cur
Esc::Picker.cur.Close()
#HotIf Editor.Active()
a::Editor.Active().SetTool("arrow")
b::Editor.Active().SetTool("box")
^z::Editor.Active().Undo()
^c::Editor.Active().Copy()
^s::Editor.Active().Save()
Esc::Editor.Active().Close()
#HotIf

Dispatch(name, wParam, lParam, msg, hwnd) {
    if (obj := Wins.Get(hwnd, 0)) && obj.HasMethod(name)
        return obj.%name%(wParam, lParam)
}

; ---------------------------------------------------------------- capture

; Full-screen overlay showing a frozen, dimmed copy of the screen. Hovering
; highlights the window under the cursor; click takes it, drag takes a region.
class Picker {
    static cur := 0

    static Start() {
        if !Picker.cur
            Picker.cur := Picker()
    }

    __New() {
        this.x := SysGet(76), this.y := SysGet(77), this.w := SysGet(78), this.h := SysGet(79)
        this.shot := CaptureScreen(this.x, this.y, this.w, this.h)
        this.wins := VisibleWindows()  ; before the overlay exists, so it is not in the list
        this.dim := Canvas(this.w, this.h)
        this.dim.Blit(0, 0, this.w, this.h, this.shot.dc, 0, 0)
        g := this.dim.Graphics()
        GFill(g, 0x8C000000, 0, 0, this.w, this.h)
        GdipDelete(g)
        this.back := Canvas(this.w, this.h)

        DllCall("GetCursorPos", "int64*", &pt := 0)
        this.mx := (pt << 32 >> 32) - this.x, this.my := (pt >> 32) - this.y
        this.down := false
        this.drawn := this.Dirty(this.Target())

        this.gui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
        this.hwnd := this.gui.Hwnd
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", this.hwnd, "uint", 3, "int*", 1, "uint", 4)  ; no fade-in
        Wins[this.hwnd] := this
        this.gui.Show(Format("x{} y{} w{} h{}", this.x, this.y, this.w, this.h))
    }

    ; The rectangle (overlay coordinates) a mouse-up would capture now, or 0.
    Target() {
        if this.down
            return ClipRect(Min(this.sx, this.mx), Min(this.sy, this.my)
                , Abs(this.mx - this.sx), Abs(this.my - this.sy), this.w, this.h)
        px := this.mx + this.x, py := this.my + this.y
        for r in this.wins
            if px >= r.l && px < r.r && py >= r.t && py < r.b
                return ClipRect(r.l - this.x, r.t - this.y, r.r - r.l, r.b - r.t, this.w, this.h)
        return 0
    }

    ; Area to repaint around a target: its border and size label sit outside it.
    Dirty(rc) {
        static m := Round(40 * A_ScreenDPI / 96), mr := Round(160 * A_ScreenDPI / 96)
        return rc ? [rc.x - m, rc.y - m, rc.x + rc.w + mr, rc.y + rc.h + m] : 0
    }

    Refresh() {
        now := this.Dirty(this.Target())
        old := this.drawn
        if old && now && old[1] = now[1] && old[2] = now[2] && old[3] = now[3] && old[4] = now[4]
            return
        for r in [old, now]
            if r
                Invalidate(this.hwnd, r*)
        this.drawn := now
    }

    OnPaint(*) {
        hdc := StartPaint(this.hwnd, &l, &t, &r, &b)
        this.back.Blit(l, t, r - l, b - t, this.dim.dc, l, t)
        if rc := this.Target() {
            this.back.Blit(rc.x, rc.y, rc.w, rc.h, this.shot.dc, rc.x, rc.y)
            g := this.back.Graphics(false)
            GFrame(g, Accent, 2, rc.x - 1, rc.y - 1, rc.w + 2, rc.h + 2)
            GdipDelete(g)
            DrawLabel(this.back.dc, rc.w " × " rc.h, rc.x, rc.y)
        }
        MonitorGet(MonitorGetPrimary(), &ml, &mt, &mr)
        DrawLabel(this.back.dc, "Drag a region or click a window", (ml + mr) // 2 - this.x
            , mt - this.y + Round(16 * A_ScreenDPI / 96), true, "Esc cancels")
        Blt(hdc, l, t, r - l, b - t, this.back.dc, l, t)
        DllCall("ReleaseDC", "ptr", this.hwnd, "ptr", hdc)
        return 0
    }

    OnEraseBkgnd(*) => 1

    OnSetCursor(*) {
        DllCall("SetCursor", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32515, "ptr"))  ; IDC_CROSS
        return 1
    }

    OnMouseMove(wp, lp) {
        this.mx := lp << 48 >> 48, this.my := lp << 32 >> 48
        this.Refresh()
        return 0
    }

    OnLButtonDown(wp, lp) {
        this.down := true
        this.sx := this.mx := lp << 48 >> 48, this.sy := this.my := lp << 32 >> 48
        DllCall("SetCapture", "ptr", this.hwnd)
        this.Refresh()
        return 0
    }

    OnLButtonUp(wp, lp) {
        if !this.down
            return 0
        this.mx := lp << 48 >> 48, this.my := lp << 32 >> 48
        DllCall("ReleaseCapture")
        if Abs(this.mx - this.sx) < 4 && Abs(this.my - this.sy) < 4
            this.down := false  ; a click, not a drag: take the window under the cursor
        rc := this.Target(), shot := this.shot
        this.Close()
        if rc {
            img := Canvas(rc.w, rc.h)
            img.Blit(0, 0, rc.w, rc.h, shot.dc, rc.x, rc.y)
            Editor.Open(img, this.x + rc.x + rc.w // 2, this.y + rc.y + rc.h // 2)
        }
        return 0
    }

    OnRButtonUp(*) {
        this.Close()
        return 0
    }

    Close() {
        Wins.Delete(this.hwnd)
        this.gui.Destroy()
        this.shot := this.dim := this.back := 0
        Picker.cur := 0
    }
}

CaptureActiveWindow() {
    if Picker.cur || !(hwnd := WinExist("A"))
        return
    r := WindowRect(hwnd)
    vx := SysGet(76), vy := SysGet(77)
    if !rc := ClipRect(r.l - vx, r.t - vy, r.r - r.l, r.b - r.t, SysGet(78), SysGet(79))
        return
    Editor.Open(CaptureScreen(vx + rc.x, vy + rc.y, rc.w, rc.h), vx + rc.x + rc.w // 2, vy + rc.y + rc.h // 2)
}

; Visible top-level windows in z-order (topmost first) as {l, t, r, b} screen rects.
VisibleWindows() {
    list := []
    for hwnd in WinGetList() {
        try {
            if DllCall("IsIconic", "ptr", hwnd) || WinGetExStyle(hwnd) & 0x20  ; minimized, click-through
                continue
            DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &cloaked := 0, "uint", 4)
            if cloaked  ; on another virtual desktop, or a suspended UWP app
                continue
            r := WindowRect(hwnd)
            if r.r - r.l > 1 && r.b - r.t > 1
                list.Push(r)
        }
    }
    return list
}

; The window's visible bounds, without the invisible resize border Windows 10/11 adds.
WindowRect(hwnd) {
    rc := Buffer(16, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9, "ptr", rc, "uint", 16) != 0
        DllCall("GetWindowRect", "ptr", hwnd, "ptr", rc)
    return {l: NumGet(rc, 0, "int"), t: NumGet(rc, 4, "int"), r: NumGet(rc, 8, "int"), b: NumGet(rc, 12, "int")}
}

CaptureScreen(x, y, w, h) {
    c := Canvas(w, h)
    sdc := DllCall("GetDC", "ptr", 0, "ptr")
    Blt(c.dc, 0, 0, w, h, sdc, x, y, 0x40CC0020)  ; SRCCOPY | CAPTUREBLT
    DllCall("ReleaseDC", "ptr", 0, "ptr", sdc)
    return c
}

; ---------------------------------------------------------------- editor

; The one editor window. It draws its own title bar: a header with the tools,
; the capture on a calm canvas, and a strip of recent captures along the bottom.
class Editor {
    static cur := 0

    static Active() {
        e := Wins.Get(WinExist("A"), 0)
        return e is Editor ? e : 0
    }

    ; Shows a fresh capture, in the open editor if there is one.
    static Open(img, cx, cy) {
        if Editor.cur
            Editor.cur.Add(img)
        else
            Editor.cur := Editor(img, cx, cy)
    }

    __New(img, cx, cy) {
        dpi := this.dpi := A_ScreenDPI / 96
        this.m := Round(16 * dpi)    ; room around the image
        this.top := Round(48 * dpi)  ; header
        this.sh := Round(96 * dpi)   ; strip of recent captures
        this.tw := Round(96 * dpi), this.th := Round(64 * dpi), this.tgap := Round(10 * dpi)  ; thumbnail slot
        this.minW := Round(640 * dpi), this.minH := this.top + this.sh + 2 * this.m + Round(120 * dpi)
        this.fx := this.fb := 0      ; window frame beside and below the client area
        this.cw := this.ch := 0, this.img := this.out := this.cap := 0, this.marks := [], this.pending := 0
        this.tool := "arrow", this.sub := this.size := "", this.hot := this.hit := this.hotThumb := 0, this.scroll := 0
        this.dirty := false, this.inHistory := false
        this.flushFn := (*) => this.Flush(), this.tipFn := (*) => this.ShowTip()
        this.Layout()
        History.tw := this.tw, History.th := this.th, History.editor := this

        g := this.gui := Gui("+Resize -DPIScale")
        g.BackColor := Format("{:06X}", Theme.surface)
        g.OnEvent("Close", (*) => this.Close())
        this.hwnd := g.Hwnd
        Wins[this.hwnd] := this
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", this.hwnd, "uint", 20, "int*", Theme.dark, "uint", 4)  ; DWMWA_USE_IMMERSIVE_DARK_MODE
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", this.hwnd, "uint", 33, "int*", 2, "uint", 4)  ; DWMWA_WINDOW_CORNER_PREFERENCE: round
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", this.hwnd, "uint", 34, "uint*", Bgr(Theme.border), "uint", 4)  ; DWMWA_BORDER_COLOR
        ; Apply OnNcCalcSize, then measure the frame that is left beside and below the client area.
        DllCall("SetWindowPos", "ptr", this.hwnd, "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x37)  ; FRAMECHANGED | NOSIZE | NOMOVE | NOZORDER | NOACTIVATE
        DllCall("GetWindowRect", "ptr", this.hwnd, "ptr", wr := Buffer(16))
        DllCall("GetClientRect", "ptr", this.hwnd, "ptr", cr := Buffer(16))
        this.fx := (NumGet(wr, 8, "int") - NumGet(wr, 0, "int") - NumGet(cr, 8, "int")) // 2
        this.fb := NumGet(wr, 12, "int") - NumGet(wr, 4, "int") - NumGet(cr, 12, "int")

        mon := MonitorAt(cx, cy)
        sz := this.Ideal(img, mon)
        ww := sz.w + 2 * this.fx, wh := sz.h + this.fb
        DllCall("SetWindowPos", "ptr", this.hwnd, "ptr", 0, "int", mon.l + (mon.r - mon.l - ww) // 2
            , "int", mon.t + (mon.b - mon.t - wh) // 2, "int", ww, "int", wh, "uint", 0x14)  ; NOZORDER | NOACTIVATE
        this.Set(History.Add(img), img, true)
        DllCall("ShowWindow", "ptr", this.hwnd, "int", 1)  ; SW_SHOWNORMAL
        SetTimer((*) => History.Start(), -50)              ; older captures and their thumbnails, once we are up
    }

    ; Client size that shows img at up to 1:1 on the monitor, within the minimum size.
    Ideal(img, mon) {
        maxW := mon.r - mon.l - Round(40 * this.dpi) - 2 * this.fx, maxH := mon.b - mon.t - Round(40 * this.dpi) - this.fb
        s := Min(1, (maxW - 2 * this.m) / img.w, (maxH - this.top - this.sh - 2 * this.m) / img.h)
        return {w: Clamp(Round(img.w * s) + 2 * this.m, this.minW, maxW)
            , h: Clamp(this.top + Round(img.h * s) + 2 * this.m + this.sh, this.minH, maxH)}
    }

    ; A new capture: it joins the strip and replaces what is shown. The window
    ; grows if the capture needs it, and never shrinks.
    Add(img) {
        this.Flush()
        cap := History.Add(img)
        if !DllCall("IsZoomed", "ptr", this.hwnd) {
            WinGetPos(&x, &y, &ww, &wh, this.hwnd)
            mon := MonitorAt(x + ww // 2, y + wh // 2)
            sz := this.Ideal(img, mon)
            nw := Max(ww, sz.w + 2 * this.fx), nh := Max(wh, sz.h + this.fb)
            if nw != ww || nh != wh
                DllCall("SetWindowPos", "ptr", this.hwnd, "ptr", 0, "int", Clamp(x, mon.l, Max(mon.l, mon.r - nw))
                    , "int", Clamp(y, mon.t, Max(mon.t, mon.b - nh)), "int", nw, "int", nh, "uint", 0x14)
        }
        this.scroll := 0
        this.Set(cap, img, true)
        if DllCall("IsIconic", "ptr", this.hwnd)
            DllCall("ShowWindow", "ptr", this.hwnd, "int", 9)  ; SW_RESTORE
        WinActivate(this.hwnd)
    }

    ; Shows capture cap, whose pixels are img; fresh: its PNG is still to be written.
    Set(cap, img, fresh) {
        this.cap := cap, this.img := img, this.marks := [], this.pending := 0
        this.out := Canvas(img.w, img.h)  ; img with the marks drawn on: what gets copied and saved
        this.size := Format("{} × {}", img.w, img.h), this.sub := this.size ", on the clipboard"
        this.gui.Title := "ScreenSnappy – " this.sub
        this.Relayout(this.cw, this.ch)
        CopyImage(this.out, false)
        this.inHistory := false
        this.dirty := fresh
        if fresh
            SetTimer(this.flushFn, -1)
        Invalidate(this.hwnd, 0, 0, this.cw, this.ch)
    }

    ; Opens the i-th recent capture, with its marks flattened in.
    Switch(i) {
        cap := History.caps[i]
        if cap.path = this.cap.path
            return
        this.Flush()
        if !(img := LoadPng(cap.path)) {  ; gone from the folder
            History.caps.RemoveAt(i)
            this.InvalidateStrip()
            return
        }
        this.Set(cap, img, false)
    }

    ; Writes the capture's PNG and thumbnail if the marks changed since the last time.
    Flush() {
        SetTimer(this.flushFn, 0)
        if !this.dirty
            return
        this.dirty := false
        SavePng(this.out.hbm, this.cap.path)
        this.cap.thumb := ThumbFromCanvas(this.out, this.tw, this.th)
        this.cap.fresh := false
        this.InvalidateStrip()
    }

    ; The header buttons: tools and actions in the middle, the caption buttons at
    ; the right. Their x comes from Place once the width is known.
    Layout() {
        dpi := this.dpi
        this.bw := Round((Font("icon") ? 40 : 56) * dpi), this.bh := Round(36 * dpi), this.gap := Round(4 * dpi)
        this.capW := Round(46 * dpi), this.capH := Round(32 * dpi)
        this.toolsW := 5 * this.bw + 4 * this.gap + Round(13 * dpi)  ; plus a separator after the tools
        this.buttons := [
            {tool: "arrow", cap: "", tip: "Arrow (A)", glyph: "", text: "", act: (*) => this.SetTool("arrow")},
            {tool: "box", cap: "", tip: "Box (B)", glyph: "", text: "", act: (*) => this.SetTool("box")},
            {tool: "", cap: "", tip: "Undo (Ctrl+Z)", glyph: Chr(0xE7A7), text: "Undo", act: (*) => this.Undo()},
            {tool: "", cap: "", tip: "Copy (Ctrl+C)", glyph: Chr(0xE8C8), text: "Copy", act: (*) => this.Copy()},
            {tool: "", cap: "", tip: "Save (Ctrl+S)", glyph: Chr(0xE74E), text: "Save", act: (*) => this.Save()},
            {tool: "", cap: "min", tip: "Minimize", glyph: Chr(0xE921), text: "–", act: (*) => PostMessage(0x112, 0xF020, 0, , this.hwnd)},
            {tool: "", cap: "max", tip: "Maximize", glyph: Chr(0xE922), text: "□", act: (*) => this.ToggleMax()},
            {tool: "", cap: "close", tip: "Close", glyph: Chr(0xE8BB), text: "×", act: (*) => PostMessage(0x10, 0, 0, , this.hwnd)}]
        for i, b in this.buttons {
            b.i := i, b.x := 0, b.fg := Theme.text
            b.w := b.cap ? this.capW : this.bw, b.h := b.cap ? this.capH : this.bh
            b.y := b.cap ? 0 : (this.top - this.bh) // 2
        }
    }

    ; Places the header's buttons and title for the current width.
    Place() {
        cw := this.cw, dpi := this.dpi, dc := this.bar.dc
        x := cw - 3 * this.capW
        for b in this.buttons
            if b.cap
                b.x := x, x += this.capW
        this.titleW := TextSize(dc, Font("ui"), "ScreenSnappy")[1]
        x := Clamp((cw - this.toolsW) // 2, this.m + this.titleW + Round(12 * dpi), cw - 3 * this.capW - this.m - this.toolsW)
        room := x - this.m - this.titleW - Round(20 * dpi)  ; for the subtitle: the full text, or just the size
        this.showSub := ""
        if this.sub
            for text in [this.sub, this.size]
                if !this.showSub && TextSize(dc, Font("ui"), text)[1] <= room
                    this.showSub := text
        for b in this.buttons
            if !b.cap {
                b.x := x, x += this.bw + this.gap
                if b.tool = "box"
                    this.sepX := x + Round(6 * dpi), x += Round(13 * dpi)
            }
    }

    ; Fits everything to a client size: the header, the image on its canvas, the strip.
    Relayout(cw, ch) {
        this.cw := cw, this.ch := ch
        this.bar := Canvas(cw, this.top), this.strip := Canvas(cw, this.sh)
        this.Place()
        if !this.img
            return
        m := this.m, H := ch - this.top - this.sh
        this.scale := Min(1, Max(1, cw - 2 * m) / this.img.w, Max(1, H - 2 * m) / this.img.h)
        this.vw := Max(1, Round(this.img.w * this.scale)), this.vh := Max(1, Round(this.img.h * this.scale))
        this.view := this.scale = 1 ? this.out : Canvas(this.vw, this.vh)  ; out, shrunk to fit
        this.frame := Canvas(this.vw, this.vh)                             ; view + the mark being drawn
        this.ix := (cw - this.vw) // 2, this.iy := this.top + (H - this.vh) // 2
        ; The canvas: the surface, with a soft shadow (light mode) and a faint edge under the image.
        this.back := Canvas(cw, Max(1, H))
        g := this.back.Graphics()
        GFill(g, Argb(Theme.surface), 0, 0, cw, H)
        x := this.ix, y := this.iy - this.top, w := this.vw, h := this.vh
        if !Theme.dark
            loop 8
                GRound(g, (0x30 - 6 * (A_Index - 1)) << 24, x - A_Index + 0.5, y - A_Index + 1.5
                    , w + 2 * A_Index - 1, h + 2 * A_Index - 1, A_Index + 1, 1)
        GRound(g, Theme.dark ? 0x26FFFFFF : 0x1F000000, x - 0.5, y - 0.5, w + 1, h + 1, 1, 1)
        GdipDelete(g)
        this.Render()
    }

    ; Index of the header button at client (x, y), or 0.
    ButtonAt(x, y) {
        for b in this.buttons
            if x >= b.x && x < b.x + b.w && y >= b.y && y < b.y + b.h
                return b.i
        return 0
    }

    InImage(x, y) => x >= this.ix && x < this.ix + this.vw && y >= this.iy && y < this.iy + this.vh

    ; Where the i-th thumbnail sits in the strip (its slot, until it is built).
    ThumbRect(i) {
        t := History.caps[i].thumb, w := t ? t.w : this.tw, h := t ? t.h : this.th
        sx := this.m - this.scroll + (i - 1) * (this.tw + this.tgap)
        return {x: sx + (this.tw - w) // 2, y: (this.sh - h) // 2, w: w, h: h}
    }

    ; Index of the thumbnail at strip coordinates (x, y), or 0.
    ThumbAt(x, y) {
        if x < this.m - this.scroll
            return 0
        i := (x - this.m + this.scroll) // (this.tw + this.tgap) + 1
        if i > History.caps.Length
            return 0
        t := this.ThumbRect(i), pad := Round(4 * this.dpi)
        return x >= t.x - pad && x < t.x + t.w + pad && y >= t.y - pad && y < t.y + t.h + pad ? i : 0
    }

    ScrollMax() => Max(0, History.caps.Length * (this.tw + this.tgap) - this.tgap + 2 * this.m - this.cw)

    SetTool(tool) {
        this.tool := tool
        this.InvalidateBar()
    }

    ToggleMax() => PostMessage(0x112, DllCall("IsZoomed", "ptr", this.hwnd) ? 0xF120 : 0xF030, 0, , this.hwnd)  ; SC_RESTORE : SC_MAXIMIZE

    Render() {
        this.out.Blit(0, 0, this.img.w, this.img.h, this.img.dc, 0, 0)
        if this.marks.Length {
            g := this.out.Graphics()
            for m in this.marks
                DrawMark(g, m, 1)
            GdipDelete(g)
        }
        if this.view != this.out {
            DllCall("SetStretchBltMode", "ptr", this.view.dc, "int", 4)  ; HALFTONE
            DllCall("SetBrushOrgEx", "ptr", this.view.dc, "int", 0, "int", 0, "ptr", 0)
            DllCall("StretchBlt", "ptr", this.view.dc, "int", 0, "int", 0, "int", this.vw, "int", this.vh
                , "ptr", this.out.dc, "int", 0, "int", 0, "int", this.img.w, "int", this.img.h, "uint", 0xCC0020)
        }
    }

    Changed() {
        this.Render()
        CopyImage(this.out, false)
        this.inHistory := false
        this.dirty := true
        SetTimer(this.flushFn, -700)
        this.InvalidateImage()
    }

    InvalidateImage() => Invalidate(this.hwnd, this.ix, this.iy, this.ix + this.vw, this.iy + this.vh)
    InvalidateBar() => Invalidate(this.hwnd, 0, 0, this.cw, this.top)
    InvalidateStrip() => Invalidate(this.hwnd, 0, this.ch - this.sh, this.cw, this.ch)

    Undo() {
        if this.marks.Length {
            this.marks.Pop()
            this.Changed()
        }
    }

    Copy() {
        CopyImage(this.out, true)
        this.inHistory := true
        Flash("Copied")
    }

    Save() {
        dir := PicturesDir() "\Screenshots"
        try DirCreate(dir)
        this.gui.Opt("+OwnDialogs")
        path := FileSelect("S16", dir "\ScreenSnappy " FormatTime(, "yyyy-MM-dd HHmmss") ".png", "Save screenshot", "PNG image (*.png)")
        if path = ""
            return
        if !(path ~= "i)\.png$")
            path .= ".png"
        if SavePng(this.out.hbm, path)
            Flash("Saved " path)
        else
            MsgBox("Could not save " path, "ScreenSnappy", "Icon!")
    }

    Close() {
        this.Flush()
        ; Intermediate copies are kept out of Win+V history; put the final one there,
        ; unless something else has been copied since.
        if !this.inHistory && DllCall("GetClipboardOwner", "ptr") = A_ScriptHwnd
            CopyImage(this.out, true)
        SetTimer(this.tipFn, 0)
        ToolTip()
        Wins.Delete(this.hwnd)
        this.gui.Destroy()
        Editor.cur := 0, History.editor := 0
        this.img := this.out := this.view := this.frame := this.bar := this.back := this.strip := 0
    }

    ; Client coordinates in lParam -> [x, y] in image pixels.
    ToImage(lp) {
        x := (lp << 48 >> 48) - this.ix, y := (lp << 32 >> 48) - this.iy
        return [Clamp(Round(x / this.scale), 0, this.img.w), Clamp(Round(y / this.scale), 0, this.img.h)]
    }

    ; Moves the hover highlight to header button i (0: none), repainting both buttons.
    Hover(i) {
        for j in [this.hot, i]
            if j
                b := this.buttons[j], Invalidate(this.hwnd, b.x, 0, b.x + b.w, this.top)
        this.hot := i
        ToolTip()
        SetTimer(this.tipFn, i ? -600 : 0)
        if i
            TrackMouseLeave(this.hwnd)
    }

    ShowTip() {
        if this.hot && !this.hit
            ToolTip(this.buttons[this.hot].tip)
    }

    ; -- window messages

    ; No title bar: the client area starts at the window's top edge. Maximized,
    ; the frame hangs off-screen, so the top is inset by its thickness instead.
    OnNcCalcSize(wp, lp) {
        if !wp
            return
        l := NumGet(lp, 0, "int"), t := NumGet(lp, 4, "int")
        DllCall("DefWindowProc", "ptr", this.hwnd, "uint", 0x83, "ptr", wp, "ptr", lp)
        NumPut("int", DllCall("IsZoomed", "ptr", this.hwnd) ? t + NumGet(lp, 0, "int") - l : t, lp, 4)
        return 0
    }

    ; The header drags the window (and its top edge resizes it); the buttons stay ours.
    OnNcHitTest(wp, lp) {
        r := DllCall("DefWindowProc", "ptr", this.hwnd, "uint", 0x84, "ptr", wp, "ptr", lp, "ptr")
        if r != 1  ; the resize frame
            return r
        pt := (lp << 48 >> 48) & 0xFFFFFFFF | (lp << 32 >> 48) << 32
        DllCall("ScreenToClient", "ptr", this.hwnd, "int64*", &pt)
        x := pt << 32 >> 32, y := pt >> 32
        if y >= this.top
            return 1
        if y < this.fx && !DllCall("IsZoomed", "ptr", this.hwnd)
            return 12  ; HTTOP
        return this.ButtonAt(x, y) ? 1 : 2  ; HTCLIENT : HTCAPTION
    }

    OnGetMinMaxInfo(wp, lp) {
        NumPut("int", this.minW + 2 * this.fx, "int", this.minH + this.fb, lp, 24)  ; ptMinTrackSize
        return 0
    }

    OnSize(wp, lp) {
        if wp = 1  ; SIZE_MINIMIZED
            return 0
        w := lp & 0xFFFF, h := (lp >> 16) & 0xFFFF
        if w != this.cw || h != this.ch
            this.Relayout(w, h)
        this.scroll := Clamp(this.scroll, 0, this.ScrollMax())
        Invalidate(this.hwnd, 0, 0, w, h)
        return 0
    }

    OnMouseWheel(wp, lp) {
        this.scroll := Clamp(this.scroll - ((wp << 32 >> 48) // 120) * (this.tw + this.tgap), 0, this.ScrollMax())
        this.hotThumb := 0
        this.InvalidateStrip()
        return 0
    }

    OnLButtonDown(wp, lp) {
        x := lp << 48 >> 48, y := lp << 32 >> 48
        if y < this.top {
            if i := this.ButtonAt(x, y) {
                this.hit := i
                DllCall("SetCapture", "ptr", this.hwnd)
                this.Hover(i)
            }
            return 0
        }
        if y >= this.ch - this.sh {
            if i := this.ThumbAt(x, y - (this.ch - this.sh))
                this.Switch(i)
            return 0
        }
        if !this.InImage(x, y)
            return
        p := this.ToImage(lp)
        this.pending := {tool: this.tool, x1: p[1], y1: p[2], x2: p[1], y2: p[2]}
        DllCall("SetCapture", "ptr", this.hwnd)
        return 0
    }

    OnMouseMove(wp, lp) {
        x := lp << 48 >> 48, y := lp << 32 >> 48
        if this.pending {
            p := this.ToImage(lp)
            this.pending.x2 := p[1], this.pending.y2 := p[2]
            this.InvalidateImage()
            return 0
        }
        hot := y < this.top ? this.ButtonAt(x, y) : 0
        if hot != this.hot
            this.Hover(hot)
        ht := y >= this.ch - this.sh ? this.ThumbAt(x, y - (this.ch - this.sh)) : 0
        if ht != this.hotThumb {
            this.hotThumb := ht
            this.InvalidateStrip()
            if ht
                TrackMouseLeave(this.hwnd)
        }
        return 0
    }

    OnMouseLeave(*) {
        if this.hot
            this.Hover(0)
        if this.hotThumb
            this.hotThumb := 0, this.InvalidateStrip()
        return 0
    }

    OnLButtonUp(wp, lp) {
        if i := this.hit {
            this.hit := 0
            DllCall("ReleaseCapture")
            this.Hover(this.ButtonAt(lp << 48 >> 48, lp << 32 >> 48))
            if this.hot = i
                this.buttons[i].act.Call()
            return 0
        }
        if !(m := this.pending)
            return
        this.pending := 0
        DllCall("ReleaseCapture")
        dx := Abs(m.x2 - m.x1), dy := Abs(m.y2 - m.y1)
        if m.tool = "box" ? dx >= 2 && dy >= 2 : dx + dy >= 8 {
            this.marks.Push(m)
            this.Changed()
        } else
            this.InvalidateImage()
        return 0
    }

    OnPaint(*) {
        hdc := StartPaint(this.hwnd, &l, &t, &r, &b)
        if t < this.top {
            this.PaintBar()
            Blt(hdc, l, t, r - l, Min(b, this.top) - t, this.bar.dc, l, t)
        }
        sy := this.ch - this.sh
        if b > this.top && t < sy && this.img {
            ix := this.ix, iy := this.iy, vw := this.vw, vh := this.vh, ct := Max(t, this.top), cb := Min(b, sy)
            ; The canvas, except under the image, which is blitted whole below.
            this.Mat(hdc, l, ct, r, Min(cb, iy))
            this.Mat(hdc, l, Max(ct, iy + vh), r, cb)
            this.Mat(hdc, l, Max(ct, iy), Min(r, ix), Min(cb, iy + vh))
            this.Mat(hdc, Max(l, ix + vw), Max(ct, iy), r, Min(cb, iy + vh))
            this.frame.Blit(0, 0, vw, vh, this.view.dc, 0, 0)
            if this.pending {
                g := this.frame.Graphics()
                DrawMark(g, this.pending, this.scale)
                GdipDelete(g)
            }
            Blt(hdc, ix, iy, vw, vh, this.frame.dc, 0, 0)
        }
        if b > sy {
            this.PaintStrip()
            st := Max(t, sy)
            Blt(hdc, l, st, r - l, b - st, this.strip.dc, l, st - sy)
        }
        DllCall("ReleaseDC", "ptr", this.hwnd, "ptr", hdc)
        return 0
    }

    ; Copies [l, r) × [t, b) of the canvas backdrop to the window.
    Mat(hdc, l, t, r, b) {
        if r > l && b > t
            Blt(hdc, l, t, r - l, b - t, this.back.dc, l, t - this.top)
    }

    ; Draws the whole header into this.bar.
    PaintBar() {
        dpi := this.dpi, r := Round(5 * dpi), s := Round(16 * dpi), u := Round(dpi)
        zoomed := DllCall("IsZoomed", "ptr", this.hwnd)
        g := this.bar.Graphics()
        GFill(g, Argb(Theme.surface), 0, 0, this.cw, this.top)
        if !zoomed
            GFill(g, Argb(Theme.border), 0, 0, this.cw, 1)
        GFill(g, Argb(Theme.sep), this.sepX, (this.top - s) // 2, 1, s)
        for b in this.buttons {
            on := b.tool && b.tool = this.tool, hot := b.i = this.hot, pressed := hot && b.i = this.hit
            b.fg := Theme.text
            if b.cap = "close" && hot
                GFill(g, pressed ? 0xFFB2271A : 0xFFC42B1C, b.x, b.y, b.w, b.h), b.fg := 0xFFFFFF
            else if b.cap && hot
                GFill(g, Argb(pressed ? Theme.press : Theme.hover), b.x, b.y, b.w, b.h)
            else if on
                GRound(g, Accent, b.x, b.y, b.w, b.h, r), b.fg := 0xFFFFFF
            else if hot
                GRound(g, Argb(pressed ? Theme.press : Theme.hover), b.x, b.y, b.w, b.h, r)
            ; The tool icons are the marks themselves, in miniature.
            x := b.x + (b.w - s) // 2, y := b.y + (b.h - s) // 2
            if b.tool = "arrow"
                GArrow(g, Argb(b.fg), 2 * dpi, x + u, y + s - u, x + s - u, y + u)
            else if b.tool = "box"
                GFill(g, Argb(b.fg), x + u, y + 3 * u, s - 2 * u, s - 6 * u)
        }
        GdipDelete(g)
        dc := this.bar.dc
        ts := TextSize(dc, Font("ui"), "ScreenSnappy")
        DrawText(dc, Font("ui"), Theme.text, this.m, (this.top - ts[2]) // 2, "ScreenSnappy")
        if this.showSub
            DrawText(dc, Font("ui"), Theme.dim, this.m + ts[1] + Round(8 * dpi), (this.top - ts[2]) // 2, this.showSub)
        for b in this.buttons {
            if b.tool
                continue
            glyph := b.cap = "max" && zoomed ? Chr(0xE923) : b.glyph, hf := Font(b.cap ? "cap" : "icon")
            if !hf  ; no icon font: plain text
                glyph := b.text, hf := Font("ui")
            gs := TextSize(dc, hf, glyph)
            DrawText(dc, hf, b.fg, b.x + (b.w - gs[1]) // 2, b.y + (b.h - gs[2]) // 2, glyph)
        }
    }

    ; Draws the strip of recent captures into this.strip.
    PaintStrip() {
        r := Round(4 * this.dpi), pad := Round(4 * this.dpi)
        g := this.strip.Graphics()
        GFill(g, Argb(Theme.surface), 0, 0, this.cw, this.sh)
        GFill(g, Argb(Theme.sep), 0, 0, this.cw, 1)
        for i, cap in History.caps {
            t := this.ThumbRect(i)
            if t.x >= this.cw
                break
            if t.x + t.w <= 0
                continue
            if i = this.hotThumb
                GRound(g, Argb(Theme.hover), t.x - pad, t.y - pad, t.w + 2 * pad, t.h + 2 * pad, r)
            if !cap.thumb  ; not built yet
                GRound(g, Argb(Theme.hover), t.x, t.y, t.w, t.h, r)
            if cap.path = this.cap.path
                GRound(g, Accent, t.x - 3, t.y - 3, t.w + 6, t.h + 6, r + 2, 2)
        }
        GdipDelete(g)
        for i, cap in History.caps {
            t := this.ThumbRect(i)
            if t.x >= this.cw
                break
            if cap.thumb && t.x + t.w > 0
                Blt(this.strip.dc, t.x, t.y, t.w, t.h, cap.thumb.dc, 0, 0)
        }
    }

    OnEraseBkgnd(*) => 1

    OnSetCursor(wp, lp) {
        if wp != this.hwnd || (lp & 0xFFFF) != 1  ; not HTCLIENT of this window
            return
        DllCall("GetCursorPos", "int64*", &pt := 0)
        DllCall("ScreenToClient", "ptr", this.hwnd, "int64*", &pt)
        if !this.InImage(pt << 32 >> 32, pt >> 32)
            return
        DllCall("SetCursor", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32515, "ptr"))  ; IDC_CROSS
        return 1
    }
}

; m: {tool, x1, y1, x2, y2} in image pixels, drawn at scale s.
DrawMark(g, m, s) {
    if m.tool = "box"
        GFill(g, 0xFF000000, Min(m.x1, m.x2) * s, Min(m.y1, m.y2) * s, Abs(m.x2 - m.x1) * s, Abs(m.y2 - m.y1) * s)
    else
        GArrow(g, ArrowColor, ArrowWidth * s, m.x1 * s, m.y1 * s, m.x2 * s, m.y2 * s)
}

; ---------------------------------------------------------------- recent captures

; Recent captures, newest first, as {path, w, h, thumb, fresh}. Each one's PNG
; (marks included) lives in %TEMP%\ScreenSnappy; the newest 100 are kept.
class History {
    static caps := [], keep := 100, loaded := false, editor := 0, tw := 96, th := 64

    static Dir() => A_Temp "\ScreenSnappy"

    ; Records a new capture; the editor writes its PNG once it is on screen.
    static Add(img) {
        dir := History.Dir()
        try DirCreate(dir)
        base := dir "\ScreenSnappy " FormatTime(, "yyyy-MM-dd HHmmss"), path := base ".png", n := 1
        while FileExist(path)
            path := base " (" (++n) ").png"
        cap := {path: path, w: img.w, h: img.h, thumb: 0, fresh: true}
        History.caps.InsertAt(1, cap)
        History.Prune()
        return cap
    }

    static Prune() {
        while History.caps.Length > History.keep
            try FileDelete(History.caps.Pop().path)
    }

    ; Picks up the captures already in the folder (names sort by time), then
    ; builds the missing thumbnails in the background, one per timer tick.
    static Start() {
        if !History.loaded {
            History.loaded := true
            known := Map()
            for cap in History.caps
                known[cap.path] := true
            names := ""
            loop files History.Dir() "\ScreenSnappy *.png"
                if !known.Has(A_LoopFileFullPath)
                    names .= A_LoopFileName "`n"
            if names {
                for name in StrSplit(Sort(RTrim(names, "`n"), "R"), "`n")
                    History.caps.Push({path: History.Dir() "\" name, w: 0, h: 0, thumb: 0, fresh: false})
                History.Prune()
            }
        }
        History.Build()
    }

    static Build() {
        for i, cap in History.caps {
            if cap.thumb || cap.fresh
                continue
            if cap.thumb := ThumbFromFile(cap.path, History.tw, History.th, &w, &h)
                cap.w := w, cap.h := h
            else
                History.caps.RemoveAt(i)  ; gone from the folder
            if History.editor
                History.editor.InvalidateStrip()
            SetTimer((*) => History.Build(), -10)
            return
        }
    }
}

; ---------------------------------------------------------------- clipboard and files

; Put c on the clipboard as a 24-bit DIB, optionally kept out of Win+V history.
CopyImage(c, history) {
    static noHistory := DllCall("RegisterClipboardFormat", "str", "CanIncludeInClipboardHistory", "uint")
    stride := (c.w * 3 + 3) & ~3, size := stride * c.h
    bi := Buffer(40, 0)
    NumPut("uint", 40, "int", c.w, "int", c.h, "ushort", 1, "ushort", 24, bi)  ; bottom-up, as CF_DIB expects
    hbm := DllCall("CreateDIBSection", "ptr", 0, "ptr", bi, "uint", 0, "ptr*", &bits := 0, "ptr", 0, "uint", 0, "ptr")
    if !hbm
        return false
    dc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
    old := DllCall("SelectObject", "ptr", dc, "ptr", hbm, "ptr")
    Blt(dc, 0, 0, c.w, c.h, c.dc, 0, 0)
    DllCall("GdiFlush")
    hDib := DllCall("GlobalAlloc", "uint", 0x42, "uptr", 40 + size, "ptr")
    p := DllCall("GlobalLock", "ptr", hDib, "ptr")
    DllCall("RtlMoveMemory", "ptr", p, "ptr", bi, "uptr", 40)
    DllCall("RtlMoveMemory", "ptr", p + 40, "ptr", bits, "uptr", size)
    DllCall("GlobalUnlock", "ptr", hDib)
    DllCall("SelectObject", "ptr", dc, "ptr", old, "ptr")
    DllCall("DeleteDC", "ptr", dc)
    DllCall("DeleteObject", "ptr", hbm)

    loop 20 {
        if DllCall("OpenClipboard", "ptr", A_ScriptHwnd) {
            DllCall("EmptyClipboard")
            ok := DllCall("SetClipboardData", "uint", 8, "ptr", hDib, "ptr")  ; CF_DIB
            if ok && !history {
                hFlag := DllCall("GlobalAlloc", "uint", 0x42, "uptr", 4, "ptr")  ; zeroed DWORD = "no"
                if !DllCall("SetClipboardData", "uint", noHistory, "ptr", hFlag, "ptr")
                    DllCall("GlobalFree", "ptr", hFlag)
            }
            DllCall("CloseClipboard")
            if ok
                return true
            break
        }
        Sleep 15
    }
    DllCall("GlobalFree", "ptr", hDib)
    return false
}

SavePng(hbm, path) {
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &bmp := 0)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)  ; PNG encoder
    ok := DllCall("gdiplus\GdipSaveImageToFile", "ptr", bmp, "wstr", path, "ptr", clsid, "ptr", 0) = 0
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    return ok
}

; A capture's PNG as a Canvas, or 0.
LoadPng(path) {
    if DllCall("gdiplus\GdipLoadImageFromFile", "wstr", path, "ptr*", &bmp := 0) || !bmp
        return 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", bmp, "uint*", &w := 0)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", bmp, "uint*", &h := 0)
    c := Canvas(w, h)
    g := c.Graphics(false)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", bmp, "int", 0, "int", 0, "int", w, "int", h)
    GdipDelete(g)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    return c
}

; A thumbnail of a PNG that fits in tw × th (w, h get the image's size), or 0.
ThumbFromFile(path, tw, th, &w, &h) {
    if DllCall("gdiplus\GdipLoadImageFromFile", "wstr", path, "ptr*", &bmp := 0) || !bmp
        return 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", bmp, "uint*", &w := 0)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", bmp, "uint*", &h := 0)
    s := Min(tw / w, th / h)
    c := Canvas(Max(1, Round(w * s)), Max(1, Round(h * s)))
    g := c.Graphics()
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)  ; HighQualityBicubic
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", bmp, "int", 0, "int", 0, "int", c.w, "int", c.h)
    GdipDelete(g)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    return c
}

; A thumbnail of a canvas that fits in tw × th.
ThumbFromCanvas(src, tw, th) {
    s := Min(tw / src.w, th / src.h)
    c := Canvas(Max(1, Round(src.w * s)), Max(1, Round(src.h * s)))
    DllCall("SetStretchBltMode", "ptr", c.dc, "int", 4)  ; HALFTONE
    DllCall("SetBrushOrgEx", "ptr", c.dc, "int", 0, "int", 0, "ptr", 0)
    DllCall("StretchBlt", "ptr", c.dc, "int", 0, "int", 0, "int", c.w, "int", c.h
        , "ptr", src.dc, "int", 0, "int", 0, "int", src.w, "int", src.h, "uint", 0xCC0020)
    return c
}

PicturesDir() {
    guid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", "{33E28130-4E1E-4676-835A-98395C3BC3BB}", "ptr", guid)  ; FOLDERID_Pictures
    if DllCall("shell32\SHGetKnownFolderPath", "ptr", guid, "uint", 0, "ptr", 0, "ptr*", &p := 0) = 0 {
        dir := StrGet(p, "UTF-16")
        DllCall("ole32\CoTaskMemFree", "ptr", p)
        return dir
    }
    return EnvGet("USERPROFILE") "\Pictures"
}

; ---------------------------------------------------------------- tray

InitTray() {
    A_IconTip := "ScreenSnappy`nPrtSc: region or window`nAlt+PrtSc: active window"
    try TraySetIcon("imageres.dll", 68)
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Capture region or window  (PrtSc)", (*) => Picker.Start())
    tray.Default := "Capture region or window  (PrtSc)"
    tray.Add("Start with Windows", ToggleStartup)
    if FileExist(StartupLink())
        tray.Check("Start with Windows")
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
}

StartupLink() => A_Startup "\ScreenSnappy.lnk"

ToggleStartup(item, *) {
    if FileExist(StartupLink()) {
        FileDelete(StartupLink())
        A_TrayMenu.Uncheck(item)
    } else {
        if A_IsCompiled
            FileCreateShortcut(A_ScriptFullPath, StartupLink(), A_ScriptDir)
        else
            FileCreateShortcut(A_AhkPath, StartupLink(), A_ScriptDir, '"' A_ScriptFullPath '"')
        A_TrayMenu.Check(item)
    }
}

Flash(text) {
    ToolTip(text, , , 2)
    SetTimer(() => ToolTip(, , , 2), -1500)
}

; ---------------------------------------------------------------- theme

; Editor chrome colours (RGB) for Windows' light or dark app mode, read once at start.
AppTheme() {
    light := 1
    try light := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
    return light
        ? {dark: false, surface: 0xF3F3F3, text: 0x1B1B1B, dim: 0x6B6B6B, hover: 0xE5E5E5, press: 0xEBEBEB
            , border: 0xCFCFCF, sep: 0xDADADA}
        : {dark: true, surface: 0x202020, text: 0xFFFFFF, dim: 0xA0A0A0, hover: 0x2F2F2F, press: 0x2A2A2A
            , border: 0x404040, sep: 0x383838}
}

AccentColor() {
    if DllCall("dwmapi\DwmGetColorizationColor", "uint*", &argb := 0, "int*", &opaque := 0) = 0
        return 0xFF000000 | (argb & 0xFFFFFF)
    return 0xFF0078D4
}

Argb(rgb) => 0xFF000000 | rgb
Bgr(rgb) => (rgb & 0xFF) << 16 | (rgb & 0xFF00) | (rgb >> 16)  ; COLORREF

; The UI fonts, created on first use: "ui" header text, "tag" and "hint" overlay
; labels, "icon" and "cap" (caption button) Fluent glyphs, 0 when neither the
; Fluent nor the MDL2 icon font exists.
Font(role) {
    static fonts := Map()
    if !fonts.Has(role) {
        dpi := A_ScreenDPI / 96
        switch role {
            case "ui":   fonts[role] := FirstFont(["Segoe UI Variable Text", "Segoe UI"], Round(12 * dpi), 400)
            case "hint": fonts[role] := FirstFont(["Segoe UI Variable Small", "Segoe UI"], Round(12 * dpi), 400)
            case "tag":  fonts[role] := FirstFont(["Segoe UI Variable Text", "Segoe UI"], Round(13 * dpi), 600)
            case "icon": fonts[role] := FirstFont(["Segoe Fluent Icons", "Segoe MDL2 Assets"], Round(16 * dpi), 400, true)
            case "cap":  fonts[role] := FirstFont(["Segoe Fluent Icons", "Segoe MDL2 Assets"], Round(10 * dpi), 400, true)
        }
    }
    return fonts[role]
}

; An HFONT of the first installed face in the list; the last face, substituted
; by GDI, if none is (or 0 when strict).
FirstFont(faces, px, weight, strict := false) {
    for face in faces {
        f := DllCall("CreateFontW", "int", -px, "int", 0, "int", 0, "int", 0, "int", weight, "uint", 0, "uint", 0
            , "uint", 0, "uint", 1, "uint", 0, "uint", 0, "uint", strict ? 4 : 5, "uint", 0, "wstr", face, "ptr")
        if FontFace(f) = face || (A_Index = faces.Length && !strict)
            return f
        DllCall("DeleteObject", "ptr", f)
    }
    return 0
}

FontFace(hfont) {
    dc := DllCall("GetDC", "ptr", 0, "ptr")
    old := DllCall("SelectObject", "ptr", dc, "ptr", hfont, "ptr")
    DllCall("GetTextFaceW", "ptr", dc, "int", 64, "ptr", name := Buffer(128))
    DllCall("SelectObject", "ptr", dc, "ptr", old, "ptr")
    DllCall("ReleaseDC", "ptr", 0, "ptr", dc)
    return StrGet(name, "UTF-16")
}

; ---------------------------------------------------------------- drawing helpers

; A 32-bit top-down DIB selected into its own memory DC.
class Canvas {
    __New(w, h) {
        this.w := w, this.h := h
        bi := Buffer(40, 0)
        NumPut("uint", 40, "int", w, "int", -h, "ushort", 1, "ushort", 32, bi)
        this.hbm := DllCall("CreateDIBSection", "ptr", 0, "ptr", bi, "uint", 0, "ptr*", &bits := 0, "ptr", 0, "uint", 0, "ptr")
        if !this.hbm
            throw Error(Format("Not enough memory for a {} × {} image", w, h))
        this.dc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
        this.old := DllCall("SelectObject", "ptr", this.dc, "ptr", this.hbm, "ptr")
    }

    __Delete() {
        DllCall("SelectObject", "ptr", this.dc, "ptr", this.old, "ptr")
        DllCall("DeleteDC", "ptr", this.dc)
        DllCall("DeleteObject", "ptr", this.hbm)
    }

    Blit(x, y, w, h, srcDC, sx, sy) => Blt(this.dc, x, y, w, h, srcDC, sx, sy)

    ; A GDI+ Graphics on this canvas; free it with GdipDelete.
    Graphics(smooth := true) => GdipGraphics(this.dc, smooth)
}

Blt(dst, x, y, w, h, src, sx, sy, rop := 0xCC0020) => DllCall("BitBlt", "ptr", dst, "int", x, "int", y
    , "int", w, "int", h, "ptr", src, "int", sx, "int", sy, "uint", rop)

; Validate the window's update region without a WM_ERASEBKGND round trip and
; return a DC for it (release with ReleaseDC). l, t, r, b get the region's bounds.
StartPaint(hwnd, &l := 0, &t := 0, &r := 0, &b := 0) {
    rc := Buffer(16, 0)
    DllCall("GetUpdateRect", "ptr", hwnd, "ptr", rc, "int", 0)
    DllCall("ValidateRect", "ptr", hwnd, "ptr", 0)
    l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int"), r := NumGet(rc, 8, "int"), b := NumGet(rc, 12, "int")
    return DllCall("GetDC", "ptr", hwnd, "ptr")
}

Invalidate(hwnd, l, t, r, b) {
    rc := Buffer(16)
    NumPut("int", l, "int", t, "int", r, "int", b, rc)
    DllCall("InvalidateRect", "ptr", hwnd, "ptr", rc, "int", 0)
}

; WM_MOUSELEAVE once the mouse leaves the window's client area.
TrackMouseLeave(hwnd) {
    tme := Buffer(24, 0)
    NumPut("uint", 24, "uint", 2, "ptr", hwnd, tme)  ; TME_LEAVE
    DllCall("TrackMouseEvent", "ptr", tme)
}

; Fills [l, r) × [t, b) with an RGB colour (empty rectangles are skipped).
FillRect(hdc, l, t, r, b, rgb) {
    static brushes := Map()
    if r <= l || b <= t
        return
    if !brushes.Has(rgb)
        brushes[rgb] := DllCall("CreateSolidBrush", "uint", Bgr(rgb), "ptr")
    rc := Buffer(16)
    NumPut("int", l, "int", t, "int", r, "int", b, rc)
    DllCall("FillRect", "ptr", hdc, "ptr", rc, "ptr", brushes[rgb])
}

; [width, height] of text in a font.
TextSize(dc, hfont, text) {
    old := DllCall("SelectObject", "ptr", dc, "ptr", hfont, "ptr")
    DllCall("GetTextExtentPoint32W", "ptr", dc, "wstr", text, "int", StrLen(text), "ptr", size := Buffer(8))
    DllCall("SelectObject", "ptr", dc, "ptr", old, "ptr")
    return [NumGet(size, 0, "int"), NumGet(size, 4, "int")]
}

DrawText(dc, hfont, rgb, x, y, text) {
    old := DllCall("SelectObject", "ptr", dc, "ptr", hfont, "ptr")
    DllCall("SetBkMode", "ptr", dc, "int", 1)  ; TRANSPARENT
    DllCall("SetTextColor", "ptr", dc, "uint", Bgr(rgb))
    DllCall("TextOutW", "ptr", dc, "int", x, "int", y, "wstr", text, "int", StrLen(text))
    DllCall("SelectObject", "ptr", dc, "ptr", old, "ptr")
}

; White text (plus a dimmer sub-text) on a dark rounded tag whose top-left is
; (x, y), or top-centre if centered. By default the tag sits just above y, or
; just below it at the top of the screen.
DrawLabel(dc, text, x, y, centered := false, sub := "") {
    dpi := A_ScreenDPI / 96
    px := Round(12 * dpi), py := Round(6 * dpi), gap := Round(10 * dpi)
    s := TextSize(dc, Font("tag"), text), w := s[1] + 2 * px, h := s[2] + 2 * py
    if sub
        s2 := TextSize(dc, Font("hint"), sub), w += gap + s2[1]
    if centered
        x -= w // 2
    else
        y := y - h - 6 >= 0 ? y - h - 6 : y + 6
    g := GdipGraphics(dc)
    GRound(g, 0xF01C1C1C, x, y, w, h, Round(6 * dpi))
    GRound(g, 0x30FFFFFF, x + 0.5, y + 0.5, w - 1, h - 1, Round(6 * dpi), 1)
    GdipDelete(g)
    DrawText(dc, Font("tag"), 0xFFFFFF, x + px, y + py, text)
    if sub
        DrawText(dc, Font("hint"), 0xA6A6A6, x + px + s[1] + gap, y + py + s[2] - s2[2], sub)
}

GdipStartup() {
    DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    si := Buffer(24, 0)
    NumPut("uint", 1, si)
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token := 0, "ptr", si, "ptr", 0)
}

; A GDI+ Graphics on a DC; free it with GdipDelete before drawing on the DC with GDI.
GdipGraphics(dc, smooth := true) {
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", dc, "ptr*", &g := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", g, "int", smooth ? 4 : 3)  ; AntiAlias : None
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 4)  ; Half: whole-pixel fills stay crisp
    return g
}

GdipDelete(g) => DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)

GFill(g, argb, x, y, w, h) {
    DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &brush := 0)
    DllCall("gdiplus\GdipFillRectangle", "ptr", g, "ptr", brush, "float", x, "float", y, "float", w, "float", h)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
}

GFrame(g, argb, width, x, y, w, h) {
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawRectangle", "ptr", g, "ptr", pen, "float", x, "float", y, "float", w, "float", h)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
}

; A rounded rectangle with corner radius r: filled, or outlined if width > 0.
GRound(g, argb, x, y, w, h, r, width := 0) {
    d := 2 * r
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &path := 0)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x, "float", y, "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x + w - d, "float", y, "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x + w - d, "float", y + h - d, "float", d, "float", d, "float", 0, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", x, "float", y + h - d, "float", d, "float", d, "float", 90, "float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", path)
    if width {
        DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
        DllCall("gdiplus\GdipDrawPath", "ptr", g, "ptr", pen, "ptr", path)
        DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    } else {
        DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &brush := 0)
        DllCall("gdiplus\GdipFillPath", "ptr", g, "ptr", brush, "ptr", path)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
    }
    DllCall("gdiplus\GdipDeletePath", "ptr", path)
}

; A line with a round tail and a swept, filled head at (x2, y2).
GArrow(g, argb, width, x1, y1, x2, y2) {
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
    DllCall("gdiplus\GdipCreateAdjustableArrowCap", "float", 4.5, "float", 3.2, "int", 1, "ptr*", &cap := 0)
    DllCall("gdiplus\GdipSetAdjustableArrowCapMiddleInset", "ptr", cap, "float", 1.1)  ; notched base
    DllCall("gdiplus\GdipSetPenCustomEndCap", "ptr", pen, "ptr", cap)
    DllCall("gdiplus\GdipSetPenStartCap", "ptr", pen, "int", 2)  ; round tail
    DllCall("gdiplus\GdipDrawLine", "ptr", g, "ptr", pen, "float", x1, "float", y1, "float", x2, "float", y2)
    DllCall("gdiplus\GdipDeleteCustomLineCap", "ptr", cap)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
}

; ---------------------------------------------------------------- geometry

ClipRect(x, y, w, h, maxW, maxH) {
    l := Max(x, 0), t := Max(y, 0), r := Min(x + w, maxW), b := Min(y + h, maxH)
    return r > l && b > t ? {x: l, y: t, w: r - l, h: b - t} : 0
}

Clamp(v, lo, hi) => Min(Max(v, lo), hi)

; Work area of the monitor containing (x, y), or of the primary monitor.
MonitorAt(x, y) {
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if x >= l && x < r && y >= t && y < b {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            return {l: l, t: t, r: r, b: b}
        }
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    return {l: l, t: t, r: r, b: b}
}
