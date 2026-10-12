import QtQuick
import Quickshell

import qs.modules.common
import qs.modules.ii.background
import qs.modules.ii.bar
import qs.modules.ii.cheatsheet
import qs.modules.ii.desktopIndicator
import qs.modules.ii.dock
import qs.modules.ii.edgeReveal
import qs.modules.ii.lock
import qs.modules.ii.mediaControls
import qs.modules.ii.notificationPopup
import qs.modules.ii.onScreenDisplay
import qs.modules.ii.onScreenKeyboard
import qs.modules.ii.overview
import qs.modules.ii.polkit
import qs.modules.ii.recording
import qs.modules.ii.regionSelector
import qs.modules.ii.screenCorners
import qs.modules.ii.screenTranslator
import qs.modules.ii.sessionScreen
import qs.modules.ii.sidebarLeft
import qs.modules.ii.sidebarRight
import qs.modules.ii.switcher
import qs.modules.ii.taskManager
import qs.modules.ii.overlay
import qs.modules.ii.verticalBar
import qs.modules.ii.visualSizer
import qs.modules.ii.wallpaperSelector

Scope {
    // The bar, the dock and the vertical bar can each be switched off entirely in
    // Settings > Bar. `bar.enable` is the master switch: with it off neither bar
    // variant is loaded at all, so nothing is drawn and nothing holds an edge of
    // the screen.
    PanelLoader { extraCondition: Config.options.bar.enable && !Config.options.bar.vertical; component: Bar {} }
    PanelLoader { component: Background {} }
    // The theatre's interactive host: while the stage is open this TOP-layer
    // window owns the carousel (bottom-layer surfaces lose pointer events to
    // focused windows), backdrop presses and Escape.
    PanelLoader { component: WallpaperModal {} }
    // (The pill's Top-layer input proxy was retired: the pill now answers
    // input only while the active desktop is empty, and on an empty desktop
    // the bottom layer receives pointer events natively -- no proxy needed.
    // The volume rail's proxy went with the rail itself: the SoundBar desktop
    // widget was removed, so SoundProxy.qml is deleted too.)
    PanelLoader { component: Cheatsheet {} }
    PanelLoader { component: ClipboardListWindow {} }
    PanelLoader { extraCondition: Config.options.dock.enable; component: Dock {} }
    // The desktops, out of the bar and into a small capsule at the bottom of
    // the screen (see the module: it yields to the dock and to fullscreen).
    PanelLoader { component: DesktopIndicator {} }
    PanelLoader { component: LoadingIndicator {} }
    // The fullscreen tell: the same status pulses as the bar's indication
    // line, drawn tiny in the top-right corner while a fullscreen window
    // covers the screen (the bar -- and with it the line -- is hidden there).
    PanelLoader { component: StatusTell {} }
    PanelLoader { component: EdgeReveal {} }
    PanelLoader { component: Lock {} }
    PanelLoader { component: MusicPlayerPanel {} }
    PanelLoader { component: NotificationPopup {} }
    PanelLoader { component: OnScreenDisplay {} }
    // "Going to sleep": raised by the sleep hook (custom/scripts/before-sleep.sh)
    // a beat before the panel goes down. A wash with a label, no input -- the
    // alternative was a black screen that looks like a crash.
    PanelLoader { component: SleepNotice {} }
    PanelLoader { component: OnScreenKeyboard {} }
    PanelLoader { component: Overlay {} }
    PanelLoader { component: Overview {} }
    // The SUPER-tap app search overlay (the approved preview design).
    PanelLoader { component: AppSearchOverlay {} }
    // The desktop overview the bar's empty stretches open (design A).
    PanelLoader { component: DesktopOverview {} }
    PanelLoader { component: Polkit {} }
    PanelLoader { component: RegionSelector {} }
    // The SUPER+R quick-record status pill (only visible while recording).
    PanelLoader { component: RecordingPill {} }
    // The visual window sizer (SUPER+SHIFT+R / dock right-click "Resize…"):
    // an accent frame with drag handles around the armed window.
    PanelLoader { component: VisualSizerWindow {} }
    PanelLoader { component: ScreenCorners {} }
    PanelLoader { component: ScreenTranslator {} }
    PanelLoader { component: SessionScreen {} }
    PanelLoader { component: SidebarLeft {} }
    PanelLoader { component: SidebarRight {} }
    PanelLoader { component: Switcher {} }
    // The task manager rides the OVERLAY layer (see TaskManagerOverlay.qml):
    // it is the only surface kind that renders above a fullscreen client, so
    // "always in front" holds no matter what is open.
    PanelLoader { component: TaskManagerOverlay {} }
    PanelLoader { extraCondition: Config.options.bar.enable && Config.options.bar.vertical; component: VerticalBar {} }
    PanelLoader { component: WallpaperSelector {} }
}
