pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.widgets.widgetCanvas
import qs.modules.common.functions as CF
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

import qs.modules.ii.background.widgets
import qs.modules.ii.background.widgets.weather

Variants {
    id: root
    model: Quickshell.screens

    PanelWindow {
        id: bgRoot

        required property var modelData

        // Hide when fullscreen
        property list<HyprlandWorkspace> workspacesForMonitor: Hyprland.workspaces.values.filter(workspace => workspace.monitor && workspace.monitor.name == monitor.name)
        // ═══ Is the ACTIVE desktop fullscreen? (fixed 2026-10-02) ═══════
        //
        // This used to be a filter over the Quickshell toplevel model:
        //
        //   workspacesForMonitor.filter(w =>
        //       w.toplevels.values.filter(t => t.wayland?.fullscreen)[0] != undefined
        //       && w.active)[0] != undefined
        //
        // and that model was measured going wrong in BOTH directions on this
        // machine -- its toplevel array for the active workspace read 0
        // entries while `hyprctl` reported a window there, and it grew
        // 1,3,4,4 across four desktop switches because torn-down entries
        // linger with their flags intact.
        //
        // Leaving a fullscreen desktop is where both faults show. The stale
        // entry keeps `fullscreenHidesContent` true for a frame or two after
        // the compositor has already moved, and this surface's `color` is
        // TRANSPARENT whenever the wallpaper is hidden -- so for that window
        // the wallpaper is faded out AND the surface behind it is not there,
        // and the flat compositor clear colour shows through the whole screen.
        // That is the reported "static background colour disappears for a
        // second", and it arrives with the freeze because the same
        // miscounting re-evaluates the parallax and the desktop widgets
        // against the wrong window list while it is wrong.
        //
        // `HyprlandData.windowList` is a `hyprctl clients -j` re-read -- the
        // compositor's own answer rather than a cached mirror of it, and the
        // same authority the bar's fullscreen path already uses (see
        // Bar.qml:fullscreenOnMonitor, which was fixed for this identical
        // fault). One source, one answer, for both surfaces.
        //
        // `fullscreen` is 2 for a real fullscreen window and 0 otherwise; a
        // maximized window (1) keeps its own chrome and is the cover path's
        // business, not the wallpaper's. `hidden` is skipped because
        // hyprland does not set it for a window parked on a special workspace
        // -- the workspace test below is the only reliable "is on screen".
        readonly property bool activeWorkspaceIsFullscreen: {
            const ws = Number(monitor?.activeWorkspace?.id ?? -1);
            if (ws < 1)
                return false;
            const list = HyprlandData.windowList ?? [];
            for (let i = 0; i < list.length; i++) {
                const c = list[i];
                if (Number(c?.fullscreen) !== 2)
                    continue;
                if (Number(c?.workspace?.id) !== ws)
                    continue;
                return true;
            }
            return false;
        }
        // The fullscreen gate no longer un-maps the whole layer. Toggling
        // `visible` on a layer-shell surface REMAPS it, and every remap
        // re-decodes the wallpaper from scratch (status resets -> the image
        // snaps to opacity 0 and fades back) plus a rebuild flash in every
        // widget above -- that was the glitch on each "+"-click that left a
        // fullscreen workspace. The layer stays mapped; the CONTENT fades.
        readonly property bool fullscreenHidesContent: Config?.options.background.hideWhenFullscreen
            && !GlobalStates.screenLocked
            && bgRoot.activeWorkspaceIsFullscreen

        // Workspaces
        property HyprlandMonitor monitor: Hyprland.monitorFor(modelData)

        // Widgets yield to apps: when ANY window sits on this monitor's
        // active desktop, the desktop widgets (weather, wallpaper button,
        // volume rail) step aside -- the user is working, not grooming the
        // desktop. The wallpaper itself stays. The picking stage and the
        // lock screen bring them back regardless.
        // Desktop edit mode brings them back too: the mode only ever engages
        // on an empty desktop, and a groom-the-desktop session needs the
        // widgets even if a stale window list still reports one somewhere.
        readonly property int activeWsId: monitor?.activeWorkspace?.id ?? -1
        readonly property bool activeDesktopHasWindows: activeWsId >= 0
            && HyprlandData.windowList.some(w => (w.workspace?.id ?? -1) === activeWsId)
        readonly property bool widgetsVisible: !activeDesktopHasWindows
            || GlobalStates.wallpaperStageOpen
            || GlobalStates.screenLocked
            || GlobalStates.desktopEditMode
        // Edit mode is an empty-desktop state: the moment an app window lands
        // on this desktop (or the screen locks), the mode is over. Watching
        // it here -- where the window list is already being read -- means the
        // user can never drag widgets under a window that just opened.
        onActiveDesktopHasWindowsChanged: {
            if (activeDesktopHasWindows && !GlobalStates.screenLocked)
                GlobalStates.exitDesktopEditMode();
        }
        Connections {
            target: GlobalStates
            function onScreenLockedChanged() {
                if (GlobalStates.screenLocked)
                    GlobalStates.exitDesktopEditMode();
            }
        }
        property list<var> relevantWindows: HyprlandData.windowList.filter(win => win.monitor == monitor?.id && win.workspace.id >= 0).sort((a, b) => a.workspace.id - b.workspace.id)
        property int firstWorkspaceId: relevantWindows[0]?.workspace.id || 1
        property int lastWorkspaceId: relevantWindows[relevantWindows.length - 1]?.workspace.id || 10
        property int workspaceChunkSize: Config?.options.bar.workspaces.shown ?? 10
        property int totalWorkspaces: Math.ceil(lastWorkspaceId / workspaceChunkSize) * workspaceChunkSize
        // ── The OLED clock wallpaper ────────────────────────────────────
        //
        // When on, the PICTURE is not drawn at all; ClockWallpaper.qml paints
        // the pen's own #282828 page and the neumorphic clock with its hourly
        // line on it, and that is the whole desktop. (It was pure black for a
        // while -- an OLED panel off everywhere the clock is not -- but a
        // neumorphic dial is the same grey as its page, so on black the effect
        // had nowhere to live.) The wallpaper PATH is deliberately left alone -- it
        // is what the theme palette and the lock screen read, so this mode
        // costs no re-theming and turning it off brings the picture straight
        // back.
        readonly property bool clockWallpaperEnabled: Config.options.background.clockWallpaper?.enable ?? false
        // Wallpaper
        // Resolved through Appearance, so with a separate light/dark wallpaper
        // turned on this follows the theme the moment it changes.
        property bool wallpaperIsVideo: Appearance.themeWallpaperPath.endsWith(".mp4") || Appearance.themeWallpaperPath.endsWith(".webm") || Appearance.themeWallpaperPath.endsWith(".mkv") || Appearance.themeWallpaperPath.endsWith(".avi") || Appearance.themeWallpaperPath.endsWith(".mov")
        property string wallpaperPath: wallpaperIsVideo ? Config.options.background.thumbnailPath : Appearance.themeWallpaperPath
        // Wallpaper transition state: true while the incoming picture is
        // animating in over the old one (Connections on Wallpapers.changed).
        property bool transitionRunning: false
        property bool wallpaperSafetyTriggered: {
            const enabled = Config.options.workSafety.enable.wallpaper;
            const sensitiveWallpaper = (CF.StringUtils.stringListContainsSubstring(wallpaperPath.toLowerCase(), Config.options.workSafety.triggerCondition.fileKeywords));
            const sensitiveNetwork = (CF.StringUtils.stringListContainsSubstring(Network.networkName.toLowerCase(), Config.options.workSafety.triggerCondition.networkNameKeywords));
            return enabled && sensitiveWallpaper && sensitiveNetwork;
        }
        readonly property real parallaxRation: Config.options.background.parallax.workspaceZoom
        property real minSuitableScale: 1 // Some reasonable init, to be updated
        property real effectiveWallpaperScale: minSuitableScale * parallaxRation
        property int wallpaperWidth: modelData.width // Some reasonable init value, to be updated
        property int wallpaperHeight: modelData.height // Some reasonable init value, to be updated
        // Nothing here holds slack for a jolt. These used to add
        // `bumpSlack` so the wallpaper had room to slide sideways when a
        // swipe hit a desktop that did not exist; that gesture no longer
        // moves the picture, so the wallpaper is exactly the screen again.
        property real scaledWallpaperWidth: Math.max(wallpaperWidth * effectiveWallpaperScale, screen.width)
        property real scaledWallpaperHeight: Math.max(wallpaperHeight * effectiveWallpaperScale, screen.height)
        property real parallaxTotalPixelsX: Math.max(0, scaledWallpaperWidth - screen.width)
        property real parallaxTotalPixelsY: Math.max(0, scaledWallpaperHeight - screen.height)
        readonly property bool verticalParallax: (Config.options.background.parallax.autoVertical && wallpaperHeight > wallpaperWidth) || Config.options.background.parallax.vertical
        // Colors
        property bool shouldBlur: (GlobalStates.screenLocked && Config.options.lock.blur.enable)
        property color dominantColor: Appearance.colors.colPrimary // Default, to be changed
        property bool dominantColorIsDark: dominantColor.hslLightness < 0.5
        property color colText: {
            if (wallpaperSafetyTriggered)
                return CF.ColorUtils.mix(Appearance.colors.colOnLayer0, Appearance.colors.colPrimary, 0.75);
            return (GlobalStates.screenLocked && shouldBlur) ? Appearance.colors.colOnLayer0 : CF.ColorUtils.colorWithLightness(Appearance.colors.colPrimary, (dominantColorIsDark ? 0.8 : 0.12));
        }
        Behavior on colText {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        // Layer props
        screen: modelData
        exclusionMode: ExclusionMode.Ignore
        // While locked the blurred wallpaper must still cover the tiled
        // windows, so it leaves Bottom -- but it must NEVER sit on Overlay:
        // that is the lock window's layer, and same-layer stacking depends
        // on map order. The old condition flipped this surface to Overlay
        // only AFTER the blur scale animation finished (~400ms post-lock),
        // remapping it on top of the already-mapped lock and hiding the
        // whole lock screen one second after it appeared. Top renders above
        // every normal window yet strictly below Overlay, so the lock is
        // guaranteed on top no matter which surface maps first.
        WlrLayershell.layer: GlobalStates.screenLocked ? WlrLayer.Top : WlrLayer.Bottom
        // WlrLayershell.layer: WlrLayer.Bottom
        // While the wallpaper theatre is open the background surface takes
        // OnDemand keyboard focus: the click that opened it already focused
        // this surface, so Escape reaches the widget's close handler. Outside
        // the theatre it claims nothing, so desktop focus flows are untouched.
        WlrLayershell.keyboardFocus: GlobalStates.wallpaperStageOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "quickshell:background"
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        // THE BACKDROP. Painted with the wallpaper's own dominant colour, NOT
        // "transparent".
        //
        // This is the fix for the ~1s flat-colour flash on leaving a fullscreen
        // workspace, and it is a backdrop fix rather than a timing fix because
        // the gap is unavoidable: `visible` going false on the wallpaper drops
        // the decoded texture, so the next show has to decode a 5120x2880 JPEG
        // again. Measured on this machine: ~345ms for that decode, which is the
        // flash. No animation tuning removes a window that is a disk read.
        //
        // What animation tuning CAN do is make sure something in the picture's
        // own colour is on screen for the whole of it. With "transparent" here,
        // those frames showed Hyprland's bare background_color -- a flat colour
        // unrelated to the wallpaper, which is why it read as a glitch.
        // Painted with the wallpaper's dominant tone, the same frames show a
        // plausible continuation of the picture, so the decode is invisible.
        //
        // The quantizer is depth:0, so colors[0] is the dominant colour, and it
        // is already computed for wallpaperVibrancy -- this costs nothing extra.
        //
        // wallpaperSafetyTriggered keeps its old behaviour deliberately: when
        // the wallpaper is being hidden for safety, its colour must NOT be on
        // screen, so that branch stays as it was.
        color: {
            // Pure black, not the picture's dominant tone: the point of the
            // clock wallpaper is that the panel is switched off everywhere the
            // clock is not.
            if (bgRoot.clockWallpaperEnabled)
                return "#000000";
            if (bgRoot.wallpaperSafetyTriggered && !bgRoot.wallpaperIsVideo)
                return CF.ColorUtils.mix(Appearance.colors.colLayer0, Appearance.colors.colPrimary, 0.75);
            return Appearance.wallpaperDominantColor;
        }
        Behavior on color {
            // Long enough to cross-fade when the wallpaper actually changes,
            // but NOT so long that it is still visibly travelling during a
            // fullscreen exit. 200ms: a colour tween is cheap (no decode), and
            // it finishes well inside the ~345ms the wallpaper needs anyway.
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        onWallpaperPathChanged: {
            bgRoot.updateZoomScale();
            // Clock position gets updated after zoom scale is updated
        }

        // Wallpaper zoom scale
        function updateZoomScale() {
            getWallpaperSizeProc.path = bgRoot.wallpaperPath;
            getWallpaperSizeProc.running = true;
        }
        Process {
            id: getWallpaperSizeProc
            property string path: bgRoot.wallpaperPath
            command: ["magick", "identify", "-format", "%w %h", path]
            stdout: StdioCollector {
                id: wallpaperSizeOutputCollector
                onStreamFinished: {
                    const output = wallpaperSizeOutputCollector.text;
                    const [width, height] = output.split(" ").map(Number);
                    const [screenWidth, screenHeight] = [bgRoot.screen.width, bgRoot.screen.height];
                    bgRoot.wallpaperWidth = width;
                    bgRoot.wallpaperHeight = height;

                    // Perfect image; scale = 1
                    // Small picture; scale > 1; will zoom in the picture
                    // Big picture; scale < 1; will zoom out the picture
                    // Choose max number so every side will fit
                    bgRoot.minSuitableScale = Math.max(screenWidth / width, screenHeight / height);
                }
            }
        }

        Item {
            id: bgContent
            anchors.fill: parent
            // Smooth hide, near-instant show (see the fullscreen gate on bgRoot):
            // entering a fullscreen workspace eases the desktop content away
            // under the app, but LEAVING one must not fade the wallpaper in
            // from nothing.
            opacity: bgRoot.fullscreenHidesContent ? 0 : 1
            // NOT `visible: opacity > 0.01`.
            //
            // That line is what turned a fade into a reload. Going false
            // unloads the wallpaper's decoded texture, so the next show has to
            // decode the 5120x2880 source again -- measured ~345ms -- and the
            // frames spent decoding are exactly the frames that used to show
            // bare background_color.
            //
            // With `visible` left alone, an Item at opacity 0 is skipped by the
            // renderer but KEEPS its textures, so leaving fullscreen is a
            // composite of pixels that are already in memory: no disk read, no
            // decode, no gap. The performance win the hide exists for is
            // unaffected -- nothing is rasterised at opacity 0 -- and the
            // reload cost it was paying is simply gone.
            Behavior on opacity {
                NumberAnimation {
                    // 280ms out (unchanged: the ease-away under the app should
                    // stay unhurried), but 90ms in rather than 0.
                    //
                    // The show is not instant because the WALLPAPER can now be
                    // composited from cache, so what is left to cover is only the
                    // compositor's own surface commit -- a frame or two. 90ms
                    // finishes inside that and still reads as immediate, where 0
                    // could expose a single frame of the backdrop if the commit
                    // were ever slow.
                    duration: bgRoot.fullscreenHidesContent ? 280 : 90
                    easing.type: Easing.OutCubic
                }
            }
            StyledImage {
                id: wallpaper
                // Same reasoning as bgContent: `visible: opacity > 0` would drop
                // the decoded texture on every fullscreen entry and force a
                // ~345ms re-decode of the 5120x2880 source on the way back --
                // which is the flash. blurLoader still gates visibility (a blur
                // pass genuinely replaces the image, so hiding it there is
                // correct), but opacity is left to the renderer to skip.
                visible: !blurLoader.active
                opacity: (status === Image.Ready && !bgRoot.wallpaperIsVideo) ? 1 : 0
                // TRUE, deliberately -- this is the other half of the fix.
                //
                // `cache: false` tells Qt to drop the decoded pixmap as soon as
                // it is uploaded, so every re-show costs a fresh decode of a
                // 3-4MB 5120x2880 JPEG (~345ms measured). With it true the
                // pixmap stays resident and a re-show is a texture bind.
                //
                // Cost: one decoded wallpaper held in RAM. That is the same
                // trade every wallpaper daemon makes, and it buys the flash
                // fix outright. `asynchronous: true` below keeps the initial
                // decode off the UI thread, so the first paint is not blocked
                // by retaining it.
                cache: true
                smooth: false

                // `monitor?.` and not `monitor.` -- `monitor` is
                // Hyprland.monitorFor(modelData), which is NULL until
                // Hyprland's monitor list arrives. Lines 53 and 75 in this
                // file already guard it; this one did not, and it evaluated
                // during construction, so the TypeError ("Cannot read
                // property 'activeWorkspace' of null") aborted the object
                // tree before a single window was mapped -- an invisible
                // shell: no wallpaper, no bar, no pill, nothing, while the
                // process was still alive and answering IPC.
                property int workspaceIndex: (bgRoot.monitor?.activeWorkspace?.id ?? 1) - 1
                property real middleFraction: 0.5
                property real fraction: {
                    // 0 - start of the picture
                    // 1 - end of the picture
                    if (bgRoot.totalWorkspaces <= 1) {
                        return middleFraction;
                    }
                    return Math.max(0, Math.min(1, workspaceIndex / (bgRoot.totalWorkspaces - 1)));
                }

                property real usedFractionX: {
                    let usedFraction = middleFraction;
                    if (Config.options.background.parallax.enableWorkspace && !bgRoot.verticalParallax) {
                        usedFraction = fraction;
                    }
                    if (Config.options.background.parallax.enableSidebar) {
                        let sidebarFraction = bgRoot.parallaxRation / bgRoot.workspaceChunkSize / 2;
                        usedFraction += (sidebarFraction * GlobalStates.sidebarRightOpen - sidebarFraction * GlobalStates.sidebarLeftOpen);
                    }
                    return Math.max(0, Math.min(1, usedFraction));
                }
                property real usedFractionY: {
                    let usedFraction = middleFraction;
                    if (Config.options.background.parallax.enableWorkspace && bgRoot.verticalParallax) {
                        usedFraction = fraction;
                    }
                    return Math.max(0, Math.min(1, usedFraction));
                }

                x: {
                    if (bgRoot.screen.width > width) {
                        // Center the picture
                        return (bgRoot.screen.width - width) / 2;
                    }
                    return - bgRoot.parallaxTotalPixelsX * usedFractionX;
                }
                y: {
                    if (bgRoot.screen.height > height) {
                        // Center the picture
                        return (bgRoot.screen.height - height) / 2;
                    }
                    return - bgRoot.parallaxTotalPixelsY * usedFractionY;
                }

                // No source at all in clock-wallpaper mode: an invisible image
                // that still decodes a 5120x2880 JPEG is exactly the disk read
                // this mode exists to avoid.
                source: (bgRoot.wallpaperSafetyTriggered || bgRoot.clockWallpaperEnabled) ? "" : bgRoot.wallpaperPath
                fillMode: Image.PreserveAspectCrop
                Behavior on x {
                    NumberAnimation {
                        duration: 600
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on y {
                    NumberAnimation {
                        duration: 600
                        easing.type: Easing.OutCubic
                    }
                }
                width: bgRoot.scaledWallpaperWidth
                height: bgRoot.scaledWallpaperHeight
            }

            // ══ Wallpaper transitions ══════════════════════════════════════
            // The incoming wallpaper is drawn by the crossfade layer on top;
            // the base wallpaper cross-fades underneath it. Each apply plays
            // one consistent choreography: the image rises in and fades up
            // while blooming to rest -- clean and quick, no bloat.
            // (transitionRunning lives on bgRoot — see the PanelWindow block)

            Connections {
                target: Wallpapers
                function onChanged() {
                    // One consistent choreography per apply: the image rises
                    // in and fades up while blooming to rest -- clean, quick,
                    // no bloat.
                    const duration = 420;
                    bgRoot.transitionRunning = true;
                    transitionImage.opacity = 0;
                    transitionImage.scale = 1.06;
                    transitionRise.y = 60;
                    riseAnim.duration = duration;
                    bloomAnim.duration = duration;
                    fadeAnim.duration = duration;
                    transitionAnim.start();
                }
            }

            StyledImage {
                id: transitionImage
                // Hidden whenever the shell is locked: the lock screen's blur
                // layer owns the picture then.
                visible: bgRoot.transitionRunning && opacity > 0 && !GlobalStates.screenLocked
                anchors {
                    horizontalCenter: wallpaper.horizontalCenter
                    verticalCenter: wallpaper.verticalCenter
                }
                width: wallpaper.width
                height: wallpaper.height
                source: (bgRoot.wallpaperSafetyTriggered || bgRoot.clockWallpaperEnabled) ? "" : bgRoot.wallpaperPath
                fillMode: Image.PreserveAspectCrop
                cache: false
                asynchronous: true
                opacity: 0
                scale: 1

                // Only the wallpaper's own rise. The second Translate that
                // used to sit in this list carried the bump, so a change
                // during a jolt did not drag the outgoing picture sideways
                // with the incoming one.
                transform: Translate {
                    id: transitionRise
                    y: 0
                }

                Behavior on opacity {
                    NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
                }
                Behavior on scale {
                    NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
                }
            }

            ParallelAnimation {
                id: transitionAnim
                alwaysRunToEnd: true
                onStopped: {
                    transitionRise.y = 0;
                    transitionImage.scale = 1;
                    bgRoot.transitionRunning = false;
                }

                NumberAnimation {
                    id: fadeAnim
                    target: transitionImage
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: 420
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    id: riseAnim
                    target: transitionRise
                    property: "y"
                    from: 60
                    to: 0
                    duration: 420
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    id: bloomAnim
                    target: transitionImage
                    property: "scale"
                    from: 1.06
                    to: 1
                    duration: 420
                    easing.type: Easing.OutCubic
                }
            }

            Loader {
                id: blurLoader
                // Owns the blurred wallpaper for both consumers: the lock
                // screen (when lock blur is on) and the wallpaper stage's
                // dark theatre. The stage must not depend on the lock-blur
                // setting being enabled.
                // The stage-exit latch keeps the loader alive while the
                // scrim's fade-out plays: deactivating a Loader is instant
                // and un-animated. (The scrim itself lives OUTSIDE this
                // loader -- a Loader-created item is destroyed and recreated
                // on the active flicker at close, which snapped its opacity
                // to its initial value and cut the fade dead.)
                readonly property bool stageExitLatch: stageExitHold.running
                active: (Config.options.lock.blur.enable && (GlobalStates.screenLocked || scaleAnim.running))
                    || GlobalStates.wallpaperStageOpen || stageExitLatch
                anchors.fill: wallpaper
                scale: GlobalStates.screenLocked ? Config.options.lock.blur.extraZoom : 1
                Behavior on scale {
                    NumberAnimation {
                        id: scaleAnim
                        duration: 400
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.animationCurves.expressiveDefaultSpatial
                    }
                }
                sourceComponent: GaussianBlur {
                    source: wallpaper
                    radius: GlobalStates.screenLocked ? Config.options.lock.blur.radius : 36
                    samples: radius * 2 + 1

                    Rectangle {
                        // Fills the GaussianBlur's content so the blur has a
                        // well-defined source extent on transparent edges.
                        anchors.fill: parent
                        color: "transparent"
                    }
                }
            }

            // The theatre scrim, now a PERSISTENT item: near-black glass
            // flooding the screen while the wallpaper stage is open, fading
            // on the same beat as the blur. Because it is never destroyed,
            // its opacity Behavior actually PLAYS on close -- which is the
            // whole point; the loader above only owns the blur.
            Rectangle {
                anchors.fill: wallpaper
                opacity: GlobalStates.wallpaperStageOpen
                    || (GlobalStates.screenLocked && Config.options.lock.blur.enable) ? 1 : 0
                color: Appearance.m3colors.darkmode
                    ? Qt.rgba(0.03, 0.03, 0.045, 0.78)
                    : Qt.rgba(0.07, 0.07, 0.09, 0.72)
                Behavior on opacity {
                    NumberAnimation { duration: 380; easing.type: Easing.OutCubic }
                }
            }

            // Arms when the stage closes; keeps the blur loader mapped until
            // the scrim fade (380ms) has fully played.
            Timer {
                id: stageExitHold
                interval: 430
            }
            Connections {
                target: GlobalStates
                function onWallpaperStageOpenChanged() {
                    if (!GlobalStates.wallpaperStageOpen)
                        stageExitHold.restart();
                }
            }

            // ── The clock wallpaper ────────────────────────────────────
            //
            // Above the blur and the theatre scrim (so a lock blur cannot
            // smear a live clock) and below the widget canvas. Hidden while
            // locked on purpose: the lock screen has its own clock, and two
            // clocks on one screen is never the answer.
            ClockWallpaper {
                id: clockWallpaper
                anchors.fill: parent
                visible: bgRoot.clockWallpaperEnabled
                opacity: GlobalStates.screenLocked ? 0 : 1
                Behavior on opacity {
                    NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
                }
            }

            WidgetCanvas {
                id: widgetCanvas
                width: parent.width
                height: parent.height
                readonly property real parallaxFactor: {
                    var f = Config.options.background.parallax.widgetsFactor;
                    return f / bgRoot.parallaxRation;
                }
                readonly property real baseWallpaperOffsetX: (bgRoot.screen.width - wallpaper.width) / 2
                readonly property real baseWallpaperOffsetY: (bgRoot.screen.height - wallpaper.height) / 2
                readonly property real wallpaperTotalOffsetX: wallpaper.x - baseWallpaperOffsetX
                readonly property real wallpaperTotalOffsetY: wallpaper.y - baseWallpaperOffsetY
                readonly property bool locked: GlobalStates.screenLocked
                x: wallpaperTotalOffsetX * parallaxFactor * !locked
                y: wallpaperTotalOffsetY * parallaxFactor * !locked

                transitions: Transition {
                    PropertyAnimation {
                        properties: "width,height"
                        duration: Appearance.animation.elementMove.duration
                        easing.type: Appearance.animation.elementMove.type
                        easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                    }
                    AnchorAnimation {
                        duration: Appearance.animation.elementMove.duration
                        easing.type: Appearance.animation.elementMove.type
                        easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                    }
                }

                FadeLoader {
                    shown: Config.options.background.widgets.weather.enable && bgRoot.widgetsVisible
                    sourceComponent: WeatherWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                    }
                }

                // The wallpaper pill: the one stackable desktop control left
                // (the sound rail's pill stack went with SoundBar).
                FadeLoader {
                    shown: Config.options.background.widgets.wallpaper.enable && bgRoot.widgetsVisible
                    sourceComponent: WallpaperWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                    }
                }

            }
        }
    }
}
