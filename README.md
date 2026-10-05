# ASPN — D1 Women's Basketball Dashboards — R pipeline

The **ASPN** wordmark (top-left of every page) is a from-scratch SVG
badge styled after ESPN's original 1979 broadcast logo — a thick
rounded-pill outline around a plain, bold, upright block wordmark —
recolored to this dashboard's own palette instead of ESPN's
orange/red: a bright **neon-green** oval around a **baby-blue**
wordmark. That same baby blue is also this page's default accent
color (search focus states, active tabs/toggles, buttons) wherever a
per-team color hasn't taken over — e.g. on the homepage, the Player
Leaderboard, and Conferences, where there's no single team to theme
around. Both colors are CSS variables (`--brand-blue` /
`--brand-green`, defined in `:root` near the top of
`dashboard_template.html`) if you ever want to retune them.

Regenerates `team_dashboards.html` (every D1 team, full season game
log, four factors, box scores, opponent-adjusted ratings, top-7-by-MPG
with height) from real data every time you run it. No API key, no
scraping of barttorvik.com directly (see the comment at the top of
`build_dashboards.R` for why).

The homepage is a sortable ranking of every D1 team — Rk, Net
Rtg, Adj. Offense, Adj. Defense, eFG%, opponent eFG%, TOV%, opponent
TOV%, OREB%, opponent OREB%, FT rate, 2PT%, opponent 2PT%, 3PT%,
opponent 3PT%, 3PT rate, opponent 3PT rate, Tempo, and record — click
any column header to sort by it (click again to flip direction). The
Rk column always shows each team's position in the *current* sorted,
filtered list, so sorting by a different stat re-ranks 1 to N by that
stat instead. Net Rtg is Adj. Offense minus Adj. Defense.

**As of w1.9, Adj. Offense, Adj. Defense, Net Rtg, and Tempo come from the
same ridge model as the Projections tab, fitted in the build and shipped
into the page (see "w1.9" below). The paragraphs here describing an
iterative in-page model, a margin-of-victory dampener and a fixed home-court
constant describe w1.8 and survive only as the page's fallback when a build
ships no ratings.** Before w1.9: ratings were computed in the page itself,
not pulled pre-computed from an outside source. On
load, `dashboard_template.html` runs an iterative opponent-adjustment
model — the same general approach Bart Torvik's T-Rank and Ken
Pomeroy's ratings use — over that team's full-season, game-by-game
box scores (already embedded in the file for the Game Log): every
team starts at its raw per-game efficiency, then each team's rating
is repeatedly re-weighted by how strong its opponents turn out to be,
until the numbers stop moving (usually 20-40 passes). A home-court
adjustment (`HCA_PTS` in the template, about 4.0 points per 100
possessions, taken from the projection model's fit) is applied first
so a home-heavy or road-heavy schedule doesn't distort the result;
neutral-site games, marked from the schedule file, get none. This won't match
barttorvik.com's own numbers exactly — the home-court constant is an
approximation and Torvik's model has details (recency weighting,
garbage-time filtering, etc.) that aren't public — but it should track
it much more closely than an unadjusted average would, and it updates
automatically every time this file is rebuilt from fresh box scores.
These computed ratings are what every Rk / Adj O / Adj D / Net Rtg /
Tempo value on the page shows, including each game's Opponent-rank
columns in the Game Log and the Opponent-rank filter itself.

**Two free-throw coefficients, on purpose.** Possessions (used for
ORtg/DRtg and the adjusted ratings) are estimated as FGA − OREB + TOV +
**0.475**·FTA, KenPom's college coefficient. TOV%, TS%, and USG% instead
divide by *plays*, FGA + **0.44**·FTA + TOV, the Oliver /
Basketball-Reference convention. If a number here looks slightly off from
another site, check which of the two that site uses first. The adjusted
ratings iterate until no team's AdjO/AdjD moves more than 0.001 per 100
possessions (safety cap: 60 passes); `ADJ_RATINGS_DIAG` in the browser
console shows how many passes the current build actually needed.

**Every stat column with more than a couple of values also carries a
percentile color scale** (green = best in the currently-shown set, red
= worst, fading toward the middle) — on the homepage rankings table,
on each team's Team Profile panel, and on each team's Game Log
ORtg/DRtg columns. This is recomputed on every render from whatever
rows are actually on screen, so filtering the homepage to one
conference re-shades the colors relative to just that conference, and
windowing a team's Game Log to "last 10 games" re-shades relative to
just those 10 games — the color scale is never fixed against the full
361-team season.

Team logos (pulled live from ESPN's logo CDN by team ID, with an
automatic colored-initials fallback if a logo isn't available or the
browser has no internet connection at view time) appear next to team
names throughout — the rankings table, search results, and each
team's own dashboard header.

Three filters sit above the table: Conference narrows which teams are
listed; Games and Opponent rank (last 5/10/15/20 games, and/or Top
10/25/50/100, 101–200, Bottom 25/50/100, or a custom rank range) each
recompute every team's shooting/four-factor columns and record from
just the matching subset of *that team's own games* — so "last 10
games vs. Top 50 opponents," for instance, re-ranks the whole board
by however that window looks. **As of w1.9, Net, AdjO and AdjD on the
Rankings table follow the Games / Opponent-rank window** (see "w1.9" below);
Tempo and the Torvik-style overall rank stay season-long. Before w1.9 all of them
stayed season-long, on the reasoning that an opponent-adjusted
rating can't be recomputed from a game subset — instead, the Rk column reflects
position under the *current sort*, however the other columns are
being filtered. Everything's computed client-side from the same
full-season game logs the team dashboards use, so there's nothing
extra to fetch. Click a team's name to open its dashboard.

Every team's own dashboard has the same kind of filters: location
(home/away/neutral), Games (last 5/10/15/20), opponent rank (same
presets and custom range as the homepage), and conference
(conference-only / non-conference). Setting any filter recomputes the
record, Team Profile table (every shooting/four-factor stat and its
opponent side — eFG%, TOV%, OREB%, FT rate, 2PT%, 3PT%, 3PT rate, and
each stat's opponent version — each with its national rank
re-computed live against all 361 teams under that same filter), the
Game Log (which now also carries every game's own eFG%/TOV%/OREB%/FT
rate/2PT%/3PT%/3PT rate as Team-vs-Opponent pairs, bold marking
whichever side won that stat, alongside ORtg/DRtg and the opponent's
season ranks), and the rotation table, from just the matching games —
all done client-side in the browser, instantly, since the full
season's data is already loaded. Torvik-style overall
rank and Tempo stay season-long regardless of filters; Adj. Offense,
Adj. Defense and Net follow the Rankings table's window (w1.9) but are
not windowed on this page.

The Game Log also shows an ORtg and DRtg (points scored/allowed per
100 possessions) for every individual game, estimated from that
game's own box score (possessions estimated from each side's
FGA − OREB + TOV + 0.475×FTA, averaged across both teams). These are
per-game numbers, not the season-long opponent-adjusted Adj.
Offense/Adj. Defense in the KPI row above, so don't expect them to
match — a per-game rating against a weak or strong opponent will
swing a lot more than the adjusted season figure does.

A Recent Form strip (last up to 10 games, oldest to newest left to
right, clickable to the box score) and a second KPI row round things
out: Close Games (record in games decided by 5 points or fewer),
Home/Away/Neutral splits, and Sched. Strength (average opponent
Torvik rank faced). Like the rest of the dashboard below the filter
bar, all four recompute live from whatever games the active filters
match.

**Player Stats** shows up to 12 players (or fewer, for a short
bench), sorted by MPG, recomputed from whichever games the filters
above currently match. The same **Basic Stats / Advanced-Value** and
**Per Game / Season Total** toggles described under Player
Leaderboard above sit right over this table too, and work exactly
the same way here. A third tab, **Shooting by Zone**, shows
the same players' zone makes/attempts per game, FG%, and shot share
(Rim, Paint, Mid, Corner 3, Above-the-Break 3), the same grouped
layout as the Player Leaderboard's zone view but limited to this
roster and following this page's filters (including Opponent rank).
The Per Game / Season Total toggle switches Mk/G and At/G to FGM and
FGA. It starts in rotation order; click any column to sort. Each row is shaded by percentile within that same
roster (recomputed for whichever stat family/mode is currently
showing). Click a player to open her full player profile page.

**Player(s) in/out filter**, in the same toolbar: pick one or more
players and set them to "Played (in)" or "Did not play (out)" to see
how the team's record and stats shift with a player available vs.
missing — the natural way to gauge an injury's impact. "All
selected" requires every picked player to match the condition; "Any
selected" needs just one (useful for "at least one starter was out"
type questions). This filter is specific to whichever team's
dashboard is open — its player list rebuilds from that team's own
roster every time you switch teams — and it narrows that team's own
numbers only; it does not change what the team is being ranked
against nationally, since a roster only makes sense for one team.

### Advanced analytics (Havoc, WAB, Luck, Quad Record, and more)

Six more season-long columns on the Rankings table, and a matching
KPI row on every team's page, all computed client-side alongside the
opponent-adjustment model:

- **Havoc Rate** — steals + blocks forced, per 100 opponent
  possessions. A fan-built approximation of Torvik's stat of the
  same name (the exact published formula isn't public).
- **Assist Rate** — team assists as a share of made field goals; a
  simple read on how much of the offense is generated by passing.
- **Luck** — actual wins minus a standard Pythagorean win
  expectation (from points for/against), D1 games only. Flags teams whose record is
  running hot or cold relative to their point differential; being
  "unlucky" isn't a knock on the team, just a signal the record may
  not hold.
- **WAB (Wins Above Bubble)** — an *approximate* Wins Above Bubble:
  how many more/fewer wins a team has than a bubble-quality team
  (proxied as the average rating of teams ranked ~45th-65th, tunable
  via `BUBBLE_RANK_LO`/`BUBBLE_RANK_HI` in the script) would be
  expected to get from the exact same schedule. Each game's win chance
  uses the projection model's fitted single-game spread (about 11.3
  points) and the same home-court edge as the ratings. This uses our own rank, not the
  NCAA's official NET, so treat it as directionally right, not the
  committee's number.
- **SOS Rk / Radar** — SOS Rk is the average national rank of every
  opponent faced (1 = toughest schedule). Radar is SOS Rk minus the
  team's own AdjEM rank — a big positive number means the team's
  opponent-adjusted numbers are far ahead of the level of competition
  that's actually seen them: a flying-under-the-radar candidate.
