# Native macOS picker

This optional AppKit app searches and switches Rex sessions, windows, and panes, and supports the core Rex editing actions below. It remains an experimental port. Its integration makes the native picker and dashboard the primary entry points while the terminal picker stays available separately. It refreshes when opened, after mutations, and with **Cmd+R**.

Requires macOS 13+, the Xcode Command Line Tools, Rust 1.80+, Python 3, and a running local Rex app/server. Remote server and iOS launch are unsupported. The existing Rust core still supports Rust 1.74 when built without the optional `macos-picker` feature.

```sh
./macos/build.sh
./macos/open.sh
```

The build creates `macos/build/Interdimux Picker.app`, containing the AppKit executable and an `imux` helper built with the optional `macos-picker` feature. The generated bundle is ignored by Git. Open it in Finder or use `open.sh`; the script builds a missing bundle and reports when changed source requires rebuilding. Quit the running app with **Cmd+Q** before rebuilding. This is a local development bundle, without distribution signing or notarization.

`open.sh` uses the sole connected local macOS Rex app, or accepts an explicit target:

```sh
./macos/open.sh --client 'client:…' --session 'session:…' \
  --window 'window:…' --block 'block:…'
```

IDs are full Rex IDs, passed as arguments and URL-encoded. Session/window/block context is optional for standalone launch; when present, it identifies the originating pane. `REX_CLIENT`, `REX_SESSION`, `REX_WINDOW`, and `REX_BLOCK` supply defaults. `INTERDIMUX_REX_BIN` can select the installed Rex CLI. `--print-url` validates the local app and prints the launch URL without opening a window.

Load this after the existing Interdimux setup in Rex's `init.lua`, then reload the configuration. Keep the terminal integration for its remaining tools; bind its picker to `ctrl+b>w` if desired:

```lua
dofile("/opt/tools/interdimux/integrations/rex_macos.lua").setup {
  root = "/opt/tools/interdimux",
  key = "ctrl+b>f",
  dashboard_key = "ctrl+b>g",
}
```

Adjust the checkout path and key if needed. This registers **Interdimux: Native macOS Picker** and **Interdimux: Native macOS Dashboard** in the command palette. The action validates the local app, captures the exact app/session/window/pane context, and launches the bundle directly through Launch Services. It checks the bundle's required files without starting Python or walking the source tree on every hotkey. After source edits, rebuild and restart the picker; `./macos/open.sh --check-build` provides the full development staleness check. The native defaults replace prefix+f and prefix+g; prefix+w is not modified. An explicit prefix+u alias can remain bound to `interdimux_macos`.

Type to search; use **Cmd+1–6** to change scope, **↑/↓** or **Ctrl+N/P** to select (wrapping at either end and skipping contextual parents), **Enter** to switch, and **Escape** to dismiss. **Cmd+F** focuses and selects the search query. Reopening immediately shows the previous All list for the same client while refreshing it; activation waits for fresh results. **Cmd+Q** quits the background app. The panel grows to 1080 × 760 points, constrained to the current screen’s usable area.

The results form an expanded **session → tab → pane** tree, with compact rows, subtle branch lines and a shared, left-truncated path column. A tab with one pane uses one combined row: rename, close and swap operate on the tab, while switching, zooming, splitting and sending address its exact pane. The pane's title, command and path remain searchable. Split tabs retain their pane children. Filtering keeps a match's ancestors visible; dim parent rows provide context and are skipped by keyboard selection. Matching branches are ranked by relevance while staying together. Clearing the query restores the full hierarchy in session recency order. Escape and Cmd+W return focus to Rex; clicking another app dismisses without pulling focus back.

**Prefix+G** opens the native dashboard directly; `./macos/open.sh --dashboard` is its standalone launcher. It shows workspace counts and four groups of tools, with the same single-letter keys as the terminal dashboard. The panel appears before collection finishes, and native tool choices reuse the resident helper. Click a card, press its letter, or use arrows / Ctrl+N/P and Enter. Escape closes it and returns focus to Rex; Cmd+R refreshes its counts.

