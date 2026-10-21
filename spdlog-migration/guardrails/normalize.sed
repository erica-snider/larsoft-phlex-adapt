# G3.2 normalization rules (spdlog-migration/F4_GUARDRAILS_PLAN.md).
#
# Applied to a single test's raw captured body (already stripped of the ctest
# "<N>: " per-line test-number prefix -- see outdiff.sh's extract_body()) to
# reduce both a pre-migration (messagefacility) and post-migration (spdlog)
# capture to a comparable, bare message-body form.
#
# Each rule below states what it strips and why, so an unexplained diff during
# GATE B can be traced back to a specific rule instead of guessed at.
#
# Calibrated against a REAL captured baseline (larcorealg geometry_test, two
# back-to-back runs on 2026-09-22): the only observed non-determinism between
# identical runs was the embedded wall-clock timestamp in every %MSG banner
# line. That is what rule (1) exists to remove.

# (0) Strip ANSI/terminal escape sequences (colors, resets) from the START of
#     a line before any other rule runs.
#     CALIBRATED FINDING (real capture, geometry_iterator_test): Boost.Test's
#     colored "*** No errors detected" banner emits a trailing color-reset
#     escape (e.g. ESC[0;39;49m) that lands at the START of the NEXT printed
#     line -- which happened to be an mf %MSG banner. That escape prefix
#     defeated rule (1)'s `^%MSG-` anchor, so the banner (with its
#     non-deterministic timestamp) survived normalization and caused a false
#     "DIFFERS" between two otherwise-identical runs. Stripped unconditionally
#     at the front of every line; harmless on lines that have no such prefix.
s/^(\x1b\[[0-9;]*m)+//

# (0b) Drop cet_exec_test's own pre-run housekeeping line, e.g.:
#       removed 'geometry_lartpcdetector.txt'
#     CALIBRATED FINDING (real capture, geometry_iterator_test): this line is
#     printed by the TEST HARNESS (cet_exec_test's --remove-on-failure /
#     leftover-output cleanup), not by the code under test, and its presence
#     depends on whether a stale output file happened to exist from a PRIOR
#     run -- non-deterministic run-to-run state, not a function of the
#     source code being migrated. Left in, it produces a false DIFFERS purely
#     from run history/ordering.
/^removed '.*'$/d

# (1) Strip messagefacility's own banner line entirely:
#       %MSG-i CategoryName:  main 22-Sep-2026 13:24:55 CDT Initialization ...
#     This line carries category, severity, timestamp, application/context
#     fields, and an optional trailing "file:line" locator -- none of it is
#     the message BODY, and the timestamp makes every pre-migration capture
#     unique even with no code change. The message text that follows on
#     subsequent lines is left untouched; only the banner line itself and the
#     "%MSG" terminator line are removed.
/^%MSG-[a-zA-Z] /d
/^%MSG$/d

# (1b) Normalize the approved setup-message rename:
#       messagefacility: "MessageFacility started."
#       spdlog:          "Logging started."
#     This is an intentional migration-only wording change approved during
#     Gate B. It is not a diagnostic body, and treating both forms as the same
#     canonical text keeps historical pre-migration baselines useful without
#     hiding any other output change.
s/^MessageFacility started\.$/<LOGGING_STARTED>/
s/^Logging started\.$/<LOGGING_STARTED>/
s/^.*SetupMessageFacility: Logging started\.$/<LOGGING_STARTED>/

# (1c) Strip the DECORATED spdlog record prefix produced by the current
#      Logging.h/Logging.cxx format:
#        [LOG-<level>] [in <scope::name>]: <body>   ->  <body>
#        [LOG-<level>] [in ?]: <body>               ->  <body>
#      (Logging.cxx sets pattern "[LOG-%l] %v"; Logging.h emits
#       "[in {}]: {}" / "[in ?]: {}".)
#
#      MUST run BEFORE rule (2): a line starting with '[' never matches rule
#      (2)'s leading-identifier anchor, so without this rule the decorated
#      prefix survives normalization entirely and EVERY migrated message
#      differs from its pre-migration baseline.
#
#      spdlog's %l spells the levels: trace, debug, info, warning, error,
#      critical (verified against the installed spdlog 1.12, not assumed --
#      note "warning"/"error", NOT "warn"/"err").
#
#      Only the FIRST line of a multi-line record carries this decoration;
#      continuation lines are emitted bare (verified), so they are left alone
#      and compare directly against the mf-era continuation lines.
#
#      The level is deliberately NOT preserved in the normalized body: the
#      pre-migration mf baselines carry severity only in the %MSG banner that
#      rule (1) deletes, so keeping it here would make every migrated line
#      differ. Level is checked separately and more precisely by
#      `outdiff.sh levels`, which reads the level out of the RAW capture.
#
#      The scope is captured to the prefix sidecar by outdiff.sh before
#      normalization (PATTERN_CATALOG.md §2.4: a WRONG prefix is a real
#      defect worth seeing), exactly as for rule (2).
s/^\[LOG-(trace|debug|info|warning|error|critical)\] \[in [^]]*\]: //

