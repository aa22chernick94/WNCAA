# =============================================================================
# ASPN WBB -- 2026-27 prediction module
# =============================================================================
# Sourced by build_dashboards.R. Produces `predict_payload`, written into the
# page as __PREDICT_JSON__. If anything in here fails, the rest of the
# dashboard still builds and the Predictions tab shows the error.
#
# Pipeline
#   1. Season ratings. For every season 2017-2026, opponent-adjusted offense,
#      defense and tempo (points / possessions per 100, ridge regression on
#      every D1-vs-D1 game, home court fitted, neutral sites from the
#      schedule release).
#   2. Player value. An offense/defense rating per 100 possessions built only
#      from box stats the prep sheet also has (so it can be computed the same
#      way for every player), constrained so a team's minute-weighted player
#      values add up exactly to its adjusted rating -- the Box Plus/Minus idea.
#      That constraint is what makes a 20-ppg scorer on a weak team worth less
#      than one on a strong team.
#   3. Player projection. Next season's value from the last two seasons,
#      experience, and whether she transferred (and up or down), fitted on
#      every 2017-2026 season-to-season transition. Newcomers without D1 stats
#      get a value from recruit rank (fitted on the 2025 top-100 class's real
#      2025-26 seasons), FIBA youth numbers (fitted on 2025 FIBA players who
#      reached D1 in 2025-26), or program strength.
#   4. Team projection. Projected minutes x projected values, blended with the
#      program's own recent level, fitted and backtested season by season
#      (walk-forward: each season predicted only from earlier seasons).
#   5. Simulation. Real posted 2026-27 games, generated conference games where
#      a league hasn't posted its schedule, last season's nonconference slate
#      standing in for unannounced games, conference tournaments and an
#      approximate 68-team NCAA tournament. Once games are played, results
#      replace the preseason projection gradually (ridge fit with the
#      preseason projection as its prior, calibrated on past seasons).
# =============================================================================

PW_VERSION        <- "w1.12"
PW_CAL_VERSION    <- "w1.11"                    # calibration-cache compatibility: bump ONLY when calibration code changes (w1.10: held-out validation)
PRED_SEASON       <- 2027                       # season label = year it ends
HIST_SEASONS      <- 2017:(PRED_SEASON - 1)     # full-coverage seasons in the releases (2014-16 are partial)
PREP_SHEET_FILE   <- "2027_Prep_Sheet_v2.xlsx"  # roster source of truth (2027 Team column)
TEAMS_FILE        <- "wbb_2027_teams.csv"       # 2026-27 conferences, coaching changes, formats
N_SIMS            <- 10000
PW_RECALIBRATE    <- FALSE                      # TRUE refits the historical calibration
NCAA_FIELD        <- 68
NON_D1_EM         <- -30                        # a non-D1 opponent's rating (pts/100 vs avg D1)
# ---- w1.6 options --------------------------------------------------------------
PW_RECRUIT_HISTORY <- "wbb_recruits_history.csv" # optional: year, rank, name, espn_team_id (past top-100 classes)
PW_COACH_HISTORY   <- "wbb_coach_history.csv"    # optional: season, espn_id, coach (one row per team-season)
PW_NOND1_LEVELS    <- "wbb_nond1_levels.csv"     # optional: name, level (D2 / NAIA / JUCO) for non-D1 transfers
PW_TUNE            <- FALSE                      # TRUE runs the nested tuning study (slow; results in the Report Card)
PW_BOOT            <- 1000                       # bootstrap draws for backtest confidence intervals
PW_INS_NEWQ       <- 0.25                       # w1.10: an unlisted player on the box score is valued at this quantile of her team's sheet (0.25 = through w1.9)
PW_ROSTER_MIN_LISTED <- 3                        # listed in at least this many box scores to count as rostered
# ---- w1.9: roster transition, identity, injuries ---------------------------------
PW_REFREEZE        <- FALSE                      # TRUE for ONE run in season: rebuild the frozen preseason snapshot from the prep sheet
PW_SNAPSHOT_FILE   <- sprintf("wbb_%d_preseason_snapshot.rds", PRED_SEASON)
PW_SNAPSHOT_CSV    <- sprintf("wbb_%d_preseason_players.csv", PRED_SEASON)
PW_ROSTER_IDS_CSV  <- sprintf("wbb_%d_roster_ids.csv", PRED_SEASON)        # written every run: every roster row's id and how it was linked
PW_REVIEW_CSV      <- sprintf("wbb_%d_needs_review.csv", PRED_SEASON)      # written in season: ambiguous identity matches, never auto-merged
PW_XWALK_FILE      <- "wbb_player_xwalk.csv"     # optional, hand-kept: pid, espn_id, aliases, note
PW_ROSTER_MODE     <- tolower(Sys.getenv("WBB_ROSTER_MODE", "auto"))  # auto | prep | live
PW_ROSTER_FRESH    <- 0.90                       # ESPN listing trusted once it holds this share of a team's box-score players
PW_ROSTER_SIZE     <- c(9, 24)                   # ...and lists a plausible number of players
PW_INJURY_FILE     <- "wbb_injuries.csv"
PW_INJ_SLIP_DAYS   <- 7                          # returns slip: chance of playing is centred this many days after expected_return
PW_INJ_SLIP_SCALE  <- 3.5                        # logistic scale (days) of that ramp, roughly a two-week rise
PW_INJ_STATUS_DAYS <- 7                          # Doubtful/Questionable/Limited with no return date apply this long after `updated`
PW_INJ_MISS        <- c(out = 1, doubtful = 0.75, questionable = 0.5, limited = 0)
PW_OFFLINE         <- nzchar(Sys.getenv("WBB_OFFLINE"))   # use cached release files only (testing / no network)
set.seed(20260925)