| Group | Tools and keys |
| --- | --- |
| Navigate | **S** Switch · **E** Agents · **J** Next agent · **N** New session |
| Manage | **R** Rename · **I** Close · **W** Swap · **Z** Zoom |
| Automate | **T** Send · **A** Schedule · **O** Jobs |
| Tools | **H** Health |

Management choices open a native target picker filtered to the relevant capabilities. Enter performs the chosen operation, with the normal confirmation for Close. Escape or **‹ Dashboard** returns to the dashboard; accepting a switch or project returns to Rex. Schedule, Jobs, and Health are labeled **Terminal** and open their existing full interfaces in Rex. These handoffs require the original focused Rex pane and validate it again before launch. Dashboard counts describe the full cached workspace rather than the 100 displayed results; combined tabs still count their underlying panes.

**Actions / Cmd+K** shows the operations available for the selected target:

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

Rename, close, send, new-tab, split and swap refresh in place. Marking a swap source clears the query; Escape cancels that choice before dismissing the picker. Rex swaps require two tabs or two panes in the same session. Closing requires choosing the destructive button; Return/Escape cancel. Send preserves literal text and appends Enter; a recognized shorthand such as `C-c`, `Escape` or `F12` sends one key. Session or multi-pane-tab selections send to all their terminal panes, as stated in the dialog.

The main **All** list includes recent projects after the live session tree. Type a project name and press **Enter** to open or reuse its session. Search results use matcher relevance across sessions, tabs, panes, and projects, so a direct name match such as `fluid-packages-sui` for `fluid` can outrank a weak fuzzy live match. Editing the query selects its strongest result; refreshing the same search preserves your selection when it remains available. If there are no live or recent-project matches, a **Create “…”** row lets Enter create a session directly from the query using the shared name/path resolver and startup rules. This fallback is available in All with All fields or Names, and is suppressed for blank/filter-only queries, other scopes, and swap mode. Typing never resolves paths or scans the filesystem.

The **Projects** scope additionally lists configured project roots and supports folder browsing. Filtering searches the cached list; **Search deeper / Ctrl+F** explicitly runs the shared bounded directory scan. Browse a selected folder with **Cmd+Right**, move to its parent with **Cmd+Left**, or return to **Recents**. Enter opens or reuses a session for the exact selected directory. Browsing does not flood the main All list with scanned descendants. **Cmd+O** also offers the native macOS folder chooser. New sessions keep Rex's default initial tab title. Zoom and successful session opening return to Rex.

The search-field menu restricts fuzzy matching to **All fields**, **Names**, **Paths**, or **Commands**. Changing fields preserves the query and scope. Matching uses full metadata, even when displayed text is truncated. A combined tab includes its pane’s name/title and command metadata.

**Preview / Cmd+P** opens a side panel with selectable terminal output or project details. Terminal captures wait for selection to settle and run on a separate helper, so a slow capture cannot block query filtering. Only one capture runs at a time; rapid navigation coalesces to the latest selection, and stale replies never replace its preview. There is no continuous capture polling. Preview work is invalidated when the picker closes, refreshes, switches context, or performs a mutation. Toggle preview or refresh to retry a failed capture.

**Attention** counts only verified agents waiting for `approve` or `input`, including questions and required user interaction. Completed, idle, working and error-only states are excluded. Combined tab rows count their agent once. Status and capability metadata are computed when collecting the snapshot; typing does not poll Rex, inspect processes, scan directories or capture terminal output.

Remaining port work includes raw filtering parity, native scheduling/jobs/health screens, and automatic live snapshot updates. Those remain available in the terminal picker.

