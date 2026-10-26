pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.utils
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Scope {
    id: root

    function dismiss() {
        GlobalStates.regionSelectorOpen = false
    }

    property var action: RegionSelection.SnipAction.Copy
    property var selectionMode: RegionSelection.SelectionMode.RectCorners
    
    Variants {
        model: Quickshell.screens
        delegate: Loader {
            id: regionSelectorLoader
            required property var modelData
            active: GlobalStates.regionSelectorOpen

            sourceComponent: RegionSelection {
                screen: regionSelectorLoader.modelData
                onDismiss: root.dismiss()
                action: root.action
                selectionMode: root.selectionMode
            }
        }
    }

    function screenshot() {
        root.action = RegionSelection.SnipAction.Copy
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    function search() {
        root.action = RegionSelection.SnipAction.Search
        if (Config.options.search.imageSearch.useCircleSelection) {
            root.selectionMode = RegionSelection.SelectionMode.Circle
        } else {
            root.selectionMode = RegionSelection.SelectionMode.RectCorners
        }
        GlobalStates.regionSelectorOpen = true
    }

    function ocr() {
        root.action = RegionSelection.SnipAction.CharRecognition
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    // Record mode is the same surface as a snip, opened with the mode pill
    // already on "Record" (SUPER+S opens it on "Screenshot"; R switches).
    //
    // The old "if already open, close it" here was the only way to STOP a
    // recording: the selector doubled as its own stop button, so pressing
    // record while recording closed the thing that was recording. Stopping
    // now lives in the floating control box that appears once a region is
    // chosen (modules/ii/recording/RecordingPill.qml) -- a surface whose whole
    // job is that recording, visible while it happens.
    function record() {
        root.action = RegionSelection.SnipAction.Record
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    function recordWithSound() {
        root.action = RegionSelection.SnipAction.RecordWithSound
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    // ── The whole-screen snip (SUPER + P) ─────────────────────────────────────
    //
    // Exactly what SUPER+S does to a dragged region, done to the entire output:
    // grim writes the screen into the temp dir, the same ScreenshotAction crop
    // turns it into a clipboard image, and the temp file is removed on the way
    // out. Nothing is left on disk because `screenSnip.savePath` is empty on
    // this machine -- which is what makes this a TEMPORARY copy: it is the
    // clipboard, and the next copy replaces it.
    //
    // Deliberately NOT a "select the whole screen for me" mode inside
    // RegionSelection. That surface exists to be dragged on: opening it would
    // dim the desktop, take the keyboard and ask for a confirmation click --
    // three interruptions to take a picture that needs no input at all.
    //
    // The two halves are one shell command on purpose. Capturing with one
    // process and cropping with another would leave the temp PNG on disk
    // whenever the second one is interrupted (a reload mid-snip), and the temp
    // dir is a fixed path shared with every other snip.
    // ── The TELL (2026-10-15, reported: "a fullscreen screenshot with zero
    //    feedback") ─────────────────────────────────────────────────────────
    //
    // Everything above is about the PICTURE; this is about the ANSWER. The
    // snip is silent by construction -- it opens no surface, dims nothing,
    // asks for nothing -- so when it works the screen does not change at all
    // and when it fails it looks EXACTLY the same: the key was pressed and
    // nothing whatsoever happened. Both halves of that are the bug.
    //
    // The channel is the one the shell already built for exactly this and
    // never called: `StatusSignal.blink(color, text)`, whose own documentation
    // in BarContent.qml names the screenshot as a caller. It draws the bar's
    // under-island line in the given colour with the sentence beside it, and
    // StatusTell mirrors the same blink into the top-right corner when a
    // fullscreen window owns the screen -- which is precisely where this
    // snip is most likely to be used.
    //
    // The EXIT STATUS is why this is a Process and not the `execDetached` it
    // was: a detached command cannot say whether grim wrote anything, whether
    // magick could read it, or whether wl-copy took the selection, and a
    // silent failure is the half of "no feedback" that actually costs data --
    // the user walks away believing the screenshot is in the clipboard.
    // Failures now blink in the theme's error colour with their own sentence,
    // so both answers are visible and they are told apart by colour.
    readonly property color snipOkColor: "#2BD86B"
    readonly property color snipFailColor: Appearance.colors.colError

    function announceSnip(exitCode) {
        if (exitCode === 0) {
            StatusSignal.blink(root.snipOkColor, Translation.tr("Screenshot copied"))
            return
        }
        console.warn(`[Region Selector] Whole-screen snip: failed with exit code ${exitCode}.`)
        StatusSignal.blink(root.snipFailColor, Translation.tr("Screenshot failed"))
    }

    function screenshotFullScreen() {
        const screen = Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
            ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)
        if (!screen) {
            console.warn("[Region Selector] Whole-screen snip: no screen to capture.")
            StatusSignal.blink(root.snipFailColor, Translation.tr("Screenshot failed"))
            return
        }
        const scale = Hyprland.monitorFor(screen)?.scale ?? 1
        const dir = Directories.screenshotTemp
        const path = `${dir}/image-${screen.name}`
        const saveDir = Config.options.screenSnip.savePath !== ""
            ? Config.options.screenSnip.savePath : ""
        // ScreenshotAction speaks the geometry in PHYSICAL pixels (that is what
        // it crops out of the grim file, and what every other snip multiplies
        // its logical region by -- see RegionSelection.snip).
        const copy = ScreenshotAction.getCommand(
            0, 0, screen.width * scale, screen.height * scale,
            path, ScreenshotAction.Action.Copy, saveDir)
        // Command first, then start: the binding below reads the string, and a
        // press that arrives while the previous snip is still in flight is
        // dropped rather than queued -- two captures of the same instant are
        // one capture too many, and the running one answers for both.
        fullSnip.shellCommand =
            `mkdir -p '${StringUtils.shellSingleQuoteEscape(dir)}'`
            + ` && grim -o '${StringUtils.shellSingleQuoteEscape(screen.name)}' '${StringUtils.shellSingleQuoteEscape(path)}'`
            + ` && ${copy[2]}`
        fullSnip.running = true
    }

    Process {
        id: fullSnip
        property string shellCommand: ""
        command: ["bash", "-c", fullSnip.shellCommand]
        onExited: (exitCode, exitStatus) => root.announceSnip(exitCode)
    }

    IpcHandler {
        target: "region"

        function screenshot() {
            root.screenshot()
        }
        function search() {
            root.search()
        }
        function ocr() {
            root.ocr()
        }
        function record() {
            root.record()
        }
        function recordWithSound() {
            root.recordWithSound()
        }
        // qs -c ii ipc call region screenshotFullScreen
        function screenshotFullScreen() {
            root.screenshotFullScreen()
        }
    }

    GlobalShortcut {
        name: "regionScreenshot"
        description: "Takes a screenshot of the selected region"
        onPressed: root.screenshot()
    }
    GlobalShortcut {
        name: "regionSearch"
        description: "Searches the selected region"
        onPressed: root.search()
    }
    GlobalShortcut {
        name: "regionOcr"
        description: "Recognizes text in the selected region"
        onPressed: root.ocr()
    }
    GlobalShortcut {
        name: "regionRecord"
        description: "Records the selected region"
        onPressed: root.record()
    }
    GlobalShortcut {
        name: "regionRecordWithSound"
        description: "Records the selected region with sound"
        onPressed: root.recordWithSound()
    }
    GlobalShortcut {
        name: "regionScreenshotFull"
        description: "Copies a screenshot of the whole screen to the clipboard"
        onPressed: root.screenshotFullScreen()
    }
}
