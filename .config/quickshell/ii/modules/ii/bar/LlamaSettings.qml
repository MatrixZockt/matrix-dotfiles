import QtQuick
import QtQuick.Layouts
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Everything about how llama-server will be started, in one place.
 *
 * It used to be a column inside the Now Bar popup, and that was the wrong
 * home for it three times over: the popup is 460px tall, seven settings with
 * real controls do not fit in 460px, so the layout spent its life being
 * squeezed (a field too short to read, a spec block under the fold), and the
 * answer -- shrink everything until it fits -- made the one thing you actually
 * come to this tab for (which model, which address) unreadable to make room for
 * settings you edit once.
 *
 * So it is its own surface now. The popup shows the two facts; this shows the
 * controls, at a size you can grab.
 */
Item {
    id: root

    // How tall this wants to be. The window sizes its card to this instead of
    // guessing: a fixed full-height card left a third of the screen empty
    // under the last row, which reads as something still loading.
    readonly property real neededHeight: settingsCol.implicitHeight

// A COMPACT SETTING: a name, the flag, and a box.
//
// The counterpart to ArgRow for the values that are addresses and numbers
// rather than judgement calls. It keeps the one thing ArgRow cannot have --
// you type an IP address into a track -- and it keeps the same rule about
// what the grey means, so "127.0.0.1" in grey still reads as "nobody has
// touched this".
component TextParam: ColumnLayout {
    id: tp
    required property var param
    spacing: 4
    readonly property bool isDefault: String(tp.param.value) === String(tp.param.def)

    RowLayout {
        Layout.fillWidth: true
        spacing: 7
        StyledText {
            text: tp.param.label
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer0
        }
        StyledText {
            text: tp.param.flag
            font.pixelSize: Appearance.font.pixelSize.tiny
            font.family: "JetBrains Mono"
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.45)
        }
        Item { Layout.fillWidth: true }
        StyledText {
            // Say it in words rather than by colour alone: colour is the
            // fast channel and this is the one that survives a screenshot
            // in a terminal.
            visible: tp.isDefault
            text: Translation.tr("default")
            font.pixelSize: Appearance.font.pixelSize.tiny
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.4)
        }
    }

    MaterialTextField {
        id: tpField
        Layout.fillWidth: true
        Layout.preferredHeight: 36
        Layout.minimumHeight: 36
        font.family: "JetBrains Mono"
        font.pixelSize: Appearance.font.pixelSize.normal
        // MaterialTextField wraps by default, which folded an address onto
        // a second line with no height to sit in.
        wrapMode: TextInput.NoWrap
        padding: 8
        selectByMouse: true
        placeholderText: tp.isDefault ? String(tp.param.def) : ""
        validator: tpValidator.item
        onEditingFinished: {
            // An emptied box is not a request to run with "", and for
            // `--host` it would be a broken address rather than a
            // rejected edit. Leave the value be.
            const typed = tpField.text.trim();
            if (typed.length > 0)
                LlamaService.setParam(tp.param.key, typed);
        }
        // `text` is a Binding with a `when`, not a bare binding: typing
        // assigns `text` and would destroy a plain one for good, leaving
        // the box showing its own stale value after the model moved on.
        Binding {
            target: tpField
            property: "text"
            value: tp.isDefault ? "" : String(tp.param.value)
            when: !tpField.activeFocus
        }
    }
    Loader {
        id: tpValidator
        active: tp.param.kind === "int"
        sourceComponent: Component {
            IntValidator {
                bottom: tp.param.min
                top: tp.param.max
            }
        }
    }
}