The transport is `interdimux-picker://open?client_id=…&session_id=…&window_id=…&block_id=…`. The app communicates with its bundled helper using JSON over standard input/output. Queries search full, untruncated metadata locally using Nucleo with two workers. At most 100 rows, including parent context, are displayed; keep typing to narrow. The footer counts matching targets separately from contextual parents. Nucleo's syntax and ranking are not a promise of complete fzf compatibility, including fzf's OR expressions.

## Validation and performance

```sh
cargo test --manifest-path rust/Cargo.toml --locked --features macos-picker
python3 macos/test_backend.py
python3 macos/test_launcher.py
python3 macos/test_tree.py
python3 macos/test_responses.py
python3 macos/test_preview.py
python3 macos/test_geometry.py
python3 macos/test_navigation.py
python3 macos/test_selection.py
python3 macos/test_dashboard.py
python3 macos/test_picker_cell.py
python3 macos/render_fixture.py --output /tmp/interdimux-native-render
lua tests/rex_macos.lua
python3 macos/benchmark.py --ui --output /tmp/interdimux-macos-benchmark
```

The benchmark generates synthetic Unicode records with session/tab/pane parent links and tests a resident helper plus an optional real AppKit window. Fixture mode cannot activate Rex targets. Omit `--ui` for a headless protocol measurement. Each corpus uses 120 queries, discarding the first 12 as warmup. Reports include raw samples, stage timings, helper hash and a rendered PNG. Native timings run from query dispatch through IPC, matching, layout and display submission; **they exclude compositor/GPU/monitor presentation**, physical key-event delivery, and initial Rex collection. They are not directly comparable with the terminal's PTY-frame benchmark.

On the development Intel Mac running macOS 26.6.2, November 6, 2026:

| Synthetic records | Helper round trip median / p95 | Query + native layout median / p95 |
| --- | ---: | ---: |
| 500 | 1.97 / 2.45 ms | 5.54 / 12.24 ms |
| 5,000 | 6.73 / 9.52 ms | 10.61 / 13.16 ms |

Opening is measured separately from querying. On the live workspace, 12 sequential native opens measured **167 ms** for the first fresh snapshot, **80 ms median** for subsequent fresh snapshots, and **8.6 ms median** to submit cached rows on reopening. These times begin inside the native open handler and exclude Launch Services, process/framework startup before that handler, and compositor/GPU presentation. Client validation plus collection accounts for about 67 ms of the warm refresh. Those operations now share one Rex CLI process, with local-connection validation retained on every open.

The Rex hotkey directly starts Launch Services instead of invoking Python twice and repeating client discovery. A controlled no-UI launch-path profile measured **283 ms → 61 ms median**, including the outer Rex CLI used by the test. This measures launch preparation, not end-to-end opening; the old standalone build check separately cost about 118 ms and Python startup about 90 ms. The direct hotkey checks bundle presence; the standalone launcher retains the full source staleness audit.

Rows now use lightweight native text cells with Unicode-aware head/tail truncation instead of three text-field view hierarchies per result. Count changes preserve bounded row slots, and normal updates let AppKit coalesce layout and drawing. A nearly concealed backdrop blur was removed. Three controlled offscreen runs, holding the previous reload strategy constant, measured empty-to-100-row layout **8.91 → 4.21 ms**, mixed count-change layout **10.69 → 5.36 ms**, and full CPU bitmap drawing **41.85 → 28.02 ms**. CPU bitmap rendering is not GPU presentation. Repeat the row benchmark with `python3 macos/benchmark_render.py --mode note --runs 3`.

To repeat the read-only opening benchmark against the local Rex workspace, quit the normal picker first, then run:

```sh
"macos/build/Interdimux Picker.app/Contents/MacOS/InterdimuxPicker" \
  --benchmark-open-output /tmp/interdimux-opening.json
```

Add `--dashboard` to measure the dashboard. Its first native frame measured **79 ms**, subsequent frames **3.6 ms median**, and fresh workspace counts **68 ms median**. The dashboard view is constructed lazily, so its icons and cards add no setup work to picker-only launches. These measurements use the same native-handler boundary and exclude Launch Services/process startup before that handler and compositor/GPU presentation.

