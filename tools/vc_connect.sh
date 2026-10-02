#!/usr/bin/env bash
# ABOUTME: Routes call/browser audio (Chrome, Zoom, Zen) into REAPER's in7/in8 through a
# ABOUTME: virtual "Vidconf to REAPER" output that WirePlumber remembers; -k tears it down.
#
# ChatGPT coded script to connect Chrome windows to REAPER for recording output audio.
#
set -euo pipefail

# Regex patterns
CHROME_PATTERN="${CHROME_PATTERN:-Google Chrome}"
ZOOM_PATTERN="${ZOOM_PATTERN:-Zoom VoiceEngine}"
REAPER_PATTERN="${REAPER_PATTERN:-REAPER}"
ZEN_PATTERN="${ZEN_PATTERN:-ZEN}"
STUDIO_PATTERN="${STUDIO_PATTERN:-Studio 68c}"

# REAPER input ports that receive the call audio. REAPER needs at least 8 JACK
# inputs for the defaults; in1-in6 are left for the Studio 68c's six inputs.
REAPER_LEFT_PORT="${REAPER_LEFT_PORT:-in7}"
REAPER_RIGHT_PORT="${REAPER_RIGHT_PORT:-in8}"

# Virtual output (a PipeWire null sink) that collects the call audio. Its monitor
# outputs feed REAPER. WirePlumber remembers it as the output of each application
# routed into it, so that application's later streams (a new tab, the video after a
# YouTube advert) land in it directly, with nothing to re-wire.
SINK_NAME="${SINK_NAME:-vc_to_reaper}"
SINK_DESCRIPTION="${SINK_DESCRIPTION:-Vidconf to REAPER}"

# Seconds between checks while waiting for a Chrome/Zoom/Zen stream to appear
POLL_INTERVAL="${POLL_INTERVAL:-1}"

help() {
  cat <<EOF
Routes the audio of browser and call applications (Chrome, Zoom, Zen) into REAPER
for recording, and back to normal playback afterwards.

Without options, the script creates a virtual output called "$SINK_DESCRIPTION",
wires it to REAPER's $REAPER_LEFT_PORT (left) and $REAPER_RIGHT_PORT (right), removing anything
else connected to those two inputs, and moves every Chrome/Zoom/Zen stream that is
currently open into it. WirePlumber remembers the move per application, so later
streams from the same application go to REAPER without running the script again.
Run the script again after REAPER restarts its audio engine, because REAPER then
re-creates its ports.

If no Chrome/Zoom/Zen stream is open yet, the script sets everything else up and
waits, checking every $POLL_INTERVAL s, until a call or video starts; it then moves
that stream and exits. A stream that starts during the wait plays through the
speakers for up to $POLL_INTERVAL s before it is moved. Ctrl+C stops the wait and
leaves the virtual output in place (remove it with -k).

With -k, the script sends the applications' open streams back to the default
output, makes WirePlumber forget the move, and removes the virtual output. REAPER's
$REAPER_LEFT_PORT/$REAPER_RIGHT_PORT are left unconnected.

Usage:
  vc_connect.sh [-k] [-h]

Options:
  -k, --kill    Tear the routing down; applications play to the default output again.
  -h, --help    Show this help.

Environment variables (default in brackets):
  CHROME_PATTERN, ZOOM_PATTERN, ZEN_PATTERN
                Case-insensitive regexes matching the applications' ports
                [$CHROME_PATTERN / $ZOOM_PATTERN / $ZEN_PATTERN]
  REAPER_PATTERN
                Regex matching REAPER's JACK ports [$REAPER_PATTERN]
  REAPER_LEFT_PORT, REAPER_RIGHT_PORT
                REAPER inputs that receive the audio [$REAPER_LEFT_PORT / $REAPER_RIGHT_PORT]
  SINK_NAME, SINK_DESCRIPTION
                Node name and label of the virtual output [$SINK_NAME / $SINK_DESCRIPTION]
  POLL_INTERVAL
                Seconds between checks while waiting for a stream [$POLL_INTERVAL]
EOF
}

teardown=0
while (($#)); do
  case "$1" in
    -k|--kill) teardown=1 ;;
    -h|--help) help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo >&2; help >&2; exit 2 ;;
  esac
  shift
done

for cmd in pw-dump pw-link pw-cli pw-metadata jq; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done

