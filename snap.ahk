#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
; Snap: fast screenshots with an arrow and a black box, nothing else.
;   PrtSc or Win+Shift+S   drag to capture a region, or click a window
;   Alt+PrtSc              capture the active window
; Every capture and every edit goes on the clipboard straight away.

DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")  ; per-monitor v2: work in real pixels
GdipStartup()
InitTray()

global Wins := Map()  ; hwnd -> Picker or Editor that handles that window's messages
for msg, name in Map(0x000F, "OnPaint", 0x0014, "OnEraseBkgnd", 0x0020, "OnSetCursor", 0x0200, "OnMouseMove"
        , 0x0201, "OnLButtonDown", 0x0202, "OnLButtonUp", 0x0205, "OnRButtonUp", 0x02A3, "OnMouseLeave")
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
            Editor(img, this.x + rc.x + rc.w // 2, this.y + rc.y + rc.h // 2)
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
    Editor(CaptureScreen(vx + rc.x, vy + rc.y, rc.w, rc.h), vx + rc.x + rc.w // 2, vy + rc.y + rc.h // 2)
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

; A painted toolbar (tools left, actions right) over the capture on a matte.
class Editor {
    static Active() {
        e := Wins.Get(WinExist("A"), 0)
        return e is Editor ? e : 0
    }

    __New(img, cx, cy) {
        this.img := img, this.marks := [], this.tool := "arrow", this.pending := 0
        this.out := Canvas(img.w, img.h)  ; img with the marks drawn on: what gets copied and saved

        dpi := this.dpi := A_ScreenDPI / 96
        m := this.m := Round(12 * dpi)  ; matte around the image
        this.top := Round(44 * dpi)     ; toolbar height
        mon := MonitorAt(cx, cy)
        fitW := mon.r - mon.l - Round(40 * dpi) - 2 * m, fitH := mon.b - mon.t - this.top - Round(80 * dpi) - 2 * m
        this.scale := Min(1, fitW / img.w, fitH / img.h)
        this.vw := Max(1, Round(img.w * this.scale)), this.vh := Max(1, Round(img.h * this.scale))
        this.view := this.scale = 1 ? this.out : Canvas(this.vw, this.vh)  ; out, shrunk to fit
        this.frame := Canvas(this.vw, this.vh)                             ; view + the mark being drawn

        this.hot := 0, this.hit := 0  ; index of the button under the mouse, and of the one being pressed
        barW := this.Layout()
        this.cw := Max(this.vw + 2 * m, barW), this.ch := this.top + this.vh + 2 * m
        this.ix := (this.cw - this.vw) // 2, this.iy := this.top + m  ; where the image sits
        for b in this.buttons  ; the actions were laid out from the right edge
            if b.right
                b.x += this.cw
        this.bar := Canvas(this.cw, this.top)

        g := this.gui := Gui("-DPIScale")
        g.BackColor := Format("{:06X}", Theme.bar)
        g.OnEvent("Close", (*) => this.Close())
        this.hwnd := g.Hwnd
        ThemeTitleBar(this.hwnd)
        Wins[this.hwnd] := this

        this.Render()
        this.inHistory := false
        CopyImage(this.out, false)
        g.Title := Format("Snap – {} × {}, on the clipboard", img.w, img.h)
        g.Show(Format("w{} h{} Hide", this.cw, this.ch))
        WinGetPos(, , &ww, &wh, this.hwnd)
        g.Show(Format("x{} y{}", mon.l + (mon.r - mon.l - ww) // 2, mon.t + (mon.b - mon.t - wh) // 2))
    }

    ; Measures the toolbar buttons and places the tools from the left edge and the
    ; actions from the right (x <= 0 until the window width is known). Returns the
    ; narrowest window that fits them all.
    Layout() {
        dpi := this.dpi
        this.pad := Round(10 * dpi), this.sp := Round(6 * dpi), gap := Round(4 * dpi)
        this.icon := Round(16 * dpi), this.bh := Round(32 * dpi), this.by := (this.top - this.bh) // 2
        this.buttons := [
            {tool: "arrow", label: "Arrow", key: "A", glyph: "", act: (*) => this.SetTool("arrow")},
            {tool: "box", label: "Box", key: "B", glyph: "", act: (*) => this.SetTool("box")},
            {tool: "", label: "Undo", key: "", glyph: Chr(0xE7A7), act: (*) => this.Undo()},
            {tool: "", label: "Copy", key: "", glyph: Chr(0xE8C8), act: (*) => this.Copy()},
            {tool: "", label: "Save", key: "", glyph: Chr(0xE74E), act: (*) => this.Save()}]
        dc := this.out.dc
        for i, b in this.buttons {
            b.i := i, b.right := !b.tool, b.y := this.by, b.h := this.bh
            b.lw := TextSize(dc, Font("ui"), b.label)[1]
            b.kw := b.key ? TextSize(dc, Font("hint"), b.key)[1] : 0
            b.hasIcon := b.tool || (b.glyph && Font("icon"))
            b.w := 2 * this.pad + b.lw + (b.hasIcon ? this.icon + this.sp : 0) + (b.key ? this.sp + b.kw : 0)
        }
        x := this.m
        for b in this.buttons
            if !b.right
                b.x := x, x += b.w + gap
        left := x - gap
        x := -this.m
        loop this.buttons.Length {
            b := this.buttons[-A_Index]
            if b.right
                x -= b.w, b.x := x, x -= gap
        }
        return left - x - gap + Round(24 * dpi)
    }

    ; Index of the button at client (x, y), or 0.
    ButtonAt(x, y) {
        if y >= this.by && y < this.by + this.bh
            for b in this.buttons
                if x >= b.x && x < b.x + b.w
                    return b.i
        return 0
    }

    InImage(x, y) => x >= this.ix && x < this.ix + this.vw && y >= this.iy && y < this.iy + this.vh

    SetTool(tool) {
        this.tool := tool
        Invalidate(this.hwnd, 0, 0, this.cw, this.top)
    }

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
        this.InvalidateImage()
    }

    InvalidateImage() => Invalidate(this.hwnd, this.ix, this.iy, this.ix + this.vw, this.iy + this.vh)

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
        path := FileSelect("S16", dir "\Snap " FormatTime(, "yyyy-MM-dd HHmmss") ".png", "Save screenshot", "PNG image (*.png)")
        if path = ""
            return
        if !(path ~= "i)\.png$")
            path .= ".png"
        if SavePng(this.out.hbm, path)
            Flash("Saved " path)
        else
            MsgBox("Could not save " path, "Snap", "Icon!")
    }

    Close() {
        ; Intermediate copies are kept out of Win+V history; put the final one there,
        ; unless something else has been copied since.
        if !this.inHistory && DllCall("GetClipboardOwner", "ptr") = A_ScriptHwnd
            CopyImage(this.out, true)
        Wins.Delete(this.hwnd)
        this.gui.Destroy()
        this.img := this.out := this.view := this.frame := this.bar := 0
    }

    ; Client coordinates in lParam -> [x, y] in image pixels.
    ToImage(lp) {
        x := (lp << 48 >> 48) - this.ix, y := (lp << 32 >> 48) - this.iy
        return [Clamp(Round(x / this.scale), 0, this.img.w), Clamp(Round(y / this.scale), 0, this.img.h)]
    }

    ; Moves the hover highlight to button i (0: none), repainting both buttons.
    Hover(i) {
        for j in [this.hot, i]
            if j
                b := this.buttons[j], Invalidate(this.hwnd, b.x, 0, b.x + b.w, this.top)
        this.hot := i
        if i
            TrackMouseLeave(this.hwnd)
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
        return 0
    }

    OnMouseLeave(*) {
        if this.hot
            this.Hover(0)
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
        if b > this.top {
            ix := this.ix, iy := this.iy, vw := this.vw, vh := this.vh
            ; The matte, except under the image, which is blitted whole below.
            FillRect(hdc, l, Max(t, this.top), r, Min(b, iy), Theme.matte)
            FillRect(hdc, l, Max(t, iy + vh), r, b, Theme.matte)
            FillRect(hdc, l, Max(t, iy), Min(r, ix), Min(b, iy + vh), Theme.matte)
            FillRect(hdc, Max(l, ix + vw), Max(t, iy), r, Min(b, iy + vh), Theme.matte)
            FillRect(hdc, ix - 1, iy - 1, ix + vw + 1, iy, Theme.edge)  ; hairline around the image
            FillRect(hdc, ix - 1, iy + vh, ix + vw + 1, iy + vh + 1, Theme.edge)
            FillRect(hdc, ix - 1, iy, ix, iy + vh, Theme.edge)
            FillRect(hdc, ix + vw, iy, ix + vw + 1, iy + vh, Theme.edge)
            this.frame.Blit(0, 0, vw, vh, this.view.dc, 0, 0)
            if this.pending {
                g := this.frame.Graphics()
                DrawMark(g, this.pending, this.scale)
                GdipDelete(g)
            }
            Blt(hdc, ix, iy, vw, vh, this.frame.dc, 0, 0)
        }
        DllCall("ReleaseDC", "ptr", this.hwnd, "ptr", hdc)
        return 0
    }

    ; Draws the whole toolbar into this.bar.
    PaintBar() {
        dpi := this.dpi, r := Round(4 * dpi), s := this.icon
        g := this.bar.Graphics()
        GFill(g, Argb(Theme.bar), 0, 0, this.cw, this.top)
        for b in this.buttons {
            on := b.tool && b.tool = this.tool
            if on || b.i = this.hot {
                fill := b.i = this.hit && b.i = this.hot ? Theme.press : on ? Theme.on : Theme.hover
                GRound(g, Argb(fill), b.x, b.y, b.w, b.h, r)
                if on
                    GRound(g, Argb(Theme.onEdge), b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1, r, 1)
            }
            ; The tool icons are the marks themselves, in miniature.
            x := b.x + this.pad, y := b.y + (b.h - s) // 2, u := Round(dpi)  ; one 96-dpi pixel
            if b.tool = "arrow"
                GArrow(g, ArrowColor, 2 * dpi, x + 2 * u, y + s - 2 * u, x + s - 2 * u, y + 2 * u)
            else if b.tool = "box" {
                GFill(g, 0xFF000000, x + u, y + 3 * u, s - 2 * u, s - 6 * u)
                GFrame(g, Argb(Theme.dim), 1, x + u + 0.5, y + 3 * u + 0.5, s - 2 * u - 1, s - 6 * u - 1)
            }
        }
        GdipDelete(g)
        dc := this.bar.dc
        for b in this.buttons {
            x := b.x + this.pad
            if b.glyph && b.hasIcon {
                gs := TextSize(dc, Font("icon"), b.glyph)
                DrawText(dc, Font("icon"), Theme.text, x + (s - gs[1]) // 2, b.y + (b.h - gs[2]) // 2, b.glyph)
            }
            if b.hasIcon
                x += s + this.sp
            ls := TextSize(dc, Font("ui"), b.label)
            DrawText(dc, Font("ui"), Theme.text, x, b.y + (b.h - ls[2]) // 2, b.label)
            if b.key {
                ks := TextSize(dc, Font("hint"), b.key)
                DrawText(dc, Font("hint"), Theme.dim, x + b.lw + this.sp, b.y + (b.h - ks[2]) // 2, b.key)
            }
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
    A_IconTip := "Snap`nPrtSc: region or window`nAlt+PrtSc: active window"
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

StartupLink() => A_Startup "\Snap.lnk"

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
    ToolTip(text)
    SetTimer(() => ToolTip(), -1500)
}

; ---------------------------------------------------------------- theme

; Editor chrome colours (RGB) for Windows' light or dark app mode, read once at start.
AppTheme() {
    light := 1
    try light := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
    return light
        ? {dark: false, bar: 0xF3F3F3, matte: 0xE1E1E1, text: 0x1B1B1B, dim: 0x6E6E6E, hover: 0xE4E4E4
            , press: 0xD9D9D9, on: 0xFFFFFF, onEdge: 0xCCCCCC, edge: 0xB8B8B8}
        : {dark: true, bar: 0x202020, matte: 0x191919, text: 0xF0F0F0, dim: 0x9A9A9A, hover: 0x2D2D2D
            , press: 0x383838, on: 0x3D3D3D, onEdge: 0x505050, edge: 0x3C3C3C}
}

AccentColor() {
    if DllCall("dwmapi\DwmGetColorizationColor", "uint*", &argb := 0, "int*", &opaque := 0) = 0
        return 0xFF000000 | (argb & 0xFFFFFF)
    return 0xFF0078D4
}

; Title bar in the chrome colour, dark or light to match (Windows 11; harmless on 10).
ThemeTitleBar(hwnd) {
    DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", 20, "int*", Theme.dark, "uint", 4)  ; DWMWA_USE_IMMERSIVE_DARK_MODE
    DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", 35, "uint*", Bgr(Theme.bar), "uint", 4)  ; DWMWA_CAPTION_COLOR
}

Argb(rgb) => 0xFF000000 | rgb
Bgr(rgb) => (rgb & 0xFF) << 16 | (rgb & 0xFF00) | (rgb >> 16)  ; COLORREF

; The UI fonts, created on first use: "ui" labels, "hint" key hints, "tag" overlay
; labels, "icon" Fluent glyphs (0 when neither Fluent nor MDL2 icon font exists).
Font(role) {
    static fonts := Map()
    if !fonts.Has(role) {
        dpi := A_ScreenDPI / 96
        switch role {
            case "ui":   fonts[role] := FirstFont(["Segoe UI Variable Text", "Segoe UI"], Round(13 * dpi), 400)
            case "hint": fonts[role] := FirstFont(["Segoe UI Variable Small", "Segoe UI"], Round(12 * dpi), 400)
            case "tag":  fonts[role] := FirstFont(["Segoe UI Variable Text", "Segoe UI"], Round(13 * dpi), 600)
            case "icon": fonts[role] := FirstFont(["Segoe Fluent Icons", "Segoe MDL2 Assets"], Round(16 * dpi), 400, true)
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
