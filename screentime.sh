#!/bin/env bash

SELF="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/$(basename "$0")"
TODAY="$(date +%Y-%m-%d)"
APPNAME="screentime"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME"
STATE_FILE="$DATA_DIR/state"
TOTALS_FILE="$DATA_DIR/$TODAY"
PRIV_CMD="${PRIV_CMD:-sudo}"

now_epoch() {
  date +%s
}

format_hms() {
  local total_secs="$1"
  local h=$(( total_secs / 3600 ))
  local m=$(( (total_secs % 3600) / 60 ))
  local s=$(( total_secs % 60 ))
  printf "%d:%02d:%02d" "$h" "$m" "$s"
}

sanitize_date() {
  local display_date="$1"
  local date="$(date -d "$display_date" +%Y-%m-%d 2>/dev/null || echo "")"
  [ -n "$date" ] || {
    echo "Invalid date: $display_date" >&2
    exit 1
  }
  echo -n "$date"
}

sanitize_label() {
  echo -n "$1" | tr '\t\r\n' '  '
}

systemd_hooks_dir() {
  local dirs=(
    "/etc/systemd/system-sleep"
    "/lib/systemd/system-sleep"
    "/usr/lib/systemd/system-sleep"
  )
  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      echo -n "$(dirname "$dir")"
      return
    fi
  done
}

get_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo -en "$(now_epoch)\t"
  fi
}

set_state() {
  if [ -z "$2" ] && [ ! -f "$STATE_FILE" ]; then
    return
  fi
  echo -en "$1\t$2" > "$STATE_FILE"
}

add_total_seconds() {
  local add="$1"
  local label="$2"

  [ "$add" -gt 0 ] || return 0

  if [ ! -f "$TOTALS_FILE" ]; then
    if [ -z "$label" ]; then
      local yesterday="$(date -d yesterday +%Y-%m-%d)"
      if [ "$(basename "$TOTALS_FILE")" != "$TODAY" ] || [ ! -f "$DATA_DIR/$yesterday" ]; then
        return
      fi
      TOTALS_FILE="$DATA_DIR/$yesterday"
    fi
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

  cat "$tmp" > "$TOTALS_FILE"
  rm -f "$tmp"
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

track_focused() {
  local wid="$(focused_window_id)"
  local class="$(window_class "$wid")"
  cmd_track "$class"
}

cmd_track() {
  local label="$(sanitize_label "$1")"

  local now="$(now_epoch)"

  local state="$(get_state)"
  set_state "$now" "$label"

  local prev_ts="$(echo -n "$state" | cut -f1)"
  local prev_label="$(echo -n "$state" | cut -f2)"
  [ -n "$prev_label" ] || return

  local elapsed=$((now - prev_ts))

  add_total_seconds "$elapsed" "$prev_label"
}

cmd_show() {
  local display_date="$1"
  local date="$(sanitize_date "$display_date")"
  if [ "$date" = "$TODAY" ]; then
    cmd_track "$(get_state | cut -f2)" || true
  fi

  TOTALS_FILE="$DATA_DIR/$date"
  if [ ! -f "$TOTALS_FILE" ] || [ ! -s "$TOTALS_FILE" ]; then
    echo "No data $display_date."
    return
  fi

  local max_time=$(cut -f1 "$TOTALS_FILE" | sort -nr | head -n1)
  [ "$max_time" -gt 0 ] || max_time=1

  local cols="${COLUMNS:-80}"
  local max_bar_length=30
  [ "$cols" -ge 120 ] && max_bar_length=50

  echo "Screen time $display_date:"

  sort -nr -k1,1 "$TOTALS_FILE" | while IFS="$(echo -e "\t")" read -r secs name rest; do
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

  local total_secs=$(awk -F '\t' '{s+=$1} END{print s+0}' "$TOTALS_FILE")
  printf "\nTotal time: %s\n" "$(format_hms "$total_secs")"
}

cmd_clear() {
  local display_date="$1"
  local date="$(sanitize_date "$display_date")"

  if [ "$date" = "$TODAY" ]; then
    rm -rf "$STATE_FILE"
  fi

  TOTALS_FILE="$DATA_DIR/$date"
  rm -rf "$TOTALS_FILE"
  echo "Cleared data: $display_date."
}

cmd_subscribe() {
  local target="$1"
  track_focused

  case "$target" in
    bspwm)
      echo "Listening for focus changes (bspwm)..."
      bspc subscribe node_focus desktop_focus node_add node_remove | while IFS= read -r _; do
        track_focused
      done
      ;;
    systemd)
      local systemd_dir="$(systemd_hooks_dir)"
      [ -n "$systemd_dir" ] || {
        echo "Systemd hooks directory not found." >&2
        exit 1
      }

      local sleep_path="$systemd_dir/system-sleep/$APPNAME"
      local shutdown_path="$systemd_dir/system-shutdown/$APPNAME"

      echo "Installing systemd suspend/resume hooks: $sleep_path"
      cat <<EOF | "$PRIV_CMD" tee "$sleep_path" > /dev/null
