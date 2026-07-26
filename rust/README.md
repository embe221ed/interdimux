# imux — the interdimux core

The heavy half of interdimux: parsing the tmux dumps, sizing the columns,
resolving commands and git branches, and rendering the rows. This is the part
that was ~181 ms of in-process bash.

    cargo build --release      # -> target/release/imux

`scripts/interdimux.sh` picks the binary up automatically from
`rust/target/release/imux`. Set `INTERDIMUX_BIN=/path/to/imux` to use one
installed elsewhere, or `INTERDIMUX_USE_RUST=off` to force the bash renderer.

## The boundary

**bash owns tmux and config. The binary owns rendering.**

bash performs the single batched tmux query, resolves every option
(env → tmux option → built-in default), and pipes the raw dumps in on stdin
separated by RS (`\x1e`), in the order sessions / windows / panes /
current-target. Every option is passed explicitly — the binary must never
re-derive a default, or it will disagree with the bash fallback whenever an
option is unset.

bash keeps its own renderer, so the plugin works with no binary at all.
`tests/test_rust_parity.sh` diffs the two across the configuration space that
changes output, with a bash-vs-bash control on every case.

## One intentional divergence

bash pads columns by *character count*, so a CJK or emoji name — two terminal
cells per character — misaligns every column to its right. The binary uses real
display width. Identical for ASCII, correct where bash was not.

## Measured

Interleaved A/B, same script, binary on vs forced off (9 reps, medians):

| rows | bash total / first row | imux total / first row | speedup |
|---|---|---|---|
| 12  | 37 ms / 26 ms  | 22 ms / 20 ms | 1.7× / 1.3× |
| 57  | 80 ms / 34 ms  | 25 ms / 24 ms | 3.2× / 1.4× |
| 147 | 172 ms / 51 ms | 34 ms / 31 ms | 5.1× / 1.6× |
| 297 | 362 ms / 96 ms | 54 ms / 46 ms | 6.7× / 2.1× |
| 497 | 535 ms / 124 ms| 69 ms / 49 ms | 7.8× / 2.5× |

First-row gains are smaller than total because both pay the same fixed costs —
bash startup and the ~15 ms tmux query, which is IPC and identical in any
language. Note that at 497 rows the binary finishes the *entire* list (69 ms)
faster than bash produces its *first row* (124 ms).