// ONE BIG SETTING, the way a local-LLM console presents one.
//
// The value is the HEADLINE (19px mono, right-aligned), the track beneath
// it is something you can actually grab, and the flag sits next to the
// label as a small monospace chip rather than as its own column. That is
// the shape LM Studio, Ollama and every hardware-settings sheet converges
// on, and it is the opposite of the table this replaced: seven thin rows of
// 10px text with a 130px decoration at the end of each, which could be read
// but not operated.
//
// THE SCALE IS LOGARITHMIC. Against the raw clamp bounds every real value
// lands in the first tenth of the track -- context is 65536 in a
// 512..1048576 range, which is 6% -- so seven rows all sat at the far left
// saying "you have barely set anything" about values that are most of what
// this machine can hold. On a log scale the same numbers land at 64%, 67%
// and 33%, and the ends still mean the floor and the clamp.
//
// Declared at root scope next to PanelFadeView because an inline component
// is only in scope inside the object that declares it, and these rows are
// built through a Repeater delegate.
component ArgRow: ColumnLayout {
    id: r
    required property var param
    spacing: 2

    readonly property real lo: Math.max(1, r.param.min)
    readonly property real hi: Math.max(r.lo + 1, r.param.max)
    // Where a value sits on the track, 0..1.
    function fracOf(v) {
        const x = Math.max(r.lo, Math.min(r.hi, v));
        return Math.max(0, Math.min(1,
            (Math.log(x) - Math.log(r.lo)) / (Math.log(r.hi) - Math.log(r.lo))));
    }
    // The inverse: an x along the track, back to a value. Without this the
    // slider can only be decoration.
    function valueAt(t) {
        return r.lo * Math.pow(r.hi / r.lo, Math.max(0, Math.min(1, t)));
    }
    // A drag must only ever land on a value worth having: 36864 tokens, not
    // 33127.
    function snap(v) {
        const st = r.param.step || 1;
        return Math.max(r.lo, Math.min(r.hi, Math.round(v / st) * st));
    }
    // Grouped by hand, with a space.
    //
    // `toLocaleString` was the obvious way to write 65 536 and it printed
    // "65.536" on this machine -- the locale the shell starts under uses a
    // full stop as its group separator, so the context window came out
    // looking like a decimal number. A value you cannot read at a glance is
    // worse than a long one, and spaces are the grouping that also survives
    // being copied into a terminal.
    function fmt(v) {
        const s = Math.round(v).toString();
        let out = "";
        for (let i = 0; i < s.length; i++) {
            if (i > 0 && (s.length - i) % 3 === 0)
                out += " ";
            out += s[i];
        }
        return out;
    }
    // The value on screen. While the thumb is moving this is the local
    // figure, NOT the service's -- committing every position of a drag
    // would write the settings file a hundred times per swipe.
    property bool scrubbing: false
    property real scrub: 0
    readonly property real shown: r.scrubbing ? r.snap(r.scrub) : r.param.value
    readonly property real shownFrac: r.fracOf(r.shown)
    readonly property bool isDefault: r.shown === r.param.def

    RowLayout {
        Layout.fillWidth: true
        spacing: 7
        StyledText {
            text: r.param.label
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colOnLayer0
        }
        StyledText {
            text: r.param.flag
            font.pixelSize: Appearance.font.pixelSize.tiny
            font.family: "JetBrains Mono"
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.45)
        }
        Item { Layout.fillWidth: true }
        // The ends of the scale, in the same line as the name. They used to
        // sit on a line of their own under the track, which cost 16px a row
        // and was the difference between the whole card fitting in the
        // popup and not.
        StyledText {
            text: `${r.fmt(r.lo)} – ${r.fmt(r.hi)}`
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.45)
        }
        StyledText {
            text: r.param.key === "ctx" ? "tokens" : (r.param.key === "ngl" ? "layers" : "slots")
            font.pixelSize: Appearance.font.pixelSize.smallest
            color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.45)
        }
        // The headline. Dimmed when it is still the built-in default, so
        // "set by you" and "shipped that way" stay distinguishable at a
        // glance without reading anything.
        StyledText {
            Layout.leftMargin: 10
            text: r.fmt(r.shown)
            font.pixelSize: Appearance.font.pixelSize.larger
            font.family: "JetBrains Mono"
            font.weight: Font.DemiBold
            color: r.isDefault
                ? ColorUtils.transparentize(Appearance.colors.colSubtext, 0.25)
                : Appearance.colors.colPrimary
        }
    }

    // The track. 26px tall so it is a comfortable target, with a 10px bar
    // drawn inside it -- a 6px line is precise and miserable to grab.
    Item {
        id: track
        Layout.fillWidth: true
        Layout.preferredHeight: 24

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 10
            radius: 5
            color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.78)
            Rectangle {
                width: parent.width * r.shownFrac
                height: parent.height
                radius: 5
                color: r.isDefault
                    ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                    : Appearance.colors.colPrimary
            }
            // The default, as a notch standing on the track: you can see
            // both where the value is and where it came from.
            Rectangle {
                x: Math.max(0, Math.min(parent.width - 2, parent.width * r.fracOf(r.param.def) - 1))
                anchors.verticalCenter: parent.verticalCenter
                width: 2
                height: 16
                radius: 1
                color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.25)
            }
        }

        Rectangle {
            x: Math.max(0, Math.min(track.width - width, track.width * r.shownFrac - width / 2))
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            height: 20
            radius: 10
            color: r.isDefault
                ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.55)
                : Appearance.colors.colPrimary
            border.width: 3
            border.color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.9)
            scale: r.scrubbing ? 1.15 : 1
            Behavior on scale {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }
        }

        // Drag, and click-to-jump. Safe to use a MouseArea here even though
        // this card is full of gesture handlers: the panel's own
        // horizontal swipe is driven by touchpad WHEEL events, which a
        // mouse drag does not produce.
        MouseArea {
            id: hit
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            // A press anywhere on the track jumps there; a drag scrubs.
            onPressed: function (m) {
                r.scrubbing = true;
                r.scrub = r.valueAt(m.x / Math.max(1, width));
            }
            onPositionChanged: function (m) {
                if (!r.scrubbing)
                    return;
                r.scrub = r.valueAt(m.x / Math.max(1, width));
            }
            onReleased: {
                if (!r.scrubbing)
                    return;
                r.scrubbing = false;
                LlamaService.setParam(r.param.key, r.snap(r.scrub));
            }
            // Leaving the item mid-drag keeps the grab (the press is what
            // released it), but a cancelled press must still put the value
            // back rather than stranding the thumb off the committed one.
            onExited: {
                if (!pressed)
                    return;
                r.scrubbing = false;
                LlamaService.setParam(r.param.key, r.snap(r.scrub));
            }
            onCanceled: {
                r.scrubbing = false;
            }
        }
    }
}



    // Scrollable because a 1600px-tall screen at 1.5 scale still cannot show
    // seven settings, a switch pair and the resolved command line at once, and
    // the answer to that is a scroll rather than smaller controls.
    StyledFlickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: settingsCol.implicitHeight
        clip: true

        ColumnLayout {
            id: settingsCol
            width: scroll.width
            spacing: 10
    // The arguments it would be started with. This
    // is the SAME list LlamaService passes to
    // llama-server, read back off the service, so
    // it cannot drift from what actually runs.
    Rectangle {
        Layout.fillWidth: true
        // No fillHeight: the card is exactly as
        // tall as its content, and the Flickable
        // above handles anything that does not fit
        // the panel. Claiming the spare space here
        // is what squeezed `argsCol` below its
        // implicit height and pushed the tail rows
        // out of view.
        implicitHeight: argsCol.implicitHeight + 18
        radius: Appearance.rounding.small
        color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.45)
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.85)

        ColumnLayout {
            id: argsCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            // 2, not 4: eleven gaps at 4px was
            // ~22px of the panel's height spent on
            // air, which is the difference between
            // the last argument row being visible
            // when the card opens and not.
            spacing: 2

            // The parameter grid below is three
            // columns, and the two text columns are
            // sized from the DATA rather than from a
            // hand-picked number, so no flag or
            // label can ever be elided away by a
            // model with a longer name ("--flash-
            // attn", "Parallel slots").
            //
            // 0.62em/0.58em are the advance widths
            // these two faces actually use at the
            // tiny size (mono vs proportional);
            // both scale with the accessibility text
            // scale because they read
            // pixelSize.tiny.
            readonly property int flagColWidth: Math.max(
                40,
                Math.ceil(Math.max.apply(null, LlamaService.launchParams.map(function (p) {
                    return p.flag.length * Appearance.font.pixelSize.tiny * 0.62 + 4;
                }))))
            // The label column has to fit the note at
            // the bottom ("Required by this panel")
            // as well as the seven parameter labels,
            // because that note's flags sit in the
            // SAME flag column and have to line up
            // with "--host" and "--port". Sizing it
            // from the parameters alone elided it
            // to "Required by this pa…" -- trading
            // one truncation for another.
            readonly property int labelColWidth: Math.max(
                88,
                Math.ceil(Math.max.apply(null, LlamaService.launchParams.map(function (p) {
                    return p.label.length * Appearance.font.pixelSize.tiny * 0.58 + 8;
                }).concat(
                    Translation.tr("Required by this panel").length * Appearance.font.pixelSize.tiny * 0.58 + 8))))

            RowLayout {
                Layout.fillWidth: true
                spacing: 7
                MaterialSymbol {
                    text: "terminal"
                    iconSize: 14
                    color: Appearance.colors.colPrimary
                }
                StyledText {
                    text: Translation.tr("Launch arguments")
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer0
                }
                Item { Layout.fillWidth: true }
                // Reset is here because the defaults
                // shipped here are deliberately the
                // ones this machine OOMs on (-ngl 99
                // with -c 65536). Without a way back
                // to the built-ins from the panel,
                // "edit the parameters" would be a
                // one-way door.
                //
                // It counts what it would undo. A
                // reset that is sometimes a no-op
                // looks broken; "Reset 2" says
                // exactly how much is overridden and
                // disappears when there is nothing to
                // undo.
                RippleButton {
                    buttonText: LlamaService.overrideCount > 0
                        ? `${Translation.tr("Reset")} ${LlamaService.overrideCount}`
                        : Translation.tr("Reset")
                    implicitHeight: 24
                    // `() => LlamaService.resetParams()`, NOT
                    // `LlamaService.resetParams()`.
                    //
                    // `releaseAction` is a
                    // `property var` that
                    // RippleButton CALLS on click,
                    // so it has to hold a function.
                    // A bare call is evaluated the
                    // moment this button is
                    // constructed -- which fired a
                    // full reset of every parameter
                    // the first time the panel was
                    // built, wiping the saved file
                    // and putting every value back
                    // to its default no matter what
                    // was stored. It looked like the
                    // persistence was broken; the
                    // button was resetting itself on
                    // the way in.
                    releaseAction: () => LlamaService.resetParams()
                }
            }

            // One line that says what the grey
            // numbers in the boxes below MEAN,
            // because "is this value set or is it
            // just the default?" is otherwise a
            // guess, and a wrong guess here means
            // running the server with settings
            // nobody chose.
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Grey is the built-in default · type to change it, and it is kept")
                font.pixelSize: Appearance.font.pixelSize.tiny
                color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.35)
                elide: Text.ElideRight
            }
    // One labelled row per launch parameter, drawn from
            // LlamaService.params -- the SAME array the
            // process is started from, so a row cannot
            // describe a flag that is not passed, and a
            // flag cannot be passed without a row.
    // ── THE THREE THAT DECIDE ANYTHING ──
            //
            // Context, offload and slot count are
            // the only rows here whose VALUE you
            // reason about; the rest are switches
            // and an address. So the first three
            // are not rows in a table, they are
            // settings: a name, the value as the
            // headline, and a track big enough to
            // drag. Everything else below is
            // compact on purpose, because the point
            // of making three of them large is that
            // the other four did not have to be.
            Repeater {
                model: LlamaService.launchParams.filter(function (p) {
                    return p.key === "ctx" || p.key === "ngl" || p.key === "parallel";
                })
                delegate: ArgRow {
                    required property var modelData
                    param: modelData
                    Layout.fillWidth: true
                }
            }

            // ── HOST + PORT, one compact row ──
            //
            // A slider for a port number is a
            // joke, and a full-width setting for
            // "127.0.0.1" would spend as much
            // space as the context window. So these
            // two keep the box and lose the track,
            // side by side.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8
                spacing: 12
                TextParam {
                    Layout.fillWidth: true
                    param: LlamaService.paramDef("host")
                }
                TextParam {
                    Layout.preferredWidth: 132
                    param: LlamaService.paramDef("port")
                }
            }

            // ── THE TWO SWITCHES ──
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8
                spacing: 12
                Repeater {
                    model: LlamaService.launchParams.filter(function (p) {
                        return p.kind === "bool";
                    })
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            StyledText {
                                Layout.fillWidth: true
                                text: modelData.label
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colOnLayer0
                                elide: Text.ElideRight
                            }
                            StyledText {
                                text: modelData.flag
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                font.family: "JetBrains Mono"
                                color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.45)
                            }
                        }
                        StyledSwitch {
                            id: boolSwitch
                            onToggled: LlamaService.setParam(modelData.key, boolSwitch.checked)
                            // Same binding-versus-assignment trap as the
                            // text field: a click writes `checked`, so the
                            // binding is re-armed when the press ends or the
                            // switch desyncs the first time it is touched.
                            Binding {
                                target: boolSwitch
                                property: "checked"
                                value: !!modelData.value
                                when: !boolSwitch.down
                            }
                        }
                    }
                }
            }

            // ── what the panel can only report ─────────────────────────
            //
            // A rule first, so the editable table
            // above is unmistakably a table and
            // this is a different kind of thing.
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 5
                Layout.bottomMargin: 2
                Layout.preferredHeight: 1
                color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.88)
            }

            // Three facts in one two-column grid:
            // a fixed caption on the left, the
            // answer on the right.
            //
            // They used to be a full-width
            // sentence, a bare flag list and a
            // floating box, each with its own
            // indentation -- three kinds of
            // information with nothing in common
            // to read them against. A caption
            // column is what makes a spec sheet
            // instead of a list, and it is the same
            // shape as the Reading tiles in the
            // online pane below.
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 12
                rowSpacing: 7

                // "ALWAYS ON" is the longest caption
                // (9 characters, ~54px at the tiny
                // size); 66 leaves it room to
                // breathe and keeps the value column
                // starting at the same x on every
                // row.
                component Caption: StyledText {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: 66
                    Layout.topMargin: 1
                    font.pixelSize: Appearance.font.pixelSize.tiny
                    font.capitalization: Font.AllUppercase
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }

                Caption { text: Translation.tr("Slots") }
                // The relationship that decides how
                // the server behaves: -c is the
                // TOTAL pool, so more slots means a
                // SMALLER share each.
                //
                // It used to be written out as
                // "65536 ÷ 4 = 16384 tokens each",
                // which is three numbers to read and
                // an equation to do in your head.
                // Drawn, it is just the pool split
                // into as many pieces as there are
                // slots -- and a glance says
                // whether four slots is a sensible
                // thing to ask for on this machine.
                //
                // Capped at 16 blocks: past that
                // they are thinner than the gap
                // between them and the drawing stops
                // meaning anything.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 3
                    Repeater {
                        model: Math.min(16, Math.max(1, LlamaService.argParallel))
                        delegate: Rectangle {
                            required property int index
                            Layout.fillWidth: true
                            Layout.preferredHeight: 14
                            radius: 3
                            color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.82)
                            border.width: 1
                            border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.45)
                            StyledText {
                                anchors.centerIn: parent
                                text: `#${index + 1}`
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.family: "JetBrains Mono"
                                color: Appearance.colors.colPrimary
                            }
                        }
                    }
                    StyledText {
                        text: `${Math.floor(LlamaService.argCtx / Math.max(1, LlamaService.argParallel))} each`
                        font.pixelSize: Appearance.font.pixelSize.tiny
                        font.family: "JetBrains Mono"
                        color: Appearance.colors.colPrimary
                    }
                }

                // Always-on flags, not editable.
                // Turning either off would not give
                // a different server, it would give a
                // server this panel can no longer
                // measure -- so they are shown as
                // fixed rather than offered as
                // switches that silently break it.
                Caption {
                    text: Translation.tr("Always on")
                    visible: LlamaService.fixedArgs.length > 0
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: LlamaService.fixedArgs.length > 0
                    text: LlamaService.fixedArgs.join("  ")
                    font.pixelSize: Appearance.font.pixelSize.tiny
                    font.family: "JetBrains Mono"
                    color: ColorUtils.transparentize(Appearance.colors.colSubtext, 0.5)
                    elide: Text.ElideRight
                }

                // The exact argv, from the same
                // builder the process is handed.
                // Worth showing because the panel
                // is the only place these are
                // editable: without the resolved
                // line there is nothing to copy
                // into a terminal when something
                // refuses to come up.
                Caption { text: Translation.tr("Command") }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: argvText.implicitHeight + 12
                    radius: Appearance.rounding.small
                    color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.5)
                    border.width: 1
                    border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer1, 0.9)
                    StyledText {
                    id: argvText
                    anchors.fill: parent
                    anchors.margins: 6
                    text: LlamaService.argvText()
                    font.pixelSize: Appearance.font.pixelSize.tiny
                    font.family: "JetBrains Mono"
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.WrapAnywhere
                    // The pane scrolls now, so the argv
                    // no longer has to be squeezed
                    // into three lines and elided --
                    // there is somewhere for the rest
                    // of it to go.
                    maximumLineCount: 6
                    elide: Text.ElideRight
                }
            }
            }
            }
        }
        }
    }
}
