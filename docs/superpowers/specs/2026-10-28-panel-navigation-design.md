# KAS panel navigation and visual refresh

The KN-1010 operator reports that the working panel is hard to use: every function is in one long column and node labels have no visual separation. The supplied rendered text confirms the problem.

Use five local views: Overview, Subscriptions, Configuration, Diagnostics, Settings. Desktop navigation is a sidebar; narrow screens use a wrapping navigation bar. Keep one HTML document, embedded assets, system fonts and no runtime dependencies. Preserve every existing API and importer guard. Status cards explicitly describe binary presence, never infer running services or network health.

Alternatives: restyling the long page is cheap but retains navigation friction; separate server routes duplicate structure and introduce unnecessary backend work; client-side view switching gives direct access without backend changes. Native KeeneticOS cannot arrange this experimental KAS panel. No change leaves the reported problem unresolved. Benefit is high for routine operator use, implementation/maintenance cost is low, no router dependencies are added.

Subscriptions get separated checkbox rows, local name search, a selected count and clear operation messages. Hidden search matches remain selected and the count includes them. Navigation and language changes must preserve selections, pasted YAML and in-flight operation polling. Technical explanations stay in expandable help. Light/dark appearance follows the system. A narrow screen must have no horizontal page overflow; keyboard navigation and visible focus remain available.

Acceptance: existing 12 browser-contract tests and Go tests remain green; real-browser checks cover view navigation, mobile width, translations, search selection preservation and filter apply/clear request ordering. No backend, service lifecycle, authentication or router configuration changes.
