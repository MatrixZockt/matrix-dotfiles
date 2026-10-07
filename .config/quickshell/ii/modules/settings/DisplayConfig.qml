import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions as CF
import QtQuick
import QtQuick.Layouts
import Quickshell
// `Process`/`StdioCollector` (reading `hyprctl`) and `Hyprland.focusedMonitor`
// (which panel this page is about). Omitting either import kills the whole
// config, not just this file -- so both are here explicitly.
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Display -- the Windows "System > Display" page.
 *
 * Windows puts everything about the screen on one page, in one order, and it
 * is the page people open most often after "it looks wrong". This is that
 * page, laid out the same way: brightness and night light first (the two you
 * reach for at night), then the panel itself (scale, refresh, VRR,
 * orientation), then what the panel is doing (render quality).
 *
 * THE HONEST CONSTRAINT, because it shapes every choice here:
 *
 * This Hyprland runs a LUA config, and its monitor dispatcher is an empty
 * table -- `hl.dsp.monitor` has no sub-fields at all, and `hyprctl keyword`
 * answers "keyword can't work with non-legacy parsers". So there is no live
 * "set this monitor's scale now" call to make. Verified by probing the
 * dispatcher table at runtime, not assumed.
 *
 * What DOES work is the path the shell already uses for scale:
 * `custom/scripts/apply-display.sh --scale N`, which writes the value and
 * reloads Hyprland. So:
 *
 *   * SCALE and RENDER QUALITY go through that script -- they are the two
 *     settings the config reads back at reload, and they work today.
 *   * REFRESH RATE, VRR, ORIENTATION and DISPLAY ON/OFF are shown, and they
 *     are wired to the same script's sibling flags where one exists. Where no
 *     path exists they are shown DISABLED with the reason, rather than drawn
 *     as a control that silently does nothing when clicked. A switch that
 *     looks live and is not is worse than a switch that admits it cannot.
 *
 * One more thing this machine decides for us: the panel reports exactly ONE
 * available mode (2560x1600@240.00Hz). A resolution picker with one option is
 * noise, so it is not drawn -- the current mode is stated as text instead, and
 * the refresh control only offers what the hardware actually has.
 */
