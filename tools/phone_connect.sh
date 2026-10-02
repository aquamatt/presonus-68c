#!/usr/bin/env bash
# ABOUTME: Connects the Android phone over Bluetooth and routes the far end of its calls into
# ABOUTME: REAPER's in9 through a virtual "Phone to REAPER" output; -k undoes it.
#
# The computer acts as the phone's hands-free kit, a role PipeWire provides by itself. The
# phone's call streams are mono, 8 kHz (CVSD) or 16 kHz (mSBC). The direction towards the
# phone needs no routing: PipeWire feeds it from the default input, "Studio 68c Call Mic".
# Background: ~/src/presonus/README.md
set -euo pipefail

# Bluetooth address of the phone. Empty means the one paired device that BlueZ shows with
# the icon "phone", so that no address needs to be written down.
PHONE_MAC="${PHONE_MAC:-}"

# Regex matching REAPER's JACK ports
REAPER_PATTERN="${REAPER_PATTERN:-REAPER}"

# REAPER input that receives the far end. REAPER needs at least 9 JACK inputs for the
# default; in1-in6 are the Studio 68c's and in7/in8 are vc_connect.sh's.
REAPER_PHONE_PORT="${REAPER_PHONE_PORT:-in9}"

# Virtual output (a mono PipeWire null sink) that collects the far end of the call. Its
# monitor output feeds REAPER. WirePlumber remembers it as the target of the phone's call
# stream, so the streams of later calls land in it directly.
SINK_NAME="${SINK_NAME:-phone_to_reaper}"
SINK_DESCRIPTION="${SINK_DESCRIPTION:-Phone to REAPER}"

# Node expected to feed the phone (checked and reported, not changed)
CALL_MIC_NAME="${CALL_MIC_NAME:-s68c_call_mic}"

# Seconds between checks while waiting for a call to start
POLL_INTERVAL="${POLL_INTERVAL:-1}"

# Seconds allowed for the phone to connect
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-20}"

