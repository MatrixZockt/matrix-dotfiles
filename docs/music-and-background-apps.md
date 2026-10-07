# Music & background apps

How the music system is wired, why the top bar could not see it, and where the
background-apps tray should go.

## The three processes

| Piece | Unit | Job |
| --- | --- | --- |
| `ii-music-mpd.service` | `extras/systemd/user/` | The **engine**: headless mpv, JSON IPC on `$XDG_RUNTIME_DIR/ii-music-ipc`. Owns playback. |
| `ii-music-mpris.service` | `extras/systemd/user/` | The **face on the bus**: publishes that engine as `org.mpris.MediaPlayer2.iiMusic`. |
| `ii-music-app` | `extras/bin/` | An optional **window**: library, playlists, the extra settings. |

The engine is a systemd unit, so it survives closing the app, reloading
Quickshell, and logging out of the UI. Everything else is a client of the same
socket, which is why the sidebar, the app and the bar can never disagree.

## Why the top bar was blind (and the fix)

Every media surface in this shell — the bar's now-playing island, the liquid
bar's media pocket, the dock's collapsed pill, the media panel — reads
`MprisController.activePlayer`, which comes from `Quickshell.Services.Mpris`,
i.e. the **D-Bus session bus**.

mpv does not speak MPRIS. It was launched with `--input-ipc-server` only and
never claimed a bus name, so music started from the left sidebar was
structurally invisible on the bar: the bar showed nothing at all while a song
was playing.

`ii-music-mpris` closes that gap. It is a client of the same mpv socket
everybody else uses and the owner of one well-known name, so the existing
MPRIS code paths light up **with no shell changes at all**. It also fills the
gaps mpv leaves in the spec:

- **title / artist** — mpv's `media-title` is only the filename and `metadata`
  is empty for tagless files, so the `Artist - Title.mp3` naming is parsed
  (the same rule the sidebar's library scan uses).
- **position** — a polled MPRIS property, served from `time-pos` with
  monotonic interpolation between polls, which keeps a client's progress ring
  smooth instead of stepping twice a second.
- **artwork** — embedded APIC frames are extracted with ffmpeg into
  `~/.cache/ii-music-art` and published as a `file://` `artUrl`.
- **loop / shuffle** — `loop-file`, plus a client-side permutation of the
  playlist for shuffle (mpv 0.41 has no `shuffle` property).

### Traps hit while building it, worth not repeating

- dbus-python cannot infer a variant's signature from `{}`. `Metadata` must
  never be an empty dict; use the spec's `NoTrack` sentinel.
- The inner `a{sv}` must be typed **explicitly**
  (`dbus.Dictionary(md, signature="sv")`). Left to guess, the marshaller
  picks a signature from whichever value comes first and D-Bus *aborts the
  process* on an invalid object path.
- `Get()` returns a bare variant, so map/array values need `variant_level=1`.
- Every `a{sv}` reply needs typed values — a plain Python list has no
  inferrable signature and is rejected.
- The mpv socket is **asynchronous**. Reading a value right after `send()`
  always gets nothing; the state can only be updated inside the callback.
  This is why the bridge reconciles on a 500 ms tick rather than trusting
  property-change events alone.

## The Music app is a background app

GTK4 removed `Gtk.StatusIcon`, so a native tray icon is not available. The
model is instead:

- The window uses `hide-on-close`, so **closing it hides it** — the process
  stays, the song keeps playing.
- The app is a `Gio.Application` with a stable `application_id`, so the
  session bus keeps it single-instance: launching it again while hidden
  re-presents the existing window instead of starting a rival that would fight
  over the same socket.
- It registers itself at **startup** in
  `$XDG_RUNTIME_DIR/quickshell-bgapp-music` (containing its pid) and clears
  that file on a real quit. That file is the contract the shell's tray reads.

Settings that mpv can actually honour (volume, shuffle, repeat, output device)
persist to `~/.config/ii-music/config.json` and are re-applied on every
launch, since the daemon outlives the app.

### How the app is installed, and why there is one desktop entry

`extras/bin/ii-music-app` is the source; `install.sh` copies it to
`~/.local/bin/ii-music-app` (the `.desktop` file execs the bare name, so the
copy is what actually runs). **Edit the repo file and re-run the copy** — an
edit to `~/.local/bin` alone is lost on the next install, and the app you are
looking at is not the one you edited:

```sh
install -m 0755 extras/bin/ii-music-app ~/.local/bin/
```

There must be exactly **one** `.desktop` file per app: `extras/applications/`
is copied into `~/.local/share/applications`, and a hand-made second entry
pointing at the same binary does not merge with it. Two entries named `Music`
made the SUPER menu show the player twice, once per file. The shell picks
these up live — no reload needed — which is checkable without a mouse:

```sh
qs -c ii ipc call appSearchService state   # catalogue=N listed=N dropped=N
```

### The app's UI — it IS the middle island's Music view

The window is `NowBarPanel.qml`'s **Media view** (the island's mode 1), rebuilt
in GTK4. Not "inspired by": the numbers are copied, because the request was
that it be that card.