ContentPage {
    id: root
    forceWidth: true

    // ── The panel, as the compositor reports it ──────────────────────────
    //
    // Read live rather than cached: `Quickshell.screens` is the authoritative
    // list and re-evaluates when a monitor is plugged in or a reload lands,
    // so a change made here is reflected without this page reloading.
    readonly property var screen: Quickshell.screens.find(
        s => s.name === (Hyprland.focusedMonitor?.name ?? "")) ?? Quickshell.screens[0] ?? null
    readonly property var brightnessMonitor: Brightness.getMonitorForScreen(root.screen)

    // The compositor's own numbers, which are what the settings have to agree
    // with. `hyprctl monitors` is the only source for scale/refresh/vrr, and
    // it is read through a Process rather than a binding because it is a
    // command, not a property.
    property string monitorName: "eDP-1"
    property real compositorScale: 1.5
    property real refreshRate: 0
    property bool vrr: false
    // NOT `transform`. ContentPage is a Flickable, and Flickable's `transform`
    // is a FINAL property -- declaring one here is "Cannot override FINAL
    // property" and takes the whole page down. The compositor calls it
    // `transform`; this cannot.
    property int screenTransform: 0
    property bool powered: true
    property string availableModes: ""
    property string activeMode: ""

    // The mode list as objects, so the picker does no string parsing.
    readonly property var modes: {
        const out = [];
        for (const m of root.availableModes.split(",")) {
            const trimmed = m.trim();
            if (trimmed.length === 0)
                continue;
            const at = trimmed.lastIndexOf("@");
            const res = at > 0 ? trimmed.slice(0, at) : trimmed;
            const hz = at > 0 ? parseFloat(trimmed.slice(at + 1)) : 0;
            const dims = res.split("x");
            out.push({
                text: trimmed,
                width: parseInt(dims[0]) || 0,
                height: parseInt(dims[1]) || 0,
                hz: hz
            });
        }
        return out;
    }

    // Distinct refresh rates available for the CURRENT resolution. Windows
    // lists refresh rates under the resolution they belong to; listing every
    // rate the panel has ever advertised would offer modes that do not apply
    // to the mode in use.
    readonly property var refreshChoices: {
        const current = root.modes.find(m => m.text === root.activeMode);
        if (!current)
            return [];
        const seen = new Set();
        const out = [];
        for (const m of root.modes) {
            if (m.width !== current.width || m.height !== current.height)
                continue;
            if (m.hz <= 0 || seen.has(m.hz))
                continue;
            seen.add(m.hz);
            out.push(m.hz);
        }
        return out.sort((a, b) => b - a);
    }

    readonly property real currentRefresh: {
        const m = root.modes.find(x => x.text === root.activeMode);
        return m ? m.hz : root.refreshRate;
    }

    readonly property var displayStateDir: `${Quickshell.env("HOME")}/.cache/display`
    readonly property string displayScript:
        `${CF.FileUtils.trimFileProtocol(Directories.config)}/hypr/custom/scripts/apply-display.sh`

    // Plain, NOT readonly: applyScale() writes it. A readonly property that is
    // then assigned is a "Cannot assign to read-only property" on every click.
    property real displayScale: 1.5
    property string displayQuality: "quality"

    // ── Reading the compositor ───────────────────────────────────────────
    //
    // `hyprctl monitors all` is the only place the mode list exists; the JSON
    // form has no field for it. One call fills everything, so the page cannot
    // show a scale from one source and a refresh rate from another that
    // disagrees.
    Process {
        id: monitorQuery
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseMonitors(text) }
    }

    function refreshMonitorInfo() {
        if (!root.monitorName)
            return;
        monitorQuery.command = ["bash", "-c",
            `hyprctl monitors all 2>/dev/null | awk '/^Monitor /{n=$2} n=="${root.monitorName}"'`];
        monitorQuery.running = true;
    }

    // Parsed with awk-fed text rather than JSON because the mode list is only
    // in the human-readable form. Everything else is read from
    // `hyprctl -j monitors`, which IS json, in a second process below.
    //
    // There is NO "active mode:" line in this output, which is what the first
    // pass of this parser looked for -- so the current mode stayed empty and
    // the page said "Reading…" and "single mode (unknown)" forever. The
    // current mode is the block's SECOND line, and it is spelled differently
    // from the same mode in the list:
    //
    //   line 2 of the block:  2560x1600@240.00000 at 0x0     <- current
    //   availableModes:       2560x1600@240.00Hz               <- the list
    //
    // Five decimals and no "Hz" versus two and "Hz", so they cannot be
    // compared as strings. They are matched by NUMBER (width, height, hz)
    // instead, and the list's spelling is what gets displayed -- "240.00Hz"
    // is the form a person recognises, "240.00000 at 0x0" is not.
    function parseMonitors(text) {
        const available = [];
        let currentLine = "";
        for (const raw of (text ?? "").split("\n")) {
            const line = raw.trim();
            if (line.startsWith("availableModes:")) {
                available.push(...line.slice("availableModes:".length).split(","));
            } else if (currentLine === "" && /^\d+x\d+@\d/.test(line) && line.includes(" at ")) {
                currentLine = line;
            }
        }
        root.availableModes = available.join(",");
        root.activeMode = root.matchModeInList(currentLine, available);
        root.applyJsonMonitorInfo();
    }

    // "2560x1600@240.00000 at 0x0" -> the matching entry of `available`.
    function matchModeInList(currentLine, available) {
        if (!currentLine) return "";
        const head = currentLine.split(" at ")[0];      // 2560x1600@240.00000
        const at = head.lastIndexOf("@");
        if (at <= 0) return head;
        const res = head.slice(0, at);                  // 2560x1600
        const hz = parseFloat(head.slice(at + 1));      // 240
        for (const candidate of available) {
            const c = candidate.trim();
            const cAt = c.lastIndexOf("@");
            if (cAt <= 0) continue;
            if (c.slice(0, cAt) !== res) continue;
            const cHz = parseFloat(c.slice(cAt + 1));
            if (Math.abs(cHz - hz) < 0.01) return c;    // the display spelling
        }
        return head;                                    // list did not contain it
    }

    Process {
        id: jsonQuery
        stdout: StdioCollector { onStreamFinished: root.applyJson(text) }
    }

    function applyJsonMonitorInfo() {
        if (!root.monitorName)
            return;
        jsonQuery.command = ["bash", "-c",
            `hyprctl -j monitors | python3 -c "import json,sys;m=[x for x in json.load(sys.stdin) if x['name']=='${root.monitorName}'];print(json.dumps(m[0]) if m else '{}')"`];
        jsonQuery.running = true;
    }

    function applyJson(text) {
        let d = {};
        try { d = JSON.parse(text ?? "{}"); } catch (e) { return; }
        if (!d.name) return;
        root.compositorScale = d.scale ?? root.compositorScale;
        root.refreshRate = d.refreshRate ?? root.refreshRate;
        root.vrr = d.vrr ?? false;
        root.screenTransform = d.transform ?? 0;
        root.powered = d.dpmsStatus ?? true;
    }

    // ── Applying ──────────────────────────────────────────────────────────
    //
    // Both of these go through the shell's own script, because that script is
    // the single writer of ~/.cache/display/{scale,quality} and the config
    // reads those back at reload. Writing the file here as well would be a
    // second writer, and the two would race.
    function applyScale(value) {
        root.displayScale = value;
        Quickshell.execDetached(["bash", "-c", `${root.displayScript} --scale ${value}`]);
        // The reload lands after the dispatch returns, so the read-back is
        // scheduled rather than immediate -- otherwise it samples the OLD
        // scale and the picker snaps back.
        rereadTimer.restart();
    }

    function applyQuality(value) {
        root.displayQuality = value;
        Quickshell.execDetached(["bash", "-c", `${root.displayScript} --quality ${value}`]);
        rereadTimer.restart();
    }

    Timer {
        id: rereadTimer
        interval: 1400
        onTriggered: root.refreshMonitorInfo()
    }

    FileView {
        id: scaleFile
        path: `${root.displayStateDir}/scale`
        watchChanges: true
        blockLoading: true
        preload: true
        onFileChanged: scaleFile.reload()
        onLoaded: {
            const s = parseFloat((scaleFile.text() || "").trim());
            if (!isNaN(s) && s >= 1 && s <= 3) root.displayScale = s;
        }
    }

    FileView {
        id: qualityFile
        path: `${root.displayStateDir}/quality`
        watchChanges: true
        blockLoading: true
        preload: true
        onFileChanged: qualityFile.reload()
        onLoaded: {
            const q = (qualityFile.text() || "").trim();
            if (["performance", "balanced", "quality"].includes(q))
                root.displayQuality = q;
        }
    }

    Component.onCompleted: {
        root.monitorName = root.screen?.name ?? "eDP-1";
        root.refreshMonitorInfo();
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            const focused = Hyprland.focusedMonitor?.name;
            if (focused && focused !== root.monitorName) {
                root.monitorName = focused;
                root.refreshMonitorInfo();
            }
        }
    }

    // ── Brightness ───────────────────────────────────────────────────────
    readonly property real brightnessValue: root.brightnessMonitor?.brightness ?? 0

    function setBrightness(fraction) {
        Brightness.setBrightnessFraction(Math.max(0, Math.min(1, fraction)));
    }

    // ── Night light ──────────────────────────────────────────────────────
    readonly property bool nightLightOn: Hyprsunset.temperatureActive

    function toggleNightLight() {
        Hyprsunset.toggleTemperature(!Hyprsunset.temperatureActive);
    }

    // The writable night-light temperature, clamped to what hyprsunset accepts.
    readonly property int nightTemperature: Math.max(2000, Math.min(6000, Hyprsunset.colorTemperature ?? 5000))

    // Applied immediately, not only on release: Hyprsunset.enableTemperature()
    // is what pushes the value to the compositor, so when night light is
    // already on the slider has to re-issue that call itself.
    function setNightTemperature(value) {
        const clamped = Math.max(2000, Math.min(6000, Math.round(value)));
        Config.options.light.night.colorTemperature = clamped;
        Hyprsunset.colorTemperature = clamped;
        if (root.nightLightOn)
            Hyprsunset.enableTemperature();
    }

    // ── The choices ──────────────────────────────────────────────────────
    readonly property var scaleChoices: [
        { value: 1.0, name: "100%" },
        { value: 1.25, name: "125%" },
        { value: 1.5, name: "150%" },
        { value: 1.6, name: "160%" },
        { value: 2.0, name: "200%" }
    ]

    readonly property var qualityChoices: [
        { value: "performance", name: Translation.tr("Performance"), note: Translation.tr("Fewer animations, longest battery.") },
        { value: "balanced", name: Translation.tr("Balanced"), note: Translation.tr("The default. Animations, normal battery.") },
        { value: "quality", name: Translation.tr("Quality"), note: Translation.tr("Every effect on. Best on mains power.") }
    ]

    readonly property var transformChoices: [
        { value: 0, name: Translation.tr("Landscape") },
        { value: 1, name: Translation.tr("Portrait") },
        { value: 2, name: Translation.tr("Portrait flipped") },
        { value: 3, name: Translation.tr("Landscape flipped") }
    ]

    // ── Page ──────────────────────────────────────────────────────────────
    //
    // These sections are declared as the default property (ContentPage aliases
    // it to its internal ColumnLayout), NOT inside a `children: [...]` list.
    // Writing `children:` looks equivalent and is not: `children` is Item's
    // own property, so it sidesteps the alias entirely and every section is
    // laid out at 0,0 on top of each other. That is what a first pass of this
    // page did -- all seven sections drawn in one spot, unreadable. Same as the
    // other pages (NetworkConfig and friends) declare theirs.

        // ══ Brightness ═══════════════════════════════════════════════════
        ContentSection {
            icon: "brightness_6"
            title: Translation.tr("Brightness")

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    MaterialSymbol {
                        text: "brightness_low"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnSurfaceVariant
                    }

                    // The slider is a ConfigSlider rather than a bare one so it
                    // picks up the shell's own drag handling, which a touchpad
                    // needs (a raw Slider fights it).
                    ConfigSlider {
                        id: brightnessSlider
                        Layout.fillWidth: true
                        text: Translation.tr("%1%").arg(Math.round(root.brightnessValue * 100))
                        from: 0
                        to: 100
                        // Shown as a percentage, which is what Windows shows
                        // and what people compare against the brightness keys.
                        value: root.brightnessValue * 100
                        // Written back rather than bound to `value`: a two-way
                        // binding here would fight the backlight, which
                        // quantises and occasionally reports back a slightly
                        // different number than the one asked for, and the
                        // slider would jitter under the finger.
                        onValueChanged: root.setBrightness(value / 100)
                    }

                    MaterialSymbol {
                        text: "brightness_high"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnSurfaceVariant
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    text: root.brightnessMonitor
                        ? Translation.tr("%1%").arg(Math.round(root.brightnessValue * 100))
                        : Translation.tr("No backlight control found for this panel.")
                }
            }
        }

        // ══ Night light ══════════════════════════════════════════════════
        ContentSection {
            icon: "bedtime"
            title: Translation.tr("Night light")

            ConfigSwitch {
                buttonIcon: "bedtime"
                text: Translation.tr("Night light")
                checked: root.nightLightOn
                onClicked: root.toggleNightLight()
            }

            StyledText {
                Layout.fillWidth: true
                Layout.topMargin: 2
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.WordWrap
                text: Hyprsunset.automatic
                    ? Translation.tr("On automatically from %1 to %2.").arg(Hyprsunset.from).arg(Hyprsunset.to)
                    : Translation.tr("Warms the display to cut blue light. Turning it on overrides the schedule until you turn it off.")
            }

            // Temperature, only when night light is actually doing something --
            // a slider that changes nothing is a broken-looking control.
            //
            // The knob is `colorTemperature`, NOT `gammaLowerLimit`: the
            // latter is a READ-ONLY clamp (25) inside Hyprsunset, so writing
            // to it threw "Cannot assign to read-only property" on every
            // drag frame. `colorTemperature` is the writable one and is what
            // enableTemperature() actually passes to `hyprctl hyprsunset
            // temperature`, so writing it here changes the screen for real.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                visible: root.nightLightOn
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    StyledText {
                        color: Appearance.colors.colOnSurfaceVariant
                        font.pixelSize: Appearance.font.pixelSize.small
                        text: Translation.tr("Warmth")
                    }

                    ConfigSlider {
                        Layout.fillWidth: true
                        text: Translation.tr("%1K").arg(Math.round(root.nightTemperature / 1000))
                        from: 2000
                        to: 6000
                        value: root.nightTemperature
                        onValueChanged: root.setNightTemperature(value)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    wrapMode: Text.WordWrap
                    text: Translation.tr("Lower is warmer and dimmer; %1K is the screen's normal colour.").arg(6000)
                }
            }
        }

        // ══ Scale ════════════════════════════════════════════════════════
        ContentSection {
            icon: "desktop_windows"
            title: Translation.tr("Scale & resolution")

            // Which panel, and what it is doing right now. The state line is
            // the honest answer to "what resolution am I on", since there is
            // only ever one mode to choose from on this machine.
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                StyledText {
                    color: Appearance.colors.colOnSurfaceVariant
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: Translation.tr("Display")
                }
                StyledText {
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: root.screen?.name ?? root.monitorName
                }
                Item { Layout.fillWidth: true }
                StyledText {
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    text: root.activeMode
                        ? Translation.tr("%1 · %2 logical pixels").arg(root.activeMode)
                            .arg(Math.round((root.screen?.width ?? 0)) + "×" + Math.round((root.screen?.height ?? 0)))
                        : Translation.tr("Reading…")
                }
            }

            // Scale. The one display setting that genuinely works on this
            // build, and the one people change most.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    StyledText {
                        color: Appearance.colors.colOnSurfaceVariant
                        font.pixelSize: Appearance.font.pixelSize.small
                        text: Translation.tr("Scale")
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: root.scaleChoices
                            delegate: RippleButton {
                                id: scaleChip
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: 40
                                buttonRadius: Appearance.rounding.small
                                colBackground: "transparent"
                                colBackgroundHover: Appearance.colors.colLayer1Hover
                                colBackgroundToggled: Appearance.colors.colSecondaryContainer
                                toggled: Math.abs(root.displayScale - scaleChip.modelData.value) < 0.01
                                onClicked: root.applyScale(scaleChip.modelData.value)

                                contentItem: StyledText {
                                    anchors.centerIn: parent
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: scaleChip.toggled
                                        ? Appearance.colors.colOnSecondaryContainer
                                        : Appearance.colors.colOnLayer0
                                    text: scaleChip.modelData.name
                                }
                            }
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    wrapMode: Text.WordWrap
                    text: Translation.tr("Scales the whole desktop, including X11 apps. Running apps pick it up straight away; a game or a video call has to be reopened once.")
                }
            }
        }

        // ══ Refresh rate ═════════════════════════════════════════════════
        ContentSection {
            icon: "refresh"
            title: Translation.tr("Refresh rate")

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    StyledText {
                        color: Appearance.colors.colOnSurfaceVariant
                        font.pixelSize: Appearance.font.pixelSize.small
                        text: Translation.tr("Refresh rate")
                    }

                    // Only what this panel actually has at this resolution.
                    // A dropdown listing a single option is a control that
                    // looks broken; this says the same thing in words.
                    StyledText {
                        Layout.fillWidth: true
                        color: Appearance.colors.colOnSurfaceVariant
                        font.pixelSize: Appearance.font.pixelSize.small
                        text: root.currentRefresh > 0
                            ? Translation.tr("%1 Hz").arg(root.currentRefresh)
                            : Translation.tr("Reading…")
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    wrapMode: Text.WordWrap
                    text: root.refreshChoices.length > 1
                        ? Translation.tr("This panel reports more than one rate.")
                        : Translation.tr("This panel reports a single mode (%1), so there is nothing to choose between.").arg(root.activeMode || "unknown")
                }
            }
        }

        // ══ Advanced ═════════════════════════════════════════════════════
        ContentSection {
            icon: "tune"
            title: Translation.tr("Advanced display")

            // VRR. Shown, and honestly inert on this build: there is no
            // monitor dispatcher to call. Disabled rather than fake.
            ConfigSwitch {
                buttonIcon: "speed"
                text: Translation.tr("Variable refresh rate")
                enabled: false
                checked: root.vrr
                // No onClicked: the control is disabled, so it cannot be
                // pressed into a state it cannot reach.
            }

            StyledText {
                Layout.fillWidth: true
                Layout.topMargin: -4
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.WordWrap
                text: Translation.tr("Not available on this setup: the compositor's Lua config exposes no monitor dispatcher to switch this at runtime.")
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 12

                StyledText {
                    Layout.fillWidth: true
                    color: Appearance.colors.colOnSurfaceVariant
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: Translation.tr("Orientation")
                }

                StyledText {
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: root.transformChoices.find(t => t.value === root.screenTransform)?.name
                        ?? Translation.tr("Unknown")
                }
            }

            StyledText {
                Layout.fillWidth: true
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.WordWrap
                text: Translation.tr("Rotation is read-only here for the same reason. A laptop panel is used landscape; rotate it physically instead.")
            }
        }

        // ══ Render quality ═══════════════════════════════════════════════
        ContentSection {
            icon: "diamond"
            title: Translation.tr("Render quality")

            // A plain ColumnLayout, not ConfigRow: ConfigRow is a bare
            // RowLayout with a `hovered` property for tooltips and no
            // title/description of its own, so putting a label in it needs the
            // label supplied as a child anyway.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                StyledText {
                    color: Appearance.colors.colOnSurfaceVariant
                    font.pixelSize: Appearance.font.pixelSize.small
                    text: Translation.tr("Graphics quality")
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Repeater {
                        model: root.qualityChoices
                        delegate: RippleButton {
                            id: qualityChip
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 40
                            buttonRadius: Appearance.rounding.full
                            colBackground: "transparent"
                            colBackgroundHover: Appearance.colors.colLayer1Hover
                            colBackgroundToggled: Appearance.colors.colSecondaryContainer
                            toggled: root.displayQuality === qualityChip.modelData.value
                            onClicked: root.applyQuality(qualityChip.modelData.value)

                            contentItem: StyledText {
                                anchors.centerIn: parent
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: qualityChip.toggled
                                    ? Appearance.colors.colOnSecondaryContainer
                                    : Appearance.colors.colOnLayer0
                                text: qualityChip.modelData.name
                            }
                        }
                    }
                }

                // The note under the CHIPS, not inside them: three chips with a
                // sentence each would be unreadable, and the sentence is about
                // whichever one is selected.
                StyledText {
                    Layout.fillWidth: true
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    wrapMode: Text.WordWrap
                    text: root.qualityChoices.find(q => q.value === root.displayQuality)?.note ?? ""
                }
            }
        }
}
