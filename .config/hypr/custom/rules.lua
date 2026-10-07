-- Your own window / workspace / layer rules.
-- Applied AFTER the base rules (hyprland/rules.lua).
--
-- Example: make a program always open floating and centred
-- hl.window_rule({ match = { class = "^(mpv)$" }, float = true })
-- hl.window_rule({ match = { class = "^(mpv)$" }, center = true })
--
-- Example: always open a program at a fixed size
-- hl.window_rule({ match = { class = "^(org.kde.dolphin)$" }, size = {1000, 700} })
--
-- Note: `class` is a Lua pattern, so use ^...$ for an exact match.

-- Keep windows tiled or fullscreen, nothing in between.
--
-- Electron/AppImage apps routinely ask the compositor to float themselves and
-- to open at a preferred size. Freebuff does that, so its main window always
-- came up floating even though nothing in this configuration asked for it. This
-- puts it back into the tiling layout.
--
-- The class is matched exactly, so Freebuff's real dialogs (its "Quit Freebuff?"
-- prompt, its file pickers) keep floating, which is what you want from a dialog.
hl.window_rule({ match = { class = "^@codebuff/freebuff%-desktop$" }, float = false })

-- A FULLSCREEN window is already edge to edge: the compositor puts it at
-- 0,0 with the monitor's full logical size, gaps included. What is left is
-- the 1px border, which Hyprland paints anyway -- a 2px (1 logical px at
-- 1.6x) line of colOnSurface-ish grey down the very top and left of an app
-- that is supposed to be filling the screen. On a bright app it reads as a
-- 1px inset frame, which is exactly the "there is still a border around my
-- fullscreen app" report.
--
-- border_size 0 on fullscreen windows only. Maximized (fs=1) is untouched:
-- it deliberately keeps gaps_out so the desktop still frames it, and it is a
-- different, intentional state.
hl.window_rule({ match = { fullscreen = true }, border_size = 0 })

-- ══ Everything is attached; only dialogs float ══════════════════════════
--
-- Applications belong in the tiling layout. Floating windows can be dragged
-- around, overlap each other and hide whatever is behind them, and this
-- desktop is driven from a touchpad where "find the window and drag it" is
-- exactly the interaction we are removing. Settings and the task manager are
-- the only things that present as cards, and they do that as layer surfaces,
-- not as floating windows.
--
-- This one rule is deliberately a catch-all: it is the ONLY way to also stop
-- the applications that ask the compositor to float themselves (Electron,
-- AppImages, KDE apps, anything with a remembered geometry). Matching each of
-- them by class is a losing game of whack-a-mole.
--
-- 
-- Hyprland applies rules in order and the LAST match wins, so the catch-all is
-- placed here, and the two things that genuinely must float re-assert
-- themselves BELOW it:
--
--   1. transient dialogs -- an "Open File"/"Save As" window is sized by its
--      parent application and is unusable stretched across the screen.
hl.window_rule({ match = { class = ".*" }, float = false })

