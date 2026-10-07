import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
// `FluentIcon` lives here, not in common/widgets. Without this the failure is
// "FluentIcon is not a type" at the first use, not an unresolved import.
import qs.modules.waffle.looks
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
// `IconImage` is Quickshell's own, not Qt's. Without this the first cover-art
// tile fails with "IconImage is not a type".
import Quickshell.Widgets
// `Quickshell.execDetached` for the "open the full music app" button. This is
// NOT implied by `import Quickshell.Widgets` -- each module has to be named.
import Quickshell
// IpcHandler lives in Quickshell.Io, and `import Quickshell` does NOT bring
// it in. Without this the ENTIRE config fails to load, four files up the
// error chain, with "IpcHandler is not a type" pointing at the handler.
import Quickshell.Io

/**
 * The Music tab, rebuilt as option A of the three sidebar previews.
 *
 * ── What this tab is FOR ────────────────────────────────────────────────
 * Three things, in this order of importance: pick a playlist, pick a song,
 * see at a glance which song is sounding. Everything else was cut -- the
 * Audius search panel, the settings sheet, per-track context menus, the
 * per-row duration, the two-pane rail+shelf layout, and the second "hero"
 * that repeated the track the list was already highlighting. The previous
 * 2043-line file spent most of its height on things you have to read a
 * caption to understand; this one is a player.
 *
 * ── The layout, top to bottom ──────────────────────────────────────────
 *   header      icon, "Music", the library's total track count
 *   now playing the card: art, title, playlist, play -- full width, 50px
 *   status bar  |skip|  elapsed  ====  total  |skip|, click or drag to seek
 *   playlist    a rail of pills; the active one is a bone pill
 *   tracks      the selected playlist, one row per song
 *
 * There is no volume row. There was one -- a speaker glyph and a slider --
 * and it sat directly under the player, where it read as the bar belonging to
 * the player above it while being about something else entirely. It is gone.
 * Volume is still on the media keys and in the popped-out player.
 *
 * ── Where the time lives ────────────────────────────────────────────────
 * On the STATUS BAR, at its two ends: the elapsed time at the left, the total
 * at the right, the line between them. It used to be on the card's third line
 * as `1:04 / 2:35`, which put the numbers away from the line they describe
 * and left the bar below the player answering nothing on its own.
 *
 * ── How short the card is, and why ──────────────────────────────────────
 * 50px, down from 56. The third line is gone -- it held a three-bar
 * equaliser and, before that, the time readout -- and the art came down from
 * 40 to 32 with the margins from 8 to 5.
 *
 * The arithmetic that decided it: the track list below runs at 44px a row, so
 * every 44px the card gives up is one more song with its cover art on screen.
 * The equaliser was decoration that cost a whole row, and it was not the only
 * thing in that line: the track rows carry their own playing indicator, so
 * "which one is sounding" is already answered below.
 *
 * 50 is the floor without losing information. The remaining height is two
 * lines of text -- the title and the playlist it came from -- and dropping
 * either of those to save another 18px would be trading something the user
 * asked for (more songs visible) for something they did not (a subtitle).
 *
 * ── The transport marks are the TOP BAR ISLAND'S marks ──────────────────
 * `TransportMark` (modules/common/widgets/TransportMark.qml) is the bar's own
 * island design, and this tab instantiates it three times: skip-previous to
 * the LEFT of the status bar, skip-next to the RIGHT of it, and play/pause
 * inside the card on the right of the track text.
 *
 * The skips flank the BAR, not the card. They were beside the card for a
 * round and that was wrong twice over -- it put the arrows next to the
 * artwork rather than next to the thing that says how long the song runs, and
 * it left the bar under them looking like a caption for the card instead of
 * the control it is.
 *
 * Two earlier attempts got this wrong in ways worth recording:
 *
 *  1. Copying the numbers. NowBarPanel's transport was matched digit for digit
 *     (28/32/28, `colOnLayer0`, spacing 2) and it still looked like a different
 *     design, because NowBarPanel's POPPED-OUT card is not the surface in the
 *     screenshot. The screenshot is the island in NowBar.qml -- a 25px mark, a
 *     1px hover ring, no pad on the skips. Matching the wrong file perfectly
 *     still misses.
 *
 *  2. Drawing the triangle with `ShapePath`. NowBar.qml records that
 *     QtQuick.Shapes does not paint on this machine ("19 path nodes, fill
 *     #e2e2e2, visible true, scale 1.0 ... and NOTHING painted", under either
 *     renderer, at 1x and 8x), so the drawn glyph was never the smooth hinted
 *     mark it was supposed to be. `TransportMark` uses Material Symbols for
 *     every glyph and plain Rectangles for the pause bars -- the same
 *     primitives the island uses, and the ones that are proven to paint.
 * ── Deliberately NOT carried over ──────────────────────────────────────
 * There is no online search and no settings sheet here. Both are reachable
 * from the desktop Music app (`~/.local/bin/ii-music-app`, same daemon, same
 * library) and the bar's popped-out card carries playback control, so nothing
 * is lost -- but the tab is a library browser now, not a music application.
 */

