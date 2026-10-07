pragma Singleton
import Quickshell
import "levendist.js" as Levendist

/**
 * Wrapper for levendist.js to play nicely with Quickshell's imports
 */

Singleton {
    // ── WHY THESE HAVE NO TYPE ANNOTATIONS AT ALL ──────────────────────────
    //
    // This is not an oversight and it must not be "tidied up". Adding
    // annotations here is what put an 875 MB log on this machine.
    //
    // In Quickshell's QML dialect, annotating a function's PARAMETERS makes it
    // a typed function, and a typed function must declare a return type this
    // engine recognises. `number` is not one of them -- the real type is `real`
    // -- so a `(s1: string, s2: string): number` signature is parsed as a
    // function returning VOID. Every call then returned a value Qt believed did
    // not exist, and it logged, once per call:
    //
    //   ERROR: ... should be coerced to void because the function called is
    //   insufficiently annotated. The original value is retained.
    //
    // Isolated repro on this machine, one call per config load:
    //
    //   function f(a, b)                          -> 0 warnings
    //   function f(a, b): number                  -> 0 warnings
    //   function f(a: int, b: int)                -> 1 warning
    //   function f(a: int, b: int): number        -> 1 warning
    //   function f(a: string, b: string): number  -> 1 warning
    //   function f(a: string, b: string): real    -> 0 warnings
    //   function f(token, query): number          -> 0 warnings
    //
    // The parameter annotation is the trigger; the return type only decides
    // whether it is noticed. Both of these functions sit under
    // AppSearch.tokenScore, which runs once per token per catalogue entry on
    // the ICON-GUESSING path (AppSearch.guessIcon -> fuzzyQuery), so it is one
    // of the hottest paths in the shell.
    //
    // MEASURED EFFECT. A cold `qs -c ii` on this machine wrote 31,880 of these
    // lines in ONE continuous 77-second burst and took 80.2 s to reach a whole
    // desktop. The same load with qs's stderr sent to /dev/null took 28.9 s --
    // the 51 s difference was the cost of formatting and writing the lines
    // while the shell was trying to draw itself. /tmp/ii_shell.log reached
    // 875 MB and grew about 100 KiB/s while the desktop sat idle.
    //
    // Leaving both functions unannotated keeps them plain JS (which is all they
    // ever were -- levendist.js has no types either) and produces zero warnings.
    // `...args` is kept so a future third argument needs no edit here.
    function computeScore(...args) {
        return Levendist.computeScore(...args)
    }

    function computeTextMatchScore(...args) {
        return Levendist.computeTextMatchScore(...args)
    }
}