echo "Patterns:"
echo "  Chrome : $CHROME_PATTERN"
echo "  Zoom   : $ZOOM_PATTERN"
echo "  REAPER : $REAPER_PATTERN"
echo "  ZEN    : $ZEN_PATTERN"
echo "  Studio : $STUDIO_PATTERN"
echo "REAPER inputs: left=$REAPER_LEFT_PORT right=$REAPER_RIGHT_PORT"
echo "Virtual output: $SINK_NAME (\"$SINK_DESCRIPTION\")"
echo

# Node id of the virtual output; prints nothing if it does not exist
sink_id() {
  pw-dump | jq -r --arg n "$SINK_NAME" '
    [.[] | select(.type=="PipeWire:Interface:Node" and .info.props["node.name"]==$n) | .id]
    | first // empty'
}

# Point a stream node at a target (node id + object.serial), the way pipewire-pulse
# does when a stream is moved; "-1 -1" means "follow the default output" and makes
# WirePlumber forget the remembered target for that application
set_stream_target() {
  pw-metadata -n default -- "$1" target.node "$2" Spa:Id >/dev/null
  pw-metadata -n default -- "$1" target.object "$3" Spa:Id >/dev/null
}

###############################################################################
# Detect Chrome / Zoom ports (playback + monitor), but distinguish them
###############################################################################

