# Readable Doctor overview (experimental)

After an explicit Doctor run, Diagnostics displays a RU/EN overview derived from
that same redacted report. Language changes redraw the overview without another
probe. The original report and its copy button are unchanged; neither report nor
parsed facts are persisted in browser storage.

The bounded parser currently supports Doctor 1.2.18 and 1.2.19. It requires the
anchored complete footer, matching API summary counts and exit status, and one
recognized version line. Truncation, conflicting verdicts or unknown versions show
an unavailable notice; missing or duplicated facts show “Could not determine”.
Parsing is section-scoped. Later Doctor changes need a fixture and parser review.

Cards cover model/KeeneticOS, the deepest /opt mount's internal/external/RAM class,
filesystem/source, free/total /opt and /tmp space, available RAM and swap, process
observations, watchdog scheduling, heartbeat count, restart/rate-limit counts and
the available history interval. These are observations from the report, not fresh
live readings. Heartbeats are not uptime or proof of a stable ISP; timestamps are
shown as recorded by the source, without assigning an invented timezone.

WARN/FAIL findings remain visible with localized severity/category and expandable
original evidence, rendered only through textContent. Unfamiliar finding text is
not discarded or guessed at. This first stage does not translate every technical
message or diagnose why a specific website is unavailable. See issue #270 for the
separate development of new diagnostic tools.

Later #274 work: explicit panel installation path/version/storage in Doctor and a
more detailed supported finding vocabulary. #273 tracks the independent panel
self-update. This change adds no rollback history or automatic updates.
