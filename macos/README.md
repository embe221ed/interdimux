# Native macOS picker

This optional AppKit app searches and switches Rex sessions, windows, and panes, and supports the core Rex editing actions below. It remains an experimental port. Its integration makes the native picker and dashboard the primary entry points while the terminal picker stays available separately. It refreshes when opened, after mutations, and with **Cmd+R**.

Requires macOS 13+, the Xcode Command Line Tools, Rust 1.80+, Python 3, and a running local Rex app/server. The companion runs on the Mac and can switch to sessions, tabs, and panes on configured remote Rex servers. The existing Rust core still supports Rust 1.74 when built without the optional `macos-picker` feature.

```sh
./macos/build.sh
./macos/open.sh
```

The build creates `macos/build/Interdimux Picker.app`, containing the AppKit executable and an `imux` helper built with the optional `macos-picker` feature. The build explicitly selects Cargo’s host target and packages that target’s actual helper, even when Cargo configuration or the environment requests another target. The generated bundle is ignored by Git. Open it in Finder or use `open.sh`; the script builds a missing bundle and reports when changed source requires rebuilding. Quit the running app with **Cmd+Q** before rebuilding. This is a local development bundle, without distribution signing or notarization.

`open.sh` uses the sole connected local macOS Rex app, or accepts an explicit target:

```sh
./macos/open.sh --client 'client:…' --session 'session:…' \
  --window 'window:…' --block 'block:…'
```

IDs are full Rex IDs, passed as arguments and URL-encoded. Session/window/block context is optional for standalone launch; when present, it identifies the originating pane. `REX_CLIENT`, `REX_SESSION`, `REX_WINDOW`, and `REX_BLOCK` supply defaults. Passing an explicit session and pane resolves the tab that contains that pane. `INTERDIMUX_REX_BIN` can select the installed Rex CLI. `--print-url` validates the local app and prints the launch URL without opening a window.

Load this after the existing Interdimux setup in Rex's `init.lua`, then reload the configuration. Keep the terminal integration for its remaining tools; bind its picker to `ctrl+b>w` if desired:

```lua
dofile("/opt/tools/interdimux/integrations/rex_macos.lua").setup {
  root = "/opt/tools/interdimux",
  key = "ctrl+b>f",
  dashboard_key = "ctrl+b>g",
}
```

Adjust the checkout path and key if needed. This registers **Interdimux: Native macOS Picker** and **Interdimux: Native macOS Dashboard** in the command palette. The action validates the local app and launches the bundle directly through Launch Services with the originating pane context, including the host for remote sessions. It checks the bundle's required files without starting Python or walking the source tree on every hotkey. After source edits, rebuild and restart the picker; `./macos/open.sh --check-build` provides the full development staleness check. The native defaults replace prefix+f and prefix+g; prefix+w is not modified. An explicit prefix+u alias can remain bound to `interdimux_macos`.

Type to search. Use **Cmd+1–6** to change scope, **↑/↓** or **Ctrl+N/P** to select, **Enter** to switch, and **Escape** to dismiss. Navigation wraps and skips contextual parents. **Cmd+F** focuses and selects the search query. **Cmd+Q** quits the background app. The panel grows to 1080 × 760 points within the current screen’s usable area.

Reopening from a known session on the same Rex client immediately shows the cached list. The refresh keeps surviving siblings in place and updates their metadata. With an empty search, the picker selects the previously visited session. The running helper remembers the sessions each client opens the picker from and the sessions it switches to successfully. Sidebar visits between those observations are invisible to the helper. If it is still locating the previous remote session, local rows appear immediately and the picker scrolls the remote selection into view when it arrives. Moving the selection yourself preserves your choice across updates. An early Enter waits for confirmation and cancels if the previous remote session is unavailable. Typing, changing scope, dismissing, or losing focus also cancels a queued Enter. A different client or unknown origin waits for fresh results. **Cmd+R** explicitly reloads the catalog.

The picker and dashboard follow Rex's appearance mode and selected light or dark theme, including imported themes. Colors refresh when opening and while the panel is visible, without clearing the query or selection. Automatic mode follows macOS. Native controls and confirmation sheets use the matching light or dark appearance too.

