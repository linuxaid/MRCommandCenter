# App icon concepts (issue #1)

Five directions to pick from before an icon goes into the app. Each is a 1024×1024 SVG on the
macOS icon grid (824 pt tile, 185 pt corners), drawn in the app's own palette from
`Features/CommandCenter/Theme.swift`. The PNGs are 512 px previews.

| # | Concept | Idea |
| --- | --- | --- |
| 1 | Readiness Rail | The four-segment rail from every triage row (CI · Approvals · Threads · Mergeable), three green and one waiting. |
| 2 | Merge Check | A branch curving back into main, landing on a green check. Dark tile so it stands out in the Dock. |
| 3 | Radar | "Command center": a sweep over your MRs, one blip per lane color. |
| 4 | AI Lens | A magnifier over a diff, with the purple AI sparkle. Leans on review over overseeing. |
| 5 | Triage Stack | Stacked MR cards, the front one ready to merge, on the "Your Move" orange. |

Once one is chosen, it gets refined and built into an Icon Composer `.icon` for the app target.
