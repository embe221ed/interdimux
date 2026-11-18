# Rex performance review, 18 November 2026

On this Intel Mac, moving already-built result rows into the native helper response consistently reduced latency on the 500-row fixture. At 10,000 rows the mixed-query result varied between trials. Decoding each Rex snapshot once had a larger effect on opening large workspaces. A 2,500-pane synthetic snapshot reached the picker in 54.82 ms median, down from 67.13 ms.

## Method

The baseline was the working tree at the start of the review, including the pending remote-host implementation on top of commit `bcde326`. All comparisons used locked, optimized `macos-picker` builds. The host ran macOS 26.7.3 on an Intel Core i9-9980HK with fzf 0.75.0 and Python 3.14. Some review and test work ran concurrently. Treat percentile differences from a single machine as observations, particularly with 20 samples.

The local results directory is `macos/build/review-2026-11-18/`. It contains the binaries, raw JSON, additional shim scripts and run logs for this checkout. Git ignores these generated artifacts. The protocol and PTY comparison drivers record binary hashes.

## Native picker queries

Each helper ran four independent processes per catalog. The benchmark alternated process order, warmed the process for one 12-query cycle and measured five subsequent cycles. Each row below represents 240 round trips per binary, including Python JSON encoding and decoding, pipes, matching and result serialization. Queries include blank, typing prefixes, misses, broad matches and Unicode. The full warmup responses, including all row fields, ordering and selected IDs, matched across both binaries after excluding timing fields.

| Catalog rows | Baseline p50 / p95, ms | Combined p50 / p95, ms | Process start through first results, baseline → combined p50, ms |
| ---: | ---: | ---: | ---: |
| 50 | 0.82 / 1.15 | 0.63 / 0.87 | 8.51 → 8.77 |
| 500 | 1.98 / 2.46 | 1.65 / 2.04 | 16.23 → 16.64 |
| 5,000 | 6.58 / 9.13 | 6.14 / 8.55 | 84.17 → 87.73 |
| 10,000 | 12.16 / 17.13 | 11.27 / 15.98 | 171.51 → 167.84 |

A second A/B experiment isolated the result-envelope change. At 500 rows, p50/p95 went from 1.82/2.46 to 1.52/2.23 ms. At 5,000 rows, it went from 6.32/8.82 to 5.61/8.20 ms. The helper now moves the JSON array into the response, which avoids allocating copies of up to 100 result objects for each request.

The final app-bundled helper also passed the parity checks at all four sizes. In a 48-query smoke run at 500 rows it took 1.51/2.07 ms p50/p95 versus 1.78/2.31 ms on the baseline. At 10,000 rows the smoke run was slower, so a follow-up used eight alternating trials and 480 queries per binary. Mixed queries measured **11.36/16.21 ms baseline and 11.50/17.02 ms final**. Blank-query medians improved from 2.09 to 1.81 ms. At this size, query matching dominates envelope assembly, and the mixed-workload gain in the earlier experiment did not repeat.

## Native picker opening

A private Rex executable returned a synthetic local app identity and a full JSON snapshot with distinct session, window and pane IDs. Each timing covers an open on a resident helper, including spawning the shim. Preview-only mode isolates local collection and indexing. Four alternating processes per binary each performed one warmup and five measured opens per size. The candidate includes the final app-identity lookup and uses the benchmark process's real PID.

| Panes | Baseline open p50 / p95, ms | Candidate open p50 / p95, ms | Collection and decode p50, baseline → candidate, ms |
| ---: | ---: | ---: | ---: |
| 12 | 14.79 / 15.59 | 15.14 / 18.59 | 13.98 → 14.34 |
| 500 | 26.27 / 28.97 | 24.31 / 30.50 | 19.91 → 18.39 |
| 2,500 | 67.13 / 71.06 | 54.82 / 58.81 | 43.68 → 31.86 |

The 2,500-pane envelope was 830 KB. Handling its decoded snapshot in place accounted for most of the improvement. Small-catalog tails varied across runs. For live collector timing and RPC counts, use the private Rex server benchmark in `dev/perf/rex-snapshot.py`.

## Project search and remote updates