**All**, **Sessions**, **Tabs**, and **Panes** include results from hosts in `rex hosts list`. Local results are ready as soon as the local snapshot arrives. On a cold open, the running picker can read the connected-session list from the originating Rex app when Automation access is already available. It shows sessions for matching physical hosts while direct host discovery continues. Each host’s reply reconciles that list, then adds tabs and panes in the background. Remote rows fill in automatic names from foreground commands, verified terminal titles, and working directories as that metadata arrives. Explicit Rex labels take precedence over automatic names. Reopening reuses the remote rows held by the running picker. Search by name or type a Rex host label in **All fields**. A remote row shows its host and marks cached data if a refresh fails.

Press **Enter** on a remote row to open its exact session, tab, or pane. This requires a connected host in the originating Rex Mac app and a version with the AppleScript **show** command (preview.28 or later). The first remote switch can ask for macOS Automation permission. You can manage that permission under **System Settings → Privacy &amp; Security → Automation**. Terminal previews and editing actions are available for local rows.

On the first open, an existing Automation grant lets the picker read connected sessions from the Mac app while the servers are responding. Opening the list never asks for that grant. Each server’s reply replaces the early session rows and supplies its tabs and panes.

For a remote session, the picker asks the originating Mac app to show its exact session object. It checks the connected host against the physical server ID in Rex’s saved host record. When that identity is unavailable, it verifies the host and session through the Rex CLI. A conflicting host identity requires a refresh.

For tabs and panes, the picker can reuse the connections it opened to read remote layouts. It keeps up to two, releases idle connections after 45 seconds, and checks the target again when you press Enter. Other targets use a fresh connection. The picker can use Rex’s active SSH forwards after matching their host IDs, or the SSH agent and OpenSSH configuration available to the Rex CLI.

Remote terminal details arrive in batches of four over a separate connection to each host. The first batch can update the list while later reads run. Reopening shares the current work. **Cmd+R** can start fresh discovery even when an earlier metadata read is still pending.

The results form an expanded **session → tab → pane** tree, with compact rows, subtle branch lines and a shared, left-truncated path column. A tab with one pane uses one combined row: rename, close and swap operate on the tab, while switching, zooming, splitting and sending address its exact pane. The pane's title, command and path remain searchable. Split tabs retain their pane children. Filtering keeps a match's ancestors visible; dim parent rows provide context and are skipped by keyboard selection. Matching branches are ranked by relevance while staying together. Clearing the query restores the catalog tree and its previous-session selection. Escape and Cmd+W return focus to Rex; clicking another app dismisses without pulling focus back.

Press **Tab** from search to focus the result list. **←** selects the nearest selectable parent and **→** the first selectable child, following the visible tree through dim context rows. Roots and leaves stay selected when there is no target in that direction. While typing in search, **←/→** move the text cursor. **Cmd+F** returns to search. In a narrow list, target names take priority over the path column. The full path is available in the row’s tooltip and accessibility label.

**Prefix+G** opens the native dashboard. Use `./macos/open.sh --dashboard` to open it directly. The header shows workspace counts. Click the waiting-agent count to see which agents need input or approval. Navigate and Manage sit side by side above the Rex terminal tools, and stack on narrow screens. The panel appears before collection finishes, and native tool choices reuse the resident helper. Click a command or press its letter to run it. Use **↑/↓** or **Ctrl+N/P** to move through the commands, **←/→** to move across columns, and **Enter** to run the selection. **Escape** returns to Rex. **Cmd+R** refreshes the counts.

| Group | Tools and keys |
| --- | --- |
| Navigate | **S** Switch · **E** Agents · **J** Next agent · **N** New session |
| Manage | **R** Rename · **I** Close · **W** Swap · **Z** Zoom · **T** Send |
| Rex terminal | **A** Schedule · **O** Jobs · **H** Health |

Management choices open a native target picker filtered to the relevant capabilities. Enter performs the chosen operation, with the normal confirmation for Close. Escape or the back button beside search returns to the dashboard. Accepting a switch or project returns to Rex. Schedule, Jobs and Health open their full interfaces in the originating Rex pane. The dashboard validates that pane before launch. When the origin is remote or the pane is unavailable, these commands appear dimmed and keyboard navigation skips them. Dashboard counts cover the full cached workspace, including underlying panes on combined tab rows.

**Actions / Cmd+K** shows the operations available for the selected target. Right-click or Control-click a result to open the same menu for that row:

