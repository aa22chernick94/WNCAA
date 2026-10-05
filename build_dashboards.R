# =============================================================================
# build_dashboards.R
#
# Rebuilds the D1 women's basketball "last 10 games" team dashboard as one
# self-contained HTML file, from real data pulled directly from
# sportsdataverse's public GitHub release assets -- the same files wehoop's
# own load_wbb_*() convenience functions read from internally:
#   - team box scores, player box scores  : espn_womens_college_basketball_team_boxscores /
#                                            espn_womens_college_basketball_player_boxscores
#   - the D1-only team list + conference   : wbb_crosswalk release
#     (its ESPN<->Bart Torvik match is D1-only, since Torvik doesn't cover
#     D2/D3 -- this is what filters team_box's ~660 teams down to 361 D1 ones)
#   - player height                        : espn_womens_college_basketball_rosters release
#
# This goes DIRECT to those release files rather than through wehoop's R
# package. That's a deliberate change from an earlier version of this script:
# wehoop's exported R function surface has proven inconsistent across
# versions (load_wbb_ratings(), specifically, wasn't exported in every
# release, which is what broke an earlier version of this script that used
# it -- opponent-adjusted ratings are no longer pulled from that release at
# all, see below). Fetching the release files directly removes that
# dependency entirely -- it's the exact same underlying wehoop-maintained
# dataset, just without going through an R wrapper whose availability can't
# be relied on. Every one of the URLs below was confirmed to return real,
# working data before being wired in.
#
# Opponent-adjusted efficiency ratings (Adj O/Adj D/AdjEM/Adj Tempo) are NOT
# pulled from a release file here. They're computed entirely client-side in
# dashboard_template.html (see computeAdjustedRatings()), from the same box
# scores loaded below, and that JS-side model is the single source of truth
# for every rank/rating shown anywhere in the page -- this script no longer
# fetches or ships a second, R-computed version that would just be
# discarded on load.
#
# All of these are static release files, not a live scrape -- fast and won't
# get rate-limited or blocked. They're rebuilt on a nightly cadence upstream,
# so running this each morning naturally picks up the previous day's games.
#
# Output: team_dashboards.html, in the same folder as this script, ready to
# open directly in a browser -- no server, no network calls at view time.
# =============================================================================

# Text encoding: accented names (Quiñonez, Monét) come out of the prep sheet
# garbled ("Qui<U+00F1>onez") when R isn't running in a UTF-8 locale, which
# also stops them matching FIBA stats and other tabs. Switch to UTF-8 if the
# system has it; nothing changes if it doesn't.
invisible(for (.l in c("en_US.UTF-8", "C.UTF-8", "English_United States.utf8", ".UTF-8"))
  if (isTRUE(l10n_info()$`UTF-8`) || nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", .l)))) break)

needed_pkgs <- c("dplyr", "tidyr", "jsonlite", "purrr", "nanoparquet", "readxl")
missing_pkgs <- needed_pkgs[!sapply(needed_pkgs, requireNamespace, quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  message("Installing missing packages: ", paste(missing_pkgs, collapse = ", "))
  install.packages(missing_pkgs, repos = "https://cloud.r-project.org")
}

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(jsonlite)
  library(purrr)
})

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a
na0 <- function(x) ifelse(is.na(x), 0, x)
# Guards against a column name that doesn't exist in this particular data
# pull (rather than letting `df$missing_col` silently return NULL and break
# a later purrr::pmap() with a length mismatch) -- used below for player-
# level fields that aren't already relied on elsewhere in this script, so
# their exact column name in player_box hasn't been separately confirmed.
safe_col <- function(df, name) if (name %in% names(df)) df[[name]] else rep(NA_real_, nrow(df))

# reliable script-directory detection when run via `Rscript build_dashboards.R`
# (sys.frame()$ofile only works inside source()/knitr, not Rscript)
get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  getwd()
}

# ---- config -----------------------------------------------------------------
# Season label follows sportsdataverse's convention: the year the season
# ENDS in (e.g. the 2025-26 season is "2026"). Auto-detected from today's
# date rather than a wehoop helper, for the same reason noted above.
# Games start in November, so that's the rollover point -- from January
# through October, the "current" season is still the one already in
# progress or just completed (label = this year); only from November
# onward does the new season's data start existing upstream at all
# (label = next year). Override this directly if it ever guesses wrong,
# e.g. in the first few days of a new season before its release file
# exists yet.
today <- Sys.Date()
SEASON <- if (as.integer(format(today, "%m")) >= 11) {
  as.integer(format(today, "%Y")) + 1
} else {
  as.integer(format(today, "%Y"))
}
OUT_DIR <- get_script_dir()

message("Season: ", SEASON, " | full season, all games")

# ---- direct data download (cached locally after the first run) -------------
GH_RELEASES <- "https://github.com/sportsdataverse/sportsdataverse-data/releases/download"

