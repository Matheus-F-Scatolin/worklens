# What Worklens costs the Mac

`docs/PLAN.md` has promised "< 60 MB RSS idle and negligible CPU between captures" since the
first commit, and until now nothing had checked it where a user could see. The 2026-09 review
pass came closest (`git show b077b0f:docs/reviews/2026-09-review-pass-1.md`, §5 item 2) and
concluded that **resident size is the wrong metric**, that it mostly counts the shared dyld cache,
that the criterion should be restated as *dirty footprint* (`footprint -p`, say < 60 MB), and that
"a one-hour soak under real use is still owed". This file is that recommendation finished — the
criterion restated, an hour soaked, and the half of it that still needs a person named as such.

> **Read this as one provisional run on one Mac.** Every figure below was measured in a single
> session on **2026-09-16**, on one Apple-silicon MacBook, on the installed
> `/Applications/Worklens.app` at the shipped defaults (`CAPTURE_INTERVAL_SECONDS=60`,
> `CAPTURE_SOURCE=both`, `CAPTURE_MAX_EDGE_PX=1024`, screenshots kept). It is not an average over
> machines, and two of the four figures the issue asked for could not be measured at all — they
> say so below rather than carrying a guess. The methods are written out so anyone can re-measure.

## The numbers

| What | Measured | How |
|---|---|---|
| Dirty memory, idle | **22 MB**, flat across all 65 samples, peak 25 MB | `footprint -p <pid>`, once a minute for 64 minutes |
| Resident size, idle | 72-95 MB, noisy | `ps -o rss=` in the same samples — and the reason the target is not written in this unit |
| CPU, idle | **5.9 s over 64 minutes — 0.09 s a minute, 0.15 % of one core** | `ps -o time=` deltas across the same soak |
| CPU per capture tick | **not measured** — see below | — |
| CPU to describe one frame | **≈ 0.03-0.04 s of CPU**, 1.8-1.9 s wall | `/usr/bin/time -p` on the `describe-image` command (removed in #300), three real frames, real Gemini calls |
| Bytes written per active hour | **≈ 6 MB** — 5.3 MB of screenshots + 0.8 MB of database | 20.0 active hours of this Mac's own history; method below |

Against the restated criterion — dirty footprint under 60 MB — the app has **a third of its
budget in use**: 22 MB. The old RSS wording would have read 72-95 MB and looked like a failure at
the same instant, which is exactly what the review pass said would happen.

## Method, figure by figure

**Idle memory and idle CPU.** The app was already running and the screen was locked, so every
tick was writing a `locked` row and nothing else — a true floor, not "a light day". A shell loop
sampled `footprint -p $(pgrep -x Worklens)`, `ps -o rss=` and `ps -o time=` once a minute for
64 minutes — 65 samples, no capture row written in any of them. `phys_footprint` read 22 MB in
every one of the 65, and the peak the process had ever reached was 25 MB. CPU accumulated steadily:
5.94 s across the hour, 0.09 s a minute, **0.15 % of one core** — the timer, the menu's
30-second counter refresh and the permission recheck. Resident size over the same samples wandered
between 72 and 95 MB without the app doing anything, which is the whole argument for not writing
the target in that unit.

**CPU to describe one frame.** The `describe-image` command (removed in #300) on three real JPEGs from the previous
day's `screenshots/` folder, each under `/usr/bin/time -p`, with the real Gemini key: 0.03-0.04 s
of user+sys CPU per frame against 1.8-1.9 s of wall clock. Nearly all of the wall time is waiting
on the network. The CPU figure *includes* process launch, so it is an upper bound on what the
running app pays per frame. The three calls cost $0.0017 in total and are in the ledger.

**Bytes per active hour.** Not a stopwatch — this Mac's own eight days of history, which is a
better answer than one measured hour. For each day folder under `screenshots/`, its size on disk,
against that day's count of `captures` rows with no `skip_reason` (a real capture, one per minute
of activity, so `rows ÷ 60` is an hour actually at the keyboard):

| Day | Real captures | Active hours | Screenshots | MB per active hour |
|---|---|---|---|---|
| 2026-09-08 | 108 | 1.80 | 15.6 MB | 8.7 |
| 2026-09-09 | 220 | 3.67 | 18.2 MB | 5.0 |
| 2026-09-10 | 252 | 4.20 | 19.1 MB | 4.6 |
| 2026-09-11 | 167 | 2.78 | 21.8 MB | 7.8 |
| 2026-09-12 | 185 | 3.08 | 7.1 MB | 2.3 |
| 2026-09-14 | 144 | 2.40 | 11.7 MB | 4.9 |
| 2026-09-15 | 124 | 2.07 | 12.4 MB | 6.0 |
| **Total** | 1 200 | **20.0** | **105.8 MB** | **5.3** |

The database (`worklens.sqlite` plus its `-wal` and `-shm`) was 16.4 MB across the same eight
days — 0.8 MB per active hour. Together, **about 6 MB an hour at the keyboard**, so a working day
of this shape costs 12-18 MB. A day's screenshots are what `SCREENSHOT_DISK_BUDGET_GB` prunes;
the database is not pruned, and at this rate a year of use is on the order of a gigabyte of it.

Two caveats worth keeping: `captured_at` is UTC while the day folders are local days, so a day's
two halves can be off by an hour's worth of frames; and the spread (2.3 to 8.7) is real — how much
the screen changes matters more than how long it is on, because an unchanged screen is never
photographed.

## What could not be measured, and why

- **CPU per capture tick.** A tick needs a screen to photograph. The measurement session ran
  while the Mac was locked, and `worklens capture-once` answers *"No display is available to
  capture"* — so there was no honest number to take. To measure it: with the screen unlocked, run
  `/usr/bin/time -p worklens capture-once --out /tmp/frame.png` a few times for the screenshot and
  encode alone, or sample `ps -o time=` across a window in which the app wrote *n* real capture
  rows and divide. Do not infer it from the idle figure above: the idle soak contains no capture
  at all.
- **A soak "under real use".** Same reason. The hour measured above is an idle, locked hour, which
  is the floor and not the ceiling. The honest version of that measurement is an hour of ordinary
  work with the same sampler running, which is a session with a person in it.

## Re-measuring

```sh
# Idle dirty footprint and idle CPU, once a minute.
PID=$(pgrep -x Worklens)
while :; do
  printf '%s %s %s\n' "$(date +%T)" \
    "$(footprint -p $PID | awk '/phys_footprint:/{print $2, $3}')" \
    "$(ps -o time= -p $PID)"
  sleep 60
done

# CPU per capture tick — needs an unlocked screen.
/usr/bin/time -p worklens capture-once --out /tmp/frame.png
```

The bytes-per-hour table is `du` over `screenshots/<day>/` against
`select date(captured_at), count(*) from captures where skip_reason is null group by 1`.

## What the app now says for itself

Settings → Usage → **Data folder** gives the size of `DATA_DIR`, and the meter above it how much
of `SCREENSHOT_DISK_BUDGET_GB` the screenshots use. The seven-day MB-a-day row that once sat
there went with the rest of the distribution-era support kit in #301.

And `CAPTURE_ON_BATTERY` (#145) is the other half of the answer: on battery, or in Low Power Mode
on the charger, the interval stretches five-fold and the menu says so. See
`docs/architecture.md` → "The battery policy is one pure function".
