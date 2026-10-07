import QtQuick
import Quickshell
import qs
import qs.modules.common

// The wallpaper pill is RETIRED (2026-09-26, by request): the floating
// "Wallpaper" capsule at the bottom of an empty desktop is gone.
//
// Everything it used to host moved to its natural homes:
//   * the coverflow "theatre" now lives only in WallpaperModal (unchanged),
//     opened by PINCHING OUT on the touchpad while the desktop is empty and
//     closed by pinching in (the compositor-side gestures live in
//     hyprland/custom/general.lua) -- or from the left sidebar's Wallpaper
//     widget card and the Settings page;
//   * the "add wallpaper" picker machinery moved into WallpaperModal, which
//     now answers GlobalStates.requestWallpaperAdd itself;
//   * (the sidebar WidgetsBoard that used to edit this widget is deleted).
//
// This file stays as a no-op stub because Background.qml's FadeLoader and the
// `background.widgets.wallpaper.enable` config option still reference it; an
// empty, invisible item keeps those valid without rendering anything.
AbstractBackgroundWidget {
    id: root
    configEntryName: "wallpaper"
    implicitWidth: 0
    implicitHeight: 0
    visible: false
}