| Action | Native shortcut | Terminal-picker alias |
| --- | --- | --- |
| Rename | Cmd+E | Ctrl+E |
| Close, with confirmation | Cmd+Backspace | Ctrl+X |
| Zoom pane | Ctrl+Z | Ctrl+Z |
| Swap: choose source, then destination | Cmd+S | Ctrl+S |
| Send literal command text or a single key | Cmd+T | Ctrl+T |
| Toggle inline preview | Cmd+P | Ctrl+/ |
| New tab: name or directory | Cmd+N | Alt+N |
| Split right / down | Alt+V / Alt+H | Alt+V / Alt+H |
| Open project folder | Cmd+O | Ctrl+O |
| Find or create session by name/path | Cmd+Shift+N | Alt+Enter |
| Agents needing attention | Cmd+5 | Actions menu |
| Recent projects and directories | Cmd+6 | Actions menu |
| Browse selected / parent folder | Cmd+Right / Cmd+Left | Actions menu |
| Search deeper in project directories | Ctrl+F | Actions menu |
| Refresh | Cmd+R | Ctrl+R |

Rename, close, send, new-tab, split and swap refresh in place. Marking a swap source clears the query; Escape cancels that choice before dismissing the picker. Rex swaps require two tabs or two panes in the same session. Close confirmations initially focus Cancel. Use Tab to focus Close, then Enter or Space to confirm; Escape always cancels. Send preserves literal text and appends Enter; a recognized shorthand such as `C-c`, `Escape` or `F12` sends one key. Session or multi-pane-tab selections send to all their terminal panes, as stated in the dialog.

The main **All** list includes recent projects after the live session tree. Type a project name and press **Enter** to open or reuse its session. If a nonblank search has no cached matches, a 100 ms pause starts one background zoxide inventory load. The full returned inventory becomes searchable, including lower-ranked entries beyond the initial suggestions; later queries and reopenings reuse it. **Cmd+R** clears the completed inventory so the next miss can retry a failed lookup or load database changes. Typing stays responsive while the optional command runs, with a 250 ms deadline and 1 MiB output limit. Loading performs no per-directory existence checks or scans, and opening or searches with cached matches never start it. Names, Paths, and All fields support this fallback. `INTERDIMUX_USE_ZOXIDE=off` disables it; `INTERDIMUX_ZOXIDE_BIN` can select the executable when needed. Search results use matcher relevance across sessions, tabs, panes, and projects. In All fields and Names, contiguous existing session-name matches get a small preference over similarly strong project suggestions: `hu` and `sui` prefer an open `sui-hunt`, while `hd` still prefers `hudi` over a weak match in session metadata. Substantially stronger project matches retain their relevance advantage. Editing the query selects its strongest result; refreshing the same search preserves your selection when it remains available. If the completed lookup still has no matches, a **Create “…”** row lets Enter create a session directly from the query using the shared name/path resolver and startup rules. Creation is available in All with All fields or Names, and is suppressed while zoxide is pending, for blank/filter-only queries, other scopes, and swap mode. Typing never resolves candidate paths or scans the filesystem.

The **Projects** scope additionally lists configured project roots and supports folder browsing. Filtering searches the cached list; **Search deeper / Ctrl+F** explicitly runs the shared bounded directory scan. Browse a selected folder with **Cmd+Right**, move to its parent with **Cmd+Left**, or return to **Recents**. Enter opens or reuses a session for the exact selected directory. Browsing does not flood the main All list with scanned descendants. Existing Rex working directories retain their literal identity for session reuse and new-tab inheritance; control characters are escaped in the displayed path. Typed project creation and project history continue to reject control-character paths explicitly. **Cmd+O** also offers the native macOS folder chooser. New sessions keep Rex's default initial tab title. Zoom and successful session opening return to Rex.

The search-field menu restricts fuzzy matching to **All fields**, **Names**, **Paths**, or **Commands**. Changing fields preserves the query and scope. Matching uses full metadata, even when displayed text is truncated. A combined tab includes its pane’s name/title and command metadata.

**Preview / Cmd+P** opens a side panel with selectable terminal output or project details. Opening preview on a settled selection starts its capture as soon as the preview helper is ready. When you move or type, it waits for selection to settle. The helper uses the displayed row’s exact pane and reuses a local Rex connection for subsequent captures. It checks the current layout before reading terminal output. A slow capture runs independently of search filtering. Only one capture runs at a time; rapid navigation coalesces to the latest selection, and stale replies never replace its preview. There is no continuous capture polling. Preview work is invalidated when the picker closes, refreshes, switches context, or performs a mutation. Toggle preview or refresh to retry a failed capture.

**Attention** counts only verified agents waiting for `approve` or `input`, including questions and required user interaction. Completed, idle, working and error-only states are excluded. Combined tab rows count their agent once. Status and capability metadata are computed when collecting the snapshot; typing does not poll Rex, inspect processes, scan directories or capture terminal output.

