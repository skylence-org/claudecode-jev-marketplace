#!/usr/bin/env bash
# core-hud.sh: Claude Code statusline.
# L1: session: ⏺ model · effort │ config: model · effort · adv model │ project ⎇ branch ~Nf +A -D
# L2: gradient context bar (24 cells, 1/8-cell resolution) PCT% of CTX · safe · handoff banner
# L3: 5h ▸ used% [spark] rate%/h → limit-vs-reset verdict · resets HH:MM
# L4: 7d ▸ used% rate%/h · resets Day HH:MM · session cost
#
# RATE ENGINE: every render appends (epoch,u5,u7) to a per-user history file
# (deduped to one sample per 20s). Burn rate = delta over the last ~10 min,
# responsive within a couple of renders, not the whole-window average. The
# sparkline is 8×3-min buckets of 5h-quota deltas over the last 24 min. When
# the projected time-to-100% lands BEFORE the window reset, the verdict goes
# red with the projected limit clock.

# Disable glob expansion so unquoted vars with wildcards are never expanded.
set -f
input=$(cat)
[ -z "$input" ] && {
  echo "Claude"
  exit 0
}
command -v jq >/dev/null || {
  echo "Claude [needs jq]"
  exit 0
}

# ── Colors ──
C=$'\033[36m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' M=$'\033[35m' T=$'\033[96m' D=$'\033[37m' W=$'\033[97m' B=$'\033[1m' N=$'\033[0m'
x() { printf '\033[38;5;%sm' "$1"; }  # 256-color foreground
SEP=$'\037'
NOW=$(date +%s)

