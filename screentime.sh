#!/bin/sh
set -eu

APPNAME="screentime"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME"
STATE_FILE="$DATA_DIR/state"
TOTALS_FILE="$DATA_DIR/$(date +%Y-%m-%d)"

mkdir -p "$DATA_DIR"
: > /dev/null 2>&1 || true

now_epoch() {
  date +%s
}

format_hms() {
  local total_secs="$1"
  local h=$((total_secs / 3600))
  local m=$(( (total_secs % 3600) / 60 ))
  local s=$(( total_secs % 60 ))
  printf "%d:%02d:%02d" "$h" "$m" "$s"
}

sanitize_date() {
  local display_date="$1"
  local date="$(date -d "$display_date" +%Y-%m-%d 2>/dev/null || echo "")"
  [ -n "$date" ] || {
    echo "Invalid date: $display_date"
    exit 1
  }
  echo -n "$date"
}

sanitize_label() {
  echo -n "$1" | tr '\t\r\n' '  '
}

get_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo -n ""
  fi
}

set_state() {
  echo -en "$1\t$2" > "$STATE_FILE"
}

add_total_seconds() {
  local add="$1"
  local label="$2"

  [ "$add" -gt 0 ] || return 0

  if [ ! -f "$TOTALS_FILE" ]; then
    : > "$TOTALS_FILE"
  fi

  local tmp="$DATA_DIR/.totals.tmp.$$"

  awk -F '\t' -v OFS='\t' -v add="$add" -v lab="$label" '
    BEGIN { found=0 }
    NF>=2 {
      secs=$1
      name=$2
      if (name==lab) { secs+=add; found=1 }
      print secs, name
      next
    }
    END {
      if (!found) print add, lab
    }
  ' "$TOTALS_FILE" > "$tmp"

  mv "$tmp" "$TOTALS_FILE"
}

focused_window_id() {
  bspc query -N -n focused.window 2>/dev/null || true
}

window_class() {
  local wid="$1"
  [ -n "$wid" ] || { echo "idle"; return; }

  local cls="$(xprop -id "$wid" WM_CLASS 2>/dev/null | rev | cut -d'"' -f2 | rev)"
  [ -n "$cls" ] && { echo "$cls"; return; }

  echo "unknown"
}

cmd_track() {
  local label="$(sanitize_label "$1")"

  local now="$(now_epoch)"

  local state="$(get_state)"
  if [ -z "$state" ]; then
    set_state "$now" "$label"
    exit 0
  fi

  local prev_ts="$(echo -n "$state" | cut -f1)"
  local prev_label="$(echo -n "$state" | cut -f2)"

  case "$prev_ts" in
    ''|*[!0-9]*)
      set_state "$now" "$label"
      exit 0
      ;;
  esac

  local elapsed=$((now - prev_ts))
  [ "$elapsed" -ge 0 ] || elapsed=0

  add_total_seconds "$elapsed" "$prev_label"
  set_state "$now" "$label"
}

cmd_show() {
  local display_date="$1"
  local date="$(sanitize_date "$display_date")"
  cmd_track "$(get_state | cut -f2)" || true

  TOTALS_FILE="$DATA_DIR/$date"
  if [ ! -f "$TOTALS_FILE" ] || [ ! -s "$TOTALS_FILE" ]; then
    echo "No data $display_date."
    exit 0
  fi

  local max_time=$(cut -f1 "$TOTALS_FILE" | sort -nr | head -n1)
  [ "$max_time" -gt 0 ] || max_time=1

  local cols="${COLUMNS:-80}"
  local max_bar_length=30
  if [ "$cols" -ge 120 ]; then max_bar_length=50; fi

  echo "Screen time $display_date:"

  local total_secs=0
  sort -nr -k1,1 "$TOTALS_FILE" | while IFS="$(echo -e "\t")" read -r secs name rest; do
    total_secs=$((total_secs + secs))
    local time="$(format_hms "$secs")"

    local bar_length=$(((secs * max_bar_length + max_time / 2) / max_time))
    [ "$bar_length" -gt "$max_bar_length" ] && bar_length="$max_bar_length"

    local i=0
    local bar=""
    while [ "$i" -lt "$bar_length" ]; do
      bar="${bar}█"
      i=$((i + 1))
    done

    printf "%8s %s %*s %s\n" "$time" "$bar" "$(( max_bar_length - bar_length ))" "" "$name"
  done
  printf "\nTotal time: %s\n" "$(format_hms "$total_secs")"
}

cmd_clear() {
  local display_date="$1"
  local date="$(sanitize_date "$display_date")"

  if [ "$date" = "$(basename "$TOTALS_FILE")" ]; then
    rm -rf "$STATE_FILE"
  fi

  TOTALS_FILE="$DATA_DIR/$date"
  rm -rf "$TOTALS_FILE"
  echo "Cleared data: $display_date."
}

cmd_subscribe() {
  local wid="$(focused_window_id)"
  local class="$(window_class "$wid")"
  cmd_track "$class"

  bspc subscribe node_focus desktop_focus node_add node_remove | while IFS= read -r _; do
    wid="$(focused_window_id)"
    class="$(window_class "$wid")"
    cmd_track "$class"
  done
}

cmd_help() {
  cat <<EOF
Usage: $0 <command> [args]
Commands:
  [show | show [date]]          Show totals with bars
  track [label]                 Track focus changes
  clear [date]                  Clear tracked data
  subscribe                     Continuously track focus changes (for bspwm)
  help                          Show this help message
Arguments:
  date                          Date in any format recognized by 'date -d'
                                e.g. "today", "yesterday", "last monday",
                                     "2026-01-03", "01/03/2026", etc.
  label                         Label for the tracked time. 'subscribe' uses
                                the window class of the focused window.
EOF
}

cmd="${1:-show}"
case "$cmd" in
  track) cmd_track "${2:-idle}" ;;
  clear) cmd_clear "${2:-today}" ;;
  help|-h|--help) cmd_help ;;
  show) cmd_show "${2:-today}" ;;
  subscribe) cmd_subscribe ;;
  *) cmd_help; exit 2 ;;
esac