-- Exception 1: dialogs. Same list the base config floats, re-asserted because
-- the catch-all above would otherwise flatten them, plus the portal backends
-- (the desktop's own file chooser renders as a layer surface, but KDE's and
-- GTK's fallbacks are real windows) and the polkit password agents.
hl.window_rule({ match = { title = "^(Open File|Select a File|Open Folder|Save As|Library|File Upload|Choose wallpaper)(.*)$" }, float = true })
hl.window_rule({ match = { title = "^(.*)(wants to save|wants to open)$" }, float = true })
hl.window_rule({ match = { class = "org.freedesktop.impl.portal.desktop" }, float = true })
hl.window_rule({ match = { class = ".*portal.*" }, float = true })
hl.window_rule({ match = { class = ".*[Pp]olkit.*" }, float = true })
hl.window_rule({ match = { class = "^(org.kde.polkit%-kde%-authentication%-agent%-1|hyprpolkitagent|polkit%-gnome%-authentication%-agent.*)$" }, float = true })
hl.window_rule({ match = { title = "^(Authentication Required|Authenticate)(.*)$" }, float = true })
-- Picture-in-picture and the screen-sharing indicator are overlays by design,
-- not desktop applications; attaching them would defeat their purpose.
hl.window_rule({ match = { title = "^([Pp]icture[-\\s]?[Ii]n[-\\s]?[Pp]icture)(.*)$" }, float = true })
hl.window_rule({ match = { title = ".*is sharing (a window|your screen).*" }, float = true })

-- ══ Wallpaper theatre ════════════════════════════════════════════════════
-- NO RULES. There used to be four here, and there are deliberately none now.
--
-- The theatre went back to being a layer-shell surface on WlrLayer.Overlay,
-- configured exactly like the login screen (see WallpaperModal.qml). Every
-- one of those four rules existed only because it had briefly been a real
-- toplevel:
--
--   float / center -- the tiler's business. A layer surface is placed by the
--     compositor as an overlay and the tiling layout never sees it, so there
--     is nothing to keep the tiler off. That quarter-tile clip (~392x446 with
--     a ~1000px strip hanging outside it, unclickable) was the symptom of
--     making it a toplevel in the first place, and it cannot recur.
--
--   no_blur / xray -- there is no frosted plate left to blur. The surface is
--     `color: "transparent"` with no background fill at all; only a soft
--     darkening fades inward from the four edges of the monitor, which needs
--     no compositor involvement.
--
-- Deleting them is also the honest outcome for a rule layer that has already
-- cost real pain: `blur = true` and `ignore_alpha = 0` are LAYER-rule field
-- names and do not exist on hl.window_rule, so writing them here made the
-- whole config fail to load -- and a config that fails to load takes the
-- GESTURES down with it. Nothing here should be able to do that again.

-- Bitwarden -- floats, and keeps the size the app asked for.
--
-- Which window this actually is, because it is NOT the one the name suggests.
-- The Brave extension's own popup is an xdg_popup: Chromium positions it
-- itself and Hyprland never tiles it, so it cannot be the thing that went
-- wrong. What DOES tile is the Bitwarden DESKTOP app -- /usr/bin/
-- bitwarden-desktop, an Electron binary, pulled in by the extension's native
-- messaging integration. It is an ordinary toplevel, so it met the
-- catch-all `float = false` above and was forced into the tiling layout,
-- which handed it the whole 791x943 work area. A password manager is a
-- small utility panel; letting it take a full workspace is what made it look
-- "so big that it attaches".
--
-- `float = true` alone is the whole fix: a floating window is placed at the
-- size the app requested rather than a size the tiler dictates, so the
-- window comes back to its natural panel size on its own.
--
-- Deliberately NO `size = {...}` pin. Floating already restores the app's
-- own sizing, and pinning one would override the user's own resizes on every
-- reopen -- a rule that looks precise but is quietly hostile. If a specific
-- cap is ever wanted, this is the place to add it.
--
-- `center = true` because a floating panel that appears wherever it happens
-- to land is worse than useless on a tiled desktop.
--
-- Matched on the Electron WM class (`StartupWMClass=Bitwarden` in
-- /usr/share/applications/bitwarden.desktop). `.*[Bb]itwarden.*` would also
-- catch a hypothetical web page with "bitwarden" in its title, so the
-- pattern is anchored to the whole class name.
hl.window_rule({
    name   = "bitwarden-floats",
    match  = { class = "^Bitwarden$" },
    float  = true,
    center = true,
})

-- The bar's popup apps (battery / Wi-Fi / Bluetooth / clock cards).
--
-- Hyprland blurs what is behind these surfaces natively, which is what makes
-- the card read as a floating app sitting on a frosted desktop. Doing it here
-- rather than with a Qt blur inside the shell matters: the Qt effect on a
-- fullscreen surface crashed the whole shell (segfault in
-- QQuickWindow::maybeUpdate) the moment the popup appeared, so the compositor
-- does the blurring instead -- same result, no shader in the shell.
--
-- ignore_alpha 0 blurs the surface's transparent regions too, so the frosting
-- covers the whole screen rather than only the card's own pixels.
hl.layer_rule({ match = { namespace = "quickshell:barPanel" }, blur = true })
hl.layer_rule({ match = { namespace = "quickshell:barPanel" }, ignore_alpha = 0 })


-- The task manager and the other overlay widgets get the same treatment, so
-- they read as a card floating in front of the desktop instead of a sheet of
-- solid colour: the overlay window is a translucent scrim over whatever is
-- behind it, and the compositor blurs that.
hl.layer_rule({ match = { namespace = "quickshell:overlay" }, blur = true })
hl.layer_rule({ match = { namespace = "quickshell:overlay" }, ignore_alpha = 0 })

-- xray OFF for all of them. The base config turns it on for every layer, and
-- with it on a blurred layer samples the WALLPAPER rather than the windows
-- behind it -- which is exactly why the backdrop looked like "the blurred
-- desktop" even with applications open underneath. Off, the blur shows the
-- apps themselves, so the popup reads as sitting in front of the desktop you
-- already had.
hl.layer_rule({ match = { namespace = "quickshell:barPanel" }, xray = false })
hl.layer_rule({ match = { namespace = "quickshell:overlay" }, xray = false })

-- The SUPER-tap app search card gets the same frosting as the bar popups:
-- translucent card + compositor blur, and xray OFF so the blur samples the
-- applications behind it (the desktop stays sharp around the card -- the
-- scrim is only the card-sized window itself, not a full-screen dim).
hl.layer_rule({ match = { namespace = "quickshell:appSearchOverlay" }, blur = true })
hl.layer_rule({ match = { namespace = "quickshell:appSearchOverlay" }, ignore_alpha = 0 })
hl.layer_rule({ match = { namespace = "quickshell:appSearchOverlay" }, xray = false })

-- The clipboard popup (SUPER+V) deliberately does NOT blur.
--
-- It used to, at the same 8px/2-pass radius as the bar popups, on the theory
-- that a translucent card needs a frosted backdrop to read as translucent. On
-- a card this dark and this transparent that is backwards: the frost shows
-- through as a haze, washing the surface out toward the average of whatever
-- is behind it, and the popup read as foggy rather than as glass. It is also
-- the wrong idiom for a full-screen surface -- see the ignore_alpha note
-- below. Turning it off is what makes the darker, more transparent card look
-- like a tinted pane instead of a frosted one.
--
-- "Less blur" cannot be dialled in per layer. Hyprland's layer rule `blur` is
-- a boolean, not a radius: there is no blur_size/blur_passes on a layer rule,
-- only on the global [decoration:blur]. A blur_size field here was tried and
-- Hyprland accepted the reload without complaint while ignoring it entirely,
-- which is the worst possible failure mode -- a config line that looks like it
-- works. The only knob that would soften this without affecting every other
-- blurred surface does not exist, so the honest options were full frost or
-- none, and this asked for none.
--
-- xray is still set: with the blur off it is inert today, but it keeps the
-- intent explicit if the blur is ever turned back on.
hl.layer_rule({ match = { namespace = "quickshell:clipboard" }, blur = false })
hl.layer_rule({ match = { namespace = "quickshell:clipboard" }, xray = false })

-- NO ignore_alpha here, unlike the bar popups above, and that difference is
-- load-bearing. This popup's window is the WHOLE SCREEN -- it carries the
-- outside-press catcher, not just the card -- so ignore_alpha 0 would frost
-- every pixel of the desktop for as long as the popup is open.

-- The desktop overview (the bar's empty stretches, SUPER + four fingers down)
-- deliberately gets NO rule here. It is a full-screen surface that paints its
-- own opaque dimmed wallpaper and floats translucent cards over it, so there
-- is nothing behind it for the compositor to sample: a blur rule on an opaque
-- surface is dead config. (It was tried, and the cards came out flat.)
-- (The settings app and the task manager used to be layer-surface "popup
-- apps" with their own frost rules and morph hosts here; they are ordinary
-- desktop windows now, so the window rules above are all they get. The files
-- app was retired with them -- it is the Explorer desktop app.)
-- ══ The Explorer file picker (org.hypr.Explorer.Picker) ═════════════════
--
-- The desktop's file-chooser dialog ("Add wallpaper", every portal
-- Open/Save dialog -- all render as this one class). It must be a SMALL,
-- DRAGGABLE dialog ANCHORED TO THE TOP-RIGHT CORNER of the focused
-- monitor for its lifetime, and it must never follow desktop switches.
--
-- History: the catch-all float=false above re-asserts itself after
-- map-time state changes, so a bare runtime "float" dispatch lost the
-- race and the picker stayed TILED -- filling the whole screen (the
-- "overlays the entire screen" report). And a runtime pin() DID land --
-- which is exactly wrong for a temporary dialog: pinned windows follow
-- every desktop switch ("not staying on the same desktop").
--
-- The working recipe (both sides): this rule is the login-time baseline,
-- and the picker ALSO anchors itself live with ADDRESS-TARGETED
-- dispatches (float unset + resize + move, coordinates computed there from
-- the window's own monitor -- the dispatcher's move rejects expression
-- strings). That live half is the `window.open` hook at the end of
-- custom/general.lua; it was documented here but missing from the code,
-- which is why the picker arrived TILED and every "open a dropdown" report
-- followed: a fullscreen app lost its fullscreen, and a tiled one reflowed
-- for about a second. NO pin anywhere: the dialog stays on the desktop it
-- was opened on.
--
-- `float = "unset"` is the verb, not `float = true` -- the tiler is what
-- re-asserts float=false afterwards, so the rule has to fight for the
-- window's lifetime, not just at map time.
-- The Explorer window itself is TRANSLUCENT (theme.css paints it at ~82%
-- alpha, matching the shell's see-through background). The base config
-- disables blur for every window, which would leave hard, unreadable
-- see-through text over the desktop -- so re-enable the compositor's
-- frosted blur for Explorer specifically, exactly like the shell's
-- translucent surfaces. (no_blur = false; the field is the base config's
-- own spelling -- hl.window_rule has no positive `blur` field.)
hl.window_rule({
    name    = "explorer-window-blur",
    match   = { class = "^org%.hypr%.Explorer$" },
    no_blur = false,
})

hl.window_rule({
    name  = "explorer-picker-dialog",
    match = { class = "^org%.hypr%.Explorer%.Picker$" },
    float = true,
    size  = { 780, 560 },
})




-- Razer Command Center's "Change charge limit" confirmation.
--
-- GTK4 exposes NO window-type API -- there is no set_type_hint on Gtk.Window
-- and Gdk.Toplevel does not surface one either -- so the app cannot mark
-- itself as a dialog for the compositor, and Hyprland tiles it like any
-- other window. That made a modal confirmation appear as an attached panel
-- filling part of the screen, which is exactly the wrong read for something
-- that restarts the machine.
--
-- Matched on TITLE, not class: the main window is org.matrix.RazerControlCenter
-- and is meant to stay tiled, so a class rule would have floated that too.
-- This title is set by the app on that one window only.
--
-- NO `size` HERE, DELIBERATELY.
--
-- The width comes from the app's own `default_width=370`, and GTK already
-- measures the dialog's content and asks for exactly the height it needs.
-- This rule used to pin size = {370, 560}, and because the compositor hands
-- the client a fixed 560px allocation, GTK laid the ~460px of real content
-- out from the top and left the remainder as empty space at the bottom --
-- a "big spacing under the buttons" that no amount of margin or padding
-- tuning inside the app could ever remove. The padding was never the bug;
-- the extra height was handed to the window from outside it.
--
-- Letting the client size itself is the fix: if the BIOS guide text ever
-- grows or shrinks, the window follows it instead of drifting out of sync.
hl.window_rule({
    name  = "rcc-charge-limit-dialog",
    match = { title = "^Change charge limit$" },
    float = true,
})
