pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions as CF
import qs.modules.common.widgets

/**
 * Account.
 *
 * This page used to not exist. "Accounts" in the rail pointed at KeybindsConfig,
 * so asking for your account got you a list of shortcuts -- the search index did
 * the same, routing the words *account, user, login, password* to the keybinds
 * page. Keybinds now has its own tab (Settings -> Keybinds) and this is what the
 * rail and the search mean by an account.
 *
 * Two real jobs, one honest boundary.
 *
 * CHANGING THE PASSWORD is the system's own `passwd` doing the work, driven by
 * ~/.local/bin/ii-passwd. Nothing here needs root and nothing here touches
 * /etc/shadow: passwd is setuid, it asks PAM for the current password, and PAM
 * applies whatever policy this machine has. The page hands the three lines over
 * on a pipe and immediately forgets them -- the fields are cleared the moment the
 * change starts, and the answer comes back as one word ("OK", "ERR bad-current",
 * "ERR weak: ..."), never as your password.
 *
 * THE RECOVERY CODE is an anti-lockout tool: 20 characters from the OS random
 * source, stored only as a memory-hard scrypt hash by /usr/local/sbin/ii-recover.
 * Because the hash costs 64 MiB and ~0.2 s per guess and the code is 100 bits,
 * a copy of that file cannot be cracked. Because the file is root-owned, this
 * account cannot rewrite its own recovery secret (which would be a way to become
 * root). Generating one needs root, so it goes through pkexec and the shell's own
 * polkit prompt -- the same dialog every other privileged action on this desktop
 * uses.
 *
 * THE HONEST BOUNDARY is the last section, and it is not decoration. None of this
 * protects the disk: this machine has no LUKS anywhere, so anyone holding the
 * laptop can boot around the system and reset the password without ever meeting
 * the recovery code. The page says so, in those words, because a settings page
 * that implies otherwise is worse than no settings page.
 */
