pragma Singleton
pragma ComponentBehavior: Bound

// From https://git.outfoxxed.me/outfoxxed/nixnew
// It does not have a license, but the author is okay with redistribution.

import QtQml.Models
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.services
import qs.modules.common
import qs.modules.common.functions

/**
 * A service that provides easy access to the active Mpris player.
 */
Singleton {
	id: root;
	property list<MprisPlayer> players: Mpris.players.values.filter(player => isRealPlayer(player));
	property MprisPlayer trackedPlayer: null;
	property MprisPlayer activePlayer: trackedPlayer ?? Mpris.players.values[0] ?? null;

	// ── The player the top bar KEEPS showing ─────────────────────────────
	//
	// `activePlayer` above answers "which bus is first on the list", which is
	// the right answer for a live readout and the wrong one for the island.
	// The moment playback pauses, that expression falls back to whatever bus
	// happens to be next, and the island swapped to a browser's stale track
	// or went blank -- so pausing music meant losing the song you were about
	// to resume, which is the one moment the name is worth keeping on screen.
	//
	// The rule is deliberately narrow, because "sticky" is easy to overdo:
	// a player is handed over ONLY when some other player is actually making
	// sound. Not when a bus appears, not when the list reorders, not when a
	// title changes. A paused local track therefore survives a browser
	// starting and stopping, a bus being added, anything -- and the moment the
	// browser really plays something, the island follows it.
	// playerctld is a MIRROR of whichever bus is active, not a source of its
	// own: it reports the same identity and answers the same verbs. Counting it
	// as a player meant every "stop everything" paused the same thing twice --
	// the mirror answered after the real one and the second pause undid the
	// first -- so it is excluded everywhere a real source is meant.
	function isProxyBus(player) {
		return String(player?.dbusName ?? "").startsWith("org.mpris.MediaPlayer2.playerctld")
	}

	readonly property var playingPlayers:
		Mpris.players.values.filter(p => p.isPlaying === true && !root.isProxyBus(p))

	// The last player that was heard, and so the one to fall back on.
	property MprisPlayer stickyPlayer: null

	// ── Every player that has been HEARD this session, most recent first ──
	//
	// `stickyPlayer` answers "what was playing last", which is the right first
	// answer for the three-finger tap and useless the moment that player is
	// gone: a YouTube tab that is closed takes its bus with it, and the tap had
	// nothing left to ask. The user's rule for that case is "play from whatever
	// else I played before", and this is that list. A player whose bus has
	// since disappeared is null here (QML nulls references to destroyed
	// objects) and is skipped by `candidates()` below rather than toggled into
	// nothing.
	property var playHistory: []

	function rememberPlayed(player) {
		if (!player) return;
		const rest = root.playHistory.filter(p => p !== null && p !== undefined && p !== player);
		rest.unshift(player);
		// Eight is far more history than a single afternoon produces and it is
		// not persisted: this is "what I have played since I logged in", not a
		// database.
		root.playHistory = rest.slice(0, 8);
	}

	// The app that is AUDIBLY playing right now wins; everything else is a
	// fallback for when nothing is (then the song you paused stays on screen,
	// which is the one case the old sticky behaviour got right).
	//
	// When the audible app publishes no player -- a game, Discord -- this is
	// null on purpose: the bar then shows that app's name instead of a stale
	// song, which is what "switch to the other outputs" means.
	readonly property MprisPlayer shownPlayer: {
		if (root.soundAppName !== "")
			return root.soundAppPlayer
		return root.playingPlayers.length > 0
			? root.playingPlayers[root.playingPlayers.length - 1]
			: (root.stickyPlayer ?? root.activePlayer)
	}

	// Adopt whoever is sounding, as soon as they are sounding.
	//
	// `playingPlayers` is a filtered array, so it is REASSIGNED -- a new array
	// every time -- on every play, pause and bus change. An assigned-handler
	// therefore sees all of them without this file having to know which
	// signal the MPRIS map happens to emit for a given build of Quickshell,
	// which is the part that was never safe to assume.
	//
	// The "not empty" half is what makes this an adoption rather than a
	// release: on the pause there is nothing left to adopt, so `stickyPlayer`
	// is left exactly where it was, which is the entire behaviour being asked
	// for.
	onPlayingPlayersChanged: {
		const heard = root.playingPlayers.length > 0
			? root.playingPlayers[root.playingPlayers.length - 1]
			: undefined;
		if (heard !== undefined) {
			root.stickyPlayer = heard;
			root.rememberPlayed(heard);
		}
	}

	// Seeded with this shell's own player where there is one, so the island
	// opens on the music you left rather than on whatever bus the daemon
	// happened to publish first. `activePlayer` is still the fallback for a
	// session that genuinely has no history.
	Component.onCompleted: {
		const mine = Mpris.players.values.find(
			p => String(p.dbusName ?? "").startsWith("org.mpris.MediaPlayer2.iiMusic"));
		if (mine !== undefined)
			root.stickyPlayer = mine;
	}
	signal trackChanged(reverse: bool);

	property bool __reverse: false;

	property var activeTrack;

	readonly property bool hasActivePlasmaIntegration: Mpris.players.values.some(
		p => p.dbusName?.startsWith('org.mpris.MediaPlayer2.plasma-browser-integration')
	)
	function isRealPlayer(player) {
        if (!Config.options.media.filterDuplicatePlayers) {
            return true;
        }
        return (
            // Remove native browser buses only if plasma-browser-integration is actually active on D-Bus
            !(hasActivePlasmaIntegration && player.dbusName.startsWith('org.mpris.MediaPlayer2.firefox')) && !(hasActivePlasmaIntegration && player.dbusName.startsWith('org.mpris.MediaPlayer2.chromium')) &&
            // playerctld just copies other buses and we don't need duplicates
            !player.dbusName?.startsWith('org.mpris.MediaPlayer2.playerctld') &&
            // Non-instance mpd bus
            !(player.dbusName?.endsWith('.mpd') && !player.dbusName.endsWith('MediaPlayer2.mpd')));
    }

	// Original stuff from fox below
	Instantiator {
		model: Mpris.players;

		Connections {
			required property MprisPlayer modelData;
			target: modelData;

			Component.onCompleted: {
				if (root.trackedPlayer == null || modelData.isPlaying) {
					root.trackedPlayer = modelData;
				}
			}

			Component.onDestruction: {
				if (root.trackedPlayer == null || !root.trackedPlayer.isPlaying) {
					for (const player of Mpris.players.values) {
						if (player.playbackState.isPlaying) {
							root.trackedPlayer = player;
							break;
						}
					}

					if (trackedPlayer == null && Mpris.players.values.length != 0) {
						trackedPlayer = Mpris.players.values[0];
					}
				}
			}

			function onPlaybackStateChanged() {
				if (root.trackedPlayer !== modelData) root.trackedPlayer = modelData;
			}
		}
	}

	Connections {
		target: activePlayer

		function onPostTrackChanged() {
			root.updateTrack();
		}

		function onTrackArtUrlChanged() {
			// console.log("arturl:", activePlayer.trackArtUrl)
			// root.updateTrack();
			if (root.activePlayer.uniqueId == root.activeTrack.uniqueId && root.activePlayer.trackArtUrl != root.activeTrack.artUrl) {
				// cantata likes to send cover updates *BEFORE* updating the track info.
				// as such, art url changes shouldn't be able to break the reverse animation
				const r = root.__reverse;
				root.updateTrack();
				root.__reverse = r;

			}
		}
	}

	onActivePlayerChanged: this.updateTrack();

	// ── What is actually playing ─────────────────────────────────────────
	//
	// A browser publishes exactly ONE name: `xesam:title`, and what it holds is
	// whatever the page's Media Session API decided to say. For a site with no
	// media metadata of its own that is a placeholder -- a sentence about the
	// mechanism ("A site is playing media") instead of the name of the thing
	// playing -- and there is no second title on the bus to go and ask for.
	//
	// The name does exist, one layer up: a page playing a video gives its
	// window the page's title, and for a video that IS the video's name. So a
	// placeholder is resolved from the window instead.
	//
	// Only the FOCUSED window, and only when it really is the app publishing
	// the player (matched by class). Both restrictions are deliberate. An
	// unrelated focused window would put the wrong name on the track outright;
	// and an unfocused browser window's title is whatever tab it happens to be
	// on, which is a confident lie rather than an admission of ignorance. When
	// neither is available the honest "unknown" is returned -- a placeholder is
	// never passed through on purpose.
	//
	// Hyprland is read through the window-data service rather than through
	// Quickshell's own Hyprland singleton, which on this build has neither
	// `focusedWindow` nor a populated `activeToplevel` -- both were measured,
	// and both fail silently, which is the worst way for a name to fail.
	function mediaTitle(player) {
		const raw = String(player?.trackTitle ?? "").trim();
		const cleaned = StringUtils.cleanMusicTitle(raw);
		if (cleaned !== "" && !isPlaceholderTitle(cleaned))
			return cleaned;
		const fromWindow = windowTitleFor(player);
		if (fromWindow !== "")
			return fromWindow;
		// A real title that merely looked like a placeholder is still better
		// than nothing; a genuine placeholder is not.
		return isPlaceholderTitle(cleaned) ? "" : cleaned;
	}

	function isPlaceholderTitle(title) {
		const t = String(title).toLowerCase();
		// The browser describing its own mechanism rather than the media.
		if (t.includes("playing media"))
			return true;
		// ...and the other shapes of the same nothing.
		return /^(unknown|untitled|media|audio|video|web media|no media|unknown title)$/.test(t);
	}

	function windowTitleFor(player) {
		const win = HyprlandData.activeWindow;
		const title = String(win?.title ?? "").trim();
		const cls = String(win?.class ?? "").trim();
		if (title === "" || cls === "" || cls === "null")
			return "";
		if (!appMatches(player, cls))
			return "";
		return stripWindowDecorations(title, cls);
	}

	function appMatches(player, cls) {
		const app = cls.toLowerCase();
		// The bus name is the most reliable handle there is:
		// org.mpris.MediaPlayer2.brave.instance2414939 -> "brave".
		const bus = String(player?.dbus?.name ?? "");
		const marker = "org.mpris.MediaPlayer2.";
		const tail = bus.indexOf(marker) >= 0
			? bus.slice(bus.indexOf(marker) + marker.length).split(".")[0].toLowerCase()
			: "";
		const identity = String(player?.identity ?? "").toLowerCase();
		// Both directions of containment, because the two sides disagree about
		// what to call the same program: window class "brave-browser", identity
		// "brave", bus tail "brave".
		for (const t of [tail, identity]) {
			// Two letters match far too much to be evidence of anything.
			if (t.length < 3)
				continue;
			if (app === t || app.includes(t) || t.includes(app))
				return true;
		}
		return false;
	}

	function stripWindowDecorations(title, cls) {
		const app = String(cls).toLowerCase().trim();
		// Every name the same program might wear in a title: the window class
		// is "brave-browser", the title bar says "Brave".
		const names = [app];
		const short = app
			.replace(/[-_](browser|bin|stable|dev|nightly|esr|desktop)$/, "")
			.replace(/\.desktop$/, "");
		if (short !== "" && short !== app) {
			names.push(short);
			names.push(short.charAt(0).toUpperCase() + short.slice(1));
		}
		// Sites that append their own name to the page title, which is not the
		// video's name and reads as noise in a one-line label.
		const sites = ["youtube", "soundcloud", "bandcamp", "vimeo",
			"dailymotion", "twitch"];
		let out = String(title);
		// Bounded: a title that legitimately contains " - " is only ever
		// stripped when the piece after it is known to be a suffix, so this
		// cannot eat a real title.
		for (let i = 0; i < 3; i++) {
			const m = out.match(/^(.*?)\s*[-–—|]\s*([^–—|]+?)\s*$/);
			if (m === null)
				break;
			const tailText = m[2].toLowerCase();
			if (!names.includes(tailText) && !sites.includes(tailText))
				break;
			out = m[1].trim();
		}
		return out;
	}

	function updateTrack() {
		//console.log(`update: ${this.activePlayer?.trackTitle ?? ""} : ${this.activePlayer?.trackArtists}`)
		this.activeTrack = {
			uniqueId: this.activePlayer?.uniqueId ?? 0,
			artUrl: this.activePlayer?.trackArtUrl ?? "",
			title: this.mediaTitle(this.activePlayer) || Translation.tr("Unknown Title"),
			artist: this.activePlayer?.trackArtist || Translation.tr("Unknown Artist"),
			album: this.activePlayer?.trackAlbum || Translation.tr("Unknown Album"),
		};

		this.trackChanged(__reverse);
		this.__reverse = false;
	}

	property bool isPlaying: this.activePlayer && this.activePlayer.isPlaying;
	property bool canTogglePlaying: this.activePlayer?.canTogglePlaying ?? false;
	function togglePlaying() {
		if (this.canTogglePlaying) this.activePlayer.togglePlaying();
	}

	// ═════════════════════════════════════════════════════════════════════
	// WHO THE THREE-FINGER TAP IS ALLOWED TO PLAY (2026-11-05)
	// ═════════════════════════════════════════════════════════════════════
	// The tap used to ask `activePlayer` and nothing else. Close the YouTube
	// tab and `activePlayer` is either gone or a bus with no media behind it,
	// so the gesture did nothing at all -- on a machine whose media is very
	// often exactly one browser tab. The rule asked for is a chain:
	//
	//   1. what was heard last (stickyPlayer / shownPlayer / activePlayer),
	//   2. anything else the user has played this session, most recent first,
	//      which is the "another YouTube video that is open" case,
	//   3. any remaining live player,
	//   4. and only after all of that: the music saved on this PC, which the
	//      caller reaches for because the local player needs a track loaded
	//      first (see shell.qml's tap handler).
	//
	// The local iiMusic bus is deliberately EXCLUDED from this list: it is the
	// fallback, and toggling a paused mpv with an empty playlist does nothing.

	readonly property string localBus: "org.mpris.MediaPlayer2.iiMusic"

	function candidates() {
		const live = Mpris.players.values.filter(p => String(p.dbusName ?? "") !== root.localBus
			&& !root.isProxyBus(p));
		const ordered = [];
		const push = p => {
			if (!p || ordered.indexOf(p) >= 0) return;
			// Still on the bus is the liveness test that matters. A closed tab
			// -- and a daemon that restarted -- are both "not in this list".
			if (live.indexOf(p) < 0) return;
			ordered.push(p);
		};
		push(root.stickyPlayer);
		push(root.shownPlayer);
		push(root.activePlayer);
		for (const p of root.playHistory) push(p);
		for (const p of live) push(p);
		return ordered;
	}

	// Whether a player has anything to start at all. `canPlay` is the player's
	// own answer; browsers publish `canTogglePlaying` while paused instead. A
	// bus that claims neither, and has no title either, is the shape a closed
	// tab leaves behind -- it must be skipped, not toggled into silence.
	function canPlay(player) {
		if (player.canPlay === true || player.canGoNext === true) return true;
		if (player.canTogglePlaying === true) return String(player.trackTitle ?? "").trim() !== "";
		return false;
	}

	// Toggle the best candidate and say who answered, "" when nobody could.
	function toggleBest() {
		for (const player of root.candidates()) {
			if (!root.canPlay(player)) continue;
			try {
				player.togglePlaying();
				return String(player.identity ?? player.dbusName ?? "player");
			} catch (error) {
				// A destroyed QObject throws here; the next candidate in the
				// chain is still worth trying.
				console.warn(`[Mpris] ${player?.identity ?? "a player"} would not play: ${error}`);
			}
		}
		return "";
	}

	// ═════════════════════════════════════════════════════════════════════
	// THE THREE-FINGER TAP IS A SILENCE SWITCH (2026-11-05, requested)
	// ═════════════════════════════════════════════════════════════════════
	// The tap used to toggle ONE player -- whatever the island was following --
	// so with a video in a browser AND music loaded it silenced one of them and
	// left the other talking. The requested behaviour is a switch:
	//
	//   tap while anything sounds .... silence EVERY source
	//   tap again ................... bring back the one heard last, and no more
	//
	// "The one heard last" is `stickyPlayer`, which is exactly what the island
	// was following when the sound stopped; the bus order says nothing about
	// who the user was listening to. It is kept at the END of `tapSilenced` so
	// the resume is simply "the newest entry that is still alive" -- a closed
	// tab leaves null behind and the next one in line answers instead.
	// ── What is REALLY making sound ──────────────────────────────────────
	//
	// Neither MPRIS nor PipeWire's stream list can answer it. Brave's bus
	// follows ONE tab and that tab can be a stale, paused one while a different
	// tab is audibly playing -- measured: the switch reported only "local
	// music" and left the playing video running -- and a paused stream stays in
	// PipeWire's list, so "has a stream" is not "is sounding" either. The
	// server's own Corked/Mute flags on each sink-input are the honest answer,
	// so they are read from pactl and cached a few times a second.
	property var sinkInputs: []
	// When that list was read. A sweep must not act twice on one reading: after
	// a browser `stop` the flags change, and stopping again on stale data leaves
	// the session Stopped -- which no MPRIS client can start again (measured:
	// canPlay false, "No player could handle this command"), so the second tap
	// would have nothing to bring back.
	property double sinkInputsAt: 0

	function absorbSinkInputs(text) {
		try {
			root.sinkInputs = JSON.parse(text ?? "[]") ?? []
		} catch (error) {
			root.sinkInputs = []
		}
		root.sinkInputsAt = Date.now()
	}

	// Sink-inputs of one app ("" for all of them) that are not corked and not
	// muted: the streams that are actually being heard right now.
	// A notification is not an output. `media.role` is the only property that
	// says so outright -- libcanberra and the GTK/macOS-style notifiers send
	// "event", some send "notification" -- so those never count as something
	// being heard, whatever app they came from. A client that sets no role at
	// all is caught by the duration gate in noteHeardApps instead.
	function isAlertStream(stream) {
		const role = String(stream?.properties?.["media.role"] ?? "").toLowerCase()
		return /notification|event|alert|alarm|phone/.test(role)
	}

	function audibleStreams(appKey) {
		const key = String(appKey ?? "").toLowerCase()
		return (root.sinkInputs ?? []).filter(s => {
			if (s?.corked === true || s?.mute === true) return false
			if (root.isAlertStream(s)) return false
			if (key === "") return true
			const props = s?.properties ?? {}
			return String(props["application.name"] ?? "").toLowerCase().includes(key)
				|| String(props["application.id"] ?? "").toLowerCase().includes(key)
		})
	}

	readonly property int audibleCount: root.audibleStreams("").length

	// ── Which OUTPUT is making sound, app by app ──────────────────────────
	//
	// The bar followed `stickyPlayer`, which is right while something is
	// playing and wrong the moment it stops: pausing the local music left the
	// island on the paused song while a game, Discord or a video was audibly
	// playing -- the exact thing the user keeps having to ask for. The audio
	// server is the only honest source, and it names the APP, which is also
	// what "the other outputs" means: a game and Discord have no MPRIS bus at
	// all, so a player-only answer can never point at them.
	//
	// `heardApps` keeps only apps that are audible RIGHT NOW, in the order they
	// started making sound, so the newest one is last. An app that goes quiet
	// leaves the list, and if it comes back it goes to the end again -- which
	// is what makes "I switched to the other video" move the bar.
	property var heardApps: []

	// ── A beep is not an output either ────────────────────────────────────
	//
	// A toast that plays a chime used to take the island: its stream is
	// audible, it has an application name, so the bar showed the media panel
	// (with whatever music was sticky) every time any app notified. Electron
	// and Discord-style notifiers set no `media.role`, so isAlertStream()
	// cannot see them -- duration is the only honest test left. An app has to
	// be heard for minAudibleMs before it may take the bar; a notification
	// chime is 200-900 ms, while music, video and games never are. Kept as
	// low as that allows: this is also the delay before the bar appears when
	// music starts, so 2000 was audible as lag and 1200 is not.
	readonly property int minAudibleMs: 1200
	// app name -> when it was first heard in the current stretch of sound.
	property var streamFirstHeard: ({})

	// ── A BROWSER CHIME IS NOT A BROWSER PLAYING ──────────────────────────
	//
	// The duration gate below is enough for a toast chime from most apps, but a
	// Chromium-based browser keeps its audio stream open after the sound stops:
	// the chime is over, the stream is still uncorked, and the app looks like it
	// has been heard for as long as the stream lives. Measured cause of "the bar
	// jumps to the browser when a notification arrives and stays there": a web
	// push notification's sound is played by the BROWSER PROCESS, not by a tab,
	// so nothing is playing and nothing is audible, yet a stream named after the
	// browser exists.
	//
	// Browsers always publish MPRIS while they are really playing (that bus is
	// what the play/pause buttons already follow), so for a browser stream the
	// answer "is this an output?" is the player's PlaybackStatus -- plus the
	// audible-tab probe, in case a page is sounding with no player behind it.
	// Only browsers get this test: games, Discord, mpv and the rest publish no
	// player, and are still judged by the duration gate alone.
	function isBrowserChimeOnly(name) {
		if (!/brave|chromium|chrome/i.test(String(name ?? ""))) return false
		const player = root.playerForStreamApp(name)
		if (player?.isPlaying === true) return false
		if (root.browserTabPlaying) return false
		return true
	}

	function noteHeardApps() {
		const now = Date.now()
		const first = {}
		const seen = []
		for (const s of root.audibleStreams("")) {
			const name = String(s?.properties?.["application.name"] ?? "").trim()
			// The shell's own notification sounds are a beep, not an output:
			// letting one take the bar would flash the island on every toast.
			if (name === "" || name === Audio.systemSoundAppName) continue
			if (root.isBrowserChimeOnly(name)) continue
			if (first[name] === undefined)
				first[name] = root.streamFirstHeard?.[name] ?? now
			if (now - first[name] < root.minAudibleMs) continue
			if (seen.indexOf(name) < 0) seen.push(name)
		}
		// Written only when the set of audible names changes: this runs twice a
		// second, and an unconditional write would push a change through every
		// binding that reads it for nothing. Apps that went quiet are dropped
		// here, so their next sound starts the clock again from zero.
		if (Object.keys(root.streamFirstHeard ?? {}).sort().join("\n") !== Object.keys(first).sort().join("\n"))
			root.streamFirstHeard = first
		const kept = (root.heardApps ?? []).filter(x => seen.indexOf(x.name) >= 0)
		for (const name of seen)
			if (!kept.some(x => x.name === name)) kept.push({ name: name })
		// Only reassign on a real change: the poll runs twice a second and an
		// unconditional write would push a change signal through every bound
		// property (and every view repaint) for nothing.
		const before = (root.heardApps ?? []).map(x => x.name).join("\n")
		const after = kept.map(x => x.name).join("\n")
		if (before !== after) root.heardApps = kept
	}
	onSinkInputsChanged: root.noteHeardApps()

	readonly property var soundOutput: (root.heardApps ?? []).length > 0
		? root.heardApps[root.heardApps.length - 1] : null
	// The name to put on the bar when the app has no player to ask.
	readonly property string soundAppName: String(root.soundOutput?.name ?? "")

	// The player behind a PipeWire app name, when that app publishes one.
	function playerForStreamApp(name) {
		const want = String(name ?? "").toLowerCase()
		if (want === "") return null
		const all = Mpris.players.values.filter(p => !root.isProxyBus(p))
		const local = all.find(p => String(p.dbusName ?? "").startsWith(root.localBus))
		// The shell's music player is mpv under the hood, and its stream says
		// "mpv"; naming it Music keeps the bar off a bare "mpv".
		if (local && (want === "mpv" || want === "music")) return local
		return all.find(p => {
			const id = String(p?.identity ?? "").toLowerCase()
			return id !== "" && (id === want || id.includes(want) || want.includes(id))
		}) ?? null
	}

	readonly property var soundAppPlayer: root.playerForStreamApp(root.soundAppName)

	// Something is being heard right now, whoever is producing it. This is
	// what the island's media view is allowed to open for.
	readonly property bool soundOutputActive: root.soundAppName !== ""

	// ── Which TAB of a browser is making the sound ────────────────────────
	//
	// A browser publishes ONE media session for all of its tabs, so the bar
	// named the FOCUSED tab while a different tab was the one that was audible
	// (measured: "Best Gaming Music Mix" playing, the bar showing "CHILL PHONK
	// MIX" because that was the tab in front). PipeWire cannot help either --
	// every Chromium tab's stream says media.name "Playback" with application
	// name "Brave". The browser alone knows, and the script asks it; it
	// prints [] whenever no debugging port is open, which keeps the MPRIS
	// answer as the fallback rather than showing nothing.
	property var browserAudibleTabs: []

	readonly property bool browserSounding: root.soundAppName !== ""
		&& /brave|chromium|chrome/i.test(root.soundAppName)

	Process {
		id: tabProbe
		command: ["python3", root.browserTabScript]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(text ?? "[]")
					root.browserAudibleTabs = Array.isArray(parsed) ? parsed : []
				} catch (error) {
					root.browserAudibleTabs = []
				}
				// Reality has caught up with the press: hand the glyph back to
				// the measurement. Only on AGREEMENT -- a probe that is still
				// answering with the state before the press must not undo the
				// optimistic flip half a frame after it happened.
				if (root.tabIntentActive && root.browserTabPlaying === root.tabIntentOn) {
					console.log(`[tab] intent confirmed after ${Date.now() - root.tabIntentAt}ms`)
					root.tabIntentActive = false
				}
			}
		}
	}
	Timer {
		// Only while a browser is the thing being heard: this spawns python, and
		// there is no reason to pay for that when the sound is music or a game.
		interval: 1200
		repeat: true
		running: root.browserSounding
		onTriggered: {
			if (!tabProbe.running) tabProbe.running = true
		}
	}
	onBrowserSoundingChanged: {
		if (!root.browserSounding) root.browserAudibleTabs = []
	}

	readonly property string browserTabTitle: String((root.browserAudibleTabs ?? [])[0] ?? "")

	// Is the browser's sound ON? Asked of the browser, not of its MPRIS bus:
	// the bus belongs to the media-session tab, which is the FOCUSED one, so a
	// transport button driven by it showed "play" while a different tab was
	// audibly playing -- and pressing it then paused that other tab instead.
	readonly property bool browserTabPlaying: (root.browserAudibleTabs ?? []).length > 0
	property bool browserActionIssued: false

	// ── The transport GLYPH, which must not wait to be told ──────────────
	//
	// `browserTabPlaying` is measured, and measuring costs time: the tab has
	// to be asked (a process + a devtools round trip), then the video has to
	// actually stop or start, and the answer only reaches the bar on the next
	// 1.2s probe. Measured on this machine, that made the island's play/pause
	// glyph flip a second or two AFTER the press -- the press worked, the
	// picture lagged behind it.
	//
	// So a press states its intent immediately and the glyph follows the
	// intent, not the measurement. The intent is dropped the moment a probe
	// AGREES with it (reality has caught up, nothing left to fake), and after
	// a timeout in case the action failed -- a glyph that lies forever is
	// worse than one that lags.
	property bool tabIntentOn: false
	property bool tabIntentActive: false
	property double tabIntentAt: 0
	readonly property int tabIntentMs: 4000
	/// What every transport surface draws. Logic keeps using the measured one.
	readonly property bool browserTabPlayingShown: root.tabIntentActive
		? root.tabIntentOn : root.browserTabPlaying

	Timer {
		id: tabIntentExpiry
		interval: root.tabIntentMs
		running: root.tabIntentActive
		onTriggered: {
			console.log("[tab] intent expired without agreement, back to measured")
			root.tabIntentActive = false
		}
	}

	readonly property string browserTabScript: String(Qt.resolvedUrl("../scripts/brave-audible-tab.py")).replace("file://", "")

	// play | pause | toggle, acted on the tab that is really making sound.
	function browserTabAction(action) {
		const asked = String(action)
		// The glyph answers the press NOW (see tabIntentOn). `toggle` has no
		// written state to read, so it means "the other one from what is shown".
		root.tabIntentOn = asked === "pause" ? false
			: asked === "play" ? true
			: !root.browserTabPlayingShown
		root.tabIntentActive = true
		root.tabIntentAt = Date.now()
		// The focused window's title goes with the verb: the browser reports its
		// tabs in its own order, and that order is what made the next press start
		// an older video. The window title is the tab the user is looking at.
		tabAction.command = ["python3", root.browserTabScript, asked, "9222",
			String(HyprlandData.activeWindow?.title ?? ""),
			String(root.nowPlayingName ?? "")]
		if (!tabAction.running) tabAction.running = true
	}

	Process {
		id: tabAction
		stdout: StdioCollector {
			onStreamFinished: {
				console.log(`[tab] ${String(text ?? "").trim()}`)
				// Re-read straight away: the glyph and the name both come from the
				// probe, and waiting for the 1.2s timer made the button look stuck
				// for a moment after every press.
				tabRefresh.restart()
			}
		}
	}
	Timer {
		id: tabRefresh
		interval: 200
		onTriggered: {
			if (root.browserSounding && !tabProbe.running) tabProbe.running = true
		}
	}

	// A page title carries site furniture a now-playing line does not want.
	function tabTitleClean(raw) {
		return String(raw ?? "")
			.replace(/\s*[-–|]\s*YouTube( Music)?\s*$/i, "")
			.trim()
	}

	// THE name every bar surface prints.
	//
	// Order: the audible browser tab (the only source that can be right when
	// a browser has two things playing), then the player's own track, then the
	// app's name for a game or Discord, which publish no player at all.
	readonly property string nowPlayingName: {
		if (root.browserSounding && root.browserTabTitle !== "") {
			const cleaned = StringUtils.cleanMusicTitle(root.browserTabTitle)
			return root.tabTitleClean(cleaned !== "" ? cleaned : root.browserTabTitle)
		}
		return root.mediaTitle(root.shownPlayer) || root.soundAppName
	}

	Process {
		id: sinkPoll
		command: ["pactl", "-f", "json", "list", "sink-inputs"]
		stdout: StdioCollector { onStreamFinished: root.absorbSinkInputs(text) }
	}
	Timer {
		interval: 500
		repeat: true
		running: true
		onTriggered: {
			if (!sinkPoll.running) sinkPoll.running = true
		}
	}

	function browserKey(player) {
		const bus = String(player?.dbusName ?? "").toLowerCase()
		const who = String(player?.identity ?? "").toLowerCase()
		for (const key of ["brave", "chromium", "chrome"])
			if (bus.includes(key) || who.includes(key)) return key
		return ""
	}

	readonly property var soundingNow:
		root.players.filter(p => !root.isProxyBus(p)
			&& (p.isPlaying === true
				|| (root.browserKey(p) !== "" && root.audibleStreams(root.browserKey(p)).length > 0)))

	// What the switch itself stopped, oldest first. Only players this gesture
	// silenced are in here: a source the user paused by hand must not be
	// started again by the next tap.
	property var tapSilenced: []
	// When it was filled, so a tap a moment later is still the second press.
	property double tapSilencedAt: 0

	function tapSilencedNames(list) {
		return (list ?? []).map(x => x === "local"
			? "local music"
			: String(x?.identity ?? x?.dbusName ?? "player")).join(", ")
	}

	// Is this the browser? Brave and Chromium publish their whole window as one
	// player, which is the odd case the tap has to work around.
	function isBrowser(player) {
		return root.browserKey(player) !== ""
	}

	// ── The streams that are still sounding after the players were paused ──
	//
	// A browser tab that is not Chromium's media session has no pause interface
	// at all, so it keeps playing. Its output is silenced at the stream instead
	// -- the last lever there is, and a reversible one: these nodes are unmuted
	// again the moment the switch brings something back, or as soon as the user
	// starts playing anything by hand.
	// ── Reaching the browser tab Chromium will not hand over ──
	//
	// A browser is one MPRIS player for all of its tabs, and `pause` only ever
	// reaches the tab holding the media session. The tab that is not the session
	// has no interface at all -- but `stop` releases the session and Chromium
	// promotes the next PLAYING tab, which the next sweep can then pause.
	// Muting the stream was tried instead and is what the user rejected: the
	// video kept playing, silently, and stayed silent afterwards. Stopping is
	// the real thing.
	property var tapMutedStreams: []

	function unmuteEverything() {
		// Every output, not just the recorded ones: a stream's mute lives in the
		// audio server, while this list lives in the shell -- a reload in between
		// left streams silent with nothing left to restore them (measured: three
		// muted streams that no press of the switch could bring back).
		for (const node of Audio.outputAppNodes) {
			try {
				if (node?.audio) node.audio.muted = false
			} catch (error) {
				// The stream is gone; nothing to restore.
			}
		}
		root.tapMutedStreams = []
	}

	// Deliberately NO watcher that unmutes when playback reappears: a browser's
	// bus reports Playing for a moment while it settles after a pause, and an
	// unmute on that reading put the sound straight back after the user asked
	// for silence. The streams come back on the next press of the switch, which
	// always unmutes before it resumes anything.

	// Pause every player that is playing, once. Returns how many answered.
	//
	// CHROMIUM'S PROMOTION is why this is a function rather than a loop inside
	// `silenceEverything()`: a browser is ONE MPRIS player for all of its tabs,
	// and when that session pauses Chromium hands the media session to another
	// PLAYING tab. One pause therefore stops one tab and silently promotes the
	// next -- so the switch repeats the pause a few times, and each repeat
	// catches whatever was promoted. Muting instead of pausing was tried and is
	// exactly what the user rejected: the video kept playing, just inaudibly.
	function pauseSounding() {
		let n = 0
		for (const p of root.soundingNow) {
			// startsWith, not equality: this bus is published with an
			// instance suffix (the same reason `localMusicPlayer` matches it
			// this way). An exact test missed it, so the local player was
			// paused twice and the second pause undid the first.
			if (String(p.dbusName ?? "").startsWith(root.localBus)) continue
			try {
				// The browser: `pause` reaches one tab and Chromium keeps the
				// media session on it -- measured, two playing tabs and the
				// second kept sounding, and repeated pauses never moved the
				// session. `stop` DOES release it, Chromium promotes the next
				// playing tab, and the next sweep stops that one too. But a
				// stopped session cannot be started again through MPRIS, so
				// the first sweep stops (to get past the tab holding the
				// session) and the later sweeps PAUSE, leaving the tab the
				// switch lands on resumable -- the one "pressed again" brings
				// back.
				if (root.isBrowser(p)) {
					// A CDP pause for the audible tab is already on its way (see
					// `silenceEverything`); the MPRIS verb would go to the FOCUSED
					// tab instead and stop the wrong video.
					if (root.browserActionIssued) continue
					// The bus says Paused but a stream is still audible: that is the
					// tab the CDP action exists for, and pausing the bus here only
					// reaches whatever tab that window has in front. Leave it alone.
					if (p.isPlaying !== true) continue
					// PAUSE only, and this is not negotiable: `stop` releases the
					// browser's media session and a released session cannot be
					// started again by any client (measured: canPlay false, "no
					// player could handle this command"), which is exactly the
					// "second tap does not bring it back" bug. A just-paused tab
					// also keeps its stream open for seconds, so "still audible"
					// cannot be trusted to mean "another tab is playing" -- the
					// release fired on that false reading and left a paused video
					// unstartable. Pause, and only pause.
					p.pause()
					n += 1
					continue
				}
				// PAUSE, and never a toggle.
				//
				// This loop only ever runs to STOP things, and the players in it
				// are here on an audio reading, not on their own state: a tab that
				// was just paused keeps its stream open for a moment, so a paused
				// player shows up in this list. Toggling that one STARTED it --
				// which is exactly the report: the tap stopped the video being
				// watched and a different video from earlier began playing. A
				// source that cannot pause is left alone instead of being nudged.
				if (p.canPause !== true) continue
				p.pause()
				n += 1
			} catch (error) {
				console.warn(`[Mpris] could not pause ${p?.identity ?? "a player"}: ${error}`)
			}
		}
		return n
	}

	// The promotion catch-up: a few repeats, then it gives up rather than
	// poking a player that keeps coming back.
	property int pauseWavesLeft: 0
	Timer {
		// Slower than the sink poll by design: each sweep must see the Corked
		// flags the previous one caused, or it would stop the wrong tab.
		interval: 900
		repeat: true
		running: root.pauseWavesLeft > 0
		onTriggered: {
			const again = root.pauseSounding()
			root.pauseWavesLeft -= 1
			if (again === 0)
				root.pauseWavesLeft = 0
		}
	}

	// Silence every source. Returns who was silenced, "" when nothing sounded.
	function silenceEverything() {
		// The shell's own player answers through its own API rather than through
		// its bus -- same reason `claimOutput()` matches it by bus name -- and
		// it is kept OUT of the loop below: pausing the bus and then calling
		// playPause() would toggle the same player twice and leave it talking.
		const sounding = root.soundingNow.filter(p => !String(p.dbusName ?? "").startsWith(root.localBus))
		const localSounding = MusicPlayer.hasTrack && MusicPlayer.paused === false
		// `audibleCount` catches the case the bus hides: a browser playing on a
		// tab whose session the bus is not following.
		if (sounding.length === 0 && !localSounding && root.audibleCount === 0)
			return ""

		const heard = sounding.indexOf(root.stickyPlayer) >= 0
			? root.stickyPlayer
			: (sounding.length > 0 ? sounding[sounding.length - 1] : "local")

		const stopped = sounding.slice()
		// No stream muting anywhere in this path. Muting was tried and is what
		// the user heard as a bug: it runs milliseconds after the pause, so a
		// video that WAS paused still ended up with a muted stream, and clicking
		// play afterwards gave a silent video. Everything here stops playback at
		// the player, which Chromium honours.
		root.pauseWavesLeft = 0
		root.browserActionIssued = false
		// Stop the browser tab that is really playing. MPRIS only reaches the
		// media-session tab, which is whichever one is in front.
		if (root.browserSounding) {
			root.browserActionIssued = true
			root.browserTabAction("pause")
		}
		root.pauseSounding()
		// Let the promotion catch-up follow whatever a browser hands its media
		// session to next; it stops by itself when nothing is left playing. Five
		// sweeps, because a sweep may spend itself waiting for a fresh reading.
		root.pauseWavesLeft = 5
		if (localSounding) {
			MusicPlayer.playPause()
			stopped.push("local")
		}

		const at = stopped.indexOf(heard)
		if (at >= 0 && at !== stopped.length - 1) {
			stopped.splice(at, 1)
			stopped.push(heard)
		}
		root.tapSilenced = stopped
		root.tapSilencedAt = Date.now()
		return root.tapSilencedNames(stopped)
	}

	// Bring back the last thing this switch silenced. "" when there is nothing.
	function resumeLastSilenced() {
		// The catch-up must not fight the resume: a wave that fires after the
		// requested player has been started would immediately pause it again.
		root.pauseWavesLeft = 0
		root.unmuteEverything()

		const list = (root.tapSilenced ?? []).filter(x => x !== null && x !== undefined)
		for (let i = list.length - 1; i >= 0; --i) {
			const entry = list[i]
			if (entry === "local") {
				if (!MusicPlayer.hasTrack) continue
				MusicPlayer.playPause()
				root.tapSilenced = []
				return "local music"
			}
			if (Mpris.players.values.indexOf(entry) < 0) continue
			if (root.isBrowser(entry)) {
				// Bring back the tab the previous press stopped, not the one the
				// browser's media session happens to point at.
				root.browserTabAction("play")
				root.tapSilenced = []
				return "Brave"
			}
			try {
				// `play`, never a toggle: this entry is here because the switch
				// paused it, and a browser ignores PlayPause once its session has
				// been released -- measured, `playerctl play-pause` left the tab
				// paused while `playerctl play` started it. A toggle would report
				// success and do nothing, which is exactly "the second tap does
				// not bring it back".
				if (typeof entry.play === "function") entry.play()
				else entry.togglePlaying()
				root.tapSilenced = []
				return String(entry.identity ?? entry.dbusName ?? "player")
			} catch (error) {
				console.warn(`[Mpris] could not resume ${entry?.identity ?? "a player"}: ${error}`)
			}
		}
		root.tapSilenced = []
		return ""
	}

	// One press of the switch. Silences when nothing is remembered; otherwise
	// brings back exactly what the previous press stopped. "" means "nothing
	// done", and the caller falls back to starting something.
	//
	// The decision comes from the switch's OWN memory, not from a measurement:
	// a paused browser keeps an audio stream open (measured here), so "is
	// anything sounding" cannot be read reliably at the moment of the tap.
	// Erring towards silence is also the safe direction -- the alternative
	// started music on top of a video that was still playing.
	// ── ONE measured press ───────────────────────────────────────────────
	//
	// What the press does is decided by ASKING, every time, never by what the
	// previous press remembered. The memory version went wrong in both
	// directions: a stale "last silenced" entry made a press start a video that
	// was not playing, and then the following press stopped everything.
	property bool tapPending: false

	function tapDecide(browserTitles) {
		const remembered = (root.tapSilenced ?? []).filter(x => x !== null && x !== undefined)
		const browserPlaying = (browserTitles ?? []).length > 0
		// Non-browser sources are asked about their own state; a browser is left
		// out because its bus is one player for every tab and can be wrong.
		const otherPlaying = root.players.some(p => !root.isProxyBus(p)
			&& !root.isBrowser(p) && p.isPlaying === true)
		const localPlaying = MusicPlayer.hasTrack && MusicPlayer.paused === false
		if (browserPlaying || otherPlaying || localPlaying) {
			// Something is playing: stop that. A fresh stop starts a fresh memory.
			root.tapSilenced = []
			root.silenceEverything()
			return
		}
		if (remembered.length > 0) {
			root.resumeLastSilenced()
			return
		}
		// Nothing is playing and nothing was stopped: doing nothing is the only
		// answer that cannot start a video the user was not watching.
		console.log("[tap] nothing playing and nothing remembered: leaving playback alone")
	}

	function tapSwitch() {
		if (root.tapPending)
			return ""
		root.tapPending = true
		tapMeasure.command = ["python3", root.browserTabScript, "list", "9222"]
		tapMeasure.running = true
		return ""
	}

	Process {
		id: tapMeasure
		stdout: StdioCollector {
			onStreamFinished: {
				let titles = []
				try {
					titles = JSON.parse(String(this.text ?? "").trim() || "[]")
				} catch (error) {
					titles = []
				}
				root.tapDecide(Array.isArray(titles) ? titles : [])
			}
		}
		onExited: (exitCode, exitStatus) => { root.tapPending = false }
	}

	function previous() {
		if (this.canGoPrevious) {
			this.__reverse = true;
			this.activePlayer.previous();
		}
	}

	property bool canGoNext: this.activePlayer?.canGoNext ?? false;
	function next() {
		if (this.canGoNext) {
			this.__reverse = false;
			this.activePlayer.next();
		}
	}

	property bool canChangeVolume: this.activePlayer && this.activePlayer.volumeSupported && this.activePlayer.canControl;

	property bool loopSupported: this.activePlayer && this.activePlayer.loopSupported && this.activePlayer.canControl;
	property var loopState: this.activePlayer?.loopState ?? MprisLoopState.None;
	function setLoopState(loopState: var) {
		if (this.loopSupported) {
			this.activePlayer.loopState = loopState;
		}
	}

	property bool shuffleSupported: this.activePlayer && this.activePlayer.shuffleSupported && this.activePlayer.canControl;
	property bool hasShuffle: this.activePlayer?.shuffle ?? false;
	function setShuffle(shuffle: bool) {
		if (this.shuffleSupported) {
			this.activePlayer.shuffle = shuffle;
		}
	}

	function setActivePlayer(player: MprisPlayer) {
		const targetPlayer = player ?? Mpris.players[0];
		console.log(`[Mpris] Active player ${targetPlayer} << ${activePlayer}`)

		if (targetPlayer && this.activePlayer) {
			this.__reverse = Mpris.players.indexOf(targetPlayer) < Mpris.players.indexOf(this.activePlayer);
		} else {
			// always animate forward if going to null
			this.__reverse = false;
		}

		this.trackedPlayer = targetPlayer;
	}

	IpcHandler {
		target: "mpris"

		function pauseAll(): void {
			for (const player of Mpris.players.values) {
				if (player.canPause) player.pause();
			}
		}

		function playPause(): void { root.togglePlaying(); }
		// The three-finger tap's switch, callable from outside so it can be
		// exercised without the gesture (and so the log names who answered).
		// What the bar thinks is making sound, in one line: the audible apps in
		// the order they started, which app is being followed, and the player it
		// resolved to (none for a game or Discord).
		function sound(): string {
			return `apps=[${(root.heardApps ?? []).map(x => x.name).join(", ")}]`
				+ ` following=${root.soundAppName === "" ? "-" : root.soundAppName}`
				+ ` player=${root.soundAppPlayer?.identity ?? root.soundAppPlayer?.dbusName ?? "none"}`
				+ ` active=${root.soundOutputActive}`
				+ ` tabPlaying=${root.browserTabPlaying}`
				+ ` tab=${root.browserTabTitle === "" ? "-" : root.browserTabTitle}`
				+ ` name=${root.nowPlayingName === "" ? "-" : root.nowPlayingName}`
		}
		function silence(): string { return root.silenceEverything(); }
		function tap(): string { return root.tapSwitch(); }
		function resume(): string { return root.resumeLastSilenced(); }
		// The three-finger tap's chain, callable from outside so it can be
		// exercised without the gesture (and so the log names who answered).
		function playBest(): void { root.toggleBest(); }
		// Read-only: the order the tap would try, live.
		function playCandidates(): string {
			return root.candidates()
				.map((p, i) => `${i + 1}.${String(p.identity ?? p.dbusName ?? "player")}${root.canPlay(p) ? "" : "(nothing to play)"}`)
				.join(" > ");
		}
		function previous(): void { root.previous(); }
		function next(): void { root.next(); }
	}
}
