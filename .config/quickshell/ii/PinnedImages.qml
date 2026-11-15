import QtQuick
import Quickshell

/**
 * Every pinned picture, one surface each.
 *
 * The registry is GlobalStates.pinnedImages, so this file has no state of its
 * own: a pin appends an entry and a surface appears, an unpin removes one and
 * the surface goes with it. Variants -- the same instancing the dictation
 * indicator uses for its per-screen window -- is what turns the list into
 * surfaces; there is deliberately no other bookkeeping, because two places
 * claiming to know the pinned set is how a picture ends up on screen with no
 * entry, or the other way round.
 */
Scope {
    id: root

    Variants {
        model: GlobalStates.pinnedImages

        // No properties set here on purpose: Variants hands the entry to the
        // delegate as `modelData`, and PinnedImage declares that itself.
        delegate: PinnedImage {}
    }
}