help() {
  cat <<EOF
Connects the Android phone to this computer over Bluetooth, as a hands-free kit, and
routes the far end of its calls into REAPER for recording, and back afterwards.

Without options, the script:

1. finds the phone: \$PHONE_MAC, or else the one paired device that BlueZ shows with
   the icon "phone";
2. checks that REAPER is running with an input $REAPER_PHONE_PORT;
3. connects the phone, unless it is connected already, and checks that its PipeWire
   profile is "audio-gateway";
4. creates a virtual output called "$SINK_DESCRIPTION" and wires it to REAPER's
   $REAPER_PHONE_PORT, removing anything else connected to that input;
5. moves the phone's call stream into the virtual output. The stream appears when a
   call starts, so if there is none yet the script waits, checking every
   $POLL_INTERVAL s; up to $POLL_INTERVAL s of the call then plays on the default output before
   it is moved. WirePlumber remembers the move, so later calls reach REAPER without
   running the script again.

The far end is then heard only through REAPER, which must monitor $REAPER_PHONE_PORT.
Your voice needs no routing: PipeWire feeds the phone from the default input,
"Studio 68c Call Mic", and REAPER records input 4 on in4. The script reports what
feeds the phone. Run it again whenever REAPER restarts its audio engine, because
REAPER then recreates its ports.

WirePlumber files the move under the stream's role, "Communication", so while the
virtual output exists, any other program playing with that role also lands in it.

With -k, the script sends an ongoing call back to the default output, makes
WirePlumber forget the move, removes the virtual output and disconnects the phone,
which otherwise sends every call to this computer. Without a call in progress
WirePlumber keeps the move, but with the virtual output gone, calls play on the
default output until the script runs again.

Usage:
  phone_connect.sh [-k] [-h]

Options:
  -k, --kill    Tear the routing down and disconnect the phone.
  -h, --help    Show this help.

Environment variables (default in brackets):
  PHONE_MAC     Bluetooth address of the phone, as AA:BB:CC:DD:EE:FF
                [the paired device with the icon "phone"]
  REAPER_PATTERN
                Regex matching REAPER's JACK ports [$REAPER_PATTERN]
  REAPER_PHONE_PORT
                REAPER input that receives the far end [$REAPER_PHONE_PORT]
  SINK_NAME, SINK_DESCRIPTION
                Node name and label of the virtual output [$SINK_NAME / $SINK_DESCRIPTION]
  CALL_MIC_NAME Node expected to feed the phone [$CALL_MIC_NAME]
  POLL_INTERVAL Seconds between checks while waiting for a call [$POLL_INTERVAL]
  CONNECT_TIMEOUT
                Seconds allowed for the phone to connect [$CONNECT_TIMEOUT]
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

for cmd in pw-dump pw-link pw-cli pw-metadata jq bluetoothctl timeout; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done

###############################################################################
# Helpers
###############################################################################

# Node id of the node with the given node.name; prints nothing if it does not exist
node_id() {
  pw-dump | jq -r --arg n "$1" '
    [.[] | select(.type=="PipeWire:Interface:Node" and .info.props["node.name"]==$n) | .id]
    | first // empty'
}

# Port id of a node's port, by node id and port name; prints nothing until it exists
node_port() {
  pw-dump | jq -r --argjson id "$1" --arg pn "$2" '
    [.[] | select(.type=="PipeWire:Interface:Port" and .info.props["node.id"]==$id and .info.props["port.name"]==$pn) | .id]
    | first // empty'
}

# Node id of one of the phone's call streams: "Stream/Output/Audio" carries the far end,
# "Stream/Input/Audio" goes to the phone. The phone's media (A2DP) streams have another
# profile and are left alone. Prints nothing while there is no call stream.
call_stream_id() {
  pw-dump | jq -r --arg mac "$phone" --arg class "$1" '
    [.[] | select(.type=="PipeWire:Interface:Node") | .info.props as $p |
     select($p["api.bluez5.address"]==$mac and
            $p["api.bluez5.profile"]=="headset-audio-gateway" and
            $p["media.class"]==$class) | .id]
    | first // empty'
}

# Point a stream node at a target (node id + object.serial), the way pipewire-pulse
# does when a stream is moved; "-1 -1" means "follow the default output" and makes
# WirePlumber forget the remembered target
set_stream_target() {
  pw-metadata -n default -- "$1" target.node "$2" Spa:Id >/dev/null
  pw-metadata -n default -- "$1" target.object "$3" Spa:Id >/dev/null
}

link_exists() {
  pw-dump | jq -e --argjson o "$1" --argjson i "$2" '
    any(.[]; .type=="PipeWire:Interface:Link" and
             .info.props["link.output.port"]==$o and .info.props["link.input.port"]==$i)' >/dev/null
}

# bluetoothctl's output is captured before matching: with pipefail, a grep -q that
# stops reading early could fail the pipeline even on a match
phone_connected() {
  local info
  info=$(bluetoothctl info "$phone")
  grep -Eq '^[[:space:]]*Connected: yes$' <<<"$info"
}

###############################################################################
# Find the phone
###############################################################################

if [[ -n "$PHONE_MAC" ]]; then
  phone="$PHONE_MAC"
else
  phones=()
  while read -r _ mac _; do
    info=$(bluetoothctl info "$mac") || continue
    if grep -Eq '^[[:space:]]*Icon: phone$' <<<"$info"; then
      phones+=("$mac")
    fi
  done < <(bluetoothctl devices Paired)
  if ((${#phones[@]} == 0)); then
    echo "No paired phone found. Pair it first (GNOME Settings > Bluetooth), or set PHONE_MAC."
    exit 1
  fi
  if ((${#phones[@]} > 1)); then
    echo "More than one paired phone; set PHONE_MAC to one of: ${phones[*]}"
    exit 1
  fi
  phone="${phones[0]}"
fi
phone_info=$(bluetoothctl info "$phone") || { echo "BlueZ does not know the phone $phone: is it paired?"; exit 1; }
phone_name=$(sed -n 's/^[[:space:]]*Alias: //p' <<<"$phone_info")
echo "Phone: ${phone_name:-unknown} ($phone)"
echo "REAPER input: $REAPER_PHONE_PORT"
echo "Virtual output: $SINK_NAME (\"$SINK_DESCRIPTION\")"
echo

###############################################################################
# Teardown (-k): send an ongoing call back to the default output, make
# WirePlumber forget the move, remove the virtual output, disconnect the phone
###############################################################################

if ((teardown)); then
  far_id=$(call_stream_id Stream/Output/Audio)
  if [[ -n "$far_id" ]]; then
    echo "  call stream node $far_id → default output"
    set_stream_target "$far_id" -1 -1
  else
    echo "No call in progress, so WirePlumber keeps the move; without the virtual"
    echo "output, calls play on the default output until this script runs again."
  fi

  sid=$(node_id "$SINK_NAME")
  if [[ -n "$sid" ]]; then
    echo "Removing virtual output $SINK_NAME (node $sid)"
    pw-cli destroy "$sid"
  else
    echo "Virtual output $SINK_NAME is not present."
  fi

  if phone_connected; then
    echo "Disconnecting the phone; its calls stay on the phone from now on."
    timeout "$CONNECT_TIMEOUT" bluetoothctl disconnect "$phone" >/dev/null || true
  else
    echo "The phone is not connected."
  fi
  echo "Done."
  exit 0
fi

###############################################################################
# Find the REAPER input ports that receive the far end. Checked before the phone
# is connected, so that a call is never moved away from the speakers into a
# REAPER that is not there.
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

# Port id of the REAPER input with the given name; prints nothing if there is none
reaper_port() {
  local line pid pname palias
  for line in "${reaper_ports[@]}"; do
    read -r pid pname palias <<<"$line"
    if [[ "$pname" == "$1" || "$palias" == *":$1" ]]; then
      echo "$pid"
      return 0
    fi
  done
}

reaper_phone=$(reaper_port "$REAPER_PHONE_PORT")
[[ -z "$reaper_phone" ]] && { echo "REAPER $REAPER_PHONE_PORT not found (is REAPER running, with enough JACK inputs?)"; exit 1; }

echo "Using REAPER port $REAPER_PHONE_PORT = $reaper_phone"
echo

###############################################################################
# Connect the phone and check its PipeWire profile. "audio-gateway" carries
# both its calls (HFP) and its media (A2DP); WirePlumber normally selects it.
###############################################################################

if phone_connected; then
  echo "The phone is connected."
else
  echo "Connecting the phone..."
  timeout "$CONNECT_TIMEOUT" bluetoothctl connect "$phone" >/dev/null || true
  phone_connected || { echo "The phone did not connect: is its Bluetooth on, and is it in range?"; exit 1; }
fi

card_name="bluez_card.${phone//:/_}"
card_id=""
for _ in {1..20}; do
  card_id=$(pw-dump | jq -r --arg c "$card_name" '
    [.[] | select(.type=="PipeWire:Interface:Device" and .info.props["device.name"]==$c) | .id]
    | first // empty')
  [[ -n "$card_id" ]] && break
  sleep 0.5
done
[[ -z "$card_id" ]] && { echo "PipeWire shows no audio device for the phone ($card_name)"; exit 1; }

profile=$(pw-dump | jq -r --argjson d "$card_id" '.[] | select(.id==$d) | .info.params.Profile[0]?.name // empty')
if [[ "$profile" != "audio-gateway" ]]; then
  idx=$(pw-dump | jq -r --argjson d "$card_id" '
    .[] | select(.id==$d) | .info.params.EnumProfile[]? | select(.name=="audio-gateway") | .index')
  if [[ -z "$idx" ]]; then
    echo "The phone offers no call audio: in its Bluetooth settings for this computer,"
    echo "check that \"Phone calls\" is allowed."
    exit 1
  fi
  # Saved, because WirePlumber 0.4 restores a saved profile before applying any rule
  echo "Switching the phone's profile from \"${profile:-none}\" to \"audio-gateway\""
  pw-cli set-param "$card_id" Profile "{ index: $idx, save: true }" >/dev/null
fi
echo

###############################################################################
# Create the virtual output unless it exists already
###############################################################################

sid=$(node_id "$SINK_NAME")
if [[ -z "$sid" ]]; then
  echo "Creating virtual output $SINK_NAME..."
  # The same settings as vc_connect.sh's virtual output, in mono: object.linger keeps
  # the node after pw-cli exits, and with monitor.channel-volumes left off the monitor
  # carries the audio at unity gain whatever the output's volume.
  pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$SINK_NAME node.description=\"$SINK_DESCRIPTION\" media.class=Audio/Sink object.linger=true audio.position=[MONO] monitor.passthrough=true }" >/dev/null
  for _ in {1..30}; do
    sid=$(node_id "$SINK_NAME")
    [[ -n "$sid" ]] && break
    sleep 0.1
  done
  [[ -z "$sid" ]] && { echo "Virtual output $SINK_NAME did not appear"; exit 1; }
fi

sink_serial=$(pw-dump | jq -r --argjson id "$sid" '.[] | select(.id==$id) | .info.props["object.serial"]')

mon=""
for _ in {1..30}; do
  mon=$(node_port "$sid" monitor_MONO)
  [[ -n "$mon" ]] && break
  sleep 0.1
done
[[ -z "$mon" ]] && { echo "Monitor port of $SINK_NAME did not appear"; exit 1; }

echo "Virtual output: node $sid (serial $sink_serial), monitor_MONO=$mon"
echo

###############################################################################
# Disconnect anything else feeding the REAPER input, so that it carries only the
# phone: REAPER auto-connects its inputs in order to hardware capture ports. The
# virtual output's own link is kept, so re-running causes no dropout.
###############################################################################

echo "Scanning existing links into REAPER $REAPER_PHONE_PORT..."

mapfile -t reaper_links < <(
  pw-dump | jq -r --argjson port "$reaper_phone" --argjson mon "$mon" '
    . as $all |
    $all[] | select(.type=="PipeWire:Interface:Link") |
    .info.props as $lp |
    select($lp["link.input.port"] == $port and $lp["link.output.port"] != $mon) |

    # Output side alias for info
    ($all[] | select(.type=="PipeWire:Interface:Port" and .id == $lp["link.output.port"])) as $outport |

    "\(.id) \($lp["link.output.port"]) \($lp["link.input.port"]) \($outport.info.props["port.alias"]//"")"
  '
)

if ((${#reaper_links[@]} > 0)); then
  echo "Disconnecting other links into REAPER $REAPER_PHONE_PORT:"
  for l in "${reaper_links[@]}"; do
    read -r lid outp inp outp_alias <<<"$l"
    printf "  link %-4s OUT=%-4s (%s) -> %-4s\n" "$lid" "$outp" "$outp_alias" "$inp"
    pw-cli destroy "$lid" || echo "Failed to delete link $lid"
  done
else
  echo "Nothing else connected to REAPER $REAPER_PHONE_PORT."
fi
echo

###############################################################################
# Wire the virtual output to REAPER: monitor_MONO -> in9
###############################################################################

echo "Connecting $SINK_NAME monitor_MONO -> REAPER $REAPER_PHONE_PORT"
if link_exists "$mon" "$reaper_phone"; then
  echo "  monitor_MONO → $REAPER_PHONE_PORT already linked"
else
  pw-link "$mon" "$reaper_phone" || echo "  warning: failed to link $mon -> $reaper_phone"
fi
echo

###############################################################################
# If no call is in progress, wait for one. The virtual output is already wired
# to REAPER, so the far-end stream only needs moving once it appears.
###############################################################################

far_id=$(call_stream_id Stream/Output/Audio)
if [[ -z "$far_id" ]]; then
  echo "No call stream yet; waiting for a call to start (checking every ${POLL_INTERVAL}s, Ctrl+C to stop)."
  echo "If a call is in progress and nothing happens, choose this computer as the call's"
  echo "audio output on the phone, and check that \"Phone calls\" is allowed for it."
  trap 'echo; echo "Stopped waiting. \"$SINK_DESCRIPTION\" stays wired to REAPER; remove it with: $(basename "$0") -k"; exit 130' INT
  while :; do
    sleep "$POLL_INTERVAL"
    far_id=$(call_stream_id Stream/Output/Audio)
    [[ -n "$far_id" ]] && break
  done
  trap - INT
fi

codec=$(pw-dump | jq -r --argjson id "$far_id" '.[] | select(.id==$id) | .info.props["api.bluez5.codec"] // "unknown"')
echo "Call stream: node $far_id, codec $codec"

###############################################################################
# Move the far end into the virtual output. WirePlumber drops its link to the
# default output, links it to the virtual output and remembers the move.
###############################################################################

echo "  call stream node $far_id → $SINK_NAME"
set_stream_target "$far_id" "$sid" "$sink_serial"

# Report whether the move took effect and what feeds the phone
far_linked=0
for _ in {1..30}; do
  if pw-dump | jq -e --argjson f "$far_id" --argjson s "$sid" '
       any(.[]; .type=="PipeWire:Interface:Link" and
                .info.props["link.output.node"]==$f and .info.props["link.input.node"]==$s)' >/dev/null; then
    far_linked=1
    break
  fi
  sleep 0.1
done
((far_linked)) || echo "  warning: the call stream is not linked to $SINK_NAME yet; check with: pw-link -l"

near_id=$(call_stream_id Stream/Input/Audio)
if [[ -n "$near_id" ]]; then
  feeding=$(pw-dump | jq -r --argjson n "$near_id" '
    . as $all |
    [$all[] | select(.type=="PipeWire:Interface:Link" and .info.props["link.input.node"]==$n)
     | .info.props["link.output.node"]] | unique | .[] as $o |
    $all[] | select(.id==$o) | .info.props["node.name"]')
  echo "The phone hears: ${feeding:-nothing}"
  [[ "$feeding" == "$CALL_MIC_NAME" ]] || echo "  warning: expected $CALL_MIC_NAME; check the default input with: wpctl status"
else
  echo "  warning: no stream towards the phone found"
fi

echo "Done. Undo with: $(basename "$0") -k"
