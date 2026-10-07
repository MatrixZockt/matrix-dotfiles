-- Launch WhatsApp Desktop directly via SUPER+Shift+W.
-- Bypasses the app-search catalogue entirely, so this always works
-- regardless of whether DesktopEntries picked up the desktop file.
-- The real binary lives in a path with a space, so use the no-space wrapper.
hl.bind("SUPER + SHIFT + W", hl.dsp.exec_cmd("/opt/whatsapp-linux-desktop/bin/whatsapp-linux-desktop"), { description = "App: WhatsApp Desktop" })