Remaining port work includes raw filtering parity, native scheduling/jobs/health screens, and automatic live snapshot updates. Those remain available in the terminal picker.

The transport is `interdimux-picker://open?client_id=…&session_id=…&window_id=…&block_id=…`. The app communicates with its bundled helper using JSON over standard input/output. Queries search full, untruncated metadata locally using Nucleo with two workers. At most 100 rows, including parent context, are displayed; keep typing to narrow. The count beside the scopes excludes contextual parents. The footer indicates when more matches are available. Nucleo's syntax and ranking are not a promise of complete fzf compatibility, including fzf's OR expressions.

## Validation and performance

CI runs locked Rust tests with `macos-picker` on Linux and both Mac architectures. The macOS jobs also build the AppKit bundle and run all offscreen checks with `bash macos/test.sh`. Live Rex tests and visible benchmarks remain opt-in. The individual checks are:

```sh
cargo test --manifest-path rust/Cargo.toml --locked --features macos-picker
python3 macos/test_backend.py
python3 macos/test_dialogs.py
python3 macos/test_launcher.py
python3 macos/test_tree.py
python3 macos/test_responses.py
python3 macos/test_preview.py
python3 macos/test_geometry.py
python3 macos/test_navigation.py
python3 macos/test_selection.py
python3 macos/test_opening.py
python3 macos/test_rex_theme.py
python3 macos/test_theme.py --output /tmp/interdimux-theme-renders
python3 macos/test_dashboard.py
python3 macos/test_picker_cell.py
python3 macos/render_fixture.py --output /tmp/interdimux-native-render
lua tests/rex_macos.lua
python3 macos/benchmark.py --ui --output /tmp/interdimux-macos-benchmark
```

The benchmark generates synthetic Unicode records with session/tab/pane parent links and tests a resident helper plus an optional real AppKit window. Fixture mode cannot activate Rex targets. Omit `--ui` for a headless protocol measurement. Each corpus uses 120 queries, discarding the first 12 as warmup. Reports include raw samples, stage timings, helper hash and a rendered PNG. Native timings run from query dispatch through IPC, matching, layout and display submission; **they exclude compositor/GPU/monitor presentation**, physical key-event delivery, and initial Rex collection. They are not directly comparable with the terminal's PTY-frame benchmark.

For lazy zoxide loading, run the isolated protocol benchmark after building the release helper:

```sh
python3 macos/benchmark_zoxide.py --output /tmp/interdimux-zoxide-performance.json
python3 macos/benchmark_zoxide.py --remote-publication --sizes 446 5000 12000 --rounds 10 --queries 10 --output /tmp/interdimux-remote-publication.json
```

It uses private Rex/zoxide shims and synthetic inventories of 446 and 5,000 paths. It checks that opening and cached hits make no zoxide calls, measures cached queries before/during/after loading and cached reopening, and exercises a stalled worker. Three rounds include raw samples, median/p95, and the helper hash. The timing includes serialization, pipes, matching, and fixture processes; it excludes real Rex collection, AppKit, rendering, and the UI idle delay. It neither activates sessions nor accesses the real zoxide database.

For directory discovery, compare release helpers on the same temporary project trees. This reports scan time and the number of directories found within the 150 ms metadata budget. It also checks that visible rows retain their association with renamed sessions.

```sh
python3 macos/benchmark_project_discovery.py --helper before=/path/to/previous/imux \
  --helper 'after=macos/build/Interdimux Picker.app/Contents/Helpers/imux'
```

On the development Intel Mac running macOS 26.6.2, November 6, 2026:

| Synthetic records | Helper round trip median / p95 | Query + native layout median / p95 |
| --- | ---: | ---: |
| 500 | 1.97 / 2.45 ms | 5.54 / 12.24 ms |
| 5,000 | 6.73 / 9.52 ms | 10.61 / 13.16 ms |

Opening is measured separately from querying. The report distinguishes immediate presentation (`picker_frame_ms`, with `cached_rows` indicating list reuse) from fresh results (`ready_ms`). These times begin inside the native open handler and exclude Launch Services, process/framework startup before that handler, and compositor/GPU presentation. Cached rows, tree layout, and native cells are reused without an extra Rex call to determine the initial selection. Client validation and collection share one Rex CLI process, with local-connection validation retained on every open. The request starts before native layout so collection and opening-frame preparation can overlap.