# Fills app_ports, app_all_ids, monitor_ids and app_node_ids from the current
# graph. With the argument "print" it also lists the ports it found; without it,
# it stays quiet, as needed while polling.
find_app_streams() {
  local print_ports=0
  [[ "${1:-}" == "print" ]] && print_ports=1

  mapfile -t app_ports < <(
    pw-dump | jq -r --arg cpat "$CHROME_PATTERN" --arg zpat "$ZOOM_PATTERN" --arg epat "$ZEN_PATTERN" '
      .[] | select(.type=="PipeWire:Interface:Port") |
      .info.props as $p |

      # Only OUT ports
      select($p["port.direction"] == "out") |

      # Match Chrome or Zoom using ANY of:
      select(
        ($p["port.alias"]//""       | test($cpat;"i") or test($zpat;"i") or test($epat;"i")) or
        ($p["object.path"]//""      | test($cpat;"i") or test($zpat;"i") or test($epat;"i")) or
        ($p["node.name"]//""        | test($cpat;"i") or test($zpat;"i") or test($epat;"i")) or
        ($p["application.name"]//"" | test($cpat;"i") or test($zpat;"i") or test($epat;"i"))
      ) |

      # Output format: id node_id channel port_name alias
      "\(.id) \($p["node.id"]//"") \($p["audio.channel"]//"") \($p["port.name"]//"") \($p["port.alias"]//"")"
    '
  )

  app_all_ids=()
  app_node_ids=()
  monitor_ids=()

  if ((print_ports)); then
    if ((${#app_ports[@]} == 0)); then
      echo "No Chrome/Zoom/Zen output ports found."
    else
      echo "Detected Chrome/Zoom/Zen ports:"
    fi
  fi

  local line pid nid ch name alias is_monitor is_playback
  for line in "${app_ports[@]}"; do
    read -r pid nid ch name alias <<<"$line"
    app_all_ids+=("$pid")

    # Identify monitor vs playback
    is_monitor=0
    if [[ "$name" == monitor_* ]] || [[ "$alias" == *":monitor_"* ]] || [[ "$alias" == *"monitor_FL"* ]] || [[ "$alias" == *"monitor_FR"* ]]; then
      is_monitor=1
      monitor_ids+=("$pid")
    fi

    # Playback = ports whose port.name starts with "output_" (or alias contains ":output_")
    is_playback=0
    if [[ "$name" == output_* ]] || [[ "$alias" == *":output_"* ]]; then
      is_playback=1
    fi

    if ((print_ports)); then
      printf "  id=%-3s  chan=%-4s  kind=%-8s  name=%-12s  alias=%s\n" \
        "$pid" "$ch" \
        $([ "$is_monitor" -eq 1 ] && echo "monitor" || ([ "$is_playback" -eq 1 ] && echo "playback" || echo "other")) \
        "$name" "$alias"
    fi

    # Only playback streams are moved (monitors such as 'Chrome input:monitor_FL/FR'
    # are not); collect each stream node once, whatever its channel count
    if [ "$is_playback" -eq 1 ] && [[ " ${app_node_ids[*]} " != *" $nid "* ]]; then
      app_node_ids+=("$nid")
    fi
  done

  if ((print_ports)); then
    echo
  fi
  return 0
}

echo "Scanning for Chrome/Zoom output ports (playback + monitor)..."
find_app_streams print

###############################################################################
# Teardown (-k): send the open streams back to the default output, make
# WirePlumber forget the remembered target, and remove the virtual output
###############################################################################

if ((teardown)); then
  if ((${#app_node_ids[@]} == 0)); then
    echo "No open Chrome/Zoom/Zen playback stream to move back."
  fi
  for nid in "${app_node_ids[@]}"; do
    echo "  stream node $nid → default output"
    set_stream_target "$nid" -1 -1
  done

  sid=$(sink_id)
  if [[ -n "$sid" ]]; then
    echo "Removing virtual output $SINK_NAME (node $sid)"
    pw-cli destroy "$sid"
  else
    echo "Virtual output $SINK_NAME is not present."
  fi
  echo "Done."
  exit 0
fi

###############################################################################
# Find the REAPER input ports that receive the call audio (left + right)
###############################################################################

echo "Scanning REAPER ports..."

mapfile -t reaper_ports < <(
  pw-dump | jq -r --arg pat "$REAPER_PATTERN" '
    .[] | select(.type=="PipeWire:Interface:Port") |
    .info.props as $p |
    select($p["port.direction"]=="in") |
    select(
      ($p["port.alias"]//""       | test($pat;"i"))
      or ($p["object.path"]//""   | test($pat;"i"))
      or ($p["node.name"]//""     | test($pat;"i"))
      or ($p["application.name"]//"" | test($pat;"i"))
    ) |
    "\(.id) \($p["port.name"]//"") \($p["port.alias"]//"")"
  '
)

reaper_left=""
reaper_right=""

for line in "${reaper_ports[@]}"; do
  read -r pid pname palias <<<"$line"
  [[ "$pname" == "$REAPER_LEFT_PORT" || "$palias" == *":$REAPER_LEFT_PORT" ]] && reaper_left="$pid"
  [[ "$pname" == "$REAPER_RIGHT_PORT" || "$palias" == *":$REAPER_RIGHT_PORT" ]] && reaper_right="$pid"
done

[[ -z "$reaper_left" ]] && { echo "REAPER $REAPER_LEFT_PORT not found (is REAPER running, with enough JACK inputs?)"; exit 1; }
[[ -z "$reaper_right" ]] && { echo "REAPER $REAPER_RIGHT_PORT not found (is REAPER running, with enough JACK inputs?)"; exit 1; }

echo "Using REAPER ports:"
echo "  $REAPER_LEFT_PORT (left)  = $reaper_left"
echo "  $REAPER_RIGHT_PORT (right) = $reaper_right"
echo

###############################################################################
# Create the virtual output unless it exists already
###############################################################################

sid=$(sink_id)
if [[ -z "$sid" ]]; then
  echo "Creating virtual output $SINK_NAME..."
  # object.linger keeps the node after pw-cli exits. monitor.channel-volumes is
  # left off, so the monitor ports carry the audio at unity gain whatever the
  # output's volume. With no priority.driver set, the node runs on its own clock
  # only when unconnected; wired to REAPER it follows the Studio 68c's clock.
  pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$SINK_NAME node.description=\"$SINK_DESCRIPTION\" media.class=Audio/Sink object.linger=true audio.position=[FL FR] monitor.passthrough=true }" >/dev/null
  for _ in {1..30}; do
    sid=$(sink_id)
    [[ -n "$sid" ]] && break
    sleep 0.1
  done
  [[ -z "$sid" ]] && { echo "Virtual output $SINK_NAME did not appear"; exit 1; }
fi

sink_serial=$(pw-dump | jq -r --argjson id "$sid" '.[] | select(.id==$id) | .info.props["object.serial"]')

# Port id of one of the virtual output's ports; prints nothing until it exists
sink_port() {
  pw-dump | jq -r --argjson id "$sid" --arg pn "$1" '
    [.[] | select(.type=="PipeWire:Interface:Port" and .info.props["node.id"]==$id and .info.props["port.name"]==$pn) | .id]
    | first // empty'
}

mon_fl=""
mon_fr=""
for _ in {1..30}; do
  mon_fl=$(sink_port monitor_FL)
  mon_fr=$(sink_port monitor_FR)
  [[ -n "$mon_fl" && -n "$mon_fr" ]] && break
  sleep 0.1
done
[[ -z "$mon_fl" || -z "$mon_fr" ]] && { echo "Monitor ports of $SINK_NAME did not appear"; exit 1; }

echo "Virtual output: node $sid (serial $sink_serial), monitor_FL=$mon_fl monitor_FR=$mon_fr"
echo

###############################################################################
# Disconnect anything else feeding the target REAPER inputs, so they carry only
# the call audio. REAPER auto-connects its inputs in order to hardware capture
# ports, so with 8 inputs in7/in8 arrive linked to the built-in analogue input.
# The virtual output's own links are kept, so re-running causes no dropout.
###############################################################################

echo "Scanning existing links into REAPER $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT..."

mapfile -t reaper_links < <(
  pw-dump | jq -r --argjson lport "$reaper_left" --argjson rport "$reaper_right" \
                  --argjson mfl "$mon_fl" --argjson mfr "$mon_fr" '
    . as $all |
    $all[] | select(.type=="PipeWire:Interface:Link") |
    .info.props as $lp |
    select($lp["link.input.port"] == $lport or $lp["link.input.port"] == $rport) |

    # Keep the virtual output links (monitor_FL -> left, monitor_FR -> right)
    select((($lp["link.output.port"] == $mfl and $lp["link.input.port"] == $lport) or
            ($lp["link.output.port"] == $mfr and $lp["link.input.port"] == $rport)) | not) |

    # Output side alias for info
    ($all[] | select(.type=="PipeWire:Interface:Port" and .id == $lp["link.output.port"])) as $outport |

    "\(.id) \($lp["link.output.port"]) \($lp["link.input.port"]) \($outport.info.props["port.alias"]//"")"
  '
)

if ((${#reaper_links[@]} > 0)); then
  echo "Disconnecting existing links into REAPER $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT:"
  for l in "${reaper_links[@]}"; do
    read -r lid outp inp outp_alias <<<"$l"
    printf "  link %-4s OUT=%-4s (%s) -> %-4s\n" "$lid" "$outp" "$outp_alias" "$inp"
    pw-cli destroy "$lid" || echo "Failed to delete link $lid"
  done
else
  echo "Nothing else connected to REAPER $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT."
fi
echo

###############################################################################
# Wire the virtual output to REAPER: monitor_FL -> left, monitor_FR -> right
###############################################################################

link_exists() {
  pw-dump | jq -e --argjson o "$1" --argjson i "$2" '
    any(.[]; .type=="PipeWire:Interface:Link" and
             .info.props["link.output.port"]==$o and .info.props["link.input.port"]==$i)' >/dev/null
}

echo "Connecting $SINK_NAME monitor_FL -> REAPER $REAPER_LEFT_PORT ; monitor_FR -> REAPER $REAPER_RIGHT_PORT"
if link_exists "$mon_fl" "$reaper_left"; then
  echo "  monitor_FL → $REAPER_LEFT_PORT already linked"
else
  pw-link "$mon_fl" "$reaper_left" || echo "  warning: failed to link $mon_fl -> $reaper_left"
fi
if link_exists "$mon_fr" "$reaper_right"; then
  echo "  monitor_FR → $REAPER_RIGHT_PORT already linked"
else
  pw-link "$mon_fr" "$reaper_right" || echo "  warning: failed to link $mon_fr -> $reaper_right"
fi
echo

###############################################################################
# If no Chrome/Zoom/Zen stream is open yet, wait for one. The virtual output is
# already wired to REAPER, so the stream only needs moving once it appears.
###############################################################################

if ((${#app_node_ids[@]} == 0)); then
  echo "No Chrome/Zoom/Zen playback stream yet; waiting for a call or video to start"
  echo "(checking every ${POLL_INTERVAL}s, Ctrl+C to stop)..."
  trap 'echo; echo "Stopped waiting. \"$SINK_DESCRIPTION\" stays wired to REAPER; remove it with: $(basename "$0") -k"; exit 130' INT
  while :; do
    sleep "$POLL_INTERVAL"
    find_app_streams
    if ((${#app_node_ids[@]} > 0)); then
      break
    fi
  done
  trap - INT
  find_app_streams print
fi

###############################################################################
# Move the open Chrome/Zoom/Zen playback streams into the virtual output.
# WirePlumber moves them (dropping their links to the speakers) and remembers
# the virtual output for each application.
###############################################################################

echo "Moving Chrome/Zoom/Zen playback streams to $SINK_NAME..."
for nid in "${app_node_ids[@]}"; do
  echo "  stream node $nid → $SINK_NAME"
  set_stream_target "$nid" "$sid" "$sink_serial"
done

echo "Done. Undo with: $(basename "$0") -k"