It opens and hides the panel 12 times and exits without selecting or creating Rex targets. Add `--fixture macos/Tests/fixtures/actions.json` to use synthetic data instead. The report includes individual cached/fresh native timings and helper stage timings. These are local measurements, not latency guarantees for every Mac.

Rust regression checks passed 402 tests in total (one manual benchmark ignored), including the new matcher regression; the default core also checked with Rust 1.74.1. Launcher tests cover exact origin IDs, ambiguous/remote clients, stale builds (including vendored sources) and argument quoting. Swift transport checks cover fragmented UTF-8, disconnects, reconnects, malformed replies and independent preview requests. Tree tests cover grouping, ancestor retention, scoped matches, contextual row counts, branch continuity, reranking, malformed parent links and the 100-row limit. Action tests cover combined identities, literal input, required close confirmation, swap constraints, session reuse/startup ordering, attention ownership and fixture mutation rejection. Response-routing and preview-gate tests cover delayed replies, typing deferral, coalescing and hide/reopen lifecycle. Geometry and cell tests cover small screens, aligned path columns, clipping, metadata freshness, resizing, and actual table transitions through 0/100/7/70/0/12/12/1 rows with reranking and hit-tested target identity. Selection tests cover query, field, scope and action changes, same-search refresh preservation, missing targets and context-only rows. Query regressions cover strong name/project matches ahead of weak fuzzy live matches, recent-project retention after browsing, creation eligibility, stale/consumed creation IDs, and fixture mutation rejection.

Path-filter tests found an upstream Unicode substring boundary bug: a quoted match at the end of a Unicode path could be missed. The optional matcher is pinned and [vendored with a one-line correction](../rust/vendor/nucleo-matcher/INTERDIMUX_PATCH.md) and its original license. Regressions cover Unicode/ASCII suffixes, anchors, negative exact matches, literal trailing spaces, and field changes across the real JSON-lines process.

Eleven real Rex integration checks passed in disposable sessions: combined scopes, literal rename/unconfirmed close, project discovery/browsing/deep search/parent/reset, independent search fields, new tabs/splits, tab/pane swaps, exact-pane sends/read-only previews, zoom, confirmed closes/recollapse, main-search recent-project activation/default-title/exact-directory reuse, and unmatched-query creation with stale/consumed-ID rejection. All owned sessions were removed and the original session/window restored. Interactive verification of the rebuilt app covered the actual Rex shortcut, exact recent-project matches in All (including typing `fluid` one character at a time), manual selection preserved by refresh, best-match selection restored after editing, the creation row and its inline preview, warm reopening with a cleared query, and Escape returning keyboard focus to Rex. Seven native renders cover wide/narrow project and terminal previews, empty states, Unicode wrapping and left-truncated paths. The dashboard pass additionally verified prefix+f/g/w against live Rex, both directions of Ctrl+N/P wraparound, Rename/Close/Send dialog cancellation, Swap query reset and cancellation, Projects and Attention routes, the no-agent Next action, and all three terminal handoffs. Dashboard rendering tests cover 940×680, compact 680×560, narrow scrolling, loading state, count refresh, keyboard routing, and accessible button metadata. Delayed query replies cannot overwrite an in-flight dashboard action. Fullscreen, multiple monitors, complete IME behavior, and every directory-browser control remain outside the interactive validation scope.

To repeat the explicit live checks, first record the original session/window and choose a local client. This command creates and cleans up its own temporary sessions, selects the specified original session afterward, and stores a manifest and timings under `macos/build/`:

```sh
python3 macos/test_live_actions.py --run-live \
  --client 'client:…' --restore-session 'session:…' --restore-window 'window:…'
```

Launcher checks run without opening an app or contacting Rex:

```sh
python3 macos/test_launcher.py
lua tests/rex_macos.lua .
```