ContentPage {
    id: root
    forceWidth: true

    // ── Identity ─────────────────────────────────────────────────────────────
    // Overridable so the page can be pointed at another account when testing;
    // in the app it is you.
    property string userName: SystemInfo.username || Quickshell.env("USER") || ""
    property string homeDir: CF.FileUtils.trimFileProtocol(Directories.home)
    property string fullName: ""
    property string loginShell: ""

    // Helpers. ii-passwd is unprivileged and lives with the user's other
    // scripts; ii-recover is root-owned in /usr/local/sbin (see extras/sbin).
    readonly property string passwdHelper: `${root.homeDir}/.local/bin/ii-passwd`
    readonly property string recoverHelper: "/usr/local/sbin/ii-recover"

    // ── Password state ───────────────────────────────────────────────────────
    property string passwordChanged: ""
    property bool formOpen: false
    property string changeState: "idle" // idle | running | done | failed
    property string changeMessage: ""
    // Held only between the button press and the write into passwd's stdin, then
    // wiped. It exists at all so the text fields can be cleared immediately.
    property string pendingAnswers: ""

    // ── Recovery state ───────────────────────────────────────────────────────
    property bool recoveryInstalled: true
    property bool recoverySet: false
    property string recoveryDate: ""
    property bool recoveryBusy: false
    property string recoveryMessage: ""
    property string issuedCode: "" // shown once, after generation
    property string verifyInput: ""
    property string verifyMessage: ""
    property bool confirmRemove: false

    function refresh() {
        identityProcess.running = true;
        agingProcess.running = true;
        helperCheckProcess.running = true;
        recoveryStatusProcess.running = true;
    }

    Component.onCompleted: root.refresh()
    onUserNameChanged: root.refresh()

    // ── Who you are ──────────────────────────────────────────────────────────
    Process {
        id: identityProcess
        command: ["getent", "passwd", root.userName]
        stdout: StdioCollector {
            onStreamFinished: {
                // name:x:uid:gid:full name:home:shell
                const fields = text.trim().split(":");
                if (fields.length < 7) return;
                root.fullName = fields[4];
                root.loginShell = fields[6];
            }
        }
    }

    Process {
        id: agingProcess
        // A user may read their own aging information without privileges.
        command: ["chage", "-l", root.userName]
        stdout: StdioCollector {
            onStreamFinished: {
                const line = text.split("\n").find(l => l.startsWith("Last password change"));
                if (!line) return;
                root.passwordChanged = line.slice(line.indexOf(":") + 1).trim();
            }
        }
    }

    // ── Changing the password ────────────────────────────────────────────────
    Process {
        id: changeProcess
        stdinEnabled: true
        command: [root.passwdHelper, "--user", root.userName]
        stdout: StdioCollector { id: changeOut }
        stderr: StdioCollector { id: changeErr }

        onRunningChanged: {
            if (!changeProcess.running) return;
            changeProcess.write(root.pendingAnswers);
            root.pendingAnswers = "";
            changeProcess.stdinEnabled = false; // end of input
        }

        onExited: (exitCode, exitStatus) => {
            const line = changeOut.text.trim().split("\n").pop() ?? "";
            if (exitCode === 0 && line === "OK") {
                root.changeState = "done";
                root.changeMessage = Translation.tr("Password changed.");
                root.formOpen = false;
                root.refresh();
                return;
            }
            root.changeState = "failed";
            root.changeMessage = root.explain(line, changeErr.text);
        }
    }

    // The helper's status line, turned into something a person wants to read.
    function explain(line, stderrText) {
        if (line.startsWith("ERR bad-current"))
            return Translation.tr("That current password is not right. Nothing was changed.");
        if (line.startsWith("ERR locked"))
            return Translation.tr("Too many failed attempts: the account is locked for a few minutes.");
        if (line.startsWith("ERR mismatch"))
            return Translation.tr("The two new passwords did not match.");
        if (line.startsWith("ERR weak:"))
            return Translation.tr("The system refused that password: %1").arg(line.slice(9).trim());
        if (line.startsWith("ERR timeout"))
            return Translation.tr("passwd stopped responding. Nothing was changed.");
        if (line === "" && stderrText.trim() !== "")
            return Translation.tr("Could not run the password helper: %1").arg(stderrText.trim());
        return line === "" ? Translation.tr("The change failed. Nothing was changed.") : line;
    }

    function startPasswordChange() {
        const current = currentField.text;
        const next = newField.text;
        const confirm = confirmField.text;

        if (next.length === 0) {
            root.changeState = "failed";
            root.changeMessage = Translation.tr("Enter the new password first.");
            return;
        }
        // This machine has no pwquality policy configured (the system floor is
        // PASS_MIN_LEN=5), so passwd itself would accept something trivially
        // short. The page holds to 8 and says why rather than silently allowing
        // a one-character password to be set.
        if (next.length < 8) {
            root.changeState = "failed";
            root.changeMessage = Translation.tr("Use at least 8 characters. The system's own minimum is lower, but 8 is the point of changing it.");
            return;
        }
        if (next !== confirm) {
            root.changeState = "failed";
            root.changeMessage = Translation.tr("The two new passwords do not match.");
            return;
        }

        root.pendingAnswers = current + "\n" + next + "\n" + confirm + "\n";
        // Wipe the fields at once: the passwords live in the pipe now, not in
        // this window's text properties.
        currentField.text = "";
        newField.text = "";
        confirmField.text = "";
        root.changeState = "running";
        root.changeMessage = Translation.tr("Asking the system to change it...");
        changeProcess.stdinEnabled = true;
        changeProcess.running = true;
    }

    // ── Recovery code ────────────────────────────────────────────────────────
    // Is the root helper installed on this machine? Asked with `test -x`, which
    // always starts and so always reports an exit code -- unlike inferring it
    // from the helper's own exit status, where a program that fails to START at
    // all never reports one (the page then claimed a code could be generated on
    // a machine that has no ii-recover, until the click failed).
    Process {
        id: helperCheckProcess
        command: ["/usr/bin/test", "-x", root.recoverHelper]
        onExited: (exitCode, exitStatus) => {
            root.recoveryInstalled = exitCode === 0;
        }
    }

    function checkCode() {
        if (verifyField.text.trim() === "") {
            root.verifyMessage = Translation.tr("Type the code first.");
            return;
        }
        root.verifyInput = verifyField.text;
        verifyField.text = "";
        verifyProcess.stdinEnabled = true;
        verifyProcess.running = true;
    }

    Process {
        id: recoveryStatusProcess
        command: [root.recoverHelper, "--status", "--user", root.userName]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = text.trim();
                root.recoverySet = out.startsWith("SET");
                root.recoveryDate = out.startsWith("SET") ? out.slice(4).trim() : "";
            }
        }
        // Whether the helper exists at all is helperCheckProcess's job, above.
    }

    Process {
        id: generateProcess
        // Root is needed to write the store, and pkexec is what asks for it --
        // through the shell's own polkit dialog, not a terminal.
        command: root.recoverySet
            ? ["pkexec", root.recoverHelper, "--setup", "--force", "--user", root.userName]
            : ["pkexec", root.recoverHelper, "--setup", "--user", root.userName]
        stdout: StdioCollector {
            onStreamFinished: {
                const code = text.trim().split("\n").pop() ?? "";
                if (code.length > 0) root.issuedCode = code;
            }
        }
        stderr: StdioCollector { id: generateErr }
        onExited: (exitCode, exitStatus) => {
            root.recoveryBusy = false;
            if (exitCode === 0 && root.issuedCode !== "") {
                root.recoveryMessage = "";
                root.refresh();
                return;
            }
            root.issuedCode = "";
            const detail = generateErr.text.trim();
            root.recoveryMessage = detail !== ""
                ? Translation.tr("Not generated: %1").arg(detail.split("\n").pop())
                : Translation.tr("Not generated. Authorisation was refused or cancelled.");
        }
    }

    Process {
        id: verifyProcess
        stdinEnabled: true
        command: [root.recoverHelper, "--check", "--user", root.userName]
        stdout: StdioCollector { id: verifyOut }
        onRunningChanged: {
            if (!verifyProcess.running) return;
            verifyProcess.write(root.verifyInput + "\n");
            root.verifyInput = "";
            verifyProcess.stdinEnabled = false;
        }
        onExited: (exitCode, exitStatus) => {
            verifyOut.text.trim() === "OK"
                ? root.verifyMessage = Translation.tr("That code matches the one on file.")
                : root.verifyMessage = Translation.tr("That does not match the code on file.");
        }
    }

    Process {
        id: removeProcess
        command: ["pkexec", root.recoverHelper, "--remove", "--user", root.userName]
        stderr: StdioCollector { id: removeErr }
        onExited: (exitCode, exitStatus) => {
            root.recoveryBusy = false;
            root.confirmRemove = false;
            if (exitCode === 0) {
                root.recoveryMessage = Translation.tr("Recovery code removed.");
                root.issuedCode = "";
                root.refresh();
                return;
            }
            root.recoveryMessage = Translation.tr("Not removed: %1").arg(removeErr.text.trim().split("\n").pop() ?? "");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    ContentSection {
        icon: "person"
        title: Translation.tr("This account")

        ConfigRow {
            Layout.fillWidth: true
            spacing: 14

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 56
                implicitHeight: 56
                radius: Appearance.rounding.full
                color: Appearance.colors.colSecondaryContainer
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "person"
                    iconSize: 30
                    color: Appearance.colors.colOnSecondaryContainer
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                StyledText {
                    Layout.fillWidth: true
                    text: root.fullName !== "" ? root.fullName : root.userName
                    font.pixelSize: Appearance.font.pixelSize.large
                    font.weight: Font.Medium
                    color: Appearance.colors.colOnSecondaryContainer
                }
                StyledText {
                    Layout.fillWidth: true
                    text: root.userName + (root.loginShell !== "" ? ` · ${root.loginShell}` : "")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }

    // ── Password ─────────────────────────────────────────────────────────────
    ContentSection {
        icon: "lock"
        title: Translation.tr("Password")

        ConfigRow {
            Layout.fillWidth: true
            StyledText {
                Layout.fillWidth: true
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
                text: root.passwordChanged !== ""
                    ? Translation.tr("Last changed %1").arg(root.passwordChanged)
                    : Translation.tr("Last changed: unknown")
            }
            RippleButtonWithIcon {
                materialIcon: root.formOpen ? "close" : "lock_reset"
                mainText: root.formOpen
                    ? Translation.tr("Cancel")
                    : Translation.tr("Change password")
                onClicked: {
                    root.formOpen = !root.formOpen;
                    root.changeState = "idle";
                    root.changeMessage = "";
                }
            }
        }

        // The form is shown/hidden rather than revealed: a Revealer measures its
        // children to animate, and a child that fills its width while the parent
        // measures it is a binding loop waiting to happen.
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.formOpen
            spacing: 6

                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.Wrap
                    text: Translation.tr("Your current password is checked by the system itself (PAM), exactly as when changing it in a shell. Nothing here reads or stores it.")
                }

                MaterialTextField {
                    id: currentField
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Current password")
                    echoMode: TextInput.Password
                }
                MaterialTextField {
                    id: newField
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("New password (at least 8 characters)")
                    echoMode: TextInput.Password
                }
                MaterialTextField {
                    id: confirmField
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("New password again")
                    echoMode: TextInput.Password
                    onAccepted: root.startPasswordChange()
                }

            RowLayout {
                spacing: 8
                RippleButtonWithIcon {
                    enabled: root.changeState !== "running"
                    materialIcon: "check"
                    mainText: root.changeState === "running"
                        ? Translation.tr("Changing...")
                        : Translation.tr("Set new password")
                    onClicked: root.startPasswordChange()
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: root.changeState === "running"
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                    text: Translation.tr("Waiting for passwd...")
                }
            }
        }

        ConfigRow {
            Layout.fillWidth: true
            visible: root.changeMessage !== ""
            spacing: 8
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: root.changeState === "done" ? "check_circle" : "error"
                iconSize: 18
                color: root.changeState === "done"
                    ? Appearance.colors.colPrimary
                    : Appearance.m3colors.m3error
            }
            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font.pixelSize: Appearance.font.pixelSize.small
                color: root.changeState === "done"
                    ? Appearance.colors.colPrimary
                    : Appearance.m3colors.m3error
                text: root.changeMessage
            }
        }
    }

    // ── Recovery ─────────────────────────────────────────────────────────────
    ContentSection {
        icon: "key"
        title: Translation.tr("Recovery code")

        StyledText {
            Layout.fillWidth: true
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
            text: root.recoveryInstalled
                ? (root.recoverySet
                    ? Translation.tr("A recovery code is set (created %1). It is stored only as a memory-hard hash, so it cannot be read back — losing it means generating a new one.").arg(root.recoveryDate)
                    : Translation.tr("No recovery code is set. Generate one so that a forgotten password does not mean a rescue disk."))
                : Translation.tr("ii-recover is not installed on this machine yet.")
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            RippleButtonWithIcon {
                enabled: root.recoveryInstalled && !root.recoveryBusy
                materialIcon: root.recoverySet ? "autorenew" : "key"
                mainText: root.recoverySet
                    ? Translation.tr("Replace code")
                    : Translation.tr("Generate code")
                onClicked: {
                    root.recoveryBusy = true;
                    root.recoveryMessage = Translation.tr("Waiting for authorisation...");
                    generateProcess.running = true;
                }
            }

            RippleButtonWithIcon {
                visible: root.recoverySet && root.issuedCode === ""
                materialIcon: "delete"
                mainText: root.confirmRemove ? Translation.tr("Really remove") : Translation.tr("Remove")
                onClicked: {
                    if (!root.confirmRemove) {
                        root.confirmRemove = true;
                        return;
                    }
                    root.recoveryBusy = true;
                    removeProcess.running = true;
                }
            }
        }

        // The code itself, shown once and never stored.
        Rectangle {
            Layout.fillWidth: true
            visible: root.issuedCode !== ""
            implicitHeight: shownCode.implicitHeight + 24
            radius: Appearance.rounding.normal
            color: Appearance.colors.colLayer2
            border.width: 1
            border.color: Appearance.colors.colOutlineVariant

            ColumnLayout {
                id: shownCode
                anchors {
                    fill: parent
                    margins: 12
                }
                spacing: 6

                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.m3colors.m3error
                    font.weight: Font.DemiBold
                    text: Translation.tr("Write this down now — it is shown once and cannot be recovered:")
                }
                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    font {
                        family: Appearance.font.family.monospace
                        pixelSize: Appearance.font.pixelSize.large
                        weight: Font.DemiBold
                    }
                    color: Appearance.colors.colOnLayer2
                    text: root.issuedCode
                }
                RowLayout {
                    spacing: 8
                    RippleButtonWithIcon {
                        materialIcon: "content_copy"
                        mainText: Translation.tr("Copy")
                        onClicked: {
                            Quickshell.clipboardText = root.issuedCode;
                            root.recoveryMessage = Translation.tr("Copied. A clipboard is not a place to keep it — write it down too.");
                        }
                    }
                    RippleButtonWithIcon {
                        materialIcon: "visibility_off"
                        mainText: Translation.tr("I have written it down")
                        onClicked: {
                            root.issuedCode = "";
                            root.recoveryMessage = Translation.tr("Stored. Turn to the recovery code when you need to get back in.");
                        }
                    }
                }
            }
        }

        // Checking a code needs no privileges: verification is a hash comparison,
        // so this asks nobody for a password.
        ConfigRow {
            Layout.fillWidth: true
            visible: root.recoverySet && root.issuedCode === ""
            spacing: 8
            MaterialTextField {
                id: verifyField
                Layout.fillWidth: true
                placeholderText: Translation.tr("Type a recovery code to check it")
                font.family: Appearance.font.family.monospace
                onAccepted: root.checkCode()
            }
            RippleButtonWithIcon {
                materialIcon: "fact_check"
                mainText: Translation.tr("Check code")
                onClicked: root.checkCode()
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.verifyMessage !== ""
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            property bool matched: root.verifyMessage.startsWith(Translation.tr("That code matches"))
            color: matched ? Appearance.colors.colPrimary : Appearance.m3colors.m3error
            text: root.verifyMessage
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.recoveryMessage !== ""
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: root.recoveryMessage
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("Locked out? Switch to a text console (Ctrl+Alt+F3), log in as root, and run:  ii-recover --reset %1").arg(root.userName)
        }

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("Generating or removing a code needs root, so those two buttons ask for your password with the desktop's own prompt.")
        }
    }

    // ── The boundary ─────────────────────────────────────────────────────────
    ContentSection {
        icon: "shield"
        title: Translation.tr("What this protects, and what it does not")

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("Protected: the stored recovery hash. It is scrypt at 64 MiB per attempt and the code is 100 random bits, so copying that file does not let anyone find the code.")
        }
        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("Not protected: the disk. This machine has no full-disk encryption, so anyone who gets hold of the laptop can boot from other media and reset the password without ever needing the recovery code. Encrypting the disk is the only thing that changes that, and it is a separate job.")
        }
        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
            text: Translation.tr("So: the code gets YOU back in when the password is gone. It is not a lock on the machine.")
        }
    }
}
