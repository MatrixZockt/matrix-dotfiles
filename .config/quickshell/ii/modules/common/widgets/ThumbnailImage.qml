import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Thumbnail image. Generates to the right place at the right size, and
 * KEEPS it generated: the cache is watched, so a missing thumbnail is
 * created on demand and a newly created one appears without a reload.
 * See Freedesktop's spec: https://specifications.freedesktop.org/thumbnail-spec/thumbnail-spec-latest.html
 *
 * WHY NOT onSourceSizeChanged: generation used to trigger only when
 * `sourceSize` changed -- but sourceSize only changes when an image has
 * LOADED, and with the thumbnail missing nothing ever loads. A deadlock:
 * no thumbnail -> no load -> no trigger -> no thumbnail, forever. That is
 * why the whole ~/.cache/thumbnails tree was empty and every wallpaper
 * card showed its fallback instead of a preview. The trigger is now the
 * FILE's existence (a watched FileView), which cannot deadlock: missing
 * file -> generate -> watcher sees it appear -> image reloads.
 */
StyledImage {
    id: root

    property bool generateThumbnail: true
    required property string sourcePath
    property string thumbnailSizeName: Images.thumbnailSizeNameForDimensions(sourceSize.width, sourceSize.height)
    property string thumbnailPath: {
        // A string property must never be handed `undefined`: an empty source
        // (a placeholder tile, a not-yet-set path) would otherwise log a
        // binding warning on every instantiation.
        if (sourcePath.length == 0) return "";
        const resolvedUrlWithoutFileProtocol = FileUtils.trimFileProtocol(`${Qt.resolvedUrl(sourcePath)}`);
        const encodedUrlWithoutFileProtocol = resolvedUrlWithoutFileProtocol.split("/").map(part => encodeURIComponent(part)).join("/");
        const md5Hash = Qt.md5(`file://${encodedUrlWithoutFileProtocol}`);
        return `${Directories.genericCache}/thumbnails/${thumbnailSizeName}/${md5Hash}.png`;
    }
    source: root._effectivePath

    // ── Deferred source: the binding-loop breaker ────────────────────────
    // `source` must not depend on `thumbnailPath` in the SAME evaluation:
    // thumbnailSizeName reads sourceSize, which comes from the LOADED image,
    // which comes from source -- a cycle Qt warns about on every load. The
    // one-frame bounce turns the cycle into a converging sequence (each hop
    // a fresh event): name → path → load → size → (maybe) a bigger name →
    // settle. Same final behaviour, no warnings.
    property string _effectivePath: ""
    Timer {
        id: sourceBounce
        interval: 10
        onTriggered: {
            // Once generation has given up, the thumbnail is a dead end --
            // point at the original instead of re-requesting a file that is
            // never going to appear.
            if (root._failed) root.fallBackToSource();
            else root._effectivePath = root.thumbnailPath;
        }
    }
    // Second bounce so the fallback happens AFTER the bounce above cleared
    // _effectivePath, rather than being immediately overwritten by it.
    Timer {
        id: sourceFallback
        interval: 30
        onTriggered: root.fallBackToSource()
    }
    Component.onCompleted: root._effectivePath = root.thumbnailPath

    asynchronous: true
    smooth: true
    mipmap: false

    // Visible once EITHER the thumbnail or the original has decoded. The old
    // `status === Image.Ready` check was already true for the fallback, so
    // the only change is that an image which can never decode now resolves to
    // Error rather than spinning -- and the host can use `undecodable`.
    //
    // LATCHED, and that is the fix for "the wallpapers go invisible when I
    // rotate the carousel".
    //
    // `status` is not monotonic. Every re-point of `source` in this file --
    // the generator's `_effectivePath = ""` bounce, the watcher's
    // `onFileChanged` bounce, `onThumbnailPathChanged` -- drives it straight
    // back through Null/Loading, so a raw `status === Ready` test drops the
    // opacity to 0 in the middle of a refresh that was always going to
    // succeed. In the carousel that is the visible symptom: rotating brings
    // a card into `loadSides`, its Loader builds a fresh ThumbnailImage, and
    // while that one re-decodes the card is fully transparent. On a fast
    // rotation the decode never finishes before the next card is asked for,
    // so the cards read as blank or vanishing rather than as loading.
    //
    // Once this widget HAS decoded, it stays visible: a re-decode of the
    // same widget is a refresh of an image the user is already looking at,
    // and Qt keeps painting the previous frame until the new one is ready.
    // Fading out on every refresh is what made it read as "disappearing".
    // The gate still holds for the case it exists for -- an image that has
    // NEVER decoded stays hidden instead of flashing an empty box.
    opacity: (status === Image.Ready || _everDecoded) ? 1 : 0
    property bool _everDecoded: false
    Behavior on opacity {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
    }

    // ── Existence watch: the generation trigger that cannot deadlock ──────
    // `path` is "" while sourcePath is empty; the handlers no-op then.
    FileView {
        id: thumbWatch
        path: root.thumbnailPath
        watchChanges: true
        onLoaded: root.ensureThumbnail()
        onLoadFailed: root.ensureThumbnail()   // the interesting case: absent
        onFileChanged: {
            // The generator finished: blank the source and bounce so the
            // Image re-reads the now-existing file and fades in.
            root._effectivePath = "";
            sourceBounce.restart();
        }
    }

    property bool _generating: false
    // ── The failure latch ──────────────────────────────────────────────
    // WHY THIS EXISTS
    //
    // Every trigger below re-arms on "the image failed to load": onStatusChanged
    // sees Error -> ensureThumbnail(); the process finishes -> onExited re-points
    // the source; the image fails again -> onStatusChanged fires again. With a
    // file magick CANNOT decode that loop never terminates.
    //
    // It is not hypothetical. ~/Pictures/Wallpapers/
    // dabi-digital-render-3840x2160-16702.png is 1.4 GB of gzip data that
    // merely has a .png name (magic 1f8b), so magick fails with "improper
    // image header" every single time. Measured with the shell running: 2-3
    // magick processes alive at all times, permanently, from a file that can
    // never succeed. Every tile and every carousel card showing that one file
    // kept a decoder churning on a gigabyte-scale blob forever.
    //
    // So the loop now has a counter AND a latch:
    //   * `_attempts` bounds the retries -- two tries is enough to cover a
    //     transient failure (thumbnails dir removed mid-run, disk full at the
    //     wrong moment) without ever reaching "forever".
    //   * `_failed` latches once the generator has run and still produced
    //     nothing, which is the answer for "this file is not a readable image".
    //     After that the widget stops spawning processes and stops asking.
    property int _attempts: 0
    property bool _failed: false
    // Public: a host can show its own icon when no preview is possible,
    // rather than leaving the user looking at an empty tile.
    readonly property bool undecodable: root._failed && status === Image.Error

    function ensureThumbnail() {
        if (!root.generateThumbnail) return;
        if (root.thumbnailPath.length === 0 || root.sourcePath.length === 0) return;
        if (root._generating) return;
        if (root._failed) return;                       // the latch: no more
        if (root._attempts >= 2) return;                // the bound
        // Only generate when actually absent: a load failure of an EXISTING
        // thumbnail (corrupt file) should also regenerate, which the
        // watcher's loadFailed covers -- so no size/mtime subtleties here.
        if (thumbWatch.loaded && thumbWatch.text().length > 0) return;
        root._attempts += 1;
        root._generating = true;
        thumbnailGeneration.running = true;
    }

    // Point at the original file instead of the thumbnail. magick lacking a
    // decoder does NOT mean Qt lacks one: Qt's own image plugins cover
    // formats (and policy-blocked cases) that ImageMagick refuses, so the
    // full-size original is a genuinely better second chance than a blank.
    function fallBackToSource() {
        const direct = FileUtils.trimFileProtocol(root.sourcePath);
        if (direct.length === 0) return;
        root._effectivePath = direct;
    }

    // ONE handler for the path change: the watcher reloads, and the source
    // bounce schedules the re-point. (Two separate onThumbnailPathChanged
    // blocks are a "property value set multiple times" parse error -- the
    // crash-loop class.)
    //
    // THE SIZE CORRECTION. `thumbnailSizeName` is derived from `sourceSize`,
    // which StyledImage computes from `width`/`height`. A Loader sizes the item
    // it builds, but that size lands AFTER Component.onCompleted has already
    // read `thumbnailPath` -- so a card constructed at 0x0 asks magick for a
    // 0x0 bucket ("normal"), spends its whole attempt budget there, and never
    // corrects itself, because nothing was watching width/height. That is a
    // second way a rotated-to card could end up with no visible picture.
    //
    // Re-asking on a size change closes it: when the real size arrives the
    // bucket name changes, this fires, the watcher reloads, and the image
    // points at the correctly-sized thumbnail. Guarded on the latch and the
    // budget exactly like every other trigger, so a file that can never be
    // decoded still stops asking.
    function correctSizeAndRetry() {
        // Only while still hunting: once something is showing, or once the
        // file has been given up on, a size change is not worth another fork.
        if (root._failed || root._everDecoded || root._generating)
            return;
        if (root.width <= 0 || root.height <= 0)
            return;
        thumbWatch.reload();
        sourceBounce.restart();
    }
    onWidthChanged: root.correctSizeAndRetry()
    onHeightChanged: root.correctSizeAndRetry()
    onThumbnailPathChanged: {
        thumbWatch.reload();
        sourceBounce.restart();
    }
    onStatusChanged: {
        // Latch the visibility on the FIRST successful decode; see `opacity`.
        if (status === Image.Ready)
            root._everDecoded = true;
        // A failed load with a supposedly-present thumbnail means the cache
        // file is stale/corrupt: regenerate once. Guarded on the latch, or a
        // file that can never be decoded regenerates forever.
        if (status === Image.Error && thumbnailPath.length > 0
            && !root._failed)
            root.ensureThumbnail();
    }

    // A different FILE is a different question: clear the latch so it gets
    // its own budget. Without this, one undecodable image in a folder would
    // stop every later image in the same view from generating.
    onSourcePathChanged: {
        root._attempts = 0;
        root._failed = false;
    }

    Process {
        id: thumbnailGeneration
        command: {
            const maxSize = Images.thumbnailSizes[root.thumbnailSizeName];
            return ["bash", "-c",
                `mkdir -p '${FileUtils.trimFileProtocol(root.thumbnailPath).split("/").slice(0, -1).join("/")}'`
                + ` && [ -f '${FileUtils.trimFileProtocol(root.thumbnailPath)}' ] && exit 0`
                + ` || { magick '${root.sourcePath}' -resize ${maxSize}x${maxSize} '${FileUtils.trimFileProtocol(root.thumbnailPath)}'; }`
            ]
        }
        onExited: (exitCode, exitStatus) => {
            root._generating = false;
            // Did it actually produce anything? A non-zero exit, or a zero
            // exit that left no file, both mean "no thumbnail" -- and that is
            // the moment to stop asking rather than start the cycle again.
            const produced = thumbWatch.loaded && thumbWatch.text().length > 0;
            if (exitCode !== 0 || !produced)
                root._failed = true;
            // Whatever happened, re-point the image at the (now hopefully
            // existing) thumbnail. Through the bounce, NOT a direct source
            // write: `source` is bound to _effectivePath now.
            root._effectivePath = "";
            sourceBounce.restart();
            thumbWatch.reload();
            // No thumbnail and generation gave up: try the original file with
            // Qt's own decoders before settling for nothing.
            if (root._failed) {
                sourceFallback.restart();
            }
        }
    }
}
