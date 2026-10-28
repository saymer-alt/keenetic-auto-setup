# Panel navigation preview

Browser screenshots use sanitized API fixtures, not a connected router. They show
implemented HTML/CSS, not a separate visual mockup. These files are documentation;
the router binary embeds only `web/*` and the canonical scripts.

- [Desktop overview](overview-desktop.png)
- [Desktop subscriptions](subscriptions-desktop.png)
- [Mobile subscriptions](subscriptions-mobile.png)
- [Dark mobile subscriptions](subscriptions-dark-mobile.png)

Checks: `node --test web/control-center/tests/*.test.cjs`; Go test/vet.
Optional real Chromium check: install Playwright in the developer environment and
run `node web/control-center/tests/panel-browser-check.cjs`. An existing browser can
be selected with `KAS_TEST_CHROMIUM=/path/to/chrome`. This checks real DOM navigation,
keyboard, retained forms/selections, RU/EN, search, confirmation cancellation,
apply/clear request ordering, persistent completion banner and page overflow at
360/390/768/1440px. Mock API responses are not evidence of real importer execution;
the independent native-emulator workflow covers that backend.