| | the card | the app |
| --- | --- | --- |
| hero cover | 64px, `colLayer1`, 3px inset | **96px** (`HERO_COVER`), 3px inset |
| title | `pixelSize.title`, DemiBold | 22px / 700 |
| sub-line | playlist · album, never twice | same, case-insensitive |
| play disc | 34px, `outlined`, no hover wash | **25px `Mark`**, like every other mark |
| skips | `TransportMark`, 8px apart | 25px `Mark`, 8px apart |
| sound bar | `SpectrumSeekBar`, `pad: 4` | `SoundBar`, `PAD = 4` |
| row | 42px, `spacing: 5` | **56px** (`ROW_H`), 7px between rows |
| header | 32px, above the view, not in it | `.colhead`, above the list |

**Where the app deliberately does NOT copy the card: the hero is bigger.**
That card is 920x580 and mostly list, so its hero is one narrow band; in this
window the hero is the whole "now playing" statement, and 64px read as a
thumbnail pressed against the title. `HERO_COVER`/`HERO_GAP`/`HERO_AIR` are
constants above the palette — one edit to change all three — and the list
still gets every pixel that is left.

This went one step too far and was walked back. The hero was cut to a thin
strip (64px cover, 10px gaps, 30px bar) on the theory that the list is what the
pixels are for. That was wrong: the "playing now" statement is what the window
is opened *for*, and at strip size it read as a caption above a list. The list
is a scroller and gives up rows happily; the hero has no second place to be
looked at. So the hero is sized to read (96/18/16) and the list takes the rest.

**Rows are sized off the art, not the other way round.** They were 42px tall
holding a 24px thumbnail beside 15px text — the art was *smaller than the type
next to it*, and the list read as a dense index rather than as a set of songs.
`ROW_H`/`ART` are now 56/36, and the regression tests assert
`ROW_H >= ART + 20` so the row can never be sized against its own contents.

**Added, and only this:** the playlist rail on the left and the search field.
The card has no room for a rail and none for a search that reaches the
internet; the window is the same instrument plus a filing cabinet next to it.

The bar is one object doing four jobs — spectrum, seek line, clock, volume —
with the card's geometry exactly:

- one pill per ~12px, 3px between them, never narrower than 3px
- the line is 4px at the **bottom** of the bars zone and the pills' feet are
  its **top** edge. They stand ON the track; they do not float above it
- a pill is lit up to the playhead and dim ahead of it — that split IS the
  progress, so there is no second line that could disagree with it
- **volume is the ceiling**: at half volume the bars cannot reach the top, so
  one line says two things with no legend
- a 2px rounded cap on the pill tops and square feet; a dome turns a row of
  bars into a row of lozenges

**A paused bar rests; it does not vanish.** This was reported as "the audio bar
is not shown", and it was true — but only while paused. The draw multiplied
every pill's height by a `sink` of `0.0` when nothing was playing and then
skipped anything under 0.4px, so pausing erased all 74 pills and left a bare
4px line. Silence is not absence. An idle spectrum is synthesised instead: a
shallow arc of short pills in the dim accent, deliberately *not* scaled by
volume (it represents no sound, so it must not claim to be a quiet one — and a
muted user still sees the bar it belongs to). The silhouette is identical in
both states, so nothing appears or disappears on pause.

The trap worth remembering: `sink = 0` is not "hide the spectrum", it is "make
every pill shorter than the skip threshold", which is the same as deleting the
widget.

### The transport is the BAR's marks, not the panel's