The Rex hotkey directly starts Launch Services instead of invoking Python twice and repeating client discovery. A controlled no-UI launch-path profile measured **283 ms → 61 ms median**, including the outer Rex CLI used by the test. This measures launch preparation, not end-to-end opening; the old standalone build check separately cost about 118 ms and Python startup about 90 ms. The direct hotkey checks bundle presence; the standalone launcher retains the full source staleness audit.

Rows now use lightweight native text cells with Unicode-aware head/tail truncation instead of three text-field view hierarchies per result. Count changes preserve bounded row slots, and normal updates let AppKit coalesce layout and drawing. A nearly concealed backdrop blur was removed. Three controlled offscreen runs, holding the previous reload strategy constant, measured empty-to-100-row layout **8.91 → 4.21 ms**, mixed count-change layout **10.69 → 5.36 ms**, and full CPU bitmap drawing **41.85 → 28.02 ms**. CPU bitmap rendering is not GPU presentation. Repeat the row benchmark with `python3 macos/benchmark_render.py --mode note --runs 3`.

Use the same native views to measure dashboard keyboard selection, count updates, and full bitmap drawing, or to compare changed and repeated terminal output. Add `--compact` to the dashboard or picker modes for a 680 × 560 window. The preview workload uses a 388-point column and a 40-line terminal transcript.

```sh
python3 macos/benchmark_render.py --mode dashboard --runs 6
python3 macos/benchmark_render.py --mode dashboard --compact --runs 6
python3 macos/benchmark_render.py --mode preview --runs 6
```

The November 18 comparison used `ee8e63c` as the baseline on an Intel Mac running macOS 26.7.3. After six paired runs during development, three alternating pairs checked the final source with 324 measured queries per build against the same 5,000-item fixture and Rust helper. Native result preparation and layout took **3.13 → 2.86 ms median** and **9.70 → 9.04 ms p95**. Including the helper round trip, queries took **10.26 → 10.08 ms median** and **12.50 → 12.24 ms p95** through native display submission. Picker bitmap drawing took **9.45 → 8.27 ms median** at 1080 × 760. Dashboard drawing took **23.79 → 12.65 ms median** at 940 × 680. A separate 24-pair check measured the first picker frame at **12.51 → 11.71 ms median** and fresh results at **112.34 → 113.62 ms median**. These are offscreen AppKit measurements. Physical input, Launch Services and display presentation are outside the timing interval.

To repeat the read-only opening benchmark against the local Rex workspace, quit the normal picker first, then run:

```sh
"macos/build/Interdimux Picker.app/Contents/MacOS/InterdimuxPicker" \
  --benchmark-open-output /tmp/interdimux-opening.json
```

Add `--dashboard` to measure the dashboard. Its first native frame measured **79 ms**, subsequent frames **3.6 ms median**, and fresh workspace counts **68 ms median**. The dashboard view is constructed lazily, so its icons and cards add no setup work to picker-only launches. These measurements use the same native-handler boundary and exclude Launch Services/process startup before that handler and compositor/GPU presentation.

It opens and hides the panel 12 times and exits without selecting or creating Rex targets. Add `--fixture macos/Tests/fixtures/actions.json` to use synthetic data instead. The report includes individual opening-frame/fresh-results timings and helper stage timings. These are local measurements, not latency guarantees for every Mac.

Rust regression checks passed 412 tests in total (one manual benchmark ignored), including the new matcher regression; the default core also checked with Rust 1.74.1. Launcher tests cover exact origin IDs, ambiguous/remote clients, stale builds (including vendored sources) and argument quoting. Dialog checks exercise real offscreen confirmation sheets: default Cancel, Tab/Shift-Tab focus, Return/keypad Enter, Escape, Space and window-scoped events. Swift transport checks cover fragmented UTF-8, disconnects, reconnects, malformed replies, query/action UTF-8 limits, encoded request limits, closed-pipe writes, obsolete write cancellation and independent preview requests. Reconnecting can send normal queries even while the old helper ignores termination and blocks its input pipe. Tree tests cover grouping, ancestor retention, scoped matches, contextual row counts, branch continuity, reranking, malformed parent links and the 100-row limit. Action tests cover combined identities, literal input, required close confirmation, swap constraints, session reuse/startup ordering, attention ownership and fixture mutation rejection. Response-routing and preview-gate tests cover delayed replies, typing deferral, coalescing and hide/reopen lifecycle. Geometry and cell tests cover small screens, aligned path columns, clipping, metadata freshness, resizing, and actual table transitions through 0/100/7/70/0/12/12/1 rows with reranking and hit-tested target identity. Selection tests cover query, field, scope and action changes, same-search refresh preservation, missing targets and context-only rows. Query regressions cover strong name/project matches ahead of weak fuzzy live matches, recent-project retention after browsing, creation eligibility, stale/consumed creation IDs, and fixture mutation rejection.