_cache_dir_ok() { [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -w "$1" ]; }
_read_cache_record() {
  local line="$1" delim rest field
  CACHE_FIELDS=()
  if [[ "$line" == *"$SEP"* ]]; then delim="$SEP"; else delim='|'; fi
  rest="$line"
  while [[ "$rest" == *"$delim"* ]]; do
    field=${rest%%"$delim"*}
    CACHE_FIELDS+=("$field")
    rest=${rest#*"$delim"}
  done
  CACHE_FIELDS+=("$rest")
}
_load_cache_record_file() {
  local path="$1" line=""
  [ -f "$path" ] || return 1
  IFS= read -r line <"$path" || line=""
  _read_cache_record "$line"
}
_write_cache_record() {
  local path="$1" tmp dir
  shift
  dir=${path%/*}
  tmp=$(mktemp "${dir}/claude-sl-tmp-XXXXXX" 2>/dev/null || true)
  [ -n "$tmp" ] || return 1
  (
    IFS="$SEP"
    printf '%s\n' "$*"
  ) >"$tmp" && mv "$tmp" "$path"
}
_write_quota_snapshot_if_changed() {
  local path="$1" u5="$2" u7="$3" r5="$4" r7="$5"
  if [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] && _load_cache_record_file "$path"; then
    [[ "${CACHE_FIELDS[0]:-}" == "$u5" ]] &&
      [[ "${CACHE_FIELDS[1]:-}" == "$u7" ]] &&
      [[ "${CACHE_FIELDS[2]:-}" == "$r5" ]] &&
      [[ "${CACHE_FIELDS[3]:-}" == "$r7" ]] && return 0
  fi
  _write_cache_record "$path" "$u5" "$u7" "$r5" "$r7"
}
_minutes_until() {
  local epoch="$1" mins
  [[ "$epoch" =~ ^[0-9]+$ ]] && ((epoch > 0)) || return
  mins=$(((epoch - NOW) / 60))
  ((mins < 0)) && mins=0
  printf '%s\n' "$mins"
}
_valid_quota_snapshot() {
  local u5="$1" u7="$2" r5="$3" r7="$4"
  [[ "$u5" =~ ^[0-9]+$ ]] || return 1
  [[ "$u7" =~ ^[0-9]+$ ]] || return 1
  [[ "$r5" =~ ^[0-9]+$ ]] || return 1
  [[ "$r7" =~ ^[0-9]+$ ]] || return 1
  ((r5 > NOW && r7 > NOW))
}
_clock() {  # epoch → HH:MM (+ "Day DD Mon" when not today); empty on failure
  local epoch="$1" _rt _today _rday
  [[ "$epoch" =~ ^[0-9]+$ ]] && ((epoch > 0)) || return
  _rt=$(date -d "@${epoch}" +"%H:%M" 2>/dev/null || date -r "${epoch}" +"%H:%M" 2>/dev/null || echo "")
  [ -n "$_rt" ] || return
  _today=$(date +"%Y-%m-%d")
  _rday=$(date -d "@${epoch}" +"%Y-%m-%d" 2>/dev/null || date -r "${epoch}" +"%Y-%m-%d" 2>/dev/null || echo "")
  if [[ -n "$_rday" && "$_today" != "$_rday" ]]; then
    printf '%s %s' "$(date -d "@${epoch}" +"%a" 2>/dev/null || date -r "${epoch}" +"%a" 2>/dev/null)" "$_rt"
  else
    printf '%s' "$_rt"
  fi
}
_collect_git_info() {
  BRN="" FC=0 AD=0 DL=0
  git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || return 1
  BRN=$(git -C "$DIR" --no-optional-locks branch --show-current 2>/dev/null)
  while IFS=$'\t' read -r a d _; do
    [[ "$a" =~ ^[0-9]+$ ]] || continue
    FC=$((FC + 1))
    AD=$((AD + a))
    DL=$((DL + d))
  done < <(git -C "$DIR" --no-optional-locks diff HEAD --numstat 2>/dev/null)
}

_CD="" CACHE_OK=0
for _BASE in "${XDG_RUNTIME_DIR:-}" "${HOME}/.cache"; do
  [ -n "$_BASE" ] || continue
  _CAND="${_BASE%/}/claude-pace"
  # shellcheck disable=SC2174
  [ -e "$_CAND" ] || mkdir -p -m 700 "$_CAND" 2>/dev/null || continue
  _cache_dir_ok "$_CAND" || continue
  _CD="$_CAND"
  CACHE_OK=1
  break
done
QC="" HIST=""
[[ "$CACHE_OK" == "1" ]] && QC="${_CD}/claude-sl-quota" && HIST="${_CD}/claude-sl-hist"
_stale() { [ ! -f "$1" ] || [ $((NOW - $(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0))) -gt "$2" ]; }

# ── Parse stdin + settings in one jq call ──
_cfg_eff=$(jq -r '.effortLevel // ""' ~/.claude/settings.json 2>/dev/null || echo "")
_cfg_model=$(jq -r '.model // ""' ~/.claude/settings.json 2>/dev/null || echo "")
_cfg_adv=$(jq -r '.advisorModel // ""' ~/.claude/settings.json 2>/dev/null || echo "")
HAS_RL=0
IFS=$'\t' read -r MODEL DIR PCT CTX REM COST DUR_MS EFF HAS_RL U5 U7 R5 R7 < <(
  jq -r \
    '[(.model.display_name//"?"),(.workspace.project_dir//"."),
    (.context_window.used_percentage//0|floor),(.context_window.context_window_size//0),
    (.context_window.remaining_percentage//0|floor),
    (.cost.total_cost_usd//0),
    (.cost.total_duration_ms//0),
    (.effort.level//""),
    (if .rate_limits then 1 else 0 end),
    (.rate_limits.five_hour.used_percentage//null|if type=="number" then floor else "--" end),
    (.rate_limits.seven_day.used_percentage//null|if type=="number" then floor else "--" end),
    (.rate_limits.five_hour.resets_at//0),
    (.rate_limits.seven_day.resets_at//0)]|@tsv' <<<"$input" | tr -d '\r'
)

# ── Context label and token counts ──
if ((CTX >= 1000000)); then
  CL="$((CTX / 1000000))M"
elif ((CTX > 0)); then
  CL="$((CTX / 1000))K"
else CL=""; fi
USED_K="" REM_K=""
((CTX > 0 && PCT > 0)) && USED_K="$((PCT * CTX / 100000))K"
((CTX > 0 && REM > 0)) && REM_K="$((REM * CTX / 100000))K"

MODEL=${MODEL/ context)/)}
[[ "$CTX" -gt 0 && "$MODEL" != *"("* ]] && MODEL="${MODEL} (${CL})"
((${#MODEL} > 30)) && MODEL="${MODEL:0:29}…"

# Model accent color by family.
MC=$C
case "$MODEL" in
  *[Ff]able*) MC=$M ;;
  *[Oo]pus*) MC=$C ;;
  *[Ss]onnet*) MC="$(x 75)" ;;
  *[Hh]aiku*) MC=$G ;;
esac

# Effort chip: the LIVE session effort from stdin (.effort.level), which tracks
# mid-session /effort changes. This used to render settings.json's effortLevel
# glued to the live model name, so a session running at max still displayed the
# configured low. Absent when the model has no effort parameter.
# L1 group separators, shared so the spacing cannot drift between groups.
# Named L1_* deliberately: SEP is already the \037 cache-record delimiter above,
# and shadowing it corrupts every cached git record.
L1_BAR=" $(x 240)│${N} "
L1_DOT=" $(x 240)·${N} "
EFF_CHIP=""
case "$EFF" in
  max) EFF_CHIP="${L1_DOT}${M}${B}max${N}" ;;
  xhigh) EFF_CHIP="${L1_DOT}${M}xhigh${N}" ;;
  high) EFF_CHIP="${L1_DOT}${Y}high${N}" ;;
  medium) EFF_CHIP="${L1_DOT}${D}med${N}" ;;
  low) EFF_CHIP="${L1_DOT}${D}low${N}" ;;
esac

# ── Gradient context bar: 24 cells, 1/8-cell resolution ──
# Filled cells colored by position on a green→red ramp; partial cell uses
# eighth-blocks so growth is visible between percents; unused = dim dots;
# auto-compact buffer = dim red shade at the tail.
RAMP=(46 46 82 82 118 118 154 154 190 190 226 226 220 220 214 214 208 208 202 202 198 198 196 196)
PARTIAL=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
BAR_W=24
FE=$((PCT * BAR_W * 8 / 100)); ((FE < 0)) && FE=0; ((FE > BAR_W * 8)) && FE=$((BAR_W * 8))
FULL=$((FE / 8)); PART=$((FE % 8))
SAFE_CELLS=0; ((REM > 0)) && SAFE_CELLS=$((REM * BAR_W / 100))
((FULL + SAFE_CELLS > BAR_W)) && SAFE_CELLS=$((BAR_W - FULL))
((PCT == 0 && SAFE_CELLS == 0)) && SAFE_CELLS=$BAR_W
BAR=""
for ((i = 0; i < FULL; i++)); do BAR+="$(x "${RAMP[i]}")█"; done
CONSUMED=$FULL
if ((PART > 0 && FULL < BAR_W)); then
  BAR+="$(x "${RAMP[FULL]}")${PARTIAL[PART]}"
  CONSUMED=$((FULL + 1))
fi
TAIL=$((BAR_W - CONSUMED)); ((TAIL < 0)) && TAIL=0
BUF_CELLS=$((TAIL - SAFE_CELLS)); ((BUF_CELLS < 0)) && BUF_CELLS=0
SAFE_DRAW=$((TAIL - BUF_CELLS)); ((SAFE_DRAW < 0)) && SAFE_DRAW=0
BAR+="$(x 240)"
for ((i = 0; i < SAFE_DRAW; i++)); do BAR+='⋅'; done
if ((BUF_CELLS > 0)); then
  BAR+="$(x 88)"
  for ((i = 0; i < BUF_CELLS; i++)); do BAR+='▒'; done
fi
BAR+="$N"

# ── Git info (5s cache) ──
BRN="" FC=0 AD=0 DL=0
if [[ "$CACHE_OK" == "1" ]]; then
  GC="${_CD}/claude-sl-git-$(printf '%s' "$DIR" | { shasum 2>/dev/null || sha1sum; } | cut -c1-16)"
  if _stale "$GC" 5; then
    if _collect_git_info; then
      _write_cache_record "$GC" "$BRN" "$FC" "$AD" "$DL"
    else
      _write_cache_record "$GC" "" "" "" ""
    fi
  elif _load_cache_record_file "$GC"; then
    BRN=${CACHE_FIELDS[0]:-}
    FC=${CACHE_FIELDS[1]:-}
    AD=${CACHE_FIELDS[2]:-}
    DL=${CACHE_FIELDS[3]:-}
  fi
  [[ "$FC" =~ ^[0-9]+$ ]] || FC=0
  [[ "$AD" =~ ^[0-9]+$ ]] || AD=0
  [[ "$DL" =~ ^[0-9]+$ ]] || DL=0
else
  _collect_git_info || true
fi

# ── Project name + worktree identity ──
PN="${DIR##*/}"
PN="${PN##*\\}"
IS_WT=0 _REPO=""
if [[ "${DIR/#$HOME/\~}" =~ /([^/]+)/\.claude/worktrees/([^/]+) ]]; then
  IS_WT=1
  _REPO="${BASH_REMATCH[1]}"
  _WT_NAME="${BASH_REMATCH[2]}"
  PN="$_REPO"
fi
((${#PN} > 25)) && PN="${PN:0:25}…"
L1R="${W}${PN}${N}"
if [ -n "$BRN" ]; then
  ((${#BRN} > 35)) && BRN="${BRN:0:35}…"
  L1R+=" $(x 245)⎇${N} ${T}${BRN}${N}"
  ((FC > 0)) 2>/dev/null && L1R+=" $(x 245)~${FC}f${N} ${G}+${AD}${N} ${R}-${DL}${N}"
elif [[ "$IS_WT" == "1" ]]; then
  L1R="${W}${_REPO}/${_WT_NAME}${N}"
fi

# ── Quota snapshot (stdin when present, else last cached) ──
SHOW_COST=0
if [[ "$HAS_RL" == "1" ]]; then
  RM5=$(_minutes_until "$R5")
  RM7=$(_minutes_until "$R7")
  if [[ -n "$QC" ]] && _valid_quota_snapshot "$U5" "$U7" "$R5" "$R7"; then
    _write_quota_snapshot_if_changed "$QC" "$U5" "$U7" "$R5" "$R7" || true
  fi
else
  U5="--" U7="--" RM5="" RM7=""
  SHOW_COST=1
  if [[ -n "$QC" ]] && _load_cache_record_file "$QC"; then
    _CU5=${CACHE_FIELDS[0]:-}
    _CU7=${CACHE_FIELDS[1]:-}
    _CR5=${CACHE_FIELDS[2]:-}
    _CR7=${CACHE_FIELDS[3]:-}
    if _valid_quota_snapshot "$_CU5" "$_CU7" "$_CR5" "$_CR7"; then
      U5="$_CU5" U7="$_CU7" R5="$_CR5" R7="$_CR7"
      RM5=$(_minutes_until "$R5")
      RM7=$(_minutes_until "$R7")
      SHOW_COST=0
    fi
  fi
fi

# ── RATE ENGINE: sample history → burn %/h (last ~10 min) + 5h sparkline ──
RATE5="" RATE7="" SPARK=""
if [[ -n "$HIST" && "$U5" =~ ^[0-9]+$ && "$U7" =~ ^[0-9]+$ ]]; then
  _LAST_TS=0
  [ -f "$HIST" ] && _LAST_TS=$(tail -n 1 "$HIST" 2>/dev/null | cut -d' ' -f1)
  [[ "$_LAST_TS" =~ ^[0-9]+$ ]] || _LAST_TS=0
  # Quota resets make used% DROP; a drop invalidates old samples, so start fresh.
  if ((NOW - _LAST_TS >= 20)); then
    if [ -f "$HIST" ]; then
      _LAST_U5=$(tail -n 1 "$HIST" 2>/dev/null | cut -d' ' -f2)
      [[ "$_LAST_U5" =~ ^[0-9]+$ ]] && ((U5 < _LAST_U5 - 2)) && : >"$HIST"
    fi
    printf '%s %s %s\n' "$NOW" "$U5" "$U7" >>"$HIST" 2>/dev/null || true
    # Trim occasionally.
    if [ "$(wc -l <"$HIST" 2>/dev/null || echo 0)" -gt 400 ]; then
      tail -n 200 "$HIST" >"$HIST.t.$$" 2>/dev/null && mv "$HIST.t.$$" "$HIST" 2>/dev/null || rm -f "$HIST.t.$$"
    fi
  fi
  IFS=$'\t' read -r RATE5 RATE7 SPARK < <(awk -v now="$NOW" -v u5="$U5" -v u7="$U7" '
    { ts[NR]=$1; a5[NR]=$2; a7[NR]=$3 }
    END {
      n = NR
      # Burn rate: against the sample closest to 10 min back (accept 2-30 min).
      bi = 0
      for (i = 1; i <= n; i++) { age = now - ts[i]; if (age >= 120 && age <= 1800) { if (!bi || (age < now - ts[bi])) ; } }
      best = -1
      for (i = 1; i <= n; i++) {
        age = now - ts[i]
        if (age < 120 || age > 1800) continue
        d = age - 600; if (d < 0) d = -d
        if (best < 0 || d < best) { best = d; bi = i }
      }
      r5 = ""; r7 = ""
      if (bi > 0) {
        dt = now - ts[bi]
        if (dt >= 120) {
          r5 = (u5 - a5[bi]) * 3600.0 / dt
          r7 = (u7 - a7[bi]) * 3600.0 / dt
          if (r5 < 0) r5 = 0
          if (r7 < 0) r7 = 0
        }
      }
      # Sparkline: 8 × 3-min buckets over the last 24 min of 5h-quota deltas.
      spark = ""
      lv[1]="▁"; lv[2]="▂"; lv[3]="▃"; lv[4]="▄"; lv[5]="▅"; lv[6]="▆"; lv[7]="▇"; lv[8]="█"
      have = 0
      for (b = 7; b >= 0; b--) {
        t1 = now - (b + 1) * 180; t2 = now - b * 180
        lo = -1; hi = -1
        for (i = 1; i <= n; i++) {
          if (ts[i] <= t1) lo = i
          if (ts[i] <= t2) hi = i
        }
        if (lo > 0 && hi > 0 && hi >= lo) {
          d = a5[hi] - a5[lo]
          if (d < 0) d = 0
          idx = int(d / 0.75) + 1
          if (idx > 8) idx = 8
          spark = spark lv[idx]
          if (d > 0) have = 1
        } else spark = spark " "
      }
      sub(/^ +/, "", spark); if (spark ~ /^ *$/) spark = ""
      printf "%s\t%s\t%s\n", (r5 == "" ? "" : sprintf("%.1f", r5)), (r7 == "" ? "" : sprintf("%.1f", r7)), spark
    }' "$HIST" 2>/dev/null) || { RATE5="" RATE7="" SPARK=""; }
fi

# ── Quota line renderer ──
# _quota label used% rm window_min reset_epoch rate spark
_quota() {
  local label="$1" u="$2" rm="$3" w="$4" epoch="$5" rate="$6" spark="$7"
  local out="" uc=$G verdict="" rc=245 arrow="" sus t_lim lim_clock rst
  if [[ ! "$u" =~ ^[0-9]+$ ]]; then
    printf '%s %s' "$(x 245)${label} ▸${N}" "${D}--${N}"
    return
  fi
  ((u >= 90)) && uc=$R || { ((u >= 70)) && uc=$Y; }
  out="$(x 245)${label} ▸${N} ${uc}${B}${u}%%${N}"
  [ -n "$spark" ] && out+=" $(x 66)${spark}${N}"
  if [[ "$rate" =~ ^[0-9.]+$ ]]; then
    # Sustainable pace = 100% spread over the window; ×1000 fixed-point math.
    sus=$((100000 * 60 / w))                       # (%/h)×1000
    local r1000=$(awk -v r="$rate" 'BEGIN{printf "%d", r*1000}')
    if ((r1000 > 0)); then
      if ((r1000 > sus * 3 / 2)); then rc=196 arrow="↑"
      elif ((r1000 > sus * 11 / 10)); then rc=214 arrow="↗"
      elif ((r1000 > sus / 2)); then rc=250 arrow="→"
      else rc=245 arrow="↘"; fi
      out+=" $(x "$rc")${arrow}${rate}%%/h${N}"
    fi
    # Projection: does the current burn hit 100% before the reset?
    if [[ "$rm" =~ ^[0-9]+$ ]] && ((r1000 > 0)); then
      t_lim=$(awk -v u="$u" -v r="$rate" 'BEGIN{ if (r > 0) printf "%d", (100 - u) * 60 / r; else print 999999 }')
      if ((t_lim < rm)); then
        lim_clock=$(_clock $((NOW + t_lim * 60)))
        out+=" ${R}${B}⚠ limit ~${lim_clock:-soon} before reset${N}"
      fi
    fi
  fi
  if [[ "$rm" =~ ^[0-9]+$ ]]; then
    rst=$(_clock "$epoch")
    if [ -n "$rst" ]; then
      out+=" $(x 240)· resets ${rst}${N}"
    else
      ((rm >= 1440)) && out+=" $(x 240)· resets in $((rm / 1440))d${N}"
      ((rm < 1440 && rm >= 60)) && out+=" $(x 240)· resets in $((rm / 60))h${N}"
      ((rm < 60)) && out+=" $(x 240)· resets in ${rm}m${N}"
    fi
  fi
  printf '%s' "$out"
}

# ── Handoff urgency banner ──
BANNER=""
if [[ "$PCT" =~ ^[0-9]+$ ]]; then
  _pace_hot=0
  [[ "$RATE5" =~ ^[0-9.]+$ ]] && _pace_hot=$(awk -v r="$RATE5" 'BEGIN{print (r > 30) ? 1 : 0}')
  if ((PCT >= 85)); then
    BANNER="${R}${B}● handoff NOW: auto-compact imminent${N}"
  elif ((PCT >= 60)); then
    BANNER="${Y}● handoff soon${N}"
  elif ((PCT >= 50)) && [[ "$_pace_hot" == "1" ]]; then
    BANNER="${Y}● handoff soon (hot burn)${N}"
  fi
fi

# ── Assembly ──
# Two groups, deliberately not bundled: what this SESSION is running (live, from
# stdin) and what settings.json CONFIGURES (model, effort, advisor). The old
# layout printed the configured effort next to the live model name, which read
# as one value and hid every mid-session /effort change.
_cfg_bits="$_cfg_model"
[[ -n "$_cfg_eff" ]] && _cfg_bits="${_cfg_bits:+${_cfg_bits}${L1_DOT}}${_cfg_eff}"
[[ -n "$_cfg_adv" ]] && _cfg_bits="${_cfg_bits:+${_cfg_bits}${L1_DOT}}adv ${_cfg_adv}"
_CFG_GRP=""
[[ -n "$_cfg_bits" ]] && _CFG_GRP="${T}config:${N} ${T}${_cfg_bits}${N}${L1_BAR}"
L1="${T}session:${N} ${MC}${B}⏺ ${MODEL}${N}${EFF_CHIP}${L1_BAR}${_CFG_GRP}${L1R}"

if ((PCT == 0 && CTX > 0)); then
  _CTX_LABEL="$(x 250)${CL} avail${N}"
else
  _CTX_LABEL="${W}${B}${PCT}%%${N}$(x 245)${CL:+ of ${CL}}${N}"
fi
L2="${BAR} $(printf "$_CTX_LABEL")${REM_K:+ $(x 240)· ${REM_K} safe${N}}${BANNER:+  ${BANNER}}"

L3="$(printf "$(_quota 5h "$U5" "$RM5" 300 "$R5" "$RATE5" "$SPARK")")"
L4="$(printf "$(_quota 7d "$U7" "$RM7" 10080 "$R7" "$RATE7" "")")"
# Session cost (+ avg $/h from session duration) on the 7d line.
if [[ "$COST" != "0" && -n "$COST" ]]; then
  _CS=$(awk -v c="$COST" 'BEGIN{ if (c > 0) printf "$%.2f", c }')
  if [ -n "$_CS" ]; then
    _CPH=$(awk -v c="$COST" -v ms="$DUR_MS" 'BEGIN{ if (ms > 300000) printf " ($%.1f/h)", c * 3600000 / ms }')
    L4+=" $(x 240)· ${_CS}${_CPH}${N}"
  fi
fi

printf '%s\n' "$L1"
printf '%s\n' "$L2"
printf '%s\n' "$L3"
printf '%s\n' "$L4"
