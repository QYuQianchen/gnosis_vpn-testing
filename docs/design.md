# Why the experiment is shaped this way

#8408 asks for a bandwidth comparison between automatic path finding and pinned
paths. Reading the code changes what that sentence means, in three ways.

## 1 · There is no "path" — there is a distribution over paths

The entry node re-draws the forward route on **every outgoing packet** and the
return route on **every SURB**, as a weighted random draw over up to
`max_cached_paths` validated candidates, with `return_path_exploration` of the
return draws made uniformly at random on purpose. A session is multipath-striped
by construction, over legs whose per-hop mixer delay is `U(0, 20) ms` and whose
end-to-end RTTs differ by hundreds of milliseconds.

That is a **variance** mechanism, not a throughput one — which matches the
symptom being chased: random performance floors, not a low ceiling.

`max_cached_paths` is a **ceiling, not a count**. The real candidate count is
the relays you hold a channel to that also hold one to the exit — single digits
to low tens, not 50. And `min_paths_anonymity_floor` is a **cap despite its
name**: `prune_for_consistency` returns early if `candidates.len() <= floor`,
otherwise prunes *down* to it, dropping highest-latency first.

That matters for reading the arms: the jura network configs set
`min_paths_anonymity_floor = 3`, so on jura **`auto` already draws from at most 3
candidates**. `narrow` then differs from `auto` mainly in weighting and
exploration, not in candidate count.

## 2 · The config keys named in the issue do not pin a path

`min_channel` / `max_channel` / relay allowlist map onto
`strategy.min_open_channels`, `strategy.target_open_channels` and
`strategy.channel_allowlist`. Those govern which payment channels the entry
opens — which relays exist as graph edges. That constrains the **forward** leg
only, and indirectly. `path = { intermediates = [...] }` was removed at config
v4→v5 and is rejected by the v6 parser.

## 3 · The real lever is one layer above hopr-lib

hopr-lib's `protocol.path_planner` is:

```rust
#[cfg_attr(feature = "serde", serde(skip))]
pub path_planner: crate::path::PathPlannerConfig,
```

`serde(skip)`, and `PathPlannerConfig` derives no serde at all. It is absent
from the config schema, so it **cannot** be set from a hopr-lib YAML — and since
`HoprProtocolConfig` is `deny_unknown_fields`, trying stops the client rather
than being ignored.

It is set in code, by gnosis_vpn, and **only when it generates the config**
(`gnosis_vpn-lib/src/hopr/config.rs`):

```rust
cfg.protocol.path_planner = edgli::latency_path_planner_config(min_ack_rate);
// Layer user overrides on top of the latency preset; unset fields keep the preset value.
path_planner.apply(&mut cfg.protocol.path_planner);
```

Those overrides are `PathPlannerOptions` — every `PathPlannerConfig` field as an
`Option` — read from gnosis_vpn's own `config.toml`:

```toml
[connection.path_planner]
max_cached_paths          = 1     # collapse the candidate collection to one path
return_path_exploration   = 0.0   # stop the uniform-random return draws
return_path_weight_temper = 1.0   # untemper the weights
```

`max_cached_paths = 1` leaves the `WeightedCollection` with a single entry, so
every packet's forward route and every SURB's return route resolve to the same
path. **A genuine pin of both legs, no recompile, no channel churn** — with one
qualification, measured on the test VM: the planner re-evaluates each
destination's entry at every cache refresh (`kind="background-refresh"`,
`refresh_period` = half of `cache_ttl`, 10 s by default) and may pick a
*different* single path. Pinned means **one path at a time**: per-packet
striping is gone, but the route can still switch every few seconds (`auto`:
3 candidates, 9 paths over 90 s; `pin-planner`: 1 candidate, 4 paths). A switch
is one discontinuity per refresh, not reordering on every packet, so it does
not undo the pin's test of the striping hypothesis — but if the floors turn out
to follow path *switches*, a longer `cache_ttl` is the next variable to try.

Setting `GNOSISVPN_HOPR_CONFIG_PATH` is exactly backwards: `from_path`
deserializes `HoprLibConfig` straight from disk and never calls `apply()`, so it
is the one mode in which the planner cannot be influenced at all. Every arm here
therefore runs in **generated** mode and differs only in the keys its
`config.toml` names.

The packaged network configs already declare `[connection.path_planner]`, so an
arm's keys must be **merged into** that table, not appended as a second one — TOML
rejects a table declared twice, and `gnosis_vpn-root` maps every config error to
exit 66. `lib/tomlmerge.py` does the merge and refuses to write a config that
does not parse; `tests/run-config-tests.sh` pins it.

---

## Hypotheses, pre-registered

Written before the run, so the analysis is not a story fitted to the data.

| # | Hypothesis | Signature if true |
|---|---|---|
| **H1** | Relays saturated by aggregate traffic | relay `hopr_egress_ring_buffer_dropped` climbs, `hopr_mixer_queue_size` grows, floors correlate with *which* relay |
| **H2** | Relays blocked in the runtime, not on CPU | `hopr_packet_decode_timeouts_total` rises while relay CPU stays well under 100 % |
| **H3** | Multipath striping + a LAN-sized reassembly window | `auto` shows high `hopr_session_frame_discarded_total` and wide p10↔p90; pinned arms show near-zero discards and a **tighter** distribution even at no better median |
| **H4** | Client aggregation onto shared relays | N clients on the same relay degrade sharply vs. N on distinct relays at equal load |
| **H5** | Loss-driven CC collapse, not missing capacity | UDP shows multi-percent datagram loss while TCP sits far below the UDP rate; BBR beats CUBIC over the same arm |
| **H6** | Path finding is not implicated | pinned and auto coincide within noise |

Not mutually exclusive — separated because they imply different fixes. H1 → more
or bigger relays. H2 → a runtime fix, and bigger machines are wasted money.
H3/H5 → size the reassembly window from measured RTT and reduce deliberate
diversity under load. H4 → spread clients across relays.

H3 predicts the pinning benefit **grows with RTT**, which is what a multi-exit
sweep tests rather than assumes.

## Metric definitions — fixed before any data

- **Session throughput** — median of the 1-second samples, first 5 s dropped;
  for a multi-rep session, the median across its repeats.
- **Floor rate** — fraction of sessions below `GVPN_FLOOR_MBPS`, set from the
  baseline's observed p25 and then frozen.
- **Tail spread** — p90 / p10 across session medians.
- **Between/within CV** — coefficient of variation across session medians, and
  across repeats within a session. The split answers "do bad sessions stay bad
  for their whole life, or flicker?"

The headline is **floor rate, p10 and tail spread** — not mean throughput. An
arm 5 % slower on average with a quarter of the floor rate is a win under this
issue's own reasoning: the stated goal is eliminating random performance floors,
not raising the ceiling.

## What this kit cannot answer

Relay-side metrics (`hopr_packet_decode_timeouts_total`,
`hopr_egress_ring_buffer_dropped`, `hopr_mixer_queue_size`) need operator access
to the relays. Without them H1 and H2 cannot be tested — only the path-selection
hypotheses. Say so in the report rather than guessing.
