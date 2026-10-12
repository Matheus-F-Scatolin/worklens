# Test fixtures

The golden files the timeline renderer is checked against.

| file | what |
| --- | --- |
| `timeline-golden.md` | what `TimelineRendererTests` expects the renderer to print for its day |
| `timeline-context-golden.md` | a day with a meeting and its context events (`ContextTimelineTests`) |

The invented day of undescribed frames the fake pipeline tests describe lives in
`Tests/WorklensCoreTests/SampleDay.swift`, as Swift constants rather than a JSON file.

Nothing here is real.