# Every file here is the current season's, which upstream rebuilds nightly, so
# a cached copy older than CACHE_MAX_HOURS is downloaded again. (Before this,
# a file was only ever downloaded once, so daily runs kept showing the first
# day's games.) If a refresh fails, the stale copy is used and a warning says so.
CACHE_MAX_HOURS <- 12
# WBB_OFFLINE=1 uses whatever is in .wbb_cache without trying to refresh it
# (no network, or testing); WBB_SKIP_PBP=1 skips the ~90 MB play-by-play file
# (low-memory machines: shot zones and game flow come back empty).
OFFLINE  <- nzchar(Sys.getenv("WBB_OFFLINE"))
SKIP_PBP <- nzchar(Sys.getenv("WBB_SKIP_PBP"))
# A downloaded file is only swapped into the cache once it actually opens: a
# truncated transfer used to be accepted (anything over 100 bytes) and then fail
# later at read time ("error reading from connection").
valid_download <- function(path) {
  if (!file.exists(path) || file.size(path) < 100) return(FALSE)
  if (grepl("\\.parquet$", path)) {
    con <- file(path, "rb"); on.exit(close(con))
    head <- readBin(con, "raw", 4); seek(con, file.size(path) - 4); tail <- readBin(con, "raw", 4)
    return(identical(rawToChar(head), "PAR1") && identical(rawToChar(tail), "PAR1"))
  }
  if (grepl("\\.rds$", path)) return(isTRUE(tryCatch({ readRDS(path); TRUE }, error = function(e) FALSE)))
  TRUE
}
download_cached <- function(url, filename) {
  cache_dir <- file.path(OUT_DIR, ".wbb_cache")
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  dest <- file.path(cache_dir, filename)
  fresh <- file.exists(dest) && file.size(dest) > 100 &&
    (OFFLINE || difftime(Sys.time(), file.mtime(dest), units = "hours") < CACHE_MAX_HOURS)
  if (fresh) return(dest)
  if (OFFLINE) stop("WBB_OFFLINE is set and ", filename, " isn't cached")
  message("  downloading ", filename, " ...")
  tmp <- paste0(dest, ".part")
  ok <- tryCatch({ utils::download.file(url, tmp, mode = "wb", quiet = TRUE); TRUE },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (ok && valid_download(tmp)) { file.rename(tmp, dest); return(dest) }
  if (file.exists(tmp)) unlink(tmp)
  if (file.exists(dest) && file.size(dest) > 100) {
    message("  WARNING: couldn't refresh ", filename, " -- using the copy from ",
            format(file.mtime(dest), "%Y-%m-%d %H:%M"), ".")
    return(dest)
  }
  stop("couldn't download ", filename, " from ", url)
}
read_rds_release <- function(tag, filename) {
  readRDS(download_cached(paste0(GH_RELEASES, "/", tag, "/", filename), filename))
}
read_parquet_release <- function(tag, filename) {
  nanoparquet::read_parquet(download_cached(paste0(GH_RELEASES, "/", tag, "/", filename), filename))
}

# Season rollover (w1.9): SEASON flips on Nov 1, often a day or two before the
# new season's box-score release exists. Instead of stopping the whole build
# (projections included), fall back to the season just finished and say so; the
# Projections tab still shows the new season. Same for the crosswalk and rosters,
# which can lag the box scores.
read_season_rds <- function(tag, stem) {
  x <- tryCatch(read_rds_release(tag, paste0(stem, SEASON, ".rds")), error = function(e) NULL)
  if (!is.null(x) && nrow(x) > 0) return(x)
  NULL
}
message("Loading team box scores ...")
team_box <- read_season_rds("espn_womens_college_basketball_team_boxscores", "team_box_")
SEASON_FALLBACK <- FALSE
if (is.null(team_box)) {
  message("  WARNING: no ", SEASON, " box scores published yet -- showing the ", SEASON - 1,
          " season on the dashboards; the Projections tab is unaffected.")
  SEASON <- SEASON - 1; SEASON_FALLBACK <- TRUE
  team_box <- read_rds_release("espn_womens_college_basketball_team_boxscores", paste0("team_box_", SEASON, ".rds"))
}

message("Loading player box scores ...")
player_box <- read_rds_release(
  "espn_womens_college_basketball_player_boxscores", paste0("player_box_", SEASON, ".rds")
)

message("Loading D1 team crosswalk (also gives conference) ...")
crosswalk <- tryCatch(read_parquet_release("wbb_crosswalk", paste0("wbb_team_crosswalk_", SEASON, ".parquet")),
  error = function(e) {
    message("  WARNING: no ", SEASON, " crosswalk yet -- using ", SEASON - 1, "'s (teams that changed conference or ",
            "division show last season's until it's published; the schedule check below still adds new D1 members).")
    read_parquet_release("wbb_crosswalk", paste0("wbb_team_crosswalk_", SEASON - 1, ".parquet"))
  })

message("Loading rosters (for player height, and now jersey/experience/hometown too) ...")
rosters <- tryCatch(read_parquet_release("espn_womens_college_basketball_rosters", paste0("rosters_", SEASON, ".parquet")),
  error = function(e) {
    message("  WARNING: no ", SEASON, " rosters yet -- using ", SEASON - 1, "'s for heights and bios.")
    read_parquet_release("espn_womens_college_basketball_rosters", paste0("rosters_", SEASON - 1, ".parquet"))
  })

# Per-player-season box Plus/Minus (offense/defense/total), used below as the
# base for the Player Value stats (BPM/VORP/Win Shares/BPR). This release can
# lag the others slightly (it's derived FROM the box scores above), so this
# degrades gracefully rather than failing the whole build: if it's not
# published yet for this SEASON, player_value stays NULL and every player's
# value columns simply show as unavailable instead of blocking the run.
message("Loading player value (Box Plus/Minus) ratings ...")
player_value <- tryCatch(
  read_parquet_release("wbb_player_value", paste0("wbb_player_value_", SEASON, ".parquet")),
  error = function(e) {
    message("  WARNING: wbb_player_value not available for season ", SEASON, " yet -- ",
            "player value stats (BPM/VORP/WS/BPR) will be blank this run. (", conditionMessage(e), ")")
    NULL
  }
)

# Play-by-play, for the shot-zone tables (Team Shooting/Defense by Zone,
# Player Shooting by Zone). Same graceful-degradation approach as
# player_value above: if this isn't available for SEASON, the zone tables
# just come back empty instead of blocking the whole build.
message("Loading play-by-play (for shot zones) ...")
pbp <- if (SKIP_PBP) { message("  WBB_SKIP_PBP is set -- skipping play-by-play."); NULL } else tryCatch(
  read_rds_release("espn_womens_college_basketball_pbp", paste0("play_by_play_", SEASON, ".rds")),
  error = function(e) {
    message("  WARNING: play-by-play not available for season ", SEASON,
            " -- shot-zone tables will be empty this run. (", conditionMessage(e), ")")
    NULL
  }
)

# Schedule: the box scores only say home or away, so neutral sites, overtime
# periods, and which finished games are missing a box score come from here.
# Optional like the two above: without it every game stays home/away (the old
# behavior), tempo isn't overtime-adjusted, and the data check is skipped.
message("Loading schedule (neutral sites, overtime, data checks) ...")
schedule <- tryCatch(
  read_parquet_release("espn_womens_college_basketball_schedules", paste0("wbb_schedule_", SEASON, ".parquet")),
  error = function(e) {
    message("  WARNING: schedule not available for season ", SEASON,
            " -- neutral sites and overtime won't be marked this run. (", conditionMessage(e), ")")
    NULL
  }
)
neutral_by_gid <- character(0); ot_by_gid <- integer(0)
if (!is.null(schedule)) {
  schedule <- as.data.frame(schedule, stringsAsFactors = FALSE)
  schedule$game_id <- as.character(schedule$game_id)
  schedule <- schedule[!duplicated(schedule$game_id), ]
  neutral_by_gid <- schedule$game_id[schedule$neutral_site %in% TRUE]
  if (!is.null(schedule$status_period)) {
    reg <- suppressWarnings(as.integer(schedule$format_regulation_periods %||% 4L))
    reg[is.na(reg)] <- 4L
    per <- suppressWarnings(as.integer(schedule$status_period))
    ot <- ifelse(!is.na(per) & per > reg, per - reg, 0L)
    ot_by_gid <- setNames(as.integer(ot), schedule$game_id)
  }
}
lookup_ot <- function(gid) { v <- unname(ot_by_gid[as.character(gid)]); if (length(v) == 0 || is.na(v)) 0L else v }

# ---- normalize key types -----------------------------------------------------
team_box <- team_box %>%
  mutate(
    team_id = as.character(team_id),
    opponent_team_id = as.character(opponent_team_id)
  )
player_box <- player_box %>%
  mutate(team_id = as.character(team_id), athlete_id = as.character(athlete_id))
rosters <- rosters %>% mutate(team_id = as.character(team_id), athlete_id = as.character(athlete_id))
if (!is.null(player_value)) {
  player_value <- player_value %>% mutate(team_id = as.character(team_id), player_id = as.character(player_id))
}

d1_ids <- unique(as.character(crosswalk$espn_team_id))
conf_by_id <- setNames(crosswalk$espn_conference, as.character(crosswalk$espn_team_id))

# D1 membership: the crosswalk, plus any team this season's schedule places in
# a D1 conference with at least D1_MIN_GAMES finished games against crosswalk
# D1 teams. The crosswalk can lag or run ahead of the season (the 2026 file
# dropped Saint Francis (PA), a 2025-26 NEC member, and leaves out
# reclassifying members like Mercyhurst that play a full conference
# schedule). A team outside this set is non-D1: its games stay in its
# opponents' records and game logs but are left out of ratings and WAB.
D1_MIN_GAMES <- 10
d1_added <- character(0)
if (!is.null(schedule) && all(c("home_conference_id", "away_conference_id") %in% names(schedule))) {
  fin <- schedule[schedule$status_type_completed %in% TRUE, ]
  sides <- rbind(
    data.frame(id = as.character(fin$home_id), cid = as.character(fin$home_conference_id), opp = as.character(fin$away_id), stringsAsFactors = FALSE),
    data.frame(id = as.character(fin$away_id), cid = as.character(fin$away_conference_id), opp = as.character(fin$home_id), stringsAsFactors = FALSE))
  sides <- sides[!is.na(sides$cid) & sides$cid != "" & sides$cid != "NA", ]
  if (nrow(sides)) {
    main_cid <- tapply(sides$cid, sides$id, function(x) names(which.max(table(x))))
    in_cw <- names(main_cid) %in% d1_ids
    # a D1 conference's name, taken from its crosswalk members
    cid_conf <- tapply(unname(conf_by_id[names(main_cid)[in_cw]]), main_cid[in_cw],
                       function(x) { x <- x[!is.na(x)]; if (length(x)) names(which.max(table(x))) else NA_character_ })
    cand <- names(main_cid)[!in_cw & main_cid %in% names(cid_conf)]
    vs_d1 <- vapply(cand, function(i) sum(sides$id == i & sides$opp %in% d1_ids), numeric(1))
    d1_added <- cand[vs_d1 >= D1_MIN_GAMES]
    if (length(d1_added)) {
      conf_by_id <- c(conf_by_id, setNames(unname(cid_conf[main_cid[d1_added]]), d1_added))
      d1_ids <- c(d1_ids, d1_added)
      nm <- vapply(d1_added, function(i) {
        k <- which(as.character(fin$home_id) == i)[1]
        if (!is.na(k)) fin$home_display_name[k] else fin$away_display_name[which(as.character(fin$away_id) == i)[1]]
      }, character(1))
      message("  added to D1 from the schedule: ", paste0(nm, " (", conf_by_id[d1_added], ")", collapse = ", "))
    }
  }
}
# safe lookup: an opponent may not be D1 (exhibition games happen), and it
# won't have an entry in conf_by_id -- [[ ]] errors on a missing name for a
# plain vector, so use single-bracket indexing (returns NA, never errors)
lookup_conf <- function(id) {
  v <- unname(conf_by_id[id])
  if (length(v) == 0 || is.na(v)) NA_character_ else v
}

# real ESPN team branding colors, straight off team_box (team_color /
# team_alternate_color are per-team-per-game but constant across a team's
# season -- take the first non-missing occurrence per team)
clean_hex <- function(x) {
  x <- trimws(tolower(as.character(x)))
  ifelse(grepl("^[0-9a-f]{6}$", x), x, NA_character_)
}
color_lookup <- team_box %>%
  mutate(team_color = clean_hex(team_color), team_alternate_color = clean_hex(team_alternate_color)) %>%
  filter(!is.na(team_color) | !is.na(team_alternate_color)) %>%
  distinct(team_id, .keep_all = TRUE) %>%
  select(team_id, team_color, team_alternate_color)
primary_by_id <- setNames(color_lookup$team_color, color_lookup$team_id)
secondary_by_id <- setNames(color_lookup$team_alternate_color, color_lookup$team_id)

# safe lookup: [[ ]] errors on a missing name for an atomic vector, so use
# single-bracket indexing (returns NA_character_, never errors) instead
lookup_color <- function(map, id) {
  v <- unname(map[id])
  if (length(v) == 0 || is.na(v)) NULL else v
}

height_lookup <- rosters %>%
  select(team_id, athlete_id, height) %>%
  distinct(team_id, athlete_id, .keep_all = TRUE)

# ---- opponent's raw box line, joined onto each team-game row --------------
# (client-side JS recomputes four factors, gauges, and top-7 from these raw
# numbers for WHATEVER subset of games the person filters to -- so what's
# needed here is each side's raw counting stats per game, not a single
# precomputed percentage the way the old last-10-only version had)
opp_box <- team_box %>%
  select(game_id, team_id, field_goals_made, field_goals_attempted,
         three_point_field_goals_made, three_point_field_goals_attempted,
         free_throws_made, free_throws_attempted, turnovers,
         offensive_rebounds, defensive_rebounds, team_score,
         assists, steals, blocks, fouls, fast_break_points, points_in_paint,
         largest_lead, total_technical_fouls) %>%
  rename(
    opponent_team_id = team_id,
    o_fgm = field_goals_made, o_fga = field_goals_attempted,
    o_tpm = three_point_field_goals_made, o_tpa = three_point_field_goals_attempted,
    o_ftm = free_throws_made, o_fta = free_throws_attempted, o_tov = turnovers,
    o_oreb = offensive_rebounds, o_dreb = defensive_rebounds, o_pts = team_score,
    o_ast = assists, o_stl = steals, o_blk = blocks, o_pf = fouls,
    o_fbPts = fast_break_points, o_pip = points_in_paint,
    o_lead = largest_lead, o_techFouls = total_technical_fouls
  )
team_box <- team_box %>% left_join(opp_box, by = c("game_id", "opponent_team_id"))

# =============================================================================
# ---- SHOT ZONE CLASSIFICATION (play-by-play) --------------------------------
# =============================================================================
# Same approach used for the WNBA edition of this dashboard, verified
# against this exact season's real play-by-play before being wired in:
#   - 2-point vs. 3-point is EXACT, straight from pbp's own points_attempted
#     column, not geometry.
#   - The 5-zone split within that (Rim/Paint/Mid-Range/Corner 3/
#     Above-the-Break 3) is a distance + sideline-proximity heuristic (see
#     README for the full account), not an official zone definition --
#     checked to produce sane shooting percentages by zone and, for every
#     team, to account for 100% of that team's box-score FGA.
#   - coordinate_x/coordinate_y are already transformed by the
#     sportsdataverse pipeline into hoop-relative feet, same convention as
#     the WNBA/NBA pbp. A small fraction of rows (~0.26% of shots, ~1.5% of
#     games, in the current season) carry corrupted/sentinel coordinate
#     values (32-bit-overflow-looking numbers) -- those are dropped by the
#     |x|<=60/|y|<=60 sanity bound below rather than propagated as bogus
#     zones.
ZONE_ORDER <- c("rim", "paint", "mid", "corner3", "break3")
ZONE_LABEL <- c(rim = "Rim", paint = "Paint", mid = "Mid-Range",
                 corner3 = "Corner 3", break3 = "Above-the-Break 3")

if (!is.null(pbp)) {
  message("Classifying shot zones from play-by-play ...")
  shots <- pbp %>%
    mutate(team_id = as.character(team_id), athlete_id_1 = as.character(athlete_id_1)) %>%
    filter(shooting_play == TRUE, !grepl("free\\s*throw", type_text, ignore.case = TRUE),
           !is.na(coordinate_x), !is.na(coordinate_y),
           abs(coordinate_x) <= 60, abs(coordinate_y) <= 60) %>%
    mutate(
      is_three = points_attempted == 3,
      hoop_x = ifelse(coordinate_x >= 0, 41.75, -41.75),
      dist_ft = sqrt((coordinate_x - hoop_x)^2 + coordinate_y^2),
      made = scoring_play == TRUE,
      zone = case_when(
        !is_three & dist_ft <= 4  ~ "rim",
        !is_three & dist_ft <= 14 ~ "paint",
        !is_three                 ~ "mid",
        is_three & abs(coordinate_y) >= 21 & dist_ft <= 24 ~ "corner3",
        is_three                  ~ "break3",
        TRUE ~ "other"
      )
    ) %>%
    left_join(team_box %>% select(game_id, team_id, opponent_team_id) %>% distinct(),
              by = c("game_id", "team_id")) %>%
    rename(def_team_id = opponent_team_id) %>%
    filter(zone %in% ZONE_ORDER)

  # per (id, game_id) zone counts as one 10-column integer matrix row
  # (ZONE_ORDER x fga/fgm), looked up by vectorised match() -- w1.9 replaces a
  # per-row tibble subset that ran ~840k times per build
  build_zone_lookup <- function(df, id_col) {
    agg <- df %>% group_by(id = as.character(.data[[id_col]]), game_id = as.character(game_id), zone) %>%
      summarise(fga = n(), fgm = sum(made, na.rm = TRUE), .groups = "drop")
    key <- paste0(agg$id, "|", agg$game_id); keys <- unique(key)
    M <- matrix(0L, length(keys), 2 * length(ZONE_ORDER)); r <- match(key, keys); zi <- match(agg$zone, ZONE_ORDER)
    M[cbind(r, 2 * zi - 1)] <- as.integer(agg$fga); M[cbind(r, 2 * zi)] <- as.integer(agg$fgm)
    list(keys = keys, M = M)
  }
  off_zone_lookup <- build_zone_lookup(shots, "team_id")
  def_zone_lookup <- build_zone_lookup(shots, "def_team_id")
  player_zone_lookup <- build_zone_lookup(shots, "athlete_id_1")
} else {
  off_zone_lookup <- def_zone_lookup <- player_zone_lookup <- list(keys = character(0), M = matrix(0L, 0, 2 * length(ZONE_ORDER)))
}

# zone rows for many (id, game) pairs at once: n x 10 integer matrix, zeros when
# a game/id has no classified shots (or play-by-play is unavailable), so the
# client never has to special-case "no data" vs. "zero shots that game"
zone_rows <- function(lookup, ids, gids) {
  r <- match(paste0(as.character(ids), "|", as.character(gids)), lookup$keys)
  out <- matrix(0L, length(r), 2 * length(ZONE_ORDER)); ok <- !is.na(r)
  if (any(ok)) out[ok, ] <- lookup$M[r[ok], , drop = FALSE]
  out
}
# compact zone dict for one row: {rim:[fga,fgm], paint:[fga,fgm], ...}
zone_dict_from <- function(v) setNames(lapply(seq_along(ZONE_ORDER), function(z) list(v[2 * z - 1], v[2 * z])), ZONE_ORDER)

# =============================================================================
# ---- GAME FLOW (play-by-play): score margin, win probability, quarters -----
# =============================================================================
# Feeds the Game Recap's flow chart, quarter-by-quarter table, lead changes,
# ties, runs and win-probability swings. One entry per game (not per team),
# keyed by game id, from the same play-by-play file the shot zones use:
#   h : the play-by-play's home team id (the client flips the view for the
#       other side, so neutral-site games still orient correctly)
#   p : cumulative score at the end of each period, flat [h1, a1, h2, a2, ...]
#   e : every change in the score margin (home minus away), in play order,
#       packed as one letter for the change (a..i = -9..-1, j..r = +1..+9;
#       a bigger jump is split into several letters) followed by the seconds
#       of game time since the previous change (omitted when 0)
#   w : ESPN's home win probability after each of those changes, two digits
#       per change ("00".."99", "--" if missing); w0 is the pregame value
# Elapsed time assumes 10-minute quarters and 5-minute overtimes (NCAA women).
# The client checks the end-of-game score here against the box score and
# says so if they disagree, rather than drawing a chart that doesn't add up.
# If the play-by-play is missing or lacks a needed column, this returns an
# empty list and the recap simply leaves the flow sections out.
FLOW_NEEDED_COLS <- c("game_id", "game_play_number", "period_number", "clock_minutes",
                      "clock_seconds", "home_score", "away_score", "home_team_id")
build_game_flow <- function(pbp, keep_gids) {
  if (is.null(pbp) || !all(FLOW_NEEDED_COLS %in% names(pbp))) {
    if (!is.null(pbp)) message("  WARNING: play-by-play is missing a column the game-flow chart needs (",
                               paste(setdiff(FLOW_NEEDED_COLS, names(pbp)), collapse = ", "),
                               ") -- recaps will skip the flow chart and quarter scores.")
    return(list())
  }
  has_wp <- "espn_home_wp" %in% names(pbp)
  d <- tibble::tibble(
    gid = as.character(pbp$game_id), ord = suppressWarnings(as.numeric(pbp$game_play_number)),
    per = suppressWarnings(as.integer(pbp$period_number)),
    clk = suppressWarnings(as.numeric(pbp$clock_minutes) * 60 + as.numeric(pbp$clock_seconds)),
    hs = suppressWarnings(as.integer(pbp$home_score)), as = suppressWarnings(as.integer(pbp$away_score)),
    hid = as.character(pbp$home_team_id),
    wp = if (has_wp) suppressWarnings(as.numeric(pbp$espn_home_wp)) else NA_real_
  )
  d <- d[d$gid %in% keep_gids & !is.na(d$per) & d$per >= 1 & !is.na(d$hs) & !is.na(d$as), ]
  if (!nrow(d)) return(list())
  d <- d[order(d$gid, d$ord, na.last = TRUE), ]
  plen <- ifelse(d$per <= 4, 600, 300)
  pstart <- ifelse(d$per <= 4, (d$per - 1) * 600, 2400 + (d$per - 5) * 300)
  d$t <- pstart + plen - pmin(pmax(d$clk, 0), plen)
  d <- d %>% group_by(gid) %>% tidyr::fill(t, .direction = "downup") %>%
    mutate(t = ifelse(is.na(t), 0, t), t = cummax(t)) %>% ungroup()

  # end-of-period cumulative scores
  per_tbl <- d %>% group_by(gid, per) %>%
    summarise(h = max(hs), a = max(as), .groups = "drop") %>%
    arrange(gid, per) %>% group_by(gid) %>% mutate(h = cummax(h), a = cummax(a)) %>% ungroup()
  per_list <- split(per_tbl, per_tbl$gid)

  # margin changes
  ev <- d %>% group_by(gid) %>%
    mutate(m = hs - as, dm = m - lag(m, default = 0L)) %>%
    filter(dm != 0) %>%
    mutate(dt = round(t - lag(t, default = 0)), dt = ifelse(is.na(dt) | dt < 0, 0, dt)) %>%
    ungroup()
  # split jumps bigger than 9 into several letters (rare -- a score correction)
  ev$n <- pmax(1L, as.integer(ceiling(abs(ev$dm) / 9)))
  if (any(ev$n > 1)) {
    ev$row <- seq_len(nrow(ev))
    ev <- tidyr::uncount(ev, n, .remove = FALSE, .id = "k")
    big <- ev$n > 1
    rest <- abs(ev$dm) - 9 * (ev$n - 1)
    ev$dm[big] <- sign(ev$dm[big]) * ifelse(ev$k[big] < ev$n[big], 9, rest[big])
    ev$dt[big & ev$k > 1] <- 0
  }
  ev$code <- paste0(letters[ifelse(ev$dm < 0, 10 + ev$dm, 9 + ev$dm)], ifelse(ev$dt > 0, ev$dt, ""))
  ev$wpc <- ifelse(is.na(ev$wp), "--", sprintf("%02d", as.integer(pmin(99, pmax(0, round(ev$wp * 100))))))
  ev_tbl <- ev %>% group_by(gid) %>%
    summarise(e = paste(code, collapse = ""), w = paste(wpc, collapse = ""), .groups = "drop")
  ev_map <- setNames(seq_len(nrow(ev_tbl)), ev_tbl$gid)

  head_tbl <- d %>% group_by(gid) %>% summarise(hid = first(hid), w0 = first(wp), .groups = "drop")
  out <- list()
  for (k in seq_len(nrow(head_tbl))) {
    g <- head_tbl$gid[k]
    pr <- per_list[[g]]
    j <- ev_map[g]
    w <- if (!is.na(j)) ev_tbl$w[j] else ""
    out[[g]] <- list(
      h = head_tbl$hid[k],
      p = if (is.null(pr)) list() else as.integer(as.vector(rbind(pr$h, pr$a))),
      e = if (!is.na(j)) ev_tbl$e[j] else "",
      w = if (has_wp && !grepl("^(--)*$", w)) w else NULL,
      w0 = if (has_wp && !is.na(head_tbl$w0[k])) round(head_tbl$w0[k], 3) else NULL
    )
  }
  out
}

# ---- full season, D1 teams only --------------------------------------------
season_games <- team_box %>%
  filter(team_id %in% d1_ids, !is.na(team_score), !is.na(opponent_team_score)) %>%
  arrange(team_id, desc(game_date))

message("Building dashboards for ", n_distinct(season_games$team_id), " D1 teams, full season (~",
        round(nrow(season_games) / n_distinct(season_games$team_id)), " games each) ...")

# ---- per-game box score rows (both teams), with height ----------------------
# Payload-size design (this used to be ~87% of the whole page):
#   1. Each game's box score is stored ONCE, keyed "gameId:teamId", in a
#      shared box_store -- previously every game carried its own `box` AND an
#      `oppBox` that was a byte-for-byte copy of the opponent's own `box`, so
#      every D1-vs-D1 box score was shipped twice.
#   2. Rows are arrays in BOX_COLS order instead of named objects (drops the
#      repeated key names), and zones are a flat 10-int vector in
#      ZONE_ORDER x (fga, fgm) order instead of a nested dict.
#   3. Name/position/height -- identical in every game a player appears in --
#      live once in box_info, keyed by athlete id (or "n:<name>" if ESPN has
#      no athlete id for that row).
# dashboard_template.html's hydrateBoxes() rebuilds the exact original
# {id, n, p, h, min, ..., zones:{rim:[fga,fgm], ...}} row objects on load and
# re-attaches g.box / g.oppBox, so no other client code had to change.
BOX_COLS <- c("key", "min", "pts", "reb", "oreb", "ast", "stl", "blk", "tov", "pf", "fg", "tp", "ft", "zones")

# Pre-split once instead of filtering the full national player_box table on
# every call -- box_rows_for used to run ~2 full-table scans per game per
# team, which was most of the build's "slow part".
player_box_by_game_team <- player_box %>%
  filter(did_not_play != TRUE) %>%
  left_join(height_lookup, by = c("team_id", "athlete_id")) %>%
  arrange(desc(minutes))
local({
  zm <- zone_rows(player_zone_lookup, player_box_by_game_team$athlete_id, player_box_by_game_team$game_id)
  player_box_by_game_team$zrow <<- I(split(zm, seq_len(nrow(zm))))   # one 10-int vector per box row
})
player_box_by_game_team <- split(player_box_by_game_team, paste0(player_box_by_game_team$game_id, ":", player_box_by_game_team$team_id))

box_store <- new.env(hash = TRUE)   # "gameId:teamId" -> list of row arrays
box_info <- new.env(hash = TRUE)    # info key -> list(name, position, height)


box_rows_for <- function(game_id_, team_id_) {
  rows <- player_box_by_game_team[[paste0(game_id_, ":", team_id_)]]
  if (is.null(rows) || nrow(rows) == 0) return(list())
  tov_col <- safe_col(rows, "turnovers")
  oreb_col <- safe_col(rows, "offensive_rebounds")
  pf_col <- safe_col(rows, "fouls")
  purrr::pmap(list(
    aid = rows$athlete_id,
    n = rows$athlete_display_name,
    p = rows$athlete_position_abbreviation,
    h = rows$height,
    minv = rows$minutes, pts = rows$points, reb = rows$rebounds, oreb = oreb_col,
    ast = rows$assists, stl = rows$steals, blk = rows$blocks, tov = tov_col, pf = pf_col,
    fgm = rows$field_goals_made, fga = rows$field_goals_attempted,
    tpm = rows$three_point_field_goals_made, tpa = rows$three_point_field_goals_attempted,
    ftm = rows$free_throws_made, fta = rows$free_throws_attempted, zr = rows$zrow
  ), function(aid, n, p, h, minv, pts, reb, oreb, ast, stl, blk, tov, pf, fgm, fga, tpm, tpa, ftm, fta, zr) {
    info_key <- if (is.na(aid) || !nzchar(as.character(aid))) paste0("n:", n) else as.character(aid)
    if (is.null(box_info[[info_key]])) {
      assign(info_key, list(n %||% "", p %||% "", h %||% ""), envir = box_info)
    }
    list(
      info_key,
      as.integer(round(minv %||% 0)), as.integer(pts %||% 0),
      as.integer(reb %||% 0), as.integer(round(oreb %||% 0)), as.integer(ast %||% 0),
      as.integer(stl %||% 0), as.integer(blk %||% 0),
      as.integer(round(tov %||% 0)), as.integer(round(pf %||% 0)),
      paste0(fgm %||% 0, "-", fga %||% 0),
      paste0(tpm %||% 0, "-", tpa %||% 0),
      paste0(ftm %||% 0, "-", fta %||% 0),
      as.list(as.integer(zr))
    )
  })
}

# Store a game/team box once; later requests for the same key are no-ops.
store_box <- function(game_id_, team_id_) {
  key <- paste0(game_id_, ":", team_id_)
  if (!exists(key, envir = box_store, inherits = FALSE)) {
    assign(key, box_rows_for(game_id_, team_id_), envir = box_store)
  }
  invisible(key)
}

# ---- assemble per-team summary (lightweight, meta only) + full detail ------
# (per-game data -- raw box components, box scores, everything the client
# needs to filter and recompute -- lives ONLY in teams_detail, keyed by
# team_id; teams_summary is just what search/landing needs, so the two
# don't duplicate the (large) game-by-game data)
message("Assembling per-team payloads (this is the slow part) ...")

team_ids <- unique(season_games$team_id)
teams_summary <- vector("list", length(team_ids))
teams_detail <- list()

for (i in seq_along(team_ids)) {
  tid <- team_ids[i]
  sub <- season_games %>% filter(team_id == tid)
  team_name <- sub$team_display_name[1]
  wins <- sum(sub$team_score > sub$opponent_team_score)
  zoff <- zone_rows(off_zone_lookup, sub$team_id, sub$game_id)
  zdef <- zone_rows(def_zone_lookup, sub$team_id, sub$game_id)

  detail_games <- purrr::pmap(list(
    game_id = sub$game_id, date = as.character(sub$game_date), opp = sub$opponent_team_display_name,
    opp_id = sub$opponent_team_id, loc = sub$team_home_away, res = sub$team_winner,
    ts = sub$team_score, os = sub$opponent_team_score,
    fgm = sub$field_goals_made, fga = sub$field_goals_attempted,
    tpm = sub$three_point_field_goals_made, tpa = sub$three_point_field_goals_attempted,
    ftm = sub$free_throws_made, fta = sub$free_throws_attempted, tov = sub$turnovers,
    oreb = sub$offensive_rebounds, dreb = sub$defensive_rebounds,
    ast = sub$assists, stl = sub$steals, blk = sub$blocks, pf = sub$fouls,
    fbPts = sub$fast_break_points, pip = sub$points_in_paint,
    lead = sub$largest_lead, techFouls = sub$total_technical_fouls,
    o_fgm = sub$o_fgm, o_fga = sub$o_fga, o_tpm = sub$o_tpm, o_tpa = sub$o_tpa,
    o_ftm = sub$o_ftm, o_fta = sub$o_fta, o_tov = sub$o_tov,
    o_oreb = sub$o_oreb, o_dreb = sub$o_dreb,
    o_ast = sub$o_ast, o_stl = sub$o_stl, o_blk = sub$o_blk, o_pf = sub$o_pf,
    o_fbPts = sub$o_fbPts, o_pip = sub$o_pip, o_lead = sub$o_lead, o_techFouls = sub$o_techFouls,
    zi = seq_len(nrow(sub))
  ), function(game_id, date, opp, opp_id, loc, res, ts, os,
              fgm, fga, tpm, tpa, ftm, fta, tov, oreb, dreb, ast, stl, blk, pf, fbPts, pip, lead, techFouls,
              o_fgm, o_fga, o_tpm, o_tpa, o_ftm, o_fta, o_tov, o_oreb, o_dreb,
              o_ast, o_stl, o_blk, o_pf, o_fbPts, o_pip, o_lead, o_techFouls, zi) {
    # box / oppBox are NOT embedded per game anymore -- each side's box score
    # is stored once in box_store (keyed gid:teamId), and hydrateBoxes() in
    # dashboard_template.html re-attaches g.box / g.oppBox on load from the
    # gid + oppId this row already carries.
    store_box(game_id, tid)
    store_box(game_id, opp_id)
    list(
      date = substr(date, 1, 10), opponent = opp, oppId = opp_id, gid = as.character(game_id),
      loc = if (as.character(game_id) %in% neutral_by_gid) "N" else if (loc == "home") "H" else if (loc == "away") "A" else "N",
      ot = lookup_ot(game_id),
      result = if (ts > os) "W" else "L",          # from the score: an NA team_winner used to read as a loss
      score = paste0(as.integer(ts), "-", as.integer(os)),
      isConf = isTRUE(lookup_conf(tid) == lookup_conf(opp_id)),
      t = list(fgm = na0(fgm), fga = na0(fga), tpm = na0(tpm), tpa = na0(tpa),
               ftm = na0(ftm), fta = na0(fta), tov = na0(tov),
               oreb = na0(oreb), dreb = na0(dreb), pts = as.integer(ts),
               ast = na0(ast), stl = na0(stl), blk = na0(blk), pf = na0(pf),
               fbPts = na0(fbPts), pip = na0(pip), lead = na0(lead), techFouls = na0(techFouls)),
      o = list(fgm = na0(o_fgm), fga = na0(o_fga), tpm = na0(o_tpm), tpa = na0(o_tpa),
               ftm = na0(o_ftm), fta = na0(o_fta), tov = na0(o_tov),
               oreb = na0(o_oreb), dreb = na0(o_dreb), pts = as.integer(os),
               ast = na0(o_ast), stl = na0(o_stl), blk = na0(o_blk), pf = na0(o_pf),
               fbPts = na0(o_fbPts), pip = na0(o_pip), lead = na0(o_lead), techFouls = na0(o_techFouls)),
      zonesOff = zone_dict_from(zoff[zi, ]),
      zonesDef = zone_dict_from(zdef[zi, ])
    )
  })

  teams_summary[[i]] <- list(
    id = tid, team = team_name, conf = conf_by_id[[tid]] %||% "",
    primary = lookup_color(primary_by_id, tid), secondary = lookup_color(secondary_by_id, tid),
    record = paste0(wins, "-", nrow(sub) - wins)
  )

  teams_detail[[tid]] <- list(team = team_name, games = detail_games)

  if (i %% 25 == 0) message("  ... ", i, " / ", length(team_ids))
}

# ---- data check for the "Data through" stamp in the page header ------------
# Finished games involving a D1 team with no box score in the release (they
# are missing from every rating and record), and D1 games with no shot
# locations in the play-by-play (their shot-zone numbers show as zeros).
data_meta <- list(
  built = format(Sys.time(), "%Y-%m-%d %H:%M"),
  through = as.character(max(as.Date(season_games$game_date), na.rm = TRUE)),
  team_games = nrow(season_games),
  schedule = !is.null(schedule), pbp = !is.null(pbp),
  d1_teams = length(unique(season_games$team_id)), d1_added = I(unname(vapply(d1_added, function(i) {
    x <- season_games$team_display_name[season_games$team_id == i][1]; if (is.na(x)) i else x }, character(1)))),
  non_d1_games = sum(!(season_games$opponent_team_id %in% d1_ids)),
  neutral = length(unique(unlist(lapply(teams_detail, function(d) unlist(lapply(d$games, function(g) if (identical(g$loc, "N")) g$gid)))))),   # games, not team-games
  missing_box = list(), no_shots = NULL,
  season_fallback = SEASON_FALLBACK   # TRUE: the new season's box scores weren't published yet
)
if (!is.null(schedule)) {
  done <- schedule[schedule$status_type_completed %in% TRUE &
                     (as.character(schedule$home_id) %in% d1_ids | as.character(schedule$away_id) %in% d1_ids) &
                     !(schedule$game_id %in% as.character(team_box$game_id)), ]
  done <- done[order(done$game_date, decreasing = TRUE), ]
  data_meta$missing_box <- lapply(seq_len(nrow(done)), function(k) list(
    gid = done$game_id[k], date = as.character(done$game_date[k]),
    home = done$home_display_name[k], away = done$away_display_name[k]))
}
# ---- game flow for the Game Recap (play-by-play) ---------------------------
message("Building game flow (score margin, win probability, quarters) ...")
game_flow <- tryCatch(
  build_game_flow(pbp, unique(as.character(season_games$game_id))),
  error = function(e) {
    message("  WARNING: game flow failed -- recaps will leave out the flow chart and quarter scores. (",
            conditionMessage(e), ")")
    list()
  }
)
message("  game flow for ", length(game_flow), " games")
data_meta$flow_games <- length(game_flow)

if (!is.null(pbp)) {
  gids <- unique(as.character(season_games$game_id))
  shot_gids <- unique(as.character(pbp$game_id[!is.na(pbp$coordinate_x) & !is.na(pbp$coordinate_y)]))
  data_meta$no_shots <- sum(!gids %in% shot_gids)
}
summary_payload <- list(season = SEASON, n_teams = length(teams_summary), teams = teams_summary, meta = data_meta)

# =============================================================================
# ---- Opponent-adjusted ratings: ONE model for the whole page (w1.9) ---------
# =============================================================================
# Before w1.9 the homepage ran its own iterative, multiplicative adjustment in
# the browser, with every game's efficiency log-compressed toward the league
# average first. That halved the spread of AdjEM (UConn about +32 instead of
# +65 per 100) while WAB, the matchup tool and the performance ratings used a
# game spread and home edge fitted on the full scale -- so WAB credited soft
# schedules by several wins. The page now uses the same ridge model as the
# Projections tab: for a finished season, fitted on that season's D1 games;
# once the projected season is under way, the projection's in-season ratings
# (results plus the preseason prior), so early-season ranks aren't 2-game noise.
# The in-page iteration is kept only as a fallback when this block can't run.
pw_env <- new.env(parent = globalenv())
predict_file <- file.path(OUT_DIR, "predict_wbb.R")
pw_loaded <- file.exists(predict_file) && isTRUE(tryCatch({
  assign("PW_DEFINE_ONLY", TRUE, envir = pw_env); sys.source(predict_file, envir = pw_env); TRUE
}, error = function(e) { message("  WARNING: couldn't load predict_wbb.R (", conditionMessage(e), ")"); FALSE }))
cal_gm <- if (pw_loaded) tryCatch({
  cf <- file.path(OUT_DIR, ".wbb_cache", sprintf("predict_wbb_calibration_%d.rds", pw_env$PRED_SEASON))
  if (file.exists(cf)) readRDS(cf)$gm else NULL }, error = function(e) NULL) else NULL
GAME_SIGMA_PTS <- if (!is.null(cal_gm$sigma)) cal_gm$sigma else 11.3

message("Fitting opponent-adjusted ratings ...")
estp <- function(fga, oreb, tov, fta) fga - na0(oreb) + tov + 0.475 * fta
rating_games <- local({
  hg <- season_games %>% filter(team_home_away == "home", opponent_team_id %in% d1_ids) %>% distinct(game_id, .keep_all = TRUE)
  rg <- data.frame(gid = as.character(hg$game_id), home = hg$team_id, away = hg$opponent_team_id,
                   hs = hg$team_score, as = hg$opponent_team_score,
                   poss = (estp(hg$field_goals_attempted, hg$offensive_rebounds, hg$turnovers, hg$free_throws_attempted) +
                           estp(hg$o_fga, hg$o_oreb, hg$o_tov, hg$o_fta)) / 2, stringsAsFactors = FALSE)
  rg$neutral <- rg$gid %in% neutral_by_gid
  rg$poss40 <- rg$poss * 40 / (40 + 5 * vapply(rg$gid, lookup_ot, integer(1)))   # tempo per 40 minutes
  rg[is.finite(rg$poss), ]
})
season_rat <- if (pw_loaded && nrow(rating_games) >= 50) tryCatch({
  tms <- sort(unique(c(rating_games$home, rating_games$away)))
  r <- pw_env$pw_fit_ratings(rating_games, tms, lambda = 1, fit_h = is.null(cal_gm$h), h_fixed = if (is.null(cal_gm$h)) 1.4 else cal_gm$h)
  list(source = "ridge, this season's D1 games", h = r$h[1], mu = r$mu[1], tmu = r$tmu[1],
       tab = data.frame(team = r$team, O = r$O, D = r$D, T = r$T, games = r$games, sd = NA_real_, stringsAsFactors = FALSE))
}, error = function(e) { message("  WARNING: rating fit failed (", conditionMessage(e), ") -- the page falls back to its own model."); NULL }) else NULL

# ---- Player Value stats: BPM (offense/defense/total) from the wbb_player_value
# release, plus VORP, wins above replacement, and Game Score per 40 -- each split
# offense/defense/total, keyed "teamId:athleteId". (The payload keys are still
# ws_* and bpr_* so older pages keep working; the labels changed in w1.9.)
#
# w1.9 fixes:
#   * VORP's minutes share was a player's minutes over the team's SUMMED player
#     minutes (~200 a game), not over the minutes a team plays (~40 a game), so
#     every VORP was a fifth of its size. Now minutes / (team player-minutes / 5),
#     Basketball-Reference's "% of team minutes" (overtime included).
#   * "Win Shares" divided VORP by 2.7 (an NBA constant that should multiply).
#     A linear points-to-wins rule also breaks at WBB's extremes (a +60 team can't
#     win 70 games), so wins above replacement are now computed per team -- actual
#     D1 wins minus what a replacement-level team (REPL_TEAM_Q percentile of D1)
#     would expect against the same schedule, home/away/neutral included -- and
#     shared among her players by positive VORP. Team totals are exact and bounded.
#   * "BPR" was Hollinger's Game Score per 40 under a name that collides with
#     EvanMiya's Bayesian Performance Rating; the page now labels it GmSc/40.
message("Building player value stats (BPM/VORP/WAR/GmSc) ...")
REPL_OBPM <- -1.0; REPL_DBPM <- -1.0        # replacement level, half of the standard -2.0 combined BPM baseline each side
FULL_SEASON_GAMES <- 31                      # reference D1 WBB season length, VORP's analogue of the NBA's /82
REPL_TEAM_Q <- 0.05                          # replacement-level team: this percentile of D1 (assumption, stated in the UI)

player_agg <- player_box %>%
  filter(did_not_play != TRUE, team_id %in% d1_ids) %>%
  group_by(team_id, athlete_id) %>%
  summarise(
    gp = n(), min = sum(minutes, na.rm = TRUE), pts = sum(points, na.rm = TRUE),
    oreb = sum(offensive_rebounds, na.rm = TRUE),
    dreb = sum(defensive_rebounds, na.rm = TRUE),
    ast = sum(assists, na.rm = TRUE), stl = sum(steals, na.rm = TRUE), blk = sum(blocks, na.rm = TRUE),
    tov = sum(turnovers, na.rm = TRUE), pf = sum(fouls, na.rm = TRUE),
    fgm = sum(field_goals_made, na.rm = TRUE), fga = sum(field_goals_attempted, na.rm = TRUE),
    ftm = sum(free_throws_made, na.rm = TRUE), fta = sum(free_throws_attempted, na.rm = TRUE),
    .groups = "drop"
  ) %>% filter(min > 0)
pa <- as.data.frame(player_agg, stringsAsFactors = FALSE)
team_games_by_id <- setNames(sapply(teams_detail, function(d) length(d$games)), names(teams_detail))
team_min_map <- tapply(pa$min, pa$team_id, sum)

# Game Score (Hollinger), split offense/defense, per 40 minutes
pa$gs_o <- with(pa, pts + 0.4 * fgm - 0.7 * fga - 0.4 * (fta - ftm) + 0.7 * oreb + 0.7 * ast - tov) * 40 / pa$min
pa$gs_d <- with(pa, 0.3 * dreb + stl + 0.7 * blk - 0.4 * pf) * 40 / pa$min
pa$key <- paste0(pa$team_id, ":", pa$athlete_id)
kv <- if (!is.null(player_value)) match(pa$key, paste0(player_value$team_id, ":", player_value$player_id)) else rep(NA_integer_, nrow(pa))
pa$obpm <- if (!is.null(player_value)) player_value$box_obpm[kv] else NA_real_
pa$dbpm <- if (!is.null(player_value)) player_value$box_dbpm[kv] else NA_real_
pa$bpm  <- if (!is.null(player_value)) player_value$box_bpm[kv] else NA_real_
tg <- unname(team_games_by_id[pa$team_id]); tg[is.na(tg)] <- FULL_SEASON_GAMES
min_share <- pa$min / (unname(team_min_map[pa$team_id]) / 5)     # share of the minutes her team played
pa$vorp_o <- (pa$obpm - REPL_OBPM) * min_share * tg / FULL_SEASON_GAMES
pa$vorp_d <- (pa$dbpm - REPL_DBPM) * min_share * tg / FULL_SEASON_GAMES

# team wins above a replacement-level team, on each team's own D1 schedule
pa$war_o <- NA_real_; pa$war_d <- NA_real_
if (!is.null(season_rat) && !is.null(player_value)) local({
  tab <- season_rat$tab; em <- setNames(tab$O - tab$D, tab$team)
  em_repl <- unname(stats::quantile(em, REPL_TEAM_Q))
  sig_em <- GAME_SIGMA_PTS / (season_rat$tmu / 100)
  rg <- rating_games[rating_games$home %in% names(em) & rating_games$away %in% names(em), ]
  loc <- ifelse(rg$neutral, 0, 1)
  side <- rbind(data.frame(team = rg$home, opp = rg$away, l = loc, won = rg$hs > rg$as),
                data.frame(team = rg$away, opp = rg$home, l = -loc, won = rg$as > rg$hs))
  side$p_repl <- stats::pnorm((em_repl - em[side$opp] + 2 * season_rat$h * side$l) / sig_em)
  twar <- tapply(side$won - side$p_repl, side$team, sum)
  vo <- pmax(pa$vorp_o, 0); vd <- pmax(pa$vorp_d, 0); vo[is.na(vo)] <- 0; vd[is.na(vd)] <- 0
  tot <- tapply(vo + vd, pa$team_id, sum)
  t_war <- unname(twar[pa$team_id]); t_tot <- unname(tot[pa$team_id])
  ok <- !is.na(pa$bpm) & !is.na(t_war) & t_tot > 0
  pa$war_o[ok] <<- t_war[ok] * vo[ok] / t_tot[ok]
  pa$war_d[ok] <<- t_war[ok] * vd[ok] / t_tot[ok]
})

r1 <- function(x) round(x, 1)
player_values <- setNames(lapply(seq_len(nrow(pa)), function(i) {
  e <- list(gp = as.integer(pa$gp[i]), min = as.integer(pa$min[i]),
            bpr_o = r1(pa$gs_o[i]), bpr_d = r1(pa$gs_d[i]), bpr = r1(pa$gs_o[i] + pa$gs_d[i]))
  # players not in the wbb_player_value release (too few minutes, etc.) leave
  # the BPM-based keys out; the client treats a missing key as null
  if (!is.na(pa$bpm[i])) e <- c(e, list(
    obpm = r1(pa$obpm[i]), dbpm = r1(pa$dbpm[i]), bpm = r1(pa$bpm[i]),
    vorp_o = r1(pa$vorp_o[i]), vorp_d = r1(pa$vorp_d[i]), vorp = r1(pa$vorp_o[i] + pa$vorp_d[i]),
    ws_o = if (is.na(pa$war_o[i])) NULL else r1(pa$war_o[i]), ws_d = if (is.na(pa$war_d[i])) NULL else r1(pa$war_d[i]),
    ws = if (is.na(pa$war_o[i])) NULL else r1(pa$war_o[i] + pa$war_d[i])))
  e
}), pa$key)

# ---- Player bio (jersey/experience/headshot/hometown) for the player
# profile page -- same "teamId:athleteId" key shape as player_values above
message("Building player bio lookup ...")
player_bio <- rosters %>%
  distinct(team_id, athlete_id, .keep_all = TRUE) %>%
  transmute(
    key = paste0(team_id, ":", athlete_id),
    jersey = jersey, exp = experience_display_value, headshot = headshot_href,
    hometown = ifelse(!is.na(birth_place_city) & !is.na(birth_place_state),
                       paste0(birth_place_city, ", ", birth_place_state),
                       ifelse(!is.na(birth_place_city), birth_place_city, NA_character_))
  )
player_bio_list <- setNames(
  purrr::pmap(list(player_bio$jersey, player_bio$exp, player_bio$headshot, player_bio$hometown),
              function(jersey, exp, headshot, hometown) list(jersey = jersey, exp = exp, headshot = headshot, hometown = hometown)),
  player_bio$key
)

message("Writing HTML ...")
# Every JSON block sits inside a <script> tag, so any "</" in the data (a name,
# a note, a hometown) must be escaped or it can end the tag early. w1.9 applies
# this to every block (before, only the projections block was escaped).
to_json <- function(x, ...) gsub("</", "<\\/", as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", ...)), fixed = TRUE)
summary_json <- to_json(summary_payload)
detail_json <- to_json(teams_detail)
player_values_json <- to_json(player_values)
player_bio_json <- to_json(player_bio_list)
# shared, deduplicated box scores (see BOX_COLS / store_box above); the
# schema travels with the data so the client never hard-codes column order
box_json <- to_json(list(cols = BOX_COLS, zones = ZONE_ORDER, info = as.list(box_info), rows = as.list(box_store)))
message("  box scores stored: ", length(ls(box_store)), " team-games, ",
        length(ls(box_info)), " distinct players")
# game flow: one entry per game id (see build_game_flow); an empty result
# still serializes as an object so the page can tell "no flow" from an error
flow_json <- to_json(list(v = 1L, g = if (length(game_flow)) game_flow else setNames(list(), character(0))))
generated_at <- format(Sys.time(), "%Y-%m-%d %H:%M")

# ---- 2026-27 projections (predict_wbb.R) ------------------------------------
# Roster-based preseason model + season simulation; see README "2026-27
# Projections". Needs predict_wbb.R, wbb_2027_teams.csv and the prep sheet
# (2027_Prep_Sheet_v2.xlsx) next to this script. If anything in it fails, the
# rest of the dashboard still builds and the tab explains what went wrong.
# w1.9: everything below needs only the JSON strings built above, so release the
# big tables (national player box, play-by-play shots, per-game stores) before the
# 10,000-season simulation. On a 4 GB machine the build used to be killed here.
rm(list = intersect(c("player_box", "player_box_by_game_team", "team_box", "season_games", "pbp", "shots", "opp_box",
                      "off_zone_lookup", "def_zone_lookup", "player_zone_lookup", "box_store", "box_info",
                      "teams_detail", "game_flow", "player_agg", "pa", "rosters", "player_bio", "player_bio_list"), ls()))
invisible(gc())
predict_payload <- NULL
predict_json <- tryCatch({
  if (!file.exists(predict_file)) stop("predict_wbb.R not found next to build_dashboards.R")
  if (!pw_loaded) stop("predict_wbb.R couldn't be loaded (see the warning above)")
  message("Building 2026-27 projections ...")
  predict_payload <- pw_env$pw_run()
  to_json(predict_payload, digits = NA)
}, error = function(e) {
  message("  WARNING: prediction module failed -- the Projections tab will show this error. (", conditionMessage(e), ")")
  as.character(jsonlite::toJSON(list(ok = FALSE, error = conditionMessage(e)), auto_unbox = TRUE))
})

template_path <- file.path(OUT_DIR, "dashboard_template.html")
if (!file.exists(template_path)) {
  stop(
    "dashboard_template.html not found next to build_dashboards.R.\n",
    "This script's HTML/CSS/JS template lives in that separate file -- ",
    "keep both files in the same folder (expected: ", template_path, ")."
  )
}
html_shell <- paste(readLines(template_path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")

# ---- w1.11: compressed data blocks ------------------------------------------------
# Each JSON block is zlib-compressed and base64-encoded (data-z="deflate"); the
# template's loader unpacks them in the browser before the app starts. The file
# drops to roughly a quarter of its size (smaller Drive copies, faster phone
# loads). Only done when the template has the loader (id="wbb-main"), so an older
# template never receives data it can't read. WBB_COMPRESS=0 turns it off.
COMPRESS <- !identical(Sys.getenv("WBB_COMPRESS"), "0") && grepl('id="wbb-main"', html_shell, fixed = TRUE)
pack <- function(js) {
  js <- as.character(js)
  if (!COMPRESS) return(js)
  jsonlite::base64_enc(memCompress(charToRaw(enc2utf8(js)), type = "gzip"))   # zlib stream = DecompressionStream("deflate")
}
out_html <- html_shell
out_html <- sub("__SUMMARY_JSON__", pack(summary_json), out_html, fixed = TRUE)
out_html <- sub("__DETAIL_JSON__", pack(detail_json), out_html, fixed = TRUE)
out_html <- sub("__PLAYER_VALUES_JSON__", pack(player_values_json), out_html, fixed = TRUE)
out_html <- sub("__PLAYER_BIO_JSON__", pack(player_bio_json), out_html, fixed = TRUE)
if (!grepl("__BOX_JSON__", out_html, fixed = TRUE)) {
  stop("dashboard_template.html has no __BOX_JSON__ placeholder -- this build script ",
       "requires the matching template (box scores are no longer embedded per game).")
}
out_html <- sub("__BOX_JSON__", pack(box_json), out_html, fixed = TRUE)
out_html <- sub("__PREDICT_JSON__", pack(predict_json), out_html, fixed = TRUE)
# ---- the page's ratings (w1.9): this season's ridge fit, or -- once the
# projected season is the one on the dashboards -- the projection's in-season
# ratings (results + preseason prior), with the ridge fit for anyone it lacks
ratings_payload <- local({
  if (is.null(season_rat)) return(NULL)
  tab <- season_rat$tab; src <- season_rat$source; h <- season_rat$h; mu <- season_rat$mu; tmu <- season_rat$tmu
  rn <- predict_payload$ratings_now
  if (!is.null(rn) && pw_loaded && identical(as.integer(SEASON), as.integer(pw_env$PRED_SEASON))) {
    pr <- data.frame(team = rn$team, O = rn$O, D = rn$D, T = rn$T, games = rn$games, sd = rn$sd, stringsAsFactors = FALSE)
    # teams the projection doesn't carry keep their ridge fit (same model, both centred on D1 average)
    extra <- tab[!tab$team %in% pr$team, ]
    tab <- rbind(pr, extra); src <- paste0("projection model, ", rn$mode, " (results + preseason prior)")
    h <- rn$h; mu <- rn$mu; tmu <- rn$tmu
  }
  list(source = src, h = round(h, 3), mu = round(mu, 3), tmu = round(tmu, 3), sigma = round(GAME_SIGMA_PTS, 3),
       cols = c("adjO", "adjD", "em", "tempo", "sd", "games"),
       teams = setNames(lapply(seq_len(nrow(tab)), function(i) list(round(mu + tab$O[i], 2), round(mu + tab$D[i], 2),
                        round(tab$O[i] - tab$D[i], 2), round(tmu + tab$T[i], 2), if (is.na(tab$sd[i])) NULL else round(tab$sd[i], 2),
                        as.integer(tab$games[i]))), tab$team))
})
if (grepl("__RATINGS_JSON__", out_html, fixed = TRUE)) {
  out_html <- sub("__RATINGS_JSON__", pack(if (is.null(ratings_payload)) "null" else to_json(ratings_payload, digits = NA)), out_html, fixed = TRUE)
} else message("  WARNING: dashboard_template.html has no __RATINGS_JSON__ placeholder (older template) -- ",
               "the page will use its own in-browser ratings.")
if (grepl("__FLOW_JSON__", out_html, fixed = TRUE)) {
  out_html <- sub("__FLOW_JSON__", pack(flow_json), out_html, fixed = TRUE)
} else {
  message("  WARNING: dashboard_template.html has no __FLOW_JSON__ placeholder (older template) -- ",
          "game recaps will skip the flow chart and quarter scores.")
}

if (COMPRESS) out_html <- gsub('type="application/json">', 'type="application/json" data-z="deflate">', out_html, fixed = TRUE)
out_path <- file.path(OUT_DIR, "team_dashboards.html")
writeLines(out_html, out_path, useBytes = TRUE)

message("Done. Wrote ", out_path, " (", round(file.size(out_path) / 1e6, 1), " MB", if (COMPRESS) ", compressed data" else "", "), ",
        length(teams_summary), " D1 teams, season ", SEASON, ".")