# ---- downloads (cached in .wbb_cache; finished seasons never re-download) ----
pw_cache_dir <- function() { d <- file.path(OUT_DIR, ".wbb_cache"); dir.create(d, FALSE, TRUE); d }
pw_get <- function(tag, fn, refresh = FALSE) {
  dest <- file.path(pw_cache_dir(), fn)
  fresh <- file.exists(dest) && file.size(dest) > 100 &&
    (!refresh || PW_OFFLINE || difftime(Sys.time(), file.mtime(dest), units = "hours") < 12)
  if (fresh) return(dest)
  if (PW_OFFLINE) return(NULL)
  tmp <- paste0(dest, ".part")
  ok <- tryCatch({ utils::download.file(paste0(GH_RELEASES, "/", tag, "/", fn), tmp, mode = "wb", quiet = TRUE); TRUE },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (ok && file.exists(tmp) && file.size(tmp) > 100) { file.rename(tmp, dest); return(dest) }
  if (file.exists(tmp)) unlink(tmp)
  if (file.exists(dest) && file.size(dest) > 100) return(dest)   # stale copy beats nothing
  NULL
}
pw_pq <- function(tag, fn, refresh = FALSE) {
  p <- pw_get(tag, fn, refresh)
  if (is.null(p)) return(NULL)
  as.data.frame(nanoparquet::read_parquet(p), stringsAsFactors = FALSE)
}
pw_num <- function(x) suppressWarnings(as.numeric(x))

# ---- sparse normal equations (each row touches only a few coefficients) -------
# idx / val: m x k matrices of column indices and values; returns X'WX and X'Wy
pw_normal_eq <- function(idx, val, w, y, p) {
  A <- matrix(0, p, p); b <- numeric(p); k <- ncol(idx)
  for (a in seq_len(k)) {
    s <- tapply(w * val[, a] * y, idx[, a], sum); b[as.integer(names(s))] <- b[as.integer(names(s))] + s
    for (c in seq_len(k)) {
      lin <- (idx[, c] - 1) * p + idx[, a]
      s <- tapply(w * val[, a] * val[, c], lin, sum)
      A[as.integer(names(s))] <- A[as.integer(names(s))] + s
    }
  }
  list(A = A, b = b)
}

# ---- one season of games -----------------------------------------------------
pw_schedule <- function(yr) {
  s <- pw_pq("espn_womens_college_basketball_schedules", sprintf("wbb_schedule_%d.parquet", yr), refresh = yr >= PRED_SEASON)
  if (is.null(s)) return(NULL)
  s$game_id <- as.character(s$game_id); s$home_id <- as.character(s$home_id); s$away_id <- as.character(s$away_id)
  s
}

pw_season_games <- function(yr) {
  tb <- pw_pq("espn_womens_college_basketball_team_boxscores", sprintf("team_box_%d.parquet", yr), refresh = yr >= PRED_SEASON)
  if (is.null(tb) || !nrow(tb)) return(NULL)
  tb$team_id <- as.character(tb$team_id); tb$opponent_team_id <- as.character(tb$opponent_team_id)
  tb$game_id <- as.character(tb$game_id)
  for (v in c("team_score", "opponent_team_score", "field_goals_attempted", "offensive_rebounds", "turnovers", "free_throws_attempted"))
    tb[[v]] <- pw_num(tb[[v]])
  tb <- tb[!is.na(tb$team_score) & !is.na(tb$opponent_team_score) & !is.na(tb$field_goals_attempted) &
           !is.na(tb$turnovers) & tb$team_score > 0, ]
  tb$poss <- tb$field_goals_attempted - na0(tb$offensive_rebounds) + tb$turnovers + 0.475 * tb$free_throws_attempted
  cnt <- table(tb$team_id)
  d1 <- names(cnt)[cnt >= (if (yr >= PRED_SEASON) 1 else 10)]
  h <- tb[tb$team_home_away == "home", ]; h <- h[!duplicated(h$game_id), ]
  a <- tb[tb$team_home_away == "away", c("game_id", "poss")]; a <- a[!duplicated(a$game_id), ]
  h$aposs <- a$poss[match(h$game_id, a$game_id)]
  sch <- pw_schedule(yr)
  neu <- if (!is.null(sch)) sch$neutral_site[match(h$game_id, sch$game_id)] else NA
  cc  <- if (!is.null(sch)) sch$conference_competition[match(h$game_id, sch$game_id)] else NA
  data.frame(gid = h$game_id, date = as.Date(h$game_date), season = yr, st = as.integer(h$season_type),
             home = h$team_id, away = h$opponent_team_id, hs = h$team_score, as = h$opponent_team_score,
             poss = ifelse(is.na(h$aposs), h$poss, (h$poss + h$aposs) / 2),
             neutral = !is.na(neu) & neu %in% TRUE, conf = !is.na(cc) & cc %in% TRUE,
             hname = h$team_display_name, aname = h$opponent_team_display_name,
             d1h = h$team_id %in% d1, d1a = h$opponent_team_id %in% d1, stringsAsFactors = FALSE)
}

# ---- opponent-adjusted ratings -----------------------------------------------
# eff (pts/100) = mu + O[off team] + D[def team] + h * loc ; loc = +1 home side, -1 away side
# poss          = tmu + T[home] + T[away]
# Ridge toward `prior` (list of named O, D, T; default 0) with weight `lambda`
# games' worth; `w` optional per-game weights (recency in-season).
pw_fit_ratings <- function(g, teams, lambda = 1, prior = NULL, w = NULL, fit_h = TRUE, h_fixed = 1.4) {
  n <- length(teams); p <- 2 * n + 2
  g <- g[g$home %in% teams & g$away %in% teams & g$poss > 40, ]
  if (is.null(w)) w <- rep(1, nrow(g))
  hi <- match(g$home, teams); ai <- match(g$away, teams)
  loc <- ifelse(g$neutral, 0, 1)
  m <- nrow(g)
  idx <- rbind(cbind(1, 1 + hi, 1 + n + ai, p), cbind(1, 1 + ai, 1 + n + hi, p))
  val <- rbind(cbind(1, 1, 1, loc), cbind(1, 1, 1, -loc))
  y <- c(100 * g$hs / g$poss, 100 * g$as / g$poss); ww <- c(w, w)
  if (!fit_h) { y <- y - val[, 4] * h_fixed; val[, 4] <- 0 }
  ne <- pw_normal_eq(idx, val, ww, y, p)
  pO <- if (is.null(prior)) rep(0, n) else unname(prior$O[teams]); pO[is.na(pO)] <- 0
  pD <- if (is.null(prior)) rep(0, n) else unname(prior$D[teams]); pD[is.na(pD)] <- 0
  lam <- if (length(lambda) == 1) rep(lambda, n) else unname(lambda[teams])
  pen <- c(1e-4, lam, lam, if (fit_h) 1e-3 else 1)
  A <- ne$A + diag(pen); b <- ne$b + pen * c(0, pO, pD, 0)
  th <- solve(A, b)
  O <- th[1 + seq_len(n)]; D <- th[1 + n + seq_len(n)]
  mu <- th[1] + mean(O) + mean(D); O <- O - mean(O); D <- D - mean(D)
  # tempo
  pT <- if (is.null(prior) || is.null(prior$T)) rep(0, n) else unname(prior$T[teams]); pT[is.na(pT)] <- 0
  idx2 <- cbind(1, 1 + hi, 1 + ai); val2 <- cbind(1, 1, 1)
  # tempo per 40 minutes when the caller supplies it (overtime-adjusted, w1.9);
  # the historical calibration doesn't, so its numbers are unchanged
  ne2 <- pw_normal_eq(idx2, val2, w, if (!is.null(g$poss40)) g$poss40 else g$poss, n + 1)
  A2 <- ne2$A + diag(c(1e-4, lam)); b2 <- ne2$b + c(1e-4, lam) * c(0, pT)
  t2 <- solve(A2, b2); Tm <- t2[-1]; tmu <- t2[1] + 2 * mean(Tm); Tm <- Tm - mean(Tm)
  ng <- tabulate(c(hi, ai), n)
  data.frame(team = teams, O = O, D = D, em = O - D, adjO = mu + O, adjD = mu + D, T = Tm,
             tempo = tmu + Tm, games = ng, mu = mu, tmu = tmu, h = if (fit_h) th[p] else h_fixed,
             stringsAsFactors = FALSE)
}

pw_season_ratings <- function(g) {
  gg <- g[g$d1h & g$d1a, ]
  teams <- sort(unique(c(gg$home, gg$away)))
  pw_fit_ratings(gg, teams, lambda = 1)
}

# ---- player seasons ------------------------------------------------------------
PW_STATS <- c("pts", "fgm", "fga", "fg3m", "fg3a", "ftm", "fta", "reb", "ast", "stl", "blk", "tov", "oreb", "dreb", "pf")
pw_player_seasons <- function(yr) {
  pb <- pw_pq("espn_womens_college_basketball_player_boxscores", sprintf("player_box_%d.parquet", yr), refresh = yr >= PRED_SEASON)
  if (is.null(pb)) return(NULL)
  pb$min <- pw_num(pb$minutes)
  roster <- pw_roster_listing(pb)
  pb <- pb[!is.na(pb$min) & pb$min > 0 & !is.na(pb$athlete_id), ]
  map <- c(pts = "points", fgm = "field_goals_made", fga = "field_goals_attempted",
           fg3m = "three_point_field_goals_made", fg3a = "three_point_field_goals_attempted",
           ftm = "free_throws_made", fta = "free_throws_attempted", reb = "rebounds",
           ast = "assists", stl = "steals", blk = "blocks", tov = "turnovers",
           oreb = "offensive_rebounds", dreb = "defensive_rebounds", pf = "fouls")
  X <- sapply(map, function(v) if (is.null(pb[[v]])) rep(NA_real_, nrow(pb)) else na0(pw_num(pb[[v]])))
  # older box scores without the split: estimate from total rebounds
  miss <- is.na(X[, "oreb"]) | (X[, "oreb"] + X[, "dreb"] == 0 & X[, "reb"] > 0)
  X[miss, "oreb"] <- 0.3 * X[miss, "reb"]; X[miss, "dreb"] <- X[miss, "reb"] - X[miss, "oreb"]
  key <- paste(pb$athlete_id, pb$team_id, sep = "|")
  agg <- rowsum(cbind(min = pb$min, gp = 1, X), key)
  df <- data.frame(key = rownames(agg), agg, stringsAsFactors = FALSE)
  df$athlete_id <- sub("\\|.*", "", df$key); df$team_id <- sub(".*\\|", "", df$key)
  nm <- pb[!duplicated(pb$athlete_id), c("athlete_id", "athlete_display_name", "athlete_position_abbreviation")]
  df$name <- nm$athlete_display_name[match(df$athlete_id, nm$athlete_id)]
  df$pos <- nm$athlete_position_abbreviation[match(df$athlete_id, nm$athlete_id)]
  # a mid-season transfer keeps the team she played the most minutes for
  df <- df[order(df$athlete_id, -df$min), ]
  tot <- rowsum(as.matrix(df[, c("min", "gp", names(map))]), df$athlete_id)
  df <- df[!duplicated(df$athlete_id), ]
  df[, c("min", "gp", names(map))] <- tot[df$athlete_id, ]
  df$season <- yr
  out <- df[, c("season", "athlete_id", "name", "pos", "team_id", "min", "gp", names(map))]
  # rostered = the team she logged minutes for, else the team whose box scores list her most
  if (!is.null(roster)) {
    roster$team_id[roster$athlete_id %in% out$athlete_id] <- out$team_id[match(roster$athlete_id[roster$athlete_id %in% out$athlete_id], out$athlete_id)]
    roster$played <- roster$athlete_id %in% out$athlete_id
    roster <- roster[roster$played | roster$listed >= PW_ROSTER_MIN_LISTED, ]
  }
  attr(out, "roster") <- roster
  out
}

# Every player a team's box scores list in a season, including "did not play"
# rows. This is the season's roster as a prep sheet would show it: redshirts,
# players hurt all year and end-of-bench walk-ons included. The backtest uses it
# so it faces the same problem production does (w1.6).
pw_roster_listing <- function(pb) {
  if (is.null(pb$did_not_play) || !nrow(pb)) return(NULL)
  x <- pb[!is.na(pb$athlete_id) & !is.na(pb$team_id), c("athlete_id", "team_id", "game_id")]
  x$athlete_id <- as.character(x$athlete_id); x$team_id <- as.character(x$team_id)
  x <- x[!duplicated(paste(x$athlete_id, x$game_id)), ]
  k <- paste(x$athlete_id, x$team_id, sep = "|")
  n <- table(k)
  r <- data.frame(athlete_id = sub("\\|.*", "", names(n)), team_id = sub(".*\\|", "", names(n)), listed = as.integer(n),
                  stringsAsFactors = FALSE)
  r <- r[order(r$athlete_id, -r$listed), ]
  tot <- tapply(r$listed, r$athlete_id, sum)
  r <- r[!duplicated(r$athlete_id), ]
  r$listed <- as.integer(tot[r$athlete_id])
  nm <- pb[!duplicated(pb$athlete_id), c("athlete_id", "athlete_display_name")]
  r$name <- nm$athlete_display_name[match(r$athlete_id, as.character(nm$athlete_id))]
  r
}

# ---- player value (team-constrained box rating) --------------------------------
# Position adjustment (the idea behind Box Plus/Minus 2.0's position terms):
# box stats hand bigs credit for rebounds and blocks that come with the role and
# give guards little for the defense they play on the perimeter. Before the team
# constraint, each position group's league-average raw value is pulled toward
# the overall average by PW_POS_ALPHA (0 = off, 1 = fully neutral), chosen on the
# walk-forward team backtest. The team totals are unchanged -- only how a team's
# rating is shared among its players.
PW_POS_ALPHA <- 1
# Individual defensive box credit (steals, blocks, defensive rebounds) is kept at
# this weight; the rest of each team's defense is shared across its players.
# Backtest 2020-2026, team error: 1 -> 7.49, 0.75 -> 7.48, 0.5 -> 7.45,
# 0.25 -> 7.42 (best), 0 -> 7.69.
PW_DSHRINK <- 0.25
pw_pos_group <- function(pos) {
  p <- toupper(ifelse(is.na(pos), "", as.character(pos)))
  ifelse(grepl("^C", p), "C", ifelse(grepl("G", p), "G", ifelse(grepl("F", p), "F", "U")))
}

# Offense. Points are credited only above what a league-average shooter would
# score on the same attempts ("xpts" = points - league points per true shot
# attempt x attempts). Fitting points and attempts separately at the team level
# rewards volume regardless of efficiency, because every team uses about the same
# number of possessions: a team-level fit can't see that a missed shot uses a
# possession a teammate would have used. "tsa" (true shot attempts) keeps a
# fitted value for creating shots.
# Offensive rebounds count on offense and defensive rebounds on defense (total
# rebounds on the offensive side had been offsetting poor shooting).
PW_OFF_FEATS <- c("xpts", "tsa", "ast", "tov", "oreb")
pw_add_derived <- function(R, ctr) {
  cc <- ctr["pts"] / (ctr["fga"] + 0.44 * ctr["fta"])
  tsa <- R[, "fga"] + 0.44 * R[, "fta"]
  cbind(R, xpts = R[, "pts"] - cc * tsa, tsa = tsa)
}
# Personal fouls join the defensive side (w1.6): fouls hand the opponent free
# throws, and the box already records them for every player.
PW_DEF_FEATS <- c("stl", "blk", "dreb", "pf")

# per-100 rates for each player; pace = team possessions per 40 minutes
pw_rates <- function(ps, pace) {
  pc <- pace[ps$team_id]; pc[is.na(pc)] <- 70
  denom <- pmax(ps$min, 1) / 40 * pc
  out <- sapply(PW_STATS, function(s) 100 * ps[[s]] / denom)
  if (is.null(dim(out))) out <- matrix(out, nrow = 1, dimnames = list(NULL, PW_STATS))
  out
}

# team-level fit: rating deviation ~ team per-100 rates (season-centred)
pw_fit_value_model <- function(team_rows) {
  fO <- lm(reformulate(paste0("c_", PW_OFF_FEATS), "yO"), data = team_rows)
  fD <- lm(reformulate(paste0("c_", PW_DEF_FEATS), "yD"), data = team_rows)
  list(off = coef(fO), def = coef(fD), r2O = summary(fO)$r.squared, r2D = summary(fD)$r.squared,
       sdO = sd(resid(fO)), sdD = sd(resid(fD)))
}

# raw values from rates; `ctr` = season league-average team per-100 rates
pw_raw_values <- function(R, ctr, vm) {
  if (!"xpts" %in% colnames(R)) R <- pw_add_derived(R, ctr)
  cO <- vm$off; cD <- vm$def
  rO <- cO[1] / 5 + as.vector(sweep(R[, PW_OFF_FEATS, drop = FALSE], 2, ctr[PW_OFF_FEATS] / 5) %*% cO[-1])
  rD <- cD[1] / 5 + as.vector(sweep(R[, PW_DEF_FEATS, drop = FALSE], 2, ctr[PW_DEF_FEATS] / 5) %*% cD[-1])
  list(O = rO, D = rD)
}

# team-level aggregate rows for one season (for fitting the value model)
pw_team_rate_rows <- function(ps, rat, pace) {
  tm <- rowsum(as.matrix(ps[, c("min", PW_STATS)]), ps$team_id)
  tm <- tm[rownames(tm) %in% rat$team, , drop = FALSE]
  poss_tot <- tm[, "min"] / 200 * pace[rownames(tm)]
  R <- 100 * tm[, PW_STATS] / poss_tot
  ctr0 <- colMeans(R); R <- pw_add_derived(R, ctr0); ctr <- colMeans(R)
  r <- rat[match(rownames(tm), rat$team), ]
  out <- data.frame(team = rownames(tm), yO = r$O, yD = -r$D, stringsAsFactors = FALSE)
  for (s in colnames(R)) out[[paste0("c_", s)]] <- R[, s] - ctr[s]
  list(rows = out, ctr = ctr)
}

# player values for one season, constrained to the team ratings
pw_player_values <- function(ps, rat, pace, ctr, vm) {
  ps <- ps[ps$team_id %in% rat$team, ]
  R <- pw_rates(ps, pace)
  rv <- pw_raw_values(R, ctr, vm)
  tmin <- tapply(ps$min, ps$team_id, sum)
  ps$w <- 5 * ps$min / tmin[ps$team_id]
  ps$rawO <- rv$O; ps$rawD <- rv$D
  # individual defensive box credit is trusted only PW_DSHRINK as much: box stats
  # explain less than half of team defense, the rest is shared by the lineup
  if (PW_DSHRINK < 1) { wt <- pmin(ps$min, 1000); ps$rawD <- PW_DSHRINK * ps$rawD + (1 - PW_DSHRINK) * sum(wt * ps$rawD) / sum(wt) }
  if (PW_POS_ALPHA > 0 && !is.null(ps$pos)) {
    pg <- pw_pos_group(ps$pos); kn <- pg != "U"; wt <- pmin(ps$min, 1000)
    for (col in c("rawO", "rawD")) {
      allm <- sum((wt * ps[[col]])[kn]) / sum(wt[kn])
      gm <- tapply((wt * ps[[col]])[kn], pg[kn], sum) / tapply(wt[kn], pg[kn], sum)
      adj <- ifelse(kn, gm[pg] - allm, 0); adj[is.na(adj)] <- 0
      ps[[col]] <- ps[[col]] - PW_POS_ALPHA * adj
    }
  }
  sO <- tapply(ps$w * ps$rawO, ps$team_id, sum); sD <- tapply(ps$w * ps$rawD, ps$team_id, sum)
  r <- rat[match(names(sO), rat$team), ]
  adjO <- (r$O - sO) / 5; adjD <- (-r$D - sD) / 5
  names(adjO) <- names(sO); names(adjD) <- names(sD)
  ps$vO <- ps$rawO + adjO[ps$team_id]; ps$vD <- ps$rawD + adjD[ps$team_id]
  ps$v <- ps$vO + ps$vD
  ps$team_em <- rat$em[match(ps$team_id, rat$team)]
  ps$mpg <- ps$min / pmax(ps$gp, 1)
  ps
}


# =============================================================================
PW_MAX_MPG <- 36.5
# Part 2 -- player projection, minutes, team projection (fitted on history)
# =============================================================================
PW_REL_K <- 150   # minutes at which last season's value counts half

# Features for a target-season roster. `roster`: athlete_id, team_id (target team).
pw_player_features <- function(roster, T, H) {
  get <- function(yr) { x <- H[[as.character(yr)]]; if (is.null(x)) NULL else x$pv }
  p1 <- get(T - 1); p2 <- get(T - 2)
  r1 <- H[[as.character(T - 1)]]$rat
  f <- roster
  i1 <- if (is.null(p1)) rep(NA_integer_, nrow(f)) else match(f$athlete_id, p1$athlete_id)
  i2 <- if (is.null(p2)) rep(NA_integer_, nrow(f)) else match(f$athlete_id, p2$athlete_id)
  f$has1 <- !is.na(i1); f$has2 <- !is.na(i2)
  pick <- function(p, i, v, d = 0) { if (is.null(p)) return(rep(d, length(i))); x <- p[[v]][i]; x[is.na(x)] <- d; x }
  f$vO1 <- pick(p1, i1, "vO"); f$vD1 <- pick(p1, i1, "vD"); f$min1 <- pick(p1, i1, "min"); f$mpg1 <- pick(p1, i1, "mpg")
  f$gp1 <- pick(p1, i1, "gp")
  f$team1 <- if (is.null(p1)) NA else p1$team_id[i1]
  f$vO2 <- pick(p2, i2, "vO"); f$vD2 <- pick(p2, i2, "vD"); f$min2 <- pick(p2, i2, "min")
  f$team2 <- if (is.null(p2)) NA else p2$team_id[i2]
  # Sat out last season (injury, redshirt, sit-out transfer): her most recent
  # season becomes "last season", and `gap` lets the data decide how much of it
  # carries over -- fitted on every past player who missed a year and came back.
  p3 <- get(T - 3); i3 <- if (is.null(p3)) rep(NA_integer_, nrow(f)) else match(f$athlete_id, p3$athlete_id)
  f$gap <- as.numeric(!f$has1 & f$has2)
  g <- f$gap == 1
  if (any(g)) {
    f$vO1[g] <- f$vO2[g]; f$vD1[g] <- f$vD2[g]; f$min1[g] <- f$min2[g]; f$team1[g] <- f$team2[g]
    f$mpg1[g] <- pick(p2, i2, "mpg")[g]; f$gp1[g] <- pick(p2, i2, "gp")[g]
    f$vO2[g] <- pick(p3, i3, "vO")[g]; f$vD2[g] <- pick(p3, i3, "vD")[g]; f$min2[g] <- pick(p3, i3, "min")[g]
  }
  f$r1 <- f$min1 / (f$min1 + PW_REL_K); f$r2 <- f$min2 / (f$min2 + PW_REL_K)
  # last season's shooting efficiency relative to the league (true shooting %,
  # in points) and how much she shot, from whichever season is "last" for her
  src <- ifelse(g, 2, 1)
  eff_cols <- function(p, i) { if (is.null(p) || is.null(p$fga)) return(list(ts = rep(NA, length(i)), us = rep(NA, length(i))))
    tsa <- p$fga[i] + 0.44 * p$fta[i]; lg <- sum(p$pts, na.rm = TRUE) / (2 * sum(p$fga + 0.44 * p$fta, na.rm = TRUE))
    list(ts = 100 * (p$pts[i] / pmax(2 * tsa, 1) - lg), us = 40 * (tsa + p$tov[i]) / pmax(p$min[i], 1)) }
  e1 <- eff_cols(p1, i1); e2 <- eff_cols(p2, i2)
  f$ts1 <- ifelse(src == 2, e2$ts, e1$ts); f$us1 <- ifelse(src == 2, e2$us, e1$us)
  f$ts1[is.na(f$ts1)] <- 0; f$us1[is.na(f$us1)] <- 0
  f$ts1 <- pmax(pmin(f$ts1, 20), -20)
  seen <- f$has1 + f$has2
  for (k in 3:4) { pk <- get(T - k); if (!is.null(pk)) seen <- seen + f$athlete_id %in% pk$athlete_id }
  f$seen <- pmin(seen, 3)
  last_team <- ifelse(f$has1, f$team1, f$team2)
  f$transfer <- as.numeric((f$has1 | f$has2) & !is.na(last_team) & last_team != f$team_id)
  # program strength last season (per player share: /5). Teams without a D1
  # rating last season (new to D1) get the 10th-percentile program.
  low <- stats::quantile(r1$O, .1); lowD <- stats::quantile(r1$D, .9)
  tO <- r1$O[match(f$team_id, r1$team)]; tD <- r1$D[match(f$team_id, r1$team)]
  f$tO <- ifelse(is.na(tO), low, tO) / 5; f$tD <- -ifelse(is.na(tD), lowD, tD) / 5
  oO <- r1$O[match(last_team, r1$team)]; oD <- r1$D[match(last_team, r1$team)]
  f$oO <- ifelse(is.na(oO), f$tO * 5, oO) / 5; f$oD <- -ifelse(is.na(oD), -f$tD * 5, oD) / 5
  f$newc <- as.numeric(!(f$has1 | f$has2))
  # tempo of the team she last played for (her own team's if she's new): feeds
  # the tempo projection, so a roster rebuilt from fast teams projects faster
  tT <- r1$T[match(f$team_id, r1$team)]; oT <- r1$T[match(last_team, r1$team)]
  f$oT <- ifelse(is.na(oT), ifelse(is.na(tT), 0, tT), oT)
  f
}

# The hinge terms let the data decide whether the very best players regress
# more than a straight line implies (i.e. whether star values should be shrunk).
PW_FORM_O <-  vO ~ I(vO1 * r1) + I(vO2 * r2) + r1 + I(seen == 2) + I(seen >= 3) + transfer + tO + I(transfer * oO) + I(transfer * vO1 * r1) +
  gap + I(gap * vO1 * r1) + I(pmax(vO1 * r1 - 8, 0))
PW_FORM_D <- vD ~ I(vD1 * r1) + I(vD2 * r2) + r1 + I(seen == 2) + I(seen >= 3) + transfer + tD + I(transfer * oD) + I(transfer * vD1 * r1) +
  gap + I(gap * vD1 * r1) + I(pmax(vD1 * r1 - 6, 0))
# (w1.6 tested, not adopted) a separate carry-forward slope after a player's
# first D1 season: paired bootstrap change in team error +0.004 (95% CI -0.027 to
# +0.033), so the seen-count dummies stay as the development terms.

# training rows: every rostered player in season T with her T-1 / T-2 history.
# rosters = TRUE (w1.6) uses every player the box scores list, including players
# who never got on the floor (redshirts, season-long injuries) -- the same kind
# of roster the prep sheet hands production. rosters = FALSE is the old
# "players who took the floor" version, kept as the oracle comparison.
pw_transition_rows <- function(H, seasons, rosters = TRUE) {
  do.call(rbind, lapply(seasons, function(T) {
    hs <- H[[as.character(T)]]; pv <- hs$pv
    ro <- if (rosters && !is.null(hs$roster)) hs$roster[, c("athlete_id", "team_id")] else pv[, c("athlete_id", "team_id")]
    ro <- ro[ro$team_id %in% hs$rat$team & ro$team_id %in% pv$team_id, ]
    f <- pw_player_features(ro, T, H)
    i <- match(f$athlete_id, pv$athlete_id)
    f$vO <- pv$vO[i]; f$vD <- pv$vD[i]; f$min <- na0(pv$min[i]); f$season <- T
    f$name <- if (!is.null(hs$roster$name)) hs$roster$name[match(f$athlete_id, hs$roster$athlete_id)] else pv$name[i]
    f$name[is.na(f$name)] <- pv$name[i][is.na(f$name)]
    tg <- tapply(pv$gp, pv$team_id, max); f$m <- f$min / tg[f$team_id]; f$gpf <- na0(pv$gp[i]) / tg[f$team_id]
    f
  }))
}

pw_fit_player_models <- function(tr) {
  tr$wt <- pmin(tr$min, 800)
  ret <- tr[tr$newc == 0 & tr$min >= 40, ]; nw <- tr[tr$newc == 1 & tr$min >= 40, ]
  list(O = lm(PW_FORM_O, data = ret, weights = wt),
       D = lm(PW_FORM_D, data = ret, weights = wt),
       nO = lm(vO ~ tO, data = nw, weights = wt),
       nD = lm(vD ~ tD, data = nw, weights = wt))
}

# predict that treats a coefficient the training data couldn't identify as 0
pw_pred <- function(fit, newdata) {
  tt <- if (inherits(fit, "pwslim")) fit$terms else delete.response(terms(fit))
  b <- if (inherits(fit, "pwslim")) fit$coefficients else coef(fit)
  X <- model.matrix(tt, model.frame(tt, newdata, na.action = na.pass))
  b[is.na(b)] <- 0; as.vector(X %*% b[colnames(X)])
}
pw_predict_players <- function(f, pm) {
  f$pvO <- ifelse(f$newc == 1, pw_pred(pm$nO, f), pw_pred(pm$O, f))
  f$pvD <- ifelse(f$newc == 1, pw_pred(pm$nD, f), pw_pred(pm$D, f))
  f$pv <- f$pvO + f$pvD
  f
}

# Minutes, in two stages, fitted on every past team (walk-forward in the backtest):
#   1. a pecking order: who is likely to play most (value, last season's role)
#   2. minutes for each slot in that order from what the Nth player on a real
#      D1 roster averages, adjusted by the player's own track record -- including
#      how big a role she had and at how strong a program. Transfers from strong
#      programs historically earn more than a flat rule gives them.
# Allocating by pecking-order slot keeps full 15-player rosters (walk-ons,
# redshirts, recruits) from diluting the starters' minutes.
PW_MIN_ALPHA <- 0.5
PW_MIN_FORM2 <- m ~ tm + pv + I(mpg1 * (1 - transfer) * has1) + I(mpg1 * transfer) + I(mpg1 * transfer * (oO + oD)) +
  I(transfer * (oO + oD)) + I(mpg1 * gap) + newc + transfer
pw_fit_minutes <- function(tr) {
  s1 <- lm(m ~ pv + I(pmax(pv, 0)) + I(mpg1 * (1 - transfer)) + I(mpg1 * transfer) + has1 + newc + r1 + gap, data = tr)
  tr$claim <- pw_pred(s1, tr)
  tr$prk <- ave(-tr$claim, paste(tr$season, tr$team_id), FUN = function(z) rank(z, ties.method = "first"))
  tmpl <- tapply(tr$m, pmin(tr$prk, 15), mean); tr$tm <- tmpl[pmin(tr$prk, 15)]
  s2 <- lm(PW_MIN_FORM2, data = tr)
  avail <- if (!is.null(tr$gpf)) tapply(tr$gpf, pmin(tr$prk, 15), mean, na.rm = TRUE) else rep(0.85, 15)
  list(s1 = s1, tmpl = as.vector(tmpl), s2 = s2, avail = as.vector(avail))
}
pw_alloc_minutes <- function(f, mm, total = 200, k = 1) {
  claim <- pw_pred(mm$s1, f)
  # unlisted roster spots are placeholders, not players: always last in line (w1.6)
  if (!is.null(f$source)) claim[f$source %in% "pad"] <- min(claim, na.rm = TRUE) - 100
  f$prk <- ave(-claim, f$team_id, FUN = function(z) rank(z, ties.method = "first"))
  f$tm <- mm$tmpl[pmin(f$prk, length(mm$tmpl))]
  raw <- pw_pred(mm$s2, f)
  # recruits: blend toward their calibrated rank-and-program estimate
  if (!is.null(f$m_override)) { w <- ifelse(is.na(f$m_override), 0, f$m_w); raw <- (1 - w) * raw + w * ifelse(is.na(f$m_override), 0, f$m_override) }
  raw <- pmin(pmax(raw, 0.3), 36)
  # a placeholder never out-claims a real player on the same roster (w1.6)
  if (!is.null(f$source) && any(f$source %in% "pad")) {
    isp <- f$source %in% "pad"
    lo <- tapply(ifelse(isp, NA, raw), f$team_id, function(z) if (all(is.na(z))) Inf else min(z, na.rm = TRUE))
    raw[isp] <- pmin(raw[isp], lo[f$team_id[isp]])
  }
  f$avail <- mm$avail[pmin(f$prk, length(mm$avail))]
  # Fit every team to 200 minutes. When a roster has more claims than minutes
  # (or fewer), the top five absorb PW_MIN_ALPHA as much of the change as the
  # bench -- coaches trim the bench first. 0.5 fitted best on 2020-2026.
  e <- ifelse(f$prk <= 5, PW_MIN_ALPHA, 1); m <- raw
  for (t in unique(f$team_id)) {
    k <- f$team_id == t
    g <- function(ls) sum(raw[k] * exp(ls * e[k])) - total
    ls <- tryCatch(stats::uniroot(g, c(-6, 6))$root, error = function(err) log(total / sum(raw[k])))
    m[k] <- raw[k] * exp(ls * e[k])
  }
  # after scaling, still no placeholder above a real player: excess goes to the real players
  if (!is.null(f$source) && any(f$source %in% "pad")) {
    isp <- f$source %in% "pad"
    for (t in unique(f$team_id[isp])) for (it in 1:5) {
      k <- f$team_id == t; kr <- k & !isp; kp <- k & isp
      if (!any(kr)) break
      lo <- min(m[kr]); ex <- sum(pmax(m[kp] - lo, 0)); if (ex < 1e-6) break
      m[kp] <- pmin(m[kp], lo); m[kr] <- m[kr] + ex * m[kr] / sum(m[kr])
    }
  }
  # never more than 38 a game; hand the excess to the rest of the rotation
  for (it in 1:3) { over <- pmax(m - PW_MAX_MPG, 0); if (!any(over > 0)) break
    ex <- tapply(over, f$team_id, sum); m <- pmin(m, PW_MAX_MPG)
    room <- ifelse(m < PW_MAX_MPG, m, 0); rs <- tapply(room, f$team_id, sum)
    add <- ifelse(rs[f$team_id] > 0, room / rs[f$team_id] * ex[f$team_id], 0)
    m <- m + add }
  f$pm <- m; f$w <- 5 * m / total
  f
}

pw_team_roster_sums <- function(f) {
  data.frame(team = names(tapply(f$w, f$team_id, sum)),
             rO = as.vector(tapply(f$w * f$pvO, f$team_id, sum)),
             rD = as.vector(tapply(f$w * f$pvD, f$team_id, sum)),
             retmin = as.vector(tapply(f$w * (1 - f$newc) * (1 - f$transfer), f$team_id, sum)) / 5,
             trmin = as.vector(tapply(f$w * f$transfer, f$team_id, sum)) / 5,
             trorig = as.vector(tapply(f$w * f$transfer * (f$oO + f$oD), f$team_id, sum)),
             trT = as.vector(tapply(f$w * f$transfer * f$oT, f$team_id, sum)) / 5,
             padsh = if (is.null(f$source)) 0 else as.vector(tapply(f$w * (f$source %in% "pad"), f$team_id, sum)) / 5,
             stringsAsFactors = FALSE)
}

# team-level frame for target season T (roster sums + program history)
pw_team_frame <- function(rs, T, H) {
  r1 <- H[[as.character(T - 1)]]$rat; r2 <- H[[as.character(T - 2)]]$rat
  lowO <- stats::quantile(r1$O, .1); lowD <- stats::quantile(r1$D, .9)
  rs$O1 <- r1$O[match(rs$team, r1$team)]; rs$D1 <- r1$D[match(rs$team, r1$team)]
  rs$T1 <- r1$T[match(rs$team, r1$team)]
  rs$new_d1 <- as.numeric(is.na(rs$O1))
  rs$O1[is.na(rs$O1)] <- lowO; rs$D1[is.na(rs$D1)] <- lowD; rs$T1[is.na(rs$T1)] <- 0
  rs$O2 <- if (is.null(r2)) rs$O1 else r2$O[match(rs$team, r2$team)]
  rs$D2 <- if (is.null(r2)) rs$D1 else r2$D[match(rs$team, r2$team)]
  rs$O2[is.na(rs$O2)] <- rs$O1[is.na(rs$O2)]; rs$D2[is.na(rs$D2)] <- rs$D1[is.na(rs$D2)]
  rs
}
# trorig: how strong the programs a team's transfers came from were (weighted by
# their projected minutes). A roster rebuilt from high-major transfers has
# outperformed one rebuilt from mid-majors with the same box-score values.
# (Scaling program history by roster continuity was also tested; it didn't help.)
# w1.11: written as last season plus roster CHANGE. The old form (rO + O1 + O2 + both
# x retmin) put near-duplicate columns side by side (roster defense vs last
# season's defense correlate 0.98), so coefficients came out as offsetting pairs
# (1.43 and -0.44) that meant nothing on their own. This form is as accurate or
# slightly better in the walk-forward backtest (7.616 vs 7.625 RMSE, 5 of 7
# seasons better) and each coefficient reads directly: I(rO - O1) is how much a
# change in roster value moves the team, O1 how much of last season carries over.
PW_TEAM_FORM_O <- yO ~ O1 + I(rO - O1) + O2 + I((O1 - O2) * retmin) + trorig
PW_TEAM_FORM_D <- yD ~ D1 + I(rD - D1) + D2 + I((D1 - D2) * retmin) + trorig
# the weight on roster value (used to price an injured player's minutes)
pw_roster_weight <- function(cf, side) {
  v <- if (side == "O") cf[c("I(rO - O1)", "rO")] else cf[c("I(rD - D1)", "rD")]
  v <- v[!is.na(v)]; if (length(v)) unname(v[1]) else 1 }
# (w1.6) tempo: last season's pace, how much of it walks back in the door, and
# the pace of the teams the transfers came from.
PW_TEAM_FORM_T <- yT ~ T1 + I(T1 * retmin) + trT
# A new head coach enters every team equation when coaching history is supplied
# (PW_COACH_HISTORY); without it the model can't estimate the effect.
pw_team_forms <- function(with_coach = FALSE) {
  if (!with_coach) return(list(O = PW_TEAM_FORM_O, D = PW_TEAM_FORM_D, T = PW_TEAM_FORM_T))
  list(O = update(PW_TEAM_FORM_O, . ~ . + nc + I(nc * O1)), D = update(PW_TEAM_FORM_D, . ~ . + nc + I(nc * D1)),
       T = update(PW_TEAM_FORM_T, . ~ . + nc + I(nc * T1)))
}


# =============================================================================
# Part 3 -- the 2026-27 roster (prep sheet), newcomer calibration, projection
# =============================================================================
pw_norm_name <- function(x) {
  x <- iconv(as.character(x), to = "ASCII//TRANSLIT", sub = "")
  x <- tolower(x); x <- gsub("[^a-z ]", "", x)
  x <- gsub("\\b(jr|sr|ii|iii|iv)\\b", "", x)
  gsub("\\s+", "", x)
}
pw_id <- function(x) { x <- suppressWarnings(as.numeric(x)); ifelse(is.na(x), NA_character_, sprintf("%.0f", x)) }
# Stable synthetic ids (w1.9). Rows without an ESPN id used to be numbered by
# their position in the sheet ("fr_12", "rec_5"), so re-sorting or inserting a
# row renumbered everyone after it and silently broke anything keyed to them
# (overrides, injuries, the player crosswalk, the snapshot). These are built from
# the player's normalised name and team instead, so they survive edits.
pw_stable_id <- function(prefix, name, team_id) {
  nm <- pw_norm_name(name); nm[is.na(nm) | !nzchar(nm)] <- "unknown"
  tm <- as.character(team_id); tm[is.na(tm) | !nzchar(tm)] <- "na"
  make.unique(paste0(prefix, "_", tm, "_", nm), sep = "_")
}
# Optional hand-kept player crosswalk (w1.9): pid (a stable id from
# wbb_<season>_roster_ids.csv, or an ESPN id), espn_id (the ESPN athlete id to
# link it to), aliases ("Madi|Madison"), note. Used to link a sheet row to its
# box-score history before the season and to its box scores during it.
pw_read_xwalk <- function() {
  x <- pw_read_opt_csv(PW_XWALK_FILE)
  if (is.null(x)) return(data.frame(pid = character(0), espn_id = character(0), aliases = character(0), note = character(0), stringsAsFactors = FALSE))
  for (v in c("pid", "espn_id", "aliases", "note")) if (is.null(x[[v]])) x[[v]] <- NA_character_
  x$pid <- trimws(x$pid); x$espn_id <- sub("\\.0+$", "", trimws(x$espn_id))
  x$espn_id[!nzchar(x$espn_id) %in% TRUE] <- NA
  x <- x[!is.na(x$pid) & nzchar(x$pid), c("pid", "espn_id", "aliases", "note")]
  x[!duplicated(x$pid), ]
}

pw_read_prep <- function(path) {
  if (!file.exists(path)) stop("prep sheet not found: ", path)
  sh <- readxl::excel_sheets(path)
  rd <- function(s, ...) as.data.frame(suppressWarnings(suppressMessages(readxl::read_excel(path, sheet = s, ...))), stringsAsFactors = FALSE)
  s_stats <- sh[grepl("^ncaaw_player_season_stats_2025", sh)][1]
  s_fresh <- sh[grepl("^freshmen", sh, ignore.case = TRUE)][1]
  stats <- rd(s_stats); fresh <- rd(s_fresh)
  rec <- list()
  for (s in sh[grepl("recruits", sh, ignore.case = TRUE)]) {
    x <- rd(s); yr <- as.integer(substr(s, 1, 4))
    rec[[s]] <- data.frame(year = yr, rank = pw_num(x$RK), name = x$NAME, college = x$COLLEGE,
                           pos = x$POS, stringsAsFactors = FALSE)
  }
  rec <- do.call(rbind, rec); rec <- rec[!is.na(rec$rank) & !is.na(rec$name), ]
  fiba <- list()
  for (s in sh[grepl("eurobasket|americup|afrobasket", sh, ignore.case = TRUE)]) {
    x <- rd(s, col_names = FALSE); x <- x[-1, , drop = FALSE]
    if (ncol(x) < 20 || !nrow(x)) next
    fiba[[s]] <- data.frame(event = s, year = as.integer(substr(s, 1, 4)), country = x[[1]], name = x[[3]],
                            gp = pw_num(x[[4]]), min = pw_num(x[[5]]), eff = pw_num(x[[19]]), pts = pw_num(x[[20]]),
                            u20 = as.numeric(grepl("U20", s, ignore.case = TRUE)),
                            div_b = as.numeric(grepl("\\bB$", trimws(s))), stringsAsFactors = FALSE)
  }
  fiba <- do.call(rbind, fiba)
  fiba <- fiba[!is.na(fiba$name) & !is.na(fiba$min) & fiba$min > 0, ]
  fiba$key <- pw_norm_name(fiba$name)
  off <- pw_fiba_offsets(fiba)
  fiba$level <- pw_fiba_level(fiba$event)
  fiba$adj <- unname(off$level[fiba$level]); fiba$adj[is.na(fiba$adj)] <- 0
  list(stats = stats, fresh = fresh, rec = rec, fiba = fiba, fiba_off = off)
}

# ---- FIBA competition strength -------------------------------------------------
# The same EFF/40 means different things at different levels: B divisions
# inflate it, U20 deflates it. Measured from players who appear in more than one
# event (same player, different competition): a fixed-effects fit of EFF/40 on
# player + event, each event compared with that summer's U18 Division A (so a
# year of growth isn't mistaken for difficulty), pooled by level. Levels that
# never share players with the Eurobasket events (Americup, Afrobasket) or that
# aren't in the sheet (Division C) fall back to the stated assumptions below.
PW_FIBA_DEFAULT <- c("U18 A" = 0, "U18 B" = 3.3, "U18 C" = 5, "U20 A" = -3.4, "U20 B" = 1.3, "U20 C" = 3,
                     "Americup" = 0, "Afrobasket" = 3.3)
pw_fiba_level <- function(ev) {
  e <- toupper(trimws(ev))
  ifelse(grepl("AFRO", e), "Afrobasket", ifelse(grepl("AMERICUP", e), "Americup",
    paste0(ifelse(grepl("U20", e), "U20", "U18"), " ", ifelse(grepl("\\bC$", e), "C", ifelse(grepl("\\bB$", e), "B", "A")))))
}
pw_fiba_offsets <- function(fiba) {
  lev <- PW_FIBA_DEFAULT; src <- setNames(rep("assumed", length(lev)), names(lev)); nlev <- setNames(rep(0, length(lev)), names(lev))
  fb <- fiba; fb$tm <- fb$min * fb$gp; fb <- fb[fb$tm >= 30, ]; fb$eff40 <- 40 * fb$eff / fb$min
  m <- fb[fb$key %in% fb$key[duplicated(fb$key)], ]
  if (nrow(m) >= 50 && length(unique(m$event)) >= 3) {
    m$event <- factor(m$event)
    fit <- lm(eff40 ~ 0 + factor(key) + event, m, weights = pmin(m$tm, 250))
    cf <- coef(fit); fe <- setNames(rep(0, nlevels(m$event)), levels(m$event))
    for (e in levels(m$event)[-1]) { v <- cf[paste0("event", e)]; fe[e] <- if (is.na(v)) NA else v }
    ev <- names(fe); yr <- substr(ev, 1, 4); lv <- pw_fiba_level(ev)
    ref <- sapply(seq_along(ev), function(i) { r <- fe[yr == yr[i] & lv == "U18 A"]; if (length(r)) r[1] else NA })
    rel <- fe - ref; np <- as.vector(table(m$event)[ev])
    for (l in setdiff(unique(lv), "U18 A")) {
      k <- which(lv == l & !is.na(rel))
      if (length(k) && sum(np[k]) >= 30) { lev[l] <- sum(rel[k] * np[k]) / sum(np[k]); src[l] <- "measured"; nlev[l] <- sum(np[k]) }
    }
    src["U18 A"] <- "baseline"
  }
  list(level = lev, source = src, n = nlev, n_multi = length(unique(m$key)))
}

# FIBA summary per player for events in `years`: minute-weighted EFF per 40
pw_fiba_summary <- function(fiba, years) {
  f <- fiba[fiba$year %in% years, ]
  if (!nrow(f)) return(NULL)
  tm <- f$min * f$gp
  adj <- if (is.null(f$adj)) 0 else f$adj
  agg <- data.frame(key = f$key, tm = tm, e = f$eff * f$gp, p = f$pts * f$gp, u20 = f$u20 * tm, b = f$div_b * tm, aj = adj * tm)
  a <- rowsum(as.matrix(agg[, -1]), agg$key)
  data.frame(key = rownames(a), fmin = a[, "tm"], eff40 = 40 * a[, "e"] / a[, "tm"] - a[, "aj"] / a[, "tm"],
             eff40_raw = 40 * a[, "e"] / a[, "tm"], pts40 = 40 * a[, "p"] / a[, "tm"],
             u20 = a[, "u20"] / a[, "tm"], divb = a[, "b"] / a[, "tm"],
             events = as.vector(table(f$key)[rownames(a)]), stringsAsFactors = FALSE)
}

# ---- newcomer calibration on the 2025-26 season --------------------------------
# Residuals of 2025-26 newcomers against the generic newcomer model, explained by
# recruit rank (2025 class) or FIBA youth production (summer 2025 events).
pw_calibrate_newcomers <- function(H, pm, prep) {
  yrs <- as.integer(names(H)); Tl <- max(yrs)
  # recruiting classes: the prep sheet's, plus PW_RECRUIT_HISTORY when supplied
  # (w1.6) -- each season whose freshman class is known joins the rank fit
  rh <- pw_read_recruit_history()
  rc_all <- rbind(data.frame(year = prep$rec$year, rank = prep$rec$rank, key = pw_norm_name(prep$rec$name), stringsAsFactors = FALSE),
                  if (is.null(rh)) NULL else rh[, c("year", "rank", "key")])
  rc_all <- rc_all[!duplicated(paste(rc_all$year, rc_all$key)), ]
  Ts <- yrs[yrs >= min(yrs) + 2 & (yrs - 1) %in% rc_all$year]
  if (!Tl %in% Ts) Ts <- c(Ts, Tl)
  one <- function(T) {
    pv <- H[[as.character(T)]]$pv
    f <- pw_player_features(pv[, c("athlete_id", "team_id")], T, H)
    f <- pw_predict_players(f, pm)
    f$vO <- pv$vO; f$vD <- pv$vD; f$min <- pv$min; f$key <- pw_norm_name(pv$name); f$season <- T
    nw <- f[f$newc == 1 & f$min >= 40, ]
    nw$rO <- nw$vO - nw$pvO; nw$rD <- nw$vD - nw$pvD
    rc <- rc_all[rc_all$year == T - 1, ]
    nw$rank <- rc$rank[match(nw$key, rc$key)]
    tg <- tapply(pv$gp, pv$team_id, max); nw$m <- nw$min / tg[nw$team_id]
    rp <- H[[as.character(T - 1)]]$rat; nw$prog <- rp$em[match(nw$team_id, rp$team)]; nw$prog[is.na(nw$prog)] <- 0
    nw$name <- pv$name[match(nw$athlete_id, pv$athlete_id)]
    nw
  }
  NW <- do.call(rbind, lapply(Ts, one))
  rk <- NW[!is.na(NW$rank), ]
  fr <- lm(cbind(rO, rD) ~ log(rank), data = rk, weights = pmin(rk$min, 800))
  unr <- NW[is.na(NW$rank), ]
  off_unr <- c(O = weighted.mean(unr$rO, pmin(unr$min, 800)), D = weighted.mean(unr$rD, pmin(unr$min, 800)))
  # replacement level for an unlisted roster spot: a lower-quartile unranked newcomer (w1.6)
  repl <- c(O = unname(stats::quantile(unr$rO, .25)), D = unname(stats::quantile(unr$rD, .25)))
  unl <- unr[unr$season == Tl, ]
  fs <- pw_fiba_summary(prep$fiba, Tl - 1)
  fb <- merge(unl, fs, by = "key")
  fb <- fb[fb$fmin >= 60, ]
  ff <- if (nrow(fb) >= 12) lm(cbind(rO, rD) ~ eff40, data = fb, weights = pmin(fb$min, 800)) else NULL
  fiba_fit_check <- if (nrow(fb) >= 12) {
    r2 <- function(x) { v <- fb$rO + fb$rD; summary(lm(v ~ x, weights = pmin(fb$min, 800)))$r.squared }
    c(level_adjusted = r2(fb$eff40), raw = r2(fb$eff40_raw))
  } else NULL
  # minutes: how much ranked freshmen actually played, by rank (per team game)
  mfit <- coef(lm(m ~ log(rank) + prog, data = rk))       # top programs give freshmen fewer minutes
  list(rank_min_fit = mfit, rank_fit = coef(fr), n_rank = nrow(rk), n_classes = length(unique(rk$season)),
       off_unranked = off_unr, replacement = repl, n_unranked = nrow(unr),
       fiba_fit = if (is.null(ff)) NULL else coef(ff), n_fiba = nrow(fb), fiba_r2 = fiba_fit_check,
       fiba_resid_mean = if (nrow(fb)) c(O = mean(fb$rO), D = mean(fb$rD)) else c(O = 0, D = 0),
       rank_table = data.frame(rank = rk$rank, name = rk$name, v = rk$vO + rk$vD, min = rk$min, stringsAsFactors = FALSE))
}

pw_rank_bump <- function(cal, rank) {
  b <- cal$rank_fit
  cbind(O = b[1, "rO"] + b[2, "rO"] * log(rank), D = b[1, "rD"] + b[2, "rD"] * log(rank))
}
pw_fiba_bump <- function(cal, eff40) {
  if (is.null(cal$fiba_fit)) return(cbind(O = cal$fiba_resid_mean["O"] + 0 * eff40, D = cal$fiba_resid_mean["D"] + 0 * eff40))
  b <- cal$fiba_fit
  cbind(O = b[1, "rO"] + b[2, "rO"] * eff40, D = b[1, "rD"] + b[2, "rD"] * eff40)
}

# ---- 2026-27 roster from the prep sheet --------------------------------------
pw_build_roster <- function(prep, teams, H) {
  T0 <- max(as.integer(names(H)))
  st <- prep$stats
  tid <- setNames(teams$espn_id, teams$team)
  st$athlete_id <- pw_id(st$athlete_id)
  miss_id <- is.na(st$athlete_id)
  st$athlete_id[miss_id] <- pw_stable_id("noid", st$athlete_display_name[miss_id], unname(tid[as.character(st$`2027 Team`[miss_id])]))
  st <- st[!duplicated(st$athlete_id), ]
  r1 <- st[st$`2027 Team` %in% teams$team, ]
  ro <- data.frame(athlete_id = r1$athlete_id, team_id = unname(tid[r1$`2027 Team`]), team = r1$`2027 Team`,
                   name = r1$athlete_display_name, prev_team = r1$`2026 Team`, exp_years = pw_num(r1$`Experience Years`),
                   height = as.character(r1$Height), cls = NA_character_, pos = NA_character_, source = "stats",
                   stringsAsFactors = FALSE)
  ro$pid <- ro$athlete_id                               # w1.9: the identity that never changes for this run's rows
  # last-season lines for display
  ro$ly_gp <- pw_num(r1$games_played); ro$ly_mpg <- pw_num(r1$mpg); ro$ly_ppg <- pw_num(r1$ppg)
  ro$ly_rpg <- pw_num(r1$rpg); ro$ly_apg <- pw_num(r1$apg); ro$ly_min <- pw_num(r1$total_minutes); ro$ly_pts <- pw_num(r1$total_pts)
  # newcomers without prior college stats
  fr <- prep$fresh
  fr <- fr[!is.na(fr$Team) & fr$Team %in% teams$team & !is.na(fr$Name), ]
  key_st <- paste(pw_norm_name(ro$name), ro$team)
  fr <- fr[!paste(pw_norm_name(fr$Name), fr$Team) %in% key_st, ]
  fr <- fr[!duplicated(paste(pw_norm_name(fr$Name), fr$Team)), ]
  # The same player sometimes appears twice: in the stats tab, and in the
  # Freshmen tab under a nickname or another spelling ("Madi"/"Madison" Morson,
  # "Kace"/"Kacelyn" Urlacher). A Freshmen-tab row on the same team, with the same
  # last name, a first name sharing its first three letters, and a class other than
  # freshman is treated as that player. Freshmen with a shared last name (twins,
  # sisters) are kept.
  if (nrow(fr) && nrow(ro)) {
    ln <- function(x) pw_last_name(x); f3 <- function(x) substr(pw_norm_name(sub("\\s.*", "", x)), 1, 3)
    is_fr <- grepl("^(fr|1st|freshman|first)", tolower(trimws(as.character(fr$Class))))
    dup <- vapply(seq_len(nrow(fr)), function(k) {
      if (is_fr[k]) return(FALSE)
      any(ro$team == fr$Team[k] & ln(ro$name) == ln(fr$Name[k]) & f3(ro$name) == f3(fr$Name[k]))
    }, logical(1))
    dropped_dups <- paste0(fr$Name[dup], " (", fr$Team[dup], ")")
    fr <- fr[!dup, ]
  } else dropped_dups <- character(0)
  if (nrow(fr)) {
    ro2 <- data.frame(athlete_id = pw_stable_id("fr", fr$Name, unname(tid[fr$Team])), team_id = unname(tid[fr$Team]), team = fr$Team,
                      name = fr$Name, prev_team = fr$`Previous School/Team`, exp_years = 0,
                      height = as.character(fr$Height), cls = as.character(fr$Class), pos = as.character(fr$Position),
                      source = "newcomer", ly_gp = NA, ly_mpg = NA, ly_ppg = NA, ly_rpg = NA, ly_apg = NA,
                      ly_min = NA, ly_pts = NA, stringsAsFactors = FALSE)
    ro2$pid <- ro2$athlete_id
    ro <- rbind(ro, ro2[, names(ro)])
  }
  # Identity: link every player to her box-score history. IDs first; when the
  # sheet's ID is missing or doesn't match, fall back to name + school (either
  # last season's school or the 2026-27 one), then to a name that's unique in
  # the recent box scores. Newcomer-tab entries with D1 history become returners
  # or transfers instead of blank-slate newcomers.
  allpv <- do.call(rbind, lapply(rev(names(H)), function(y) H[[y]]$pv[, c("athlete_id", "name", "team_id")]))
  allpv$key <- pw_norm_name(allpv$name)
  allpv <- allpv[!duplicated(paste(allpv$athlete_id, allpv$team_id)), ]
  tid_all <- setNames(teams$espn_id, teams$team)
  ro$matched <- "id"
  # w1.9: hand-kept links first (wbb_player_xwalk.csv), so a known nickname or a
  # wrong sheet id is fixed once and stays fixed
  xw <- pw_read_xwalk()
  kx <- match(ro$pid, xw$pid); hx <- !is.na(kx) & !is.na(xw$espn_id[kx])
  if (any(hx)) {
    ro$athlete_id[hx] <- xw$espn_id[kx[hx]]; ro$matched[hx] <- "xwalk"
    ro$source[hx & ro$source == "newcomer" & ro$athlete_id %in% allpv$athlete_id] <- "history"
  }
  ro$aliases <- xw$aliases[kx]
  for (k in which(!ro$athlete_id %in% allpv$athlete_id & ro$matched != "xwalk")) {
    cand <- allpv[allpv$key == pw_norm_name(ro$name[k]), ]
    ro$matched[k] <- "none"
    if (!nrow(cand)) next
    pt <- unname(tid_all[as.character(ro$prev_team[k])])
    c2 <- if (!is.na(pt)) cand[cand$team_id == pt, ] else cand[0, ]
    if (!nrow(c2)) c2 <- cand[cand$team_id == ro$team_id[k], ]
    # a name alone is only trusted for rows from the stats sheet; a Freshmen-tab
    # newcomer sharing a name with a past D1 player must also share a school
    if (!nrow(c2) && ro$source[k] == "stats" && length(unique(cand$athlete_id)) == 1) c2 <- cand
    if (nrow(c2)) {
      ro$athlete_id[k] <- c2$athlete_id[1]; ro$matched[k] <- "name"
      if (ro$source[k] == "newcomer") ro$source[k] <- "history"
    }
  }
  ro <- ro[order(ro$source != "stats"), ]; ro <- ro[!duplicated(ro$athlete_id), ]
  # thin or missing rosters (the sheet lists fewer than PW_MIN_ROSTER players):
  # pad with unlisted roster spots valued as an unranked newcomer, so the
  # program still gets a projection instead of a 5-player team playing 40 a night
  # w1.6: an override with an athlete_id and action "exclude" drops that exact
  # prep-sheet row -- for two players sharing a name, where a name can't tell
  # them apart (e.g. a recruit's school assigned to another player's stats row)
  ov <- pw_read_overrides()
  xid <- ov$athlete_id[tolower(ov$action) == "exclude" & !is.na(ov$athlete_id)]
  if (length(xid)) ro <- ro[!ro$athlete_id %in% xid, ]
  cnt <- table(factor(ro$team, levels = teams$team))
  need <- pmax(PW_MIN_ROSTER - as.integer(cnt), 0)
  if (any(need > 0)) {
    tt <- rep(names(cnt), need)
    pad <- ro[rep(NA_integer_, length(tt)), ]
    pad$athlete_id <- paste0("pad_", unname(tid[tt]), "_", ave(seq_along(tt), tt, FUN = seq_along)); pad$team <- tt; pad$team_id <- unname(tid[tt])
    pad$pid <- pad$athlete_id; pad$matched <- "pad"
    pad$name <- "Unlisted roster spot"; pad$source <- "pad"; pad$exp_years <- 0
    ro <- rbind(ro, pad)
  }
  ro$key <- pw_norm_name(ro$name)
  ro$rec_key <- ifelse(ro$source == "newcomer", ro$key, NA)
  ro <- pw_attach_recruits(ro, prep, teams, H)
  ro <- pw_attach_prior_class(ro, prep, teams, H)
  attr(ro, "dropped_dups") <- dropped_dups
  ro
}

pw_last_name <- function(x) {
  w <- strsplit(tolower(iconv(x, to = "ASCII//TRANSLIT", sub = "")), "\\s+")
  vapply(w, function(z) gsub("[^a-z]", "", z[length(z)]), "")
}

# Last year's top-100 class. Their pedigree still says something when college
# hasn't: a recruit who redshirted or was hurt (Leah Macy) or barely played
# (Emilee Skinner) keeps her recruit-rank prior, fading as college minutes pile
# up. A recruit with no 2025-26 minutes never reaches the prep sheet's stats tab,
# so if she's on no roster at all she's restored to her school (Data checks).
PW_OVERRIDES_FILE <- "wbb_2027_roster_overrides.csv"   # optional: name, team, action (keep/exclude), note
pw_read_overrides <- function() {
  f <- file.path(OUT_DIR, PW_OVERRIDES_FILE)
  if (!file.exists(f)) return(data.frame(name = character(0), team = character(0), action = character(0), note = character(0)))
  o <- utils::read.csv(f, stringsAsFactors = FALSE, encoding = "UTF-8", colClasses = "character")
  if (is.null(o$athlete_id)) o$athlete_id <- NA_character_
  o$athlete_id <- sub("\\.0+$", "", trimws(o$athlete_id)); o$athlete_id[!nzchar(o$athlete_id) %in% TRUE] <- NA
  # a row with an athlete_id targets that one prep-sheet row, never everyone with the name
  o$key <- ifelse(is.na(o$athlete_id), pw_norm_name(o$name), NA_character_)
  o
}
pw_attach_prior_class <- function(ro, prep, teams, H) {
  T <- max(as.integer(names(H))) + 1
  rc <- prep$rec[prep$rec$year == T - 2, ]
  ro$rank_prev <- NA_real_; ro$prior_added <- FALSE; ro$prior_note <- NA_character_
  if (!nrow(rc)) return(ro)
  ov <- pw_read_overrides()
  cmap <- pw_college_map(prep, teams, H)
  # box-score history at the recruit's school, so nicknames ("LA" Sneed,
  # "Addie" Deal) and spelling variants still connect through last name + school
  # (only 2025-26: a 2025 recruit has no earlier college seasons, and older
  # seasons bring in former players who share her last name and school)
  hist <- H[[as.character(T - 1)]]$pv[, c("athlete_id", "name", "team_id")]
  hist <- hist[hist$team_id != "NOND1", ]
  ln_h <- pw_last_name(hist$name)
  for (k in seq_len(nrow(rc))) {
    key <- pw_norm_name(rc$name[k]); ln <- pw_last_name(rc$name[k]); tm <- cmap(rc$college[k])
    oi <- match(key, ov$key)
    if (!is.na(oi) && tolower(ov$action[oi]) == "exclude") next
    dest <- if (!is.na(oi) && ov$team[oi] %in% teams$team) teams$espn_id[teams$team == ov$team[oi]] else tm
    # 1. exact name on a 2026-27 roster
    hit <- which(ro$key == key)
    # 2. her box-score id at her original school, wherever she is now
    if (length(hit) != 1 && !is.na(tm)) {
      ids <- unique(hist$athlete_id[hist$team_id == tm & ln_h == ln])
      if (length(ids) == 1) {
        hit <- which(ro$athlete_id == ids)
        if (!length(hit)) next                          # played in college, not on any 2026-27 roster: left the sheet
      }
    }
    # 3. same last name on her original school's 2026-27 roster
    if (length(hit) != 1 && !is.na(tm)) hit <- which(ro$team_id == tm & pw_last_name(ro$name) == ln & ro$source != "pad")
    if (length(hit) == 1) { ro$rank_prev[hit] <- rc$rank[k]; next }
    if (length(hit) > 1 || is.na(tm)) next
    # 4. no college minutes anywhere and on no roster: restore to her school
    if (key %in% pw_norm_name(hist$name)) next
    add <- ro[1, ]; add[] <- NA
    add$athlete_id <- pw_stable_id("rp", rc$name[k], dest); add$pid <- add$athlete_id; add$team_id <- dest; add$team <- teams$team[teams$espn_id == dest]
    add$name <- rc$name[k]; add$source <- "newcomer"; add$exp_years <- 0; add$cls <- "R-Fr."; add$pos <- rc$pos[k]
    add$prev_team <- if (!is.na(dest) && dest != tm) paste0(teams$team[teams$espn_id == tm], " (did not play 2025-26)") else "Did not play 2025-26"
    add$key <- key; add$rec_key <- NA; add$rec_added <- FALSE
    add$matched <- "none"; add$rank_prev <- rc$rank[k]; add$prior_added <- TRUE
    add$prior_note <- if (!is.na(oi)) ov$note[oi] else "Not in the prep sheet; assumed still at her school (unverified)"
    ro <- rbind(ro, add)
  }
  ro$prior_added[is.na(ro$prior_added)] <- FALSE
  ro
}
PW_MIN_ROSTER <- 10

# Recruiting lists use short school names ("FSU", "UConn") and often formal first
# names ("Melissa" for "Missy"). Map schools through last year's class (where each
# recruit actually played), then a unique name match; match players by exact name,
# else same team + same last name. A top-100 recruit who isn't on her school's
# roster in the Freshmen tab is added to it (listed under Data checks).
pw_college_map <- function(prep, teams, H) {
  T0 <- max(as.integer(names(H))); pv <- H[[as.character(T0)]]$pv
  rc <- prep$rec[prep$rec$year == T0 - 1, ]
  tid <- pv$team_id[match(pw_norm_name(rc$name), pw_norm_name(pv$name))]
  m <- tapply(tid, rc$college, function(x) { x <- x[!is.na(x)]; if (!length(x)) NA else names(sort(table(x), decreasing = TRUE))[1] })
  m <- m[!is.na(m)]
  alias <- c(FSU = "Florida State", UConn = "UConn", USC = "USC", LSU = "LSU", "Ole Miss" = "Ole Miss", UCLA = "UCLA",
             "NC State" = "NC State", UNC = "North Carolina", "Miami" = "Miami Hurricanes", TCU = "TCU", SMU = "SMU", BYU = "BYU")
  function(college) {
    if (!is.na(m[college])) return(unname(m[college]))
    key <- pw_norm_name(if (!is.na(alias[college])) alias[college] else college)
    nt <- pw_norm_name(teams$team)
    hit <- which(substr(nt, 1, nchar(key)) == key)
    if (length(hit) > 1) {                                   # prefer "<school> <one-word mascot>"
      rest <- mapply(function(a) nchar(a) - nchar(key), nt[hit])
      hit <- hit[rest == min(rest)]
    }
    if (length(hit) == 1) teams$espn_id[hit] else NA_character_
  }
}
pw_attach_recruits <- function(ro, prep, teams, H) {
  T <- max(as.integer(names(H))) + 1
  rc <- prep$rec[prep$rec$year == T - 1, ]
  if (!nrow(rc)) return(ro)
  cmap <- pw_college_map(prep, teams, H)
  last <- function(x) { w <- strsplit(tolower(iconv(x, to = "ASCII//TRANSLIT", sub = "")), "\\s+"); vapply(w, function(z) gsub("[^a-z]", "", z[length(z)]), "") }
  ro$rec_added <- FALSE
  for (k in seq_len(nrow(rc))) {
    key <- pw_norm_name(rc$name[k])
    if (key %in% ro$rec_key) next
    tm <- cmap(rc$college[k])
    if (is.na(tm)) next
    cand <- which(ro$team_id == tm & ro$source == "newcomer" & last(ro$name) == last(rc$name[k]))
    if (length(cand) == 1) { ro$rec_key[cand] <- key; next }
    if (key %in% ro$key[ro$team_id == tm]) next                # already there with college stats
    add <- ro[1, ]; add[] <- NA
    add$athlete_id <- pw_stable_id("rec", rc$name[k], tm); add$pid <- add$athlete_id; add$team_id <- tm; add$team <- teams$team[teams$espn_id == tm]
    add$name <- rc$name[k]; add$source <- "newcomer"; add$exp_years <- 0; add$cls <- "Fr."; add$pos <- rc$pos[k]
    add$prev_team <- "Top-100 recruit (added)"; add$key <- key; add$rec_key <- key; add$rec_added <- TRUE; add$matched <- "recruit"
    ro <- rbind(ro, add)
  }
  ro$rec_added[is.na(ro$rec_added)] <- FALSE
  ro
}

# players with college stats last season that aren't in the D1 box scores
# (moving up from D2/NAIA/JUCO): value their box line as if on a bottom-tier
# D1 team, and let the transfer model treat her as coming from that level.
pw_add_nond1 <- function(H, ro, prep, vm) {
  T0 <- as.character(max(as.integer(names(H))))
  pv <- H[[T0]]$pv; rat <- H[[T0]]$rat
  st <- prep$stats; st$athlete_id <- pw_id(st$athlete_id)
  seen_ids <- unique(unlist(lapply(H, function(s) s$pv$athlete_id)))      # any D1 box-score history
  cand <- ro[ro$source == "stats" & !ro$athlete_id %in% seen_ids & !is.na(ro$ly_min) & ro$ly_min > 0, ]
  if (!nrow(cand)) return(list(H = H, ids = character(0)))
  s <- st[match(cand$athlete_id, st$athlete_id), ]
  ps <- data.frame(season = as.integer(T0), athlete_id = cand$athlete_id, name = cand$name, pos = NA, team_id = "NOND1",
                   min = pw_num(s$total_minutes), gp = pw_num(s$games_played), pts = pw_num(s$total_pts),
                   fgm = pw_num(s$fg_made), fga = pw_num(s$fg_att), fg3m = pw_num(s$fg3_made), fg3a = pw_num(s$fg3_att),
                   ftm = pw_num(s$ft_made), fta = pw_num(s$ft_att), reb = pw_num(s$total_reb), ast = pw_num(s$total_ast),
                   oreb = 0.3 * pw_num(s$total_reb), dreb = 0.7 * pw_num(s$total_reb),   # sheet has totals only
                   stl = pw_num(s$total_stl), blk = pw_num(s$total_blk), tov = pw_num(s$total_to), pf = 0, stringsAsFactors = FALSE)
  ps[is.na(ps)] <- 0
  # (w1.6) the level she's coming from. A bottom-tier D1 team stands in for each
  # level: the lower the level, the lower the D1 percentile. These are stated
  # assumptions (PW_NOND1_Q) -- the public data has no D2/NAIA/JUCO box scores to
  # fit them from. Levels come from PW_NOND1_LEVELS when supplied, else junior
  # colleges are recognized by name, else "D2/NAIA".
  lv_file <- pw_read_opt_csv(PW_NOND1_LEVELS)
  lvl <- rep(NA_character_, nrow(cand))
  if (!is.null(lv_file)) lvl <- toupper(trimws(lv_file$level))[match(pw_norm_name(cand$name), pw_norm_name(lv_file$name))]
  juco <- grepl("community college|junior college|\\bj\\.?c\\.?$|\\bcc$|\\bjuco\\b", tolower(as.character(cand$prev_team)))
  lvl[is.na(lvl) & juco] <- "JUCO"; lvl[is.na(lvl) | !lvl %in% names(PW_NOND1_Q)] <- "D2/NAIA"
  adj_at <- function(q) { low <- rat$em <= stats::quantile(rat$em, q)
    c(mean(tapply(pv$vO - pv$rawO, pv$team_id, mean)[rat$team[low]], na.rm = TRUE),
      mean(tapply(pv$vD - pv$rawD, pv$team_id, mean)[rat$team[low]], na.rm = TRUE)) }
  A <- sapply(PW_NOND1_Q[lvl], adj_at)
  adjO <- A[1, ]; adjD <- A[2, ]
  R <- pw_rates(ps, c(NOND1 = 70))
  R[, "pf"] <- H[[T0]]$ctr["pf"] / 5                     # the sheet has no fouls: charge a league-average rate
  rv <- pw_raw_values(R, H[[T0]]$ctr, vm)
  ps$rawO <- rv$O; ps$rawD <- rv$D; ps$vO <- rv$O + adjO; ps$vD <- rv$D + adjD; ps$v <- ps$vO + ps$vD
  ps$w <- NA; ps$team_em <- min(rat$em); ps$mpg <- ps$min / pmax(ps$gp, 1)
  H[[T0]]$pv <- rbind(pv, ps[, names(pv)])
  H[[T0]]$rat <- rbind(rat, transform(rat[which.min(rat$em), ], team = "NOND1",
                                     O = stats::quantile(rat$O, .03), D = stats::quantile(rat$D, .97)))
  list(H = H, ids = cand$athlete_id, level = setNames(lvl, cand$athlete_id))
}
PW_NOND1_Q <- c("D2" = 0.05, "NAIA" = 0.03, "JUCO" = 0.03, "D2/NAIA" = 0.05)   # assumed D1 percentile per level

# ---- full 2026-27 projection --------------------------------------------------
pw_project_2027 <- function(H, cal, prep, teams, vm) {
  T <- max(as.integer(names(H))) + 1
  ro <- pw_build_roster(prep, teams, H); dups <- attr(ro, "dropped_dups")
  nd <- pw_add_nond1(H, ro, prep, vm); Hx <- nd$H
  f <- pw_player_features(ro[, c("athlete_id", "team_id")], T, Hx)
  f <- cbind(f, ro[, setdiff(names(ro), names(f))])
  f <- pw_predict_players(f, cal$pm)
  # newcomer adjustments: recruit rank > FIBA > unranked baseline
  rc <- prep$rec[prep$rec$year == T - 1, ]
  f$rank <- ifelse(f$newc == 1, rc$rank[match(f$rec_key, pw_norm_name(rc$name))], NA)
  fs <- pw_fiba_summary(prep$fiba, c(T - 2, T - 1))
  mfi <- if (is.null(fs)) rep(NA, nrow(f)) else match(f$key, fs$key)
  f$eff40 <- ifelse(f$newc == 1 & !is.na(mfi), fs$eff40[mfi], NA)
  f$fiba_events <- ifelse(is.na(f$eff40), NA, fs$events[mfi]); f$fiba_min <- ifelse(is.na(f$eff40), NA, fs$fmin[mfi])
  f$fiba_ok <- !is.na(f$eff40) & !is.na(f$fiba_min) & f$fiba_min >= 60 & is.na(f$rank)
  bO <- rep(0, nrow(f)); bD <- rep(0, nrow(f))
  isr <- which(f$newc == 1 & !is.na(f$rank)); isf <- which(f$newc == 1 & f$fiba_ok)
  isu <- which(f$newc == 1 & is.na(f$rank) & !f$fiba_ok)
  if (length(isr)) { b <- pw_rank_bump(cal$newc, f$rank[isr]); bO[isr] <- b[, "O"]; bD[isr] <- b[, "D"] }
  if (length(isf)) { b <- pw_fiba_bump(cal$newc, f$eff40[isf]); bO[isf] <- cal$newc$off_unranked["O"] + 0.5 * (b[, "O"] - cal$newc$off_unranked["O"])
                     bD[isf] <- cal$newc$off_unranked["D"] + 0.5 * (b[, "D"] - cal$newc$off_unranked["D"]) }
  if (length(isu)) { bO[isu] <- cal$newc$off_unranked["O"]; bD[isu] <- cal$newc$off_unranked["D"] }
  # unlisted roster spots (w1.6): on a roster the sheet lists nearly in full, one
  # or two placeholders are end-of-bench players, so they get replacement level.
  # When 3+ are missing, the placeholders stand in for the real rotation, so they
  # keep a typical newcomer's value at that program (and the team is flagged low
  # confidence, with extra uncertainty) -- replacement level there would project
  # the program far below its own history.
  npad <- tapply(f$source %in% "pad", f$team_id, sum)
  ipad <- which(f$source %in% "pad" & npad[f$team_id] < 3)
  if (length(ipad) && !is.null(cal$newc$replacement)) { bO[ipad] <- cal$newc$replacement["O"]; bD[ipad] <- cal$newc$replacement["D"] }
  # last year's recruits: the same rank curve, weighted by how little college
  # evidence there is (the model's own minutes-reliability curve)
  f$rel <- (f$min1 + f$min2) / (f$min1 + f$min2 + PW_REL_K)
  ip <- which(!is.na(f$rank_prev) & is.na(f$rank))
  if (length(ip)) {
    b <- pw_rank_bump(cal$newc, f$rank_prev[ip]); wgt <- 1 - f$rel[ip]
    base <- ifelse(f$newc[ip] == 1, 1, 0)             # newcomers: replace the unranked offset
    bO[ip] <- bO[ip] * (1 - base) + b[, "O"] * wgt; bD[ip] <- bD[ip] * (1 - base) + b[, "D"] * wgt
  }
  f$pvO <- f$pvO + bO; f$pvD <- f$pvD + bD; f$pv <- f$pvO + f$pvD
  f$nond1 <- f$athlete_id %in% nd$ids
  mf <- cal$newc$rank_min_fit; prog <- 5 * (f$tO + f$tD)            # program's rating last season
  rmin <- function(r) pmax(mf[1] + mf[2] * log(pmax(r, 1)) + mf[3] * prog, 2)
  f$m_override <- ifelse(f$newc == 1 & !is.na(f$rank), rmin(f$rank), ifelse(!is.na(f$rank_prev) & is.na(f$rank), rmin(f$rank_prev), NA))
  f$m_w <- ifelse(f$newc == 1 & !is.na(f$rank), 1, ifelse(!is.na(f$rank_prev) & is.na(f$rank), 1 - f$rel, 0))
  f <- pw_alloc_minutes(f, cal$mm, k = cal$mk)
  f$status <- ifelse(f$newc == 1 & !is.na(f$rank_prev) & is.na(f$rank), "Redshirt (2025 recruit)",
              ifelse(f$newc == 1, ifelse(!is.na(f$rank), "Top-100 recruit", ifelse(f$fiba_ok, "International (FIBA)", ifelse(f$source == "pad", "Unlisted spot", "Newcomer"))),
                     ifelse(f$nond1, "Transfer (non-D1)", ifelse(f$transfer == 1, "Transfer", "Returning"))))
  # last college line, always from the box scores (the prep sheet carries a
  # 2024-25 line for players who sat out 2025-26)
  P1 <- Hx[[as.character(T - 1)]]$pv; P2 <- Hx[[as.character(T - 2)]]$pv
  i1 <- match(f$athlete_id, P1$athlete_id); i2 <- match(f$athlete_id, P2$athlete_id)
  real1 <- !is.na(i1) & P1$team_id[pmax(i1, 1)] != "NOND1"
  f$ly_mpg <- ifelse(real1, P1$mpg[i1], ifelse(f$nond1, f$ly_mpg, NA))
  f$ly_ppg <- ifelse(real1, P1$pts[i1] / pmax(P1$gp[i1], 1), ifelse(f$nond1, f$ly_ppg, NA))
  lmin <- ifelse(real1, P1$min[i1], ifelse(f$gap == 1, P2$min[i2], NA))
  lpts <- ifelse(real1, P1$pts[i1], ifelse(f$gap == 1, P2$pts[i2], NA))
  f$ly_rpg[f$gap == 1] <- NA; f$ly_apg[f$gap == 1] <- NA
  f$note <- ifelse(f$gap == 1, sprintf("Missed %d-%02d; %d-%02d: %.1f mpg, %.1f ppg", T - 2, (T - 1) %% 100, T - 3, (T - 2) %% 100,
                                       P2$mpg[i2], P2$pts[i2] / pmax(P2$gp[i2], 1)), NA)
  pn <- ifelse(!is.na(f$rank_prev) & is.na(f$rank) & f$rel < 0.75,
               sprintf("No. %d recruit in 2025; pedigree counts %d%% (%s)", as.integer(f$rank_prev), round(100 * (1 - f$rel)),
                       ifelse(f$min1 + f$min2 > 0, sprintf("%d college min", as.integer(f$min1 + f$min2)), "no college minutes yet")), NA)
  f$note <- ifelse(is.na(f$note), pn, ifelse(is.na(pn), f$note, paste0(f$note, "; ", pn)))
  f$note <- ifelse(f$prior_added %in% TRUE & !is.na(f$prior_note), paste0(f$prior_note, "; ", f$note), f$note)
  lvn <- ifelse(f$nond1, paste0("Valued at the ", unname(nd$level[f$athlete_id]), " level (assumed)"), NA)
  f$note <- ifelse(is.na(lvn), f$note, ifelse(is.na(f$note), lvn, paste0(f$note, "; ", lvn)))
  # Minutes are projected per team game (what the team rating needs: games a
  # player misses count as zero). For display they're converted to minutes per
  # game played -- the same basis as last season's MPG -- using how often players
  # in each rotation slot have actually been available.
  f$pm_disp <- pmin(f$pm / mean(cal$mm$avail[1:5]), 38)
  # projected scoring for players with a real college line
  f$ppg_proj <- ifelse(!is.na(lmin) & lmin >= 100, lpts / lmin * f$pm_disp, NA)
  rs <- pw_team_roster_sums(f)
  tf <- pw_team_frame(rs, T, Hx[names(Hx) != "NOND1"])
  tf$D1 <- -tf$D1; tf$D2 <- -tf$D2
  tm <- teams[match(tf$team, teams$espn_id), ]
  tf$nc <- as.numeric(tm$new_coach %in% 1)
  tf$pO <- pw_pred(cal$tO, tf); tf$pD <- -pw_pred(cal$tD, tf)       # back to "points allowed" sign
  tf$pT <- pw_pred(cal$tT, tf)
  newc_share <- 1 - tf$retmin
  # uncertainty: newcomer share, with unlisted spots counted twice (they are
  # guesses about who will even be there); a new coach adds 10% only when the
  # coaching effect isn't already fitted from PW_COACH_HISTORY (w1.6)
  tf$sd <- sqrt(pmax(cal$sd_fit[1] + cal$sd_fit[2] * (newc_share + tf$padsh), 9)) *
    ifelse(tm$new_coach == 1 & !isTRUE(cal$with_coach), 1.1, 1)
  tf$pads <- as.vector(tapply(f$source %in% "pad", f$team_id, sum)[tf$team])
  # the part of that uncertainty a whole conference shares (fitted, w1.6)
  sc2 <- if (is.null(cal$sc2)) 0 else cal$sc2
  tf$sc <- sqrt(pmin(sc2, 0.9 * tf$sd^2))
  # mean-centre O/D so ratings are "vs an average D1 team"
  tf$pO <- tf$pO - mean(tf$pO); tf$pD <- tf$pD - mean(tf$pD)
  tf$pem <- tf$pO - tf$pD
  list(teams = tf, players = f, dropped_dups = dups)
}


# =============================================================================
# Part 4 -- 2026-27 schedule and the season simulation
# =============================================================================
# Schedule, in order of preference for every team:
#   1. games posted in the release (real dates, venues, results once played)
#   2. conference games generated to each league's game count (teams file),
#      only where a league hasn't posted its full slate -- flagged "projected"
#   3. unannounced nonconference games: last season's nonconference opponents
#      (same venue), counted for that team only -- flagged "placeholder"
pw_build_schedule <- function(teams, sched27, sched26, played = NULL, seed = 7) {
  set.seed(seed)
  ids <- teams$espn_id; conf <- setNames(teams$conf, ids)
  s <- sched27[sched27$season_type == 2 | is.na(sched27$season_type), ]
  s <- s[s$home_id %in% ids | s$away_id %in% ids, ]
  s <- s[!duplicated(s$game_id), ]
  g <- data.frame(gid = s$game_id, date = as.Date(s$game_date), home = s$home_id, away = s$away_id,
                  neutral = s$neutral_site %in% TRUE, stringsAsFactors = FALSE)
  g$home[!g$home %in% ids] <- "NOND1"; g$away[!g$away %in% ids] <- "NOND1"
  g <- g[!(g$home == "NOND1" & g$away == "NOND1"), ]
  g$conf <- g$home != "NOND1" & g$away != "NOND1" & conf[g$home] == conf[g$away]
  g$conf[is.na(g$conf)] <- FALSE
  g$kind <- "posted"; g$count_for <- "both"
  # results already in
  g$hs <- NA_real_; g$as <- NA_real_
  if (!is.null(played) && nrow(played)) {
    m <- match(g$gid, played$gid)
    g$hs <- played$hs[m]; g$as <- played$as[m]
    sw <- !is.na(m) & played$home[m] != g$home     # release swapped sides
    if (any(sw)) { t <- g$hs[sw]; g$hs[sw] <- g$as[sw]; g$as[sw] <- t }
    extra <- played[!played$gid %in% g$gid & played$st == 2 & (played$home %in% ids | played$away %in% ids), ]
    if (nrow(extra)) {
      e <- data.frame(gid = extra$gid, date = extra$date, home = ifelse(extra$home %in% ids, extra$home, "NOND1"),
                      away = ifelse(extra$away %in% ids, extra$away, "NOND1"), neutral = extra$neutral,
                      stringsAsFactors = FALSE)
      e$conf <- e$home != "NOND1" & e$away != "NOND1" & conf[e$home] %in% conf[e$away] & conf[e$home] == conf[e$away]
      e$conf[is.na(e$conf)] <- FALSE
      e$kind <- "posted"; e$count_for <- "both"; e$hs <- extra$hs; e$as <- extra$as
      g <- rbind(g, e)
    }
  }
  # ---- conference fill ----
  add <- list()
  for (cf in unique(teams$conf)) {
    mem <- ids[teams$conf == cf]; n <- length(mem); G <- teams$conf_games[teams$conf == cf][1]
    if (n < 2 || is.na(G)) next
    cg <- g[g$conf & g$home %in% mem, ]
    cnt <- setNames(tabulate(match(c(cg$home, cg$away), mem), n), mem)
    P <- matrix(0, n, n, dimnames = list(mem, mem)); H <- P
    for (k in seq_len(nrow(cg))) { i <- cg$home[k]; j <- cg$away[k]; P[i, j] <- P[i, j] + 1; P[j, i] <- P[j, i] + 1; H[i, j] <- H[i, j] + 1 }
    need <- pmax(G - cnt, 0); cap <- if (G <= 2 * (n - 1)) 2 else 3
    guard <- 0
    while (sum(need) > 1 && guard < 5000) {
      guard <- guard + 1
      cand_i <- which(need == max(need)); i <- cand_i[sample.int(length(cand_i), 1)]
      ok <- which(need > 0 & seq_len(n) != i & P[i, ] < cap)
      if (!length(ok)) { need[i] <- 0; next }
      sc <- P[i, ok] * 100 - need[ok] + stats::runif(length(ok))
      j <- ok[which.min(sc)]
      home_i <- if (H[j, i] > H[i, j]) TRUE else if (H[i, j] > H[j, i]) FALSE else stats::runif(1) < .5
      hh <- if (home_i) mem[i] else mem[j]; aa <- if (home_i) mem[j] else mem[i]
      add[[length(add) + 1]] <- data.frame(gid = paste0("proj_", cf, "_", length(add)), date = as.Date(NA), home = hh, away = aa,
                                           neutral = FALSE, conf = TRUE, kind = "projected", count_for = "both",
                                           hs = NA_real_, as = NA_real_, stringsAsFactors = FALSE)
      P[i, j] <- P[i, j] + 1; P[j, i] <- P[j, i] + 1
      if (home_i) H[i, j] <- H[i, j] + 1 else H[j, i] <- H[j, i] + 1
      need[i] <- need[i] - 1; need[j] <- need[j] - 1
    }
  }
  if (length(add)) g <- rbind(g, do.call(rbind, add))
  # ---- nonconference placeholders from last season's slate ----
  ph <- list()
  if (!is.null(sched26)) {
    s6 <- sched26[sched26$season_type == 2 & !(sched26$conference_competition %in% TRUE), ]
    for (tm in ids) {
      mine <- s6[s6$home_id == tm | s6$away_id == tm, ]
      if (!nrow(mine)) next
      mine <- mine[order(mine$game_date), ]
      opp <- ifelse(mine$home_id == tm, mine$away_id, mine$home_id)
      opp[!opp %in% ids] <- "NOND1"
      loc <- ifelse(mine$neutral_site %in% TRUE, "N", ifelse(mine$home_id == tm, "H", "A"))
      keep <- !(opp != "NOND1" & conf[opp] %in% conf[tm])            # now a league rival
      opp <- opp[keep]; loc <- loc[keep]
      have <- g[!g$conf & (g$home == tm | g$away == tm), ]
      n_need <- length(opp) - nrow(have)
      if (n_need <= 0) next
      have_opp <- ifelse(have$home == tm, have$away, have$home)
      use <- which(!(opp %in% have_opp & opp != "NOND1"))
      use <- use[seq_len(min(n_need, length(use)))]
      if (!length(use)) next
      hh <- ifelse(loc[use] == "A", opp[use], tm); aa <- ifelse(loc[use] == "A", tm, opp[use])
      ph[[tm]] <- data.frame(gid = paste0("ph_", tm, "_", seq_along(use)), date = as.Date(NA), home = hh, away = aa,
                             neutral = loc[use] == "N", conf = FALSE, kind = "placeholder",
                             count_for = ifelse(hh == tm, "h", "a"), hs = NA_real_, as = NA_real_, stringsAsFactors = FALSE)
    }
  }
  if (length(ph)) g <- rbind(g, do.call(rbind, ph))
  g$done <- !is.na(g$hs) & !is.na(g$as)
  g
}

# ---- game model helpers --------------------------------------------------------
# expected possessions and margin (home minus away, points)
pw_game_expect <- function(emh, ema, th, ta, loc, gm) {
  poss <- gm$tmu + th + ta
  list(poss = poss, margin = (emh - ema + 2 * gm$h * loc) * poss / 100)
}

# ---- simulation ------------------------------------------------------------------
# teams: data frame espn_id, conf, ct_teams, auto_bid; rt: team ratings (team, em, sd, T)
# g: schedule; gm: list(h, tmu, sigma)
pw_simulate <- function(teams, rt, g, gm, n_sims = N_SIMS, chunk = 1000) {
  ids <- c(teams$espn_id, "NOND1"); N <- length(ids) - 1
  em0 <- c(rt$em[match(teams$espn_id, rt$team)], NON_D1_EM)
  sd0 <- c(rt$sd[match(teams$espn_id, rt$team)], 0)
  # w1.6: each team's uncertainty = its own part + a part its whole conference
  # shares (a league that is better or worse than projected across the board)
  sc0 <- if (is.null(rt$sc)) rep(0, N) else rt$sc[match(teams$espn_id, rt$team)]; sc0[is.na(sc0)] <- 0
  id0 <- sqrt(pmax(sd0[1:N]^2 - sc0^2, 0))
  cidx <- match(teams$conf, unique(teams$conf)); nconf <- length(unique(teams$conf))
  tt  <- c(rt$T[match(teams$espn_id, rt$team)], -2)
  hi <- match(g$home, ids); ai <- match(g$away, ids); loc <- ifelse(g$neutral, 0, 1)
  G <- nrow(g)
  cH <- g$count_for %in% c("both", "h") & hi <= N; cA <- g$count_for %in% c("both", "a") & ai <= N
  # incidence matrices (team x game)
  inc <- function(rows, cols, keep) { M <- matrix(0, N, G); k <- which(keep); M[cbind(rows[k], cols[k])] <- 1; M }
  IH <- inc(hi, seq_len(G), cH); IA <- inc(ai, seq_len(G), cA)
  ICH <- inc(hi, seq_len(G), cH & g$conf); ICA <- inc(ai, seq_len(G), cA & g$conf)
  confs <- unique(teams$conf)
  res <- list(W = matrix(0, N, 0), L = NULL)
  acc <- list(w = 0, l = 0, cw = 0, cl = 0, w2 = 0, reg1 = rep(0, N), regsh = rep(0, N), ctch = 0, ncaa = 0, auto = 0,
              seedsum = 0, top4 = 0, r32 = 0, s16 = 0, e8 = 0, f4 = 0, final = 0, champ = 0, one = 0,
              rk = matrix(0, N, 0))
  cseed <- lapply(confs, function(cf) { n <- sum(teams$conf == cf); matrix(0, n, n) }); names(cseed) <- confs
  rkq <- NULL; recs <- NULL
  done <- 0
  pexp <- pw_game_expect(em0[hi], em0[ai], tt[hi], tt[ai], loc, gm)
  inj_em <- if (is.null(g$inj_em)) rep(0, G) else { z <- g$inj_em; z[is.na(z)] <- 0; z }
  while (done < n_sims) {
    S <- min(chunk, n_sims - done); done <- done + S
    Z <- matrix(stats::rnorm(N * S), N, S); ZC <- matrix(stats::rnorm(nconf * S), nconf, S)
    EM <- rbind(em0[1:N] + id0 * Z + sc0 * ZC[cidx, , drop = FALSE], rep(NON_D1_EM, S))   # (N+1) x S true strength
    # w1.9: expected rating change from injuries, game by game (0 when none)
    mu <- (EM[hi, , drop = FALSE] - EM[ai, , drop = FALSE] + 2 * gm$h * loc + inj_em) * pexp$poss / 100
    mar <- mu + gm$sigma * matrix(stats::rnorm(G * S), G, S)
    if (any(g$done)) mar[g$done, ] <- (g$hs - g$as)[g$done]
    hw <- (mar > 0) * 1
    W <- IH %*% hw + IA %*% (1 - hw); L <- IH %*% (1 - hw) + IA %*% hw
    CW <- ICH %*% hw + ICA %*% (1 - hw); CL <- ICH %*% (1 - hw) + ICA %*% hw
    # performance rating seen by the selection committee proxy: strength plus
    # how much better/worse the team played than expected (per 100 possessions)
    rp <- (mar - mu) / pexp$poss * 100
    ng <- rowSums(IH) + rowSums(IA)
    PERF <- EM[1:N, , drop = FALSE] + (IH %*% rp - IA %*% rp) / pmax(ng, 1)
    acc$w <- acc$w + rowSums(W); acc$l <- acc$l + rowSums(L); acc$cw <- acc$cw + rowSums(CW); acc$cl <- acc$cl + rowSums(CL)
    rk <- apply(-PERF, 2, rank, ties.method = "random")
    rkq <- cbind(rkq, rk[, sample.int(S, min(S, 400))])
    recs <- cbind(recs, W[, sample.int(S, min(S, 200))])
    # conference standings & tournaments
    champ <- matrix(0L, 0, S); champ_conf <- character(0)
    for (cf in confs) {
      mem <- which(teams$conf == cf); n <- length(mem)
      key <- CW[mem, , drop = FALSE] / pmax(CW[mem, , drop = FALSE] + CL[mem, , drop = FALSE], 1) * 1000 + PERF[mem, , drop = FALSE] * 1e-3
      ord <- apply(-key, 2, order)                                     # n x S: row = seed, value = local index
      if (n == 1) ord <- matrix(1L, 1, S)
      for (sd in seq_len(n)) { tab <- tabulate(ord[sd, ], n); cseed[[cf]][, sd] <- cseed[[cf]][, sd] + tab }
      best <- apply(CW[mem, , drop = FALSE], 2, max)
      top <- CW[mem, , drop = FALSE] == matrix(best, n, S, byrow = TRUE)
      nt <- colSums(top)
      acc$regsh[mem] <- acc$regsh[mem] + rowSums(top)
      acc$reg1[mem] <- acc$reg1[mem] + rowSums(top & matrix(nt == 1, n, S, byrow = TRUE))
      k <- min(teams$ct_teams[mem[1]], n)
      seeds <- matrix(mem[ord[seq_len(k), , drop = FALSE]], k, S)
      ch <- pw_bracket(seeds, EM, tt, gm, host_rounds = 0)
      champ <- rbind(champ, ch); champ_conf <- c(champ_conf, cf)
    }
    for (r in seq_len(nrow(champ))) acc$ctch <- acc$ctch + tabulate(champ[r, ], N)
    # NCAA field
    ab <- champ[teams$auto_bid[match(champ_conf, teams$conf)] == 1, , drop = FALSE]
    nt <- NCAA_FIELD
    field <- matrix(0L, nt, S)
    for (s in seq_len(S)) {
      auto <- unique(ab[, s]); pool <- setdiff(order(-PERF[, s]), auto)
      inn <- c(auto, pool[seq_len(nt - length(auto))])
      field[, s] <- inn[order(-PERF[inn, s])]
    }
    for (s in seq_len(S)) acc$auto <- acc$auto + tabulate(unique(ab[, s]), N)
    acc$ncaa <- acc$ncaa + tabulate(field, N)
    nc <- pw_ncaa(field, EM, tt, gm)
    acc$seedsum <- acc$seedsum + nc$seedsum; acc$top4 <- acc$top4 + nc$top4; acc$one <- acc$one + nc$one
    acc$r32 <- acc$r32 + nc$r32; acc$s16 <- acc$s16 + nc$s16; acc$e8 <- acc$e8 + nc$e8
    acc$f4 <- acc$f4 + nc$f4; acc$final <- acc$final + nc$final; acc$champ <- acc$champ + nc$champ
  }
  n <- n_sims
  q <- function(p) apply(rkq, 1, stats::quantile, p, type = 1)
  out <- data.frame(team = teams$espn_id, w = acc$w / n, l = acc$l / n, cw = acc$cw / n, cl = acc$cl / n,
                    reg_title = acc$regsh / n, reg_outright = acc$reg1 / n, ct_champ = acc$ctch / n,
                    ncaa = acc$ncaa / n, auto = acc$auto / n, seed = ifelse(acc$ncaa > 0, acc$seedsum / pmax(acc$ncaa, 1), NA),
                    one_seed = acc$one / n, top4 = acc$top4 / n, r32 = acc$r32 / n, s16 = acc$s16 / n, e8 = acc$e8 / n,
                    f4 = acc$f4 / n, final = acc$final / n, champ = acc$champ / n,
                    rk10 = q(.1), rk50 = q(.5), rk90 = q(.9), stringsAsFactors = FALSE)
  wq <- t(apply(recs, 1, stats::quantile, c(.1, .9), type = 1))
  out$w10 <- wq[, 1]; out$w90 <- wq[, 2]
  list(teams = out, conf_seeds = lapply(cseed, function(m) m / n))
}

# single-elimination bracket, vectorised over simulations. seeds: k x S matrix of
# team indices (row = seed). Top seeds get byes to fill a power-of-two bracket.
pw_game_sim <- function(a, b, EM, tt, gm, home_a = 0) {
  poss <- gm$tmu + tt[a] + tt[b]
  mu <- (EM[cbind(a, seq_along(a))] - EM[cbind(b, seq_along(b))] + 2 * gm$h * home_a) * poss / 100
  ifelse(mu + gm$sigma * stats::rnorm(length(a)) > 0, a, b)
}
pw_bracket_order <- function(P) { o <- 1; while (length(o) < P) { m <- 2 * length(o) + 1; o <- as.vector(rbind(o, m - o)) }; o }
pw_bracket <- function(seeds, EM, tt, gm, host_rounds = 0) {
  k <- nrow(seeds); S <- ncol(seeds)
  if (k == 1) return(seeds[1, ])
  P <- 2^ceiling(log2(k)); ord <- pw_bracket_order(P)
  slot <- lapply(ord, function(s) if (s <= k) seeds[s, ] else rep(NA_integer_, S))
  while (length(slot) > 1) {
    nxt <- vector("list", length(slot) / 2)
    for (i in seq_along(nxt)) {
      a <- slot[[2 * i - 1]]; b <- slot[[2 * i]]
      nxt[[i]] <- if (all(is.na(b))) a else if (all(is.na(a))) b else pw_game_sim(a, b, EM, tt, gm)
    }
    slot <- nxt
  }
  slot[[1]]
}

# NCAA tournament: field = 68 x S team indices ordered best to worst (overall
# seed list). Ranks 61-68 play the First Four for the four 16-seed spots. S-curve
# into four regions; seeds 1-4 host the first two rounds.
pw_ncaa <- function(field, EM, tt, gm) {
  S <- ncol(field); N <- nrow(EM) - 1
  ff <- sapply(1:4, function(i) pw_game_sim(field[60 + 2 * i - 1, ], field[60 + 2 * i, ], EM, tt, gm))
  if (S == 1) ff <- matrix(ff, 1)
  line <- c(rep(1:15, each = 4))
  seedsum <- tabulate(field[1:60, ], N) * 0
  for (r in 1:60) seedsum <- seedsum + tabulate(field[r, ], N) * line[r]
  for (i in 1:4) { seedsum <- seedsum + tabulate(field[60 + 2 * i - 1, ], N) * 16 + tabulate(field[60 + 2 * i, ], N) * 16 }
  top4 <- tabulate(field[1:16, ], N); one <- tabulate(field[1:4, ], N)
  # region r gets, on line s, the overall rank per serpentine
  reg_team <- function(r, s) {
    if (s == 16) return(ff[, r])
    pos <- if (s %% 2 == 1) r else 5 - r
    field[4 * (s - 1) + pos, ]
  }
  pairs <- list(c(1, 16), c(8, 9), c(5, 12), c(4, 13), c(6, 11), c(3, 14), c(7, 10), c(2, 15))
  r32 <- s16 <- e8 <- f4 <- rep(0, N); rw <- list()
  for (r in 1:4) {
    w1 <- lapply(pairs, function(p) pw_game_sim(reg_team(r, p[1]), reg_team(r, p[2]), EM, tt, gm, home_a = as.numeric(p[1] <= 4)))
    for (x in w1) r32 <- r32 + tabulate(x, N)
    # round 2: host = the better seed if it's a top-4 seed
    hosts <- c(1, 4, 3, 2)
    w2 <- lapply(1:4, function(i) {
      a <- w1[[2 * i - 1]]; b <- w1[[2 * i]]; h <- reg_team(r, hosts[i])
      pw_game_sim(a, b, EM, tt, gm, home_a = (a == h) - (b == h))
    })
    for (x in w2) s16 <- s16 + tabulate(x, N)
    w3 <- list(pw_game_sim(w2[[1]], w2[[2]], EM, tt, gm), pw_game_sim(w2[[3]], w2[[4]], EM, tt, gm))
    for (x in w3) e8 <- e8 + tabulate(x, N)
    rw[[r]] <- pw_game_sim(w3[[1]], w3[[2]], EM, tt, gm); f4 <- f4 + tabulate(rw[[r]], N)
  }
  s1 <- pw_game_sim(rw[[1]], rw[[4]], EM, tt, gm); s2 <- pw_game_sim(rw[[2]], rw[[3]], EM, tt, gm)
  ch <- pw_game_sim(s1, s2, EM, tt, gm)
  list(seedsum = seedsum, top4 = top4, one = one, r32 = r32, s16 = s16, e8 = e8, f4 = f4,
       final = tabulate(c(s1, s2), N), champ = tabulate(ch, N))
}


# =============================================================================
# Part 5 -- calibration (cached), in-season updating, and the page payload
# =============================================================================
PW_MIN_K   <- 1.75            # minutes allocation exponent (chosen on the team backtest)
PW_LAMBDAS <- c(1.5, 3, 5, 8, 12, 20)

pw_slim <- function(fit) structure(list(terms = delete.response(terms(fit)), coefficients = coef(fit)), class = "pwslim")

# ---- conferences as the schedule shows them ------------------------------------
# Teams joined by conference games in a season form that season's leagues
# (connected components), so history needs no conference table.
pw_conf_groups <- function(g) {
  cg <- g[g$conf & g$d1h & g$d1a, ]
  teams <- sort(unique(c(g$home[g$d1h], g$away[g$d1a])))
  lab <- setNames(seq_along(teams), teams)
  h <- as.character(cg$home); a <- as.character(cg$away)
  for (it in 1:100) {
    m <- pmin(lab[h], lab[a])
    tmp <- tapply(c(m, m), c(h, a), min)
    new <- lab; new[names(tmp)] <- pmin(new[names(tmp)], tmp)
    new <- setNames(new[new], names(new))           # jump to the root's label
    if (identical(new, lab)) break
    lab <- new
  }
  setNames(paste0("c", lab), names(lab))
}

# ---- walk-forward pieces ------------------------------------------------------
# player values for every season in H under value model vm
pw_apply_values <- function(H, vm) {
  for (yr in names(H)) {
    s <- H[[yr]]
    H[[yr]]$pv <- pw_player_values(s$ps, s$rat, s$pace, s$ctr, vm)
  }
  H
}

pw_read_opt_csv <- function(fn) {
  f <- file.path(OUT_DIR, fn)
  if (!file.exists(f)) return(NULL)
  x <- tryCatch(utils::read.csv(f, stringsAsFactors = FALSE, encoding = "UTF-8", colClasses = "character"), error = function(e) NULL)
  if (is.null(x) || !nrow(x)) return(NULL)
  names(x) <- sub("^\ufeff", "", names(x)); x
}
# past recruiting classes: year, rank, name, espn_team_id
pw_read_recruit_history <- function() {
  x <- pw_read_opt_csv(PW_RECRUIT_HISTORY); if (is.null(x)) return(NULL)
  data.frame(year = as.integer(x$year), rank = pw_num(x$rank), key = pw_norm_name(x$name),
             team_id = if (is.null(x$espn_team_id)) NA_character_ else x$espn_team_id, stringsAsFactors = FALSE)
}
# coaching history: season, espn_id, coach  ->  new-coach flag by team-season
pw_read_coach_history <- function() {
  x <- pw_read_opt_csv(PW_COACH_HISTORY); if (is.null(x)) return(NULL)
  x$season <- as.integer(x$season); x <- x[order(x$espn_id, x$season), ]
  prev <- ave(x$coach, x$espn_id, FUN = function(z) c(NA, head(z, -1)))
  prevs <- ave(x$season, x$espn_id, FUN = function(z) c(NA, head(z, -1)))
  ok <- !is.na(prev) & prevs == x$season - 1
  data.frame(season = x$season[ok], team = x$espn_id[ok], nc = as.numeric(tolower(trimws(x$coach[ok])) != tolower(trimws(prev[ok]))),
             stringsAsFactors = FALSE)
}

# recruit-rank adjustment inside the backtest (only when PW_RECRUIT_HISTORY is
# supplied): fitted on earlier seasons' ranked newcomers, applied to season T's
pw_backtest_recruits <- function(f, trn, T, H, rec) {
  tag <- function(d) { y <- d$season - 1; r <- rec[rec$year %in% y, ]
    k1 <- paste(y, pw_norm_name(d$name), d$team_id); k2 <- paste(y, pw_norm_name(d$name))
    rk <- r$rank[match(k1, paste(r$year, r$key, r$team_id))]
    alt <- r$rank[match(k2, paste(r$year, r$key))]; rk[is.na(rk)] <- alt[is.na(rk)]; rk }
  trn$rank <- ifelse(trn$newc == 1, tag(trn), NA); f$rank <- ifelse(f$newc == 1, tag(f), NA)
  fit_rows <- trn[!is.na(trn$rank) & trn$min >= 40, ]
  if (nrow(fit_rows) < 20 || !any(!is.na(f$rank))) return(f)
  fit_rows$rO <- fit_rows$vO - fit_rows$pvO; fit_rows$rD <- fit_rows$vD - fit_rows$pvD
  b <- coef(lm(cbind(rO, rD) ~ log(rank), data = fit_rows, weights = pmin(fit_rows$min, 800)))
  mrows <- trn[!is.na(trn$rank), ]; mrows$prog <- 5 * (mrows$tO + mrows$tD)
  mf <- coef(lm(m ~ log(rank) + prog, data = mrows))
  i <- which(!is.na(f$rank))
  f$pvO[i] <- f$pvO[i] + b[1, "rO"] + b[2, "rO"] * log(f$rank[i])
  f$pvD[i] <- f$pvD[i] + b[1, "rD"] + b[2, "rD"] * log(f$rank[i])
  f$pv <- f$pvO + f$pvD
  f$m_override <- NA_real_; f$m_w <- 0
  f$m_override[i] <- pmax(mf[1] + mf[2] * log(f$rank[i]) + mf[3] * 5 * (f$tO[i] + f$tD[i]), 2); f$m_w[i] <- 1
  f
}

# one backtest season: fit on transitions before T, project season T's rosters
pw_backtest_frame <- function(TR, T, H, rec = NULL, coach = NULL) {
  trn <- TR[TR$season < T, ]; pm <- pw_fit_player_models(trn)
  trn <- pw_predict_players(trn, pm); mm <- pw_fit_minutes(trn)
  f <- pw_predict_players(TR[TR$season == T, ], pm)
  if (!is.null(rec)) f <- pw_backtest_recruits(f, trn, T, H, rec)
  f <- pw_alloc_minutes(f, mm, k = PW_MIN_K)
  rs <- pw_team_frame(pw_team_roster_sums(f), T, H); rat <- H[[as.character(T)]]$rat
  rs$yO <- rat$O[match(rs$team, rat$team)]; rs$yD <- -rat$D[match(rs$team, rat$team)]; rs$yT <- rat$T[match(rs$team, rat$team)]
  rs$D1 <- -rs$D1; rs$D2 <- -rs$D2; rs$season <- T
  rs$conf <- unname(H[[as.character(T)]]$conf[rs$team])
  rs$nc <- if (is.null(coach)) 0 else { z <- coach$nc[match(paste(T, rs$team), paste(coach$season, coach$team))]; ifelse(is.na(z), 0, z) }
  out <- rs[!is.na(rs$yO), ]
  attr(out, "players") <- f[, c("athlete_id", "team_id", "pvO", "pvD", "pm")]
  out
}

# walk-forward evaluation of a set of team frames
pw_backtest_eval <- function(TF, forms) {
  bt <- NULL; res <- NULL; PRE <- list()
  for (T in sort(unique(TF$season))[-1]) {
    trn <- TF[TF$season < T, ]; te <- TF[TF$season == T, ]
    fO <- lm(forms$O, trn); fD <- lm(forms$D, trn); fT <- lm(forms$T, trn)
    pO <- pw_pred(fO, te); pD <- pw_pred(fD, te); em <- te$yO + te$yD; pem <- pO + pD
    carry <- pw_pred(lm(I(yO + yD) ~ I(O1 + D1), trn), te)
    pT <- pw_pred(fT, te)
    bt <- rbind(bt, data.frame(season = T, n = nrow(te), rmse = sqrt(mean((pem - em)^2)), rmse_carry = sqrt(mean((carry - em)^2)),
                               spearman = stats::cor(pem, em, method = "spearman"), spearman_carry = stats::cor(carry, em, method = "spearman"),
                               top25 = length(intersect(te$team[order(-pem)][1:25], te$team[order(-em)][1:25])),
                               rmse_tempo = sqrt(mean((pT - te$yT)^2)), rmse_tempo_carry = sqrt(mean((pw_pred(lm(yT ~ T1, trn), te) - te$yT)^2))))
    res <- rbind(res, data.frame(season = T, team = te$team, conf = te$conf, r = pem - em, e2 = (pem - em)^2, nw = 1 - te$retmin,
                                 tr = te$trmin, c2 = (carry - em)^2, stringsAsFactors = FALSE))
    PRE[[as.character(T)]] <- data.frame(team = te$team, O = pO - mean(pO), D = -(pD - mean(pD)), T = pT, nw = 1 - te$retmin,
                                         conf = te$conf, stringsAsFactors = FALSE)
  }
  list(bt = bt, res = res, PRE = PRE)
}

# bootstrap (team-seasons resampled) intervals for the headline numbers
pw_boot <- function(res, B = PW_BOOT) {
  # w1.10: resample whole season x conference clusters. A conference's teams share
  # preseason error (sc2), so resampling team-seasons one at a time treated ~360
  # correlated rows as independent and made the intervals too narrow. The iid
  # version is kept (_iid) for comparison.
  n <- nrow(res); set.seed(11)
  q <- function(x) unname(stats::quantile(x, c(.025, .975)))
  d0 <- replicate(B, { i <- sample.int(n, n, TRUE); c(sqrt(mean(res$e2[i])), sqrt(mean(res$c2[i]))) })
  cl <- paste(res$season, ifelse(is.na(res$conf), paste0("t", res$team), res$conf))
  ix <- split(seq_len(n), factor(cl, levels = unique(cl))); nc <- length(ix)
  d <- replicate(B, { i <- unlist(ix[sample.int(nc, nc, TRUE)], use.names = FALSE); c(sqrt(mean(res$e2[i])), sqrt(mean(res$c2[i]))) })
  list(rmse = sqrt(mean(res$e2)), rmse_ci = q(d[1, ]), gain = sqrt(mean(res$c2)) - sqrt(mean(res$e2)), gain_ci = q(d[2, ] - d[1, ]),
       rmse_ci_iid = q(d0[1, ]), gain_ci_iid = q(d0[2, ] - d0[1, ]), n_clusters = nc)
}

# how much of the preseason error a whole conference shares (variance, pts^2 /100)
pw_conf_var <- function(res) {
  res <- res[!is.na(res$conf), ]
  res$r0 <- res$r - ave(res$r, res$season)
  k <- paste(res$season, res$conf)
  m <- tapply(res$r0, k, mean); n <- tapply(res$r0, k, length); v <- tapply(res$r0, k, stats::var)
  ok <- n >= 4
  sw <- sum(v[ok] * (n[ok] - 1)) / sum(n[ok] - 1)
  max(0, sum(n[ok] * (m[ok]^2 - sw / n[ok])) / sum(n[ok]))
}

# Single-game spread. Residuals against ratings fitted without the game (cross-
# fitting) still carry the error of those ratings, and in-sample residuals are
# flattered by them. Fitting ratings on 80% and on 50% of each season's games
# gives two residual variances, v(f) = sigma^2 + C / f; solving the pair
# removes the rating error and leaves the game-to-game noise the simulation
# needs (w1.6; w1.5 used in-sample residuals x 1.05).
pw_game_sigma <- function(HG, H, seasons) {
  hh <- NULL; set.seed(5); v <- c(f8 = 0, f5 = 0); nn <- c(f8 = 0, f5 = 0)
  for (yr in seasons) {
    g <- HG[[yr]]; r <- H[[yr]]$rat; g <- g[g$home %in% r$team & g$away %in% r$team & g$poss > 40, ]
    for (K in c(5, 2)) {
      fold <- sample(rep(seq_len(K), length.out = nrow(g)))
      for (k in seq_len(K)) {
        fit <- pw_fit_ratings(g[fold != k, ], r$team, lambda = 1)
        te <- g[fold == k, ]; em <- setNames(fit$em, r$team); Tm <- setNames(fit$T, r$team)
        e <- pw_game_expect(em[te$home], em[te$away], Tm[te$home], Tm[te$away], ifelse(te$neutral, 0, 1),
                            list(tmu = fit$tmu[1], h = fit$h[1]))
        rr <- (te$hs - te$as) - e$margin; nm <- if (K == 5) "f8" else "f5"
        v[nm] <- v[nm] + sum(rr^2); nn[nm] <- nn[nm] + length(rr)
      }
    }
    hh <- c(hh, r$h[1])
  }
  v <- v / nn
  C <- (v["f5"] - v["f8"]) / (1 / 0.5 - 1 / 0.8)
  s2 <- v["f8"] - C / 0.8
  list(sigma = sqrt(max(s2, 0.8 * v["f8"])), h = mean(hh), sigma_crossfit = sqrt(unname(v["f8"])))
}

# ---- w1.10: constants frozen per held-out season ------------------------------------
# The in-season replay used four numbers fitted on ALL backtest seasons (the
# game spread sigma and home edge h, the preseason spread fit sd_fit, the
# conference variance sc2) and the full-sample box-score value model, so each
# replayed season was scored with constants that had seen its own results. Here
# every replayed season gets constants fitted on the OTHER seasons only (the
# value model is the one already refitted inside each walk-forward fold), and the
# league tempo it is predicted against is the PRIOR season's. Production still
# uses the all-season values.
pw_game_sigma_parts <- function(HG, H, yr) {
  set.seed(5 + as.integer(yr)); v <- c(f8 = 0, f5 = 0); nn <- c(f8 = 0, f5 = 0)
  g <- HG[[yr]]; r <- H[[yr]]$rat; g <- g[g$home %in% r$team & g$away %in% r$team & g$poss > 40, ]
  for (K in c(5, 2)) {
    fold <- sample(rep(seq_len(K), length.out = nrow(g)))
    for (k in seq_len(K)) {
      fit <- pw_fit_ratings(g[fold != k, ], r$team, lambda = 1)
      te <- g[fold == k, ]; em <- setNames(fit$em, r$team); Tm <- setNames(fit$T, r$team)
      e <- pw_game_expect(em[te$home], em[te$away], Tm[te$home], Tm[te$away], ifelse(te$neutral, 0, 1), list(tmu = fit$tmu[1], h = fit$h[1]))
      rr <- (te$hs - te$as) - e$margin; nm <- if (K == 5) "f8" else "f5"
      v[nm] <- v[nm] + sum(rr^2); nn[nm] <- nn[nm] + length(rr)
    }
  }
  list(v = v, n = nn, h = r$h[1])
}
# ---- w1.11: team-specific home edge ---------------------------------------------------
# Each team's home margin over expectation minus its road margin over expectation
# (per 100 possessions, against that season's ratings and the league home edge),
# pooled over the `back` seasons before T, then shrunk toward zero by how noisy it
# is (empirical Bayes). True differences between teams are small (sd about 0.7 to
# 1.6 per 100, rising since 2024) and one team's raw estimate is mostly noise (se
# about 3), so most teams end up within a point of the league edge. In the
# 2020-26 replay this improved held-out log loss in 6 of 7 seasons (0.47920 vs
# 0.47929). Returned as deviations from the league edge, in margin per 100.
pw_team_hca <- function(HG, H, T, back = 4) {
  ys <- as.character((T - back):(T - 1)); ys <- ys[ys %in% names(HG) & ys %in% names(H)]
  if (!length(ys)) return(NULL)
  r <- do.call(rbind, lapply(ys, function(y) { g <- HG[[y]]; rt <- H[[y]]$rat; em <- setNames(rt$em, rt$team); h <- rt$h[1]
    g <- g[!g$neutral & g$home %in% rt$team & g$away %in% rt$team & g$poss > 40, ]
    res <- 100 * (g$hs - g$as) / g$poss - (em[g$home] - em[g$away] + 2 * h)
    rbind(data.frame(team = g$home, res = res, home = 1), data.frame(team = g$away, res = -res, home = 0)) }))
  s2 <- stats::var(r$res)
  a <- do.call(rbind, lapply(split(r, r$team), function(d) { nh <- sum(d$home == 1); na <- sum(d$home == 0)
    if (nh < 5 || na < 5) return(NULL)
    data.frame(team = d$team[1], raw = mean(d$res[d$home == 1]) - mean(d$res[d$home == 0]), v = s2 * (1 / nh + 1 / na), n = nh + na) }))
  a$raw <- a$raw - mean(a$raw)
  tau2 <- max(0, stats::var(a$raw) - mean(a$v))
  a$d <- a$raw * tau2 / (tau2 + a$v)
  list(d = setNames(a$d, a$team), tau = sqrt(tau2), se = sqrt(mean(a$v)), seasons = range(as.integer(ys)), n_teams = nrow(a))
}
# games with the team-specific part of the home edge taken out of the score, so a
# fit with the league edge sees them on equal terms (d = deviations, margin per 100)
pw_strip_team_hca <- function(g, d) {
  if (is.null(d) || !nrow(g)) return(g)
  dl <- unname(d[g$home]); dl[is.na(dl) | g$neutral] <- 0
  g$hs <- g$hs - dl / 2 * g$poss / 100; g$as <- g$as + dl / 2 * g$poss / 100
  g
}

pw_fold_constants <- function(res, HG, H, seasons) {
  parts <- lapply(setNames(seasons, seasons), function(y) pw_game_sigma_parts(HG, H, y))
  out <- list(sd_fit = list(), sc2 = list(), gm = list())
  for (y in seasons) {
    o <- res[res$season != as.integer(y), ]
    out$sd_fit[[y]] <- coef(lm(e2 ~ nw, o)); out$sc2[[y]] <- pw_conf_var(o)
    ps <- parts[setdiff(seasons, y)]
    v <- Reduce(`+`, lapply(ps, `[[`, "v")) / Reduce(`+`, lapply(ps, `[[`, "n"))   # parts hold sums of squares and counts
    C <- (v[["f5"]] - v[["f8"]]) / (1 / 0.5 - 1 / 0.8); s2 <- v[["f8"]] - C / 0.8
    prev <- H[[as.character(as.integer(y) - 1)]]
    out$gm[[y]] <- list(h = mean(vapply(ps, `[[`, 0, "h")), sigma = unname(sqrt(max(s2, 0.8 * v[["f8"]]))),
                        tmu = if (!is.null(prev)) prev$rat$tmu[1] else H[[y]]$rat$tmu[1])
  }
  out
}

# ---- in-season: how many games is the preseason projection worth? -------------
# For each past season, refit every 14 days on the games so far with the
# walk-forward preseason projection as the prior, predict the next 14 days.
# w1.6: two ways of setting the prior's weight are compared -- the same number
# of games for every team ("flat"), or scaled by each team's preseason
# uncertainty ("scaled": a roster of newcomers gets a lighter prior) -- and the
# win-probability spread is fitted on these out-of-sample games (k_pre, k_in).
pw_calibrate_inseason <- function(HG, PRE, gm, sc2, fc = NULL) {
  rows <- NULL
  for (yr in names(PRE)) {
    gmy <- if (!is.null(fc)) fc$gm[[yr]] else gm; sc2y <- if (!is.null(fc)) fc$sc2[[yr]] else sc2   # w1.10: constants from the other seasons
    g <- HG[[yr]]; pr <- PRE[[yr]]
    g <- g[g$home %in% pr$team & g$away %in% pr$team & g$poss > 40, ]
    g <- g[order(g$date), ]
    teams <- pr$team
    prior <- list(O = setNames(pr$O, teams), D = setNames(pr$D, teams), T = setNames(pr$T, teams))
    sdv <- setNames(pr$sd, teams)
    loc <- ifelse(g$neutral, 0, 1)
    e0 <- pw_game_expect(prior$O[g$home] - prior$D[g$home], prior$O[g$away] - prior$D[g$away],
                         prior$T[g$home], prior$T[g$away], loc, gmy)
    rows <- rbind(rows, data.frame(season = yr, mode = "pre", lambda = Inf, day = as.numeric(g$date - min(g$date)),
                                   pred = e0$margin, act = g$hs - g$as, poss = e0$poss, conf = g$conf,
                                   vh = sdv[g$home]^2, va = sdv[g$away]^2, shh = 1, sha = 1, sig = gmy$sigma, sc2r = sc2y))
    cps <- seq(min(g$date) + 14, max(g$date), by = 14)
    for (mode in c("flat", "scaled")) for (L in PW_LAMBDAS) {
      lam <- if (mode == "flat") setNames(rep(L, length(teams)), teams) else L * mean(sdv^2) / sdv^2
      for (k in seq_along(cps)) {
        cp <- cps[k]; past <- g[g$date < cp, ]; nxt <- g[g$date >= cp & g$date < cp + 14, ]
        if (!nrow(nxt)) next
        fit <- pw_fit_ratings(past, teams, lambda = lam, prior = prior, fit_h = FALSE, h_fixed = gmy$h)
        em <- setNames(fit$em, teams); Tm <- setNames(fit$T, teams)
        sh <- setNames(lam / (lam + fit$games), teams)
        e <- pw_game_expect(em[nxt$home], em[nxt$away], Tm[nxt$home], Tm[nxt$away], ifelse(nxt$neutral, 0, 1),
                            list(tmu = fit$tmu[1], h = gmy$h))
        rows <- rbind(rows, data.frame(season = yr, mode = mode, lambda = L, day = as.numeric(nxt$date - min(g$date)),
                                       pred = e$margin, act = nxt$hs - nxt$as, poss = e$poss, conf = nxt$conf,
                                       vh = sdv[nxt$home]^2 * sh[nxt$home], va = sdv[nxt$away]^2 * sh[nxt$away],
                                       shh = sh[nxt$home], sha = sh[nxt$away], sig = gmy$sigma, sc2r = sc2y))
      }
    }
  }
  rows <- rows[rows$act != 0, ]
  ll <- function(p, y) -mean(y * log(p) + (1 - y) * log(1 - p))
  clamp <- function(p) pmin(pmax(p, 1e-4), 1 - 1e-4)
  summ <- do.call(rbind, lapply(split(rows, paste(rows$mode, rows$lambda)), function(r) {
    y <- as.numeric(r$act > 0)
    s <- stats::optimize(function(s) ll(clamp(stats::pnorm(r$pred / s)), y), c(4, 30))$minimum
    p <- stats::pnorm(r$pred / s)
    data.frame(mode = r$mode[1], lambda = r$lambda[1], n = nrow(r), scale = s, logloss = ll(p, y), acc = mean((p > .5) == (y == 1)),
               mae = mean(abs(r$pred - r$act)), stringsAsFactors = FALSE)
  }))
  fin <- summ[is.finite(summ$lambda), ]
  bi <- which.min(fin$logloss); best <- fin$lambda[bi]; best_mode <- fin$mode[bi]
  # probability spread: sigma^2 + k * (poss/100)^2 * rating variance of the
  # difference, where teams in the same league share the conference component
  pvar <- function(r) (r$poss / 100)^2 * pmax(r$vh + r$va - r$conf * r$sc2r * (r$shh + r$sha), 0)
  pk <- function(r, k) stats::pnorm(r$pred / sqrt(r$sig^2 + k * pvar(r)))
  fitk <- function(r) { y <- as.numeric(r$act > 0); stats::optimize(function(k) ll(clamp(pk(r, k)), y), c(0, 3))$minimum }
  rp <- rows[rows$mode == "pre", ]; ri <- rows[rows$mode == best_mode & rows$lambda == best, ]
  k_pre <- fitk(rp); k_in <- fitk(ri)
  yv <- function(r) as.numeric(r$act > 0)
  old_pre <- stats::pnorm(rp$pred / sqrt(rp$sig^2 + (rp$poss / 100)^2 * (rp$vh + rp$va)))   # the w1.5 formula
  prob_check <- data.frame(what = c("preseason, w1.5 spread", "preseason, fitted spread", "in-season, fitted spread"),
                           logloss = c(ll(clamp(old_pre), yv(rp)), ll(clamp(pk(rp, k_pre)), yv(rp)), ll(clamp(pk(ri, k_in)), yv(ri))),
                           brier = c(mean((old_pre - yv(rp))^2), mean((pk(rp, k_pre) - yv(rp))^2), mean((pk(ri, k_in) - yv(ri))^2)))
  bins_of <- function(r, p) {
    pf <- pmax(p, 1 - p); won <- (p > .5) == (r$act > 0)
    br <- cut(pf, c(.5, .6, .7, .8, .9, .95, 1), include.lowest = TRUE)
    b <- data.frame(p = tapply(pf, br, mean), actual = tapply(won, br, mean), n = as.vector(table(br)))
    b[!is.na(b$p), ]
  }
  # ---- w1.10: leave one season out ------------------------------------------------
  # Everything above is chosen AND scored on the same games, so its log loss is
  # optimistic. Here each season is held out in turn: the setting (flat/scaled and
  # lambda), the probit scale and the spread weights k_pre / k_in are chosen on the
  # other seasons, then scored on the held-out one. The pooled held-out log loss is
  # what choosing these numbers actually delivers.
  keyof <- function(r) paste(r$mode, r$lambda)
  rows$key <- keyof(rows); setk <- unique(rows$key[is.finite(rows$lambda)])
  loso <- NULL; held <- list()
  for (sn in unique(rows$season)) {
    tr <- rows[rows$season != sn, ]; te <- rows[rows$season == sn, ]
    one <- function(k, d) { r <- d[d$key == k, ]; y <- as.numeric(r$act > 0)
      sc <- stats::optimize(function(s) ll(clamp(stats::pnorm(r$pred / s)), y), c(4, 30))$minimum
      list(sc = sc, ll = ll(clamp(stats::pnorm(r$pred / sc)), y)) }
    tl <- vapply(setk, function(k) one(k, tr)$ll, 0); kb <- setk[which.min(tl)]
    sc_b <- one(kb, tr)$sc; rb <- te[te$key == kb, ]; yb <- as.numeric(rb$act > 0)
    rpt <- tr[tr$mode == "pre", ]; sc_p <- one("pre Inf", tr)$sc; rpe <- te[te$mode == "pre", ]; ype <- as.numeric(rpe$act > 0)
    kp <- fitk(rpt); kin <- fitk(tr[tr$key == kb, ])
    pit <- function(r, k) clamp(pk(r, k)); 
    loso <- rbind(loso, data.frame(season = sn, n_pre = nrow(rpe), n_in = nrow(rb), pick = kb,
      ll_pre_scale = ll(clamp(stats::pnorm(rpe$pred / sc_p)), ype), ll_pre_spread = ll(pit(rpe, kp), ype),
      ll_in_scale = ll(clamp(stats::pnorm(rb$pred / sc_b)), yb), ll_in_spread = ll(pit(rb, kin), yb),
      k_pre = kp, k_in = kin, stringsAsFactors = FALSE))
  }
  wm <- function(x, w) sum(x * w) / sum(w)
  loso_sum <- c(pre_scale = wm(loso$ll_pre_scale, loso$n_pre), pre_spread = wm(loso$ll_pre_spread, loso$n_pre),
                in_scale = wm(loso$ll_in_scale, loso$n_in), in_spread = wm(loso$ll_in_spread, loso$n_in))
  list(summary = summ, lambda = best, mode = best_mode, scale = fin$scale[bi],
       bins = bins_of(ri, pk(ri, k_in)), bins_pre = bins_of(rp, pk(rp, k_pre)),
       k_pre = k_pre, k_in = k_in, prob_check = prob_check, pre_only = summ[!is.finite(summ$lambda), ],
       loso = loso, loso_ll = loso_sum)
}

# =============================================================================
# In-season player layer (w1.7)
# Once the season's box scores exist, three things use them:
#  * roster check   -- who is actually playing vs. the prep sheet (Data checks)
#  * availability   -- a player with no minutes in her team's last
#                      PW_OUT_GAMES games is treated as out; forward minutes are
#                      re-spread over the players who are playing. The rating
#                      from results reflects the lineup that played, so the
#                      team is shifted by the value of the lineup change.
#  * player values  -- each player's value is updated from her box scores this
#                      season (weighted by minutes played), and the preseason
#                      prior moves with the updated roster value.
# How much weight each gets is fitted by replaying 2020-2026 two weeks at a time
# (pw_calibrate_players); a weight of zero switches a piece off.
# =============================================================================
PW_KEEP_REPLAY <- FALSE              # TRUE keeps the replay inputs in the calibration cache (development)
PW_INS_K     <- c(150, 400)          # minutes at which this season's box line counts as much as the projection
PW_INS_A1    <- c(0, 0.25, 0.5, 0.75, 1)  # weight on the lineup (availability / rotation) shift
PW_INS_START <- c(0, 28, 42)         # days into the season before the lineup shift switches on
PW_INS_A2    <- 0                    # weight on re-valued players in the prior (tested in w1.7: never helped)
PW_INS_A3    <- c(0, 0.25, 0.5, 0.75, 1)  # weight on the observed rotation in the prior (w1.8)
PW_INS_G0    <- 4                    # team games before observed minutes outweigh projected minutes
PW_OUT_GAMES <- 3                    # no minutes in this many straight team games = out
PW_RECENT    <- 5                    # team games that define the current rotation

# one row per player per game (players listed but not playing have min = 0)
pw_player_games <- function(yr, pb = NULL) {
  if (is.null(pb)) pb <- pw_pq("espn_womens_college_basketball_player_boxscores", sprintf("player_box_%d.parquet", yr), refresh = yr >= PRED_SEASON)
  if (is.null(pb) || !nrow(pb)) return(NULL)
  pb <- pb[!is.na(pb$athlete_id) & !is.na(pb$team_id), ]
  mn <- pw_num(pb$minutes); mn[is.na(mn)] <- 0
  map <- c(pts = "points", fgm = "field_goals_made", fga = "field_goals_attempted",
           fg3m = "three_point_field_goals_made", fg3a = "three_point_field_goals_attempted",
           ftm = "free_throws_made", fta = "free_throws_attempted", reb = "rebounds",
           ast = "assists", stl = "steals", blk = "blocks", tov = "turnovers",
           oreb = "offensive_rebounds", dreb = "defensive_rebounds", pf = "fouls")
  X <- sapply(map, function(v) if (is.null(pb[[v]])) rep(0, nrow(pb)) else na0(pw_num(pb[[v]])))
  miss <- X[, "oreb"] + X[, "dreb"] == 0 & X[, "reb"] > 0
  X[miss, "oreb"] <- 0.3 * X[miss, "reb"]; X[miss, "dreb"] <- X[miss, "reb"] - X[miss, "oreb"]
  out <- data.frame(game_id = as.character(pb$game_id), date = as.Date(pb$game_date),
                    athlete_id = as.character(pb$athlete_id), team_id = as.character(pb$team_id),
                    name = pb$athlete_display_name, pos = pb$athlete_position_abbreviation, min = mn,
                    X, stringsAsFactors = FALSE)
  out[!duplicated(paste(out$athlete_id, out$game_id)), ]
}

# minutes per team game rescaled to 200, nobody above 38
pw_norm200 <- function(m, team) {
  s <- ave(m, team, FUN = sum); m <- ifelse(s > 0, m * 200 / s, 0)
  for (it in 1:6) {
    ex <- pmax(m - 38, 0); if (sum(ex) < 1e-6) break
    m <- pmin(m, 38); room <- ifelse(m < 38, m, 0)
    add <- ave(ex, team, FUN = sum); rs <- ave(room, team, FUN = sum)
    m <- m + ifelse(rs > 0, add * room / rs, 0)
  }
  m
}

# Components at one point in the season.
#   pgm : per-game rows for games so far       pf : preseason frame (athlete_id,
#   team_id, pvO, pvD, pm)                     rat: current ratings (team, O, D, em, T, tempo)
# Returns per-team shifts (em units, split O / D) for each K, and the player table.
pw_ins_components <- function(pgm, pf, rat, ctr, vm, Ks = PW_INS_K, force_out = NULL) {
  teams <- rat$team
  pgm <- pgm[pgm$team_id %in% teams, ]
  if (!nrow(pgm)) return(NULL)
  gl <- unique(pgm[, c("team_id", "game_id", "date")])
  tg <- table(factor(gl$team_id, levels = teams))
  gl <- gl[order(gl$team_id, -as.numeric(gl$date)), ]
  gl$k <- ave(seq_len(nrow(gl)), gl$team_id, FUN = seq_along)
  lastk <- paste(gl$team_id, gl$game_id)[gl$k <= PW_OUT_GAMES]
  pl <- pgm[pgm$min > 0, ]
  recent <- unique(paste(pl$athlete_id, pl$team_id)[paste(pl$team_id, pl$game_id) %in% lastk])
  key <- paste(pl$athlete_id, pl$team_id, sep = "|")
  agg <- rowsum(cbind(min = pl$min, gp = 1, as.matrix(pl[, PW_STATS])), key)
  ps <- data.frame(athlete_id = sub("\\|.*", "", rownames(agg)), team_id = sub(".*\\|", "", rownames(agg)), agg,
                   stringsAsFactors = FALSE)
  ps$pos <- pl$pos[match(ps$athlete_id, pl$athlete_id)]
  pv <- pw_player_values(ps, rat, setNames(rat$tempo, rat$team), ctr, vm)
  U <- merge(pf[pf$team_id %in% teams, c("athlete_id", "team_id", "pvO", "pvD", "pm")],
             pv[, c("athlete_id", "team_id", "min", "vO", "vD")], by = c("athlete_id", "team_id"), all = TRUE)
  # somebody playing who wasn't in the preseason frame: a lower-quartile player on that team
  lo <- function(v) { q <- tapply(pf[[v]], pf$team_id, function(z) stats::quantile(z, PW_INS_NEWQ, na.rm = TRUE)); q[U$team_id] }
  nb <- is.na(U$pvO)
  U$pvO[nb] <- lo("pvO")[nb]; U$pvD[nb] <- lo("pvD")[nb]; U$pm[nb] <- 0
  U$pvO[is.na(U$pvO)] <- 0; U$pvD[is.na(U$pvD)] <- 0
  U$min[is.na(U$min)] <- 0; U$new_on_box <- nb
  n <- as.numeric(tg[U$team_id])
  U$m_obs <- U$min / pmax(n, 1)
  U$out <- n >= PW_OUT_GAMES + 1 & !paste(U$athlete_id, U$team_id) %in% recent
  # w1.9: players a current ESPN listing no longer has (and who haven't played
  # for the team) are out from the first game, not only after PW_OUT_GAMES.
  # NULL in the historical replay, so the calibration is unchanged.
  if (length(force_out)) U$out <- U$out | (paste(U$athlete_id, U$team_id) %in% force_out & U$min == 0)
  # forward minutes: her share over the team's last PW_RECENT games (zero if she
  # sat), so the shift reflects the lineup now vs. the lineup behind the results.
  # Before a team has PW_INS_G0 games, projected minutes carry the weight.
  rk <- paste(gl$team_id, gl$game_id)[gl$k <= PW_RECENT]
  rmin <- tapply(pl$min[paste(pl$team_id, pl$game_id) %in% rk], paste(pl$athlete_id, pl$team_id)[paste(pl$team_id, pl$game_id) %in% rk], sum)
  nr <- pmin(n, PW_RECENT)
  U$m_recent <- ifelse(nr > 0, na0(as.numeric(rmin[paste(U$athlete_id, U$team_id)])) / pmax(nr, 1), 0)
  mf <- ifelse(n >= PW_INS_G0, U$m_recent, (PW_INS_G0 * U$pm + n * U$m_recent) / (PW_INS_G0 + n)); mf[U$out] <- 0
  U$m_fwd <- pw_norm200(mf, U$team_id)
  U$m_past <- ifelse(n > 0, pw_norm200(U$m_obs, U$team_id), U$m_fwd)
  U$w_pre <- pw_norm200(U$pm, U$team_id)
  res <- list()
  for (K in Ks) {
    bO <- ifelse(U$min > 0, (K * U$pvO + U$min * U$vO) / (K + U$min), U$pvO)
    bD <- ifelse(U$min > 0, (K * U$pvD + U$min * U$vD) / (K + U$min), U$pvD)
    dm <- (U$m_fwd - U$m_past) / 40
    f <- function(x) { z <- tapply(x, factor(U$team_id, levels = teams), sum); z[is.na(z)] <- 0; z }
    # w1.8: observed rotation so far, valued at PRESEASON player values, vs. the
    # projected rotation -- moves the preseason prior toward who actually plays
    dr <- (U$m_past - U$w_pre) / 40
    res[[as.character(K)]] <- list(aO = f(dm * bO), aD = f(dm * bD), rO = f(dr * U$pvO), rD = f(dr * U$pvD),
                                   vO = f(U$w_pre / 40 * (bO - U$pvO)), vD = f(U$w_pre / 40 * (bD - U$pvD)),
                                   bO = bO, bD = bD)
  }
  list(U = U, comp = res, tg = tg)
}

# Replay 2020-2026 (same 14-day checkpoints and prior weight as the in-season
# calibration) and choose K, a1, a2 by log loss on the games that follow each
# checkpoint. A leave-one-season-out version of the choice is reported too.
pw_calibrate_players <- function(HG, PRE, PF, gm, ins, H, vm, rows = NULL, fc = NULL, VM = NULL) {
  if (is.null(rows)) {
  for (yr in names(PRE)) {
    if (is.null(PF[[yr]])) next
    gmy <- if (!is.null(fc)) fc$gm[[yr]] else gm; vmy <- if (!is.null(VM[[yr]])) VM[[yr]] else vm   # w1.10: fold-frozen
    g <- HG[[yr]]; pr <- PRE[[yr]]
    g <- g[g$home %in% pr$team & g$away %in% pr$team & g$poss > 40, ]; g <- g[order(g$date), ]
    pgm_all <- pw_player_games(as.integer(yr)); if (is.null(pgm_all)) next
    teams <- pr$team; sdv <- setNames(pr$sd, teams)
    prior <- list(O = setNames(pr$O, teams), D = setNames(pr$D, teams), T = setNames(pr$T, teams))
    L <- ins$lambda
    lam <- if (identical(ins$mode, "scaled")) L * mean(sdv^2) / sdv^2 else setNames(rep(L, length(teams)), teams)
    ctr <- H[[as.character(as.integer(yr) - 1)]]$ctr; if (is.null(ctr)) ctr <- H[[yr]]$ctr
    pf <- PF[[yr]]
    cps <- seq(min(g$date) + 14, max(g$date), by = 14)
    for (cp in as.list(cps)) {
      past <- g[g$date < cp, ]; nxt <- g[g$date >= cp & g$date < cp + 14, ]
      if (!nrow(nxt) || nrow(past) < 20) next
      fit <- pw_fit_ratings(past, teams, lambda = lam, prior = prior, fit_h = FALSE, h_fixed = gmy$h)
      rat <- data.frame(team = teams, O = fit$O, D = fit$D, em = fit$em, T = fit$T, tempo = fit$tmu[1] + fit$T, stringsAsFactors = FALSE)
      cc <- pw_ins_components(pgm_all[pgm_all$date < cp, ], pf, rat, ctr, vmy)
      if (is.null(cc)) next
      em <- setNames(fit$em, teams); Tm <- setNames(fit$T, teams); sh <- setNames(lam / (lam + fit$games), teams)
      e <- pw_game_expect(em[nxt$home], em[nxt$away], Tm[nxt$home], Tm[nxt$away], ifelse(nxt$neutral, 0, 1),
                          list(tmu = fit$tmu[1], h = gmy$h))
      r <- data.frame(season = yr, day = as.numeric(cp - min(g$date)), pred = e$margin, act = nxt$hs - nxt$as, poss = e$poss)
      for (K in names(cc$comp)) {
        z <- cc$comp[[K]]
        r[[paste0("A", K)]] <- (z$aO + z$aD)[nxt$home] - (z$aO + z$aD)[nxt$away]
        r[[paste0("V", K)]] <- (sh * (z$vO + z$vD))[nxt$home] - (sh * (z$vO + z$vD))[nxt$away]
        r[[paste0("R", K)]] <- (sh * (z$rO + z$rD))[nxt$home] - (sh * (z$rO + z$rD))[nxt$away]
      }
      rows <- rbind(rows, r)
    }
  }
  }
  if (is.null(rows)) return(NULL)
  rows_all <- rows
  rows <- rows[rows$act != 0, ]
  y <- as.numeric(rows$act > 0)
  ll <- function(p, y) -mean(y * log(p) + (1 - y) * log(1 - p))
  clamp <- function(p) pmin(pmax(p, 1e-4), 1 - 1e-4)
  grid <- expand.grid(K = PW_INS_K, a1 = PW_INS_A1, a2 = PW_INS_A2, start = PW_INS_START, a3 = PW_INS_A3)
  grid <- grid[!(grid$a1 == 0 & grid$start > 0), ]; rownames(grid) <- NULL
  marg <- function(i, idx = TRUE) { K <- as.character(grid$K[i]); on <- as.numeric(rows$day[idx] >= grid$start[i])
    rows$pred[idx] + (on * grid$a1[i] * rows[[paste0("A", K)]][idx] + grid$a2[i] * rows[[paste0("V", K)]][idx] +
                      grid$a3[i] * rows[[paste0("R", K)]][idx]) * rows$poss[idx] / 100 }
  score <- function(i, fit_idx, ev_idx) {
    m1 <- marg(i, fit_idx); s <- stats::optimize(function(s) ll(clamp(stats::pnorm(m1 / s)), y[fit_idx]), c(4, 30))$minimum
    m2 <- marg(i, ev_idx); p <- clamp(stats::pnorm(m2 / s))
    c(ll = ll(p, y[ev_idx]), brier = mean((p - y[ev_idx])^2), acc = mean((p > .5) == (y[ev_idx] == 1)), mae = mean(abs(m2 - rows$act[ev_idx])))
  }
  all <- rep(TRUE, nrow(rows)); early <- rows$day <= 42
  G <- cbind(grid, t(sapply(seq_len(nrow(grid)), function(i) score(i, all, all))))
  best <- which.min(G$ll); base <- which(grid$a1 == 0 & grid$a2 == 0 & grid$start == 0 & grid$a3 == 0)[1]
  # the w1.7 model (lineup shift only) for comparison
  w17 <- grid$a3 == 0; b17 <- which(w17)[which.min(G$ll[w17])]
  # leave one season out: choose on the other seasons, score on the held-out one
  loso <- NULL
  for (s in unique(rows$season)) {
    tr <- rows$season != s; te <- !tr
    sc <- sapply(seq_len(nrow(grid)), function(i) score(i, tr, tr)["ll"])
    pick <- which.min(sc)
    loso <- rbind(loso, data.frame(season = s, n = sum(te), pick = pick,
                                   ll_pick = score(pick, tr, te)["ll"], ll_base = score(base, tr, te)["ll"],
                                   ll_pick_early = if (any(te & early)) score(pick, tr, te & early)["ll"] else NA,
                                   ll_base_early = if (any(te & early)) score(base, tr, te & early)["ll"] else NA))
  }
  wm <- function(x, w) sum(x * w, na.rm = TRUE) / sum(w[!is.na(x)])
  ne <- tapply(early, rows$season, sum)[as.character(loso$season)]
  list(grid = G, best = as.list(grid[best, ]), n = nrow(rows), n_early = sum(early),
       base = G[base, c("ll", "brier", "acc", "mae")], chosen = G[best, c("ll", "brier", "acc", "mae")],
       early_base = score(base, all, early), early_chosen = score(best, all, early),
       loso = loso, loso_ll = wm(loso$ll_pick, loso$n), loso_base_ll = wm(loso$ll_base, loso$n),
       loso_ll_early = wm(loso$ll_pick_early, ne), loso_base_ll_early = wm(loso$ll_base_early, ne),
       w17 = G[b17, c("ll", "brier", "acc", "mae")],
       rows = if (isTRUE(PW_KEEP_REPLAY)) rows_all else NULL)
}

# Live in-season player layer: box scores so far vs. the prep-sheet projection.
# Returns the lineup shift per team (applied only once the replay-chosen start
# day is reached) plus roster-check lists for the Data checks panel.
pw_inseason_players <- function(pgm, players, teams, rt, cal, gm_now, er = NULL) {
  cp <- cal$inseason$player; if (is.null(cp)) return(NULL)
  K <- cp$best$K; a1 <- cp$best$a1; start <- cp$best$start
  pf <- players[!players$source %in% "pad", ]
  pf$athlete_id <- as.character(pf$athlete_id)
  if (is.null(pf$pid)) pf$pid <- pf$athlete_id
  pgm <- pgm[pgm$team_id %in% teams$espn_id, ]
  if (!nrow(pgm)) return(NULL)
  tname <- setNames(teams$team, teams$espn_id)
  bx <- pgm[!duplicated(paste(pgm$athlete_id, pgm$team_id)), c("athlete_id", "team_id", "name")]
  # w1.9: staged identity linking (name, alias, nickname, unique name elsewhere);
  # ambiguous cases go to the review file instead of being merged
  lk <- pw_link_box_ids(pf, bx); pf <- lk$pf
  # w1.9: which roster each team uses now, and who a current ESPN listing drops
  rs <- pw_roster_sources(teams$espn_id, pgm, er)
  live <- rs$team[rs$source == "live"]
  force_out <- character(0); joined <- character(0)
  if (length(live) && !is.null(er)) {
    erl <- er[er$team_id %in% live, ]
    gone <- pf[pf$team_id %in% live & !paste(pf$athlete_id, pf$team_id) %in% paste(erl$athlete_id, erl$team_id) &
                 !paste(pf$athlete_id, pf$team_id) %in% paste(pgm$athlete_id[pgm$min > 0], pgm$team_id[pgm$min > 0]), ]
    force_out <- paste(gone$athlete_id, gone$team_id)
    nw <- erl[!paste(erl$athlete_id, erl$team_id) %in% paste(pf$athlete_id, pf$team_id) & !erl$athlete_id %in% pf$athlete_id, ]
    joined <- if (nrow(nw)) paste0(nw$name, " (", tname[nw$team_id], ")") else character(0)
  }
  # somebody on the sheet at one school, in box scores at another
  mv <- merge(pf[, c("athlete_id", "name", "team_id")], bx[, c("athlete_id", "team_id")], by = "athlete_id", suffixes = c("_sheet", "_box"))
  mv <- mv[mv$team_id_sheet != mv$team_id_box & mv$team_id_box %in% names(tname), ]
  mv <- mv[!mv$athlete_id %in% pf$athlete_id[paste(pf$athlete_id, pf$team_id) %in% paste(bx$athlete_id, bx$team_id)], ]
  rat <- data.frame(team = rt$team, O = rt$O, D = rt$D, em = rt$em, T = rt$T, tempo = gm_now$tmu + rt$T, stringsAsFactors = FALSE)
  ctr <- cal$H[[length(cal$H)]]$ctr
  cc <- pw_ins_components(pgm, pf[, c("athlete_id", "team_id", "pvO", "pvD", "pm")], rat, ctr, cal$vm, Ks = K, force_out = force_out)
  if (is.null(cc)) return(NULL)
  U <- cc$U; z <- cc$comp[[as.character(K)]]
  asof <- max(pgm$date); day <- as.numeric(asof - min(pgm$date))
  on <- day >= start
  U$name <- pf$name[match(paste(U$athlete_id, U$team_id), paste(pf$athlete_id, pf$team_id))]
  U$name[is.na(U$name)] <- bx$name[match(U$athlete_id[is.na(U$name)], bx$athlete_id)]
  n <- as.numeric(cc$tg[U$team_id])
  listed <- unique(paste(pgm$athlete_id, pgm$team_id))
  U$listed <- paste(U$athlete_id, U$team_id) %in% listed
  U$elsewhere <- U$athlete_id %in% mv$athlete_id & !U$listed
  U$playing_for <- tname[mv$team_id_box[match(U$athlete_id, mv$athlete_id)]]
  fmt <- function(d, extra = "") if (nrow(d)) paste0(d$name, " (", tname[d$team_id], extra, ")") else character(0)
  not_on_sheet <- U[U$new_on_box & U$min > 0 & !U$athlete_id %in% mv$athlete_id, ]
  not_on_sheet <- not_on_sheet[order(-not_on_sheet$min), ]
  # out = has appeared for her team this season, then no minutes in the last few games
  outp <- U[U$out & U$listed & U$pm >= 10, ]; outp <- outp[order(-outp$pm), ]
  nev <- pf[!paste(pf$athlete_id, pf$team_id) %in% listed & !pf$athlete_id %in% mv$athlete_id & as.numeric(cc$tg[pf$team_id]) >= 5, ]
  a3 <- if (is.null(cp$best$a3)) 0 else cp$best$a3
  list(shift_O = if (on) a1 * z$aO else 0 * z$aO, shift_D = if (on) a1 * z$aD else 0 * z$aD, on = on, day = day, asof = asof, bO = z$bO, bD = z$bD,
       rot_O = a3 * z$rO, rot_D = a3 * z$rD, a3 = a3,
       start = start, a1 = a1, U = U, K = K, sheet_ids = pf[, c("athlete_id", "pid", "team_id", "name")], review = lk$review, sources = rs,
       checks = list(asof = format(asof), day = day, shift_on = on, start_day = start,
                     # paste0() on zero rows still returns " ()" (zero-length args are recycled
                     # against the literals), which printed as an empty entry; guard each list
                     not_on_sheet = if (nrow(not_on_sheet)) paste0(not_on_sheet$name, " (", tname[not_on_sheet$team_id], ", ", round(not_on_sheet$min), " min)") else character(0),
                     out = if (nrow(outp)) paste0(outp$name, " (", tname[outp$team_id], ")") else character(0),
                     never_listed = fmt(nev),
                     elsewhere = if (nrow(mv)) paste0(mv$name, " (sheet: ", tname[mv$team_id_sheet], "; playing for ", tname[mv$team_id_box], ")") else character(0),
                     roster = list(live = sum(rs$games > 0), fresh = sum(rs$source == "live"),
                                   stale = unname(tname[rs$team[rs$games > 0 & rs$source == "box" & PW_ROSTER_MODE != "prep"]]),
                                   joined = joined,
                                   left = if (length(force_out)) { z <- pf[paste(pf$athlete_id, pf$team_id) %in% force_out, ]; paste0(z$name, " (", tname[z$team_id], ")") } else character(0)),
                     review = if (is.null(lk$review)) character(0) else paste0(lk$review$name, " (", tname[lk$review$team_id], "): ", lk$review$candidates, " -- ", lk$review$reason)))
}

# ---- the full historical calibration (cached once per season) ----------------
pw_calibrate <- function(inseason = TRUE) {
  message("  [predict] calibrating on ", min(HIST_SEASONS), "-", max(HIST_SEASONS), " (first run of the season takes a few minutes) ...")
  H <- list(); HG <- list()
  for (yr in HIST_SEASONS) {
    g <- pw_season_games(yr); if (is.null(g)) next
    rat <- pw_season_ratings(g); pace <- setNames(rat$tempo, rat$team)
    ps <- pw_player_seasons(yr)
    H[[as.character(yr)]] <- list(rat = rat, pace = pace, ps = ps, roster = attr(ps, "roster"), conf = pw_conf_groups(g))
    HG[[as.character(yr)]] <- g[g$d1h & g$d1a, ]
  }
  yrs <- as.integer(names(H))
  rows <- do.call(rbind, lapply(names(H), function(y) {
    tr <- pw_team_rate_rows(H[[y]]$ps, H[[y]]$rat, H[[y]]$pace); H[[y]]$ctr <<- tr$ctr
    cbind(tr$rows, season = as.integer(y)) }))
  vm <- pw_fit_value_model(rows)
  rec <- pw_read_recruit_history(); coach <- pw_read_coach_history()
  forms <- pw_team_forms(!is.null(coach) && any(coach$nc == 1))
  # walk-forward team frames. The box-score value model is refitted inside each
  # fold on earlier seasons only (w1.6), so no season is valued with
  # coefficients that saw its own results.
  TF <- NULL; TFo <- NULL; PF <- list(); VM <- list()
  for (T in yrs[-(1:2)]) {
    vmT <- pw_fit_value_model(rows[rows$season < T, ]); VM[[as.character(T)]] <- vmT
    HT <- pw_apply_values(H[as.character(yrs[yrs <= T])], vmT)
    sT <- yrs[yrs <= T][-1]
    fr <- pw_backtest_frame(pw_transition_rows(HT, sT, rosters = TRUE),  T, HT, rec, coach)
    PF[[as.character(T)]] <- attr(fr, "players"); TF <- rbind(TF, fr)
    TFo <- rbind(TFo, pw_backtest_frame(pw_transition_rows(HT, sT, rosters = FALSE), T, HT, NULL, coach))
  }
  ev <- pw_backtest_eval(TF, forms); evo <- pw_backtest_eval(TFo, forms)
  bt <- ev$bt; res <- ev$res
  bt$rmse_oracle <- evo$bt$rmse[match(bt$season, evo$bt$season)]
  sd_fit <- coef(lm(e2 ~ nw, res))
  sc2 <- pw_conf_var(res)
  hi_tr <- res$tr >= 0.3
  bt_transfer <- list(n = sum(hi_tr), rmse = sqrt(mean(res$e2[hi_tr])), rmse_carry = sqrt(mean(res$c2[hi_tr])))
  boot <- pw_boot(res); boot_oracle <- pw_boot(evo$res)
  # production fits: every season, full-sample value model, full rosters
  H <- pw_apply_values(H, vm)
  TR <- pw_transition_rows(H, yrs[-1], rosters = TRUE)
  pm <- pw_fit_player_models(TR); TRp <- pw_predict_players(TR, pm); mm <- pw_fit_minutes(TRp)
  # game model constants from the last four seasons (cross-fitted spread)
  gsg <- pw_game_sigma(HG, H, tail(names(HG), 4))
  gm <- list(h = gsg$h, tmu = H[[tail(names(H), 1)]]$rat$tmu[1], sigma = unname(gsg$sigma), sigma_crossfit = gsg$sigma_crossfit)
  # w1.10: each replayed season's preseason spread, game constants and value model
  # come from the OTHER seasons (see pw_fold_constants); production keeps the all-season fits
  fc <- pw_fold_constants(res, HG, H, names(ev$PRE))
  PRE <- setNames(lapply(names(ev$PRE), function(y) { p <- ev$PRE[[y]]; sf <- fc$sd_fit[[y]]; p$sd <- sqrt(pmax(sf[1] + sf[2] * p$nw, 9)); p }), names(ev$PRE))
  tune <- if (PW_TUNE) pw_tune_nested() else NULL
  if (!inseason) return(list(backtest = bt, bt_transfer = bt_transfer, boot = boot, boot_oracle = boot_oracle, sc2 = sc2,
                             TR = TR, H = H, TF = TF, TFo = TFo, gm = gm, sd_fit = sd_fit, res = res))
  message("  [predict] calibrating in-season updating ...")
  ins <- pw_calibrate_inseason(HG, PRE, gm, sc2, fc)
  message("  [predict] calibrating the in-season player layer ...")
  ins$player <- tryCatch(pw_calibrate_players(HG, PRE, PF, gm, ins, H, vm, fc = fc, VM = VM), error = function(e) { message("  WARNING: player layer calibration failed: ", conditionMessage(e)); NULL })
  if (isTRUE(PW_KEEP_REPLAY)) ins$replay <- list(HG = HG[names(PRE)], PRE = PRE, PF = PF, ctr = lapply(H, function(s) s$ctr))
  # keep only what the projection needs
  keep <- tail(names(H), 4)
  Hk <- lapply(H[keep], function(s) list(rat = s$rat, ctr = s$ctr,
       pv = s$pv[, c("season", "athlete_id", "name", "pos", "team_id", "min", "gp", "pts", "fga", "fta", "tov", "vO", "vD", "v", "rawO", "rawD", "mpg", "w", "team_em")]))
  fO <- lm(forms$O, TF); fD <- lm(forms$D, TF); fT <- lm(forms$T, TF)
  list(version = PW_CAL_VERSION, seasons = range(yrs), H = Hk, vm = vm,
       pm = lapply(pm, pw_slim), mm = list(s1 = pw_slim(mm$s1), tmpl = mm$tmpl, s2 = pw_slim(mm$s2), avail = mm$avail), mk = PW_MIN_K,
       tO = pw_slim(fO), tD = pw_slim(fD), tT = pw_slim(fT), with_coach = !is.null(coach) && any(coach$nc == 1),
       team_coef = list(O = coef(fO), D = coef(fD), T = coef(fT)),
       sd_fit = sd_fit, sc2 = sc2, gm = gm, backtest = bt, bt_transfer = bt_transfer, boot = boot, boot_oracle = boot_oracle,
       inseason = ins, pos_alpha = PW_POS_ALPHA, recruit_history = !is.null(rec), tune = tune,
       team_hca = pw_team_hca(HG, H, max(yrs) + 1),
       player_coef = list(O = pm$O$coefficients, D = pm$D$coefficients),
       player_r2 = c(O = summary(lm(PW_FORM_O, TR[TR$newc == 0 & TR$min >= 40, ], weights = pmin(min, 800)))$r.squared),
       n_transitions = sum(TR$min > 0), n_rostered = nrow(TR), n_team_seasons = nrow(TF))
}

# ---- nested tuning study (PW_TUNE) ----------------------------------------------
# For each setting on the grid, run the whole walk-forward backtest. Then, for
# each season, pick the setting that did best on EARLIER seasons only and score
# it on that season. The nested error is what the tuning procedure itself
# delivers; the gap to the best single setting is the optimism of tuning on the
# backtest.
PW_TUNE_GRID <- expand.grid(dshrink = c(0, 0.25, 0.5, 1), pos_alpha = c(0, 1))
pw_tune_nested <- function() {
  env <- environment(pw_player_values); old <- c(get("PW_DSHRINK", env), get("PW_POS_ALPHA", env))
  on.exit({ assign("PW_DSHRINK", old[1], env); assign("PW_POS_ALPHA", old[2], env); assign("PW_TUNE", TRUE, env) })
  assign("PW_TUNE", FALSE, env)
  per <- list()
  for (i in seq_len(nrow(PW_TUNE_GRID))) {
    assign("PW_DSHRINK", PW_TUNE_GRID$dshrink[i], env); assign("PW_POS_ALPHA", PW_TUNE_GRID$pos_alpha[i], env)
    message("  [predict] tuning ", i, "/", nrow(PW_TUNE_GRID))
    b <- pw_calibrate(inseason = FALSE)$backtest
    per[[i]] <- data.frame(setting = i, season = b$season, mse = b$rmse^2, n = b$n)
  }
  P <- do.call(rbind, per); ss <- sort(unique(P$season))
  nested <- NULL
  for (T in ss[-1]) {
    past <- P[P$season < T, ]; sc <- tapply(past$mse * past$n, past$setting, sum) / tapply(past$n, past$setting, sum)
    pick <- as.integer(names(which.min(sc)))
    nested <- rbind(nested, data.frame(season = T, pick = pick, mse = P$mse[P$season == T & P$setting == pick], n = P$n[P$season == T & P$setting == pick]))
  }
  ev <- ss[-1]; E <- P[P$season %in% ev, ]
  best <- tapply(E$mse * E$n, E$setting, sum) / tapply(E$n, E$setting, sum)
  list(grid = cbind(PW_TUNE_GRID, rmse = sqrt(as.vector(best))), nested_rmse = sqrt(sum(nested$mse * nested$n) / sum(nested$n)),
       best_single_rmse = sqrt(min(best)), picks = nested)
}


# =============================================================================
# Part 5b (w1.9) -- preseason snapshot, live-roster switch, identity linking,
# injuries, tip-off times and logged picks
# =============================================================================

# ---- preseason snapshot --------------------------------------------------------
# The prep sheet is the roster source only until the first D1-vs-D1 game. Every
# preseason run saves what it produced; once the season starts, runs read that
# frozen copy and never open the sheet, so late edits can't rewrite the prior the
# season's results are being compared against. PW_REFREEZE = TRUE (one run)
# rebuilds it from the sheet if a real error turns up after the start.
pw_snapshot_path <- function() file.path(OUT_DIR, PW_SNAPSHOT_FILE)
pw_save_snapshot <- function(P, prep, newc, mode) {
  snap <- list(version = PW_VERSION, built = format(Sys.time(), "%Y-%m-%d %H:%M"), mode = mode,
               sheet_md5 = unname(tools::md5sum(file.path(OUT_DIR, PREP_SHEET_FILE))),
               P = P, prep = prep, newc = newc)
  tmp <- paste0(pw_snapshot_path(), ".tmp"); saveRDS(snap, tmp)
  if (!file.rename(tmp, pw_snapshot_path())) { file.copy(tmp, pw_snapshot_path(), overwrite = TRUE); unlink(tmp) }
  f <- P$players
  cols <- intersect(c("pid", "athlete_id", "name", "team", "team_id", "status", "source", "matched", "prev_team", "cls",
                      "exp_years", "rank", "pm", "pm_disp", "pvO", "pvD", "pv", "note"), names(f))
  out <- f[order(f$team, -f$pm), cols]
  for (v in c("pm", "pm_disp", "pvO", "pvD", "pv")) if (!is.null(out[[v]])) out[[v]] <- round(out[[v]], 2)
  tryCatch(utils::write.csv(out, file.path(OUT_DIR, PW_SNAPSHOT_CSV), row.names = FALSE, fileEncoding = "UTF-8"),
           error = function(e) message("  WARNING: couldn't write ", PW_SNAPSHOT_CSV, ": ", conditionMessage(e)))
  snap
}

# every roster row's stable id and how it was linked to ESPN (written each run;
# copy rows into wbb_player_xwalk.csv to fix a link or add nicknames)
pw_write_roster_ids <- function(f) {
  x <- f[!f$source %in% "pad", ]
  out <- data.frame(pid = x$pid, espn_id = ifelse(grepl("^[0-9]+$", x$athlete_id), x$athlete_id, NA),
                    name = x$name, team = x$team, team_id = x$team_id, source = x$source, matched = x$matched,
                    aliases = if (is.null(x$aliases)) NA else x$aliases, stringsAsFactors = FALSE)
  tryCatch(utils::write.csv(out[order(out$team, out$name), ], file.path(OUT_DIR, PW_ROSTER_IDS_CSV), row.names = FALSE, fileEncoding = "UTF-8"),
           error = function(e) message("  WARNING: couldn't write ", PW_ROSTER_IDS_CSV, ": ", conditionMessage(e)))
}

# ---- this season's rosters: which source each team uses -----------------------
# ESPN's roster release for the coming season starts out as a copy of last
# season's, so a listing is trusted per team only once it holds PW_ROSTER_FRESH of
# the players that team's box scores have used, and lists a plausible number.
pw_espn_roster <- function(yr) {
  r <- tryCatch(pw_pq("espn_womens_college_basketball_rosters", sprintf("rosters_%d.parquet", yr), refresh = TRUE), error = function(e) NULL)
  if (is.null(r) || !nrow(r)) return(NULL)
  if (!is.null(r$season)) r <- r[as.integer(pw_num(r$season)) %in% yr, ]
  if (!nrow(r)) return(NULL)
  nm <- if (!is.null(r$display_name)) r$display_name else r$full_name
  data.frame(athlete_id = pw_id(r$athlete_id), team_id = as.character(pw_id(r$team_id)), name = nm, stringsAsFactors = FALSE)
}
pw_roster_sources <- function(ids, pgm, er) {
  played <- pgm[pgm$min > 0, ]
  ng <- tapply(pgm$game_id, factor(pgm$team_id, levels = ids), function(z) length(unique(z))); ng[is.na(ng)] <- 0
  out <- data.frame(team = ids, games = as.integer(ng), n_listed = 0L, overlap = NA_real_, source = "prep", stringsAsFactors = FALSE)
  for (i in seq_along(ids)) {
    if (out$games[i] == 0 || PW_ROSTER_MODE == "prep") next
    pl <- unique(played$athlete_id[played$team_id == ids[i]])
    li <- if (is.null(er)) character(0) else er$athlete_id[er$team_id == ids[i]]
    out$n_listed[i] <- length(li)
    out$overlap[i] <- if (length(pl)) mean(pl %in% li) else NA
    fresh <- length(li) >= PW_ROSTER_SIZE[1] && length(li) <= PW_ROSTER_SIZE[2] && isTRUE(out$overlap[i] >= PW_ROSTER_FRESH)
    out$source[i] <- if (fresh || (PW_ROSTER_MODE == "live" && length(li))) "live" else "box"
  }
  out
}

# ---- identity: sheet rows <-> this season's box scores ---------------------------
# Stages, each run for every unlinked row before the next: exact name on the same
# team, a hand-kept alias (wbb_player_xwalk.csv), then same last name + same first
# three letters (Madi/Madison). A box-score player claimed by two sheet rows in the
# same stage, or a row with several candidates, goes to the review file instead of
# being merged. Last, a row with no ESPN id is linked by exact name anywhere in
# D1 when that name is unique (moved schools after the sheet was frozen).
pw_first3 <- function(x) substr(pw_norm_name(sub("\\s.*", "", trimws(as.character(x)))), 1, 3)
pw_link_box_ids <- function(pf, bx) {
  pf$link <- ifelse(pf$athlete_id %in% bx$athlete_id, "id", NA_character_)
  bx$key <- pw_norm_name(bx$name); bx$ln <- pw_last_name(bx$name); bx$f3 <- pw_first3(bx$name)
  pkey <- pw_norm_name(pf$name); pln <- pw_last_name(pf$name); pf3 <- pw_first3(pf$name)
  al <- if (is.null(pf$aliases)) rep(NA_character_, nrow(pf)) else pf$aliases
  review <- list()
  claim <- function(stage, k) {
    cb <- which(bx$team_id == pf$team_id[k] & !bx$athlete_id %in% pf$athlete_id[!is.na(pf$link)])
    if (!length(cb)) return(integer(0))
    hit <- switch(stage,
      name = cb[bx$key[cb] == pkey[k]],
      alias = { if (is.na(al[k]) || !nzchar(al[k])) integer(0) else {
                  a <- trimws(strsplit(al[k], "\\|")[[1]]); full <- pw_norm_name(a[grepl("\\s", a)]); first <- pw_norm_name(a[!grepl("\\s", a)])
                  cb[bx$key[cb] %in% full | (bx$ln[cb] == pln[k] & pw_norm_name(sub("\\s.*", "", bx$name[cb])) %in% first)] } },
      nickname = cb[bx$ln[cb] == pln[k] & bx$f3[cb] == pf3[k] & nzchar(pln[k])])
    hit
  }
  for (stage in c("name", "alias", "nickname")) {
    todo <- which(is.na(pf$link))
    if (!length(todo)) break
    hits <- lapply(todo, function(k) claim(stage, k))
    one <- vapply(hits, length, 1L) == 1
    got <- rep(NA_integer_, length(todo)); got[one] <- vapply(hits[one], `[`, 1L, 1)
    dup <- !is.na(got) & got %in% got[duplicated(got) & !is.na(got)]
    for (i in which(one & !dup)) { k <- todo[i]; pf$athlete_id[k] <- bx$athlete_id[got[i]]; pf$link[k] <- stage }
    for (i in which(vapply(hits, length, 1L) > 1 | dup)) {
      k <- todo[i]
      review[[length(review) + 1]] <- data.frame(pid = pf$pid[k], name = pf$name[k], team_id = pf$team_id[k],
        candidates = paste(unique(bx$name[hits[[i]]]), collapse = " | "),
        reason = if (dup[i]) paste0("two sheet rows match the same box-score player (", stage, ")") else paste0("several box-score players match (", stage, ")"),
        stringsAsFactors = FALSE)
      pf$link[k] <- "review"
    }
  }
  # unique exact name anywhere, for rows that never had an ESPN id
  syn <- which(is.na(pf$link) & !grepl("^[0-9]+$", pf$athlete_id))
  if (length(syn)) {
    nk <- table(bx$key)
    for (k in syn) {
      j <- which(bx$key == pkey[k] & !bx$athlete_id %in% pf$athlete_id)
      if (length(j) == 1 && nk[[pkey[k]]] == 1) { pf$athlete_id[k] <- bx$athlete_id[j]; pf$link[k] <- "name (other team)" }
    }
  }
  # possible matches worth a look: unlinked sheet row + unlinked box player, same team and last name
  for (k in which(is.na(pf$link))) {
    j <- which(bx$team_id == pf$team_id[k] & bx$ln == pln[k] & !bx$athlete_id %in% pf$athlete_id)
    if (length(j)) review[[length(review) + 1]] <- data.frame(pid = pf$pid[k], name = pf$name[k], team_id = pf$team_id[k],
      candidates = paste(unique(bx$name[j]), collapse = " | "), reason = "same team and last name, different first name",
      stringsAsFactors = FALSE)
  }
  pf$link[pf$link %in% "review"] <- NA
  list(pf = pf, review = if (length(review)) do.call(rbind, review) else NULL)
}

# ---- injuries (wbb_injuries.csv) -------------------------------------------------
# One row per injury: athlete_id (optional), name, team, status (Out / Doubtful /
# Questionable / Limited), expected_return (date, "season" or blank), out_since,
# minutes_cap, injury, source, updated. See the README for how each is used.
pw_read_injuries <- function(teams, f, pgm = NULL, today = Sys.Date()) {
  path <- file.path(OUT_DIR, PW_INJURY_FILE)
  res <- list(file = file.exists(path), rows = 0L, tab = NULL, active = character(0), returned = character(0),
              stale = character(0), unmatched = character(0))
  x <- pw_read_opt_csv(PW_INJURY_FILE)
  if (is.null(x)) return(res)
  for (v in c("athlete_id", "name", "team", "status", "expected_return", "out_since", "minutes_cap", "injury", "updated"))
    if (is.null(x[[v]])) x[[v]] <- NA_character_
  x <- x[!(is.na(x$name) | !nzchar(trimws(x$name))) | !is.na(x$athlete_id), ]
  res$rows <- nrow(x)
  if (!nrow(x)) return(res)
  # blank cells and "season" are NA; ISO dates and US m/d/Y both read (as.Date() on a
  # blank string errors, which is what a CSV with an empty out_since hands it)
  pdate <- function(v) { v <- trimws(as.character(v)); v[!nzchar(v) %in% TRUE] <- NA
    d <- suppressWarnings(as.Date(v, format = "%Y-%m-%d")); d2 <- suppressWarnings(as.Date(v, format = "%m/%d/%Y")); d[is.na(d)] <- d2[is.na(d)]; d }
  tid <- ifelse(trimws(x$team) %in% teams$espn_id, trimws(x$team), teams$espn_id[match(trimws(x$team), teams$team)])
  x$team_id <- tid
  x$status <- tolower(trimws(x$status)); x$status[!x$status %in% names(PW_INJ_MISS)] <- "out"
  x$season_out <- tolower(trimws(x$expected_return)) %in% c("season", "out for season")
  x$ret <- pdate(x$expected_return); x$since <- pdate(x$out_since); x$upd <- pdate(x$updated)
  x$cap <- pw_num(x$minutes_cap)
  aid <- sub("\\.0+$", "", trimws(as.character(x$athlete_id))); aid[!nzchar(aid) %in% TRUE] <- NA
  # link to a roster row: id on that team, then id anywhere, then name on that team
  fk <- paste(pw_norm_name(f$name), f$team_id)
  k <- match(paste(aid, x$team_id), paste(f$athlete_id, f$team_id))
  k2 <- match(aid, f$athlete_id); k[is.na(k)] <- k2[is.na(k)]
  k2 <- match(aid, f$pid); k[is.na(k)] <- k2[is.na(k)]
  k3 <- match(paste(pw_norm_name(x$name), x$team_id), fk); k[is.na(k)] <- k3[is.na(k)]
  res$unmatched <- paste0(x$name[is.na(k)], " (", ifelse(is.na(x$team[is.na(k)]), "no team", x$team[is.na(k)]), ")")
  x$row <- k; x <- x[!is.na(k), ]
  if (!nrow(x)) return(res)
  x$athlete_id <- f$athlete_id[x$row]; x$team_id <- f$team_id[x$row]; x$name <- f$name[x$row]
  # a box score beats the file: minutes on or after out_since / updated retire the row
  x$active <- TRUE; x$last_played <- as.Date(NA)
  if (!is.null(pgm) && nrow(pgm)) {
    pl <- pgm[pgm$min > 0, ]
    lp <- tapply(pl$date, paste(pl$athlete_id, pl$team_id), max)
    x$last_played <- as.Date(unname(lp[paste(x$athlete_id, x$team_id)]), origin = "1970-01-01")
    from <- pmax(x$since, x$upd, na.rm = TRUE)
    back <- !is.na(x$last_played) & !is.na(from) & x$last_played >= from
    x$active[back] <- FALSE
    res$returned <- paste0(x$name[back], " (", teams$team[match(x$team_id[back], teams$espn_id)], ", played ", format(x$last_played[back]), ")")
    # past the expected return, team has played since, she hasn't: still out
    tg <- tapply(pgm$date, pgm$team_id, max)
    team_last <- as.Date(unname(tg[x$team_id]), origin = "1970-01-01")
    x$stale <- x$active & x$status == "out" & !x$season_out & !is.na(x$ret) & x$ret < today & !is.na(team_last) & team_last > x$ret &
      (is.na(x$last_played) | x$last_played < x$ret)
  } else x$stale <- FALSE
  x$stale[is.na(x$stale)] <- FALSE
  res$stale <- paste0(x$name[x$stale], " (", teams$team[match(x$team_id[x$stale], teams$espn_id)], ", expected ", format(x$ret[x$stale]), ")")
  # windows for the softer statuses: until expected_return, else PW_INJ_STATUS_DAYS after `updated`
  x$until <- x$ret
  soft <- x$status != "out" & is.na(x$until)
  x$until[soft] <- (if (all(is.na(x$upd))) today else x$upd)[soft] + PW_INJ_STATUS_DAYS
  x$until[soft & is.na(x$upd)] <- today + PW_INJ_STATUS_DAYS
  x$label <- ifelse(x$season_out, "Out for season",
             ifelse(x$status == "out", ifelse(x$stale, paste0("Out, was expected back ", format(x$ret)),
                                              ifelse(is.na(x$ret), "Out", paste0("Out, expected back ", format(x$ret)))),
             ifelse(x$status == "limited", ifelse(is.na(x$cap), "Limited", paste0("Limited to ", round(x$cap), " min")),
                    tools::toTitleCase(x$status))))
  inj <- trimws(as.character(x$injury)); x$label <- ifelse(!is.na(inj) & nzchar(inj), paste0(x$label, " (", inj, ")"), x$label)
  x <- x[x$active, ]
  res$active <- paste0(x$name, " (", teams$team[match(x$team_id, teams$espn_id)], "): ", x$label)
  res$tab <- x
  res
}
# chance she misses a game on `date` (vector over rows of the injury table)
pw_inj_pmiss <- function(x, date) {
  date <- as.Date(date)
  p <- ifelse(x$season_out | (x$status == "out" & (is.na(x$ret) | x$stale)), 1,
       ifelse(x$status == "out", 1 - stats::plogis(as.numeric(date - (x$ret + PW_INJ_SLIP_DAYS)) / PW_INJ_SLIP_SCALE),
       ifelse(!is.na(x$until) & date <= x$until, unname(PW_INJ_MISS[x$status]), 0)))
  if (is.na(date)) p <- ifelse(x$season_out | x$status == "out", 1, unname(PW_INJ_MISS[x$status]))
  p[is.na(p)] <- 0
  p
}
# fraction of her minutes lost when she plays limited
pw_inj_capfrac <- function(x, m, date) {
  date <- as.Date(date)
  on <- x$status == "limited" & !is.na(x$cap) & (is.na(date) | is.na(x$until) | date <= x$until)
  ifelse(on & m > 0, pmax(m - x$cap, 0) / m, 0)
}

# Team rating change (em units, split O and D, D = points allowed) when a set of
# players lose `share` of their minutes, which go to teammates in proportion to
# their own minutes. `cO`, `cD` turn a change in minute-weighted roster value into
# a change in team rating: preseason the team model's fitted weights on roster
# value, in season the fitted lineup-shift weight.
pw_minutes_shift <- function(f, team, idx, share, valO, valD, cO, cD) {
  k <- which(f$team_id == team & !f$source %in% "pad")
  m <- f$m_cur[k]; m[is.na(m)] <- 0
  j <- match(idx[idx %in% k], k)
  if (!length(j)) return(c(O = 0, D = 0))
  lost <- rep(0, length(k)); lost[j] <- share * m[j]
  keep <- m - lost; pool <- sum(lost)
  others <- keep * (lost == 0)
  if (sum(others) <= 0) return(c(O = 0, D = 0))
  newm <- keep + pool * others / sum(others)
  dw <- 5 * (newm - m) / 200
  c(O = cO * sum(dw * valO[k]), D = -cD * sum(dw * valD[k]))
}

# ---- w1.12: minutes-drop flags --------------------------------------------------
# A key player whose minutes fall off a cliff in ONE game is the earliest sign of an
# injury that the box scores give: the "out" rule above needs three games, and
# wbb_injuries.csv needs someone to type. A player is KEY when she averaged at least
# PW_MF_KEY_MIN minutes per 40 over her previous (up to) 5 team games and played all
# but at most one of them. A game is FLAGGED when she:
#   DNP     -- was listed but didn't play (never excused);
#   severe  -- played 30% of her usual minutes or less;
#   sharp   -- played 50% or less;
# unless it is explained by foul trouble (PW_MF_FOULS or more fouls) or by the whole
# rotation sitting (her key teammates' median minutes that game are 75% of usual or
# less -- a blowout or a rest game; DNPs are never excused this way).
# Backtest (2017-26 box scores, ~45,000 key player-games a season; 2017-22 and
# 2023-26 give the same rates): after such a game she misses the NEXT game entirely
# 57% (DNP) / 21% (severe) / 9% (sharp) of the time, against 1.7% for a key player
# with normal minutes, and plays under half her usual minutes 62% / 46% / 26% of the
# time. Foul-trouble crashes (1-2%) and team-wide ones (4% for sharp) are not
# elevated, which is why they are excused. NOTE the final margin is NOT used: a crash
# in a 20+ point game predicts a missed next game as well as one in a close game
# (13% vs 11%); what clears her is her teammates' minutes dropping with hers.
# Flags are reported, not applied: they don't change any rating or win chance.
PW_MF_KEY_MIN  <- 20
PW_MF_SEVERE   <- 0.30
PW_MF_SHARP    <- 0.50
PW_MF_FOULS    <- 4
PW_MF_TEAMWIDE <- 0.75
PW_MF_P_MISS   <- c(DNP = 0.57, severe = 0.21, sharp = 0.09)   # P(misses her next game), 2017-26
PW_MF_P_HALF   <- c(DNP = 0.62, severe = 0.46, sharp = 0.26)   # P(plays under half her usual minutes next game)
PW_MF_BASE     <- 0.017                                        # P(misses next game | key, normal minutes)
# w1.12: the DNP rate above (57%) pools a first missed game and a second straight one, which
# differ: 52.5% vs 62.7% to miss the next game, 59.8% vs 69.9% to play under half her usual minutes
# (2018-26; 3rd straight 75%, 4th+ 91%, but a player stops counting as "key" after the 2nd, so
# the flag only ever shows these two).
PW_MF_P_DNP    <- list(miss = c(first = 0.525, second = 0.627), half = c(first = 0.598, second = 0.699))
pw_minutes_flags <- function(pgm, all_games = FALSE) {
  if (is.null(pgm) || !nrow(pgm)) return(NULL)
  pgm <- pgm[!is.na(pgm$date) & !is.na(pgm$athlete_id), ]
  tg <- unique(pgm[, c("team_id", "game_id", "date")])
  sm <- tapply(pgm$min, paste(pgm$team_id, pgm$game_id), sum)
  tg$len <- { s <- unname(sm[paste(tg$team_id, tg$game_id)]); ifelse(is.na(s) | s < 150, 40, pmax(40, 5 * round(s / 25))) }
  tg <- tg[order(tg$team_id, tg$date, tg$game_id), ]
  tg$gn <- ave(seq_len(nrow(tg)), tg$team_id, FUN = seq_along)
  pl <- unique(pgm[, c("team_id", "athlete_id")])
  gr <- merge(pl, tg, by = "team_id")                       # every player x every game of her team
  gr <- gr[order(gr$team_id, gr$athlete_id, gr$gn), ]
  k <- match(paste(gr$team_id, gr$athlete_id, gr$game_id), paste(pgm$team_id, pgm$athlete_id, pgm$game_id))
  gr$min <- ifelse(is.na(k), 0, pgm$min[k]); gr$pf <- ifelse(is.na(k), 0, pgm$pf[k])
  gr$name <- pgm$name[match(gr$athlete_id, pgm$athlete_id)]
  gr$am <- gr$min * 40 / gr$len; gr$played <- as.numeric(gr$min > 0)
  grp <- paste(gr$team_id, gr$athlete_id); pos <- ave(seq_len(nrow(gr)), grp, FUN = seq_along)
  lagk <- function(x, k) { y <- c(rep(NA_real_, k), x[seq_len(length(x) - k)]); y[pos <= k] <- NA; y }
  A <- sapply(1:5, function(k) lagk(gr$am, k)); B <- sapply(1:5, function(k) lagk(gr$played, k))
  n <- rowSums(!is.na(A)); base <- ifelse(n >= 3, rowSums(A, na.rm = TRUE) / pmax(n, 1), NA)
  key <- !is.na(base) & base >= PW_MF_KEY_MIN & rowSums(B, na.rm = TRUE) >= n - 1
  ratio <- ifelse(key, gr$am / base, NA)
  tk <- paste(gr$team_id, gr$game_id)
  mate <- rep(NA_real_, nrow(gr))                           # median ratio of her key teammates that game
  ki <- which(key)
  mate[ki] <- ave(ratio[ki], tk[ki], FUN = function(v) if (length(v) >= 3) vapply(seq_along(v), function(i) stats::median(v[-i]), 0) else rep(NA_real_, length(v)))
  tier <- ifelse(!key, NA, ifelse(gr$min == 0, "DNP", ifelse(ratio <= PW_MF_SEVERE, "severe", ifelse(ratio <= PW_MF_SHARP, "sharp", NA))))
  why <- ifelse(is.na(tier), NA, ifelse(tier != "DNP" & gr$pf >= PW_MF_FOULS, "fouls",
                ifelse(tier != "DNP" & !is.na(mate) & mate <= PW_MF_TEAMWIDE, "team-wide", "isolated")))
  prev0 <- lagk(as.numeric(gr$min == 0), 1)                 # w1.12: did she also miss the game before?
  out <- data.frame(team_id = gr$team_id, athlete_id = gr$athlete_id, name = gr$name, game_id = gr$game_id, date = gr$date, gn = gr$gn,
                    tier = tier, why = why, usual = base, played = gr$am, mins = gr$min, fouls = gr$pf, prev0 = prev0, stringsAsFactors = FALSE)
  out <- out[!is.na(out$tier) & out$why == "isolated", ]
  last_gn <- tapply(tg$gn, tg$team_id, max)
  out$latest <- out$gn == unname(last_gn[out$team_id])
  out$p_miss <- unname(PW_MF_P_MISS[out$tier]); out$p_half <- unname(PW_MF_P_HALF[out$tier])
  d2 <- out$tier == "DNP" & out$prev0 %in% 1                # second straight missed game
  d1 <- out$tier == "DNP" & !d2
  out$p_miss[d1] <- PW_MF_P_DNP$miss[["first"]]; out$p_miss[d2] <- PW_MF_P_DNP$miss[["second"]]
  out$p_half[d1] <- PW_MF_P_DNP$half[["first"]]; out$p_half[d2] <- PW_MF_P_DNP$half[["second"]]
  if (!all_games) out <- out[out$latest, ]
  out[order(-out$p_miss, out$team_id, out$name), ]
}

# ---- tip-off times and logged picks ------------------------------------------------
pw_tipoffs <- function(s27, gids) {
  if (is.null(s27)) return(rep(NA_character_, length(gids)))
  raw <- if (!is.null(s27$date)) as.character(s27$date) else NA_character_
  tv <- if (!is.null(s27$time_valid)) s27$time_valid %in% c(TRUE, 1, "TRUE", "true") else rep(TRUE, nrow(s27))
  det <- if (!is.null(s27$status_type_detail)) grepl("TBD|TBA", s27$status_type_detail, ignore.case = TRUE) else FALSE
  tip <- ifelse(tv & !det & grepl("T[0-9]{2}:[0-9]{2}", raw), raw, NA_character_)
  if (all(is.na(tip)) && !is.null(s27$game_date_time) && inherits(s27$game_date_time, "POSIXct"))
    tip <- ifelse(tv & !det, format(s27$game_date_time, "%Y-%m-%dT%H:%MZ", tz = "UTC"), NA_character_)
  unname(tip[match(gids, as.character(s27$game_id))])
}
pw_logged_picks <- function(g) {
  f <- pw_log_file(); out <- list(p = rep(NA_real_, nrow(g)), m = rep(NA_real_, nrow(g)))
  if (!file.exists(f)) return(out)
  lg <- tryCatch(utils::read.csv(f, colClasses = c(gid = "character", home = "character", away = "character"), stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(lg) || !nrow(lg)) return(out)
  k <- match(g$gid, lg$gid); ok <- !is.na(k)
  flip <- ok & lg$home[pmax(k, 1)] != g$home
  out$p[ok] <- ifelse(flip[ok], 1 - lg$p[k[ok]], lg$p[k[ok]])
  out$m[ok] <- ifelse(flip[ok], -lg$margin[k[ok]], lg$margin[k[ok]])
  out
}

# =============================================================================
# Part 6 -- run everything and build the payload for the page
# =============================================================================
pw_read_teams <- function() {
  f <- file.path(OUT_DIR, TEAMS_FILE)
  if (!file.exists(f)) stop(TEAMS_FILE, " not found next to the script")
  t <- utils::read.csv(f, colClasses = c(espn_id = "character"), stringsAsFactors = FALSE, encoding = "UTF-8", check.names = FALSE)
  names(t) <- sub("^\ufeff", "", names(t))
  t$new_coach[is.na(t$new_coach)] <- 0; t$auto_bid[is.na(t$auto_bid)] <- 1
  t$ct_teams[is.na(t$ct_teams)] <- ave(rep(1, nrow(t)), t$conf, FUN = length)[is.na(t$ct_teams)]
  t
}

pw_log_file <- function() file.path(OUT_DIR, "predictions_log_wbb.csv")
pw_update_log <- function(up, played) {
  f <- pw_log_file()
  old <- if (file.exists(f)) utils::read.csv(f, colClasses = c(gid = "character", home = "character", away = "character"), stringsAsFactors = FALSE) else NULL
  # w1.9: the log keeps the LATEST pick made before game day ends (each run
  # overwrites picks for games not yet played), not the first one made up to
  # three days out -- so a graded pick reflects the injuries and lineups known
  # the morning of the game
  new <- up[up$date <= Sys.Date() + 3 & up$date >= Sys.Date(), c("gid", "date", "home", "away", "p", "margin")]
  if (nrow(new)) {
    new$logged <- format(Sys.time(), "%Y-%m-%d %H:%M"); new$date <- as.character(new$date)
    keep <- if (is.null(old)) NULL else old[!(old$gid %in% new$gid & as.Date(old$date) >= Sys.Date()), ]
    new <- new[!new$gid %in% keep$gid, ]
    old <- rbind(keep, new[, names(new)])
    tmp <- paste0(f, ".tmp"); utils::write.csv(old, tmp, row.names = FALSE)
    if (!file.rename(tmp, f)) { file.copy(tmp, f, overwrite = TRUE); unlink(tmp) }
  }
  if (is.null(old) || is.null(played) || !nrow(played)) return(NULL)
  m <- merge(old, played[, c("gid", "hs", "as")], by = "gid")
  m <- m[m$hs != m$as, ]
  if (!nrow(m)) return(NULL)
  y <- as.numeric(m$hs > m$as); p <- pmin(pmax(m$p, 1e-4), 1 - 1e-4)
  list(n = nrow(m), acc = mean((p > .5) == (y == 1)), ll = -mean(y * log(p) + (1 - y) * log(1 - p)),
       mae = mean(abs(m$margin - (m$hs - m$as))), since = min(m$logged))
}

pw_run <- function() {
  t0 <- Sys.time()
  cf <- file.path(pw_cache_dir(), sprintf("predict_wbb_calibration_%d.rds", PRED_SEASON))
  cal <- if (!PW_RECALIBRATE && file.exists(cf)) tryCatch(readRDS(cf), error = function(e) NULL) else NULL
  if (is.null(cal) || !identical(cal$version, PW_CAL_VERSION)) { cal <- pw_calibrate(); saveRDS(cal, cf) }
  gm <- cal$gm
  teams <- pw_read_teams()
  ids <- teams$espn_id
  # ---- has the season started? (decides prep sheet vs frozen snapshot) ----------
  g27 <- tryCatch(pw_season_games(PRED_SEASON), error = function(e) NULL)
  started <- !is.null(g27) && nrow(g27) > 0 && any(g27$home %in% ids & g27$away %in% ids)
  snap <- NULL
  if (started && !isTRUE(PW_REFREEZE) && file.exists(pw_snapshot_path()))
    snap <- tryCatch(readRDS(pw_snapshot_path()), error = function(e) { message("  WARNING: couldn't read the snapshot: ", conditionMessage(e)); NULL })
  if (!is.null(snap)) {
    message("  [predict] season under way: using the preseason snapshot saved ", snap$built, " (prep sheet not read)")
    prep <- snap$prep; cal$newc <- snap$newc; P <- snap$P
    snap_info <- list(mode = "frozen", built = snap$built)
  } else {
    prep <- pw_read_prep(file.path(OUT_DIR, PREP_SHEET_FILE))
    message("  [predict] projecting 2026-27 rosters from ", PREP_SHEET_FILE, " ...")
    cal$newc <- pw_calibrate_newcomers(cal$H, cal$pm, prep)
    P <- pw_project_2027(cal$H, cal, prep, teams, cal$vm)
    mode <- if (!started) "preseason" else if (isTRUE(PW_REFREEZE)) "refrozen (PW_REFREEZE)" else "rebuilt after the season started (no snapshot found)"
    if (started) message("  WARNING: season has started; snapshot ", if (isTRUE(PW_REFREEZE)) "refrozen from the prep sheet" else "was missing and is being created now")
    snap <- pw_save_snapshot(P, prep, cal$newc, mode)
    snap_info <- list(mode = mode, built = snap$built)
  }
  if (is.null(P$players$pid)) P$players$pid <- P$players$athlete_id
  if (is.null(P$players$aliases)) P$players$aliases <- NA_character_
  pw_write_roster_ids(P$players)
  pre <- P$teams[match(ids, P$teams$team), ]
  # ---- injuries: season-long outs come off the preseason projection ----------------
  pgm27 <- if (started) tryCatch(pw_player_games(PRED_SEASON), error = function(e) NULL) else NULL
  inj <- tryCatch(pw_read_injuries(teams, P$players, pgm27), error = function(e) {
    message("  WARNING: couldn't read ", PW_INJURY_FILE, ": ", conditionMessage(e)); list(file = TRUE, rows = 0L, tab = NULL, unmatched = conditionMessage(e)) })
  cO_pre <- pw_roster_weight(cal$team_coef$O, "O"); cD_pre <- pw_roster_weight(cal$team_coef$D, "D")
  P$players$m_cur <- P$players$pm
  if (!is.null(inj$tab) && any(inj$tab$season_out)) {
    so <- inj$tab[inj$tab$season_out, ]
    for (t in unique(so$team_id)) {
      ix <- so$row[so$team_id == t]
      d <- pw_minutes_shift(P$players, t, ix, 1, P$players$pvO, P$players$pvD, cO_pre, cD_pre)
      i <- match(t, ids)
      if (!is.na(i)) { pre$pO[i] <- pre$pO[i] + d[["O"]]; pre$pD[i] <- pre$pD[i] + d[["D"]]; pre$pem[i] <- pre$pO[i] - pre$pD[i] }
      # her minutes go to teammates in the roster table too
      k <- which(P$players$team_id == t & !P$players$source %in% "pad")
      m <- P$players$pm[k]; lost <- sum(m[k %in% ix]); m[k %in% ix] <- 0
      if (sum(m) > 0) m <- m + lost * m / sum(m)
      P$players$pm[k] <- m; P$players$pm_disp[k %in% ix] <- 0; P$players$m_cur <- P$players$pm
    }
    P$players$note[so$row] <- ifelse(is.na(P$players$note[so$row]), "Out for season (wbb_injuries.csv)", paste0("Out for season; ", P$players$note[so$row]))
  }
  # ---- in-season update --------------------------------------------------------
  played <- NULL; nplayed <- rep(0, length(ids))
  rt <- data.frame(team = ids, em = pre$pem, O = pre$pO, D = pre$pD, T = pre$pT, sd = pre$sd, sc = pre$sc, stringsAsFactors = FALSE)
  gm_now <- gm; gm_now$mu <- mean(cal$H[[length(cal$H)]]$rat$mu); shrink <- rep(1, length(ids))
  if (!is.null(g27) && nrow(g27)) {
    played <- g27
    d1g <- g27[g27$home %in% ids & g27$away %in% ids & g27$poss > 40, ]
    if (nrow(d1g) >= 20) {
      L <- cal$inseason$lambda
      lam <- if (identical(cal$inseason$mode, "scaled")) setNames(L * mean(pre$sd^2) / pre$sd^2, ids) else setNames(rep(L, length(ids)), ids)
      prior <- list(O = setNames(pre$pO, ids), D = setNames(pre$pD, ids), T = setNames(pre$pT, ids))
      # w1.11: the team-specific part of the home edge comes out before the fit
      fit <- pw_fit_ratings(pw_strip_team_hca(d1g, cal$team_hca$d), ids, lambda = lam, prior = prior, fit_h = FALSE, h_fixed = gm$h)
      nplayed <- fit$games
      rt$O <- fit$O; rt$D <- fit$D; rt$em <- fit$em; rt$T <- fit$T
      shrink <- lam / (lam + nplayed)
      rt$sd <- pre$sd * sqrt(shrink); rt$sc <- pre$sc * sqrt(shrink)
      gm_now$tmu <- fit$tmu[1]; gm_now$mu <- fit$mu[1]
    }
  }
  # ---- in-season player layer: lineup shift, roster switch, identity --------------
  insp <- NULL
  if (!is.null(played) && !is.null(pgm27) && nrow(pgm27)) {
    er <- pw_espn_roster(PRED_SEASON)
    insp <- tryCatch(pw_inseason_players(pgm27, P$players, teams, rt, cal, gm_now, er),
                     error = function(e) { message("  WARNING: in-season player layer failed: ", conditionMessage(e)); NULL })
    if (!is.null(insp)) {
      i <- match(rt$team, names(insp$shift_O)); sO <- na0(insp$shift_O[i]); sD <- na0(insp$shift_D[i])
      sO <- sO + shrink * na0(insp$rot_O[i]); sD <- sD + shrink * na0(insp$rot_D[i])
      rt$O <- rt$O + sO; rt$D <- rt$D - sD; rt$em <- rt$em + sO + sD; rt$shift <- sO + sD
      # carry the box-score ids found by the identity linker back to the roster rows
      sid <- insp$sheet_ids; kk <- match(P$players$pid, sid$pid)
      P$players$athlete_id[!is.na(kk)] <- sid$athlete_id[kk[!is.na(kk)]]
      U <- insp$U; k <- match(paste(P$players$athlete_id, P$players$team_id), paste(U$athlete_id, U$team_id))
      nm <- is.na(k)
      k2 <- match(paste(pw_norm_name(P$players$name), P$players$team_id), paste(pw_norm_name(U$name), U$team_id)); k[nm] <- k2[nm]
      has <- !is.na(k)
      tg27 <- as.numeric(table(factor(unique(pgm27[, c("team_id", "game_id")])$team_id, levels = teams$espn_id))[P$players$team_id])
      live_team <- !is.na(tg27) & tg27 > 0
      P$players$pm_disp[has] <- U$m_fwd[k[has]]
      P$players$pm_disp[P$players$source %in% "pad" & live_team] <- 0
      # values and minutes the injury layer uses in season: forward minutes, box-updated values
      P$players$m_cur[has & live_team] <- U$m_fwd[k[has & live_team]]
      bO <- insp$bO; bD <- insp$bD
      P$players$vO_cur <- P$players$pvO; P$players$vD_cur <- P$players$pvD
      if (!is.null(bO)) { P$players$vO_cur[has] <- bO[k[has]]; P$players$vD_cur[has] <- bD[k[has]] }
      addnote <- function(i, txt) P$players$note[i] <<- ifelse(is.na(P$players$note[i]), txt, paste0(txt, "; ", P$players$note[i]))
      isout <- has & U$out[k] %in% TRUE & U$listed[k] %in% TRUE
      addnote(isout, paste0("Out: no minutes in the last ", PW_OUT_GAMES, " games"))
      iels <- has & U$elsewhere[k] %in% TRUE
      addnote(iels, paste0("Playing for ", U$playing_for[k][iels], " in 2026-27 box scores"))
      inev <- has & !(U$listed[k] %in% TRUE) & !(U$elsewhere[k] %in% TRUE) & live_team & tg27 >= 5
      addnote(inev, "Not in any 2026-27 box score yet")
      if (!is.null(insp$review) && nrow(insp$review))
        tryCatch(utils::write.csv(insp$review, file.path(OUT_DIR, PW_REVIEW_CSV), row.names = FALSE, fileEncoding = "UTF-8"), error = function(e) NULL)
      else if (file.exists(file.path(OUT_DIR, PW_REVIEW_CSV))) unlink(file.path(OUT_DIR, PW_REVIEW_CSV))
    }
  }
  # ---- w1.12: minutes-drop flags (reported, not applied) -------------------------------
  mf <- if (!is.null(pgm27) && nrow(pgm27)) tryCatch(pw_minutes_flags(pgm27), error = function(e) {
    message("  WARNING: minutes-drop flags failed: ", conditionMessage(e)); NULL }) else NULL
  if (!is.null(mf) && nrow(mf)) {
    tn <- setNames(teams$team, teams$espn_id)
    kk <- match(paste(mf$athlete_id, mf$team_id), paste(P$players$athlete_id, P$players$team_id))
    txt <- sprintf("Minutes drop: %d of her usual %d on %s (not foul trouble or a team-wide drop); about %d%% of such players miss their next game",
                   round(mf$mins), round(mf$usual), format(mf$date, "%b %d"), round(100 * mf$p_miss))
    for (j in which(!is.na(kk))) P$players$note[kk[j]] <- ifelse(is.na(P$players$note[kk[j]]), txt[j], paste0(txt[j], "; ", P$players$note[kk[j]]))
    csv <- data.frame(date = as.character(mf$date), team = unname(tn[mf$team_id]), name = mf$name, athlete_id = mf$athlete_id, flag = mf$tier,
                      minutes = round(mf$mins), usual = round(mf$usual), fouls = mf$fouls, p_miss_next = mf$p_miss, p_under_half = mf$p_half,
                      status = "", expected_return = "", note = "", stringsAsFactors = FALSE)
    tryCatch(utils::write.csv(csv, file.path(OUT_DIR, sprintf("wbb_%d_minutes_flags.csv", PRED_SEASON)), row.names = FALSE, fileEncoding = "UTF-8"),
             error = function(e) message("  WARNING: couldn't write the minutes-flags CSV: ", conditionMessage(e)))
  }
  rt$rank <- rank(-rt$em, ties.method = "first")
  # ---- schedule ------------------------------------------------------------------
  message("  [predict] building the 2026-27 schedule and simulating ", N_SIMS, " seasons ...")
  s27 <- pw_schedule(PRED_SEASON); s26 <- pw_schedule(PRED_SEASON - 1)
  g <- pw_build_schedule(teams, s27, s26, played)
  # ---- injuries: game by game -------------------------------------------------------
  g$inj_O_h <- 0; g$inj_D_h <- 0; g$inj_O_a <- 0; g$inj_D_a <- 0; g_inj <- vector("list", nrow(g))
  if (!is.null(inj$tab) && nrow(inj$tab)) {
    x <- inj$tab[!inj$tab$season_out, ]            # season-long outs are already in the team ratings
    if (nrow(x)) {
      ins_on <- sum(nplayed) > 0 && !is.null(cal$inseason$player)
      a1 <- if (ins_on) cal$inseason$player$best$a1 else NA
      vO <- if (ins_on && !is.null(P$players$vO_cur)) P$players$vO_cur else P$players$pvO
      vD <- if (ins_on && !is.null(P$players$vD_cur)) P$players$vD_cur else P$players$pvD
      cO <- if (ins_on) a1 else cO_pre; cD <- if (ins_on) a1 else cD_pre
      # full effect of each injured player missing a whole game
      full <- t(vapply(seq_len(nrow(x)), function(r) pw_minutes_shift(P$players, x$team_id[r], x$row[r], 1, vO, vD, cO, cD), c(O = 0, D = 0)))
      todo <- which(!g$done & g$kind == "posted" & (g$home %in% x$team_id | g$away %in% x$team_id))
      for (gi in todo) for (side in c("h", "a")) {
        tm <- if (side == "h") g$home[gi] else g$away[gi]
        r <- which(x$team_id == tm); if (!length(r)) next
        pm <- pw_inj_pmiss(x[r, ], g$date[gi])
        cf <- pw_inj_capfrac(x[r, ], P$players$m_cur[x$row[r]], g$date[gi])
        w <- pmax(pm, cf)                                 # expected share of her minutes lost
        if (!any(w > 0.02)) next
        dO <- sum(w * full[r, "O"]); dD <- sum(w * full[r, "D"])
        if (side == "h") { g$inj_O_h[gi] <- dO; g$inj_D_h[gi] <- dD } else { g$inj_O_a[gi] <- dO; g$inj_D_a[gi] <- dD }
        keep <- which(w > 0.02)
        g_inj[[gi]] <- c(g_inj[[gi]], lapply(keep, function(j) list(side, x$name[r[j]], round(pm[j], 2), x$label[r[j]], x$status[r[j]])))
      }
    }
  }
  # home-minus-away rating change, em units, for the simulation and the game lines
  # w1.11: each home team's own edge over the league's (0 at neutral sites)
  g$hca_d <- if (is.null(cal$team_hca)) 0 else { z <- unname(cal$team_hca$d[g$home]); z[is.na(z) | g$neutral] <- 0; z }
  # home-minus-away rating change for the game, em units: injuries plus the team home edge
  g$inj_em <- (g$inj_O_h - g$inj_D_h) - (g$inj_O_a - g$inj_D_a) + g$hca_d
  sim <- pw_simulate(teams, rt, g, gm_now)
  # ---- per-game probabilities -----------------------------------------------------
  idx <- c(ids, "NOND1")
  EMv <- c(rt$em, NON_D1_EM); SDv <- c(rt$sd, 0); SCv <- c(rt$sc, 0); Tv <- c(rt$T, -2)
  Ov <- c(rt$O, NON_D1_EM / 2); Dv <- c(rt$D, -NON_D1_EM / 2)
  hi <- match(g$home, idx); ai <- match(g$away, idx)
  e <- pw_game_expect(EMv[hi] + g$inj_O_h - g$inj_D_h + g$hca_d, EMv[ai] + g$inj_O_a - g$inj_D_a, Tv[hi], Tv[ai], ifelse(g$neutral, 0, 1), gm_now)
  kk <- if (sum(nplayed) > 0) cal$inseason$k_in else cal$inseason$k_pre; if (is.null(kk)) kk <- 1
  same <- as.numeric(g$conf %in% TRUE)
  pv <- pmax(SDv[hi]^2 + SDv[ai]^2 - same * (SCv[hi]^2 + SCv[ai]^2), 0)
  s <- sqrt(gm_now$sigma^2 + kk * (e$poss / 100)^2 * pv)
  g$p <- stats::pnorm(e$margin / s); g$margin <- e$margin
  g$total <- e$poss / 100 * (2 * gm_now$mu + Ov[hi] + Ov[ai] + Dv[hi] + Dv[ai] + g$inj_O_h + g$inj_O_a + g$inj_D_h + g$inj_D_a)
  live <- tryCatch(pw_update_log(g[g$kind == "posted" & !g$done & !is.na(g$date), ], played), error = function(e) NULL)
  # w1.12: minutes-drop flags on each upcoming game (shown on the slate, not in the probabilities)
  g$mf <- vector("list", nrow(g))
  # only each flagged team's NEXT game: the backtest says what follows her NEXT game, nothing about one weeks away
  if (!is.null(mf) && nrow(mf)) for (tm in unique(mf$team_id)) {
    ix <- which(!g$done & g$kind == "posted" & !is.na(g$date) & (g$home == tm | g$away == tm)); if (!length(ix)) next
    gi <- ix[which.min(g$date[ix])]; side <- if (g$home[gi] == tm) "h" else "a"; r <- mf[mf$team_id == tm, ]
    g$mf[[gi]] <- c(g$mf[[gi]], lapply(seq_len(nrow(r)), function(j) list(side, r$name[j], r$tier[j], round(r$usual[j]), round(r$mins[j]), r$p_miss[j])))
  }
  # ---- tip-offs, logged picks, injuries for the page ---------------------------------
  g$tip <- pw_tipoffs(s27, g$gid)
  lp <- pw_logged_picks(g); g$lp <- lp$p; g$lm <- lp$m
  g$inj <- g_inj
  # ---- payload -------------------------------------------------------------------
  out <- pw_payload(teams, P, rt, pre, sim, g, cal, gm_now, nplayed, live, prep, t0)
  out$report$checks$inseason <- if (is.null(insp)) NULL else insp$checks
  out$report$checks$snapshot <- snap_info
  out$report$checks$minute_flags <- list(
    n = if (is.null(mf)) 0L else nrow(mf), asof = if (is.null(pgm27) || !nrow(pgm27)) NULL else format(max(pgm27$date), "%Y-%m-%d"),
    rows = if (is.null(mf) || !nrow(mf)) character(0) else paste0(mf$name, " (", teams$team[match(mf$team_id, teams$espn_id)], "): ", ifelse(mf$tier == "DNP", "did not play", paste0(round(mf$mins), " min")),
                                    " vs usual ", round(mf$usual), ", ", format(mf$date, "%b %d"), " [", mf$tier, ifelse(mf$tier == "DNP" & mf$prev0 %in% 1, ", 2nd straight", ""), "]"),
    p_miss = as.list(PW_MF_P_MISS), base = PW_MF_BASE)
  out$report$checks$injuries <- list(file = isTRUE(inj$file), rows = inj$rows, active = inj$active, returned = inj$returned,
                                     stale = inj$stale, unmatched = inj$unmatched)
  # ratings for the rest of the page (one source of truth with this tab)
  out$ratings_now <- list(mode = if (sum(nplayed) > 0) "in-season" else "preseason", mu = round(gm_now$mu, 3), tmu = round(gm_now$tmu, 3),
                          h = round(gm_now$h, 3), team = ids, O = round(rt$O, 3), D = round(rt$D, 3), T = round(rt$T, 3), sd = round(rt$sd, 3),
                          games = as.integer(nplayed))
  out
}

pw_payload <- function(teams, P, rt, pre, sim, g, cal, gm, nplayed, live, prep, t0) {
  r1 <- function(x, d = 1) round(as.numeric(x), d)
  ids <- teams$espn_id
  st <- sim$teams[match(ids, sim$teams$team), ]
  H26 <- cal$H[[length(cal$H)]]
  last <- H26$rat[match(ids, H26$rat$team), ]
  rank26 <- rank(-H26$rat$em, ties.method = "first")[match(ids, H26$rat$team)]
  # colours: dashboard's own lookup when available, else the schedule release
  col <- rep(NA_character_, length(ids))
  if (exists("primary_by_id")) col <- unname(get("primary_by_id")[ids])
  s27 <- pw_schedule(PRED_SEASON)
  if (!is.null(s27)) { cc <- c(setNames(s27$home_color, s27$home_id), setNames(s27$away_color, s27$away_id))
    col[is.na(col)] <- unname(cc[ids[is.na(col)]]) }
  # schedule status by team
  kind_n <- function(k) { x <- g[g$kind == k, ]; tabulate(match(c(x$home[x$count_for %in% c("both", "h")], x$away[x$count_for %in% c("both", "a")]), ids), length(ids)) }
  n_posted <- kind_n("posted"); n_proj <- kind_n("projected"); n_ph <- kind_n("placeholder")
  f <- P$players
  tl <- lapply(seq_along(ids), function(i) {
    id <- ids[i]
    list(id = id, name = teams$team[i], conf = teams$conf[i], color = col[i],
         em = r1(rt$em[i]), O = r1(rt$O[i]), D = r1(rt$D[i]), T = r1(gm$tmu + rt$T[i]), sd = r1(rt$sd[i]), sc = r1(rt$sc[i], 2), rank = rt$rank[i],
         pads = pre$pads[i], lowconf = isTRUE(pre$pads[i] >= 3),
         pre_em = r1(pre$pem[i]), pre_rank = rank(-pre$pem, ties.method = "first")[i],
         em26 = r1(last$em[i]), rank26 = rank26[i], O26 = r1(last$O[i]), D26 = r1(last$D[i]),
         ret = r1(pre$retmin[i] * 100, 0), gp = nplayed[i],
         w = r1(st$w[i]), l = r1(st$l[i]), cw = r1(st$cw[i]), cl = r1(st$cl[i]), w10 = st$w10[i], w90 = st$w90[i],
         reg = r1(st$reg_title[i], 3), reg1 = r1(st$reg_outright[i], 3), ct = r1(st$ct_champ[i], 3),
         ncaa = r1(st$ncaa[i], 3), auto = r1(st$auto[i], 3), seed = r1(st$seed[i]), one = r1(st$one_seed[i], 3),
         top4 = r1(st$top4[i], 3), r32 = r1(st$r32[i], 3), s16 = r1(st$s16[i], 3), e8 = r1(st$e8[i], 3),
         f4 = r1(st$f4[i], 3), fin = r1(st$final[i], 3), ch = r1(st$champ[i], 4),
         rk10 = st$rk10[i], rk50 = st$rk50[i], rk90 = st$rk90[i],
         coach = teams$coach[i], new_coach = teams$new_coach[i], moved = teams$moved_from[i],
         sched = c(n_posted[i], n_proj[i], n_ph[i]))
  })
  # rosters: [name, status, from, exp, ht, ly_mpg, ly_ppg, ly_rpg, ly_apg, proj_mpg, proj_ppg, vO, vD, rank]
  rost <- lapply(split(f, f$team_id), function(x) {
    x <- x[order(-x$pm), ]
    lapply(seq_len(nrow(x)), function(k) list(
      x$name[k], x$status[k], if (x$status[k] %in% c("Transfer", "Transfer (non-D1)", "Newcomer", "International (FIBA)", "Top-100 recruit", "Redshirt (2025 recruit)")) x$prev_team[k] else NA,
      if (!is.na(x$cls[k])) x$cls[k] else if (!is.na(x$exp_years[k]) && x$exp_years[k] > 0) paste0(x$exp_years[k], " yr") else NA,
      x$height[k], r1(x$ly_mpg[k]), r1(x$ly_ppg[k]), r1(x$ly_rpg[k]), r1(x$ly_apg[k]),
      r1(x$pm_disp[k]), r1(x$ppg_proj[k]), r1(x$pvO[k]), r1(x$pvD[k]), if (is.na(x$rank[k])) NA else x$rank[k],
      if (is.na(x$eff40[k])) NA else r1(x$eff40[k]), if (is.na(x$note[k])) NA else x$note[k], r1(x$pm[k])))
  })
  # departures
  stt <- prep$stats; stt$athlete_id <- pw_id(stt$athlete_id)
  dep <- stt[stt$`2026 Team` %in% teams$team & (is.na(stt$`2027 Team`) | stt$`2027 Team` != stt$`2026 Team`), ]
  dep$v <- H26$pv$v[match(dep$athlete_id, H26$pv$athlete_id)]
  dep$tid <- ids[match(dep$`2026 Team`, teams$team)]
  deps <- lapply(split(dep, dep$tid), function(x) {
    x <- x[order(-pw_num(x$total_minutes)), ]; x <- x[seq_len(min(nrow(x), 10)), ]
    lapply(seq_len(nrow(x)), function(k) list(x$athlete_display_name[k],
      if (is.na(x$`2027 Team`[k])) "Left D1" else if (x$`2027 Team`[k] == "GRADUATED") "Graduated" else x$`2027 Team`[k],
      r1(pw_num(x$mpg[k])), r1(pw_num(x$ppg[k])), r1(x$v[k])))
  })
  # games: [gid, date, home, away, neutral, conf, kind, p_home, margin, total, hs, as]
  gl <- lapply(seq_len(nrow(g)), function(k) list(g$gid[k], if (is.na(g$date[k])) NA else format(g$date[k]), g$home[k], g$away[k],
      as.integer(g$neutral[k]), as.integer(g$conf[k]), substr(g$kind[k], 1, 2), r1(g$p[k], 3), r1(g$margin[k]), r1(g$total[k], 0),
      if (g$done[k]) g$hs[k] else NA, if (g$done[k]) g$as[k] else NA, g$count_for[k],
      # w1.9: [13] tip-off (UTC), [14] logged pregame p_home, [15] logged margin, [16] injuries
      if (is.null(g$tip) || is.na(g$tip[k])) NA else g$tip[k],
      if (is.null(g$lp) || is.na(g$lp[k])) NA else r1(g$lp[k], 3),
      if (is.null(g$lm) || is.na(g$lm[k])) NA else r1(g$lm[k]),
      if (is.null(g$inj) || is.null(g$inj[[k]])) list() else g$inj[[k]],
      # w1.12: [17] minutes-drop flags [side, name, tier, usual, played, p_miss_next]
      if (is.null(g$mf) || is.null(g$mf[[k]])) list() else g$mf[[k]]))
  confs <- lapply(unique(teams$conf), function(cf) {
    mem <- which(teams$conf == cf)
    cg <- g[g$conf & g$home %in% ids[mem], ]
    status <- if (!any(cg$kind == "projected")) "official" else if (any(cg$kind == "posted")) "partial" else "projected"
    list(conf = cf, teams = ids[mem], games = teams$conf_games[mem[1]], ct = teams$ct_teams[mem[1]], status = status,
         seeds = round(sim$conf_seeds[[cf]], 3))
  })
  bt <- cal$backtest
  ins <- cal$inseason
  checks <- list(
    padded = unname(tapply(f$source == "pad", f$team, sum)[tapply(f$source == "pad", f$team, sum) > 0]),
    padded_teams = names(which(tapply(f$source == "pad", f$team, sum) > 0)),
    recruits_found = sum(f$status == "Top-100 recruit"), recruits_total = sum(prep$rec$year == PRED_SEASON - 1),
    fiba_found = sum(f$status == "International (FIBA)"), nond1 = sum(f$status == "Transfer (non-D1)"),
    new_coaches = sum(teams$new_coach %in% 1), low_conf = sum(pre$pads >= 3, na.rm = TRUE),
    roster_players = sum(f$source != "pad"),
    unmatched_recruits = {
      rc <- prep$rec[prep$rec$year == PRED_SEASON - 1, ]
      miss <- rc[!pw_norm_name(rc$name) %in% f$rec_key[!is.na(f$rank)], ]
      if (nrow(miss)) paste0(miss$name, " (No. ", miss$rank, ", ", miss$college, ")") else character(0)
    },
    prior_added = if (any(f$prior_added %in% TRUE)) { z <- f[f$prior_added %in% TRUE, ]; paste0(z$name, " (No. ", z$rank_prev, ", ", z$team, "; ", ifelse(is.na(z$prior_note), "unverified", sub(";.*", "", z$prior_note)), ")") } else character(0),
    duplicates = if (length(P$dropped_dups)) P$dropped_dups else character(0),
    added_recruits = if (any(f$rec_added %in% TRUE)) paste0(f$name[f$rec_added %in% TRUE], " (", f$team[f$rec_added %in% TRUE], ")") else character(0))
  list(ok = TRUE, version = PW_VERSION, built = format(Sys.time(), "%Y-%m-%d %H:%M"), season = "2026-27",
       mode = if (sum(nplayed) > 0) "in-season" else "preseason", games_played = sum(g$done & g$count_for == "both"),
       n_sims = N_SIMS, field = NCAA_FIELD,
       gm = list(h = r1(gm$h, 2), tmu = r1(gm$tmu), sigma = r1(gm$sigma, 2), mu = r1(if (is.null(gm$mu)) mean(H26$rat$mu) else gm$mu),
                 k = r1(if (sum(nplayed) > 0) cal$inseason$k_in else cal$inseason$k_pre, 3),
                 sigma_crossfit = if (is.null(gm$sigma_crossfit)) NULL else r1(gm$sigma_crossfit, 2)),
       teams = tl, rosters = rost, departures = deps, games = gl, confs = confs,
       report = list(backtest = bt, bt_transfer = cal$bt_transfer, pos_alpha = cal$pos_alpha, calib_seasons = cal$seasons, transitions = cal$n_transitions, team_seasons = cal$n_team_seasons,
                     value_r2 = c(O = cal$vm$r2O, D = cal$vm$r2D), player_r2 = cal$player_r2,
                     team_coef = cal$team_coef, sd_fit = cal$sd_fit,
                     inseason = ins$summary, lambda = ins$lambda, bins = ins$bins,
                     inseason_mode = ins$mode, bins_pre = ins$bins_pre, k_pre = ins$k_pre, k_in = ins$k_in, prob_check = ins$prob_check,
                     inseason_loso = if (is.null(ins$loso_ll)) NULL else as.list(ins$loso_ll),   # a list, so it reaches the page as named fields inseason_loso_picks = if (is.null(ins$loso)) NULL else unique(ins$loso$pick), inseason_loso_n = if (is.null(ins$loso)) NULL else nrow(ins$loso),
                     player_layer = if (is.null(ins$player)) NULL else list(best = ins$player$best, n = ins$player$n,
                        loso_base = ins$player$loso_base_ll, loso = ins$player$loso_ll,
                        early_base = unname(ins$player$early_base["ll"]), early = unname(ins$player$early_chosen["ll"]),
                        seasons_better = sum(ins$player$loso$ll_pick < ins$player$loso$ll_base), seasons = nrow(ins$player$loso)),
                     team_hca = if (is.null(cal$team_hca)) NULL else list(tau = r1(cal$team_hca$tau, 2), se = r1(cal$team_hca$se, 2),
                        seasons = cal$team_hca$seasons, n = cal$team_hca$n_teams, range = r1(range(cal$team_hca$d) / 100 * gm$tmu, 2)),
                     boot = cal$boot, boot_oracle = cal$boot_oracle, conf_sd = r1(sqrt(if (is.null(cal$sc2)) 0 else cal$sc2), 2),
                     tune = cal$tune, rostered = cal$n_rostered, recruit_history = isTRUE(cal$recruit_history),
                     with_coach = isTRUE(cal$with_coach), tempo_coef = cal$team_coef$T,
                     newc = list(n_rank = cal$newc$n_rank, n_fiba = cal$newc$n_fiba, n_unranked = cal$newc$n_unranked,
                                 rank1 = r1(sum(pw_rank_bump(cal$newc, 1)) + 0, 2), rank50 = r1(sum(pw_rank_bump(cal$newc, 50)), 2),
                                 rank100 = r1(sum(pw_rank_bump(cal$newc, 100)), 2), unranked = r1(sum(cal$newc$off_unranked), 2),
                                 replacement = r1(sum(cal$newc$replacement), 2), n_classes = cal$newc$n_classes,
                                 min1 = r1(sum(cal$newc$rank_min_fit * c(1, log(1), 0))), min50 = r1(sum(cal$newc$rank_min_fit * c(1, log(50), 0))),
                                 min_prog = r1(cal$newc$rank_min_fit[3], 2),
                                 fiba_r2 = if (is.null(cal$newc$fiba_r2)) NULL else as.list(round(cal$newc$fiba_r2, 3)),
                                 fiba_levels = lapply(names(prep$fiba_off$level), function(l) list(l, r1(prep$fiba_off$level[[l]]), prep$fiba_off$source[[l]], prep$fiba_off$n[[l]])),
                                 fiba_multi = prep$fiba_off$n_multi),
                     live = live, checks = checks,
                     seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")))))
}


# ---- entry point (build_dashboards.R sources this inside tryCatch) ------------
# build_dashboards.R (w1.9) sources this with PW_DEFINE_ONLY = TRUE to borrow the
# rating model for the rest of the page, then calls pw_run() itself
if (!isTRUE(get0("PW_DEFINE_ONLY", ifnotfound = FALSE))) predict_payload <- pw_run()
