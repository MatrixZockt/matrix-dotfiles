import qs.modules.common
import QtQuick

StyledText {
    id: root
    property real iconSize: Appearance?.font.pixelSize.small ?? 16
    property real fill: 0
    // Reduce memory consumption spikes from constant font remapping.
    //
    // Hover feeds the FILL axis, not a transform: a native-rendered glyph is
    // rasterized ONCE at `pixelSize` and a Scale on the item stretches those
    // pixels, so the "bigger on hover" swell was a blur -- and next to a growing
    // info row in the bar, the smear was the first thing the eye caught. The
    // variable font redraws the glyph at the same size with the filled outline
    // instead: heavier, never softer, and no layout above it moves.
    property real truncatedFill: Math.max(fill, autoHover && pointerOverMe ? 1 : 0).toFixed(1)
    renderType: Text.NativeRendering
    font {
        hintingPreference: Font.PreferNoHinting
        family: Appearance?.font.family.iconMaterial ?? "Material Symbols Rounded"
        pixelSize: iconSize
        weight: Font.Normal + (Font.DemiBold - Font.Normal) * truncatedFill
        variableAxes: {
            "FILL": truncatedFill,
            // "wght": font.weight,
            // "GRAD": 0,
            "opsz": iconSize,
        }
    }

    // ── Hover feedback ──────────────────────────────────────────────────
    // One gesture, one look, for every icon that opts in: the glyph FILLS
    // while the pointer is anywhere over the control that owns it (see
    // `truncatedFill` -- the axis, not a scale, because a transform smears a
    // natively rendered glyph).
    //
    // `autoHover` walks the parent chain looking for the usual hover flags
    // (Button.hovered, MouseArea.containsMouse) rather than every widget
    // having to wire them up by hand: one line per icon instead of a
    // hand-rolled HoverHandler in each.
    property bool autoHover: false
    property int hoverLookupDepth: 6
    readonly property bool pointerOverMe: {
        if (!root.autoHover)
            return false;
        let item = root.parent;
        for (let depth = 0; depth < root.hoverLookupDepth && item; ++depth, item = item.parent) {
            if (item.hovered === true)
                return true;
            if (item.containsMouse === true)
                return true;
        }
        return false;
    }

    // NO `Behavior on fill`. It was here, with the note "Leaky leaky, no
    // good", and it was the cause of the island's "small triangle inside a
    // bigger triangle" on hover.
    //
    // FILL is a variable-font axis with TWO STOPS: 0 is an empty outline,
    // 1 is solid. There is no glyph at 0.4 or 0.7 -- the font interpolates
    // the outlines and hands you a hollow triangle with a smaller solid one
    // nested inside it, which is a shape nobody designed and nobody wants.
    // Asking for a fraction directly is the mistake this island already
    // documented once (a literal 0.75 produced exactly that artefact).
    //
    // Animating the property is the same mistake wearing a disguise: the
    // Behavior swept 0 -> 1 over 200ms, so every hover passed through a
    // hundred values that are not glyphs, and the triangle visibly grew a
    // second triangle inside itself on the way. Hover read as a shape
    // deforming rather than as a button lighting up.
    //
    // So the axis is SWITCHED, never swept: `fill` is set to 0 or 1 and
    // stays there, and the motion on hover comes from the widgets that
    // surround the icon -- the island button's ring, which fades over
    // 110ms. One animated thing that was designed to be animated beats one
    // animated thing that passes through states the font does not have.
    //
    // This is a shared component, so the fix applies to every icon in the
    // shell that fills on hover, not just the island's transport. The change
    // is the same everywhere: the fill switches at the instant hover starts
    // instead of sweeping over 200ms.
}
