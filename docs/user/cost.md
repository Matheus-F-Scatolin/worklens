# What Worklens costs

You pay Google directly, for your own key. There is no Worklens subscription, no
account and no margin in the middle — nothing is charged by this project, ever.

## At the defaults

An 8-hour day at `CAPTURE_INTERVAL_SECONDS=60` is 480 frames, of which roughly 40 % survive the
change and metadata filters and are actually described (≈ 200 calls).

| What | How it adds up | Per day |
|---|---|---|
| Describing frames — Gemini 3.5 Flash-Lite | ≈ 200 calls × ~$0.0005 measured per frame | ≈ $0.10 |
| **Total** | | **≈ $0.10 / day ≈ $2 / month** |

That is the whole bill: describing frames is the only call Worklens makes for you. The daily and
weekly reports, which used to be most of it, were cut on 2026-10-05.

The describe figure is measured rather than estimated: a text-first frame costs $0.00043 (537
prompt tokens) and a frame carrying a JPEG $0.00050–$0.00053, from the runs recorded in
[`docs/decisions.md`](../decisions.md) — which also has the original derivation and the older,
higher image-only numbers from before describing became text-first. A quiet day costs less
because fewer frames change; a day of back-to-back different screens costs more.

**Your own number is in Settings → Usage**, and it comes from the ledger rather than from this
page: today against the budget, and the last 30 days by purpose. The MCP `stats` tool reads the
same ledger.

## The hard stop

`DAILY_BUDGET_USD` (default `1.50`, in `.env`) is a hard stop on describing frames, not a
warning. Past it, frames are still captured but queue up as "over budget", and the menu-bar icon
changes to say so. The menu then offers **Allow $X more today…**: it raises the budget for today
alone — tomorrow starts on `DAILY_BUDGET_USD` again — and puts the frames today already skipped
for budget back in the queue, so they are described rather than dropped. Settings → Usage
carries the same raise while summarizing is on hold, beside the **Daily budget** field that changes
the budget for good.

Nothing raises the budget on its own, and Worklens can only spend against a key you put in `.env`
yourself.

## Reading the spend table

Settings → Usage charts the last 30 days of spend, one bar per day, and **Copy as CSV** copies the
same numbers. Days are **local**, so a day's bar closes at your midnight, not UTC. The bar splits
into the things that cost money — **Summaries**, and **Reports** on a day from before the reports
were cut — plus **Other**: spend recorded against a feature that no longer runs, or against a
model this build no longer calls. It is never zero
retroactively, which is why an older day can still add up to more than its parts explain.

Past the disk budget, whole day folders of screenshots are deleted oldest first — never today's or
yesterday's — and the summaries and timeline for those days stay.

## If it needs to be cheaper

- **Capture less often.** `CAPTURE_INTERVAL_SECONDS=120` roughly halves the describe line, at the
  price of a coarser timeline.
- **Send smaller images.** `MEDIA_RESOLUTION_LOW` halves the image tokens of the frames that do
  carry a picture. With `CAPTURE_SOURCE=auto` and Accessibility granted, a window whose own text
  already covers it is described from that text and never photographed at all.
- **Use a cheaper describer.** `DESCRIBE_MODEL=gemini-2.5-flash-lite` ($0.10 / $0.40 per M) takes
  the describe line to a few cents a day.

Screenshots cost disk rather than money: `SCREENSHOT_DISK_BUDGET_GB` (default 20) prunes whole day
folders, oldest first, never today or yesterday. The descriptions and timelines stay.
`RETENTION_DAYS` is the other half of that — an age rather than a size, and it takes the rows as
well as the pixels. How much a day of use costs in megabytes, and what a pass leaves behind, is in
[data.md](data.md).
