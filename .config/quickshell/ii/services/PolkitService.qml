pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Polkit
// The notification sound, the shared switch that silences it, and the player
// that applies the system sound volume and mute. The same three things a real
// notification uses, so that "the notification sound" means one thing in this
// shell rather than two.
import qs.services
import qs.modules.common

Singleton {
    id: root
    property alias agent: polkitAgent
    property alias active: polkitAgent.isActive
    property alias flow: polkitAgent.flow
    property bool interactionAvailable: false
    property string cleanMessage: {
        if (!root.flow) return "";
        return root.flow.message.endsWith(".")
            ? root.flow.message.slice(0, -1)
            : root.flow.message
    }
    property string cleanPrompt: {
        const inputPrompt = PolkitService.flow?.inputPrompt.trim() ?? "";
        const cleanedInputPrompt = inputPrompt.endsWith(":") ? inputPrompt.slice(0, -1) : inputPrompt;
        const usePasswordChars = !PolkitService.flow?.responseVisible ?? true
        return cleanedInputPrompt || (usePasswordChars ? Translation.tr("Password") : Translation.tr("Input"))
    }

    // ── The request announces itself, in sound only ───────────────────
    //
    // The prompt is a fullscreen dialog that appears without announcing
    // itself: it waits, silently, and the report was that it can sit there
    // unnoticed. This is the whole answer to that -- no banner, no toast, no
    // card, nothing on screen: the dialog is already there, and the sound
    // only says that it is.
    //
    // It rides the NOTIFICATION sound rather than a file of its own, so the
    // `notifications.sound` switch that already silences notifications
    // silences this too, and `Audio.playSystemSoundFile` applies the system
    // sound volume and mute for it (and does nothing at all when muted).
    //
    // The same file, at the same level: the level lives on the chime
    // (`Notifications.notificationGain`, +5 dB so it reads over music), and a
    // prompt that is scored quieter than the notifications it is made of would
    // be the one sound in the session you cannot hear.
    function playRequestSound() {
        if (!(Config?.options.notifications.sound ?? true))
            return;
        Audio.playSystemSoundFile(Notifications.defaultNotifSound, Notifications.notificationGain);
    }

    function cancel() {
        root.flow.cancelAuthenticationRequest()
    }

    function submit(string) {
        root.flow.submit(string)
        root.interactionAvailable = false
    }

    Connections {
        target: root.flow
        function onAuthenticationFailed() {
            root.interactionAvailable = true;
        }
    }

    PolkitAgent {
        id: polkitAgent
        onAuthenticationRequestStarted: {
            root.interactionAvailable = true;
            // The same instant the dialog comes up, so the sound is what tells
            // you it did. Fired per REQUEST, not per attempt: a wrong password
            // comes back through onAuthenticationFailed below and does not
            // make a second noise at you.
            root.playRequestSound();
        }
    }
}
