# Scale, and the three studies

## Why it takes as long as it does

Not the transfers. A 25 MB leg at 5 Mbit/s is ~42 s, so a down-plus-up session
moves data for ~84 s — but costs ~3 min:

| | |
|---|---|
| connect + first path draw | 40 s |
| the transfers | 84 s |
| settle, disconnect, cooldown before the next arm | 45 s |
| UDP probe + inter-leg gaps | 20 s |

The cooldown is not padding: without it the next arm inherits the last one's
SURB balancer estimate and path cache, which is the contamination interleaving
exists to avoid.

```
wall clock  =  ~3 min  ×  arms  ×  exits  ×  cycles
```

## Cutting arms is not like cutting cycles

Arms and exits are coverage: drop one and you learn less, but what remains is
still true. Cycles are resolution: drop them and what remains starts lying.

Below **8 sessions per arm** the bootstrap returns nothing, so every confidence
interval disappears. Below **30** the report prints a caveat.

Same simulated effect, same ~1¼ h (`tests/mkrun.py`, scenario `thin`):

| | 5 arms × 5 cycles | 2 arms × 12 cycles |
|---|---|---|
| wall clock | 1 h 18 m | 1 h 15 m |
| sessions per arm | 5 | 12 |
| verdict | *"Too few sessions to separate the arms"* | *"Suggestive but not conclusive: +635% (-13 … +784)"* |
| intervals | none | present, honest about spanning zero |
| `no-explore` | **−74 %** — apparent harm from an arm configured to help | not run |

That −74 % is sampling, not misconfiguration: five sessions cannot estimate a
10th percentile, so one unlucky session inverted the sign. With five arms you
get five chances to publish something backwards. And at n=5 the floor rate can
only be 0, 20, 40, 60, 80 or 100 % — the headline number has six possible values.

**Spend a fixed budget on cycles before arms.**

| Config | Wall clock | Sessions/arm | Answers |
|---|---|---|---|
| `smoke`, 5 arms | ~10 min | 1 | does every arm's config load |
| `quick`, 2 arms | ~25 min | 3 | `auto`'s p25, for the floor |
| `transfers`, 2 arms, 12 cycles | ~1 h 15 m | 12 | is there a signal worth chasing |
| **`transfers`, 2 arms, 30 cycles** | **~3 h 10 m** | **30** | **a quotable floor-rate result** |
| `transfers`, 5 arms, 30 cycles | ~7 h 50 m | 30 | which lever, one exit |
| `soak`, 5 arms, 3 exits | ~36 h | 60+ | the full matrix, exit as a dimension |

Start at three hours. Only spend the 36 if the answer turns out worth arguing about.

---

## Three studies, not one run

Six arms. The boundary is node-global state: an arm that changes the node's
channel set changes it for every other arm in the run.

| Study | Arms | Why separate |
|---|---|---|
| **1 — planner** | `auto` `pin-planner` `no-explore` `narrow` `zero-hop` | — |
| **2 — return leg** | `pin-cfg-<relay>` `pin-cfg-pinned-<relay>` | needs the channels trimmed to one relay |
| **3 — restore** | `auto` | confirms the node came back |

### Study 1 — the planner arms

All five interleave in one run; none touches channels or identity.

```sh
make launch STUDY=2026-09-24-transfers-25mb
```

`zero-hop` needs `--allow-insecure` and sends with no relay, so the exit sees
this VM's IP. Fine on a throwaway box; drop it from `GVPN_ARMS` otherwise.

| Comparison | Answers |
|---|---|
| `auto` vs `pin-planner` | does pinning raise the floor at all? **If no, stop** — studies 2–3 answer nothing |
| `auto` vs `no-explore` | is it specifically the 10 % random return draws? A one-line fix if so |
| `pin-planner` vs `narrow` | how much diversity survives? Close means a shippable setting |
| `zero-hop` vs the rest | the ceiling — how much of the gap is the relay at all |

### Study 2 — the return leg

**Only if study 1 showed a gap.** Pick a relay that carried traffic and
performed around the median — the best one biases the arm upward.

```sh
make arms                                          # renders the pin-cfg PAIR
sudo ./bench/use-arm.sh pin-cfg-0xRELAY…           # allowlist FIRST, so nothing reopens
sudo -E ./tools/close-channels.py --keep 0xRELAY --send
#   wait out the grace period — --list says when
sudo -E ./tools/close-channels.py --finalize --send
sudo ./bench/use-arm.sh pin-cfg-0xRELAY… --count   # must read 1
make launch STUDY=<your-return-leg-study>
```

Both arms hold the same allowlist and the same one-channel topology; they differ
only in whether `max_cached_paths = 1` collapses the return draw. **The gap
between them is the return leg.** Both read 1 route — expected, since the count
only sees the forward path.

The first close is sent alone and verified on-chain; if that canary fails,
nothing else was touched.

Keep `GVPN_PIN_VERSION` and `GVPN_FLOOR_MBPS` identical to study 1, or the two
are not comparable. `auto` cannot be a baseline here — on a one-channel node it
is not auto.

### Study 3 — restore

The step people skip. While trimmed, this node is not a normal client.

```sh
sudo ./bench/use-arm.sh auto                        # drops the allowlist
watch -n 60 'sudo -E ./tools/close-channels.py --list'
sudo -E ./bench/gvpn-bench.sh --profile quick && make report
```

Its `auto` should match study 1's. If not, the node has not recovered and
anything measured next is suspect.

## Things that will bite

| | |
|---|---|
| Mixing `auto` into study 2 | on a one-channel node `auto` is not auto |
| Different `GVPN_PIN_VERSION` between studies | compares versions, not routing modes |
| Re-picking `GVPN_FLOOR_MBPS` per study | makes the headline whatever you wanted |
| Picking the best relay for `pin-cfg` | biases the arm upward |
| Skipping study 3 | every later measurement is on a one-channel node |
| Re-rendering arms mid-study | changes what the remaining cycles measure; restart it |
