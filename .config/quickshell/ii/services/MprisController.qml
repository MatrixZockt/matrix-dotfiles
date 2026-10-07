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
	readonly property var playingPlayers:
		Mpris.players.values.filter(p => p.isPlaying === true)

	// The last player that was heard, and so the one to fall back on.
	property MprisPlayer stickyPlayer: null

	readonly property MprisPlayer shownPlayer:
		root.playingPlayers.length > 0
			? root.playingPlayers[root.playingPlayers.length - 1]
			: (root.stickyPlayer ?? root.activePlayer)

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
		root.stickyPlayer = root.playingPlayers.length > 0
			? root.playingPlayers[root.playingPlayers.length - 1]
			: root.stickyPlayer;
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

	property bool canGoPrevious: this.activePlayer?.canGoPrevious ?? false;
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
		function previous(): void { root.previous(); }
		function next(): void { root.next(); }
	}
}