#!/bin/sh
case "\$1" in
  pre) "$SELF" event suspend --dir "$DATA_DIR";;
  post) "$SELF" event resume --dir "$DATA_DIR";;
esac
EOF
      "$PRIV_CMD" chmod a+rx "$sleep_path"

      echo "Installing systemd shutdown hook: $shutdown_path"
      cat <<EOF | "$PRIV_CMD" tee "$shutdown_path" > /dev/null
#!/bin/sh
"$SELF" event shutdown --dir "$DATA_DIR"
EOF
      "$PRIV_CMD" chmod a+rx "$shutdown_path"
      ;;
    *)
      echo "Unsupported target: $target" >&2
      exit 1
      ;;
  esac
}

cmd_event() {
  local event="$1"
  case "$event" in
      suspend|shutdown)
        cmd_track ""
        ;;
      resume)
        track_focused
        ;;
      *)
        echo "Unrecognized event: $event" >&2
        exit 1
        ;;
    esac
}

cmd_help() {
  cat <<EOF
Usage: $0 <command> [args] [options]
Commands:
  [show] [date]                 Show totals with bars
  track [label]                 Track focus changes
  clear [date]                  Clear tracked data
  subscribe                     Continuously track focus changes (for bspwm)
  event <event>                 Track system events
  help                          Show this help message
Arguments:
  date                          Date in any format recognized by 'date -d'
                                e.g. "today", "yesterday", "last monday",
                                     "2026-01-03", "01/03/2026", etc.
  label                         Label for the tracked time. 'subscribe' uses
                                the window class of the focused window.
  event                         System event: suspend, resume, shutdown
Options:
  --dir <path>                  Data directory (default: $DATA_DIR)
  --privilege-command <cmd>     Command to use for privileged operations (default: sudo)
EOF
}

cmd="${1:-show}"
if [ -n "$1" ]; then
  shift
fi

arg=""
case "$cmd" in
  track)
    arg="${1:-idle}" ;;
  show|clear)
    arg="${1:-today}" ;;
  subscribe)
    arg="${1:-bspwm}" ;;
  event)
    arg="$1"
    [ -n "$arg" ] || {
      echo "Missing <suspend|resume> after 'event' command" >&2
      exit 1
    }
    ;;
  help) ;;
  *) cmd_help; exit 2 ;;
esac
if [ -n "$1" ]; then
  shift
fi

while [ -n "$1" ]; do
  case "$1" in
    -h|--help) cmd_help; exit 0 ;;
    --dir)
      if [ -z "${2:-}" ]; then
        echo "Missing directory path after --dir" >&2
        exit 1
      fi
      DATA_DIR="$2"
      TOTALS_FILE="$DATA_DIR/$TODAY"
      STATE_FILE="$DATA_DIR/state"
      shift
      ;;
    --privilege-command)
      if [ -z "${2:-}" ]; then
        echo "Missing command after --privilege-command" >&2
        exit 1
      fi
      PRIV_CMD="$2"
      shift
      ;;
    *)
      echo "Unrecognized option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$DATA_DIR"
: > /dev/null 2>&1 || true

case "$cmd" in
  track) cmd_track "$arg" ;;
  show) cmd_show "$arg" ;;
  clear) cmd_clear "$arg" ;;
  subscribe) cmd_subscribe "$arg" ;;
  event) cmd_event "$arg" ;;
  help) cmd_help ;;
esac
