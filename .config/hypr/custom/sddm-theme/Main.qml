import QtQuick
import QtQuick.Layouts
import SddmComponents 2.0

/*
 * The login screen.
 *
 * The design brief, in one line: the same wallpaper as the desktop, one
 * vertically stacked column in the middle of the screen, and nothing that
 * looks like a form. No boxes around the text, no card, no chrome -- the
 * user's name is just type, the password is just type over a hairline that
 * lights up when it has focus, and the accent only appears on the one
 * control that commits (the arrow at the end of the password line).
 *
 * Why the column is vertical: everything else about this screen is a single
 * decision ("who, then the password"), and a row of pills spread the eye out
 * sideways for no reason. Stacked, the screen reads top to bottom in the same
 * order as the login itself:
 *
 *      clock ........ the ambient thing, top
 *      avatar ....... who you are (click it to switch account)
 *      name ......... the account name
 *      password ..... the hairline field, with the commit arrow
 *      status ....... only when something went wrong
 *
 * The password field takes focus by itself. Nobody should have to click into
 * a lock: the field is focused on load, re-focused on any stray click, and
 * re-focused after a failed attempt -- so typing a password is always the
 * first thing you can do, with no targeting.
 *
 * Colours and the wallpaper are not hard-coded here: install-sddm-theme.sh
 * reads the desktop's current wallpaper and its generated Material palette
 * out of the shell's own state and writes them into theme.conf, which is what
 * `themeValue()` below reads. The fallbacks are the desktop's dark palette,
 * so the file is still correct if it is ever copied somewhere by hand.
 */    Rectangle {
    id: root

    width: 640
    height: 480

    function themeValue(key, fallback) {
        var value = (typeof config === "undefined" || !config) ? undefined : config[key];
        return (value === undefined || value === null || value === "") ? fallback : String(value);
    }

    // ── Layout selection ──────────────────────────────────────────────
    // The arrangement of this screen is a layout fragment (layouts/*.js,
    // composed into layouts/active.js by scripts/set-login-layout.sh and
    // included at the bottom of this file, in Component.onCompleted). Its
    // three variables feed the root properties below, which the column and
    // clock bindings read; when the fragment is missing or incomplete each
    // variable falls back to the shipped arrangement -- a broken fragment
    // must degrade, never blank the login screen.
    property string loginAlign: "center"
    property real loginVerticalOffset: 0.04
    property bool loginClockVisible: true
    // Templates with a frosted panel behind the column ("glass"), and how
    // large the clock is drawn (1.0 = the shipped size). Both are read from
    // the same fragment as the three originals, with the same defensive
    // validation -- a fragment that omits them simply keeps the defaults.
    property bool loginCard: false
    property real loginClockScale: 1.0
    // The "ops" mission-console presentation (see layouts/ops.js): corner
    // telemetry, huge clock with accent seconds, segmented passphrase card,
    // and the arrow / dot template switcher. Set by the active fragment.
    property bool loginHud: false
    // The "sheet" arrangement (layouts/sheet.js): the clock moved to the top
    // RIGHT and enlarged, the account given Ledger's square tile and its
    // `local · admin` title, boot telemetry in the bottom corners, and the
    // round arrow replaced by a return keycap. It hides the classic column's
    // avatar and name rather than adding a second account control, so there
    // is still exactly one password field and one commit control.
    property bool loginSheet: false

    // Kernel string for the sheet layout's telemetry, baked into theme.conf
    // by install-sddm-theme.sh at install time, exactly like `host` above: a
    // greeter has no uptime or kernel service of its own.
    //
    // It was briefly a live `Process { command: "/usr/bin/cat" }` reading
    // /proc/version, which is the tidier answer and does not work here: this
    // QtQml build does not export the Process type, and shelling out from a
    // greeter is precisely the failure mode this screen must never have. A
    // wrong-but-instant string beats a right-but-hung login screen.
    readonly property string kernelVersion: themeValue("kernel", "linux")

    // Which fragment is active (written by set-login-layout.sh as
    // `var activeLayout = "…"`). The arrows cycle the other fragments by name.
    property string activeLayout: "classic"
    property var layoutNames: []

    // Reads the layout fragment's variables out of `config`, where
    // install-sddm-theme.sh flattens them into theme.conf as `layout_<name>`.
    //
    // They used to come from `Qt.include("layouts/active.js")` at runtime.
    // That cannot work: Qt.include may only be called from a .js file, so
    // every call from here threw
    //     Error: Qt.include(): Can only be called from JavaScript files
    // and the surrounding try/catch swallowed it. All eight layouts rendered
    // as the shipped arrangement and set-login-layout.sh did nothing.
    // XMLHttpRequest is not a way out either -- QML refuses GET on local
    // files unless QML_XHR_ALLOW_FILE_READ is set, and a greeter does not set
    // it. `config` is the one channel a greeter genuinely supports, and the
    // installer already writes hostname and palette through it.
    //
    // Every read is defensive and falls back to the shipped arrangement, so a
    // theme.conf without layout keys still renders a working login screen.
    function applyLoginFragment() {
        var a = root.themeValue("layout_align", "center");
        if (a === "left" || a === "center")
            root.loginAlign = a;

        var vo = parseFloat(root.themeValue("layout_verticalOffset", "0.04"));
        if (!isNaN(vo) && vo >= -0.3 && vo <= 0.4)
            root.loginVerticalOffset = vo;

        var cs = parseFloat(root.themeValue("layout_clockScale", "1.0"));
        if (!isNaN(cs) && cs >= 0.5 && cs <= 2.0)
            root.loginClockScale = cs;

        root.loginClockVisible = root.themeValue("layout_clockVisible", "true") !== "false";
        root.loginCard = root.themeValue("layout_card", "false") === "true";
        root.loginHud = root.themeValue("layout_hud", "false") === "true";
        root.loginSheet = root.themeValue("layout_sheet", "false") === "true";

        var name = root.themeValue("layout_activeLayout", "classic");
        if (name.length > 0)
            root.activeLayout = name;
    }

    // ── template switching ────────────────────────────────────────────
    // Kept for the ops HUD's arrows and dots, but it can no longer read a
    // fragment from disk (see applyLoginFragment for why). Each layout's
    // values are compiled in below, so switching works with no file access at
    // all. The values are the ones each layouts/*.js fragment declares; the
    // fragments stay the documented, human-editable description of a layout.
    function applyFragmentByName(name) {
        var L = sheet ? { align: "left", verticalOffset: 0.04, clockVisible: true,
                          card: false, clockScale: 1.0, hud: false, sheet: true }
            : name === "ops" ? { align: "center", verticalOffset: 0.04, clockVisible: true,
                          card: false, clockScale: 1.0, hud: true, sheet: false }
            : name === "glass" ? { align: "center", verticalOffset: 0.04, clockVisible: true,
                          card: true, clockScale: 1.0, hud: false, sheet: false }
            : name === "beacon" ? { align: "left", verticalOffset: 0.04, clockVisible: true,
                          card: false, clockScale: 1.45, hud: false, sheet: false }
            : name === "corner" ? { align: "left", verticalOffset: 0.16, clockVisible: true,
                          card: false, clockScale: 0.8, hud: false, sheet: false }
            : name === "minimal" ? { align: "center", verticalOffset: 0.04, clockVisible: false,
                          card: false, clockScale: 1.0, hud: false, sheet: false }
            : name === "studio" ? { align: "center", verticalOffset: 0.10, clockVisible: true,
                          card: true, clockScale: 1.2, hud: false, sheet: false }
            : null; // classic, and anything unknown
        if (!L)
            return; // unknown layout: keep the current arrangement
        root.loginAlign = L.align;
        root.loginVerticalOffset = L.verticalOffset;
        root.loginClockVisible = L.clockVisible;
        root.loginCard = L.card;
        root.loginClockScale = L.clockScale;
        root.loginHud = L.hud;
        root.loginSheet = L.sheet;
        root.activeLayout = name;
    }

    function cycleThemeLayout(dir) {
        if (root.layoutNames.length < 2)
            return;
        var i = root.layoutNames.indexOf(root.activeLayout);
        i = ((i + dir) % root.layoutNames.length + root.layoutNames.length) % root.layoutNames.length;
        root.activeLayout = root.layoutNames[i];
        root.applyFragmentByName(root.activeLayout);
    }

    readonly property color colSurface: themeValue("surface", "#141314")
    readonly property color colSurfaceContainer: themeValue("surfaceContainer", "#211f20")
    readonly property color colOnSurface: themeValue("onSurface", "#e7e1e3")
    readonly property color colOnSurfaceVariant: themeValue("onSurfaceVariant", "#cac5c7")
    readonly property color colPrimary: themeValue("primary", "#d1c2d2")
    readonly property color colOnPrimary: themeValue("onPrimary", "#372d3a")
    readonly property color colOutline: themeValue("outline", "#949091")
    readonly property color colError: themeValue("error", "#ffb4ab")
    // The machine's name, baked into theme.conf by install-sddm-theme.sh at
    // install time (a greeter has no hostname lookup of its own).
    readonly property string hostName: themeValue("host", "localhost").toUpperCase()

    readonly property string iconFont: "Material Symbols Rounded"
    readonly property string textFont: "Google Sans Flex"

    // The one measurement the whole column is built on. Everything below is a
    // multiple or a fraction of it, so the screen scales with its height
    // instead of being pinned to pixels that only look right at 1080p.
    readonly property int unit: Math.max(200, Math.min(width, height * 0.6))
    readonly property int columnWidth: Math.round(unit * 0.62)
    readonly property int avatarSize: Math.round(unit * 0.19)
    readonly property int fieldHeight: Math.round(unit * 0.10)

    // Who we are logging in as. SDDM remembers the last account; the user menu
    // is what changes it. Kept as a plain string (not an input field) because
    // a single-user machine should not have to be typed into.
    property string currentUser: ""
    property string statusMessage: ""
    property bool statusIsError: false
    property bool userMenuOpen: false
    property bool powerMenuOpen: false

    TextConstants { id: textConstants }

    function doLogin() {
        if (root.currentUser.length === 0) {
            root.statusMessage = textConstants.promptSelectUser;
            root.statusIsError = true;
            return;
        }
        root.userMenuOpen = false;
        root.statusMessage = "";
        root.statusIsError = false;
        // Session row: SDDM's remembered one, clamped into range. The list
        // holds exactly one working entry (hyprland.desktop -- see the notes
        // below on the removed uwsm duplicate), so any out-of-range or unset
        // value means row 0, the only valid choice.
        sddm.login(root.currentUser, passwordField.text,
                   Math.max(0, sessionModel.lastIndex || 0));
    }

    // Automatic focus. Called on load, on any click that misses a control, and
    // after a failed attempt -- so the field is always ready to take a password.
    function focusPassword() {
        passwordField.forceActiveFocus();
    }

    // The name of the active keyboard layout, read defensively: the greeter
    // exposes it through `keyboard`, and a layout list that is empty (or a
    // greeter that does not publish one) must simply hide the label rather
    // than throw.
    function layoutText() {
        try {
            if (typeof keyboard === "undefined" || !keyboard || !keyboard.layouts
                    || keyboard.layouts.length === 0)
                return "";
            var idx = (typeof keyboard.currentLayout === "number") ? keyboard.currentLayout : 0;
            var layout = keyboard.layouts[idx];
            if (!layout)
                return "";
            return layout.shortName || layout.longName || "";
        } catch (e) {
            return "";
        }
    }

    function cycleKeyboardLayout() {
        try {
            if (typeof keyboard === "undefined" || !keyboard || !keyboard.layouts
                    || keyboard.layouts.length < 2)
                return;
            keyboard.currentLayout = (keyboard.currentLayout + 1) % keyboard.layouts.length;
        } catch (e) {
            // A greeter without a keyboard model: nothing to cycle.
        }
    }

    // ------------------------------------------------------------------
    // Log in state coming back from the greeter
    // ------------------------------------------------------------------
    Connections {
        target: sddm

        function onLoginFailed() {
            passwordField.text = "";
            root.statusIsError = true;
            root.statusMessage = textConstants.loginFailed;
            root.focusPassword();
        }

        function onInformationMessage(message) {
            root.statusIsError = true;
            root.statusMessage = message;
        }
    }

    // ------------------------------------------------------------------
    // Background: the desktop's wallpaper under a vertical scrim. The scrim
    // is darkest at the top and bottom, which is where the clock and the
    // controls sit, so both keep their contrast over a bright photo -- while
    // the middle stays almost untouched (the picture is the point).
    // ------------------------------------------------------------------
    Image {
        anchors.fill: parent
        source: Qt.resolvedUrl(root.themeValue("background", "background.png"))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
            GradientStop { position: 0.42; color: Qt.rgba(0, 0, 0, 0.18) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.60) }
        }
    }

    // The sheet arrangement's own scrim: a single FLAT, very light wash over
    // the whole screen, sitting between the wallpaper and everything else.
    //
    // The gradient above is the shipped one and it is not what the sheet
    // design was drawn against. That gradient is heavy where the clock and
    // the form sit (0.55 at the top, 0.60 at the bottom) and almost absent
    // through the middle, so it reads as a vignette: the wallpaper visibly
    // darkens toward the edges. The sheet design has no vignette -- it is a
    // uniform tint, and the previews that were approved used a flat
    // rgba(8,8,8,.80) over the picture. Measured against the render, that
    // reads as far too dark here, so this is a much thinner 0.22: enough to
    // hold the type legible over a bright photo, faint enough that the
    // wallpaper is not dimmed.
    //
    // It is additive with the gradient above rather than a replacement,
    // because the gradient is what keeps the clock readable at the top on
    // every layout. On sheet the two together come to about 0.63 at the top
    // edge and 0.68 at the bottom, which is lighter at the middle than the
    // shipped arrangement and flat in feel.
    Rectangle {
        visible: root.loginSheet
        anchors.fill: parent
        color: Qt.rgba(0.03, 0.03, 0.035, 0.22)
    }

    // ------------------------------------------------------------------
    // Clock, top centre: the only decoration, and it is the thing you look
    // at while the machine boots. Light weight, wide tracking, no bold.
    // ------------------------------------------------------------------
    Column {
        id: clockBlock
        // Two arrangements. The classic one is centred at the top; "sheet"
        // pins it hard to the right edge, which is what that design is built
        // around -- the form owns the left, the time owns the right.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: root.loginSheet ? (parent.width / 2 - width / 2 - Math.round(parent.width * 0.06)) : 0
        anchors.top: parent.top
        anchors.topMargin: parent.height * (root.loginSheet ? 0.085 : 0.075)
        spacing: root.loginSheet ? 6 : 2
        // Layout choice: some arrangements drop the clock entirely
        // (loginClockVisible) and the password column takes the stage. HUD
        // mode draws its own clock, so the classic one steps aside.
        visible: root.loginClockVisible && !root.loginHud

        // In sheet mode the time is typeset as one line with the seconds in
        // the accent, so the block can be right-aligned to a single edge
        // without the seconds dropping onto their own row.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.loginSheet
                ? sheetTime.implicitWidth + 10 + sheetSeconds.implicitWidth
                : classicTime.implicitWidth
            height: root.loginSheet ? sheetTime.implicitHeight : classicTime.implicitHeight
            visible: root.loginSheet

            Text {
                id: sheetTime
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                text: Qt.formatTime(clockTimer.time, "HH:mm")
                color: root.colOnSurface
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Math.min(root.height * 0.115, 124)
                font.weight: Font.Light
                font.letterSpacing: -2
            }

            Text {
                id: sheetSeconds
                anchors.left: sheetTime.right
                anchors.leftMargin: 10
                anchors.bottom: parent.bottom
                text: Qt.formatTime(clockTimer.time, "ss")
                color: root.colPrimary
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Math.min(root.height * 0.115, 124) * 0.46
                font.weight: Font.Light
            }
        }

        Text {
            id: classicTime
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !root.loginSheet
            text: Qt.formatTime(clockTimer.time, "HH:mm")
            color: root.colOnSurface
            font.family: root.textFont
            font.pixelSize: Math.min(root.height * 0.15, 160) * root.loginClockScale
            font.weight: Font.Light
            font.letterSpacing: 2
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.loginSheet
                ? Qt.formatDate(clockTimer.time, "ddd dd MMM yyyy").toUpperCase()
                : Qt.formatDate(clockTimer.time, "dddd, d MMMM")
            color: root.colOnSurfaceVariant
            opacity: 0.8
            font.family: root.loginSheet ? "JetBrainsMono Nerd Font Mono" : root.textFont
            font.pixelSize: Math.max(11, Math.min(root.height * 0.018, 15))
            font.letterSpacing: root.loginSheet ? 2.4 : 0.6
        }
    }

    // A greeter is ordinary QML: there is no shell clock service here, so a
    // plain timer re-rolls the formatted strings every ten seconds.
    QtObject {
        id: clockTimer
        property date time: new Date()
    }

    Timer {
        interval: 10000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: clockTimer.time = new Date()
    }

    // Any click that does not land on a control puts the cursor back in the
    // password line. Declared before the controls so it never sits in front
    // of one.
    MouseArea {
        anchors.fill: parent
        onClicked: {
            root.userMenuOpen = false;
            root.powerMenuOpen = false;
            root.focusPassword();
        }
    }

    // ==================================================================
    // OPS HUD — the mission-console layer (fragment: ops.js)
    // Corner telemetry, huge centred clock with accent seconds, the login
    // column regrouped inside a sharp card with a segmented ruler, and the
    // arrow / dot template switcher. All colours come from the baked palette.
    // ==================================================================

    // ── the big clock (HUD draws its own; the classic clock hides) ──
    Column {
        id: hudClockBlock
        visible: root.loginHud && root.loginClockVisible
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: parent.height * 0.14
        spacing: 10

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: hudBigTime.implicitWidth + 12 + hudSeconds.implicitWidth
            height: hudBigTime.implicitHeight

            Text {
                id: hudBigTime
                anchors.left: parent.left
                text: Qt.formatTime(clockTimer.time, "HH:mm")
                color: root.colOnSurface
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Math.min(root.height * 0.13, 118)
                font.weight: Font.Bold
                font.letterSpacing: 2
            }
            Text {
                id: hudSeconds
                anchors.left: hudBigTime.right
                anchors.baseline: hudBigTime.baseline
                anchors.leftMargin: 12
                text: Qt.formatTime(clockTimer.time, "ss")
                color: root.colPrimary
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Math.min(root.height * 0.032, 30)
                font.weight: Font.Medium
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "OPERATOR // " + (root.currentUser.length > 0 ? root.currentUser.toUpperCase() : "?")
            color: root.colOnSurface
            opacity: 0.9
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 12
            font.bold: true
            font.letterSpacing: 3
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(clockTimer.time, "ddd dd.MM.yy").toUpperCase()
            color: root.colOnSurfaceVariant
            opacity: 0.65
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 12
            font.letterSpacing: 2
        }
    }

    // The classic clock block hides in HUD mode (the HUD clock replaces it).
    // The binding lives on the block itself; see clockBlock.visible below.

    // ── corner telemetry ───────────────────────────────────────
    Column {
        visible: root.loginHud
        anchors { top: parent.top; left: parent.left; margins: 26; topMargin: 20 }
        spacing: 4
        Row {
            spacing: 8
            Row {
                spacing: 2
                Repeater {
                    model: 7
                    Rectangle { width: 2; height: 9; color: root.colPrimary; rotation: 24 }
                }
            }
            Text { text: "SESSION SUSPENDED // " + (root.currentUser.length > 0 ? "ICE ACTIVE" : "NO SESSION")
                color: root.colOnSurface; font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.5 }
        }
        Text { text: "「認証待ち」認証準備中"
            color: root.colPrimary; opacity: 0.85
            font.family: "JetBrainsMono Nerd Font Mono"; font.pixelSize: 11 }
    }

    Column {
        visible: root.loginHud
        anchors { top: parent.top; right: parent.right; margins: 26; topMargin: 20 }
        spacing: 4
        Text { anchors.right: parent.right
            text: "HOST " + root.hostName + " // OFFLINE OLYMPUS"
            color: root.colOnSurfaceVariant; font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 11; font.letterSpacing: 1.5 }
        Text { anchors.right: parent.right
            text: "PROFILE // " + (root.currentUser.length > 0 ? root.currentUser.toUpperCase() : "—")
            color: root.colOnSurfaceVariant; opacity: 0.75
            font.family: "JetBrainsMono Nerd Font Mono"; font.pixelSize: 11 }
    }

    // ── HUD card around the login column + segmented ruler ──────
    Rectangle {
        visible: root.loginHud
        anchors.horizontalCenter: loginColumn.horizontalCenter
        anchors.verticalCenter: loginColumn.verticalCenter
        width: loginColumn.width + 44
        height: loginColumn.height + 78
        radius: 4
        color: Qt.rgba(root.colSurface.r, root.colSurface.g, root.colSurface.b, 0.72)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12)

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 12
            spacing: 4
            Repeater {
                model: 16
                Rectangle {
                    width: 10; height: 14
                    color: "transparent"
                    border.width: 1
                    border.color: index < passwordField.text.length
                        ? root.colPrimary
                        : Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.45)
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 34
            text: root.statusIsError ? "ACCESS DENIED — RETRY" : "AUTH // PASSPHRASE"
            color: root.statusIsError ? root.colError : root.colOnSurfaceVariant
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: 10
            font.letterSpacing: 2
        }
    }

    // ── side arrows: cycle the login templates live ─────────────
    Rectangle {
        id: hudArrowLeft
        visible: root.loginHud
        width: 52; height: 52; radius: 26
        anchors { left: parent.left; leftMargin: 24; verticalCenter: parent.verticalCenter }
        color: hudLeftArea.containsMouse ? Qt.rgba(root.colPrimary.r, root.colPrimary.g, root.colPrimary.b, 0.18)
            : Qt.rgba(0, 0, 0, 0.35)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.25)
        Text { anchors.centerIn: parent; text: "chevron_left"; font.family: root.iconFont
            font.pixelSize: 22; color: root.colOnSurface
            font.variableAxes: ({ "FILL": 0, "opsz": 22 }) }
        MouseArea { id: hudLeftArea; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: root.cycleThemeLayout(-1) }
    }
    Rectangle {
        id: hudArrowRight
        visible: root.loginHud
        width: 52; height: 52; radius: 26
        anchors { right: parent.right; rightMargin: 24; verticalCenter: parent.verticalCenter }
        color: hudRightArea.containsMouse ? Qt.rgba(root.colPrimary.r, root.colPrimary.g, root.colPrimary.b, 0.18)
            : Qt.rgba(0, 0, 0, 0.35)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.25)
        Text { anchors.centerIn: parent; text: "chevron_right"; font.family: root.iconFont
            font.pixelSize: 22; color: root.colOnSurface
            font.variableAxes: ({ "FILL": 0, "opsz": 22 }) }
        MouseArea { id: hudRightArea; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: root.cycleThemeLayout(1) }
    }

    // ── dots: one per template, click to jump ────────────────────
    Row {
        visible: root.loginHud
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
        spacing: 10
        Repeater {
            model: root.layoutNames
            delegate: Rectangle {
                required property int index
                required property string modelData
                readonly property bool selected: modelData === root.activeLayout
                width: selected ? 10 : 8; height: selected ? 10 : 8
                radius: width / 2
                color: selected ? root.colPrimary : Qt.rgba(1, 1, 1, 0.30)

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.activeLayout = modelData;
                        root.applyFragmentByName(modelData);
                    }
                }
            }
        }
    }

    // ── bottom telemetry line ───────────────────────────────────
    Row {
        visible: root.loginHud
        anchors { left: parent.left; bottom: parent.bottom; margins: 26; bottomMargin: 14 }
        spacing: 16
        Text { text: "QUEUE 1/1 CLEARED"; color: root.colOnSurfaceVariant; opacity: 0.55
            font.family: "JetBrainsMono Nerd Font Mono"; font.pixelSize: 10 }
        Text { text: "VULN 12 AFFECTED"; color: root.colError; opacity: 0.55
            font.family: "JetBrainsMono Nerd Font Mono"; font.pixelSize: 10 }
        Text { text: "ICE NOMINAL"; color: root.colOnSurfaceVariant; opacity: 0.55
            font.family: "JetBrainsMono Nerd Font Mono"; font.pixelSize: 10 }
    }

    // ==================================================================
    // The login column
    // ==================================================================
    // ── Optional frosted panel behind the column ────────────────────────
    // The "glass" family of templates: the same stack, on a soft surface so
    // it reads as one object over a busy wallpaper. Sits behind the column by
    // z-order, tracks its geometry, and is simply hidden when the template
    // does not ask for it -- nothing else in the screen changes.
    Rectangle {
        id: loginCardBackdrop
        visible: root.loginCard && !root.loginHud
        z: -1
        anchors.horizontalCenter: loginColumn.horizontalCenter
        anchors.verticalCenter: loginColumn.verticalCenter
        width: loginColumn.width + Math.round(root.width * 0.05)
        height: loginColumn.height + Math.round(root.height * 0.055)
        radius: Math.round(root.height * 0.024)
        color: Qt.rgba(root.colSurface.r, root.colSurface.g, root.colSurface.b, 0.62)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.10)
    }

    Column {
        id: loginColumn

        // Layout choice: centred (default) or left-set, both vertically
        // offset from the true centre. "sheet" pins the column to the
        // bottom-left instead, which is the arrangement its design is built
        // around.
        //
        // The column is ALWAYS anchored by its horizontal centre, even in
        // sheet mode: swapping the anchor line itself is not something a
        // binding can do, and mixing `anchors.left` with
        // `anchors.horizontalCenter` is a QML error. So "bottom-left" is
        // expressed as a centre offset that walks the column out to the left
        // margin, the same trick the "left" arrangement already uses. The
        // offset is computed from the column's own `width`, which differs in
        // sheet mode -- using root.columnWidth here left it stranded in the
        // middle, still on the centre line.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: root.loginSheet
            ? -Math.round(parent.width / 2 - width / 2 - Math.round(parent.width * 0.06))
            : (root.loginAlign === "left"
                ? -Math.round(root.width / 2 - root.columnWidth / 2 - Math.min(90, root.width * 0.08))
                : 0)
        anchors.verticalCenter: parent.verticalCenter
        // HALF the height in sheet mode, not all of it: the anchor is the
        // vertical CENTRE, so moving the column's BOTTOM up to the 8.5% margin
        // moves the centre up by the margin plus half the column. The full
        // height parked the form ~107 px above the bottom-left corner it is
        // drawn for (measured on the offscreen render at 1707x1067) while the
        // clock kept its own 8.5% from the top, so the two-corner rhythm this
        // arrangement is built on came out one-sided -- and the password line
        // was the most visible part of it, being the lowest thing in the form.
        // LockSurface.qml carries the same expression and the same note.
        anchors.verticalCenterOffset: root.loginSheet
            ? Math.round(parent.height / 2 - height / 2 - parent.height * 0.085)
            : Math.round(root.height * root.loginVerticalOffset)
        width: root.loginSheet ? Math.round(root.width * 0.34) : root.columnWidth
        spacing: Math.round(root.height * (root.loginSheet ? 0.013 : 0.018))

        // ---- avatar: who you are, and the way to change it --------------
        // In "sheet" the classic centred avatar is hidden and the account
        // gets its own square-tile block below instead. Hiding rather than
        // adding keeps exactly one account control on screen.
        Item {
            id: avatarItem
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !root.loginSheet
            width: root.avatarSize
            height: root.avatarSize

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: avatarArea.containsMouse || root.userMenuOpen
                    ? Qt.rgba(1, 1, 1, 0.10)
                    : Qt.rgba(0, 0, 0, 0.22)
                border.width: 1
                border.color: avatarArea.containsMouse || root.userMenuOpen
                    ? Qt.rgba(root.colPrimary.r, root.colPrimary.g, root.colPrimary.b, 0.65)
                    : Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.35)

                Behavior on color {
                    ColorAnimation { duration: 140 }
                }
                Behavior on border.color {
                    ColorAnimation { duration: 140 }
                }

                Text {
                    anchors.centerIn: parent
                    text: root.currentUser.length > 0
                        ? root.currentUser.substring(0, 1).toUpperCase()
                        : "?"
                    color: root.colOnSurface
                    font.family: root.textFont
                    font.pixelSize: Math.round(root.avatarSize * 0.38)
                    font.weight: Font.Medium
                }
            }

            // A small chevron in the corner of the avatar is the whole hint
            // that the account can be changed -- no separate button.
            Glyph {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: -2
                anchors.bottomMargin: -2
                text: "expand_more"
                glyphSize: 18
                color: root.colOnSurfaceVariant
                opacity: avatarArea.containsMouse || root.userMenuOpen ? 1 : 0.55
            }

            MouseArea {
                id: avatarArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (userModel.count > 1) {
                        root.userMenuOpen = !root.userMenuOpen;
                    } else {
                        root.focusPassword();
                    }
                }
            }
        }

        // ---- name: type, not a field ------------------------------------
        Item {
            id: nameItem
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !root.loginSheet
            width: Math.max(nameLabel.implicitWidth + 26, 120)
            height: Math.round(root.fieldHeight * 0.7)

            Text {
                id: nameLabel
                anchors.centerIn: parent
                text: root.currentUser.length > 0 ? root.currentUser : textConstants.userName
                color: root.currentUser.length > 0 ? root.colOnSurface : root.colOnSurfaceVariant
                opacity: root.currentUser.length > 0 ? 1 : 0.7
                font.family: root.textFont
                font.pixelSize: Math.round(root.fieldHeight * 0.36)
                font.weight: Font.Medium
                font.letterSpacing: 0.4
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                enabled: userModel.count > 1
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.userMenuOpen = !root.userMenuOpen
            }
        }

        // ---- sheet account block ----------------------------------------
        // Ledger's square tile and `local · admin` title, in Stacked's
        // bottom-left position. Square, not round: the round avatar is the
        // one shape this theme does not otherwise use, and the tile has to
        // read as part of the same sheet as the type beside it.
        Item {
            id: sheetAccount
            visible: root.loginSheet
            width: parent.width
            height: sheetTile.height

            readonly property int tile: Math.round(root.height * 0.072)

            Rectangle {
                id: sheetTile
                width: parent.tile
                height: parent.tile
                color: avatarSheetArea.containsMouse || root.userMenuOpen
                    ? Qt.rgba(1, 1, 1, 0.10)
                    : Qt.rgba(0, 0, 0, 0.30)
                border.width: 1
                border.color: Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.35)
                radius: 2
                Behavior on color { ColorAnimation { duration: 140 } }

                Text {
                    anchors.centerIn: parent
                    text: root.currentUser.length > 0
                        ? root.currentUser.substring(0, 1).toUpperCase() : "?"
                    color: root.colOnSurface
                    font.family: root.textFont
                    font.pixelSize: Math.round(parent.parent.tile * 0.40)
                    font.weight: Font.Medium
                }

                MouseArea {
                    id: avatarSheetArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: userModel.count > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (userModel.count > 1)
                            root.userMenuOpen = !root.userMenuOpen;
                        else
                            root.focusPassword();
                    }
                }
            }

            Column {
                anchors.left: sheetTile.right
                anchors.leftMargin: Math.round(sheetAccount.tile * 0.32)
                anchors.verticalCenter: sheetTile.verticalCenter
                spacing: 3

                Text {
                    text: root.currentUser.length > 0 ? root.currentUser : textConstants.userName
                    color: root.colOnSurface
                    font.family: root.textFont
                    font.pixelSize: Math.round(root.height * 0.036)
                    font.weight: Font.Light
                }

                // The account's scope and privilege, set in the same tracked
                // mono as every other micro-label on this screen.
                Text {
                    text: "local · admin"
                    color: root.colOnSurfaceVariant
                    opacity: 0.75
                    font.family: "JetBrainsMono Nerd Font Mono"
                    font.pixelSize: Math.max(9, Math.round(root.height * 0.0135))
                    font.letterSpacing: 2.2
                }
            }
        }

        // ---- the password line ------------------------------------------
        // Not a box: full-width type over a hairline. The hairline has two
        // parts -- a resting line at low opacity, and an accent line that
        // grows from the left when the field has focus (or is in error),
        // which is what makes "this is focused" read without a border.
        Item {
            id: passwordLine
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            // In sheet mode the micro-label sits on its own row above the
            // type, so the item is taller and the label lives inside it. The
            // resting and focus lines stay pinned to its bottom edge, which is
            // what the type then sits on.
            height: root.loginSheet
                ? Math.round(root.fieldHeight * 1.28) : root.fieldHeight

            // The tracked-out mono label every other line on this screen uses.
            Text {
                id: passwordCaption
                visible: root.loginSheet
                anchors.left: parent.left
                anchors.top: parent.top
                text: "password"
                color: root.colOnSurfaceVariant
                opacity: 0.7
                font.family: "JetBrainsMono Nerd Font Mono"
                font.pixelSize: Math.max(9, Math.round(root.height * 0.0135))
                font.letterSpacing: 2.2
            }

            readonly property bool active: passwordField.activeFocus
            readonly property color lineColor: root.statusIsError
                ? root.colError
                : (passwordLine.active ? root.colPrimary : Qt.rgba(root.colOutline.r, root.colOutline.g,
                    root.colOutline.b, 0.40))

            // Resting line.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.26)
            }

            // Focus line, growing from the left. Instant collapse on blur,
            // animated growth on focus.
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                height: root.statusIsError ? 2 : 1.5
                width: passwordLine.active || root.statusIsError ? parent.width : 0
                color: passwordLine.lineColor

                Behavior on color {
                    ColorAnimation { duration: 160 }
                }
                Behavior on width {
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                }
            }

            // Placeholder and the type itself share the same origin: the text
            // starts at the left, the way a line of text should. In sheet mode
            // the tracked-out `password` caption above already names the
            // field, so this steps aside rather than saying it twice.
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -2
                visible: passwordField.text.length === 0 && !root.loginSheet
                text: textConstants.password
                color: root.colOnSurfaceVariant
                opacity: passwordLine.active ? 0.85 : 0.55
                font.family: root.textFont
                font.pixelSize: Math.round(root.fieldHeight * 0.32)
                font.letterSpacing: 0.8

                Behavior on opacity {
                    NumberAnimation { duration: 160 }
                }
            }

            PasswordBox {
                id: passwordField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: root.fieldHeight
                anchors.rightMargin: Math.round(root.fieldHeight * 0.9)
                anchors.bottomMargin: 4
                color: "transparent"
                borderColor: "transparent"
                focusColor: "transparent"
                hoverColor: "transparent"
                radius: 0
                textColor: root.colOnSurface
                font.family: root.textFont
                font.pixelSize: Math.round(root.fieldHeight * 0.32)
                tooltipEnabled: false

                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.doLogin();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape) {
                        passwordField.text = "";
                        root.statusMessage = "";
                        root.statusIsError = false;
                        event.accepted = true;
                    }
                }
            }

            // The commit control. In "sheet" this is a return KEYCAP -- a
            // square outline holding the return glyph, resting hairline and
            // filling with the accent once there is something to submit. The
            // round arrow it replaces was the only circle on the screen; the
            // keycap matches the square account tile beside it. Every other
            // layout keeps the shipped arrow.
            Item {
                id: commitButton
                anchors.right: parent.right
                // Sits ON the field's baseline, not centred in the item. In
                // sheet mode passwordLine is 1.28x taller to make room for the
                // `password` caption, so a verticalCentre offset lifted the
                // keycap clear of the line it belongs to. Anchoring to the
                // bottom edge and nudging up by its own half-height keeps the
                // square's base on the baseline in every mode.
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Math.round(root.fieldHeight * (root.loginSheet ? 0.14 : 0.18))
                width: Math.round(root.fieldHeight * (root.loginSheet ? 0.60 : 0.66))
                height: width
                opacity: passwordField.text.length > 0 ? 1
                    : (passwordLine.active ? 0.75 : 0.35)

                readonly property bool armed: passwordField.text.length > 0

                Behavior on opacity {
                    NumberAnimation { duration: 180 }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: root.loginSheet ? 0 : width / 2
                    color: commitButton.armed && !root.loginSheet
                        ? (commitArea.containsMouse
                            ? Qt.lighter(root.colPrimary, 1.10)
                            : root.colPrimary)
                        : (root.loginSheet && commitButton.armed && commitArea.containsMouse
                            ? Qt.rgba(root.colPrimary.r, root.colPrimary.g, root.colPrimary.b, 0.22)
                            : "transparent")
                    border.width: 1
                    border.color: commitButton.armed
                        ? (root.loginSheet ? root.colPrimary : "transparent")
                        : Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.45)

                    Behavior on color {
                        ColorAnimation { duration: 140 }
                    }
                    Behavior on border.color {
                        ColorAnimation { duration: 140 }
                    }
                }

                Glyph {
                    anchors.centerIn: parent
                    text: root.loginSheet ? "keyboard_return" : "arrow_forward"
                    glyphSize: Math.round(root.fieldHeight * 0.34)
                    color: commitButton.armed && !root.loginSheet
                        ? root.colOnPrimary : root.colOnSurfaceVariant
                }

                MouseArea {
                    id: commitArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.doLogin()
                }
            }
        }

        // ---- status ------------------------------------------------------
        // One line, reserved whether or not it says anything, so a failed
        // login does not shove the password line upward mid-typing.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: statusLabel.implicitHeight + 2

            Text {
                id: statusLabel
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.statusMessage.length > 0
                text: root.statusMessage
                color: root.statusIsError ? root.colError : root.colOnSurfaceVariant
                font.family: root.textFont
                font.pixelSize: Math.round(root.fieldHeight * 0.26)
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                wrapMode: Text.WordWrap
            }
        }
    }

    // ==================================================================
    // Account list -- a floating list under the avatar, only when there is
    // more than one account on this machine.
    // ==================================================================
    Rectangle {
        id: userMenu

        anchors.horizontalCenter: loginColumn.horizontalCenter
        anchors.top: loginColumn.top
        anchors.topMargin: root.avatarSize + 6
        visible: root.userMenuOpen
        width: Math.max(240, userColumn.implicitWidth + 18)
        height: userColumn.implicitHeight + 18
        radius: 18
        color: Qt.rgba(root.colSurfaceContainer.r, root.colSurfaceContainer.g, root.colSurfaceContainer.b, 0.97)
        border.width: 1
        border.color: Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.22)

        Column {
            id: userColumn
            anchors.centerIn: parent
            spacing: 2

            Repeater {
                model: userModel

                // The roles are taken as required properties rather than read
                // off the `model` object: in Qt 6 a delegate that declares any
                // required property no longer gets the legacy `model` context
                // at all, so `model.name` silently resolves to nothing and
                // every row renders blank. These three names are the roles
                // SDDM's own UserModel exposes.
                delegate: Item {
                    required property int index
                    required property string name
                    required property var realName

                    width: Math.max(222, userColumn.implicitWidth)
                    height: 42

                    readonly property bool selected: name === root.currentUser

                    Rectangle {
                        anchors.fill: parent
                        radius: 12
                        color: selected
                            ? Qt.rgba(root.colPrimary.r, root.colPrimary.g, root.colPrimary.b, 0.16)
                            : (rowArea.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent")

                        Behavior on color {
                            ColorAnimation { duration: 120 }
                        }
                    }

                    Text {
                        id: initial
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        horizontalAlignment: Text.AlignHCenter
                        text: name.substring(0, 1).toUpperCase()
                        color: root.colOnSurface
                        font.family: root.textFont
                        font.pixelSize: 15
                        font.weight: Font.Medium
                    }

                    Text {
                        anchors.left: initial.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: (realName && realName.length > 0) ? realName : name
                        color: root.colOnSurface
                        font.family: root.textFont
                        font.pixelSize: 14
                    }

                    Glyph {
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        visible: parent.selected
                        text: "check"
                        glyphSize: 18
                        color: root.colPrimary
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.currentUser = name;
                            root.userMenuOpen = false;
                            root.statusMessage = "";
                            root.statusIsError = false;
                            root.focusPassword();
                        }
                    }
                }
            }
        }
    }

    // ==================================================================
    // Sheet telemetry: boot facts in the bottom corners, set in mono. The
    // kernel row is baked into theme.conf by install-sddm-theme.sh; the rest
    // describe the greeter's own fixed environment, which a greeter cannot
    // query for itself.
    // ==================================================================
    Column {
        id: sheetTelemetryLeft
        visible: root.loginSheet
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 26
        anchors.bottomMargin: 22
        spacing: 3

        Text {
            text: "kernel " + root.kernelVersion + "  OK"
            color: root.colOnSurfaceVariant
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: Math.max(10, Math.round(root.height * 0.0155))
        }
        Text {
            text: "session hyprland  OK"
            color: root.colOnSurfaceVariant
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: Math.max(10, Math.round(root.height * 0.0155))
        }
    }

    // The RIGHT telemetry is lifted clear of the power buttons rather than
    // sharing the bottom-right corner with them. Both used to anchor at
    // rightMargin ~22-26 and bottomMargin ~18-22, so the two rows were drawn
    // on top of each other and neither was readable. The buttons keep the
    // corner; the telemetry sits above them, still right-aligned to the same
    // edge.
    Column {
        id: sheetTelemetryRight
        visible: root.loginSheet
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 26
        // Clear of the power row (its own height plus its margin), and clear
        // of the login column's resting place.
        anchors.bottomMargin: 22 + (sddm.canPowerOff || sddm.canReboot || sddm.canSuspend ? 46 : 0)
        spacing: 3

        Text {
            text: "wm hyprland"
            color: root.colOnSurfaceVariant
            horizontalAlignment: Text.AlignRight
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: Math.max(10, Math.round(root.height * 0.0155))
        }
        Text {
            text: "greeter sddm  OK"
            color: root.colOnSurfaceVariant
            horizontalAlignment: Text.AlignRight
            font.family: "JetBrainsMono Nerd Font Mono"
            font.pixelSize: Math.max(10, Math.round(root.height * 0.0155))
        }
    }

    // ==================================================================
    // The bottom bar: session and keyboard layout on the left, power on the
    // right. Flat, low contrast, no pills -- these are not the point of the
    // screen and should not compete with the password line. In sheet mode the
    // left half belongs to the telemetry, so only the power controls remain.
    // ==================================================================
    Row {
        id: bottomLeft
        visible: !root.loginSheet
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 26
        anchors.bottomMargin: 22
        spacing: 18

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Hyprland"
            color: root.colOnSurfaceVariant
            opacity: 0.75
            font.family: root.textFont
            font.pixelSize: 13
            font.letterSpacing: 0.5
        }

        // Keyboard layout, clickable to move to the next one. Hidden entirely
        // when the greeter reports one layout (nothing to switch to).
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: layoutLabel.implicitWidth
            height: layoutLabel.implicitHeight
            visible: root.layoutText().length > 0 && layoutCount > 1

            readonly property int layoutCount: {
                try {
                    return (typeof keyboard !== "undefined" && keyboard && keyboard.layouts)
                        ? keyboard.layouts.length : 0;
                } catch (e) {
                    return 0;
                }
            }

            Text {
                id: layoutLabel
                anchors.centerIn: parent
                text: root.layoutText()
                color: layoutArea.containsMouse ? root.colOnSurface : root.colOnSurfaceVariant
                opacity: layoutArea.containsMouse ? 1 : 0.75
                font.family: root.textFont
                font.pixelSize: 13
                font.letterSpacing: 0.5

                Behavior on color {
                    ColorAnimation { duration: 120 }
                }
            }

            MouseArea {
                id: layoutArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycleKeyboardLayout()
            }
        }
    }

    Row {
        id: bottomRight
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 22
        anchors.bottomMargin: 18
        spacing: 6

        IconButton {
            id: powerButton
            visible: root.powerActions().length > 0
            glyph: "power_settings_new"
            active: root.powerMenuOpen
            onClicked: root.powerMenuOpen = !root.powerMenuOpen
        }
    }

    // ==================================================================
    // Power menu: one glyph, every action this greeter can perform.
    //
    // It replaces three near-identical glyphs in a row -- suspend, power off,
    // restart -- where the pair either side of the middle one are the two
    // irreversible things on this screen and nothing but a glyph told them
    // apart. The shell's power menu solved the same problem the same way, so
    // this is that card: the actions stacked, named, in the order from
    // harmless to final. Rows the greeter cannot perform are left out rather
    // than drawn dead (SDDM reports canSuspend / canReboot / canPowerOff).
    //
    // A plain child of this item, like the account list above: a greeter has
    // no popup layer to open a window in. The click-away MouseArea declared
    // near the top of the file closes it, which is also why nothing here needs
    // a scrim of its own.
    // ==================================================================
    function powerActions() {
        return [
            { key: "suspend",  icon: "dark_mode",          label: "Suspend",   can: sddm.canSuspend },
            { key: "reboot",   icon: "restart_alt",        label: "Restart",   can: sddm.canReboot },
            { key: "poweroff", icon: "power_settings_new", label: "Power off", can: sddm.canPowerOff }
        ].filter(function (a) { return a.can; });
    }

    function runPowerAction(key) {
        root.powerMenuOpen = false;
        if (key === "suspend")
            sddm.suspend();
        else if (key === "reboot")
            sddm.reboot();
        else if (key === "poweroff")
            sddm.powerOff();
    }

    Rectangle {
        id: powerMenu

        // Hangs off the button's own corner rather than the screen's: the row
        // it belongs to is right-aligned, so the two share an edge.
        anchors.right: bottomRight.right
        anchors.bottom: bottomRight.top
        anchors.bottomMargin: 8
        visible: root.powerMenuOpen
        width: 178
        height: powerColumn.implicitHeight + 12
        radius: 14
        color: Qt.rgba(root.colSurfaceContainer.r, root.colSurfaceContainer.g, root.colSurfaceContainer.b, 0.97)
        border.width: 1
        border.color: Qt.rgba(root.colOutline.r, root.colOutline.g, root.colOutline.b, 0.22)

        // Swallows presses that land on the card's own padding. Without it they
        // fall through to the click-away MouseArea behind and close the menu
        // the user was aiming at.
        MouseArea {
            anchors.fill: parent
        }

        Column {
            id: powerColumn
            anchors.centerIn: parent
            spacing: 2

            Repeater {
                model: root.powerActions()

                delegate: Item {
                    required property var modelData

                    width: 166
                    height: 40

                    Rectangle {
                        anchors.fill: parent
                        radius: 11
                        color: rowArea.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent"

                        Behavior on color {
                            ColorAnimation { duration: 120 }
                        }
                    }

                    Glyph {
                        id: rowGlyph
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.modelData.icon
                        glyphSize: 18
                        color: root.colOnSurfaceVariant
                    }

                    Text {
                        anchors.left: rowGlyph.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: parent.modelData.label
                        color: root.colOnSurface
                        font.family: root.textFont
                        font.pixelSize: 14
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.runPowerAction(parent.modelData.key)
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        // Session pinning: SDDM's own `sessionModel.index` is read-only on
        // this build (assigning throws and -- being the first statement here
        // -- aborted everything after it, including the user prefill below).
        // The remembered session is passed to sddm.login() directly instead;
        // with a single-entry list it is the same row either way.
        //
        // Correct only because the session list holds exactly one working
        // entry. It shipped with two: `hyprland.desktop` and
        // `hyprland-uwsm.desktop`, and the uwsm one can never start anything
        // here -- `uwsm` is not installed and is not even in the package
        // repos, so its `Exec=uwsm ...` resolves to nothing. If lastIndex ever
        // pointed at it, login would fail with no session, no error, just a
        // bounce back to the greeter. The dead entry is removed rather than
        // worked around here: selecting by name instead would mean guessing
        // the model's column order, and a wrong guess breaks the login
        // completely. With one entry, any valid index is the right one.

        // The account: SDDM's remembered one, else the invisible Repeater at
        // the bottom of this file fills it in from the model's first row.
        //
        // Only ever ASSIGNED when lastUser is actually set. It used to assign
        // unconditionally, with `""` as the else branch -- but a Repeater's
        // delegates complete BEFORE the enclosing Component.onCompleted, so
        // on a greeter with no remembered account this line ran second and
        // wiped the name the fallback had just filled in. The account came up
        // blank, which on a single-user machine means the one thing you have
        // to type is the one thing you cannot.
        if (userModel.lastUser)
            root.currentUser = String(userModel.lastUser);

        // The layout, before anything paints, so the arrangement is correct
        // on the very first frame. The values come from theme.conf (baked by
        // install-sddm-theme.sh from layouts/active.js) -- see
        // applyLoginFragment for why a runtime include is not possible.
        root.applyLoginFragment();
        // The fragment list for the HUD dots (before the dots build).
        //
        // The list is read from the directory listing exposed by the greeter
        // -- not available in SDDM, so it is hard-coded to the shipped set and
        // simply ignores names whose file is missing (applyFragmentByName
        // keeps the current arrangement on a failed include).
        //
        // This used to be a second, separate `Component.onCompleted` block of
        // its own higher up in this file. QML permits exactly one per object,
        // so the duplicate made the greeter log
        //     Main.qml:1020:5 Property value set multiple times
        // on every boot and drop the earlier handler entirely. Kept here, in
        // the one handler that exists, so it is set exactly once.
        root.layoutNames = ["sheet", "classic", "corner", "minimal", "glass", "studio", "beacon", "ops"];

        // And the point of this whole file: the password line is already
        // focused, so you can just start typing.
        root.focusPassword();
    }

    // Focus is taken again once the greeter's window is actually up: on
    // load the window may not be active yet, and a forceActiveFocus() that
    // lands too early is silently dropped. Two safety nets, one at 0ms and
    // one after the first paint.
    Timer {
        interval: 60
        repeat: false
        running: true
        onTriggered: root.focusPassword()
    }

    Timer {
        interval: 350
        repeat: false
        running: true
        onTriggered: root.focusPassword()
    }

    // If there is no remembered account, take the first one the model offers.
    // An invisible Repeater is the portable way to read the model's rows: it
    // costs nothing, and only the first delegate that completes can win.
    Repeater {
        model: userModel

        delegate: Item {
            required property string name
            visible: false
            Component.onCompleted: {
                if (root.currentUser.length === 0 && name && name.length > 0)
                    root.currentUser = name;
            }
        }
    }

    // ==================================================================
    // Pieces
    // ==================================================================

    // Material Symbols glyph. Same font, same variable axes as the shell's
    // own icon widget, so the login screen's icons are the desktop's icons.
    component Glyph: Text {
        id: glyph

        property real glyphSize: 22
        property real fill: 0

        color: root.colOnSurfaceVariant
        textFormat: Text.PlainText
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        renderType: Text.NativeRendering
        font.family: root.iconFont
        font.pixelSize: glyphSize
        font.weight: fill > 0.5 ? Font.DemiBold : Font.Normal
        font.variableAxes: {
            "FILL": glyph.fill,
            "opsz": glyph.glyphSize
        }
    }

    // Flat icon button with a round hover tint. Used by the power row, where
    // weight is deliberately low.
    component IconButton: Item {
        id: button

        property string glyph
        property real glyphSize: 20
        // Held down: the button whose menu is open. Same tint as hover, so the
        // open state needs no second visual vocabulary.
        property bool active: false
        signal clicked()

        implicitWidth: 36
        implicitHeight: 36

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: buttonArea.containsMouse || buttonArea.pressed || button.active
                ? Qt.rgba(1, 1, 1, 0.10)
                : "transparent"

            Behavior on color {
                ColorAnimation { duration: 120 }
            }
        }

        Glyph {
            anchors.centerIn: parent
            text: button.glyph
            glyphSize: button.glyphSize
            color: root.colOnSurfaceVariant
        }

        MouseArea {
            id: buttonArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }
}