The project fixture supplied a local snapshot, 25 recent paths, an empty project root and a private zoxide executable. Each candidate run issued 100 queries in each search phase after ten warmups. The table shows medians across three runs. Two baseline runs with 50 measured queries per phase give a directional comparison for load times.

| Inventory | First matching result, baseline → combined, ms | Cached query after load, combined p50 / p95, ms | Inventory search, combined p50 / p95, ms |
| ---: | ---: | ---: | ---: |
| 446 | 18.54 → 19.32 | 0.16 / 0.24 | 0.27 / 1.71 |
| 5,000 | 40.41 → 38.80 | 0.50 / 0.65 | 0.96 / 7.46 |
| 12,000 | 66.20 → 71.47 | 1.40 / 1.83 | 1.79 / 18.88 |

Every run kept project discovery off the opening path and loaded the optional inventory once. With a stalled zoxide child, the helper reported the timeout after 251–260 ms while continuing to serve cached results. Their per-run p95s were 0.32, 0.41 and 3.56 ms. At 12,000 entries, broad inventory search and first load remain candidates for profiling.

In a separate experiment, one new remote session arrived after the project inventory was indexed. Ten publications per size took a median of 1.21, 11.49 and 32.27 ms respectively at 446, 5,000 and 12,000 projects on the baseline. The synchronous update clones local rows, rebuilds their hierarchy and restarts matching when a host publishes. Reusing the local index when only remote sessions change would reduce contention with typing. Validate removal, stale host labels and retained selections in any incremental implementation.

## Native rendering

Three offscreen optimized AppKit processes per revision measured 108 transitions each using the production table-update mode. The fixture repeatedly changed among 0, 10, 99 and 100 rows and painted a 1080 × 760 bitmap. Values are medians of the three process-level percentiles.

| Stage | Baseline p50 / p95, ms | Combined p50 / p95, ms |
| --- | ---: | ---: |
| Update and layout | 1.02 / 6.79 | 1.01 / 6.87 |
| CPU bitmap painting | 9.65 / 10.26 | 9.88 / 10.38 |
| Empty to 100 rows, layout | 6.73 / 7.20 | 6.76 / 7.20 |

These timings exclude compositor presentation, display refresh and physical input. The table exercises row rendering independently of dashboard actions and SSH.

## Terminal picker frames

Two independent A/B runs exercised real fzf in a private PTY with local process and Git enrichment. Each size had 20 measured rounds per binary after two warmups. Each round included startup, typing, two live snapshot publications, resizing and cancellation. The confirmation run used the later build containing the remote-activation change. Across both runs, all 160 measured picker processes painted the requested frames and preserved the filtered selection.

| Panes | Event | Baseline p50 / p95, ms | Candidate p50 / p95, ms |
| ---: | --- | ---: | ---: |
| 12 | First paint | 58.3 / 62.9 | 57.8 / 101.3 |
| 12 | Typed query | 68.7 / 126.3 | 66.3 / 149.8 |
| 12 | First live update | 102.6 / 183.5 | 101.0 / 146.1 |
| 12 | Steady live update | 107.4 / 135.7 | 97.1 / 147.0 |
| 12 | Resize | 32.8 / 59.4 | 33.3 / 59.2 |
| 500 | First paint | 67.0 / 70.4 | 66.8 / 84.7 |
| 500 | Typed query | 63.1 / 77.6 | 62.5 / 85.6 |
| 500 | First live update | 111.5 / 168.7 | 116.9 / 163.3 |
| 500 | Steady live update | 120.4 / 153.7 | 120.4 / 154.0 |
| 500 | Resize | 45.4 / 47.6 | 44.7 / 47.9 |

Median first paint stayed within 1 ms across both runs and sizes. The small case's p95 first paint rose in both runs, from 59.1 to 193.2 ms and from 62.9 to 101.3 ms. At 500 panes, the first live update was 10.3 ms slower at the median in the first run and 5.3 ms slower on confirmation. Comparing the paired stress runs directly, the typical within-pair live-update differences were +3.6 ms and +3.0 ms. Other tails moved in both directions. These are open performance questions. Trace watcher wake-up, snapshot normalization, fzf reload and terminal frame delivery separately on a reserved machine to localize the delay. PTY timings start at exec, input, publication or resize and end at receipt of the completed matching terminal frame. They exclude GUI presentation and upstream Rex event coalescing.

