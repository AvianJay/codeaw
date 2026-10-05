# CPA usage, appearance and folder creation

Implemented on Windows on 2026-10-05. The earlier eight mobile regressions are
recorded separately in `mobile-regression-verification.md` and remain covered
by the full regression suite.

| Request | Cause / implementation | Verification |
|---|---|---|
| CPA endpoint and usage viewer | No CPA connection, management adapter or usage route existed. Add device secure settings and paired bridge queries for v0/v8 management APIs | Bridge tests cover URL normalization, authentication, secret stripping, optional credits failures, disabled/unsupported accounts and request routing. Controller tests cover persistence, errors and stale replies |
| Compact account lines | Add provider icons, search/filter, thin quota lines, remaining percentages, local reset time/countdown and actual Codex reset credits | Widget tests at 320×640, 390×844, 844×390 and 1200×800; real browser at 390×844 and 844×390. Browser testing found and fixed a missing callback invocation in the filter |
| UI and icons | Shared neutral/indigo theme, softer agent icons, cleaner composer/settings controls, usage navigation and saved system/light/dark preference | Full layout/composer/navigation regression suite; browser screenshots of light/dark usage and settings. Grok SVG source and MIT attribution included |
| New folder after 瀏覽… | Picker had only list/select operations and the bridge had no mkdir extension. Add create action to picker and file page | Widget browse→Chinese name→enter→select test; duplicate/error retention; bridge creation/list/session, invalid name, junction containment and opt-in tests. Actual browser created a Chinese-named directory on Windows and returned it to the new-session sheet |

Local checks: bridge `npm test` (99 passed), `npm run typecheck`, Flutter
`flutter test` (127 passed, 11 optional tests skipped), `flutter analyze` with
no issues, and release Web build. Unit/widget checks use test fixtures.

Browser CPA validation used a local HTTP management fixture with representative
Codex/Claude/Grok/Antigravity responses through the actual source bridge and
Flutter release Web app. It verified saved settings, key masking, provider
identification, separate quota windows, reset credits, search, type filters,
refresh and explicit unsupported quota behavior. It did not contact a live
CPA deployment, redeem credits, or send model requests. Live service access
needs the user's configured endpoint and Management Key; never paste keys
into an issue or chat.

CPA API behavior was checked against [CLIProxyAPI management documentation](https://help.router-for.me/management/api)
and [the official management UI](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/tree/ee79a794526a30c03748a8864a9ac6589a31833b).
Quota endpoints are service-provider interfaces and can change. Unknown or
unavailable values stay unknown; a passed reset timestamp is not treated as
proof of replenishment. “Reset count” means actual available credits, not an
estimate of future five-hour windows.

On iPhone, install the new nightly IPA and verify:

1. Settings → CPA usage: enter the real CPA endpoint and Management Key;
   compare account types, percentages, reset times and actual credits with
   CPA's own management page. The PC performs network access.
2. Portrait/landscape, system/light/dark theme, filtering and refresh.
3. New chat → Browse → parent directory → new-folder icon → Chinese name →
   Create → Select here → start chat. Repeat from the project file page.
4. The earlier native keyboard dismissal, landscape with the keyboard,
   Files/iCloud attachment picker, and LCSign import/sign/install checks.

Native iOS behavior and a live CPA deployment cannot be established by widget
fixtures or a successful IPA build alone.