# (1d) GUARD: an UNCONFIGURED spdlog default logger (i.e. lar::log::setup()
#      never called) emits its own default pattern, which carries a
#      NON-DETERMINISTIC timestamp:
#        [2026-10-07 15:44:31.855] [info] [in geo::A::f]: body
#      Verified against installed spdlog 1.12. Such a line would differ on
#      every single run. Normalize the timestamp+level decoration to a visible
#      marker rather than deleting it silently: if <UNCONFIGURED_LOGGER>
#      appears in a diff, the test is logging before/without setup() and the
#      init shim is missing -- a real finding (PATTERN_CATALOG.md §4.2), not
#      noise to be hidden.
s/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\] \[(trace|debug|info|warning|error|critical)\] \[in [^]]*\]: /<UNCONFIGURED_LOGGER> /

# (2) Strip a bare spdlog scoped-name prefix line-start, e.g.:
#       geo::WireReadoutGeom::ChannelsIntersect: channel 7 maps to no wire
#     -> channel 7 maps to no wire
#
#     This is deliberately a SEPARATE, order-preserving capture (not a blind
#     delete): PATTERN_CATALOG.md §2.4 notes a WRONG prefix is a real defect
#     worth seeing, so outdiff.sh captures the stripped prefixes to a sidecar
#     file (<test>.prefixes.txt) BEFORE this script runs (grep -oE on the raw
#     body), rather than discarding them silently.
#
#     CALIBRATED (not guessed) against a real capture: a naive
#     "^[A-Za-z_][\w:<>~ ]*: " would also eat lines that are NOT an spdlog
#     prefix at all -- ROOT's own "Info in <TGeoManager::Weight>: ..."
#     diagnostics, and ctest/cet_exec_test boilerplate ("Working Directory: ",
#     "Environment variable modifications: ", "Test timeout computed to be: ",
#     "Geometry file: ", "Running on detector: ", "Test selection: ",
#     "Comparing two wires in the same plane: ", "Returned wire would be: ").
#     Those are excluded by name below, calibrated from the actual capture
#     rather than assumed; if a NEW boilerplate producer appears in a future
#     baseline capture and leaks through, add it here rather than loosening
#     the whole rule.
/^Info in </!{
/^Environment variable/!{
/^Working Directory:/!{
/^Test timeout computed to be:/!{
/^Test selection:/!{
/^Geometry file:/!{
/^Running on detector:/!{
/^Comparing two wires/!{
/^Returned wire would be:/!{
s/^[A-Za-z_][A-Za-z0-9_:<>~,() ]*: //
}
}
}
}
}
}
}
}
}

# (3) Normalize absolute build-tree paths so a rebuild in a different
#     directory (or a different developer's checkout) does not manufacture a
#     spurious diff. Matches this repo's mpddev layout specifically rather
#     than a generic "any absolute path" rule, which would be too aggressive
#     and could eat meaningful data (e.g. a message that legitimately prints
#     a physical detector path unrelated to the build tree).
s#/[^ ]*/mpddev/build/#<BUILD>/#g
s#/[^ ]*/mpddev/srcs/#<SRCS>/#g

# (4) Normalize PIDs / addresses that some ROOT diagnostic lines include
#     (e.g. "Info in <TGeoManager::...>" lines do not carry these today, but
#     other ROOT subsystems sometimes print an address or a PID; kept general
#     and harmless if it never matches in a given capture).
s/0x[0-9a-fA-F]+/<ADDR>/g

# (5) Normalize ROOT TStopwatch timing lines, e.g.:
#       Real time 0:00:00, CP time 0.010
#     CALIBRATED FINDING (not anticipated in the original plan text): this is
#     genuine run-to-run non-determinism from actual CPU scheduling, found by
#     the G3.5 self-consistency check itself (two back-to-back baseline/check
#     runs of geometry_test with NO source edits differed only on this line).
#     It is unrelated to messagefacility/spdlog and must be normalized away or
#     every run of this harness reports a false difference regardless of any
#     migration work. Left unnormalized, this line would also defeat the
#     "leave timing intact so a real regression shows" intent from rule set
#     (1-4)'s NOTE below -- but this specific line carries no diagnostic value
#     for the migration (it is not a message body at all), so it is safe and
#     necessary to normalize.
s/^Real time [0-9:]+, CP time [0-9.]+$/<TIMING>/

# NOTE on what is intentionally NOT normalized:
#  - blank-line structure is left intact: PATTERN_CATALOG.md §5.6 / the F4
#    plan explicitly want a disappearing spurious mf blank line to SHOW UP in
#    the diff as a real (expected, acceptable) change, not be silently eaten;
#  - wall-clock durations printed by the test's OWN business logic (not the mf
#    banner) are left alone: this migration's baselines are geometry/dumper
#    text, not timing-sensitive output, and blindly stripping numbers would
#    risk hiding a genuine regression in computed values.