The play/skip buttons in the app were `Gtk.Button`s carrying stock
`media-playback-*` icons at 32px (skips) and 36px (play). That is the **old
NowBarPanel transport** (28/32/28), not the design in the top bar — and the
owner kept pointing at the bar's. They are now a port of
`modules/common/widgets/TransportMark.qml`, drawn in cairo by `Mark`:

- **25x25 for every mark.** The panel's play was 34px because that transport
  was 28/32/28 and play had to win; against 25/25/25 it does not, and a mark
  that is bigger than its neighbours is not a bigger play button, it is a
  different design. `HERO_DISC` is gone.
- **The skips carry no pad.** The bar's arrows are bare marks; a padded arrow
  "reads heavier than the song title they flank".
- **Pause is two rounded bars, drawn** — 5x13, radius 2.5, 1.7 border — not
  GTK's symbolic glyph, which is two hard rectangles. Play is an **outline**
  triangle at rest that fills on hover, which is what the bar's FILL axis
  does.
- **Hover is a 1px accent ring and nothing else.** No growth, no fill swell.

Three traps in that port, all silent:

1. **`Gtk.DrawingArea` has no signals** — `signal_list_names` on it returns an
   empty tuple — so `clicked` must be registered in `__gsignals__` before it
   can be connected or emitted.
2. **A bare `DrawingArea` measures to ZERO**, the same trap that made the
   sound bar draw nothing. Each mark asks for 25x25 explicitly.
