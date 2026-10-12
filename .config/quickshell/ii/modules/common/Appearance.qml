import QtQuick
import Quickshell
import qs.modules.common.functions
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root
    property QtObject m3colors
    property QtObject animation
    property QtObject animationCurves
    property QtObject colors
    property QtObject rounding
    property QtObject font
    property QtObject sizes
    property string syntaxHighlightingTheme

    // The wallpaper that is actually drawn right now.
    //
    // With `background.separateThemeWallpaper` off this is simply the one
    // wallpaper the user picked. With it on, it is the path stored against the
    // theme that is currently active -- and a theme with nothing stored yet falls
    // back to the shared wallpaper rather than showing nothing.
    readonly property string themeWallpaperPath: {
        if (!Config.options.background.separateThemeWallpaper)
            return Config.options.background.wallpaperPath;
        const slot = m3colors.darkmode
            ? Config.options.background.wallpaperPathDark
            : Config.options.background.wallpaperPathLight;
        return (slot && slot.length > 0) ? slot : Config.options.background.wallpaperPath;
    }
    // Transparency. The quadratic functions were derived from analysis of hand-picked transparency values.
    ColorQuantizer {
        id: wallColorQuant
        property string wallpaperPath: root.themeWallpaperPath
        property bool wallpaperIsVideo: wallpaperPath.endsWith(".mp4") || wallpaperPath.endsWith(".webm") || wallpaperPath.endsWith(".mkv") || wallpaperPath.endsWith(".avi") || wallpaperPath.endsWith(".mov")
        source: Qt.resolvedUrl(wallpaperIsVideo ? Config.options.background.thumbnailPath : root.themeWallpaperPath)
        depth: 0 // 2^0 = 1 color
        rescaleSize: 10
    }
    property real wallpaperVibrancy: (wallColorQuant.colors[0]?.hslSaturation + wallColorQuant.colors[0]?.hslLightness) / 2
    // The wallpaper's own dominant colour, as an opaque QML colour.
    //
    // Exposed because it is what makes a wallpaper reload invisible: painted
    // UNDER the wallpaper, a frame that has not decoded yet shows the picture's
    // own dominant tone instead of a flat unrelated colour, so there is nothing
    // to notice while the decode happens. `depth: 0` (see wallColorQuant) means
    // colors[0] IS the dominant one.
    //
    // Opaque on purpose -- the whole point is to be a backdrop. Guarded for the
    // empty case, because before the quantizer has produced anything
    // colors[0] is undefined and `?? fallback` is what keeps that from
    // assigning undefined to a color (a binding error, which is a warning here
    // but has bitten this file before).
    readonly property color wallpaperDominantColor: wallColorQuant.colors.length > 0
        ? wallColorQuant.colors[0]
        : "#1a1a1a"
    property real autoBackgroundTransparency: { // y = 0.5768x^2 - 0.759x + 0.2896
        let x = wallpaperVibrancy
        let y = 0.5768 * (x * x) - 0.759 * (x) + 0.2896
        return Math.max(0, Math.min(0.22, y)) - 0.12 * (m3colors.darkmode ? 0 : 1)
    }
    property real autoContentTransparency: 0.9
    property real backgroundTransparency: Config?.options.appearance.transparency.enable ? Config?.options.appearance.transparency.automatic ? autoBackgroundTransparency : Config?.options.appearance.transparency.backgroundTransparency : 0
    property real contentTransparency: Config?.options.appearance.transparency.automatic ? autoContentTransparency : Config?.options.appearance.transparency.contentTransparency

    // ── The top bar's own surface ─────────────────────────────────────────
    // Its OWN grey and its OWN alpha, deliberately not the terminal's numbers.
    //
    // The bar and the terminal want the same RESULT -- two near-black surfaces
    // that read as the same family -- and they get there by different routes.
    // The terminal is `#242424` at 0.8; the bar is a step closer to black at
    // `#1e1e1e`, which needs a slightly higher alpha to land in the same
    // place once blended over the wallpaper. Rendering them is the only way to
    // compare them: 0.8 x 0x24 = 29 for the terminal, 0.85 x 0x1e = 26 for the
    // bar -- a three-point difference, invisible side by side, where copying
    // the terminal's numbers had the bar sitting a full shade off it.
    //
    // Two habits kept here on purpose:
    //
    //   · A LITERAL hex, never `ColorUtils.mix`. The old bar was built from a
    //     mix factor, and `mix(c1, c2, p)` weights its FIRST argument -- so the
    //     number that said "18% toward black" was producing 82%, and the bar
    //     came out #030303. There is no arithmetic here to get backwards.
    //   · The alpha is written out next to the colour, so the two that have to
    //     agree on screen are never edited apart.
    //
    // The terminal's pair lives in `ColorUtils` (it is the terminal's own
    // config, mirrored by ~/.config/kitty/kitty.conf). Nothing here reads it,
    // and nothing there reads this: they are two pairs that must MATCH by eye,
    // not one number written twice.
    // FOLLOW THE THEME. This has to be a binding on `m3colors.darkmode`, not a
    // fixed literal.
    //
    // It was a literal `#d6d6d6`, and that broke the light/dark toggle in a way
    // that looked like the rest of the shell was fine: switching back to dark
    // repainted every panel from the dark palette, and left the bar a light
    // grey slab in the middle of a dark desktop. The bar was the one surface
    // in the shell not reading the palette, so it had nothing to switch with.
    //
    // The light value is darker than the darkest container tone on purpose
    // (#C6C6C6 in the light ladder): the bar is its own surface, and a bar
    // that sits inside the panel ladder reads as one more panel.
    property color barGrey: m3colors.darkmode ? "#161616" : "#c6c6c6"
    property real barOpacity: m3colors.darkmode ? 0.88 : 0.92
    //

    m3colors: QtObject {
        property bool darkmode: false
        property bool transparent: false
        property color m3background: "#141313"
        property color m3onBackground: "#e6e1e1"
        property color m3surface: "#141313"
        property color m3surfaceDim: "#141313"
        property color m3surfaceBright: "#3a3939"
        property color m3surfaceContainerLowest: "#0f0e0e"
        property color m3surfaceContainerLow: "#1c1b1c"
        property color m3surfaceContainer: "#201f20"
        property color m3surfaceContainerHigh: "#2b2a2a"
        property color m3surfaceContainerHighest: "#363435"
        property color m3onSurface: "#e6e1e1"
        property color m3surfaceVariant: "#49464a"
        property color m3onSurfaceVariant: "#cbc5ca"
        property color m3inverseSurface: "#e6e1e1"
        property color m3inverseOnSurface: "#313030"
        property color m3outline: "#948f94"
        property color m3outlineVariant: "#49464a"
        property color m3shadow: "#000000"
        property color m3scrim: "#000000"
        property color m3surfaceTint: "#cbc4cb"
        property color m3primary: "#cbc4cb"
        property color m3onPrimary: "#322f34"
        property color m3primaryContainer: "#2d2a2f"
        property color m3onPrimaryContainer: "#bcb6bc"
        property color m3inversePrimary: "#615d63"
        property color m3secondary: "#cac5c8"
        property color m3onSecondary: "#323032"
        property color m3secondaryContainer: "#4d4b4d"
        property color m3onSecondaryContainer: "#ece6e9"
        property color m3tertiary: "#d1c3c6"
        property color m3onTertiary: "#372e30"
        property color m3tertiaryContainer: "#31292b"
        property color m3onTertiaryContainer: "#c1b4b7"
        property color m3error: "#ffb4ab"
        property color m3onError: "#690005"
        property color m3errorContainer: "#93000a"
        property color m3onErrorContainer: "#ffdad6"
        property color m3primaryFixed: "#e7e0e7"
        property color m3primaryFixedDim: "#cbc4cb"
        property color m3onPrimaryFixed: "#1d1b1f"
        property color m3onPrimaryFixedVariant: "#49454b"
        property color m3secondaryFixed: "#e6e1e4"
        property color m3secondaryFixedDim: "#cac5c8"
        property color m3onSecondaryFixed: "#1d1b1d"
        property color m3onSecondaryFixedVariant: "#484648"
        property color m3tertiaryFixed: "#eddfe1"
        property color m3tertiaryFixedDim: "#d1c3c6"
        property color m3onTertiaryFixed: "#211a1c"
        property color m3onTertiaryFixedVariant: "#4e4447"
        property color m3success: "#B5CCBA"
        property color m3onSuccess: "#213528"
        property color m3successContainer: "#374B3E"
        property color m3onSuccessContainer: "#D1E9D6"
        property color term0: "#CFCFCF"
        property color term1: "#B52755"
        property color term2: "#A97363"
        property color term3: "#AF535D"
        property color term4: "#A67F7C"
        property color term5: "#B2416B"
        property color term6: "#8D76AD"
        property color term7: "#272022"
        property color term8: "#0E0D0D"
        property color term9: "#B52755"
        property color term10: "#A97363"
        property color term11: "#AF535D"
        property color term12: "#A67F7C"
        property color term13: "#B2416B"
        property color term14: "#8D76AD"
        property color term15: "#221A1A"
    }

    colors: QtObject {
        // Subtext is a LABEL colour, so it is held to text contrast, not to
        // border contrast. It used to be `m3outline` (#747474 in the light
        // palette), which is a border tone: 4.4:1 on a panel and 4.2:1 on the
        // bar -- under the 4.5:1 that body text is supposed to clear, and on
        // anything lighter it disappears. `m3onSurfaceVariant` is the palette's
        // own "secondary text" role (#474747) and lands around 8.7:1.
        //
        // This one line covers all ~190 subtext uses in the shell, which is
        // why the fix belongs here and not in the widgets.
        property color colSubtext: m3colors.m3onSurfaceVariant
        // Layer 0
        property color colLayer0Base: ColorUtils.mix(m3colors.m3background, m3colors.m3primary, Config.options.appearance.extraBackgroundTint ? 0.99 : 1)
        property color colLayer0: ColorUtils.transparentize(colLayer0Base, root.backgroundTransparency)
        property color colOnLayer0: m3colors.m3onBackground
        property color colLayer0Hover: ColorUtils.transparentize(ColorUtils.mix(colLayer0, colOnLayer0, 0.9, root.contentTransparency))
        property color colLayer0Active: ColorUtils.transparentize(ColorUtils.mix(colLayer0, colOnLayer0, 0.8, root.contentTransparency))
        property color colLayer0Border: ColorUtils.mix(root.m3colors.m3outlineVariant, colLayer0, 0.4)
        // ── The BAR's own background ──────────────────────────────────────
        // The top bar does NOT use `colLayer0`, and that is the whole point of
        // this colour. `colLayer0` is every panel, dialog, lock screen and
        // sidebar in the shell -- recolouring it to taste the bar would repaint
        // the entire interface.
        //
        // The bar's surface: its own grey at its own alpha -- see `barGrey` and
        // `barOpacity` on the root for why the bar does not simply borrow the
        // terminal's pair, and what the two come out at once blended.
        //
        // `applyAlpha` rather than `Qt.rgba(color, a)`, for the same reason the
        // terminal's own token uses it: the two-argument form of `Qt.rgba` is
        // not an alpha setter (it wants four components) and returns a colour
        // with no alpha in it, which paints nothing at all.
        property color colBarBackground: ColorUtils.applyAlpha(
            root.barGrey, root.barOpacity)
        // ── The terminal-family surfaces ────────────────────────────────
        // The settings window, the task manager, the music player and their
        // fullscreen window hosts all paint the TERMINAL's grey, so they read
        // as one family with a terminal window instead of as four apps that
        // happen to be similar.
        //
        // It lives HERE, not in `ColorUtils`, and that is the whole point of
        // the fix: the token used to be a literal `#CFCFCF` in ColorUtils, so
        // switching the shell to dark repainted every palette-driven surface
        // and left these four light. A light settings window over a dark
        // desktop is the "mixed themes" report exactly.
        //
        // `ColorUtils` cannot see `m3colors.darkmode` -- importing Appearance
        // there would close a cycle (Appearance already imports ColorUtils) --
        // so the token belongs on the object that knows what mode it is in.
        // One home, and the mode is a BINDING, so nothing can forget to follow.
        //
        // The dark value is the terminal's own dark grey at the same glass.
        readonly property color colTerminalSurface: ColorUtils.applyAlpha(
            m3colors.darkmode ? "#141414" : "#DCDCDC",
            m3colors.darkmode ? 0.9 : 0.92)
        // The same grey with no transparency: the morphing end of the settings
        // and task-manager cards, which must land pixel-identical on the
        // fullscreen window host that replaces them.
        readonly property color colTerminalSurfaceSolid: ColorUtils.applyAlpha(
            m3colors.darkmode ? "#141414" : "#DCDCDC", 1)
        // The bar's hairline, derived from ITS background rather than
        // colLayer0's -- otherwise the outline is tinted for a surface the
        // bar no longer uses, and on a light wallpaper the capsule shows a
        // dark rim it should not have.
        //
        // Built from `m3outline`, NOT `m3outlineVariant`. This is the light
        // theme's "no depth" bug in one line: `m3outlineVariant` is #C6C6C6 on
        // a #E2E2E2 bar -- 1.6:1, a hairline you cannot see. A bar with no
        // visible edge has no surface; it is a flat patch of grey with some
        // icons on it. `m3outline` (#747474) mixed 70% toward the bar lands
        // near #959595, ~2.9:1, which is a real edge that still recedes.
        property color colBarBackgroundBorder: ColorUtils.mix(
            root.m3colors.m3outline, colBarBackground, 0.85)
        // Layer 1
        property color colLayer1Base: m3colors.m3surfaceContainerLow
        property color colLayer1: ColorUtils.solveOverlayColor(colLayer0Base, colLayer1Base, 1 - root.contentTransparency);
        property color colOnLayer1: m3colors.m3onSurfaceVariant;
        property color colOnLayer1Inactive: ColorUtils.mix(colOnLayer1, colLayer1, 0.45);
        property color colLayer1Hover: ColorUtils.transparentize(ColorUtils.mix(colLayer1, colOnLayer1, 0.92), root.contentTransparency)
        property color colLayer1Active: ColorUtils.transparentize(ColorUtils.mix(colLayer1, colOnLayer1, 0.85), root.contentTransparency);
        // Layer 2
        property color colLayer2Base: m3colors.m3surfaceContainer
        property color colLayer2: ColorUtils.solveOverlayColor(colLayer1Base, colLayer2Base, 1 - root.contentTransparency)
        property color colLayer2Hover: ColorUtils.solveOverlayColor(colLayer1Base, ColorUtils.mix(colLayer2Base, colOnLayer2, 0.90), 1 - root.contentTransparency)
        property color colLayer2Active: ColorUtils.solveOverlayColor(colLayer1Base, ColorUtils.mix(colLayer2Base, colOnLayer2, 0.80), 1 - root.contentTransparency);
        property color colLayer2Disabled: ColorUtils.solveOverlayColor(colLayer1Base, ColorUtils.mix(colLayer2Base, m3colors.m3background, 0.8), 1 - root.contentTransparency);
        property color colOnLayer2: m3colors.m3onSurface;
        property color colOnLayer2Disabled: ColorUtils.mix(colOnLayer2, m3colors.m3background, 0.4);
        // Layer 3
        property color colLayer3Base: m3colors.m3surfaceContainerHigh
        property color colLayer3: ColorUtils.solveOverlayColor(colLayer2Base, colLayer3Base, 1 - root.contentTransparency)
        property color colLayer3Hover: ColorUtils.solveOverlayColor(colLayer2Base, ColorUtils.mix(colLayer3Base, colOnLayer3, 0.90), 1 - root.contentTransparency)
        property color colLayer3Active: ColorUtils.solveOverlayColor(colLayer2Base, ColorUtils.mix(colLayer3Base, colOnLayer3, 0.80), 1 - root.contentTransparency);
        property color colOnLayer3: m3colors.m3onSurface;
        // Layer 4
        property color colLayer4Base: m3colors.m3surfaceContainerHighest
        property color colLayer4: ColorUtils.solveOverlayColor(colLayer3Base, colLayer4Base, 1 - root.contentTransparency)
        property color colLayer4Hover: ColorUtils.solveOverlayColor(colLayer3Base, ColorUtils.mix(colLayer4Base, colOnLayer4, 0.90), 1 - root.contentTransparency)
        property color colLayer4Active: ColorUtils.solveOverlayColor(colLayer3Base, ColorUtils.mix(colLayer4Base, colOnLayer4, 0.80), 1 - root.contentTransparency);
        property color colOnLayer4: m3colors.m3onSurface;
        // Primary
        property color colPrimary: m3colors.m3primary
        property color colOnPrimary: m3colors.m3onPrimary
        property color colPrimaryHover: ColorUtils.mix(colors.colPrimary, colLayer1Hover, 0.87)
        property color colPrimaryActive: ColorUtils.mix(colors.colPrimary, colLayer1Active, 0.7)
        property color colPrimaryContainer: m3colors.m3primaryContainer
        property color colPrimaryContainerHover: ColorUtils.mix(colors.colPrimaryContainer, colors.colOnPrimaryContainer, 0.9)
        property color colPrimaryContainerActive: ColorUtils.mix(colors.colPrimaryContainer, colors.colOnPrimaryContainer, 0.8)
        property color colOnPrimaryContainer: m3colors.m3onPrimaryContainer
        // Secondary
        property color colSecondary: m3colors.m3secondary
        property color colSecondaryHover: ColorUtils.mix(m3colors.m3secondary, colLayer1Hover, 0.85)
        property color colSecondaryActive: ColorUtils.mix(m3colors.m3secondary, colLayer1Active, 0.4)
        property color colOnSecondary: m3colors.m3onSecondary
        property color colSecondaryContainer: m3colors.m3secondaryContainer
        property color colSecondaryContainerHover: ColorUtils.mix(m3colors.m3secondaryContainer, m3colors.m3onSecondaryContainer, 0.90)
        property color colSecondaryContainerActive: ColorUtils.mix(m3colors.m3secondaryContainer, m3colors.m3onSecondaryContainer, 0.54)
        property color colOnSecondaryContainer: m3colors.m3onSecondaryContainer
        // Tertiary
        property color colTertiary: m3colors.m3tertiary
        property color colTertiaryHover: ColorUtils.mix(m3colors.m3tertiary, colLayer1Hover, 0.85)
        property color colTertiaryActive: ColorUtils.mix(m3colors.m3tertiary, colLayer1Active, 0.4)
        property color colTertiaryContainer: m3colors.m3tertiaryContainer
        property color colTertiaryContainerHover: ColorUtils.mix(m3colors.m3tertiaryContainer, m3colors.m3onTertiaryContainer, 0.90)
        property color colTertiaryContainerActive: ColorUtils.mix(m3colors.m3tertiaryContainer, colLayer1Active, 0.54)
        property color colOnTertiary: m3colors.m3onTertiary
        property color colOnTertiaryContainer: m3colors.m3onTertiaryContainer
        // Surface
        property color colBackgroundSurfaceContainer: ColorUtils.transparentize(m3colors.m3surfaceContainer, root.backgroundTransparency)
        property color colSurfaceContainerLow: ColorUtils.solveOverlayColor(m3colors.m3background, m3colors.m3surfaceContainerLow, 1 - root.contentTransparency)
        property color colSurfaceContainer: ColorUtils.solveOverlayColor(m3colors.m3surfaceContainerLow, m3colors.m3surfaceContainer, 1 - root.contentTransparency)
        property color colSurfaceContainerHigh: ColorUtils.solveOverlayColor(m3colors.m3surfaceContainer, m3colors.m3surfaceContainerHigh, 1 - root.contentTransparency)
        property color colSurfaceContainerHighest: ColorUtils.solveOverlayColor(m3colors.m3surfaceContainerHigh, m3colors.m3surfaceContainerHighest, 1 - root.contentTransparency)
        property color colSurfaceContainerHighestHover: ColorUtils.mix(m3colors.m3surfaceContainerHighest, m3colors.m3onSurface, 0.95)
        property color colSurfaceContainerHighestActive: ColorUtils.mix(m3colors.m3surfaceContainerHighest, m3colors.m3onSurface, 0.85)
        property color colOnSurface: m3colors.m3onSurface
        property color colOnSurfaceVariant: m3colors.m3onSurfaceVariant
        // Misc
        property color colTooltip: m3colors.m3inverseSurface
        property color colOnTooltip: m3colors.m3inverseOnSurface
        property color colScrim: ColorUtils.transparentize(m3colors.m3scrim, 0.5)
        property color colShadow: ColorUtils.transparentize(m3colors.m3shadow, 0.7)
        property color colOutline: m3colors.m3outline
        property color colOutlineVariant: m3colors.m3outlineVariant
        property color colError: m3colors.m3error
        property color colErrorHover: ColorUtils.mix(m3colors.m3error, colLayer1Hover, 0.85)
        property color colErrorActive: ColorUtils.mix(m3colors.m3error, colLayer1Active, 0.7)
        property color colOnError: m3colors.m3onError
        property color colErrorContainer: m3colors.m3errorContainer
        property color colErrorContainerHover: ColorUtils.mix(m3colors.m3errorContainer, m3colors.m3onErrorContainer, 0.90)
        property color colErrorContainerActive: ColorUtils.mix(m3colors.m3errorContainer, m3colors.m3onErrorContainer, 0.70)
        property color colOnErrorContainer: m3colors.m3onErrorContainer
    }

    // ── Style template ───────────────────────────────────────────────────
    // Settings > Appearance > Theme > Style stores a slug in
    // Config.options.appearance.styleTemplate ("" = Material default). A
    // template reshapes the shell -- corner rounding, the bottom bar's
    // geometry, panel card treatment -- WITHOUT touching any behaviour, any
    // feature, or any Hyprland configuration: it only changes what these
    // shared Appearance values resolve to, and every widget in the shell
    // reads those.
    function resolvedStyleShape(slug) {
        const t = root.styles.find(s => s.slug === slug);
        return t ? t.shape : {};
    }

    readonly property string styleSlug: Config.options.appearance.styleTemplate ?? ""
    readonly property var styleShape: root.resolvedStyleShape(root.styleSlug)
    readonly property var styles: [
        {
            slug: "",
            name: "Material",
            description: "The tuned Material look this desktop ships with: soft corners, standard floating bottom bar.",
            swatch: ["#d1c2d2", "#211f20", "#675d68"],
            shape: {},
        },
        {
            slug: "sharp",
            name: "Sharp",
            description: "Architectural and exact: square corners everywhere -- buttons, cards, popups and the bar read as flat slabs.",
            swatch: ["#e7e1e3", "#191919", "#8a8a8a"],
            shape: {
                unsharpen: 0, unsharpenmore: 0, verysmall: 0, small: 1,
                normal: 2, large: 3, verylarge: 4,
                screenRounding: 3, windowRounding: 2,
            },
        },
        {
            slug: "arctic",
            name: "Arctic",
            description: "Cool and glassy: extra-round buttons and panels, soft screen corners, a gentle rounded bar.",
            swatch: ["#c3d6e8", "#1a222c", "#5b6b7a"],
            shape: {
                unsharpen: 4, unsharpenmore: 6, verysmall: 8, small: 11,
                normal: 14, large: 18, verylarge: 24,
                screenRounding: 18, windowRounding: 14,
            },
        },
        {
            slug: "brutal",
            name: "Brutal",
            description: "Bold and direct: heavy slabs, near-square corners, thick lines and a slab-like bar.",
            swatch: ["#f0e6c8", "#241f1a", "#a08a5a"],
            shape: {
                unsharpen: 1, unsharpenmore: 1, verysmall: 2, small: 3,
                normal: 4, large: 5, verylarge: 6,
                screenRounding: 4, windowRounding: 4,
            },
        },
        {
            slug: "ink",
            name: "Ink",
            description: "Calm and understated: slightly tighter corners everywhere, a slim rounded bar, quiet geometry.",
            swatch: ["#d8d3cc", "#181818", "#6f6a64"],
            shape: {
                unsharpen: 1, unsharpenmore: 2, verysmall: 3, small: 5,
                normal: 6, large: 8, verylarge: 11,
                screenRounding: 8, windowRounding: 6,
            },
        },
    ]

    readonly property var activeStyle: root.styles.find(s => s.slug === root.styleSlug) ?? root.styles[0]

    // Corner radii -- the whole UI's shared shape dial.
    //
    // These are not constants: they come from the style template above, which
    // reshapes every widget in the shell without touching behaviour or any
    // Hyprland configuration. The baseline is the tuned-down Material set this
    // shell shipped with (the original 5/8/11/15/20 read as pills at desktop
    // density; two thirds keeps corners visibly soft without the bubble look).
    //
    // `full` is not a radius, it is "make it a pill" -- the navigation-rail
    // highlight and the circular icon buttons depend on it, so templates may
    // not override it. screenRounding/windowRounding follow the template so
    // the screen mask stays coherent with the rest.
    rounding: QtObject {
        readonly property var _tpl: root.styleShape
        property int unsharpen: _tpl.unsharpen ?? 2
        property int unsharpenmore: _tpl.unsharpenmore ?? 3
        property int verysmall: _tpl.verysmall ?? 4
        property int small: _tpl.small ?? 6
        property int normal: _tpl.normal ?? 8
        property int large: _tpl.large ?? 10
        property int verylarge: _tpl.verylarge ?? 14
        property int full: 9999
        property int screenRounding: _tpl.screenRounding ?? large
        property int windowRounding: _tpl.windowRounding ?? 8
    }

    font: QtObject {
        property QtObject family: QtObject {
            property string main: Config.options.appearance.fonts.main
            property string numbers: Config.options.appearance.fonts.numbers
            property string title: Config.options.appearance.fonts.title
            property string iconMaterial: "Material Symbols Rounded"
            property string iconNerd: Config.options.appearance.fonts.iconNerd
            property string monospace: Config.options.appearance.fonts.monospace
            property string reading: Config.options.appearance.fonts.reading
            property string expressive: Config.options.appearance.fonts.expressive
        }
        property QtObject variableAxes: QtObject {
            property var main: ({
                "wght": 450,
                "wdth": 100,
            })
            property var numbers: ({
                "wght": 450,
            })
            property var title: ({ // Slightly bold weight for title
                "wght": 550, // Weight (Lowered to compensate for increased grade)
            })
        }
        property QtObject pixelSize: QtObject {
            // ── Accessibility text scale ──
            // Every UI text size in the shell flows through these values, so a
            // single multiplier rescales the whole interface. Binds live to
            // config.options.appearance.textScale so the slider takes effect
            // immediately, no reload.
            readonly property real scale: Math.min(1.6, Math.max(0.7, Config.options?.appearance?.textScale ?? 1.0))
            function scaled(v) { return Math.round(v * scale) }
            property int smallest: scaled(10)
            // `tiny` is what twenty-odd widgets already ask for (the popups, the
            // island, the file manager's metadata rows). It was never defined,
            // so every one of those bindings failed with "Unable to assign
            // [undefined] to int" and the text silently kept the inherited
            // size. Defined here as the smallest step rather than rewriting the
            // call sites: one line, and the shell's journal stops lying about
            // it on every repaint.
            property int tiny: smallest
            property int smaller: scaled(12)
            property int smallie: scaled(13)
            property int small: scaled(15)
            property int normal: scaled(16)
            property int large: scaled(17)
            property int larger: scaled(19)
            property int huge: scaled(22)
            property int hugeass: scaled(23)
            property int title: huge
        }
    }

    animationCurves: QtObject {
        // ── Motion budget ────────────────────────────────────────────────────
        // Every duration in the shell is "the number below x motionScale", so
        // one switch shortens the lot instead of each widget having its own idea
        // of what "fast" is. Performance power mode (Settings > General >
        // Power & idle, or battery.powerMode in the config) drops this to 0.12:
        // a 400ms slide becomes 48ms -- still a transition, because an instant
        // jump is harder to follow than a short one, but never something you
        // wait for.
        readonly property real motionScale: (Config.options?.battery?.powerMode ?? "default") === "performance" ? 0.12 : 1

        readonly property list<real> expressiveFastSpatial: [0.42, 1.67, 0.21, 0.90, 1, 1] // Default, 350ms
        readonly property list<real> expressiveDefaultSpatial: [0.38, 1.21, 0.22, 1.00, 1, 1] // Default, 500ms
        readonly property list<real> expressiveSlowSpatial: [0.39, 1.29, 0.35, 0.98, 1, 1] // Default, 650ms
        readonly property list<real> expressiveEffects: [0.34, 0.80, 0.34, 1.00, 1, 1] // Default, 200ms
        readonly property list<real> emphasized: [0.05, 0, 2 / 15, 0.06, 1 / 6, 0.4, 5 / 24, 0.82, 0.25, 1, 1, 1]
        readonly property list<real> emphasizedFirstHalf: [0.05, 0, 2 / 15, 0.06, 1 / 6, 0.4, 5 / 24, 0.82]
        readonly property list<real> emphasizedLastHalf: [5 / 24, 0.82, 0.25, 1, 1, 1]
        readonly property list<real> emphasizedAccel: [0.3, 0, 0.8, 0.15, 1, 1]
        readonly property list<real> emphasizedDecel: [0.05, 0.7, 0.1, 1, 1, 1]
        readonly property list<real> standard: [0.2, 0, 0, 1, 1, 1]
        readonly property list<real> standardAccel: [0.3, 0, 1, 1, 1, 1]
        readonly property list<real> standardDecel: [0, 0, 0, 1, 1, 1]
        readonly property real expressiveFastSpatialDuration: 350 * motionScale
        readonly property real expressiveDefaultSpatialDuration: 500 * motionScale
        readonly property real expressiveSlowSpatialDuration: 650 * motionScale
        readonly property real expressiveEffectsDuration: 200 * motionScale
    }

    animation: QtObject {
        property QtObject elementMove: QtObject {
            property int duration: animationCurves.expressiveDefaultSpatialDuration
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.expressiveDefaultSpatial
            property int velocity: 650
            property Component numberAnimation: Component {
                NumberAnimation {
                    duration: root.animation.elementMove.duration
                    easing.type: root.animation.elementMove.type
                    easing.bezierCurve: root.animation.elementMove.bezierCurve
                }
            }
        }

        property QtObject elementMoveSmall: QtObject {
            property int duration: animationCurves.expressiveFastSpatialDuration
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.expressiveFastSpatial
            property int velocity: 650
            property Component numberAnimation: Component {
                NumberAnimation {
                    duration: root.animation.elementMoveSmall.duration
                    easing.type: root.animation.elementMoveSmall.type
                    easing.bezierCurve: root.animation.elementMoveSmall.bezierCurve
                }
            }
        }

        property QtObject elementMoveEnter: QtObject {
            property int duration: Math.round(400 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.emphasizedDecel
            property int velocity: 650
            property Component numberAnimation: Component {
                NumberAnimation {
                    alwaysRunToEnd: true
                    duration: root.animation.elementMoveEnter.duration
                    easing.type: root.animation.elementMoveEnter.type
                    easing.bezierCurve: root.animation.elementMoveEnter.bezierCurve
                }
            }
        }

        property QtObject elementMoveExit: QtObject {
            property int duration: Math.round(200 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.emphasizedAccel
            property int velocity: 650
            property Component numberAnimation: Component {
                NumberAnimation {
                    alwaysRunToEnd: true
                    duration: root.animation.elementMoveExit.duration
                    easing.type: root.animation.elementMoveExit.type
                    easing.bezierCurve: root.animation.elementMoveExit.bezierCurve
                }
            }
        }

        // ── The sidebar reveal ─────────────────────────────────────────
        // A pair of its own, because neither of the two above is the right
        // answer for a panel that is a CONTROL rather than a flourish.
        //
        // elementMoveEnter is 400ms of emphasizedDecel. That is a lovely
        // curve for something that arrives once and then stays put, and a
        // long wait for a sidebar: these are opened by brushing the screen
        // edge and dismissed by moving away again, so the motion is not
        // something the eye rests on -- it is the response time of a
        // control, and it is usually paid twice in a row (out, then back
        // again a moment later). Same curve family, roughly half the
        // length, so the settle survives and the dead time does not.
        //
        // The exit is shorter still and accelerates, because a panel on its
        // way out should be gone before the hand that dismissed it looks
        // back. Both are scaled by motionScale like every other duration
        // here, so the performance power mode still applies.
        property QtObject sidebarRevealEnter: QtObject {
            property int duration: Math.round(200 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.emphasizedDecel
            property int velocity: 900
            property Component numberAnimation: Component {
                NumberAnimation {
                    alwaysRunToEnd: true
                    duration: root.animation.sidebarRevealEnter.duration
                    easing.type: root.animation.sidebarRevealEnter.type
                    easing.bezierCurve: root.animation.sidebarRevealEnter.bezierCurve
                }
            }
        }

        property QtObject sidebarRevealExit: QtObject {
            property int duration: Math.round(150 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.emphasizedAccel
            property int velocity: 900
            property Component numberAnimation: Component {
                NumberAnimation {
                    alwaysRunToEnd: true
                    duration: root.animation.sidebarRevealExit.duration
                    easing.type: root.animation.sidebarRevealExit.type
                    easing.bezierCurve: root.animation.sidebarRevealExit.bezierCurve
                }
            }
        }

        property QtObject elementMoveFast: QtObject {
            property int duration: animationCurves.expressiveEffectsDuration
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.expressiveEffects
            property int velocity: 850
            property Component colorAnimation: Component { ColorAnimation {
                duration: root.animation.elementMoveFast.duration
                easing.type: root.animation.elementMoveFast.type
                easing.bezierCurve: root.animation.elementMoveFast.bezierCurve
            }}
            property Component numberAnimation: Component { NumberAnimation {
                alwaysRunToEnd: true
                duration: root.animation.elementMoveFast.duration
                easing.type: root.animation.elementMoveFast.type
                easing.bezierCurve: root.animation.elementMoveFast.bezierCurve
            }}
        }

        property QtObject elementResize: QtObject {
            property int duration: Math.round(300 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.emphasized
            property int velocity: 650
            property Component numberAnimation: Component {
                NumberAnimation {
                    alwaysRunToEnd: true
                    duration: root.animation.elementResize.duration
                    easing.type: root.animation.elementResize.type
                    easing.bezierCurve: root.animation.elementResize.bezierCurve
                }
            }
        }

        property QtObject clickBounce: QtObject {
            property int duration: Math.round(400 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: animationCurves.expressiveDefaultSpatial
            property int velocity: 850
            property Component numberAnimation: Component { NumberAnimation {
                alwaysRunToEnd: true
                duration: root.animation.clickBounce.duration
                easing.type: root.animation.clickBounce.type
                easing.bezierCurve: root.animation.clickBounce.bezierCurve
            }}
        }
        
        property QtObject scroll: QtObject {
            property int duration: Math.round(200 * animationCurves.motionScale)
            property int type: Easing.BezierSpline
            property list<real> bezierCurve: root.animationCurves.standardDecel
        }

        property QtObject menuDecel: QtObject {
            property int duration: Math.round(350 * animationCurves.motionScale)
            property int type: Easing.OutExpo
        }
    }

    sizes: QtObject {
        property real baseBarHeight: 40
        property real barHeight: Config.options.bar.cornerStyle === 1 ? 
            (baseBarHeight + root.sizes.hyprlandGapsOut * 2) : baseBarHeight
        // The liquid droplet: how far the small curved section under a
        // hovered status icon can hang before it rubber-bands back.
        // How far the liquid pocket's droplet hangs below the bar. The content
        // inside it starts 4px lower (on the bar's painted bottom edge), so
        // this is 4px more than the height the content itself gets.
        property real barPocketHeight: 68
        property real barCenterSideModuleWidth: Config.options?.bar.verbose ? 360 : 140
        property real barCenterSideModuleWidthShortened: 280
        property real barCenterSideModuleWidthHellaShortened: 190
        property real barShortenScreenWidthThreshold: 1200 // Shorten if screen width is at most this value
        property real barHellaShortenScreenWidthThreshold: 1000 // Shorten even more...
        property real elevationMargin: 10
        // The outermost sliver of the screen belongs to the edge-reveal strips,
        // not to the panels they open: the sidebars' input regions stop short
        // of it (see SidebarLeft/SidebarRight) so the same few pixels that
        // summon a sidebar by hovering are also the ones that take the click
        // that sends it back. One number, three files, no drift.
        property real edgeRevealStripWidth: 10
        property real fabShadowRadius: 5
        property real fabHoveredShadowRadius: 7
        property real hyprlandGapsOut: 5
        property real notificationPopupWidth: 410
        property real osdWidth: 180
        property real searchWidthCollapsed: 210
        property real searchWidth: 360
        // Sidebar widths.
        //
        // `sidebarWidth` is both sidebars' normal width; the left one widens to
        // `sidebarWidthExtended` only while its chat is expanded, which is the one
        // view that genuinely needs the room. These came down twice: 460/750 was
        // the original, then 400/660, and both still left the quick-toggle rows
        // with a wide empty gutter, because the rows inside are icon + label and
        // do not grow with the panel.
        // Widths are adjustable from Settings > Sidebars now, so the numbers
        // live in the shell config and these just default when it is unset.
        property real sidebarWidth: Config.options.sidebar.width ?? 480
        property real sidebarWidthExtended: root.sizes.sidebarWidth + 220
        property real baseVerticalBarWidth: 46
        property real verticalBarWidth: Config.options.bar.cornerStyle === 1 ? 
            (baseVerticalBarWidth + root.sizes.hyprlandGapsOut * 2) : baseVerticalBarWidth
        property real wallpaperSelectorWidth: 1200
        property real wallpaperSelectorHeight: 690
        property real wallpaperSelectorItemMargins: 8
        property real wallpaperSelectorItemPadding: 6
    }

    syntaxHighlightingTheme: root.m3colors.darkmode ? "Monokai" : "ayu Light"
}


