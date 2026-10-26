import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell.Services.UPower
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.common.panels.lock
import qs.modules.ii.bar as Bar
import Quickshell
import Quickshell.Io
import Quickshell.Services.SystemTray

MouseArea {
    id: root
    // Not `required`: the layer-shell lock creates this surface and assigns the
    // shared context in the same frame (see LockScreen.qml). Everything that
    // reads it goes through contextReady, so the one-frame gap before the
    // assignment cannot throw.
    property LockContext context: null
    readonly property bool contextReady: context !== null && context !== undefined
    property bool active: false
    property bool showInputField: active || (root.contextReady && context.currentText.length > 0)
    readonly property bool requirePasswordToPower: Config.options.lock.security.requirePasswordToPower

    // ═════════════════════════════════════════════════════════════════════
    // THE POWER MENU — one button, three actions.
    //
    // Power off and restart used to be two of three glyph-only buttons in a
    // row (Sleep, power off, restart). The two irreversible things on this
    // screen were therefore one 34px glyph apart, told apart by nothing but
    // the drawing inside them, and the password guard did not change that --
    // it asks AFTER the wrong one is clicked, and the wrong one here ends the
    // session. The right sidebar's power button already answers this, so this
    // is that button: one glyph that opens a card of named rows, ordered from
    // harmless to final.
    //
    // The guard is unchanged, and it is the reason this is a menu and not just
    // closer spacing: picking Restart or Power off arms root.context's
    // targetAction exactly as the old button did, so the confirm key turns
    // into that action's glyph and the password above performs THAT action
    // rather than an unlock. Picking the same row again takes it back.
    // ═════════════════════════════════════════════════════════════════════
    readonly property var powerActions: [
        { key: "sleep",    icon: "bedtime",        label: Translation.tr("Sleep") },
        { key: "reboot",   icon: "restart_alt",    label: Translation.tr("Restart"),   action: LockContext.ActionEnum.Reboot },
        { key: "poweroff", icon: "settings_power", label: Translation.tr("Power off"), action: LockContext.ActionEnum.Poweroff }
    ]
    property bool powerMenuOpen: false

    function openPowerMenu(anchorItem) {
        // Placed from the button's own geometry, clamped to the surface: the
        // menu is a child of this item, and the two buttons that open it (the
        // pill toolbar's, or the sheet's) are in different parents, so anchors
        // are not available to it.
        const p = anchorItem.mapToItem(root, 0, 0);
        powerMenu.x = Math.round(Math.max(8, Math.min(p.x + p.width - powerMenu.width, root.width - powerMenu.width - 8)));
        powerMenu.y = Math.round(Math.max(8, p.y - powerMenu.height - 8));
        root.powerMenuOpen = true;
    }

    function closePowerMenu() {
        root.powerMenuOpen = false;
    }

    function runPowerAction(action) {
        root.closePowerMenu();
        // Sleep is the reversible one: it keeps the session and needs no
        // confirmation, which is also why it is not guarded like the other two.
        if (action.key === "sleep") {
            Session.suspend();
            return;
        }
        if (!root.contextReady)
            return;
        if (!root.requirePasswordToPower) {
            root.context.unlocked(action.action);
            return;
        }
        if (root.context.targetAction === action.action) {
            root.context.resetTargetAction();
            return;
        }
        root.context.targetAction = action.action;
        root.context.shouldReFocus();
    }

    // ═════════════════════════════════════════════════════════════════════
    // THE "sheet" ARRANGEMENT
    // ═════════════════════════════════════════════════════════════════════
    // The login screen's most distinctive template, ported here value for
    // value from the SDDM theme's Main.qml. It is not a variation on the
    // other seven: the form moves to the bottom-left, the clock to the
    // top-right on one line with the seconds in the accent, the account gets
    // a square tile, the password sits on a bare baseline with a return
    // KEYCAP instead of the round arrow, the scrim is a flat tint rather than
    // a vignette, and the corners carry telemetry.
    //
    // It was missing here entirely, which is why locking looked nothing like
    // logging in: the lock asked LoginLayouts for "sheet", that list had never
    // heard of it, and it silently drew "classic" instead. The list is
    // generated from the theme's own fragments now (see LoginLayouts.qml), so
    // `sheet` arrives here on its own -- what was left was to draw it.
    //
    // Every number below is copied from Main.qml, where the same values are
    // expressed against that screen's `unit`. `unit` is reproduced rather than
    // approximated so the two screens scale identically: it is the one
    // measurement the whole sheet is built from, and a lock screen that is
    // "about the same size" is exactly the drift this is fixing.
    readonly property bool sheetMode: LoginLayouts.sheet

    // Main.qml: readonly property int unit: Math.max(200, Math.min(width, height * 0.6))
    readonly property int sheetUnit: Math.max(200, Math.min(root.width, root.height * 0.6))
    // Main.qml: readonly property int fieldHeight: Math.round(unit * 0.10)
    readonly property int sheetField: Math.round(root.sheetUnit * 0.10)
    readonly property string sheetMono: Appearance.font.family.monospace
    readonly property color sheetOutline: Appearance.colors.colOutline
    // The lock CAN act on these, so unlike the greeter's "canReboot" the row
    // is always present -- but it is only shown in sheet mode, where the pill
    // toolbar it replaces is hidden.
    readonly property real sheetMargin: Math.round(root.height * 0.0135)

    // Force focus on entry
    function forceFieldFocus() {
        // Which input exists depends on the arrangement: in sheet mode the
        // pill toolbar (and passwordBox with it) is hidden, so focusing it
        // would silently focus nothing and the lock screen would come up
        // with no way to type a password.
        (root.sheetMode ? sheetPassword : passwordBox).forceActiveFocus();
    }
    Connections {
        target: context
        function onShouldReFocus() {
            forceFieldFocus();
        }
    }
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    onPressed: mouse => {
        forceFieldFocus();
        // Any press that is not on a control dismisses the power menu. The
        // menu's own rows and every button here take their own press, so this
        // only ever fires for the background -- no scrim item needed.
        if (root.powerMenuOpen)
            root.closePowerMenu();
    }
    onPositionChanged: mouse => {
        forceFieldFocus();
    }

    // Toolbar appearing animation
    property real toolbarScale: 0.9
    property real toolbarOpacity: 0
    Behavior on toolbarScale {
        NumberAnimation {
            duration: Appearance.animation.elementMove.duration
            easing.type: Appearance.animation.elementMove.type
            easing.bezierCurve: Appearance.animationCurves.expressiveFastSpatial
        }
    }
    Behavior on toolbarOpacity {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
    }

    // Init
    Component.onCompleted: {
        forceFieldFocus();
        toolbarScale = 1;
        toolbarOpacity = 1;
    }

    // Key presses
    property bool ctrlHeld: false
    Keys.onPressed: event => {
        root.context.resetClearTimer();
        if (event.key === Qt.Key_Control) {
            root.ctrlHeld = true;
        }
        if (event.key === Qt.Key_Escape) { // Esc to clear
            root.context.currentText = "";
        } 
        forceFieldFocus();
    }
    Keys.onReleased: event => {
        if (event.key === Qt.Key_Control) {
            root.ctrlHeld = false;
        }
        forceFieldFocus();
    }

    // RippleButton {
    //     anchors {
    //         top: parent.top
    //         left: parent.left
    //         leftMargin: 10
    //         topMargin: 10
    //     }
    //     implicitHeight: 40
    //     colBackground: Appearance.colors.colLayer2
    //     onClicked: {
    //         context.unlocked(LockContext.ActionEnum.Unlock);
    //         GlobalStates.screenLocked = false;
    //     }
    //     contentItem: StyledText {
    //         text: "[[ DEBUG BYPASS ]]"
    //     }
    // }

    // ═════════════════════════════════════════════════════════════════════
    // THE LOGIN SCREEN'S PICTURE, on the lock screen
    // ═════════════════════════════════════════════════════════════════════
    // The layouts were already shared with the login screen (see below), but
    // the BACKDROP was not: locking showed a flat colLayer0 wash, so the two
    // screens were the same design over two different pictures. Now the lock
    // wears the login screen's own image, cropped and scrimmed exactly the
    // way the greeter draws it, and pressing SUPER+L looks like the machine
    // going to sleep into the screen you will meet at the next boot.
    //
    // The picture belongs to the SDDM theme, not to the shell, so it is
    // resolved the way SDDM resolves it -- theme from the sddm config, then
    // the [General] background= of that theme -- by a script rather than a
    // hardcoded path. Change the greeter's theme or its picture and this
    // follows; there is no second file to edit and no way for the two to
    // drift. scripts/lock/greeter-backdrop.sh prints the resolved path, and
    // prints NOTHING if there is genuinely no picture, which is the case that
    // leaves the old flat wash showing (see the visibility below).
    //
    // Re-read on every lock, not once at startup: the greeter is a separate
    // process that can be reconfigured while this session runs, and a lock
    // screen showing last boot's picture would be exactly the drift this is
    // here to remove.
    //
    // INJECTED, not resolved here. The resolver lives in LockScreen.qml, which
    // is alive whether or not the screen is locked: the path is therefore
    // already known by the time this surface is created (no process spawn in
    // the middle of locking, where a frame of flat wash would show), the
    // resolution is shared by every monitor's surface instead of repeated per
    // screen, and the `lock backdrop` diagnostic can read it while unlocked.
    // The assignment rides the same `onLoaded` that hands over the context.
    property string backdropUrl: ""

    // The picture. `visible` is the whole fallback: an unresolvable or missing
    // file leaves this hidden, and the flat wash the lock window draws behind
    // this surface (LockScreen.qml) is what shows through instead.
    Image {
        id: greeterBackdrop
        anchors.fill: parent
        source: root.backdropUrl
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        visible: status === Image.Ready && source.toString().length > 0
    }

    // The greeter's scrim, copied value for value from the SDDM theme
    // (custom/sddm-theme/Main.qml): darkest at the top and the bottom, where
    // the clock and the form sit, nearly clear through the middle, because
    // the picture is the point. The theme's own flat wash is NOT part of this
    // -- that belongs to its `sheet` arrangement, and the classic arrangement
    // (the template in force in-session) is the gradient alone.
    Rectangle {
        anchors.fill: parent
        visible: greeterBackdrop.visible
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
            GradientStop { position: 0.42; color: Qt.rgba(0, 0, 0, 0.18) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.60) }
        }
    }

    // The sheet arrangement's own scrim: a single FLAT, very light wash over
    // the whole screen. Copied from the SDDM theme, and additive with the
    // gradient above rather than a replacement -- the gradient is what keeps
    // the clock readable at the top, and the sheet design was drawn against
    // both together. Without this the wallpaper visibly darkens toward the
    // edges and the design reads as a vignette, which is not what sheet is.
    Rectangle {
        visible: root.sheetMode
        anchors.fill: parent
        color: Qt.rgba(0.03, 0.03, 0.035, 0.22)
    }

    // ── The login screen's template, applied in-session ────────────────────
    // The lock IS the login design: the same template list
    // (services/LoginLayouts.qml -- the list the SDDM theme's .js fragments
    // mirror) decides where the column sits, whether the clock is drawn and
    // how large, and whether a frosted panel backs it. Locking with "Glass"
    // selected therefore looks like logging in through the same panel you
    // will meet at the next boot, which is the point of retiring the separate
    // hyprlock config: one screen, both jobs.
    readonly property bool loginAlignLeft: LoginLayouts.align === "left"
    readonly property bool loginClockVisible: LoginLayouts.clockVisible
    readonly property bool loginCardVisible: LoginLayouts.card
    readonly property int loginColumnOffset: Math.round(root.height * LoginLayouts.offset)

    // ── The "ops" HUD presentation ──────────────────────────────────────────
    // One of the shared templates (the one named "ops") draws the screen as a
    // mission console: telemetry strips in the corners, a huge centred clock
    // with the seconds hanging off its corner in the accent colour, the
    // password island inside a sharp-cornered card with a segmented
    // character ruler above it, and an arrow / dot switcher for the templates
    // themselves. Everything else on this surface stays as-is; the HUD adds
    // its own layer and re-styles what it needs through visible/opacity.
    readonly property bool hudMode: LoginLayouts.hud
    readonly property color hudAccent: Appearance.colors.colPrimary
    readonly property color hudDim: Appearance.colors.colOnSurfaceVariant
    readonly property color hudInk: Appearance.colors.colOnLayer0
    readonly property string hudFont: Appearance.font.family.monospace
    readonly property string hudHost: {
        const h = SystemInfo.hostname;
        return (h && h.length > 0) ? h.toUpperCase() : "LOCALHOST";
    }

    // The login screen's clock, in the login screen's treatment: top centre,
    // thin and large, sized by the template. Templates without a clock
    // (Minimal, Studio) hide it entirely -- the bar carries the time again
    // five seconds after unlocking. In HUD mode this whole column steps
    // aside: the HUD draws its own clock below.
    Column {
        id: loginClock
        visible: root.loginClockVisible && !root.hudMode && !root.sheetMode
        opacity: root.toolbarOpacity
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: Math.round(root.height * 0.10)
        }
        spacing: 2

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: DateTime.time
            color: Appearance.colors.colOnLayer0
            font.pixelSize: Math.round(Math.min(root.height * 0.15, 160) * LoginLayouts.clockScale)
            font.weight: Font.Light
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: DateTime.longDate
            color: Appearance.colors.colOnSurfaceVariant
            font.pixelSize: Appearance.font.pixelSize.large
        }
    }

    // The frosted panel the glass templates put behind the column. Declared
    // before the toolbars so all three islands paint over it, and sharing
    // their appear animation so the whole login arrives as one object. The
    // ops HUD draws its own card (sharp corners, segmented ruler) instead.
    Rectangle {
        id: loginCard
        visible: root.loginCardVisible && !root.hudMode && !root.sheetMode
        anchors.fill: mainIsland
        anchors.margins: -18
        radius: Appearance.rounding.verylarge
        color: Appearance.colors.colLayer0
        opacity: root.toolbarOpacity * 0.66
        scale: root.toolbarScale
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, Appearance.m3colors.darkmode ? 0.14 : 0.5)
    }

    // ═════════════════════════════════════════════════════════════════════
    // OPS HUD — the mission-console layer (template: "ops")
    // Corner telemetry strips, centred clock with accent seconds, the
    // password island regrouped inside a sharp card, and the template
    // switcher (arrows + dots). Everything is derived from the theme's own
    // colours, so dark and light modes both read correctly.
    // ═════════════════════════════════════════════════════════════════════

    component HudText: StyledText {
        font.family: root.hudFont
        color: root.hudDim
    }

    // ── top-left: session status ─────────────────────────────────────
    Column {
        visible: root.hudMode
        opacity: root.toolbarOpacity
        anchors {
            top: parent.top; left: parent.left
            margins: 22; topMargin: 18
        }
        spacing: 3

        Row {
            spacing: 8
            // seven diagonal slashes, the classic ops hatch
            Row {
                spacing: 2
                Repeater {
                    model: 7
                    Rectangle { width: 2; height: 8; color: root.hudAccent; rotation: 24 }
                }
            }
            HudText { text: "SESSION " + (GlobalStates.screenLocked ? "SUSPENDED" : "ACTIVE")
                color: root.hudInk; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.5 }
            HudText { text: "// " + (Battery.isCharging ? "AC ACTIVE" : "ON BATTERY")
                color: Battery.isCharging ? root.hudAccent : root.hudDim
                font.pixelSize: 11; font.letterSpacing: 1.5 }
        }
        HudText { text: "「認証待ち」認証準備中" // awaiting auth, preparing
            font.pixelSize: 11; opacity: 0.8 }
    }

    // ── top-right: host readout ──────────────────────────────────
    Column {
        visible: root.hudMode
        opacity: root.toolbarOpacity
        anchors {
            top: parent.top; right: parent.right
            margins: 22; topMargin: 18
        }
        spacing: 3

        HudText { anchors.right: parent.right
            text: "HOST " + root.hudHost + " // ONLINE"
            font.pixelSize: 11; font.letterSpacing: 1.5 }
        HudText { anchors.right: parent.right
            text: "USER // " + SystemInfo.username.toUpperCase()
            font.pixelSize: 11; opacity: 0.75 }
    }

    // ── the big clock + seconds + date line ──────────────────────
    Column {
        id: hudClock
        visible: root.hudMode
        opacity: root.toolbarOpacity
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: Math.round(root.height * 0.16)
        }
        spacing: 10

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: bigTime.implicitWidth + 14 + secondsLabel.implicitWidth
            height: bigTime.implicitHeight

            StyledText {
                id: bigTime
                anchors.left: parent.left
                text: DateTime.time
                color: root.hudInk
                font.family: root.hudFont
                font.pixelSize: Math.round(Math.min(root.height * 0.13, 118))
                font.weight: Font.Bold
                font.letterSpacing: 2
            }
            StyledText {
                id: secondsLabel
                anchors.left: bigTime.right
                anchors.baseline: bigTime.baseline
                anchors.leftMargin: 10
                text: DateTime.seconds
                color: root.hudAccent
                font.family: root.hudFont
                font.pixelSize: Math.round(Math.min(root.height * 0.032, 30))
                font.weight: Font.Medium
            }
        }

        HudText { anchors.horizontalCenter: parent.horizontalCenter
            text: "OPERATOR // " + SystemInfo.username.toUpperCase()
            font.pixelSize: 12; font.bold: true; font.letterSpacing: 3; opacity: 0.9 }
        HudText { anchors.horizontalCenter: parent.horizontalCenter
            text: DateTime.hudDateLine
            font.pixelSize: 12; opacity: 0.65; font.letterSpacing: 2 }
    }

    // ── segmented passphrase card around the password island ─────
    // The card keeps the real password island as its content (all the
    // behaviour — typing, focus, unlock, fingerprint — is untouched); the
    // HUD only supplies the housing: sharp corners, hairline border, and
    // the segmented character ruler above the field.
    Rectangle {
        id: hudCard
        visible: root.hudMode
        opacity: root.toolbarOpacity
        anchors.fill: mainIsland
        anchors.margins: -16
        anchors.topMargin: -34
        color: Qt.rgba(
            Appearance.colors.colLayer0.r,
            Appearance.colors.colLayer0.g,
            Appearance.colors.colLayer0.b, 0.72)
        radius: 4
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, Appearance.m3colors.darkmode ? 0.12 : 0.4)

        Row {
            id: hudRuler
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: parent.top; topMargin: 10
            }
            spacing: 4
            Repeater {
                model: 16
                Rectangle {
                    width: 10; height: 14
                    color: "transparent"
                    border.width: 1
                    // filled segment = one typed character; the current
                    // (next empty) slot gets the accent outline
                    readonly property bool filled: index < (root.contextReady ? root.context.currentText.length : 0)
                    border.color: filled ? root.hudAccent
                        : Qt.rgba(root.hudDim.r, root.hudDim.g, root.hudDim.b, 0.45)
                }
            }
        }
        HudText {
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: hudRuler.bottom; topMargin: 6
            }
            text: GlobalStates.screenUnlockFailed ? "ACCESS DENIED — RETRY" : "ENTER PASSPHRASE TO RESUME SESSION"
            color: GlobalStates.screenUnlockFailed ? Appearance.colors.colError : root.hudDim
            font.pixelSize: 10; font.letterSpacing: 2
        }
    }

    // ── template switcher: side arrows ───────────────────────────
    component HudArrow: Rectangle {
        id: arrowBtn
        property string glyph
        property int dir
        signal picked()
        width: 52; height: 52; radius: 26
        color: mouse.containsMouse ? Qt.rgba(root.hudAccent.r, root.hudAccent.g, root.hudAccent.b, 0.18)
            : Qt.rgba(0, 0, 0, Appearance.m3colors.darkmode ? 0.35 : 0.18)
        border.width: 1
        border.color: Qt.rgba(root.hudInk.r, root.hudInk.g, root.hudInk.b, 0.25)
        MaterialSymbol {
            anchors.centerIn: parent
            text: arrowBtn.glyph
            iconSize: 22
            color: root.hudInk
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                LoginLayouts.cycle(arrowBtn.dir);
                arrowBtn.picked();
            }
        }
    }

    HudArrow {
        visible: root.hudMode
        opacity: root.toolbarOpacity
        glyph: "chevron_left"; dir: -1
        anchors {
            left: parent.left; leftMargin: 24
            verticalCenter: parent.verticalCenter
        }
    }
    HudArrow {
        visible: root.hudMode
        opacity: root.toolbarOpacity
        glyph: "chevron_right"; dir: 1
        anchors {
            right: parent.right; rightMargin: 24
            verticalCenter: parent.verticalCenter
        }
    }

    // ── template switcher: dots ─────────────────────────────
    Row {
        visible: root.hudMode
        opacity: root.toolbarOpacity
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom; bottomMargin: 26
        }
        spacing: 10
        Repeater {
            model: LoginLayouts.list
            delegate: Rectangle {
                required property int index
                required property var modelData
                readonly property bool selected: modelData.value === LoginLayouts.current
                width: selected ? 10 : 8; height: selected ? 10 : 8
                radius: width / 2
                color: selected ? root.hudAccent
                    : Qt.rgba(root.hudInk.r, root.hudInk.g, root.hudInk.b, 0.30)
                Behavior on width { NumberAnimation { duration: 140 } }
                Behavior on height { NumberAnimation { duration: 140 } }
                Behavior on color { ColorAnimation { duration: 140 } }
            }
        }
    }

    // ── bottom telemetry line ─────────────────────────────
    Row {
        visible: root.hudMode
        opacity: root.toolbarOpacity
        anchors {
            left: parent.left; bottom: parent.bottom
            margins: 22; bottomMargin: 14
        }
        spacing: 14
        HudText { text: "QUEUE 1/1 CLEARED"; font.pixelSize: 10; opacity: 0.55 }
        HudText { text: "VULN 12 AFFECTED"; font.pixelSize: 10
            color: Battery.isLow && !Battery.isCharging ? Appearance.colors.colError : root.hudDim; opacity: 0.55 }
        HudText { text: Battery.isCharging ? "PWR AC" : "PWR BAT " + Math.round(Battery.percentage * 100) + "%"
            font.pixelSize: 10; opacity: 0.55 }
    }

    // Main toolbar: password box
    Toolbar {
        id: mainIsland
        // The pill island belongs to the centred arrangements. Sheet puts its
        // form on a bare baseline in the corner instead, so the whole toolbar
        // -- island, side strips and all -- steps aside there.
        visible: !root.sheetMode
        radius: root.hudMode ? 3 : height / 2
        // Where the column sits comes from the login template: "corner" and
        // "studio" set it low-LEFT, everything else keeps it centred, and the
        // offset is a fraction of the screen height measured from the vertical
        // centre -- read exactly the way the SDDM theme reads the same two
        // variables, so the lock and the login cannot disagree.
        x: root.loginAlignLeft
            ? Math.round(root.width * 0.07)
            : Math.round((root.width - width) / 2)
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: root.loginColumnOffset
        Behavior on x {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }
        Behavior on anchors.verticalCenterOffset {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        scale: root.toolbarScale
        opacity: root.toolbarOpacity

        // Fingerprint
        Loader {
            Layout.leftMargin: 10
            Layout.rightMargin: 6
            Layout.alignment: Qt.AlignVCenter
            active: root.context.fingerprintsConfigured
            visible: active

            sourceComponent: MaterialSymbol {
                id: fingerprintIcon
                fill: 1
                text: "fingerprint"
                iconSize: Appearance.font.pixelSize.hugeass
                color: Appearance.colors.colOnSurfaceVariant
            }
        }

        ToolbarTextField {
            id: passwordBox
            Layout.rightMargin: -Layout.leftMargin
            placeholderText: GlobalStates.screenUnlockFailed ? Translation.tr("Incorrect password") : Translation.tr("Enter password")

            // Style
            clip: true
            font.pixelSize: Appearance.font.pixelSize.small
            selectedTextColor: materialShapeChars ? "transparent" : Appearance.colors.colOnSecondaryContainer
            selectionColor: materialShapeChars ? "transparent" : Appearance.colors.colSecondaryContainer

            // Password
            enabled: !root.context.unlockInProgress
            echoMode: TextInput.Password
            inputMethodHints: Qt.ImhSensitiveData

            // Synchronizing (across monitors) and unlocking
            onTextChanged: root.context.currentText = this.text
            onAccepted: {
                root.context.tryUnlock(ctrlHeld);
            }
            Connections {
                target: root.context
                function onCurrentTextChanged() {
                    passwordBox.text = root.context.currentText;
                }
            }

            Keys.onPressed: event => {
                root.context.resetClearTimer();
            }
            
            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: passwordBox.width - 8
                    height: passwordBox.height
                    radius: height / 2
                }
            }

            // Shake when wrong password
            ErrorShakeAnimation {
                id: wrongPasswordShakeAnim
                target: passwordBox
            }
            Connections {
                target: GlobalStates
                function onScreenUnlockFailedChanged() {
                    if (GlobalStates.screenUnlockFailed) wrongPasswordShakeAnim.restart();
                }
            }

            // We're drawing dots manually
            property bool materialShapeChars: Config.options.lock.materialShapeChars
            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, materialShapeChars ? 1 : 0)
            Loader {
                active: passwordBox.materialShapeChars
                anchors {
                    fill: parent
                    leftMargin: passwordBox.padding
                    rightMargin: passwordBox.padding
                }
                sourceComponent: PasswordChars {
                    length: root.context.currentText.length
                    selectionStart: passwordBox.selectionStart
                    selectionEnd: passwordBox.selectionEnd
                    cursorPosition: passwordBox.cursorPosition
                }
            }
        }

        ToolbarButton {
            id: confirmButton
            implicitWidth: height
            toggled: true
            enabled: !root.context.unlockInProgress
            colBackgroundToggled: Appearance.colors.colPrimary

            onClicked: root.context.tryUnlock()

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                iconSize: 24
                text: {
                    if (root.context.targetAction === LockContext.ActionEnum.Unlock) {
                        return root.ctrlHeld ? "coffee" : "arrow_right_alt";
                    } else if (root.context.targetAction === LockContext.ActionEnum.Poweroff) {
                        return "settings_power";
                    } else if (root.context.targetAction === LockContext.ActionEnum.Reboot) {
                        return "restart_alt";
                    }
                }
                color: confirmButton.enabled ? Appearance.colors.colOnPrimary : Appearance.colors.colSubtext
            }
        }
    }

    // Left toolbar
    Toolbar {
        id: leftIsland
        visible: !root.sheetMode
        anchors {
            right: mainIsland.left
            top: mainIsland.top
            bottom: mainIsland.bottom
            rightMargin: 10
        }
        scale: root.toolbarScale
        opacity: root.toolbarOpacity

        // Username
        IconAndTextPair {
            Layout.leftMargin: 8
            icon: "account_circle"
            text: SystemInfo.username
        }

        // Keyboard layout (Xkb)
        Loader {
            Layout.rightMargin: 8
            Layout.fillHeight: true

            active: true
            visible: active

            sourceComponent: Row {
                spacing: 8

                MaterialSymbol {
                    id: keyboardIcon
                    anchors.verticalCenter: parent.verticalCenter
                    fill: 1
                    text: "keyboard_alt"
                    iconSize: Appearance.font.pixelSize.huge
                    color: Appearance.colors.colOnSurfaceVariant
                }
                Loader {
                    anchors.verticalCenter: parent.verticalCenter
                    sourceComponent: StyledText {
                        text: HyprlandXkb.currentLayoutCode
                        color: Appearance.colors.colOnSurfaceVariant
                        animateChange: true
                    }
                }
            }
        }

        // Keyboard layout (Fcitx)
        //
        // `showOverflowMenu: false` puts the items straight in the strip
        // rather than behind a chevron -- this one icon is a readout, not
        // a place to go, and a card holding a single glyph would be two
        // clicks to read it.
        Bar.SysTray {
            Layout.rightMargin: 10
            Layout.alignment: Qt.AlignVCenter
            showSeparator: false
            showOverflowMenu: false
            allItems: SystemTray.items.values.filter(i => i.id == "Fcitx")
            visible: allItems.length > 0
        }
    }

    // Right toolbar
    Toolbar {
        id: rightIsland
        visible: !root.sheetMode
        anchors {
            left: mainIsland.right
            top: mainIsland.top
            bottom: mainIsland.bottom
            leftMargin: 10
        }

        scale: root.toolbarScale
        opacity: root.toolbarOpacity

        IconAndTextPair {
            visible: Battery.available
            icon: Battery.isCharging ? "bolt" : "battery_full"
            text: Math.round(Battery.percentage * 100)
            color: (Battery.isLow && !Battery.isCharging) ? Appearance.colors.colError : Appearance.colors.colOnSurfaceVariant
        }

        // The one control this row has that ends anything, and it asks first
        // (see powerActions above). `toggled` doubles as the open indicator.
        IconToolbarButton {
            id: powerButton
            text: "settings_power"
            toggled: root.powerMenuOpen
            onClicked: root.powerMenuOpen ? root.closePowerMenu() : root.openPowerMenu(powerButton)
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // SHEET — the form, bottom-left, and the clock, top-right.
    // Geometry copied from the SDDM theme's Main.qml "sheet" arrangement.
    // One deliberate deviation, noted at the telemetry: the greeter prints
    // "greeter sddm", which would be a lie here, so the lock prints what it
    // actually is. Everything else -- sizes, margins, weights, the two-corner
    // rhythm -- is the same.
    // ═════════════════════════════════════════════════════════════════════

    // ── sheet clock: top RIGHT, one line, seconds in the accent ───────
    // The centring trick is Main.qml's: a Column can only be anchored by its
    // horizontal CENTRE, so "hard against the right edge" is expressed as a
    // centre offset computed from the column's own width.
    Column {
        id: sheetClock
        visible: root.sheetMode
        opacity: root.toolbarOpacity
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: Math.round(parent.width / 2 - width / 2 - Math.round(parent.width * 0.06))
        anchors.top: parent.top
        anchors.topMargin: Math.round(root.height * 0.085)
        spacing: 6

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: sheetTime.implicitWidth + 10 + sheetSeconds.implicitWidth
            height: sheetTime.implicitHeight

            StyledText {
                id: sheetTime
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                text: DateTime.time
                color: Appearance.colors.colOnSurface
                font.family: root.sheetMono
                font.pixelSize: Math.min(root.height * 0.115, 124)
                font.weight: Font.Light
                font.letterSpacing: -2
            }
            StyledText {
                id: sheetSeconds
                anchors.left: sheetTime.right
                anchors.leftMargin: 10
                anchors.bottom: parent.bottom
                text: DateTime.seconds
                color: Appearance.colors.colPrimary
                font.family: root.sheetMono
                font.pixelSize: Math.min(root.height * 0.115, 124) * 0.46
                font.weight: Font.Light
            }
        }
    }

    // ── the form column: bottom-LEFT ────────────────────────────────
    Column {
        id: sheetColumn
        visible: root.sheetMode
        opacity: root.toolbarOpacity
        // Same two offsets as Main.qml, and for the same reason: always
        // anchored by the horizontal centre, walked out to the left margin
        // and up from the bottom by measuring the column's OWN width/height.
        // Using anything else leaves it stranded mid-screen.
        //
        // HALF the height, not all of it. The anchor is the vertical CENTRE,
        // so walking the column's bottom up to the 8.5% margin means moving the
        // centre up by "the margin plus HALF the column" -- the half-height is
        // the distance from the centre to the bottom edge. Subtracting the full
        // height instead (measured 2026-10-11, greeter rendered offscreen at
        // 1707x1067: column 214 px tall) parked the whole form -- the account
        // tile, the password line, the return key -- 107 px above where the
        // design puts it, while the clock above kept its own 8.5% and the
        // corner telemetry kept its 22 px. That is the ragged thing the eye
        // reads as "the input box is not aligned": the form floated, and the
        // two-corner rhythm this arrangement is drawn around was one-sided.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: -Math.round(parent.width / 2 - width / 2 - Math.round(parent.width * 0.06))
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Math.round(parent.height / 2 - height / 2 - parent.height * 0.085)
        width: Math.round(root.width * 0.34)
        spacing: Math.round(root.height * 0.013)

        // ---- account: square tile + "local · admin" -------------------
        // Square, not round: the round avatar is the one shape this theme
        // does not otherwise use, and the tile has to read as part of the
        // same sheet as the type beside it.
        Item {
            id: sheetAccount
            width: parent.width
            height: sheetTile.height

            readonly property int tile: Math.round(root.height * 0.072)

            Rectangle {
                id: sheetTile
                width: parent.tile
                height: parent.tile
                color: Qt.rgba(0, 0, 0, 0.30)
                radius: 2
                border.width: 1
                border.color: Qt.rgba(root.sheetOutline.r, root.sheetOutline.g, root.sheetOutline.b, 0.35)

                StyledText {
                    anchors.centerIn: parent
                    text: SystemInfo.username.length > 0
                        ? SystemInfo.username.substring(0, 1).toUpperCase() : "?"
                    color: Appearance.colors.colOnSurface
                    font.pixelSize: Math.round(sheetAccount.tile * 0.40)
                    font.weight: Font.Medium
                }
            }

            Column {
                anchors.left: sheetTile.right
                anchors.leftMargin: Math.round(sheetAccount.tile * 0.32)
                anchors.verticalCenter: sheetTile.verticalCenter
                spacing: 3

                StyledText {
                    text: SystemInfo.username.length > 0 ? SystemInfo.username : "user"
                    color: Appearance.colors.colOnSurface
                    font.pixelSize: Math.round(root.height * 0.036)
                    font.weight: Font.Light
                }
                StyledText {
                    text: "local · admin"
                    color: Appearance.colors.colOnSurfaceVariant
                    opacity: 0.75
                    font.family: root.sheetMono
                    font.pixelSize: Math.max(9, root.sheetMargin)
                    font.letterSpacing: 2.2
                }
            }
        }

        // ---- the password line -----------------------------------------
        // Not a box: type over a hairline. Two parts -- a resting line at low
        // opacity, and an accent line that grows from the left on focus,
        // which is what makes "this is focused" read without a border.
        Item {
            id: sheetPasswordLine
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            // Taller than the field so the tracked-out `password` caption has
            // its own row above the type; the lines stay pinned to the
            // bottom edge, which is what the type then sits on.
            height: Math.round(root.sheetField * 1.28)

            readonly property bool focused: sheetPassword.activeFocus
            readonly property bool armed: root.contextReady
                && root.context.currentText.length > 0
            readonly property color lineColor: GlobalStates.screenUnlockFailed
                ? Appearance.colors.colError
                : (sheetPasswordLine.focused
                    ? Appearance.colors.colPrimary
                    : Qt.rgba(root.sheetOutline.r, root.sheetOutline.g, root.sheetOutline.b, 0.40))

            StyledText {
                anchors.left: parent.left
                anchors.top: parent.top
                text: "password"
                color: Appearance.colors.colOnSurfaceVariant
                opacity: 0.7
                font.family: root.sheetMono
                font.pixelSize: Math.max(9, root.sheetMargin)
                font.letterSpacing: 2.2
            }

            // Resting line.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Qt.rgba(root.sheetOutline.r, root.sheetOutline.g, root.sheetOutline.b, 0.26)
            }

            // Focus line, growing from the left.
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                height: GlobalStates.screenUnlockFailed ? 2 : 1.5
                width: (sheetPasswordLine.focused || GlobalStates.screenUnlockFailed)
                    ? parent.width : 0
                color: sheetPasswordLine.lineColor

                Behavior on color { ColorAnimation { duration: 160 } }
                Behavior on width {
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }
            }

            // The field as the greeter builds it, in the same two parts.
            //
            // Main.qml's passwordField is SDDM's PasswordBox: a 64 px FocusScope,
            // 8 px in from the item's left edge and 0.9 x fieldHeight + 8 in
            // from its right, its bottom 4 px above the hairline -- holding a
            // TextBox, whose TextInput is ONE LINE TALL and CENTRED in it
            // (`width: parent.width - 16; anchors.centerIn: parent`).
            //
            // The lock used to be one bare TextInput with none of that: no
            // left inset, and a line drawn at the TOP of a full-height box,
            // which left 46 px of air between the value and the hairline where
            // the login screen leaves 26. Both differences are structural, so
            // they are undone structurally rather than tuned: the box is the
            // box, and the field is a one-line field centred in it.
            //
            // Rendered offscreen side by side at the sheet's own 1707x1067
            // geometry (field 64, font 20, both screens' real fonts), the
            // value's ink lands on the SAME rows on both, relative to the
            // hairline, and at the same x: -42..-27, 9 px in from the column's
            // left edge.
            Item {
                id: sheetPasswordBox
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 8
                anchors.rightMargin: Math.round(root.sheetField * 0.9) + 8
                anchors.bottomMargin: 4
                height: root.sheetField

                TextInput {
                    id: sheetPassword
                    width: parent.width
                    height: implicitHeight
                    // One line, centred -- TextBox's `anchors.centerIn: parent`.
                    anchors.centerIn: parent
                    clip: true

                    color: Appearance.colors.colOnSurface
                    font.family: Appearance.font.family.main
                    font.pixelSize: Math.round(root.sheetField * 0.32)
                    selectionColor: Appearance.colors.colSecondaryContainer
                    selectedTextColor: Appearance.colors.colOnSecondaryContainer

                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhSensitiveData
                    enabled: root.contextReady && !root.context.unlockInProgress

                    // The shared LockContext is the single source of the typed
                    // text on every arrangement, so the toolbar's field and this
                    // one can never disagree about what has been typed.
                    onTextChanged: {
                        if (root.contextReady)
                            root.context.currentText = text;
                    }
                    onAccepted: root.context.tryUnlock(root.ctrlHeld)
                    Keys.onPressed: event => root.context.resetClearTimer()
                    Keys.onEscapePressed: root.context.currentText = ""
                }
            }

            // The commit control: a return KEYCAP, not the round arrow. The
            // arrow was the only circle on this screen and the keycap matches
            // the square account tile beside it. It sits ON the baseline rather
            // than centred, which is why the item is 1.28x the field height.
            Item {
                id: sheetCommit
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Math.round(root.sheetField * 0.14)
                width: Math.round(root.sheetField * 0.60)
                height: width
                opacity: sheetPasswordLine.armed ? 1 : (sheetPasswordLine.focused ? 0.75 : 0.35)

                Behavior on opacity { NumberAnimation { duration: 180 } }

                Rectangle {
                    anchors.fill: parent
                    radius: 0
                    color: sheetCommit.armed && sheetCommitHover.containsMouse
                        ? Qt.rgba(Appearance.colors.colPrimary.r, Appearance.colors.colPrimary.g,
                            Appearance.colors.colPrimary.b, 0.22)
                        : "transparent"
                    border.width: 1
                    border.color: sheetPasswordLine.armed
                        ? Appearance.colors.colPrimary
                        : Qt.rgba(root.sheetOutline.r, root.sheetOutline.g, root.sheetOutline.b, 0.45)

                    Behavior on color { ColorAnimation { duration: 140 } }
                    Behavior on border.color { ColorAnimation { duration: 140 } }
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "keyboard_return"
                    iconSize: Math.round(root.sheetField * 0.34)
                    color: Appearance.colors.colOnSurfaceVariant
                }

                MouseArea {
                    id: sheetCommitHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.context.tryUnlock()
                }
            }
        }

        // ---- status ------------------------------------------------------
        // A RESERVED line, the same one Main.qml reserves last in its column,
        // and reserved even when it has nothing to say. The reservation is not
        // decoration: the height of this row is what puts the password line
        // where the login screen puts it.
        //
        // This column had no such row, so the whole form -- the account tile,
        // the input box, the return key -- sat one column spacing plus one line
        // LOWER than the greeter's. Measured offscreen on both at the same size
        // (844x502): the password baseline was at 91.4% of the height here and
        // 87.9% on the login screen, which is the "the lock's input box is not
        // where the login's is" the eye reads as a form that has slipped down
        // toward the bottom edge. Main.qml's own note on its copy of this row
        // says the same thing from the other side.
        //
        // The greeter reserves the row for a failed login. This one has a
        // reason of its own: sheet mode reports a wrong password by turning the
        // line red and nothing else, while the classic arrangement says it in
        // the field's placeholder. The row is what a claim of "the same" has to
        // be built out of -- one phrase, one line, elided rather than wrapped,
        // so the height it reserves is exactly the height Main.qml reserves and
        // cannot grow when a message appears.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: sheetStatusLabel.implicitHeight + 2

            StyledText {
                id: sheetStatusLabel
                anchors.horizontalCenter: parent.horizontalCenter
                visible: GlobalStates.screenUnlockFailed
                text: GlobalStates.screenUnlockFailed
                    ? Translation.tr("Incorrect password") : ""
                color: Appearance.colors.colError
                font.family: Appearance.font.family.main
                font.pixelSize: Math.round(root.sheetField * 0.26)
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }
    }

    // ---- sheet telemetry: boot facts in the bottom corners -------------
    // Two mono lines a side, as on the greeter. Read at lock time from the
    // kernel rather than baked at install time, which is the one thing the
    // lock can do better than a greeter that has no uptime service of its
    // own.
    Process {
        id: kernelProc
        command: ["cat", "/proc/sys/kernel/osrelease"]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = text.trim();
                root.kernelVersion = v.length > 0 ? v : "linux";
            }
        }
    }
    property string kernelVersion: "linux"

    component SheetTelemetry: StyledText {
        font.family: root.sheetMono
        font.pixelSize: Math.max(10, Math.round(root.height * 0.0155))
        color: Appearance.colors.colOnSurfaceVariant
    }

    Column {
        id: sheetTelemetryLeft
        visible: root.sheetMode
        opacity: root.toolbarOpacity
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 26
        anchors.bottomMargin: 22
        spacing: 3

        SheetTelemetry { text: "kernel " + root.kernelVersion + "  OK" }
        SheetTelemetry { text: "session hyprland  OK" }
    }

    Column {
        id: sheetTelemetryRight
        visible: root.sheetMode
        opacity: root.toolbarOpacity
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 26
        // Lifted clear of the power row below it. Both used to share the
        // bottom-right corner and were drawn on top of each other.
        anchors.bottomMargin: 22 + 46
        spacing: 3

        SheetTelemetry { text: "wm hyprland"; horizontalAlignment: Text.AlignRight }
        // Not "greeter sddm", which is what the login screen prints: this is
        // a lock, and claiming to be a greeter would be a lie on screen.
        SheetTelemetry { text: "lock shell  OK"; horizontalAlignment: Text.AlignRight }
    }

    // ---- the power controls, bottom-right -----------------------------
    // Where the pill toolbar kept them, sheet has no toolbar, so they take
    // the corner the greeter gives them. Same three actions, same glyphs as
    // the toolbar's, and the same password-guarded two-step for power and
    // reboot.
    component SheetIconButton: Rectangle {
        id: sheetBtn
        required property string glyph
        signal triggered()
        width: 34; height: 34; radius: 4
        // `highlighted` is the open state of the menu this button opens, drawn
        // with the same tint as hover so it needs no second visual vocabulary.
        property bool highlighted: false
        color: (sheetHover.containsMouse || sheetBtn.highlighted)
            ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
        border.width: 1
        border.color: Qt.rgba(root.sheetOutline.r, root.sheetOutline.g, root.sheetOutline.b, 0.35)
        opacity: root.toolbarOpacity
        Behavior on color { ColorAnimation { duration: 140 } }

        MaterialSymbol {
            anchors.centerIn: parent
            text: sheetBtn.glyph
            iconSize: 18
            color: Appearance.colors.colOnSurfaceVariant
        }
        MouseArea {
            id: sheetHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sheetBtn.triggered()
        }
    }

    Row {
        id: sheetPowerRow
        visible: root.sheetMode
        opacity: root.toolbarOpacity
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 22
        anchors.bottomMargin: 18
        spacing: 6

        // The sheet's copy of the toolbar's button: same glyph, same menu, same
        // guard. It replaces the three-button row that stood here for the same
        // reason (see powerActions above).
        SheetIconButton {
            id: sheetPowerBtn
            glyph: "settings_power"
            highlighted: root.powerMenuOpen
            onTriggered: root.powerMenuOpen ? root.closePowerMenu() : root.openPowerMenu(sheetPowerBtn)
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // THE POWER MENU CARD, the thing the row above opens.
    //
    // Drawn inside this surface rather than as a Quickshell PopupWindow, which
    // is what the sidebar's power menu next door uses: the lock is a
    // layer-shell surface on the TOP layer, and a popup window is an ordinary
    // toplevel -- it would be composited underneath the lock and never seen.
    //
    // Declared last so it paints over the toolbar and the sheet telemetry.
    // ═════════════════════════════════════════════════════════════════════
    Rectangle {
        id: powerMenu
        visible: root.powerMenuOpen
        width: 216
        height: powerMenuColumn.implicitHeight + 16
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colLayer0
        border.width: 1
        border.color: Appearance.colors.colLayer0Border
        clip: true

        // Swallows presses that land on the card's own padding: without it they
        // reach the surface's MouseArea behind and close the menu the user was
        // aiming at. Declared first so the rows stay above it.
        MouseArea {
            anchors.fill: parent
        }

        Column {
            id: powerMenuColumn
            anchors.centerIn: parent
            width: parent.width - 16
            spacing: 2

            Repeater {
                model: root.powerActions

                delegate: RippleButton {
                    id: powerRow
                    required property var modelData

                    width: powerMenuColumn.width
                    height: 40
                    buttonRadius: powerMenu.radius - 4
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    colRipple: Appearance.colors.colLayer1Active
                    onClicked: root.runPowerAction(powerRow.modelData)

                    contentItem: RowLayout {
                        anchors {
                            fill: parent
                            leftMargin: 12
                            rightMargin: 12
                        }
                        spacing: 10

                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: powerRow.modelData.icon
                            iconSize: 18
                            color: Appearance.colors.colOnLayer0
                        }

                        StyledText {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: powerRow.modelData.label
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer0
                        }
                    }
                }
            }
        }
    }

    // Escape closes the menu, which is what a card floating over a lock should
    // answer to. The password field keeps focus throughout, so the menu never
    // swallows typing -- a password typed at a locked screen must always work.
    Shortcut {
        sequence: "Escape"
        enabled: root.powerMenuOpen
        onActivated: root.closePowerMenu()
    }

    component IconAndTextPair: Row {
        id: pair
        required property string icon
        required property string text
        property color color: Appearance.colors.colOnSurfaceVariant

        spacing: 4
        Layout.fillHeight: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        

        MaterialSymbol {
            anchors.verticalCenter: parent.verticalCenter
            fill: 1
            text: pair.icon
            iconSize: Appearance.font.pixelSize.huge
            animateChange: true
            color: pair.color
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: pair.text
            color: pair.color
        }
    }
}