For the 12-pane case, first paint exceeded 80 ms in 1 of 40 baseline processes (660 ms) and 4 of 40 candidate processes (101–333 ms). Two candidate outliers ran first within their pair and two ran second. A 40-pair follow-up passed the *same* later binary to both arms after compilation finished. The two arms measured 55.63/60.75 ms and 55.44/59.23 ms p50/p95. Two runs in the first arm exceeded 80 ms and none in the second did. In a 20-sample arm, the second slowest sample determines p95. The observed outliers warrant monitoring, but there is insufficient evidence to attribute them to a code change.

## Reproduction

Build each checkout with `bash macos/build.sh` and retain its `rust/target/release/imux`. For this local review, the following commands use the saved binaries. New runs write their own outputs.

```sh
out=macos/build/review-2026-11-18
python3 dev/perf/rex-picker.py --baseline "$out/imux-before" --candidate "$out/imux-combined" --json /tmp/rex-picker.json
python3 rust/tests/bench_native.py --baseline "$out/imux-before" --candidate "$out/imux-latest" --repetitions 20 --warmups 2 --json /tmp/rex-pty.json
python3 macos/benchmark_zoxide.py --helper "$out/imux-combined" --sizes 446 5000 12000 --rounds 3 --queries 100 --output /tmp/rex-projects.json
python3 macos/benchmark_render.py --mode note --runs 3
python3 "$out/live-open.py" "$out/imux-before" "$out/imux-latest"
python3 "$out/remote.py" "$out/imux-before"
```

## Collection on a real Rex server

The production Lua collector ran against Rex CLI 0.1.0-preview.20 (API 16) on a private Unix socket. One session held one direct `/bin/cat` terminal per window. Each sample includes a new CLI process and connection to the warm server. The harness verifies the session and pane counts and checks that each terminal returned complete metadata. These figures measure the collector through its CLI, excluding picker rendering.

| Panes | Full snapshot RPCs | Full snapshot p50 / p95, ms | Full snapshot with 1 ms added per RPC, p50 / p95, ms | Session-only p50 / p95, ms |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 6 | 46.59 / 49.56 | 54.85 / 57.33 | 46.15 / 47.88 |
| 10 | 33 | 57.23 / 64.54 | 97.03 / 98.58 | 45.48 / 46.05 |
| 100 | 303 | 156.23 / 164.14 | 523.39 / 542.70 | 45.92 / 47.03 |

The session-only path made two RPCs at every size. The delayed run injects a Lua sleep before each RPC to show sensitivity to serial latency. A real network link has different latency and scheduling behavior. Both runs excluded one warmup per size and path. The local run used 20 samples and the delayed run used 10.

```sh
python3 dev/perf/rex-snapshot.py --sizes 1 10 100 --samples 20
python3 dev/perf/rex-snapshot.py --sizes 1 10 100 --samples 10 --rpc-delay-ms 1
```

An isolated live session move also exercised the production event observer. The new order arrived using the cached session views. A 100-event burst of generic terminal progress now schedules zero collections in the observer regression. Interdimux displays Rex program-status records, whose change and removal events still trigger updates. Cold collection remains sensitive to the number of panes. The measured next experiment is to publish session structure before enriching pane metadata. [Snapshot performance work in Linear](https://linear.app/embe221ed/issue/M-516/reduce-rex-snapshot-rpc-fan-out-and-unnecessary-refresh-work)

## Interaction findings

Rex users reported that disabled pane actions can appear enabled in a context menu, and that flat search results can obscure which tab owns a pane. The new macOS row menu shares the keyboard menu's capability checks and acts on the clicked row. The existing tree keeps matches with their parents. A follow-up will evaluate Left and Right traversal while the results table has focus, preserving normal cursor movement in the search field. [Rex menu feedback](https://discord.com/channels/1546797889009881158/1567089164015378433) · [Rex tree feedback](https://discord.com/channels/1546797889009881158/1569110524472336394) · [Keyboard traversal proposal](https://linear.app/embe221ed/issue/M-726/prototype-keyboard-traversal-of-the-session-tab-and-pane-tree)