- **Quad Record**, on each team's own page — an NCAA-style Q1-Q4
  breakdown (thresholds depend on both opponent rank and game
  location, same shape as the committee's system) computed against
  our own rank. The committee reviews its exact cut lines most
  years, so treat these as close, not gospel.

Each team's page also gets an **auto-generated identity blurb** (a
plain-language read of the team's own offense/defense/four-factor/
Havoc/AST ranks, plus Luck/WAB/Radar context when notable) — built
entirely from numbers already on the page, phrased as a sentence
instead of a row of cells. (An earlier version of this page also
showed a net-rating trend sparkline here; it's been removed.)

### Player Leaderboard, Conferences, and Compare Teams

Three tabs above the Rankings table:

- **Player Leaderboard** — every rostered player in the country
  (not just one team's roster) in one sortable, filterable table.
  Two toggles sit above it: **Basic Stats / Advanced-Value** picks
  which stat family is shown (GP/MPG/PPG/.../USG% vs. the Player
  Value stats below), and **Per Game / Season Total** switches every
  counting stat in whichever family is active between a per-game
  rate and a season total at once (shooting/ratio stats like FG%,
  TS%, USG%, AST/TO, and the rate-based OBPM/DBPM/BPM/BPR don't have
  a meaningful "total," so they read the same in both modes — the
  column tooltip says so on hover). Filterable by conference,
  position, minimum games played, or a name/team search either way.
  Click a team to jump to its dashboard, or click a player's name to
  open her own **player profile page** (see below). The table shows
  100 players at a time with a **Show more** button at the bottom;
  ranks and color shading are always computed against every player
  matching the filters, not just the ones on screen, and changing any
  filter or sort starts back at the top 100.
- **Conferences** — every conference ranked by average AdjEM, with
  team count, average national rank, Top 100 count, and that
  conference's best team.
- **Compare Teams** — pick any two teams and get a side-by-side
  read on record, AdjO/AdjD/Net/Tempo, four factors, Havoc/AST%,
  Luck/WAB, and schedule strength, with the better side of each stat
  highlighted. A **Games** filter (full season, or last 5/10/15/20)
  sits alongside the existing opponent-rank filter and recomputes
  Record, Raw O/D/Net, and the four-factor rows from just that many
  of each team's most recent games; Torvik Rank, Adj O/D/Net/Tempo,
  Havoc/AST%/Luck/WAB/SOS stay season-long for the same reason they
  do everywhere else on this page. Above the table, a **Four Factors
  radar** plots both teams' national percentile on eFG%, TOV%, OREB%,
  and FT Rate, with an **Offense / Defense** toggle (defense plots
  what each team allows, with Forced TOV% as opponent turnover rate).
  Further from the center is always better on every axis. The shape
  is season-long; the numbers in its legend follow the filters.

### Stat filters on every leaderboard

Team Rankings, Player Leaderboard, Shot Zones, and Conferences each
have a **Stat filters** row at the bottom of their filter bar: pick a
stat, choose *at least* or *at most*, type a value, and press **Add**
(or Enter). Each filter shows as a chip; tap its **×** to remove it,
or press Reset to clear everything. Values are in the same units the
table shows, so 45 means 45%. Players with no value for a filtered
stat (FG% with zero attempts, say) are left out.

- **Stats** come from the columns in the view you're looking at, and
  each filter stays with that view. "PTS at least 20" added under
  Basic Stats > Per Game doesn't carry over to Season Total, where PTS
  means total points; switch back and it returns.
- **Games and minutes** are always in the list, even when the table
  isn't showing them, and apply in every view: GP, MPG, and total
  minutes for players; GP (games in the current window) for teams.
  Conferences have neither, since neither means anything for a
  conference.
- Filtering happens before color shading, the same as the other
  filters, so the shading re-ranks within whatever is left.

### Shooting by zone: Per Game / Season Total, and Opponent rank

All three zone tables (Player Leaderboard > Shooting by Zone, the Shot
Zones tab, and a team page's Player Stats > Shooting by Zone) now have
a **Per Game / Season Total** toggle. Season Total shows FGM and FGA
instead of makes and attempts per game; FG% and Sh% are the same in
both. Sorting by a makes or attempts column carries over when you
switch.

Player Leaderboard > Shooting by Zone also has an **Opponent rank**
filter (Top 25, Top 50, a custom range, and so on). It rebuilds each
player's zone numbers, GP, and minutes from only her games against
opponents in that range, so Min. games and the GP/minutes stat filters
count games within that window too. A team page's zone tab already
follows that page's own Opponent rank filter, and gives the same
numbers for the same window.

On phones and tablets, tap any dotted-underlined label, column header,
or stat name to see its explanation at the bottom of the screen (the
hover tooltips used on desktop don't exist on touch screens).

The homepage also leads with a **Stat Corner** widget — Biggest
Overachiever and Unluckiest Team (by Luck), Sleeper Alert (by
Radar), Havoc King, Best Ball Movement, and Best Resume (by WAB) —
recomputed from the same numbers every time the page loads, so it's
always pointing at whatever's actually unusual in the data that day.

### Player Value: BPM, VORP, wins above replacement, GmSc/40

Every player with logged minutes gets four value stats, each split
into **offense / defense / total** columns on the Player Leaderboard,
the Team Profile's Player Stats table, and her own player profile
page. **w1.9 corrected two of them and renamed two** (see "w1.9" below):

- **BPM (Box Plus/Minus)** — points per 100 possessions above an
  average D1 player, from sportsdataverse's `wbb_player_value`
  release. The one Player Value stat that isn't a from-scratch
  approximation.
- **VORP** — `(BPM - replacement) x share of team minutes x
  (TeamGames / FULL_SEASON_GAMES)`. Replacement is -1.0 offense / -1.0
  defense. The share of team minutes is a player's minutes over the
  minutes her team played (summed player-minutes / 5). Through w1.8 it
  was divided by summed player-minutes, so every VORP was about a
  fifth of its true size.
- **WAR (wins above replacement; was "Win Shares")** — a team's actual D1
  wins minus the wins a replacement-level team (the 5th percentile of
  D1, `REPL_TEAM_Q`) would be expected to get on the same schedule,
  home/away/neutral included, shared among her players by positive
  VORP. A team's players add up to that number, and it can't exceed
  games played. The old version divided VORP by 2.7 (an NBA constant that
  should have multiplied) and topped out at 2.1. The payload keys are
  still `ws_*`. Replacement level is an assumption, not a fitted value.
- **GmSc/40 (was "BPR")** — Hollinger's public Game Score per 40
  minutes, split offense/defense. Renamed because "BPR" is also the
  name of EvanMiya's Bayesian rating. Payload keys are still `bpr_*`.

A player with too few minutes for the `wbb_player_value` release
shows GmSc/40 (computed from her own box score) and blanks for the rest.

### Individual Player Profile pages

Clicking a player's name — from the Player Leaderboard or from a
Team Profile's Player Stats table — opens her own page: a season
stat line (per-game averages and shooting splits, basketball-
reference style), season totals, the four Player Value stats above,
and her full **season game log** (every game, not just the last 10),
with each date clickable through to that game's box score. A back
button returns to wherever you came from.

## Shot Zones: Team Shooting/Defense by Zone, Player Shooting by Zone

Every team page now has two more tables, right below Player Stats:
**Team Shooting by Zone** (this team's own shot profile) and **Team
Defense by Zone** (what it allows). Every player's page now has a
**Shooting by Zone** table too. All three break shots into five zones
— Rim, Paint, Mid-Range, Corner 3, Above-the-Break 3 — with makes/game,
attempts/game, FG%, and that zone's share of total shot volume, each
FG% cell shaded by percentile the same way everything else on this
page is.

**Team Shooting/Defense by Zone use the exact same Games / Opponent-
rank / Location / Conference / Player(s) filters already at the top of
the Team Profile page** — no new controls, they just plug into the
same `filtered` games array everything else there already recomputes
from. **Player Shooting by Zone gets its own Games + Opponent-rank
filter bar**, matching the Team Profile page's filter exactly (same
option list, same custom-range behavior) — the rest of a player's page
(Season Stats/Totals/Value/Game Log) stays season-long, same as
before; only this one new section responds to it, and it resets to
"Full season / Any rank" every time you open a different player.

### League-wide: a new Shot Zones tab, and a third Player Leaderboard view

Beyond the per-team/per-player tables above, there are now two more
places to see zone stats, both in the same sortable, every-row-at-once
style as Team Rankings and the Player Leaderboard:

- **A new top-level "Shot Zones" tab** (next to Team Rankings / Player
  Leaderboard / Conferences) — every D1 team in one table, toggled
  between **Offense by Zone** and **Defense by Zone**, with its own
  Conference / Games / Opponent-rank (+ custom range) / team-search
  filter bar. Click any of the 20 zone-stat columns (4 stats × 5
  zones) to sort by it — FG% is percentile-shaded, recomputed against
  whichever teams are currently on screen, same as Team Rankings.
- **A third Player Leaderboard view, "Shooting by Zone"** — sits
  alongside the existing Basic Stats / Advanced-Value toggle, reuses
  that page's existing Conference / Position / Min. games / Search
  filters (season-long, matching how Basic and Advanced already work
  there — this is the one zone table that does *not* get its own
  Games/Opponent-rank filter, to stay consistent with its two sibling
  tabs on the same page rather than being the odd one out). Every
  rostered player who's logged at least the minimum games, one row
  each, sortable by any zone column.

Both new tables are built with the same grouped-header layout (one
header row naming the zone, a second row for Mk/G · At/G · FG% · Sh%
under it) so five zones × four stats fits in one legible table instead
of a zone-picker dropdown.

**How the zones are built, and what to trust:** there's no official
ESPN "zone" field on a shot. These come from `espn_wbb_pbp`'s own
`coordinate_x`/`coordinate_y` (hoop-relative feet) plus its
`points_attempted` field. 2-point vs. 3-point is exact, straight from
`points_attempted`, not geometry. The 5-zone split within that is a
distance + sideline-proximity heuristic (see the comment above the
shot-classification code in `build_dashboards.R`) — not an official
zone definition, but checked against this season's real play-by-play
before being wired in: realistic shooting percentages by zone (~59%
at the rim, ~40% in the paint, low-to-mid-30s% on mid-range and both
three-point zones), and for 306 of 309 games spot-checked, shot-zone
field goal attempts summed to *exactly* that team's box-score FGA. Of
the 3 that didn't: one game has no play-by-play shot data available
upstream at all (shows as all-zero zones rather than guessing), and
two were off by exactly one shot — the kind of small pbp-vs-box-score
discrepancy that's normal any time two different upstream processes
(a play-by-play feed and a box-score compiler) generate numbers for
the same game independently. Treat zone stats the way this dashboard
already treats Havoc Rate, WAB, and Luck: a clearly-labeled,
verified-to-be-reasonable approximation, not an official stat. A
small number of games league-wide have no shot-location data at all
and will show as all zeros in these tables.

One implementation note, in case anything ever looks off after a
future rebuild: this pbp feed's own `type_text` for a made free throw
is the single word `"MadeFreeThrow"`, not `"Free Throw"` with a space
— an easy thing to miss if you're used to the WNBA feed's spacing
convention (which this shot-classification code was originally
adapted from), and if a filter for it ever regresses back to expecting
a space, made free throws will silently leak into the 2-point zone
buckets and inflate every zone's makes/attempts by a consistent
20-30% per game. The current filter (`grepl("free\\s*throw", ...,
ignore.case = TRUE)`) matches either spacing, and this was caught and
verified against the real box scores (see above) before shipping.

## Game Recaps and Matchup Previews (w1.10)

Every link that used to open a box score (a Game Log date, a Recent Form
chip, a game in a player's log) now opens a **Game Recap**, and every
scheduled game can open a **Matchup Preview**. Both appear in the same
pop-up, with a row of section buttons at the top to jump around.

### Game Recap (finished games)

- **The story.** A short write-up generated from the game itself: who won
  and how (comeback, wire-to-wire, overtime), the biggest run, the factor
  that decided it and how many points it was worth, the best individual
  game, the most out-of-character team stat, and whether it was an upset
  by season ratings (or, in season, how the model's pregame pick did).
  Beside it, key numbers: possessions and pace, points per 100, lead
  changes and ties, time leading, largest leads, biggest run, win-chance
  swings, and a **performance rating** for each team.
- **Performance rating** = the game's efficiency margin (points per 100
  possessions) + the opponent's season Net Rtg - home court. It's on the
  Net Rtg scale, so a team averages out near its own Net Rtg; the recap
  also ranks the game among that team's season.
- **Game flow.** The score margin through the game, with quarter lines and
  a hover/tap readout of the score at any moment, plus a switch to ESPN's
  live win probability. Below it, **quarter-by-quarter scores**.
- **Why it ended this way.** The final margin split into five parts that
  add up to it exactly: field-goal shooting, free throws, turnovers,
  offensive rebounds, and possessions/other. With A = FGA + 0.44 x FTA
  (scoring attempts) and P = points per attempt for each side,
  margin = (A_team - A_opp) x avg(P) + (P_team - P_opp) x avg(A): "more
  chances" plus "better chances." Turnovers and offensive rebounds are the
  two ways one team gets more chances; free throws are separated out of
  the efficiency part. Beside it, a comparison table: each team's number in
  pace, points per 100, the four factors, 3PT%, 2PT%, FT% and 3PA rate, an
  **Edge** column showing the gap between the two teams (the better team
  and the size of the gap, with an arrow toward its column: eFG% of 49.3 against 30.6 is
  +18.7%, in percentage points; lower is better for TOV%), and a small
  number beside each value showing how it compared with that team's own
  season average (green better, red worse). A tally above the table counts
  which team had the better number in how many stats; pace and 3PA rate are
  style, so they stay grey and aren't counted. Hover an edge for the gap as a
  percent of the other team's number.
- **Team stats** in two tables (shooting and scoring; possession and
  defense) laid out like the comparison above: the better number in each row
  is bold and tinted in its team's color, makes-attempts and offensive
  rebounds sit in small type beside it, and the Edge column shows the gap;
  **shot zones** for both teams in the game against their season FG% by
  zone; **standouts**: the top three on each side by Game Score, with points
  vs. her season average, season highs and true shooting.
- **Box scores** gain TS%, Game Score, points vs. her season average, and
  team totals. Player names open the player's profile; team names open the
  team's dashboard. Other meetings that season link to their own recaps.

**Where game flow comes from.** The play-by-play file this script already
downloads for shot zones also carries the running score, period, clock and
ESPN's live win probability for every play. The old note that quarter scores
weren't available was wrong: they come from the same file. New in
`build_dashboards.R`: `build_game_flow()` packs, for each game, the
end-of-quarter scores, every change in the score margin with its game
time, and ESPN's win probability at each change, into a new `flow-data`
block (about 400 bytes a game, roughly 2-2.5 MB for a full season on top of
the ~20 MB page). The page checks each game's play-by-play final against
the box score and says so if they disagree; quarter scores only show when
they add up to the final. If the play-by-play is missing or lacks a
column, the build warns and recaps simply leave the flow sections out.
Elapsed time assumes 10-minute quarters and 5-minute overtimes.
`build_dashboards.R` and `dashboard_template.html` should come from the
same version; an older template just skips flow data (with a warning).

### Matchup Preview (scheduled games)

Opens from: the **Matchup** button on each game in Games & Matchups, the
schedule on each Team Outlook (generated league games and placeholders
too), **Full matchup breakdown** under the Matchup Predictor (any two teams,
any venue), and a new **Up next** strip on every team dashboard. Finished
games in those places show **Recap** instead, when their box score is in
the file.

- **Overview:** win chances, projected score, line, total and possessions
  from the projection model (the same numbers as the Games tab, injuries
  included), days of rest, and new-coach flags.
- **Tale of the tape:** the projection (Net, Adj O/D, tempo, returning
  minutes, projected record, NCAA odds) next to the box-score profile (Net,
  Adj O/D, record, schedule strength, WAB, close games, Havoc, assist
  rate), with national ranks and bars.
- **Matchup battles:** each offense against the other defense in eFG%,
  turnover rate, offensive rebounding, FT rate, 2PT%, 3PT% and 3PT attempt
  rate. Each row shows both sides' national rank, an expected value for this
  game (offense + defense - D1 average), and an edge marker when the two
  sides' percentiles differ by 15+ points (++ for 45+).
- **Key edges:** the biggest of those gaps written out, plus tempo and
  three-point-reliance clashes.
- **Shot profile:** each offense's shot mix and FG% by zone against where
  the other defense allows shots and how well, with "strength vs. weakness"
  and similar reads.
- **Players to watch:** in season, each team's top 8 by minutes (PPG, RPG,
  APG, TS%, USG%, BPR, BPM) with injury tags; in the preseason, the
  projected rotation from the Projections tab. Minutes-weighted rotation
  height for both.
- **Recent form** (last 10, margins chart, performance rating vs season) and
  **history** (meetings, common opponents and how each team did against
  them).

**Which season the profiles are.** Until the new season's first games are
in the box-score data (the script switches seasons in November), the
box-score parts of a preview are last season's. Every section says so, and
the note under the tale of the tape gives each team's returning-minutes
share so you can judge how much last year still applies. Once this
season's games load, everything switches over on its own.

## One-time setup

1. **Install R** (if you don't have it): https://cran.r-project.org/bin/windows/base/
   During install, check "Add R to PATH" — this lets `run_daily.bat`
   call `Rscript` without a full path. If you skip that, edit
   `run_daily.bat` and replace `Rscript` with the full path, e.g.
   `"C:\Program Files\R\R-4.4.1\bin\Rscript.exe"`.

2. **Put these four files in the same folder:**
   - `build_dashboards.R`
   - `dashboard_template.html` — the page's HTML/CSS/JS shell; the
     script reads this in and fills in real data each run. **Required**
     — the script will stop with a clear error if it's missing.
   - `run_daily.bat`
   - (this `README.md`, optional)

3. **First run — do this manually once**, by double-clicking
   `run_daily.bat` or running it from a command prompt, so you can see
   any errors directly instead of buried in a log file. It will:
   - install `dplyr`, `tidyr`, `jsonlite`, `purrr`, `nanoparquet` from
     CRAN if you don't already have them (one-time, a couple of minutes)
   - download the current season's box scores, ratings, rosters, and
     player value (Box Plus/Minus) ratings directly from
     sportsdataverse's GitHub releases (a few MB, cached locally in a
     `.wbb_cache` folder next to the script; a cached file older than
     12 hours (`CACHE_MAX_HOURS`) is downloaded again, and if that
     fails the older copy is used with a warning). The player-value release can
     lag the others by a bit since it's derived from them; if it's not
     published yet for the current season, the build still succeeds --
     the Player Value stats (BPM/VORP/Win Shares) just come back blank
     until it is (see the `WARNING:` line this prints to the console
     and to `build_log_*.txt` when that happens).
   - write `team_dashboards.html` next to the script and open it
   - also copy that file to `G:\My Drive\WNCAA\2026\` (Google Drive for
     Desktop's mount of "My Drive"), named with today's date as
     `MMDDYYYY_WBBDashboard.html` — e.g. `09202026_WBBDashboard.html`
     for September 20, 2026. This is in addition to, not instead of,
     the copy left next to the script. If that Drive folder doesn't
     exist yet, the script creates it; if `G:` isn't reachable at all
     (Google Drive for Desktop not running or not signed in), it logs
     a warning and carries on — the local copy still gets made either
     way, so a Drive hiccup never blocks your local dashboard.

   This step needs a normal internet connection — CRAN and GitHub
   release assets, nothing exotic.

   One thing worth knowing: `team_dashboards.html` comes out to
   roughly **19-20 MB** (full season box scores for both teams, every
   game, all 361 D1 teams, all embedded so all the data and every stat
   works fully offline with no server). The previous format would be
   about 65 MB on a complete 2025-26 season (the older 40-47 MB figure
   was from partway through a season): every box score was embedded twice, once in each team's own game log, and
   every row repeated the player's name, position, and height. Box
   scores now ship once each in a compact format (the `box-data` block)
   and the page rebuilds the full rows when it opens, so nothing about
   how the page works changed. `build_dashboards.R` and
   `dashboard_template.html` must come from the same version: the
   script stops with a clear error if the template is missing the
   `__BOX_JSON__` placeholder. It may take a few seconds to open in a
   browser tab, especially on a phone, but everything after that first load
   (searching, filtering, sorting, switching teams) is instant since
   it's all just in-memory JavaScript by then. The one exception is
   team logos: those load live from ESPN's logo CDN, so they need an
   internet connection at view time same as any normal web page, and
   fall back automatically to a colored initials badge if that's not
   available. The build itself takes about 6-7 minutes with the data
   already cached (the first run of the day also downloads the release
   files); most of that is writing the JSON, since box scores are now
   looked up from a pre-split table instead of re-scanning the whole
   national player box score file for every game.

## w1.8b fixes (data trust)

- **Neutral sites.** ESPN's box scores only say home or away, so before
  this every neutral-site game (holiday events, most conference
  tournaments, the NCAA regionals and Final Four) was treated as a home
  game for one team. `build_dashboards.R` now reads the schedule release
  (`wbb_schedule_<season>.parquet`) and marks those games "N". That fills
  the Neutral location filter and split, removes a home-court adjustment
  from games that had none, and puts those games on the neutral Quad cut
  lines.
- **Home court.** The rating model's home-court edge was a fixed 1.4
  points per 100 possessions (about 1 point a game). It now uses the
  projection model's fitted value, about 4.0 per 100 (about 2.9 points a
  game).
- **WAB win chances.** Replaced a logistic curve that was too sure of
  itself (a 10-point-per-100 favorite at 89%) with the projection model's
  fitted single-game spread (about 74% for the same favorite).
- **Tempo** is possessions per 40 minutes, so overtime games (periods from
  the schedule) no longer inflate it.
- **Data stamp.** The top bar shows the last game in the file. Tap it
  for the build time, neutral-site count, finished games with no box
  score (they are in no rating or record), and games with no shot
  locations. The dot turns amber when games are missing, or in season
  when the newest game is more than two days older than the build.
- **Daily refresh.** Cached release files were only ever downloaded once,
  so daily runs could keep showing the first day's games. They are now
  re-downloaded when older than 12 hours.

The home-court and neutral-site fixes change Adj O/D, Net Rtg and ranks
slightly, mostly for teams with lopsided home/road schedules or many
neutral-site games. The Projections tab is unaffected: it already read
neutral sites from the schedule and fitted its own home court.

## w1.8c: non-D1 games and D1 membership

- **Ratings and WAB use D1 games only**, the same convention as KenPom,
  Torvik and the NCAA's NET. Before this, a game against a D2, D3, NAIA or
  exhibition opponent counted as a game against an average D1 team, which
  lifted any team (and any conference) that played them. Those games
  still count in records, game logs and splits. Luck (wins above
  Pythagorean expectation) uses D1 games only as well, for the same reason.
- **D1 membership** is the upstream crosswalk plus any team the season's
  schedule places in a D1 conference with at least 10 finished games
  against D1 teams (`D1_MIN_GAMES` in `build_dashboards.R`). The 2026
  crosswalk dropped Saint Francis (PA), a 2025-26 NEC member, and leaves
  out reclassifying members like Mercyhurst that play a full conference
  schedule; both are added back this way. The build log lists every team
  added, and so does the data stamp.
- The page takes its team count from the teams loaded, instead of a fixed
  361.

## w1.12: minutes flags (a key player's minutes fall off a cliff)

**What it does.** After each game, any *key* player (usual 20+ minutes) whose
minutes collapsed is flagged, unless foul trouble or the whole rotation sitting
explains it. It is **reported only**: nothing here changes a rating, win chance,
line or total. To apply an absence, add a row to `wbb_injuries.csv`.

**Where it shows.**
- **Game Predictions slate**: a "MINUTES FLAG" line on that team's *next* game
  only (the history says what follows the next game, nothing about one weeks
  away), e.g. "Boston College: Athena Tomlinson did not play (usual 31 min) ·
  ~53% miss next game".
- **Model Report Card, Data checks**: the full list, with the historical rates.
- **`wbb_2027_minutes_flags.csv`**: the same list (date, team, name, athlete_id,
  flag, minutes, usual, fouls, p_miss_next, p_under_half) for copying into
  `wbb_injuries.csv`.

**Tiers** (her minutes in the game, against her average over her last 5 games):
DNP (no minutes, or no box-score row), severe (30% of usual or less), sharp (50%
or less). Constants `PW_MF_*` at the top of the block.

**What excuses a drop** (tested on the 2017-26 box scores, ~460,000 key
player-games with a next game; normal-minutes reference: 1.6% miss the next game):

| Case | Misses next game | Plays under half her usual minutes | Excused? |
|---|---|---|---|
| DNP, 1st game | 52.5% | 59.8% | no, flagged |
| DNP, 2nd straight | 62.7% | 69.9% | no, flagged |
| Severe cut, only she sat | 21.2% | 45.9% | no, flagged |
| Sharp cut, only she sat | 8.7% | 25.8% | no, flagged |
| Sharp cut, 4+ fouls | 1.2% | 7.5% | **yes**, foul trouble |
| Severe cut, 4+ fouls | 2.3% | 11.3% | **yes** |
| Sharp cut, whole rotation sat | 4.4% | 14.1% | **yes**, team-wide |

**Blowouts: final margin is deliberately not used.** A cut in a 20+ point game
predicts a missed next game about as well as one in a close game (15.1% vs
11.3%), and a DNP in a blowout still means a missed next game 48% (win) to 58%
(loss) of the time, so a margin cutoff would hide real injuries. What does
separate rest from injury is the *team-wide* test: in 20+ point games, a cut
where only she sat was followed by a missed game 15.1% of the time; where the
rotation sat with her, 4.9%, which is close to normal. (In close games the
team-wide group is small, 242 cases, and still elevated at 9.9%, so treat a
close-game team-wide flag as unproven.)

**Limits.**
- It reports an absence after the fact; it can't see a day-of scratch.
- It can't tell an injury from a coach's decision, discipline, illness or a
  personal absence. Each flag is a "go check this player" prompt.
- No flags in a team's first 3 games (it needs her recent minutes).
- After a first missed game, her "usual" shows lower than it was (the zero-minute
  game is in the average), e.g. 25 instead of 31.
- A player stops counting as key after two straight missed games; from there
  the model's own rule (no minutes in the last 3 games) takes over.
- **Not in the w1.11 zip.** The minutes-flag code and page section were added to
  the working copy after w1.11 was packaged; this is its first release.

**How it was checked.** The shipped rates were reproduced from scratch on all 10
seasons with an independent calculation (DNP 56.6% vs the 57% constant, severe
21.2% vs 21%, sharp 8.7% vs 9%; same rates in 2017-22 and 2023-26). An in-season
simulation with planted cases flagged the DNP and the 7-minute cut, excused the
5-foul case and the rotation-wide drop, wrote the CSV, and put each flag on only
that team's next game; the Data checks section and slate line rendered in a
headless browser with no JavaScript errors. Not checked on live 2026-27 data (no
games yet).

## w1.11: the four deferred items

Every change below was scored the same way as w1.10: walk-forward for the
preseason model, and the 2020-26 two-week replay with held-out seasons for
in-season numbers. Two were adopted, one rejected, one is a file-size change.

| Item | Result | Decision |
|---|---|---|
| Team-equation collinearity | RMSE 7.616 vs 7.625 (5 of 7 seasons better); ridge 7.630 | **Adopted** the reparameterized equations |
| Garbage time / blowouts (Huber fit) | held-out log loss worse at every strength: 0.47940 (k=30), 0.48011 (k=20), 0.48239 (k=12) vs 0.47929 | **Rejected**, fit unchanged |
| Per-team home court | 0.47920 vs 0.47929, better in 6 of 7 seasons | **Adopted** for game lines, win chances, simulation |
| Payload compression | 8.8 MB to 2.4 MB on the 97-team test page; identical tables | **Adopted**, on by default |

### Team equations (collinearity)
Roster defense and last season's defense correlate 0.98, and last season's
offense and its returning-minutes interaction 0.96, so the old coefficients came
out as offsetting pairs (1.43 and -0.44). The equations are now written as last
season plus roster change:
`yO ~ O1 + I(rO - O1) + O2 + I((O1 - O2) * retmin) + trorig` (same for D).
Fitted on 2019-26: last season carries 0.76 (O) / 0.96 (D); a change in roster
value counts 0.94 (O) / 1.41 (D). The 1.41 is expected: box-score defense is
compressed (`PW_DSHRINK`), so the team equation re-expands it. Ridge with its
strength tuned on earlier seasons only didn't help (it mostly picked no shrinkage). Preseason
ratings move by at most 0.7 (sd 0.16). The injury layer reads the roster weight
from the new names (`pw_roster_weight`).

### Garbage time
Your cache has play-by-play only for 2026, so a play-by-play garbage-time filter
can't be backtested on history. The box-score version of the same idea was tested:
down-weighting games far from expectation (Huber weights on the margin per 100,
re-weighted fits). Every strength made held-out predictions worse, and stronger was
worse, so lopsided women's games carry real information about team strength.
This reverses the first review's suggestion. A play-by-play filter would need past
seasons' play-by-play files.

### Home court by team
Each team's home margin over expectation minus its road margin over expectation,
per 100 possessions, from the four previous seasons, shrunk by its noise
(empirical Bayes). Real differences between teams: about 1.8 per 100 (2023-26), up
from about 0.7-0.9 before 2024; one team's raw estimate is off by about 3, so
shrinkage is heavy. Game lines move by up to about 1.8 points at most.
It enters game lines, win chances, the season simulation, and the in-season fit
(the team-specific part is taken out of home results before fitting). The
ratings and WAB still use the league edge. `cal$team_hca` holds the values; the
Report Card describes them.

### Compressed page
Each data block is zlib-compressed and base64-encoded in the build
(`data-z="deflate"`). A small loader at the end of the page unpacks them with the
browser's built-in `DecompressionStream`, then starts the app. On the 97-team test page:
8.8 MB to 2.4 MB, the rankings table identical cell for cell, the same load
time, no errors, including a phone-size window. Needs Chrome/Edge 80+, Firefox 113+ or Safari
16.4+. Older browsers get a message instead of a blank page. `WBB_COMPRESS=0`
builds the plain page, and an older template is never sent compressed data.

### Install
Copy all five files (the four scripts/templates and
`.wbb_cache/predict_wbb_calibration_2027.rds`). The calibration version is now
`w1.11`; an older cache is refitted automatically (10+ minutes) rather than mixed
in. Calibration results with the new equations: preseason RMSE 7.616 (clustered
interval 7.40-7.86); in-season held-out log loss 0.4793 with the same winning
setting in all 7 seasons; player layer 0.4777. Not checked: a full 363-team build.

## w1.10: held-out validation of the projection model

**Correction to the w1.9 notes.** They said the w1.10 validation code was
"already in predict_wbb.R" and that the 0.4793 in-season log loss was optimistic.
Both were wrong. The code existed only in the maintainer's working copy and is
first shipped here; and run on your data, the held-out numbers match the
in-sample ones (below).

### What changed in `predict_wbb.R` (calibration only)
- **Leave one season out** for the in-season settings: prior weight (flat/scaled,
  lambda), probit scale and spread weights are chosen on the other seasons and
  scored on the held-out one.
- **Constants frozen per held-out season**: each replayed season gets the game
  spread, home edge, preseason spread fit and conference variance fitted on the
  other seasons, the walk-forward value model of its own fold, and the prior
  season's league tempo. Production still uses the all-season values.
- **Clustered bootstrap**: intervals resample whole season-by-conference blocks,
  because a league's teams share preseason error. The old team-season
  interval is kept as `rmse_ci_iid`.
- `PW_INS_NEWQ` (default 0.25): the quantile of her team's sheet values at which an
  unlisted box-score player is valued. See the result below before changing it.
- `PW_CAL_VERSION` is now `w1.10`, so code and cache can't be mixed: an older cache
  is refitted automatically once (10+ minutes), and the supplied cache is reused.
- The Report Card shows the held-out log loss and says the intervals are clustered.

### Results (2017-2026 history, the same data as your cache)
| | in-sample | held out |
|---|---|---|
| In-season game log loss | 0.4793 | 0.4793 |
| Preseason-only game log loss | 0.5210 | 0.5210 |
| In-season player layer | 0.4776 | 0.4777 (vs 0.4793 without it) |

- The same setting ("scaled", prior worth 5 games) wins in all 7 held-out
  seasons, so choosing it on the scored games cost nothing measurable.
- Preseason RMSE 7.62: interval 7.40-7.87 clustered vs 7.40-7.84 team-by-team; gain
  over carry-forward 1.61 (1.33-1.89 clustered).
- With constants frozen per season the fitted spread weights fall slightly:
  k_pre 0.45 to 0.39, k_in 0.35 to 0.28. Win probabilities move a little toward the
  favorite. This is the only change to live numbers.
- **Unlisted box-score players (deferred item, now closed):** valuing them at the
  10th, 25th or 50th percentile changes held-out log loss by under 0.00001 in every
  season. History can't test this (historical rosters come from the box scores,
  so almost nobody is unlisted). It matters only live, for walk-ons missing from
  the prep sheet. Left at 0.25.
- Everything else in the supplied cache (value model, player models, team equations,
  backtest, game constants, season data) is identical to the cache you built on
  2026-10-04.

### How it was checked
The full calibration ran on the 2017-2026 files from your cache and reproduced your
2026-10-04 calibration exactly before the new parts were added. The projection
module then loaded the new cache without refitting, and the Report Card rendered in a
headless browser with no JavaScript errors (97-team test page). That run caught and
fixed one bug: the held-out numbers reached the page as an unnamed list.
Not checked: a full 363-team build with these files.

## w1.9: roster transition, one rating model, and fixes

**Status of this section.** Items marked *(tested)* were run on the 2026
cached data or on synthetic data; *(not run)* means the code parses but
hasn't been exercised. See "What was and wasn't tested" at the end.

### Roster: prep sheet to live data
- **Frozen preseason snapshot** *(tested, synthetic season)*. Until the
  first D1-vs-D1 game of the projected season, every run builds the
  projection from the prep sheet and saves it to
  `wbb_2027_preseason_snapshot.rds` (plus a readable
  `wbb_2027_preseason_players.csv`). Once a game is played, runs read the
  snapshot and never open the sheet, so late sheet edits can't rewrite
  the prior the season is being scored against. If you find a real
  error after the start, set `PW_REFREEZE <- TRUE` for one run, then
  set it back. The Data checks note says which mode the run used.
- **Per-team roster source** *(tested, synthetic)*: prep sheet until the
  team has played, then its box scores, then ESPN's roster listing once
  it is trustworthy: it lists 9-24 players (`PW_ROSTER_SIZE`) and holds
  at least 90% (`PW_ROSTER_FRESH`) of the players who have played for the
  team. Last season's roster copied forward fails that test.
  `WBB_ROSTER_MODE=prep` or `live` forces one source for every team.
  Players a trusted listing drops (and who haven't played) count as out
  from game one. Pass-through of the real ESPN file is *(not run)*; only
  the rejection of a stale listing was tested.
- **Stable IDs** *(tested)*. Sheet rows with no ESPN id used to be named by
  row position (`fr_12`, `rec_5`, `noid_307`), so re-sorting the sheet
  renumbered them. They are now built from team and normalised name
  (`fr_2000_alexalane`). No duplicates across the 4,638 roster rows.
  `wbb_2027_roster_ids.csv` lists every id and how it was linked
  (`id`, `name`, `xwalk`, `recruit`, `none`).
- **Linking to box scores** *(tested, synthetic)*, in this order: ESPN id;
  exact name on the same team; aliases from the optional
  `wbb_player_xwalk.csv`; same last name and first three letters
  (Madi/Madison); unique exact name anywhere in D1 for rows that never had an id.
  When two sheet rows claim the same box-score player, or several players
  match, nothing is merged. The case goes to `wbb_2027_needs_review.csv`
  and the Data checks panel.
- **`wbb_player_xwalk.csv`** (optional, hand-kept): `pid, espn_id,
  aliases, note`. `pid` comes from `wbb_2027_roster_ids.csv`; `aliases`
  is `Madi|Madison`. Put a known nickname or a wrong sheet id here once.
- **Unchanged**: a player in the box scores but not on the sheet is still
  valued like her team's lower-quartile player, and the in-season
  weights were fitted with that rule. Revisit it when you recalibrate.

### Injuries *(tested, synthetic)*
`wbb_injuries.csv` is read as described under "Injuries and the in-season
roster" below. Season-long outs come off the preseason rating; other rows
adjust each affected game's win chance, line, total, and the season
simulation. A return date ramps the chance of playing over about two
weeks centered a week after the date (0.88 chance of missing on the
date, 0.50 a week later, 0.02 three weeks later). A box score after
`out_since`/`updated` retires the row. Dates read as `2026-12-20` or
`12/20/2026`; blanks are fine. Names that match no roster are listed in
Data checks. The effect of an absence depends on who replaces her
minutes: losing a player whose defensive value is below her
teammates' can improve the team's defensive rating.

### One rating model for the whole page *(tested, subset build)*
- The homepage Adj O / Adj D / Net / Tempo are now the ridge ratings from
  `predict_wbb.R`, fitted in the build and shipped as `__RATINGS_JSON__`
  (new `ratings-data` block). Once the projected season is the one on
  the dashboards, they are the projection's in-season ratings (results
  plus the preseason prior), so early-season ranks aren't two-game noise.
  Tempo is per 40 minutes (overtime-adjusted).
- Why: the old in-page iteration log-compressed each game's efficiency
  toward the league average, which halved the spread (UConn about +32
  instead of +65 per 100) while WAB, matchups and performance ratings used
  a game spread and home edge fitted on the full scale. On the 2026 data
  that distorted WAB by about 2.9 wins per team on average (up to 4.7),
  and flipped its sign for 27 teams (Python replication on an approximate D1 set).
- WAB, quads, `perfRating` and the matchup tool use the shipped home edge
  and game spread. `ADJ_RATINGS_DIAG` in the console shows the source.
  A build with no ratings falls back to the in-page model, without the compression.
- The ratings are about 2x the old scale, so any number you've learned
  to read (a +20 team, a bubble line) has moved.

### Build fixes
- **Season rollover** *(not run)*: when `SEASON` flips on Nov 1 before
  the new box scores exist, the build uses the season just finished
  (flagged in the data stamp as `season_fallback`) instead of stopping.
  Crosswalk and rosters fall back too. The Projections tab is unaffected.
- **Download validation** *(not run)*: a file replaces the cache only if
  it opens (rds reads, parquet footers present). A truncated transfer
  used to be accepted.
- **JSON escaping** *(tested)*: every embedded block escapes `</`.
- **W/L** *(tested)* comes from the score; a missing winner flag used to
  show as a loss. Neutral-site count is games, not team-games.
- **Shot zones** *(tested, no play-by-play)*: per-row zone lookups are a
  vectorised match (they used to subset a table about 840,000 times). The
  speed-up and the zone values themselves *(not run)*: my test builds had no play-by-play.
- **Memory**: big tables are released before the projection runs, and
  `WBB_SKIP_PBP=1` skips the 90 MB play-by-play file. `WBB_OFFLINE=1`
  uses cached files only.
- **Predictions log**: keeps the latest pick made before game day, not the
  first one made up to three days out. Tip-off times, logged picks and
  injuries now fill the game rows the page already reads.
- **Calibration**: see "w1.10" below. Ship `predict_wbb.R` and
  `.wbb_cache/predict_wbb_calibration_2027.rds` together.
- Muted text and table headers pass WCAG AA (`--faint` was 3.2:1).
- Percentile shading is blue (better) / orange (worse).
- Table scrollbars are visible; on touch screens up to 1024px wide, long tables
  scroll with the page instead of in a 74vh inner scroller.
- Tablets in portrait get the phone filter drawer and column collapse.
- Tiers at 1920px and 2560px widen the shell and the table type.
- `overflow-x: clip` replaces `hidden` (sticky-header safety).
- The game-flow block is parsed only when a recap opens.
- **Shade vs.** (Team Rankings filter bar) *(tested in a browser)*: "Shown
  teams" (default, the old behaviour) re-ranks the shading within whatever is on
  screen; "All D1 (national)" shades against every D1 team in the same
  Games/Opponent-rank window and above the same min-games floor, so a conference
  or tier filter no longer recolors a team. The other tables still shade
  against what's shown.
- **Net / AdjO / AdjD follow the Games and Opponent-rank filters** *(tested in
  a browser, 97-team build)*. They used to read each team's season rating
  whatever the filter. With a window on, each game in it is adjusted for that
  opponent's season-long rating and the venue (the same adjustment as the game
  performance rating), then averaged weighted by possessions. Opponents
  are not re-rated for the window, and non-D1 opponents are skipped. Read
  Net first: AdjO and AdjD each also carry the window's scoring environment
  (late-season and tournament games score lower per 100), so both can drop together
  while Net holds. A 1-3 game window is noisy: use Min. games. With no window the columns are
  the season ratings, exactly as before. Rk, Tempo and the other pages are unchanged.
- Open: the tab row takes three lines on a 390px phone. (Payload compression:
  see w1.11.)

### What was and wasn't tested
Tested: the projection module reproduces the w1.8 script exactly (rating
difference 0.0 in the same environment); linking, injuries and roster-source logic on real
roster data with synthetic box scores; an in-season run on 90 fake games;
a 97-team build to HTML with 0 JavaScript errors and no horizontal
overflow at 390, 820 and 2560px (no play-by-play, projection output stubbed in).
**Not tested**: a full 363-team build; the 10,000-season simulation after these
changes (my sandbox killed the process at the simulation, which standalone
ran fine at 300 seasons); ESPN's live roster file; the rollover fallback;
play-by-play features. After your first full run, compare the top 25 and
`ADJ_RATINGS_DIAG` against your last page. My side-by-side run of the original
script differed from your shipped page by up to 0.8 rating points
and 13 ranks for reasons I couldn't find; check yours.

## Running it every morning automatically

Windows Task Scheduler, not the BAT file alone, is what makes this
run daily without you double-clicking it:

1. Open **Task Scheduler** (search it in the Start menu).
2. **Action → Create Basic Task...**
3. Name it something like "WBB Dashboard Refresh". Next.
4. Trigger: **Daily**. Next. Pick a time — e.g. 7:00 AM, after the
   overnight data pipeline upstream has had time to update (there's
   no fixed guarantee on that timing, so if you notice games from
   `game_date == yesterday` sometimes missing, try nudging this later,
   e.g. 8–9 AM).
5. Action: **Start a program**.
   - Program/script: the full path to `run_daily.bat`
     (e.g. `C:\Users\you\wbb-dashboards\run_daily.bat`)
   - Start in (optional): the folder containing it
     (e.g. `C:\Users\you\wbb-dashboards\`) — this matters, set it.
6. Finish. Right-click the new task → **Properties** → General tab →
   check **"Run whether user is logged on or not"** if you want it to
   run even when you're not signed in (it'll prompt for your Windows
   password once, to store the credential).

That's it — it'll regenerate `team_dashboards.html` in place every
morning. Open that file (bookmark it, or pin a shortcut) whenever you
want to check it; it's a static file, so it just shows whatever the
most recent run produced.

## If something breaks

Each run writes `build_log_YYYYMMDD.txt` next to the script. If the
dashboard didn't update, open that file — it's the full R console
output, including any error. The most likely culprits:

- **No internet at run time** (laptop asleep, VPN issue) — the
  `load_*()` calls will fail with a download error; rerun manually.
- **A season rolled over** (e.g. this stops finding games at the end
  of a season, or right at the very start of a new one before its
  release files exist upstream yet) — `SEASON` is auto-detected from
  today's date near the top of `build_dashboards.R`; hardcode
  `SEASON <- 2027` (or whichever year) there as an override if it
  ever guesses wrong.
- **A CRAN package update breaks something** — pin versions with
  `renv` if this becomes a recurring problem; not set up here to keep
  the one-time setup simple.
- **The Google Drive copy didn't show up** — the R build itself still
  succeeded (that part fails loudly, with `pause`, if it doesn't); the
  Drive copy is a separate, non-fatal step at the end of
  `run_daily.bat`. Check the same `build_log_*.txt` for a `WARNING:`
  line — almost always Google Drive for Desktop isn't running or
  isn't signed in, so `G:` isn't mapped to anything that morning.
  `team_dashboards.html` next to the script is unaffected either way.

## What I could and couldn't verify

This script downloads its data directly from sportsdataverse's GitHub
release files (URLs I fetched with `curl` and confirmed return real
data), and reads them with plain `readRDS()` / `nanoparquet::read_parquet()`
rather than through the `wehoop` R package's own functions. That's a
deliberate change: an earlier version of this script called
`wehoop::load_wbb_ratings()`, and that turned out not to be exported
in the installed version of `wehoop` — the exact kind of thing I
flagged I couldn't fully verify from documentation alone, and it did
in fact break on the first real run. Going straight to the release
files sidesteps that risk entirely, since it no longer depends on
which convenience functions a given `wehoop` version happens to
export.

I confirmed every URL and every column name this script relies on
against the actual downloaded files (via Python, while building
this), so I'm confident in the data layer specifically. I still can't
execute R itself in this environment, so the R syntax around that
data layer hasn't been run end-to-end the way the Python version was.
If anything else breaks, the error message plus a copy of
`build_log_*.txt` is usually enough for me to fix it directly.

**Update, for the shot-zone tables (Team Shooting/Defense by Zone,
Player Shooting by Zone):** for this round of changes I actually
installed R in my own working environment (CRAN itself wasn't
reachable there, so `nanoparquet` specifically couldn't be installed
the normal way — I worked around that just for testing, by converting
the three cached `.parquet` files to `.rds` locally; the delivered
script still uses `nanoparquet::read_parquet()` as before, unchanged)
and ran this actual, complete pipeline against the real cached
2025-26 season data, not a Python stand-in. The full 361-team run
takes several minutes end-to-end (consistent with your own
`build_log_*.txt` timestamps), longer than fit in one step where I
was working, so I validated the complete pipeline logic — shot
classification, per-game zone attachment on both team games and
player box rows, JSON serialization, template injection — on a
10-team subset instead (same code path the full 361-team run uses;
team count doesn't change the per-team logic). That run is what
caught the `MadeFreeThrow`-vs-`Free Throw` spacing bug documented
above: shot-zone field goal attempts are checked to sum to exactly
each team's box-score FGA, and before the fix, 100% of games failed
that check; after, 99% passed exactly, with the small remainder
explained (see the Shot Zones section above). I also rendered the
actual generated HTML in a headless browser and drove it through real
interactions — opening all 10 teams, cycling every Games/Opponent-rank
combination on both team and player pages, opening player profiles,
toggling the custom-rank-range UI — with zero JavaScript errors, and
confirmed the displayed numbers actually change when a filter changes
rather than silently re-rendering the same values.

**Second update, for the league-wide Shot Zones tab and the Player
Leaderboard's Shooting by Zone view:** these needed no changes to
`build_dashboards.R` at all (they're built entirely from the same
per-game `zonesOff`/`zonesDef`/`zones` data the per-team/per-player
tables already used) — pure template/JS additions, tested the same
way: the same 10-team build, rendered in a headless browser. I visited
all four top-level tabs, cycled all three Player Leaderboard scopes
(Basic/Advanced/Shooting by Zone), opened every one of the 10 teams
with every Games/Opponent-rank combination on both team and player
pages (same regression sweep as before, to make sure nothing broke),
exercised the new Shot Zones tab's Offense/Defense toggle and its full
filter bar including a custom opponent-rank range, and sorted by
several zone columns on both new tables — zero JavaScript errors
throughout. I also specifically verified sort correctness numerically
(not just "it doesn't crash"): pulled every row's value for a freshly-
sorted column and confirmed it's monotonically descending across the
whole dataset, on both the team and player zone tables.

One more thing worth knowing: the script used to embed its HTML
template as a giant string literal inside `build_dashboards.R`
itself, using R's raw-string syntax (`r"(...)"`). That syntax needs
R 4.0+, and turned out to be fragile in practice — it broke on a
real run. The template now lives in its own file,
`dashboard_template.html`, which the script reads in at runtime.
That's both more robust (no R-version dependency, no string-escaping
edge cases) and easier to read if you ever want to look at the page
markup directly.

---

## 2026-27 Projections (new tab)

A roster-based preseason model for 2026-27 plus a full season simulation, shown in the **2026-27 Projections** tab. It updates itself as the season is played.

### Files (keep all of these in the same folder)

| File | What it is |
|---|---|
| `build_dashboards.R` | Same build script, now also runs the projection module (needs the `readxl` package, auto-installed). |
| `dashboard_template.html` | Same template plus the Projections tab. |
| `predict_wbb.R` | The projection module. Sourced by the build script; if it fails, the rest of the dashboard still builds and the tab shows the error. |
| `wbb_2027_teams.csv` | 2026-27 conferences (from the Team Preview sheets), league game counts, conference-tournament field sizes, automatic bids, coaching changes. Edit freely. |
| `wbb_2027_roster_overrides.csv` | Optional manual fixes: `name, team, action, note, athlete_id`, where action is `keep` or `exclude`. Use it for players the prep sheet can't see, such as a recruit who redshirted, or who left and hasn't landed. Notes show up on the player's row. Filling in `athlete_id` targets one stats-tab row instead of everyone with that name (see Peyton Jones below). |
| `2027_Prep_Sheet_v2.xlsx` | **Your prep sheet — copy it into this folder.** The `2027 Team` column is the roster source of truth. |
| `wbb_injuries.csv` | Injuries, kept by hand (ships with the header only). Read before and during the season; see "Injuries" below. |
| `wbb_2027_preseason_snapshot.rds` | *Written by the build.* Every preseason run saves the projection it made from the prep sheet here. Once the season starts, runs read this instead of the prep sheet. Don't delete it in season. |
| `wbb_2027_preseason_players.csv` | *Written by the build.* A readable copy of the snapshot: every player's preseason projected minutes and values. |
| `wbb_recruits_history.csv` | *Optional, ships empty.* Past top-100 classes: `year, rank, name, espn_team_id`. Filling it lets the recruit-rank adjustment be fitted on several classes and tested in the backtest. |
| `wbb_coach_history.csv` | *Optional, ships empty.* One row per team-season: `season, espn_id, coach`. Filling it lets a coaching change move the projection and tempo, fitted from history. |
| `wbb_player_xwalk.csv` | *Optional, hand-kept (w1.9).* `pid, espn_id, aliases, note`: fixes a roster link or adds a nickname. |
| `wbb_nond1_levels.csv` | *Optional, ships empty.* `name, level` (D2 / NAIA / JUCO) for transfers from below D1. Junior colleges are recognized by name without it. |

Run `build_dashboards.R` as before. The first build of the season calibrates on 2017–2026 (about 10 minutes total, including the in-season replay); after that it takes about 2.5 minutes. The calibration is cached in `.wbb_cache/predict_wbb_calibration_2027.rds`. Each build also appends upcoming picks to `predictions_log_wbb.csv` and grades them once games are final.

### Method

1. **Season ratings.** Opponent-adjusted offense, defense and tempo for every season since 2016-17 (ridge regression on every D1 game, home court fitted, neutral sites from the schedule).
2. **Player value.** Offense and defense per 100 possessions from box stats, constrained so each team's minute-weighted player values add up to its rating.
   - **Offense charges every shot.** Points count only above what a league-average shooter would score on the same attempts. There's a smaller fitted credit for creating shots, plus assists, turnovers and offensive rebounds. Fitting points and attempts separately at the team level rewarded volume regardless of efficiency, because every team uses about the same number of possessions.
   - **Rebounds are split.** Offensive rebounds count on offense and defensive rebounds on defense. Total rebounds on the offensive side had been offsetting poor shooting.
   - **Defensive box credit is kept at a quarter weight** (`PW_DSHRINK`). Steals, blocks, defensive rebounds and personal fouls count; fouls were added in w1.6. Box stats explain about half of team defense, so the rest is shared across the lineup. The weight was chosen on the w1.5 backtest (full 7.49, 0.75 → 7.48, 0.5 → 7.45, 0.25 → 7.42, none 7.69). Those differences are within noise, so the nested tuning check in the Report Card (`PW_TUNE`) shows how much choosing it that way flatters the result.
   - Adding shooting efficiency to the season-to-season projection was also tested; it didn't help once shots are charged properly.
   - **Position adjustment.** Raw box stats over-credit post players (rebounds, blocks) and under-credit guards. So each position group's league-average value is evened out before the team constraint, as in Box Plus/Minus 2.0.
   - This changes how a team's rating is shared among its players, not the team total. It was chosen on the backtest: it lowered team error from 7.88 to 7.75, and on transfer-heavy rosters from 9.04 to 8.87. Set by `PW_POS_ALPHA` (1 = full, 0 = off).
3. **Player projection.** Next season's value from the last two seasons, experience and transfers (fitted on every season-to-season transition 2018–2026).
   - **Missed seasons.** A player who sat out last season (injury, redshirt) is projected from her most recent season. Past players who missed a year kept about as much value as anyone else.
   - **Stars.** The very best players regress somewhat more than average; that extra shrink is fitted from the data.
   - **Below-D1 transfers.** Players moving up from below D1 are valued as if on a bottom-tier D1 team.
4. **Identity matching.** Players are linked to their box-score history by ESPN ID.
   - A Freshmen-tab entry on the same team, with the same last name, a first name sharing its first three letters, and a non-freshman class is merged into the stats-tab player (Madi/Madison Morson). 20 such duplicates are listed in the Report Card. Freshmen who share a last name, like twins and sisters, are kept separate.
   - When the ID is missing or doesn't match, they're matched by name plus school.
   - Freshmen-tab entries with D1 history become returners or transfers.
   - Stats shown for players who sat out 2025-26 come from their last season played and are labeled as such.
5. **Minutes.** Fitted on every team 2020–2026, walk-forward.
   - **Pecking order.** Projected minutes follow each player's place in the team's rotation, using what that slot has averaged on real D1 rosters.
   - **Track record.** That's adjusted by her own record: last season's role, and for transfers the strength of the program she left. Players transferring from strong programs have earned more minutes than a flat rule gives them.
   - **Overbooked rosters.** When a roster has more claims than minutes, the top five absorb half as much of the trimming as the bench (`PW_MIN_ALPHA`). This removed the under-projection of starters on deep teams.
   - **Recruits.** Recruit minutes depend on rank and program strength: top programs give freshmen fewer minutes.
   - **Accuracy.** Minutes error fell from 9.1 to 8.4 per team game.
   - **Two bases.** "Proj MPG" is per game played, the same basis as last season's MPG. The team rating uses minutes per team game, where games a player misses count as zero.
6. **Newcomers.**
   - Top-100 recruits get a bump by rank and extra minutes, fitted on the 2025 class's actual 2025-26 seasons.
   - **International newcomers** get a FIBA youth EFF/40 adjustment, halved because it was fitted on only 30 players.
     - EFF/40 is first put on a common scale by competition level. This is measured from 255 players who appeared in more than one event, each event compared with that summer's U18 Division A. Relative to U18 A: U18 B +3.5, U20 B +1.2, U20 A −3.7 (positive = easier, so numbers are marked down).
     - Americup and Afrobasket share no players with the Eurobasket events, and Division C isn't in the sheet, so those use stated assumptions (`PW_FIBA_DEFAULT` in `predict_wbb.R`).
     - On the 30 players with an outcome to check, level-adjusted and raw numbers predicted equally well. That test is too small to settle it, so the adjustment rests on the same-player comparisons.
   - Everyone else starts from what newcomers at similar programs have done.
   - **Last year's recruits who barely played** (injury, redshirt, e.g. Emilee Skinner, Leah Macy) keep their recruit-rank bump and a minutes floor, faded by college minutes logged. They get all of it with 0 minutes and it's mostly gone by about 450. This fade is an assumption, not a fitted result: the prep sheet has only two recruiting classes, so how pedigree survives a lost season can't be tested yet.
   - **Restored redshirts.** 2025 top-100 recruits with no 2025-26 minutes never reach the prep sheet's stats tab.
     - Each 2025 recruit is matched to a 2026-27 roster by exact name. Failing that, she's matched through her 2025-26 box-score ID at her original school, which catches nicknames and transfers (LA Sneed → Oklahoma State, Addie Deal → Wisconsin).
     - A recruit with no college minutes who is on no roster is restored to her school, unless `wbb_2027_roster_overrides.csv` excludes her.
     - As of September 2026, three are verified and restored: Leah Macy (Notre Dame), Kate Sears (Virginia Tech) and Manuella Alves-Fernandez (Illinois). Jordan Ode (did not play at Michigan State in 2025-26) is kept at Georgia Tech per `wbb_2027_roster_overrides.csv`.
     - **Peyton Jones (Utah):** the stats tab gave Utah to ESPN athlete 5320983, a different Peyton Jones who was listed on Abilene Christian's 2025-26 box scores without playing. That row is excluded by `athlete_id`, and Utah's actual Peyton Jones, the No. 67 recruit from Valor Christian HS, is placed from the recruits tab (verified against Utah's roster, Sept 2026).
     - The Report Card lists every restoration and whether it's verified.
7. **Team projection.** Projected minutes × projected values, blended with the program's last two seasons and with where the team's transfers came from.
   - Rosters rebuilt from high-major transfers have outperformed ones rebuilt from mid-majors with similar box-score values.
   - Scaling program history by roster continuity was also tested; it didn't improve accuracy, because strong programs that turned over their roster held up about as well as projected.
   - Uncertainty grows with newcomer share of minutes, with unlisted roster spots counted twice. A new head coach adds 10%, or enters the projection itself when `wbb_coach_history.csv` is filled in.
   - Part of every team's uncertainty (±1.7 of about ±7) is shared by its whole conference. It is measured from how preseason misses cluster by league in the backtest.
   - **Tempo** comes from last season's pace, how much of the roster returns, and the pace of the teams the transfers came from. The gain over last season's pace alone is small (2.18 vs 2.19 possessions).
   - **Unlisted roster spots** are placed last in the rotation and never play more than a real player on the same roster.
     - One or two on an otherwise listed roster are valued at replacement level (a lower-quartile unranked newcomer).
     - Teams missing 3 or more keep typical-newcomer values, because there the placeholders stand in for the real rotation. Those teams are marked *low confidence* and carry extra uncertainty.
   - **Transfers from below D1** are valued at a bottom-tier D1 level that depends on where they come from: 5th percentile for D2, 3rd for NAIA and junior college. These levels are assumptions (`PW_NOND1_Q`); there is no public lower-division data to fit them from.
8. **Schedule.**
   - Posted 2026-27 games are used as-is.
   - Where a league hasn't posted its schedule, conference games are generated to that league's game count.
   - Unannounced nonconference games are filled with last season's opponents (counted for that team only).
   - Both kinds of stand-in are replaced automatically as real games post.
9. **Simulation.** 10,000 seasons: standings, conference tournaments (neutral site, byes to top seeds), and a 68-team NCAA field.
   - Each run draws every team's strength from its uncertainty, with a shared draw per conference, so a whole league can come in over or under its projection.
   - Single-game spread (σ 11.3 points) is estimated with ratings fitted without the game being predicted, then the leftover rating error is removed. w1.5 used in-sample residuals × 1.05.
   - Automatic bids go to tournament champions; at-large bids and seeding use an efficiency-based résumé.
   - The top 16 seeds host the first two rounds.
10. **In season.** Ratings refit on the games played, with the preseason projection counted as 5 games of evidence (chosen on 31,897 past games). The weight is scaled per team: a roster the projection is less sure about gets a lighter prior. That beat one weight for every team, but only barely (log loss 0.4793 vs 0.4797).
11. **Rotations and lineup changes during the season (w1.7–w1.8).** Once 2026-27 box scores appear in wehoop's data (they include "did not play" rows), each build also reads them.
    - **Lineup shift.** From six weeks into the season, each team's rating is shifted by the value of its current rotation compared with the rotation behind its results, at 50% weight (75% in w1.7; lowered when fitted together with the early-season rotation piece below, since the two overlap).
      - The current rotation is each player's share of the last 5 games. A player with no minutes in 3 straight games counts as out.
      - Player values blend the projection with this season's box line, which counts fully after 150 minutes.
      - Weight, start day and blend were chosen by replaying 2020–2026 two weeks at a time (31,897 games).
      - Chosen with each season held out, log loss improves from 0.4794 to 0.4783, better in all 7 seasons (95% interval on the gain: 0.0005–0.0019).
      - In games where the shift is 1.5+ points, log loss goes from 0.488 to 0.478.
      - Before six weeks the shift was noise, so it is off.
    - **Early-season rotations (w1.8).** From the first games, each team's preseason projection is re-weighted by the minutes its players have actually played so far, keeping their preseason values.
      - Weight 0.75 on the part of the rating the preseason projection still carries, so it fades as results accumulate.
      - Fitted together with the lineup shift and held out by season, log loss goes from 0.4794 with no in-season player layer to 0.4777 (w1.7 alone: 0.4783). All 7 seasons improve.
      - First six weeks: 0.4359 → 0.4348.
      - It relies on the prep sheet matching the box scores. Players the sheet misses are valued as lower-quartile players on their team, so clear the Data checks lists early in the season.
      - It carries the prior's remaining weight (large early, fading as games accumulate). The weight (75%) is chosen by the same replay.
      - Held out by season, log loss improves by 0.00055 on top of w1.7 (95% interval 0.00011–0.00099), 6 of 7 seasons better.
      - Weeks 2–6 gain the most (0.4368 → 0.4356), the stretch where the model had no player information before.
      - The rotation over all games so far beat the last-5-games version: early on, more games means less noise.
    - **Tested and left out:** re-valuing players from this season's box scores inside the prior. Team results already carry that information, so it never helped.
    - **Roster display.** Projected minutes switch to current usage. Rows get notes: *Out*, *Playing for …*, or *Not in any box score yet*. Placeholder spots drop to zero.
    - **Data checks** list four kinds of mismatch with the prep sheet:
      - projected rotation players who are out
      - players playing but not on the sheet
      - players on the sheet at one school but playing for another
      - sheet players never listed in a box score (teams with 5+ games)
    - Nothing here changes preseason projections. The sheet stays the roster source; fix it or `wbb_2027_roster_overrides.csv` when Data checks shows a real change.
12. **Game win chances and totals.**
    - Win chances combine single-game noise with both teams' rating uncertainty (league-mates share the conference part). The balance between the two is fitted on past out-of-sample games, separately for preseason and in season.
    - The dashboard's matchup tool uses the same formula.
    - Projected totals use both teams' offense and defense. Before w1.6 they used league-average scoring for every game, so only pace varied.

### Backtest (each season predicted from earlier seasons only)

Every piece is refitted inside each season's fold on earlier seasons only, including the box-score value model. Rosters are everyone the box scores list, including players who never got on the floor, which is what the prep sheet gives the live projection. Intervals come from resampling team seasons 1,000 times.

- **Team net rating error:** 7.62 points per 100 possessions (95% interval 7.40–7.84), vs 9.21 for carrying last season forward.
  - That is 1.61 better (1.38–1.85), and better in all 7 seasons.
  - With the rosters that actually took the floor known in advance, it would be 7.49. The gap is the cost of not knowing who will play.
- **Rosters built on transfers:** error 8.47 vs 11.03 (292 team-seasons with 30%+ transfer minutes).
- **Rank correlation with final ratings:** 0.886 vs 0.832.
- **Top 25:** about 18 of the projected top 25 finish in the actual top 25.
- **Game picks:**
  - Preseason projection alone: 72.6% correct, log loss 0.521.
  - With in-season updating: 75.6% correct, log loss 0.479.
  - Calibration charts for both are in the Report Card.
- **Why these differ from w1.5's 7.42.** w1.5 scored the rosters that actually played and valued players with a box-score model fitted on every season, including the one being predicted. Fixing the second raised the known-roster error from 7.42 to 7.49. The realistic rosters account for the rest.

### What changed in w1.6

| Change | Result |
|---|---|
| Realistic-roster backtest (box-score "did not play" rows) | Honest error 7.62; the known-roster figure is still shown alongside |
| Box-score value model refitted inside each backtest season | Removes leakage (+0.07 to the error) |
| Win-probability spread fitted on out-of-sample games | Preseason log loss 0.5219 → 0.5209. A 10-point preseason favorite now shows about 79% instead of 76% |
| Totals use both teams' offense and defense | Totals now range about 107–169 instead of a narrow pace-only band |
| Per-team in-season prior weight | Chosen over a flat weight; gain is small |
| Conference-shared uncertainty in the simulation | ±1.7 of each team's uncertainty shared by its league |
| Unlisted roster spots: replacement value, last in the rotation, extra uncertainty, low-confidence flag | Placeholders no longer take real players' minutes |
| Personal fouls in defensive value | Paired change in team error −0.004 (95% CI −0.020 to +0.025): kept, a neutral addition |
| Tempo from returning share and transfer origins | 2.18 vs 2.19 possessions: small |
| Below-D1 levels (D2 / NAIA / JUCO) | Assumed offsets, labeled in player notes |
| Optional recruit, coach and level history files | Used automatically when filled in |
| Nested tuning check (`PW_TUNE <- TRUE`) | Run for this release (2021–26): re-choosing the defensive weight and position adjustment each season from earlier seasons only picks the current settings every time. Error 7.640 vs 7.625 for the best setting chosen with hindsight, so tuning flattered it by about 0.015. Turning the position adjustment off costs 0.1–0.2 |
| *Tested, not adopted:* separate carry-forward after a first D1 season | +0.004 (95% CI −0.027 to +0.033): no evidence |
| **w1.7:** in-season lineup shift from 2026-27 box scores | Log loss 0.4794 → 0.4783 held out, 7 of 7 seasons better; on from day 42 (weight 0.5 from w1.8) |
| **w1.7:** in-season roster check (Data checks, row notes) | Out / not on sheet / playing elsewhere / never listed |
| *w1.7 tested, not adopted:* updating player values in the prior from this season's box scores | No gain in any setting |
| **w1.8:** early-season rotations: preseason values re-weighted by minutes actually played, moving the prior | Log loss −0.00055 held out (interval excludes zero), 6 of 7 seasons; weeks 2–6 0.4368 → 0.4356 |
| *Tested, not adopted:* competitive-game rotations (starters' minutes share: 72.8% in games decided by 0–5, 58.8% in 31+) | Three versions, all held out by season: (1) close-game strength from competitive rotations, log loss −0.00005 (interval spans zero, slightly worse in tournament games); (2) competitiveness-weighted lineup shift, slightly worse, 2 of 7 seasons better; (3) preseason minutes trained on competitive games, team error +0.004 (interval spans zero). Actual margins track predicted margins 1:1 in close and lopsided games alike (slope 0.999 overall, 1.006 in projected 20+ games), so ratings don't understate strong teams in competitive games |

**Reading Impact.** It's a player's share of box-score credit for her team's rating, not a measure of true on-court impact. Even after the position adjustment, it can't see screening, spacing or off-ball defense.

### Game Predictions (Games & Matchups tab)

The tab opens on a daily slate: every posted game on one day, with each team's model rank, win chance, projected score, line and total.

- **Which day.** It opens on today, or the next day with games if there are none today (after the last game of the season, the last game day). The week strip, the ‹ › arrows and the date box move between days; the arrows skip days where nothing matches the filters. "Back to today" returns to the opening day.
- **Filters.** Conference shows games where either team is in that league. Top 25 has two settings: a Top 25 team playing, or Top 25 vs Top 25. Top 25 is the model's current top 25 (the same ranks shown in the slate), not a poll. The counts on the week strip follow the filters.
- **Order.** Best matchups (lowest combined rank first) or closest games. When the schedule carries tip-off times, tip-off time is added and becomes the default.
- **Non-D1 opponents** are listed in one line under the day's games instead of taking a row each.
- **Finished games** show the final score and the pick saved before tip-off in `predictions_log_wbb.csv`, marked right or wrong, with the day's pick record in the header. A finished game's own `p_home` is recomputed from ratings that already include the result, so it is never shown as a pick. Games played before the log started show the final only.
- Click a team name to open its projection. The Matchup Predictor sits below the slate.

`predict_wbb.R` adds three fields to each game for this (the rest of the model is unchanged, so `PW_VERSION` stays w1.8 and no recalibration runs):

| Field | Source |
|---|---|
| Tip-off (UTC) | The schedule release's `game_date_time`, else ESPN's raw `date` string. Games ESPN flags as time TBD show "TBA". The page shows times in the viewer's time zone. |
| Logged pregame win chance and margin | `predictions_log_wbb.csv`, matched by game ID and flipped if home and away were swapped. |

If either lookup fails, that field is left empty and the slate falls back (no times, or no pick on finished games); the rest of the build is unaffected.

### Injuries and the in-season roster (w1.9)

**Where the roster comes from.**

- **Before the first game:** the prep sheet, as before. Every preseason run saves what it produced from the sheet (each player's projection, plus the parsed sheet) to `wbb_2027_preseason_snapshot.rds`, and a readable copy to `wbb_2027_preseason_players.csv`. The last run before the first game is the one the season uses.
- **Once any 2026-27 game between D1 teams is in the data:** runs read the snapshot and never open the prep sheet. Late edits to the sheet can't move the preseason baseline. If you find a real mistake after the season starts, set `PW_REFREEZE <- TRUE` in `predict_wbb.R` for one run to rebuild the snapshot from the sheet, then set it back.
- **Each team switches to this season's roster at its first game.** Its roster is everyone in its 2026-27 box scores, plus ESPN's roster listing once that listing looks current (at least 90% of the players who have played for the team are on it, `PW_ROSTER_FRESH`). As of September 2026 ESPN's "2027" roster file is still last season's rosters, so it is never trusted just for existing. Teams that haven't played keep the preseason roster. Players who join later (midseason transfers, walk-ons) are added with their box-score value; players who leave drop off. Data checks lists joins, departures, and teams whose ESPN listing looks out of date.
- **Player projections carry over.** A player's preseason projection (recruit rank, FIBA play, transfer adjustment) stays her prior wherever she ends up, and fades as her 2026-27 minutes build, exactly as before.

**Injuries.** There is no injury feed, so `wbb_injuries.csv` is kept by hand (team releases, beat writers, your own staff). One row per injury:

| Column | Example | Notes |
|---|---|---|
| `athlete_id` | 5241475 | ESPN's id, the same as the prep sheet's stats tab. Optional; without it the player is matched by name on the team given. |
| `name`, `team` | Aimee Flippen, Abilene Christian Wildcats | Team as in `wbb_2027_teams.csv` or its ESPN id. |
| `status` | Out / Doubtful / Questionable / Limited | |
| `expected_return` | 2026-12-20, or `season`, or blank | |
| `out_since` | 2026-10-15 | |
| `minutes_cap` | 20 | For Limited. |
| `injury`, `source`, `updated` | knee; team release; 2026-10-18 | `updated` also dates a Doubtful/Questionable/Limited tag with no return date. |

How rows are used:

- **Out + `season`:** zero minutes all year, in the preseason projection too. She stays on the roster, marked "Out for season"; her minutes go to teammates by the model's usual pecking order.
- **Out + a date:** out until then, game by game. Returns tend to slip, so her chance of playing ramps up over about two weeks centered a week after the date (`PW_INJ_SLIP_DAYS`, `PW_INJ_SLIP_SCALE`).
- **Out, no date:** out until she plays or the row changes.
- **Doubtful / Questionable:** a 75% / 50% chance she misses each game, until `expected_return`, or for 7 days after `updated` without one (`PW_INJ_STATUS_DAYS`).
- **Limited:** plays, with her minutes cut to `minutes_cap` over the same window.
- **A box score beats the file.** If she plays after `out_since` / `updated`, the row stops applying and Data checks says so. Rows past their return date with no minutes since are flagged too.
- **What it changes:** each affected game's win chance, line and total (the Game Predictions slate shows who is missing and why), and the season simulation, game by game. Team ratings on the rankings stay at full strength apart from season-long outs.
- **How much a missing player costs:** preseason, the team model's fitted weight on roster value, applied to the minutes-weighted value lost when her minutes go to teammates. In season, the same weight the model already fits for any lineup change (the lineup-shift weight in the Report Card), on her box-score-updated value. The 3-game rule ("no minutes in the last 3 games = out") still catches anyone not in the file.
- Not yet calibrated: return-date slippage and how minutes ramp up after a return are set by hand. 2020-26 box scores show every multi-game absence, so both can be fitted from history later.

**Text encoding.** Both scripts now switch R to UTF-8 when the system has it. Before this, accented names came out garbled ("Blanca Qui<U+00F1>onez") on machines where R wasn't running in UTF-8, and those players couldn't be matched across the prep sheet's tabs: 93 newcomers now match FIBA youth stats, up from 84.

### Caveats

- Conference-tournament sizes in `wbb_2027_teams.csv` are approximations; correct any that are wrong.
- NCAA selection and seeding are a proxy for the committee's process.
- Teams listing fewer than 10 players in the prep sheet are padded with "Unlisted roster spots" (see Team projection above). Teams with 3 or more are marked low confidence. Mississippi Valley State and San José State list none.
- **Coaching changes:** 63 programs are marked with a new head coach for 2026-27 in `wbb_2027_teams.csv`. The list comes from Wikipedia's list of current D-I women's coaches (first season 2026-27, as of August 2026), cross-checked against the ESPN tracker and the `coach` column already in the file.
- Top-100 recruits missing from their school's Freshmen tab are added automatically. The Report Card lists them, plus any that couldn't be placed.

### Next season

1. Set `PRED_SEASON` in `predict_wbb.R`.
2. Make a new teams CSV and point `TEAMS_FILE` and `PREP_SHEET_FILE` at the new files.
3. Calibration reruns automatically for the new season (and whenever `PW_VERSION` changes). Set `PW_RECALIBRATE <- TRUE` to force it mid-season.