3. **GTK4's CSS parser has no `cursor` property** (it logs `No property named
   "cursor"` and drops the rule). The pointing hand is set on the widget with
   `set_cursor`.

The outlined triangle also has to be inset by half the stroke. Without the
inset the centred stroke eats the apex and the mark becomes an invisible
sliver at 1.7px — which is exactly what it did on the first attempt, caught by
rendering the three marks side by side and looking at them.

### Four sizing bugs only a screenshot could find

None of these throw, and none of them are visible in a widget-tree assertion
that does not ask the right question:

- **The sound bar drew nothing at all.** A `Gtk.DrawingArea` measures to
  *zero* on its own, so the whole bar laid out at 0px tall: no line, no
  pills, no spectrum, no error. Its height is now explicit and derived —
  `HEIGHT = pad*2 + bars + gap + times` = 53 — so the thing measured and the
  thing drawn cannot drift apart.
- **The two time stamps read as one number** ("1:211:28"). The spacer between
  them was an empty `Gtk.Box`, which asks for *zero* width. It expands now.
- **The row columns were drawn on top of each other** ("kurayami no
  nakaDJ UNIVXRSEL"). A horizontal `Gtk.Box` hands every child its natural
  width and shrinks nothing, so a long title claimed the row. Fixed by pinning
  every column but the title (`width_chars`) and letting only the title flex
  and ellipsise. Rows are also a fixed 42px now: a Box of labels sizes itself
  to its tallest child, so rows grew and shrank with their text.
- **The hero's cover ignored the frame it was put in**, so an "88px" cover
  allocated 318x318 and ellipsised the title beside it. `set_size_request`
  sets a **minimum**; a `Gtk.Picture`'s natural size is the *artwork's* pixel
  size (the covers are 320x320), so the row gave the picture every pixel the
  title had not already claimed. Measured on this machine, the frame's
  allocated width was 318 against a requested 88. No size request can fix
  this — the widget has to agree about its natural size, which is why the
  hero cover is a `Gtk.Image` with `set_pixel_size` (natural = exactly what
  was asked for) rather than a `Gtk.Picture` with `content-fit`. The
  regression test asserts `measure(...)[1] == HERO_COVER`, not
  `get_size_request()`; the latter passed while the layout was broken.

Two more notes on that hero, both from the same screenshot: the title now
carries `set_lines(1)` like the sub-line did (a title allowed to wrap grew the
identity block and knocked the cover out of alignment with the words), and its
vertical air is the single `HERO_AIR` used three times — above the row,
between the row and the bar, below the bar. It was 22 above (14 plus a nested
8), 18 to the bar and 10 below, which is three rhythms for one block and the
reason it read as a stack of unrelated pieces.

**The window declares a minimum width of 700**, and the number is *measured
by the test*, not asserted from arithmetic: the suite walks the widget tree
asking GTK what the layout's own minimum is and checks the declared figure
covers it. That matters because the minimum has to track the hero — it was 626
back when the cover was 72, and the cover is 96 now, which is 24 more pixels
the title has to give up. A hardcoded 640 would have silently passed while the
words were being squeezed. Without a minimum at all, a tiling compositor hands
the window less than the content needs and GTK does not shrink the transport —
it **clips** it, so the next mark vanishes off the right edge with no ellipsis
and no error. That is the same "the buttons look wrong" complaint reproduced at
the wrong width.

The bands come from the shell's own `cava` config, spawned by the app for the
same reason the shell does — the card has a service holding them in memory and
a second process cannot read that.

### Five bugs this rewrite had to fix, all of them silent

None of these throw. Each one looks like "the app is a bit off", which is why
they are worth writing down:

- **`socket.timeout` is an `OSError`.** The mpv socket had `settimeout(2)`
  for connecting and then used the same socket for a blocking `recv` — so
  every two seconds of silence, i.e. whenever nothing was changing, raised
  `TimeoutError`, tore the socket down and told the window the daemon DIED.
  That is the "Daemon offline / starting ii-music-mpd…" in the screenshot,
  next to a bar that said it was playing. The read timeout is now removed
  after connecting, and a timeout is caught separately from a disconnect.
- **The connect notification can be delivered to nobody.** `_connect()`
  notifies `handlers`, and the window appends its handler *after* the reader
  thread is already running — so when the daemon is already up at startup the
  one "we are connected" message goes nowhere and the hero says "offline"
  forever. The flag is now read from `mpv.daemon_up` on every poll, which is
  `send`'s own truth.
- **mpv's `filename` is a basename; `path` is absolute.** The library is
  scanned as absolute paths, so joining on `filename` found nothing: no
  playlist was ever detected and the playing row was never marked. Join on
  `path`.
- **An all-or-nothing frame parser.** One stray character in a cava frame made
  the whole frame raise and be skipped, every frame, forever — a flat
  spectrum with no error anywhere. Parsed field by field now.
- **`Gtk.Box` has no `get_children`, `get_child`, `replace` or `insert`** in
  this binding. The number slot is therefore a container built before it is
  needed (so number ↔ meter is a remove+append), and the accent rule is on
  every row and only *coloured* on the current one (so marking never shifts
  the columns).

And one that was a design decision rather than a bug: the position on the bar
is **interpolated** — mpv's `time-pos` only changes when it changes, so
reading it left the scrubber frozen between reports. It is the last value mpv
said plus wall time since, re-anchored every poll.

### Artwork comes out of the mp3s

There are no image files in the library at all — the pictures are APIC frames
inside the mp3s — so every image in the app is extracted on demand:

- **Now playing**: the current file's embedded art, 122px.
- **Track rows**: a 36px cover, with the play/pause badge laid over it on the
  row that is playing.
- **Playlists**: a 2×2 mosaic of the first four tracks' covers. The note icon
  shows through any square that has none, so a partly-filled mosaic still
  reads as artwork rather than as a broken image.

One ffmpeg process per track is far too slow to run on the GTK thread, so
`Covers` (a four-thread pool) extracts each file **once** into
`$XDG_CACHE_HOME/ii-music/covers/`, keyed by `sha1(path|mtime_ns|size)`, and
hands the widget a **file path** rather than bytes. Rows never wait: they show
a placeholder and swap in the art when it lands, so the window is complete and
usable before a single decode finishes. The queue is FIFO on purpose — rows
are built top to bottom and the list starts scrolled to the top, so what is on
screen is what is being decoded. Only what is actually shown gets extracted
(~36 files for a full view of one playlist plus the five mosaics, not all 125).

By path rather than by pixbuf because `Gtk.Image.set_from_pixbuf` and
`Gdk.Texture.new_for_pixbuf` are both deprecated since GTK 4.10, while
`set_from_file` is current and lets GTK stream the image instead of holding a
decoded copy in Python.

### The sidebar tab searches the same library, and the internet too

`MusicTab.qml` searches **every** local playlist (title, artist and folder
name) and, at the same time, the online catalogue through `OnlineMusic`
(Audius). One merged list, local hits first: one list because "search" means
one list when you do not already know which folder a song is in, and local
first because those hits are already on the disk and play instantly.

The results **replace** the browser instead of covering it. The playlist rail,
the rules and the track list are `visible: !root.searching`; a `ColumnLayout`
skips an invisible child, so they collapse and hand their height to the
results. The header, the now-playing card, the transport and the search field
stay exactly where they were — covering the player is wrong on its own terms,
because the thing playing is still playing and a search that hides the
transport hides what you need when a result is bad.

This replaced an overlay, and the overlay was the bug: it was an `Item` with
no background anchored over the whole tab, so the header, the card and the
rail drew straight through it, and because the field was hidden while
searching, the typed query appeared twice — once in the overlay's heading and
once over the top of the tab. There is no overlay to be transparent now.

Online requests are **debounced by 450ms** and Enter skips the wait. One
request per keystroke would fire six searches for a six-letter word, and
Audius rate-limits by `app_name`, so the surplus is what eventually makes the
search fail for everyone.

A row PLAYS (local off disk, online streamed through `playNow`) and its
buttons FILE it. Online rows get two — **save offline** on its own, and **add
to a playlist** — because those are two different questions ("keep this" vs
"file this") and collapsing them into one control loses one of them. Local
rows keep the single add-to-playlist button they always had. Online hits are
NOT capped: they accumulate across pages behind a "Load more" row at the
bottom, because "all possible songs" is a paging problem rather than a limit
problem (see below).

`qs -c ii ipc call musicTab search "<query>"` drives the same code path a
keystroke does, `close` puts it back, and `state` reports the query, the
local/online split and which of the browser widgets are visible:

```
query="phonk" searching=true local=45 online=10 onlineBusy=false
area=... field=... rail=... tracks=...
```

Two traps from writing it:

- `IpcHandler` lives in `Quickshell.Io`. Without that import the **whole
  config fails to load**, and the error chain points four files away, at
  "IpcHandler is not a type".
- `visible` is the *effective* visibility, so it reads `false` for a whole
  subtree whenever the tab itself is not showing. A `state` report of all
  false means "the tab is not on screen", not "the bindings are broken".

### Searching online, and saving what you find

Both surfaces search the same online catalogue and, more importantly, agree on
where a save lands.

**Paging.** `GET /tracks/search` returns **10 rows with no parameters at all**
and honours `limit`/`offset` (measured against the live API: `limit=100`
returns 100, `offset=10` returns a different first row). So "all possible
songs" cannot be a fixed cap; results **accumulate**:

- `OnlineMusic.qml` — `pageSize=50`, `offset`, `hasMore`, `search(text, append)`,
  `loadMore()`, dedupe by id. A short page is the last page; that is the only
  end-of-results signal the endpoint gives.
- `ii-music-app` — `AUDIUS_PAGE = 50`, same accumulate-and-append, with a
  "Load more results" **row in the list** rather than a control above it, so
  it does not push the results around while you are reading them.

Measured live, both: `phonk` → 50 → 100 → 149, then `hasMore=false` and a
further `loadMore()` is a no-op.

**Two save destinations, one API.** `download(track, folder = "")` and
`_save_online(track, folder = "")`:

| `folder` | lands in | means |
| --- | --- | --- |
| omitted | `~/Music/Spotify/Audius` (`downloadFolder`) | saved offline, in no playlist |
| a name | `~/Music/Spotify/<name>/` | that playlist, created by the download |

The library is folder-per-playlist, so a file has to live *somewhere*, and the
standalone bucket is the somewhere that means "just keep it".

**One settings file, two programs.** Both read `music.downloadFolder`,
`music.onlineAppName` and `music.rescanAfterDownload` out of
`~/.local/state/quickshell/states.json` — the shell's own `Persistent.qml`
state (`app_name` is Audius's rate-limit identity, and this app shares the
user's rather than inventing a second one). The Python side re-reads it on
every call rather than caching at import, because the shell may write it after
the app started and a stale download folder puts saves somewhere invisible.

Traps from writing the QML half, all of which cost a shell reload to find:

- **A collector's `onStreamFinished` fires before `Process.exitCode` is
  populated.** Reading it there reports a perfectly good 3 MB download as
  "Download failed" — which it did, for a while. The verdict belongs in the
  `Process`'s own `onExited`, which is what the rest of the config already
  uses.
- **No type annotations on a plain QML function.** `function search(text,
  append: bool = false)` kills the entire config with *"Type annotations are
  not supported (yet)"* four files up the chain. They are only allowed on
  `IpcHandler` functions, where Quickshell parses them itself.
- Mutating `saved` in place emits no `changed()`, so the row never flips to
  "saved". Re-assign a copy.
- A 404 from the stream endpoint is usually **not** a bug in the URL: Audius
  indexes a handful of tracks whose file no longer resolves ("track not
  found"). Say that in words rather than leaking `curl: (22)`; `--fail` plus
  `--remove-on-error` also means a failure leaves no empty mp3 behind for the
  library scan to find.

Traps from the Python half:

- **`Gtk.Button` has no `set_popover` in this binding** — only
  `Gtk.MenuButton` carries the `popover` property, and that property is what
  makes a widget *open* its popover on click. The obvious choice compiles and
  raises on the first click.
- **Connect `row-activated` on the `Gtk.ListBox`, not per row.** `Gtk.Box` has
  no `activate` signal, so the per-row version raises at runtime.
- A `Gtk.ScrolledWindow` puts a `Gtk.Viewport` between itself and its child,
  so "index 1 of the popover's children" is not the list box. Find it by type.
- A slow response for an old query must not overwrite a newer one — type
  `ph`, then `phonk`, and the `ph` answer lands last. Hence the generation
  counter in `Audius` (and `append` keeping the current one, so pages of two
  different queries never mix in one list).
- `subprocess.run` is looked up on the module at call time, so patching it in
  a test patches it for everything — restore it.

**Online rows are not queued behind local ones.** Clicking an online row plays
that one stream; clicking a local row queues the local files only. Queueing
fifty remote streams behind a click on a local track would open fifty network
connections nobody asked for and start mpv pre-buffering all of them. The
queue index is recomputed accordingly — reusing the visible row index would
land on the wrong track the moment online rows are interleaved.

**Already-saved is per destination, not per track.** Saving the same track
into a playlist and then into the standalone bucket is two answers to two
different questions, so the second one downloads. Only the *identical*
target path is refused as already done.

Verified end to end on both surfaces: a real 85 s / 3.4 MB mp3 written by each,
the library rescan picking both up (local hits 45 → 47), and the library
returned to 125 tracks after the test folders were removed.

To repaint the accent, edit the four constants at the top of the app —
`ACCENT`, `ACCENT_HOVER`, `ACCENT_DIM`, `ON_ACCENT` — and nothing else; the
play button, seek bar, selection and now-playing marker all read from them.

`~/tmp/test-ii-music-ui.py` builds the window in-process (never mapped, so
nothing flashes on screen) and asserts on the widget tree, on what the search
returns for each real playlist, on the keyboard path, and on the artwork
actually reaching the widgets: `python3 ~/tmp/test-ii-music-ui.py`. It points
at `II_MUSIC_APP` if set, which is how the Ctrl+F regression was proven
catchable — and how the online checks were mutation-tested (queueing online
rows like local ones, ignoring the `folder` argument and dropping the debounce
each make it fail).

**164 checks, exit 0**, and the online half is stubbed on purpose: a widget
tree that needs a third-party API to answer is a test that fails when someone
else's DNS is slow. The stub calls back *synchronously*, which the real client
cannot, and that is the point — it pins the callback contract to "everything
is read off `AUDIUS` afterwards", not "the answer arrives as an argument".
`download_track` is stubbed too, and the real one is then driven against a
stubbed `curl` to check its exit-code-to-sentence mapping.

## Where the background-apps tray should go

Four placements were drawn up (see `.thread-preview/tray-previews.html`):

| | Placement | Reach | Noise | Room |
| --- | --- | --- | --- | --- |
| **A** | Popover from a new bar icon, left of the tray | top-right, where the pointer already goes | zero when nothing runs | one icon slot |
| B | Its own tab in the left sidebar | needs the sidebar opened | tab bar reshapes as apps come and go | best for detail |
| C | Rows in the existing tray overflow | two clicks, behind an overflow | nothing added to the bar | title + one action per row |
| D | A strip on the hover-only dock | must aim at the bottom edge | completely hidden at rest | competes with music for the same pill |

**A is the recommendation.** It reuses the pocket machinery in
`BarContent.qml` that volume, network and battery already use, so it is one
more popover rather than a new pattern, and it inherits the pinned/overflow
semantics from `SysTray.qml` for free. It is also the only option that is
both always-reachable and completely absent when there is nothing to manage.