Item {
    id: root
    property real padding: 10
    readonly property color accent: Appearance.colors.colPrimary

    /**
     * Cover art for the LOCAL player, matched by PATH.
     *
     * Searched across every playlist rather than only the selected one: the
     * queue is built from whichever folder was played last, so the folder
     * being browsed is often not the folder the music came from.
     */
    readonly property string currentArt: {
        const path = MusicPlayer.queue?.[MusicPlayer.queuePos]?.filename ?? "";
        if (path === "") return "";
        for (const pl of MusicPlayer.library) {
            for (const t of pl.tracks)
                if (t.path === path) return t.art ?? "";
        }
        return "";
    }

    /**
     * Which playlist the track list is showing.
     *
     * Bound to the persisted selection so the tab comes back where it was,
     * and falls back to the largest playlist rather than the first
     * alphabetically: a 45-track list is a more useful default view than a
     * 13-track one, and the chips are right there to change it.
     */
    readonly property string selectedPlaylist: {
        const want = Persistent.states.music.selectedPlaylist ?? "";
        if (want !== "" && MusicPlayer.library.some(p => p.name === want))
            return want;
        let best = null;
        for (const p of MusicPlayer.library)
            if (best === null || p.tracks.length > best.tracks.length) best = p;
        return best ? best.name : "";
    }

    readonly property var currentPlaylist:
        MusicPlayer.library.find(p => p.name === root.selectedPlaylist) ?? null

    /**
     * The five playlists the rail offers, most recently played first.
     *
     * `Persistent.states.music.recentPlaylists` is written by
     * MusicPlayer.playPlaylist() and already capped at five, so this does
     * not invent a second history -- it renders the one that exists, which
     * is why the order here is "when you last played it" and not
     * alphabetical.
     *
     * Three corrections, all of them cases that are real on this machine:
     *
     *  1. A recorded name that no longer exists in the library is DROPPED.
     *     A playlist deleted from ~/Music/Spotify would otherwise leave a
     *     chip that plays nothing.
     *  2. The SELECTED playlist is always in the list even when it is not
     *     recent. It has to be: the track list directly below shows that
     *     playlist, so a selection with no chip would mean the list below
     *     and the rail above disagreed about what was open.
     *  3. With no history at all (a fresh profile) the rail falls back to
     *     the five BIGGEST playlists rather than going blank, and to the
     *     whole library when there are fewer than five.
     */
    readonly property var recentList: {
        const byName = {};
        for (const p of MusicPlayer.library) byName[p.name] = p;
        const out = [];
        for (const n of (Persistent.states.music.recentPlaylists ?? [])) {
            if (byName[n] !== undefined && !out.includes(byName[n]))
                out.push(byName[n]);
            if (out.length === 5) break;
        }
        if (out.length === 0) {
            // No history yet: the largest playlists are the most useful
            // thing to offer, and 45 tracks beats 13 as a first view.
            const sorted = MusicPlayer.library.slice().sort(
                (a, b) => b.tracks.length - a.tracks.length);
            for (const p of sorted) {
                out.push(p);
                if (out.length === 5) break;
            }
        }
        if (root.selectedPlaylist !== "" && !out.some(p => p.name === root.selectedPlaylist)) {
            const sel = byName[root.selectedPlaylist];
            if (sel !== undefined) {
                out.unshift(sel);
                // Five is a hard cap, not a target. Five recents plus a
                // selection that is none of them would otherwise be SIX
                // chips, which is the one number the rail is not allowed to
                // reach -- so the OLDEST recent falls off instead.
                out.length = Math.min(out.length, 5);
            }
        }
        return out;
    }

    /** The queue position of the currently playing track, or -1. */
    readonly property int playingIndex: {
        const path = MusicPlayer.queue?.[MusicPlayer.queuePos]?.filename ?? "";
        if (path === "" || !root.currentPlaylist) return -1;
        return root.currentPlaylist.tracks.findIndex(t => t.path === path);
    }

    // ── Search: the library, across every playlist ──────────────────────
    //
    // The query searches the WHOLE library, not the selected playlist. That
    // is the same rule currentArt already uses, and for the same reason: the
    // thing you are looking for is often in a different folder from the one
    // you happen to be browsing.
    property string query: ""
    readonly property bool searching: query.trim().length > 0

    readonly property var results: {
        const q = root.query.trim().toLowerCase();
        if (q === "") return [];
        const out = [];
        for (const pl of MusicPlayer.library) {
            for (const t of pl.tracks) {
                // Title, artist and the folder name all count, so "breakcore"
                // finds a song called Breakcore AND every track inside the
                // Breakcore playlist.
                if (t.title.toLowerCase().includes(q)
                    || (t.artist ?? "").toLowerCase().includes(q)
                    || pl.name.toLowerCase().includes(q))
                    out.push({ title: t.title, artist: t.artist ?? "", art: t.art ?? "", path: t.path, from: pl.name });
            }
        }
        return out;
    }

    /**
     * Everything the query matched, LOCAL first then the online catalogue.
     *
     * One list rather than two sections: the thing the user asked for is a
     * song, not a source, and a local hit for "Illusion" and an online one
     * are interchangeable to the person reading the list. `local` is the only
     * thing the row needs to know to decide what clicking it means.
     *
     * Online hits are capped: the catalogue returns far more than a sidebar
     * can show, and a list of 400 rows makes the local hits -- the ones that
     * are already on the disk and play instantly -- scroll off the top.
     */
    readonly property var allResults: {
        const local = root.results.map(r => Object.assign({}, r, {
            local: true,
            // the row's second line: who made it, and where it already lives
            sub: r.from ?? "",
        }));
        const online = (OnlineMusic.results ?? []).slice(0, 400).map(t =>
            Object.assign({}, t, {
                local: false,
                art: t.artUrl ?? "",
                path: "",
                from: "",
                sub: "Audius",
                stream: t,
                // Kept per row so the list can answer "is this one already on
                // the disk?" without a second lookup at click time.
                saved: OnlineMusic.savedPath(t),
            }));
        // A "load more" row at the end, as part of the model rather than a
        // ListView footer: a sentinel renders through exactly one delegate,
        // and StyledListView's base type is not something to depend on here.
        if (OnlineMusic.hasMore && online.length > 0)
            online.push({ more: true });
        return local.concat(online);
    }

    /** One line under the field saying what the search is doing. */
    readonly property string searchStatus: {
        // Template literals, not qsTr(...).arg(): String.arg() is a known
        // source of load warnings in this shell, and there is no reason to
        // reach for it here.
        const local = root.results.length;
        const online = root.allResults.length - local;
        if (OnlineMusic.searching) return qsTr("Searching online…");
        if (OnlineMusic.lastError !== "") return qsTr("Online search failed");
        if (local === 0 && online === 0) return qsTr("No matches");
        const parts = [`${local} in your library`];
        if (online > 0) parts.push(`${online} online`);
        if (OnlineMusic.hasMore) parts.push("more available");
        return parts.join(` · `);
    }

    /** Playlists holding `path` already, so a row can say "already in". */
    function playlistsWith(path) {
        return MusicPlayer.library.filter(p => p.tracks.some(t => t.path === path)).map(p => p.name);
    }

    // The add flow: pick a row -> choose a playlist here.
    property string pickerPath: ""
    // An ONLINE track being filed, if that is what was picked. A playlist is
    // a folder and an online track is not a file yet, so "add to playlist"
    // for one of these means "download it into that playlist" -- the same
    // call with a destination instead of without.
    property var pickerTrack: null
    property string pickerTitle: ""
    readonly property bool pickerOpen: pickerPath !== "" || pickerTrack !== null
    property string newPlaylistName: ""
    property bool newPlaylistShown: false

    function closeSearch() {
        root.query = "";
        root.pickerPath = "";
        root.pickerTrack = null;
        root.newPlaylistName = "";
        root.newPlaylistShown = false;
        onlineDebounce.stop();
        OnlineMusic.clear();
    }

    function fmtTime(s) {
        const t = Math.max(0, Math.floor(s ?? 0));
        const m = Math.floor(t / 60);
        return `${m}:${(t % 60) < 10 ? "0" : ""}${t % 60}`;
    }


    /**
     * The section rule the bar's card uses: a small caps label, then a
     * hairline that runs to the edge of the card. The label is bounded and
     * elided rather than given a fixed width, so a long playlist name
     * shrinks the rule instead of pushing it off the card.
     */
    component SectionRule: Item {
        id: rule
        property string label: ""
        implicitHeight: 18
        implicitWidth: 200

        StyledText {
            id: caption
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: rule.label
            font.pixelSize: Appearance.font.pixelSize.smaller
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.4
            color: Appearance.colors.colSubtext
            opacity: 0.7
            width: Math.min(implicitWidth, rule.width * 0.62)
            elide: Text.ElideRight
        }
        Rectangle {
            anchors.left: caption.right
            anchors.leftMargin: 8
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: Appearance.colors.colLayer2
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: 10

        // ── Header ───────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            FluentIcon {
                implicitSize: 18
                icon: "music-note-2"
                // Monochrome with an explicit colour: the multi-colour build
                // of this glyph is solid black, which is a black blob on a
                // dark panel next to a bright title.
                monochrome: true
                color: Appearance.colors.colOnLayer1
            }
            StyledText {
                Layout.fillWidth: true
                text: "Music"
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnLayer1
            }
            StyledText {
                text: `${MusicPlayer.totalTracks} tracks`
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
                opacity: 0.75
            }
            // Open the FULL music app.
            //
            // This tab shows five playlists, so it is a browser, not the
            // whole library -- the other playlists, the online search and
            // the settings all live in `ii-music-app`, which drives the same
            // mpv daemon and the same library, so nothing here is a second
            // source of truth. The button sits on the RIGHT of the header
            // because that is the one row with slack: the title is short and
            // the count is short, and this rail is where a control belongs
            // rather than stealing a row from the track list.
            RippleButton {
                id: openAppButton
                objectName: "openAppButton"
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Layout.leftMargin: 4
                Layout.alignment: Qt.AlignVCenter
                buttonRadius: Appearance.rounding.full
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer2Hover
                colRipple: Appearance.colors.colLayer2Active
                downAction: () => Quickshell.execDetached([
                    `${Quickshell.env("HOME")}/.local/bin/ii-music-app`
                ])
                FluentIcon {
                    anchors.centerIn: parent
                    implicitSize: 15
                    icon: "arrow-up-left"
                    monochrome: true
                    color: openAppButton.hovered
                        ? Appearance.colors.colOnLayer2
                        : Appearance.colors.colSubtext
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }
                StyledToolTip {
                    text: "Open the full music app"
                }
            }
        }

        // ── Now playing ──────────────────────────────────────────────────
        //
        // The card is the SONG -- art, title, where it came from, play. It is
        // full width, on its own.
        //
        // The BAR is the row below it: `|skip|  status bar  |skip|`. The two
        // arrows sit to the left and the right of the status bar itself, which
        // is what "put the song changing buttons left and right of the bar"
        // says. Two earlier revisions got this wrong in ways worth recording:
        //
        //   1. The skips were placed beside the CARD, so they flanked the
        //      artwork rather than the bar that shows the song's length.
        //   2. The bar was a 4px hairline with no handle and no numbers, which
        //      is a rule, not a control -- it read as no bar at all.
        //
        // Both are fixed below: the skips moved down a row, and the bar is now
        // `SeekStatusBar`, with times at its ends and a handle under the
        // pointer.
        //
        // The marks are `TransportMark`, the bar island's own design in a
        // shared file: hinted font glyphs at em 20 positioned from their
        // measured ink, a 25px box, a faint pad on play only, and a 1px accent
        // ring as the single hover tell.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Rectangle {
                objectName: "nowPlayingCard"
                Layout.fillWidth: true
                // The card is deliberately SHORT. It used to be 56px, and the
                // 19px it gave back is worth more than the equaliser it paid
                // for: the track list below runs at 44px a row, so every 44px
                // the card gives up is a whole extra song with its cover art
                // on screen. The player is a header on this screen, not the
                // subject of it.
                implicitHeight: npRow.implicitHeight + 10
                radius: Appearance.rounding.normal
                color: Appearance.colors.colLayer2

                RowLayout {
                    id: npRow
                    anchors.fill: parent
                    // 6px of margin and 9px of gap, down from 8 and 10. The
                    // skips flank the status bar below, so the card no longer
                    // has to breathe for them.
                    anchors.margins: 5
                    spacing: 8

                    Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        Layout.alignment: Qt.AlignVCenter
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer3
                        clip: true
                        IconImage {
                            anchors.fill: parent
                            anchors.margins: 2
                            // file:// is load-bearing: a bare absolute path
                            // resolves against qrc: and fails silently.
                            source: root.currentArt !== "" ? "file://" + root.currentArt : ""
                            asynchronous: true
                            visible: root.currentArt !== ""
                        }
                        FluentIcon {
                            anchors.centerIn: parent
                            implicitSize: 16
                            visible: root.currentArt === ""
                            icon: MusicPlayer.hasTrack ? "music-note-2-filled" : "music-note-2"
                            monochrome: true
                            color: root.accent
                        }
                    }

                    // Identity: a title and where it came from. Two lines,
                    // because the third is what the height came from.
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 0

                        StyledText {
                            Layout.fillWidth: true
                            text: MusicPlayer.hasTrack ? MusicPlayer.trackTitle : "Nothing playing"
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: Font.Medium
                            color: Appearance.colors.colOnLayer2
                        }
                        // The PLAYLIST, not the artist, on the second line: the
                        // track list below names the artist on every row, and the
                        // playlist is the one thing on this screen that answers
                        // "why is the next song that one".
                        StyledText {
                            Layout.fillWidth: true
                            text: root.playingIndex >= 0 ? root.selectedPlaylist
                                : (MusicPlayer.hasTrack ? "from the queue" : "Pick a playlist below")
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                        }
                    }

                    // Play/pause, on the right of the track text inside
                    // the card, where the top bar's island has it.
                    TransportMark {
                        objectName: "playMark"
                        Layout.alignment: Qt.AlignVCenter
                        glyph: MusicPlayer.hasTrack && !MusicPlayer.paused ? "pause" : "play_arrow"
                        onTriggered: {
                            MusicPlayer.ensureDaemon();
                            MusicPlayer.playPause();
                        }
                    }

                }
            }
        }

        // ── The status bar, with the song changing buttons either side ────
        //
        // THIS is the bar: `|◀|  ▓▓▓▓░░░░░  |▶|` with the elapsed time at its
        // left end and the total at its right, and the whole surface taking a
        // click or a drag to seek.
        //
        // The two skips are its neighbours, one on each side, because that is
        // what "put the song changing buttons left and right of the bar" asks
        // for. They flank the BAR, not the card above and not a row of their
        // own -- both of which were tried and both of which read as the
        // buttons belonging to something else.
        //
        // The skips are `TransportMark`, the top bar island's own mark: a
        // bare hinted glyph at em 20 in a 25px box, dimmed to 0.4 while there
        // is nothing to skip through, and a 1px accent ring as its single
        // hover tell.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            TransportMark {
                objectName: "skipPrevMark"
                Layout.alignment: Qt.AlignVCenter
                glyph: "skip_previous"
                enabled: MusicPlayer.hasTrack
                onTriggered: MusicPlayer.previous()
            }

            SeekStatusBar {
                objectName: "seekStatusBar"
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                active: MusicPlayer.hasTrack
                position: MusicPlayer.position
                duration: MusicPlayer.duration
                onSeekRequested: f => MusicPlayer.seekFraction(f)
            }

            TransportMark {
                objectName: "skipNextMark"
                Layout.alignment: Qt.AlignVCenter
                glyph: "skip_next"
                enabled: MusicPlayer.hasTrack
                onTriggered: MusicPlayer.next()
            }
        }

        // ── Playlist rail ────────────────────────────────────────────────
        //
        // A pill per playlist, the active one a bone pill. A rail rather than
        // a dropdown or a shelf: five names, all of them wanted, all of them
        // one tap from the track list below.
        // ── Search field ────────────────────────────────────────────────
        //
        // One new row, and nothing above it moved. It is here rather than in
        // the header because the header's one row of slack is spoken for by
        // the track count and the open-app button, and a 28px control cannot
        // hold a caret.
        Item {
            id: searchRow
            Layout.fillWidth: true
            Layout.preferredHeight: 32

            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer1
                border.width: 1
                border.color: searchInput.activeFocus ? root.accent : Appearance.colors.colLayer2

                FluentIcon {
                    id: searchGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    implicitSize: 14
                    icon: "search"
                    monochrome: true
                    color: Appearance.colors.colSubtext
                    opacity: 0.7
                }

                // A plain TextField rather than the shell's StyledTextInput:
                // every visible property is styled from Appearance here, so
                // nothing is inherited accidentally, and it is the one widget
                // in this file with no dependency on a component whose own
                // defaults might not match this panel.
                TextField {
                    id: searchInput
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: 6
                    anchors.right: clearSearch.left
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    height: parent.height
                    padding: 0
                    verticalAlignment: TextInput.AlignVCenter
                    background: Item { }
                    color: Appearance.colors.colOnLayer1
                    // ONE placeholder, from the control itself. This used to set
                    // `placeholderText` AND overlay a child `Text` with a
                    // different string, so both drew in the same place and the
                    // field showed two labels on top of each other. The
                    // placeholder is the control's job; a manual overlay only
                    // ever fights it, and it cannot even pick up font changes
                    // made to the field afterwards.
                    //
                    // A plain string, not qsTr(...).arg(...): String.arg() is a
                    // documented source of load warnings elsewhere in this
                    // shell (NowBarPanel logs "String.arg(): Invalid
                    // arguments").
                    placeholderText: qsTr("Search every playlist")
                    placeholderTextColor: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.normal
                    selectByMouse: true
                    onAccepted: {
                        root.query = text;
                        // Enter means "I am done typing": search now rather
                        // than waiting out the debounce.
                        onlineDebounce.stop();
                        if (text.trim().length >= 2) OnlineMusic.search(text.trim());
                        else OnlineMusic.clear();
                    }
                    Keys.onEscapePressed: root.closeSearch()
                    // The field stays put for the whole search now. It used to
                    // hide itself the moment a query existed, which left the
                    // results floating over the tab with nothing to edit,
                    // clear or go back from -- and put the typed text on
                    // screen twice, once here and once in the overlay's own
                    // heading. It is the one control the whole search hangs
                    // off, so it is always visible.
                    onTextChanged: {
                        root.query = text;
                        onlineDebounce.restart();
                    }
                }

                RippleButton {
                    id: clearSearch
                    objectName: "searchClear"
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    Layout.preferredWidth: 24
                    width: 24
                    height: 24
                    buttonRadius: Appearance.rounding.full
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer2Hover
                    colRipple: Appearance.colors.colLayer2Active
                    visible: searchInput.text.length > 0
                    downAction: () => {
                        searchInput.text = "";
                        root.query = "";
                        onlineDebounce.stop();
                        OnlineMusic.clear();
                    }
                    FluentIcon {
                        anchors.centerIn: parent
                        implicitSize: 12
                        icon: "x"
                        monochrome: true
                        color: Appearance.colors.colSubtext
                    }
                }
            }
        }

        // "Recent playlists", not "Playlists": the rail is the five most
        // recently played, and a heading that says "Playlists" over a list
        // that is missing three of them is simply wrong. The full set is one
        // button away in the header.
        SectionRule {
            objectName: "playlistRule"
            Layout.fillWidth: true
            label: "Recent playlists"
            // Hidden, not covered: a ColumnLayout skips an invisible child,
            // so the playlist rail, the track list and the rules all give
            // their height to the results below them instead of being drawn
            // over. That is the whole fix for the see-through mess -- there is
            // no overlay left to be transparent.
            visible: !root.searching
        }
        Item {
            id: playlistRail
            objectName: "playlistRail"
            visible: !root.searching
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            clip: true
            Flickable {
                id: playlistFlick
                anchors.fill: parent
                contentWidth: playlistRow.implicitWidth
                contentHeight: height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick

                Row {
                    id: playlistRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 7

                    Repeater {
                        model: root.recentList
                        RippleButton {
                            id: chip
                            required property var modelData
                            readonly property bool active: modelData.name === root.selectedPlaylist

                            implicitWidth: Math.min(
                                200,
                                Math.max(62, nameText.implicitWidth + 22))
                            implicitHeight: 26
                            buttonRadius: Appearance.rounding.full
                            colBackground: active
                                ? Appearance.colors.colPrimary
                                : "transparent"
                            colBackgroundHover: active
                                ? Appearance.colors.colPrimary
                                : Appearance.colors.colLayer2Hover
                            colRipple: Appearance.colors.colLayer2Active
                            downAction: () => {
                                Persistent.states.music.selectedPlaylist = modelData.name;
                            }
                            StyledText {
                                id: nameText
                                anchors.centerIn: parent
                                text: modelData.name
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                font.weight: chip.active ? Font.DemiBold : Font.Normal
                                color: chip.active
                                    ? Appearance.colors.colOnPrimary
                                    : Appearance.colors.colOnLayer1
                                elide: Text.ElideRight
                                width: Math.min(implicitWidth, 178)
                            }
                        }
                    }
                }
            }
            // A SIBLING of the Flickable, not a child of it. ScrollEdgeFade
            // does `anchors.fill: target`, and an item cannot anchor to its
            // own parent -- declared inside the Flickable it warns on every
            // load with "Cannot anchor to an item that isn't a parent or
            // sibling" and never fades anything. `vertical: false` is how it
            // is told to fade the X ends; there is no `horizontal` property,
            // and assigning one fails the whole configuration.
            ScrollEdgeFade { target: playlistFlick; vertical: false }
        }

        // ── Tracks ───────────────────────────────────────────────────────
        SectionRule {
            objectName: "tracksRule"
            Layout.fillWidth: true
            visible: !root.searching
            label: root.currentPlaylist
                ? `${root.currentPlaylist.name} · ${root.currentPlaylist.tracks.length}`
                : "Tracks"
        }

        StyledListView {
            id: trackList
            objectName: "trackList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: -4
            visible: !root.searching
            clip: true
            spacing: 2
            model: root.currentPlaylist ? root.currentPlaylist.tracks : []

            // A hairline scroll bar, always on: this list moves by gesture,
            // so a bar that only exists under the pointer is the only cue for
            // where you are in 45 tracks. A 6px LANE with a 2px THUMB inside
            // it -- a line, not a second column.
            scrollBarAlwaysOn: true
            scrollBarWidth: 6
            scrollBarHandleWidth: 2

            ScrollEdgeFade { target: trackList; vertical: true }

            delegate: RippleButton {
                id: trackRow
                required property var modelData
                required property int index
                readonly property bool isPlaying: index === root.playingIndex

                width: ListView.view.width
                implicitHeight: 44
                buttonRadius: Appearance.rounding.small
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer2Hover
                colRipple: Appearance.colors.colLayer2Active
                downAction: () => {
                    MusicPlayer.ensureDaemon();
                    // By (playlist, index within it). The row index counts the
                    // list being shown, which is the playlist's own list, so
                    // they agree -- but going through playPlaylist rather than
                    // queueing keeps the stop-then-append ordering that makes
                    // the index land on the row that was clicked.
                    MusicPlayer.playPlaylist(root.selectedPlaylist, index);
                }

                // The bone bar on the leading edge: the one thing on this
                // screen that answers "which row below is sounding".
                Rectangle {
                    anchors.left: parent.left
                    anchors.leftMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2.5
                    height: 22
                    radius: 1.25
                    color: root.accent
                    visible: trackRow.isPlaying
                }

                // A Rectangle, not a bare IconImage: the corner radius has to
                // be clipped, and IconImage draws its own square.
                Rectangle {
                    id: rowArt
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32
                    height: 32
                    radius: Appearance.rounding.verysmall
                    color: Appearance.colors.colLayer3
                    clip: true
                    IconImage {
                        anchors.fill: parent
                        anchors.margins: 1
                        source: trackRow.modelData.art
                            ? "file://" + trackRow.modelData.art : ""
                        asynchronous: true
                    }
                    FluentIcon {
                        anchors.centerIn: parent
                        implicitSize: 15
                        visible: (trackRow.modelData.art ?? "") === ""
                        icon: "music-note-2"
                        monochrome: true
                        color: Appearance.colors.colSubtext
                        opacity: 0.6
                    }
                }

                ColumnLayout {
                    anchors.left: rowArt.right
                    anchors.leftMargin: 10
                    anchors.right: playMark.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    StyledText {
                        Layout.fillWidth: true
                        text: trackRow.modelData.title
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: trackRow.isPlaying ? Font.DemiBold : Font.Normal
                        color: trackRow.isPlaying
                            ? Appearance.colors.colOnLayer2
                            : Appearance.colors.colOnLayer1
                    }
                }

                // The three bars again, on the row that is sounding. Frozen
                // when paused, same as the hero's.
                Item {
                    id: playMark
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: 15
                    height: 13
                    visible: trackRow.isPlaying

                    readonly property bool moving: MusicPlayer.hasTrack && !MusicPlayer.paused
                    function band(i) {
                        const p = AudioVisualizer.points;
                        if (!p || p.length < 3) return 0.4;
                        const v = p[Math.floor(i * p.length / 3)] ?? 0;
                        return 0.35 + 0.65 * Math.pow(Math.min(1, v / 700), 0.7);
                    }
                    Repeater {
                        model: 3
                        Rectangle {
                            required property int index
                            readonly property real h: parent.moving
                                ? (4 + parent.band(index) * 9) : 5
                            width: 2.5
                            height: h
                            radius: 1.25
                            x: index * 5
                            y: (parent.height - height) / 2
                            color: root.accent
                            Behavior on height {
                                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }
            }
        }

        // An empty library is a state, not a crash: say so, and say why.
        Item {
            objectName: "libraryEmpty"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: trackList.count === 0 && !root.searching
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                FluentIcon {
                    Layout.alignment: Qt.AlignHCenter
                    implicitSize: 26
                    icon: "music-note-2"
                    monochrome: true
                    color: Appearance.colors.colSubtext
                    opacity: 0.5
                }
                StyledText {
                    text: MusicPlayer.scanning ? "Scanning…" : "No songs found"
                    font.pixelSize: Appearance.font.pixelSize.normal
                    color: Appearance.colors.colSubtext
                    Layout.alignment: Qt.AlignHCenter
                }
                StyledText {
                    text: "Drop MP3s into ~/Music/Spotify/<playlist>/"
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                    opacity: 0.6
                    Layout.alignment: Qt.AlignHCenter
                }
            }
        }
        // (No close here on purpose: the search-results block below is this
        // layout's LAST child. Its closing brace used to sit above it, which
        // evicted searchArea from the ColumnLayout entirely -- as a bare child
        // of the root Item its Layout.fill* were no-ops, it had no size, and
        // the results list clipped itself to nothing while the status line
        // still painted: "counts show, rows don't".)

        // ── Search results ─────────────────────────────────────────────
        //
        // IN PLACE, not over the top. This used to be a full-tab overlay: a
        // sibling Item, anchored over the whole panel, with its own heading
        // repeating the query. Two things went wrong with that and both are
        // fixed by not doing it any more:
        //
        //  1. The overlay was an Item with no background, so the header, the
        //     now-playing card and the playlist rail drew straight through
        //     it -- and with the search field hidden as well, the query
        //     appeared twice, once here and once over the top.
        //  2. Covering the player is wrong on its own terms. What is playing
        //     is still playing, and a search that hides the transport hides
        //     the one thing you need to fix when the result is bad.
        //
        // So the browser is `visible: !root.searching` instead. A ColumnLayout
        // skips an invisible child, which means the rail, the rules and the
        // track list collapse and hand their height to this block -- the
        // music view genuinely gives way to the searched-for music, and the
        // field, the player and the transport stay exactly where they were.
        Item {
            id: searchArea
            objectName: "searchArea"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.searching

            ColumnLayout {
                anchors.fill: parent
                spacing: 10

                SectionRule {
                    objectName: "searchRule"
                    Layout.fillWidth: true
                    label: root.searchStatus
                }

                StyledListView {
                    id: searchList
                    objectName: "searchList"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    // Local matches first, then what the online catalogue
                    // found: one list, because one list is what "search" means
                    // when you do not already know where a song lives.
                    model: root.allResults
                    scrollBarAlwaysOn: true
                    scrollBarWidth: 6
                    scrollBarHandleWidth: 2

                    delegate: RippleButton {
                        id: resultRow
                        required property var modelData

                        // A sentinel row asking for the next page, not a track.
                        readonly property bool isMore: resultRow.modelData?.more === true
                        readonly property bool local: resultRow.modelData?.local === true
                        // True while THIS row is the one being downloaded.
                        readonly property bool busy: !resultRow.isMore
                            && !resultRow.local
                            && OnlineMusic.downloadingId
                                === (resultRow.modelData?.stream?.id ?? "")
                        // Saved to the disk already this session.
                        readonly property bool saved:
                            !resultRow.isMore && (resultRow.modelData?.saved ?? "") !== ""
                        // The artist allows downloads on some rows and not
                        // others; `access.download` is their decision, not ours.
                        readonly property bool canSave: resultRow.isMore
                            || resultRow.local
                            || (resultRow.modelData?.stream?.downloadable ?? false)

                        width: ListView.view.width
                        implicitHeight: 44
                        buttonRadius: Appearance.rounding.small
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer2Hover
                        colRipple: Appearance.colors.colLayer2Active
                        // The row PLAYS; the button FILES. Two different
                        // verbs, so the row cannot also be the add target --
                        // clicking a song to listen would silently put it in
                        // a playlist as well.
                        downAction: () => {
                            if (resultRow.isMore) return;
                            if (!resultRow.local) {
                                OnlineMusic.playNow(resultRow.modelData.stream);
                                return;
                            }
                            MusicPlayer.ensureDaemon();
                            MusicPlayer.cmd(["loadfile",
                                             resultRow.modelData.path, "replace"]);
                        }

                        Rectangle {
                            id: resultArt
                            visible: !resultRow.isMore
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 32
                            height: 32
                            radius: Appearance.rounding.verysmall
                            color: Appearance.colors.colLayer3
                            clip: true
                            IconImage {
                                anchors.fill: parent
                                anchors.margins: 1
                                // Local art is an extracted file, online art
                                // is an https URL -- the only difference is
                                // the file:// prefix, so one source
                                // expression covers both and neither kind of
                                // row needs its own art widget.
                                source: resultRow.modelData.local
                                    ? (resultRow.modelData.art
                                        ? "file://" + resultRow.modelData.art : "")
                                    : (resultRow.modelData.art ?? "")
                                asynchronous: true
                            }
                            FluentIcon {
                                anchors.centerIn: parent
                                implicitSize: 15
                                visible: (resultRow.modelData.art ?? "") === ""
                                icon: "music-note-2"
                                monochrome: true
                                color: Appearance.colors.colSubtext
                                opacity: 0.6
                            }
                        }

                        ColumnLayout {
                            visible: !resultRow.isMore
                            anchors.left: resultArt.right
                            anchors.leftMargin: 10
                            anchors.right: saveBtn.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            StyledText {
                                Layout.fillWidth: true
                                text: resultRow.modelData.title
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.normal
                                color: Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                Layout.fillWidth: true
                                // For a local hit this is "artist · playlist",
                                // which is what tells you where it already
                                // lives. For an online hit it is
                                // "artist · Audius", which is what tells you
                                // it is not on the disk yet.
                                text: [resultRow.modelData.artist,
                                       resultRow.modelData.sub]
                                    .filter(s => s && s.length > 0).join(" · ")
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                            }
                        }

                        // The load-more sentinel, rendered by the same
                        // delegate so the list stays one model.
                        RippleButton {
                            objectName: "loadMore"
                            visible: resultRow.isMore
                            anchors.fill: parent
                            buttonRadius: Appearance.rounding.small
                            colBackground: "transparent"
                            colBackgroundHover: Appearance.colors.colLayer2Hover
                            colRipple: Appearance.colors.colLayer2Active
                            downAction: () => OnlineMusic.loadMore()
                            StyledText {
                                anchors.centerIn: parent
                                text: OnlineMusic.searching ? "Loading…" : "Load more results"
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colPrimary
                            }
                        }

                        // Save for later: download to the disk with no
                        // playlist involved. Only online rows need it -- a
                        // local track is already offline by definition -- and
                        // only when the artist allows downloads.
                        RippleButton {
                            id: saveBtn
                            objectName: "saveOffline"
                            visible: !resultRow.isMore && !resultRow.local
                            anchors.right: addBtn.left
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26
                            height: 24
                            buttonRadius: 12
                            colBackground: resultRow.saved
                                ? "transparent" : Appearance.colors.colLayer2
                            colBackgroundHover: resultRow.saved
                                ? "transparent" : Appearance.colors.colLayer3
                            colRipple: Appearance.colors.colLayer2Active
                            enabled: !resultRow.busy && !resultRow.saved
                                && resultRow.canSave
                            downAction: () => {
                                OnlineMusic.download(resultRow.modelData.stream);
                            }
                            StyledText {
                                anchors.centerIn: parent
                                visible: resultRow.busy
                                text: "…"
                                font.pixelSize: Appearance.font.pixelSize.normal
                                color: Appearance.colors.colSubtext
                            }
                            StyledToolTip {
                                text: resultRow.saved
                                    ? qsTr("Saved offline")
                                    : (!resultRow.canSave
                                        ? qsTr("The artist does not allow downloads")
                                        : qsTr("Save offline, outside any playlist"))
                            }
                            FluentIcon {
                                anchors.centerIn: parent
                                implicitSize: 13
                                visible: !resultRow.busy
                                icon: resultRow.saved ? "checkmark" : "arrow-sync"
                                monochrome: true
                                color: resultRow.saved
                                    ? Appearance.colors.colPrimary
                                    : (resultRow.canSave
                                        ? Appearance.colors.colOnLayer1
                                        : Appearance.colors.colSubtext)
                                opacity: resultRow.canSave || resultRow.saved ? 1 : 0.5
                            }
                        }

                        // Add to a playlist. For a local track that files the
                        // file; for an online one it downloads straight into
                        // the chosen playlist, which is the same save with a
                        // destination instead of without.
                        RippleButton {
                            id: addBtn
                            objectName: "addToPlaylist"
                            visible: !resultRow.isMore
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26
                            height: 24
                            buttonRadius: 12
                            colBackground: Appearance.colors.colLayer2
                            colBackgroundHover: Appearance.colors.colLayer3
                            colRipple: Appearance.colors.colLayer2Active
                            downAction: () => {
                                root.pickerTitle = resultRow.modelData.title;
                                root.newPlaylistName = "";
                                root.newPlaylistShown = false;
                                if (resultRow.local) {
                                    root.pickerPath = resultRow.modelData.path;
                                    root.pickerTrack = null;
                                } else {
                                    root.pickerPath = "";
                                    root.pickerTrack = resultRow.modelData.stream;
                                }
                            }
                            FluentIcon {
                                anchors.centerIn: parent
                                implicitSize: 13
                                icon: "add"
                                monochrome: true
                                color: Appearance.colors.colOnLayer1
                            }
                        }
                    }
                }

                // Nothing at all: an empty list with no explanation reads as
                // a broken search, so say what happened and what to do.
                Item {
                    objectName: "searchEmpty"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: searchList.count === 0 && !OnlineMusic.searching
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        StyledText {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Nothing found")
                            font.pixelSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.alignment: Qt.AlignHCenter
                            text: OnlineMusic.lastError !== ""
                                ? qsTr("Online search failed")
                                : qsTr("Your library and the online catalogue both came up empty")
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colSubtext
                            opacity: 0.8
                        }
                    }
                }
            }

            // ── Playlist picker ───────────────────────────────────────────
            //
            // Sits on top of the results rather than replacing them, so the row
            // being filed is still visible behind it.
            Item {
                id: picker
                anchors.fill: parent
                visible: root.pickerOpen
                enabled: root.pickerOpen

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.pickerPath = ""
                }
                Rectangle {
                    anchors.fill: parent
                    color: Appearance.colors.colLayer0
                    opacity: 0.55
                }

                Rectangle {
                    id: pickerCard
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 28, 400)
                    implicitHeight: pickerCol.implicitHeight + 24
                    radius: Appearance.rounding.normal ?? 12
                    color: Appearance.colors.colLayer1
                    border.width: 1
                    border.color: Appearance.colors.colLayer2

                    ColumnLayout {
                        id: pickerCol
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 4

                        RowLayout {
                            Layout.fillWidth: true
                            StyledText {
                                Layout.fillWidth: true
                                text: qsTr("Add to playlist")
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: Font.DemiBold
                                color: Appearance.colors.colOnLayer1
                            }
                            StyledText {
                                text: root.pickerTitle
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colSubtext
                                elide: Text.ElideRight
                                Layout.maximumWidth: 180
                            }
                        }

                        Repeater {
                            model: MusicPlayer.library
                            delegate: RippleButton {
                                id: playlistOption
                                required property var modelData
                                readonly property bool already: root.pickerPath !== ""
                                && root.playlistsWith(root.pickerPath).includes(modelData.name)

                                Layout.fillWidth: true
                                Layout.preferredHeight: 34
                                buttonRadius: Appearance.rounding.small
                                // A playlist it is already in is shown, not hidden:
                                // silently dropping options is how you end up not
                                // knowing which folder a track ended up in.
                                colBackground: playlistOption.already ? "transparent" : Appearance.colors.colLayer2
                                colBackgroundHover: playlistOption.already ? "transparent" : Appearance.colors.colLayer3
                                colRipple: Appearance.colors.colLayer2Active
                                enabled: !playlistOption.already
                            downAction: () => {
                                // One picker, two jobs: a local track is a
                                // file that gets filed, an online track is a
                                // URL that gets downloaded INTO the chosen
                                // playlist (which also creates it if it is
                                // new, since the download makes the folder).
                                if (root.pickerTrack !== null)
                                    OnlineMusic.saveTo(root.pickerTrack, playlistOption.modelData.name);
                                else
                                    MusicPlayer.addToPlaylist(root.pickerPath, playlistOption.modelData.name);
                                root.pickerPath = "";
                                root.pickerTrack = null;
                            }

                                StyledText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: playlistOption.modelData.name
                                    font.pixelSize: Appearance.font.pixelSize.normal
                                    color: playlistOption.already ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer1
                                }
                                StyledText {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: playlistOption.already ? "✓ in" : `${playlistOption.modelData.tracks.length} tracks`
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: playlistOption.already ? root.accent : Appearance.colors.colSubtext
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            color: Appearance.colors.colLayer2
                        }

                        // New playlist: a text field that only exists once asked
                        // for, so the picker does not open with a live input
                        // stealing the keyboard from the list behind it.
                        TextField {
                            id: newNameField
                            Layout.fillWidth: true
                            Layout.preferredHeight: 34
                            visible: root.newPlaylistShown
                            padding: 8
                            color: Appearance.colors.colOnLayer1
                            font.pixelSize: Appearance.font.pixelSize.normal
                            placeholderText: qsTr("Playlist name")
                            placeholderTextColor: Appearance.colors.colSubtext
                            selectByMouse: true
                            background: Rectangle {
                                radius: Appearance.rounding.small
                                color: Appearance.colors.colLayer2
                                border.width: newNameField.activeFocus ? 1 : 0
                                border.color: root.accent
                            }
                        onAccepted: {
                            const n = text.trim();
                            if (n === "") return;
                            MusicPlayer.createPlaylist(n);
                            // The folder exists only after the next rescan, so
                            // the save waits for it rather than racing it.
                            addPending.name = n;
                            addPending.path = root.pickerPath;
                            addPending.track = root.pickerTrack;
                            addPending.restart();
                            root.newPlaylistShown = false;
                            root.newPlaylistName = "";
                            root.pickerPath = "";
                            root.pickerTrack = null;
                        }
                        }

                        RippleButton {
                            id: newPlaylistButton
                            Layout.fillWidth: true
                            Layout.preferredHeight: 34
                            buttonRadius: Appearance.rounding.small
                            colBackground: root.newPlaylistShown ? "transparent" : Appearance.colors.colLayer2
                            colBackgroundHover: root.newPlaylistShown ? "transparent" : Appearance.colors.colLayer3
                            colRipple: Appearance.colors.colLayer2Active
                            downAction: () => { root.newPlaylistShown = !root.newPlaylistShown; if (root.newPlaylistShown) newNameField.forceActiveFocus(); }

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.newPlaylistShown ? "Cancel" : qsTr("+  New playlist")
                                font.pixelSize: Appearance.font.pixelSize.normal
                                font.weight: root.newPlaylistShown ? Font.Normal : Font.DemiBold
                                color: root.newPlaylistShown ? Appearance.colors.colSubtext : root.accent
                            }
                        }
                    }
                }
            }
        }
    } // ← closes the main ColumnLayout; searchArea above is its last child

    // ── IPC ───────────────────────────────────────────────────────────────────
    //
    // The tab's search state, readable and drivable without a mouse.
    //
    // `state()` exists for the same reason `appSearchService state()` does:
    // "did the search switch the view, or just paint over it?" is a question
    // about which widgets are visible, and visibility is exactly what a
    // screenshot is bad at judging and a one-line report is exact at. It is
    // also the honest way to check the online half -- whether the debounce
    // fired and how many hits came back -- without typing into a layer-shell
    // surface that synthetic key events cannot reach.
    IpcHandler {
        target: "musicTab"

        // Drive the search the way the field does, so the debounce, the
        // local filter and the online request all run the same code path a
        // keystroke would.
        function search(q: string): string {
            // Sets the state directly AND the field, rather than only the
            // field: a script asking for a search should get the search even
            // if the widget's signal path is not what carried it, and the
            // return value says exactly what each of the two ended up as.
            const t = String(q ?? "");
            root.query = t;
            searchInput.text = t;
            onlineDebounce.restart();
            searchInput.forceActiveFocus();
            return `arg="${t}" field="${searchInput.text}" query="${root.query}"`;
        }

        function close(): void { root.closeSearch(); }

        // Trivial on purpose: if this answers and state() does not, the fault
        // is in state(); if neither answers, the handler is not being
        // dispatched at all and the IPC target is the thing to look at.
        function ping(): string { return `pong total=${MusicPlayer.totalTracks}`; }

        function state(): string {
            // try/catch on purpose: a diagnostic that dies quietly is worse
            // than useless, because "empty output" and "the state is fine"
            // look identical from a script.
            try {
                const local = root.results.length;
                const online = root.allResults.length - local;
                return `query="${root.query}" searching=${root.searching}`
                    + ` local=${local} online=${online}`
                    + ` onlineBusy=${OnlineMusic.searching}`
                    + ` onlineQuery="${OnlineMusic.query}"`
                    + ` area=${searchArea.visible}`
                    + ` field=${searchRow.visible}`
                    + ` rail=${playlistRail.visible}`
                    + ` tracks=${trackList.visible}`
                    + ` areaW=${Math.round(searchArea.width)} areaH=${Math.round(searchArea.height)}`
                    + ` listW=${Math.round(searchList.width)} listH=${Math.round(searchList.height)}`
                    + ` listCount=${searchList.count}`;
            } catch (e) {
                return `ERR ${e}`;
            }
        }
    }

    // The online search is DEBOUNCED, and the delay is not decoration: one
    // request per keystroke would fire six searches for a six-letter word,
    // and Audius rate-limits by app_name, so the surplus is what eventually
    // makes the search fail for everyone. 450ms is long enough to skip the
    // rest of a word and short enough that Enter feels instant -- and Enter
    // skips the wait entirely.
    Timer {
        id: onlineDebounce
        interval: 450
        onTriggered: {
            const q = searchInput.text.trim();
            // OnlineMusic.search() ignores anything under two characters, so
            // asking it to is just a wasted round trip.
            if (q.length < 2) OnlineMusic.clear();
            else OnlineMusic.search(q);
        }
    }

    // Create-then-add needs the folder to exist first, so the add runs one
    // rescan later rather than in the same tick.
    Timer {
        id: addPending
        interval: 700
        property string name: ""
        property string path: ""
        // An online track saved into a brand-new playlist: the download is
        // what makes the folder, so this branch does not need the rescan at
        // all -- but it goes through the same wait so "new playlist" behaves
        // identically for local and online rows.
        property var track: null
        onTriggered: {
            if (name === "") return;
            if (track !== null) OnlineMusic.saveTo(track, name);
            else if (path !== "") MusicPlayer.addToPlaylist(path, name);
            track = null;
            path = "";
        }
    }
}
