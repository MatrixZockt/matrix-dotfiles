pragma Singleton
import Quickshell
import "fuzzysort.js" as FuzzySort

/**
 * Wrapper for FuzzySort to play nicely with Quickshell's imports
 */

Singleton {
    function go(...args) {
        return FuzzySort.go(...args)
    }

    function prepare(...args) {
        return FuzzySort.prepare(...args)
    }

    // single(search, target) is the one-shot matcher: it takes ONE target
    // string and returns its Result (with .score/.indexes) or null when it
    // does not match. It is the right call when you are iterating over a list
    // yourself and scoring each candidate by hand -- `go` is the wrong one,
    // because its second argument is a target LIST, and handing it a
    // single prepared search string silently scores every row the same.
    function single(...args) {
        return FuzzySort.single(...args)
    }
}