The optional matcher is pinned and [vendored with documented local corrections](../rust/vendor/nucleo-matcher/INTERDIMUX_PATCH.md) and its original license. These correct Unicode substring boundaries, digit/punctuation substring prefixes, case-sensitive ASCII anchors, Unicode escape parsing, normalization tables and matrix slice bounds. Regressions cover those paths, negative exact matches, literal trailing spaces, syntax-changing incremental queries and field changes across the real JSON-lines process. The vendored crate's own tests separately cover matrix allocation boundaries and public matcher calls under Miri.

Eleven real Rex integration checks passed in disposable sessions: combined scopes, literal rename/unconfirmed close, project discovery/browsing/deep search/parent/reset, independent search fields, new tabs/splits, tab/pane swaps, exact-pane sends/read-only previews, zoom, confirmed closes/recollapse, main-search recent-project activation/default-title/exact-directory reuse, and unmatched-query creation with stale/consumed-ID rejection. All owned sessions were removed and the original session/window restored. Interactive verification of the rebuilt app covered the actual Rex shortcut, exact recent-project matches in All (including typing `fluid` one character at a time), manual selection preserved by refresh, best-match selection restored after editing, the creation row and its inline preview, warm reopening with a cleared query, and Escape returning keyboard focus to Rex. Seven native renders cover wide/narrow project and terminal previews, empty states, Unicode wrapping and left-truncated paths. The dashboard pass additionally verified prefix+f/g/w against live Rex, both directions of Ctrl+N/P wraparound, Rename/Close/Send dialog cancellation, Swap query reset and cancellation, Projects and Attention routes, the no-agent Next action, and all three terminal handoffs. Dashboard rendering tests cover 940×680, compact 680×560, narrow scrolling, loading state, count refresh, keyboard routing, and accessible button metadata. Delayed query replies cannot overwrite an in-flight dashboard action. Fullscreen, multiple monitors, complete IME behavior, and every directory-browser control remain outside the interactive validation scope.

To repeat the explicit live checks, first record the original session/window and choose a local client. This command creates and cleans up its own temporary sessions, selects the specified original session afterward, and stores a manifest and timings under `macos/build/`:

```sh
python3 macos/test_live_actions.py --run-live \
  --client 'client:…' --restore-session 'session:…' --restore-window 'window:…'
```

To time remote switches, supply a connected SSH host. This creates two disposable sessions on that host, switches between them in the selected Mac app and restores the original view. The report times when the app first reports the destination and when the helper confirms the switch. It also checks the active tab and focused pane. Screen painting and the keyboard hotkey are outside the measurement.

```sh
python3 macos/benchmark_remote_switch.py --run-live --host 'my-host' \
  --helper current='macos/build/Interdimux Picker.app/Contents/Helpers/imux' --resident current
```

Add another `--helper` to interleave trials with an earlier bundle. Repeat `--resident` for each build that supports revealing the session inside the running picker. Use `--targets session` to measure just the session switch.

To measure cold discovery without switching the Mac app, use a host with an existing session. Each sample starts a fresh helper. The report times the first local result and the first actionable row for the exact remote session.

```sh
python3 macos/benchmark_remote_switch.py --cold-rows --host 'my-host' --rounds 12 \
  --helper before='/path/to/Previous.app/Contents/Helpers/imux' --early-poll before \
  --helper current='macos/build/Interdimux Picker.app/Contents/Helpers/imux' --early-poll current \
  --resident-catalog current
```

Trials rotate the helper order. Pass `--early-poll` for both helpers to compare them at the same polling interval. Omit it for an older bundle when measuring that bundle's original backoff.

`--resident-catalog` compiles this checkout's read-only Swift catalog operation and keeps it running across trials. After the helper supplies the validated Rex app PID and process birth time, the driver reads the catalog while remote discovery continues. The report counts trials with a catalog offer, a submitted hint containing the exact target, and a callback that changed the helper's rows. If the Mac app cannot provide a hint, the benchmark still waits for the verified remote row. Both helpers should come from their respective app bundles so any standalone catalog command is available.

Launcher checks run without opening an app or contacting Rex:

```sh
python3 macos/test_launcher.py
lua tests/rex_macos.lua .
```
