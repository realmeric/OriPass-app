import os

/// Anything worth diagnosing goes to the unified log:
///
///     /usr/bin/log stream --predicate 'subsystem == "com.meric.oripass"' --level debug
///
/// `/usr/bin/log` rather than `log`: zsh has a builtin of that name.
///
/// The rule every line here is held to: nothing is interpolated but a count,
/// an id or a state. Never a title, a username, an address, a field's name or
/// its value, a request's body or a password. `make canary` reads this log back
/// after a lock and fails on a hit (D6).
enum Log {
    /// Named after the concern, not the file.
    static let app = Logger(subsystem: AppInfo.bundleID, category: "app")

    /// The child and what was asked of it: a method, a route with every id
    /// taken out, a status and a time. Never a body.
    static let bw = Logger(subsystem: AppInfo.bundleID, category: "bw")

    /// Intervals for Instruments, or `log show --signpost`. A name and a
    /// state, held to the same rule as the lines above.
    static let signposter = OSSignposter(subsystem: AppInfo.bundleID, category: "timing")
}
