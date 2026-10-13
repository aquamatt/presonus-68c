#!/usr/bin/env bash
# ABOUTME: Checks the call audio routing of the Studio 68c setup: the Call Mic's feed, the
# ABOUTME: defaults, and the call programs' microphones and sound; -f repairs, -w watches.
#
# Every check reads the same pw-dump snapshot, judged by one jq program. Background:
# ~/src/presonus/README.md
set -euo pipefail

# Node names of the Call Mic and of its capture half, both created by 60-studio68c.conf
CALL_MIC_NAME="${CALL_MIC_NAME:-s68c_call_mic}"
CALL_MIC_CAPTURE_NAME="${CALL_MIC_CAPTURE_NAME:-capture.s68c_call_mic}"

# Node name of the output that should be the default: the 68c's Pro Audio output
OUTPUT_NAME="${OUTPUT_NAME:-alsa_output.usb-PreSonus_Studio_68c_0132B680-00.pro-output-0}"

# Case-insensitive regex matching the application.name of the call programs' streams:
# Chrome ("Google Chrome", "Google Chrome input"), Chromium, Zen, Firefox, Zoom ("ZOOM
# VoiceEngine") and Signal ("Signal", "Signal Calling", "ringrtc")
PROGRAMS_PATTERN="${PROGRAMS_PATTERN:-^((google chrome|chromium)( input)?|zen|firefox|zoom voiceengine|signal( calling)?|ringrtc)$}"

# Virtual output created by vc_connect.sh, and the REAPER inputs that its monitor feeds
VC_SINK_NAME="${VC_SINK_NAME:-vc_to_reaper}"
REAPER_NODE_PATTERN="${REAPER_NODE_PATTERN:-^REAPER}"
REAPER_LEFT_PORT="${REAPER_LEFT_PORT:-in7}"
REAPER_RIGHT_PORT="${REAPER_RIGHT_PORT:-in8}"

# Saved pw-dump output to check instead of the live graph, for testing; -f and -w refuse it
PW_DUMP_FILE="${PW_DUMP_FILE:-}"

# Seconds between the watchdog's checks (-w)
WATCH_INTERVAL="${WATCH_INTERVAL:-2}"

# Seconds the watchdog waits before confirming a fault, and after repairing
WATCH_SETTLE=1

help() {
  cat <<EOF
Checks that call audio is routed the way this Studio 68c setup expects, and with -f
repairs what it can. The checks, in the order they are reported:

Call Mic     "Studio 68c Call Mic" exists and is fed by the 68c input that its
             configuration names (input 4, capture_AUX3), and by nothing else.
Defaults     The default input is the Call Mic, and the default output is the 68c's
             Pro Audio output.
Microphones  Every microphone stream of Chrome, Zen, Zoom, Firefox and Signal is fed
             by the Call Mic and by nothing else.
Sound        Every sound stream of those programs plays to one place only. A stream
             playing into "Vidconf to REAPER" and straight to the 68c as well is heard
             twice, slightly apart, like a chorus. While a program plays into
             "Vidconf to REAPER", that output must feed REAPER's $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT,
             or the call cannot be heard. While "Vidconf to REAPER" exists,
             nothing else may feed $REAPER_LEFT_PORT or $REAPER_RIGHT_PORT: REAPER connects them to the
             built-in analogue input whenever it starts its audio engine, which
             mixes that input into the call.

Without options nothing is changed, so the script is safe to run during a call. The
exit status is 0 when everything is correct and 1 when anything is not.

With -f, the script repairs the faults whose hint starts with "-f", then checks again:
  - it connects the Call Mic to the 68c input, and the call programs' microphones to
    the Call Mic, wherever those links are missing;
  - it disconnects anything else feeding the Call Mic or those microphones;
  - it disconnects a sound stream that plays to several places from all of them but
    "Vidconf to REAPER", when REAPER is running with its $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT, or else the
    default output;
  - it connects "Vidconf to REAPER" to REAPER's $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT, as vc_connect.sh does,
    when a call program plays into it and those links are missing: REAPER drops them
    whenever it restarts its audio engine;
  - it disconnects everything but "Vidconf to REAPER" from REAPER's $REAPER_LEFT_PORT/$REAPER_RIGHT_PORT, as
    vc_connect.sh -c does for hardware;
  - it sets the default input and output.
Wrong defaults are set first, because WirePlumber then moves the streams that follow
them; the links are judged again before they are repaired. -f only adds and removes
links and sets the defaults. It never restarts PipeWire or REAPER, and never changes the
68c's profile, so it is safe during a call too.

Faults whose hint starts with "by hand" are left alone: a missing Call Mic or 68c
input, a program set to use another microphone (choose "Studio 68c Call Mic" in the
program instead), a sound stream connected to nothing, and REAPER not running while a
call plays into "Vidconf to REAPER" (start REAPER, or run vc_connect.sh -k).

With -w, the script stays running as a watchdog until stopped with Ctrl+C: every
$WATCH_INTERVAL s it checks again and repairs what -f would, by itself. A fault is acted on
only when a second check, $WATCH_SETTLE s later, finds it too, because a stream that is
starting up looks wrong until WirePlumber has linked it. Wrong defaults are repaired in
one round and the links in the next. Each repair, and each fault the watchdog cannot
repair, is printed with the time, written to the journal (journalctl --user -t
check_call_audio) and shown as a desktop notification, once per fault; a fault
repaired for the third time is notified again, because something keeps undoing the
repair. The watchdog undoes deliberate changes too, such as a link made by hand in
qpwgraph or another default output chosen in GNOME Settings, so stop it before making
them. Only one watchdog runs at a time.

WirePlumber 0.4 does not put back a link that something else removed while both of
its ends still exist. That is how the Call Mic can go silent with nothing else wrong,
and -f and -w restore such links.

Usage:
  check_call_audio.sh [-f | -w] [-h]

Options:
  -f, --fix     Repair the faults whose hint starts with "-f", then check again.
  -w, --watch   Keep checking every $WATCH_INTERVAL s and repairing, until Ctrl+C.
  -h, --help    Show this help.

Environment variables (default in brackets):
  CALL_MIC_NAME, CALL_MIC_CAPTURE_NAME
                Node names of the Call Mic and of its capture half
                [$CALL_MIC_NAME / $CALL_MIC_CAPTURE_NAME]
  OUTPUT_NAME   Node name of the expected default output
                [$OUTPUT_NAME]
  PROGRAMS_PATTERN
                Case-insensitive regex matching the application.name of the call
                programs' streams
                [$PROGRAMS_PATTERN]
  VC_SINK_NAME  Node name of vc_connect.sh's virtual output [$VC_SINK_NAME]
  REAPER_NODE_PATTERN
                Case-insensitive regex matching REAPER's node name [$REAPER_NODE_PATTERN]
  REAPER_LEFT_PORT, REAPER_RIGHT_PORT
                REAPER inputs fed by the virtual output [$REAPER_LEFT_PORT / $REAPER_RIGHT_PORT]
  PW_DUMP_FILE  Saved pw-dump output to check instead of the live graph, for testing;
                -f and -w refuse it [unset]
  WATCH_INTERVAL
                Seconds between the watchdog's checks [$WATCH_INTERVAL]
EOF
}

fix=0
watch=0
while (($#)); do
  case "$1" in
    -f|--fix) fix=1 ;;
    -w|--watch) watch=1 ;;
    -h|--help) help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo >&2; help >&2; exit 2 ;;
  esac
  shift
done

if ((fix && watch)); then
  echo "Use -f or -w, not both." >&2
  exit 2
fi

for cmd in pw-dump pw-link pw-cli wpctl jq; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done
if ((watch)); then
  for cmd in flock logger; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
  done
fi

if ((fix || watch)) && [[ -n "$PW_DUMP_FILE" ]]; then
  echo "-f and -w repair the live graph only; unset PW_DUMP_FILE to use them." >&2
  exit 2
fi

# One watchdog at a time: two would race each other's repairs
if ((watch)); then
  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/check_call_audio.lock"
  if ! flock -n 9; then
    echo "A check_call_audio.sh watchdog is already running." >&2
    exit 1
  fi
fi

###############################################################################
# The checks. The jq program prints one tab-separated line per finding: kind,
# section, text. "ok" and "fault" are results; "hint" says what -f, or the user,
# can do about the fault before it; "note" is information, not a fault; "do" is a
# repair for -f: "link <output port id> <input port id>", "unlink <link id>" or
# "default <node id>".
###############################################################################

CHECKS_JQ=$(cat <<'EOF'
. as $all
| [$all[] | select(.type == "PipeWire:Interface:Node")] as $nodes
| [$all[] | select(.type == "PipeWire:Interface:Port")] as $ports
| [$all[] | select(.type == "PipeWire:Interface:Link")] as $links
| [$all[] | select(.type == "PipeWire:Interface:Metadata" and .props["metadata.name"] == "default")
   | .metadata[]?] as $meta

| def rec($kind; $section; $text): [$kind, $section, $text] | @tsv;
  def node_by_id($id): first($nodes[] | select(.id == $id)) // null;
  def node_by_name($name): first($nodes[] | select(.info.props["node.name"] == $name)) // null;
  # A node referred to by object.serial or node.name, as target.object does
  def node_by_ref($ref):
    first($nodes[] | select((.info.props["object.serial"] | tostring) == $ref
                            or .info.props["node.name"] == $ref)) // null;
  def port_by_id($id): first($ports[] | select(.id == $id)) // null;
  def node_ports($node; $direction):
    [$ports[] | select(.info.props["node.id"] == $node.id and .info.direction == $direction)];
  def node_label($node):
    if $node == null then "(gone)"
    else $node.info.props["node.description"] // $node.info.props["node.nick"]
         // $node.info.props["node.name"] // "node \($node.id)" end;
  def name_label($name):
    node_by_name($name) as $node | if $node == null then ($name // "unset") else node_label($node) end;
  def stream_label($node): "\($node.info.props["application.name"]) (node \($node.id))";
  def port_label($port):
    if $port == null then "(gone)"
    else "\(node_label(node_by_id($port.info.props["node.id"]))) \($port.info.props["port.name"])" end;
  def meta($subject; $key):
    first($meta[] | select(.subject == $subject and .key == $key) | .value) // null;
  def default_name($key): meta(0; $key) | if type == "object" then .name else . end;
  def is_program: (.info.props["application.name"] // "") | test($programs; "i");
  # The node a stream has been told to use, in the order WirePlumber 0.4 reads them: the
  # target.object then target.node metadata, then the stream's own target.object and
  # node.target. Null when the stream follows the default; {missing: ref} when the node
  # it names does not exist.
  def chosen_target($stream):
    def ref($value): if $value == null then null else $value | tostring end;
    ref(meta($stream.id; "target.object")) as $meta_object
    | ref(meta($stream.id; "target.node")) as $meta_node
    | ref($stream.info.props["target.object"]) as $prop_object
    | ref($stream.info.props["node.target"]) as $prop_node
    | if $meta_object != null then
        (if $meta_object == "-1" then null else node_by_ref($meta_object) // {missing: $meta_object} end)
      elif $meta_node != null then
        (if $meta_node == "-1" then null
         else node_by_id($meta_node | tonumber? // null) // {missing: $meta_node} end)
      elif $prop_object != null then node_by_ref($prop_object) // {missing: $prop_object}
      elif $prop_node != null then node_by_id($prop_node | tonumber? // null) // {missing: $prop_node}
      else null end;

  node_by_name($mic) as $mic_node
| node_by_name($capture) as $capture_node
| node_by_name($output) as $output_node
| node_by_name($vc) as $vc_node
| [$nodes[] | select((.info.props["node.name"] // "") | test($reaper; "i"))] as $reapers

# How the virtual output's monitor ports reach REAPER's inputs
| ( if $vc_node == null then []
    else [ [["monitor_FL", $left], ["monitor_FR", $right]][] as [$monitor, $input]
           | (first(node_ports($vc_node; "output")[] | select(.info.props["port.name"] == $monitor))
              // null) as $from
           | (first($ports[] | select(.info.direction == "input" and .info.props["port.name"] == $input
                                      and (.info.props["node.id"] as $id | any($reapers[]; .id == $id))))
              // null) as $to
           | {monitor: $monitor, input: $input, from: $from, to: $to,
              linked: ($from != null and $to != null
                       and any($links[]; .info["output-port-id"] == $from.id
                                         and .info["input-port-id"] == $to.id))} ]
    end ) as $vc_wiring
# Whether the virtual output can feed REAPER: both of its monitor ports and both REAPER
# inputs exist, linked or not
| ($vc_node != null and ($vc_wiring | length) == 2
   and all($vc_wiring[]; .from != null and .to != null)) as $vc_reaches_reaper

# Call Mic: both halves exist, and the 68c input named in its configuration feeds the
# capture half, alone
| ( if $mic_node == null or $capture_node == null then
      rec("fault"; "Call Mic"; "\($mic) does not exist"),
      rec("hint"; "Call Mic"; "by hand: install 60-studio68c.conf and restart PipeWire (README)")
    else
      ($capture_node.info.props["target.object"] // "" | tostring) as $ref
      | node_by_ref($ref) as $source
      | if $source == null then
          rec("fault"; "Call Mic"; "the input it reads, \($ref), does not exist"),
          rec("hint"; "Call Mic"; "by hand: connect the 68c and select its Pro Audio profile (README)")
        else
          ($capture_node.info.props["audio.position"] // "" | [scan("[A-Za-z0-9_]+")])[] as $channel
          | (first(node_ports($source; "output")[] | select(.info.props["audio.channel"] == $channel))
             // null) as $from
          | (first(node_ports($capture_node; "input")[] | select(.info.props["audio.channel"] == $channel))
             // null) as $to
          | if $from == null or $to == null then
              rec("fault"; "Call Mic"; "\(if $from == null then node_label($source) else $capture end) has no \($channel) port"),
              rec("hint"; "Call Mic"; "by hand: check 60-studio68c.conf against the 68c's profile (README)")
            else
              [$links[] | select(.info["input-port-id"] == $to.id)] as $in
              | ( if any($in[]; .info["output-port-id"] == $from.id) then
                    rec("ok"; "Call Mic"; "fed by \(port_label($from))")
                  else
                    rec("fault"; "Call Mic"; "nothing connects \(port_label($from)) to the Call Mic, so it is silent"),
                    rec("hint"; "Call Mic"; "-f connects it to \($capture) \($to.info.props["port.name"])"),
                    rec("do"; "Call Mic"; "link \($from.id) \($to.id)")
                  end ),
                ( $in[] | select(.info["output-port-id"] != $from.id)
                  | rec("fault"; "Call Mic"; "also fed by \(port_label(port_by_id(.info["output-port-id"])))"),
                    rec("hint"; "Call Mic"; "-f disconnects it"),
                    rec("do"; "Call Mic"; "unlink \(.id)") )
            end
        end
    end )

# Defaults: the Call Mic for input, the 68c's Pro Audio output for output
, ( default_name("default.audio.source") as $current
    | if $mic_node == null then
        rec("note"; "Defaults"; "input not checked, because the Call Mic does not exist")
      elif $current == $mic then rec("ok"; "Defaults"; "input: \(node_label($mic_node))")
      else
        rec("fault"; "Defaults"; "the default input is \(name_label($current)), not the Call Mic"),
        rec("hint"; "Defaults"; "-f makes the Call Mic the default input"),
        rec("do"; "Defaults"; "default \($mic_node.id)")
      end )
, ( default_name("default.audio.sink") as $current
    | if $output_node == null then
        rec("fault"; "Defaults"; "the expected default output, \($output), does not exist"),
        rec("hint"; "Defaults"; "by hand: connect the 68c and select its Pro Audio profile (README)")
      elif $current == $output then rec("ok"; "Defaults"; "output: \(node_label($output_node))")
      else
        rec("fault"; "Defaults"; "the default output is \(name_label($current)), not \(node_label($output_node))"),
        rec("hint"; "Defaults"; "-f makes \(node_label($output_node)) the default output"),
        rec("do"; "Defaults"; "default \($output_node.id)")
      end )

# Microphones: each call program's capture stream is fed by the Call Mic alone. A stream
# that the program has pointed at another device is reported, not changed.
, ( [$nodes[] | select(.info.props["media.class"] == "Stream/Input/Audio" and is_program)] as $streams
    | if ($streams | length) == 0 then rec("ok"; "Microphones"; "no call program has a microphone open")
      elif $mic_node == null then rec("note"; "Microphones"; "not checked, because the Call Mic does not exist")
      else
        $streams[] as $stream
        | chosen_target($stream) as $target
        | if ($target != null and $target.id != $mic_node.id)
             or ($stream.info.props["stream.capture.sink"] | tostring) == "true" then
            rec("fault"; "Microphones"; "\(stream_label($stream)) is set to use \(
                if $target == null then "the sound of the default output"
                elif $target.missing then "\($target.missing), which does not exist"
                elif $target.info.props["media.class"] == "Audio/Sink" then "the sound of \(node_label($target))"
                else node_label($target) end), not the Call Mic"),
            rec("hint"; "Microphones"; "by hand: choose Studio 68c Call Mic as the microphone in the program")
          else
            [$links[] | select(.info["input-node-id"] == $stream.id)] as $in
            | node_ports($mic_node; "output") as $mic_ports
            | [ node_ports($stream; "input")[] as $port
                | (first($mic_ports[] | select(.info.props["audio.channel"] == $port.info.props["audio.channel"]))
                   // $mic_ports[0]) as $mic_port
                | select($mic_port != null)
                | select(any($in[]; .info["output-port-id"] == $mic_port.id
                                    and .info["input-port-id"] == $port.id) | not)
                | {from: $mic_port, to: $port} ] as $missing
            | [$in[] | select(.info["output-node-id"] != $mic_node.id)] as $foreign
            | if ($missing | length) == 0 and ($foreign | length) == 0 then
                rec("ok"; "Microphones"; "\(stream_label($stream)): \(node_label($mic_node))")
              else
                ( $foreign[]
                  | rec("fault"; "Microphones"; "\(stream_label($stream)) is fed by \(port_label(port_by_id(.info["output-port-id"])))"),
                    rec("hint"; "Microphones"; "-f disconnects it"),
                    rec("do"; "Microphones"; "unlink \(.id)") ),
                ( $missing[]
                  | rec("fault"; "Microphones"; "\(stream_label($stream)) \(.to.info.props["port.name"]) is not fed by the Call Mic"),
                    rec("hint"; "Microphones"; "-f connects \(port_label(.from)) to it"),
                    rec("do"; "Microphones"; "link \(.from.id) \(.to.id)") )
              end
          end
      end )

# Sound: each call program's playback stream reaches one node only. A stream that reaches
# several keeps "Vidconf to REAPER" when that can feed REAPER (the check below connects
# it), or else the default output.
, ( [$nodes[] | select(.info.props["media.class"] == "Stream/Output/Audio" and is_program)] as $streams
    | if ($streams | length) == 0 then rec("ok"; "Sound"; "no call program is playing")
      else
        $streams[] as $stream
        | [$links[] | select(.info["output-node-id"] == $stream.id)] as $out
        | ($out | map(.info["input-node-id"]) | unique) as $destinations
        | if ($destinations | length) == 0 then
            rec("fault"; "Sound"; "\(stream_label($stream)) is connected to nothing, so it cannot be heard"),
            rec("hint"; "Sound"; "by hand: connect it in qpwgraph, or restart the program's sound")
          elif ($destinations | length) == 1 then
            rec("ok"; "Sound"; "\(stream_label($stream)): \(node_label(node_by_id($destinations[0])))")
          else
            ( if $vc_reaches_reaper and any($destinations[]; . == $vc_node.id) then $vc_node.id
              elif $output_node != null and any($destinations[]; . == $output_node.id) then $output_node.id
              elif $vc_node != null and any($destinations[]; . == $vc_node.id) then $vc_node.id
              else null end ) as $keep
            | rec("fault"; "Sound"; "\(stream_label($stream)) plays to \([$destinations[] | node_label(node_by_id(.))] | join(" and ")) at once"),
              ( if $keep == null then
                  rec("hint"; "Sound"; "by hand: disconnect all but one of them in qpwgraph")
                else
                  rec("hint"; "Sound"; "-f keeps \(node_label(node_by_id($keep))) and disconnects the rest"),
                  ( $out[] | select(.info["input-node-id"] != $keep) | rec("do"; "Sound"; "unlink \(.id)") )
                end )
          end
      end )

# Sound: while a call program plays into the virtual output, its monitor feeds REAPER.
# REAPER drops those links whenever it restarts its audio engine; they are repaired as
# vc_connect.sh makes them, when both ends exist.
, ( if $vc_node != null
       and any($links[]; .info["input-node-id"] == $vc_node.id
                         and (node_by_id(.info["output-node-id"]) as $node
                              | $node != null and ($node | is_program))) then
      if ($reapers | length) == 0 then
        rec("fault"; "Sound"; "\(node_label($vc_node)) carries call sound, but REAPER is not running, so it cannot be heard"),
        rec("hint"; "Sound"; "by hand: start REAPER and run vc_connect.sh, or run vc_connect.sh -k")
      else
        $vc_wiring[]
        | if .linked then rec("ok"; "Sound"; "\(node_label($vc_node)) \(.monitor) feeds REAPER \(.input)")
          elif .from != null and .to != null then
            rec("fault"; "Sound"; "\(node_label($vc_node)) \(.monitor) does not feed REAPER \(.input), so the call cannot be heard"),
            rec("hint"; "Sound"; "-f connects it, as vc_connect.sh does"),
            rec("do"; "Sound"; "link \(.from.id) \(.to.id)")
          else
            rec("fault"; "Sound"; "\(node_label($vc_node)) \(.monitor) does not feed REAPER \(.input), so the call cannot be heard"),
            rec("hint"; "Sound"; if .to == null then "by hand: give REAPER an input named \(.input), then run vc_connect.sh"
                                 else "by hand: run vc_connect.sh" end)
          end
      end
    else empty end )

# Sound: while the virtual output exists, nothing else feeds REAPER's two call inputs.
# REAPER connects them to the built-in analogue input whenever it starts its audio
# engine, which mixes that input into the call. Each link is judged on its own, so one or
# both channels on one or both inputs are all found. Call programs' own links are judged
# with their sound streams above.
, ( if $vc_node == null then empty
    else
      [$ports[] | select(.info.direction == "input"
                         and (.info.props["port.name"] == $left or .info.props["port.name"] == $right)
                         and (.info.props["node.id"] as $id | any($reapers[]; .id == $id)))] as $reaper_inputs
      | [ $reaper_inputs[] as $input
          | $links[]
          | select(.info["input-port-id"] == $input.id and .info["output-node-id"] != $vc_node.id)
          | select(node_by_id(.info["output-node-id"]) as $node | $node == null or ($node | is_program | not))
          | {link: ., input: $input, from: port_by_id(.info["output-port-id"])} ] as $extra
      | if ($reaper_inputs | length) == 0 then empty
        elif ($extra | length) == 0 then
          rec("ok"; "Sound"; "nothing but \(node_label($vc_node)) feeds REAPER \($left) and \($right)")
        else
          $extra[]
          | rec("fault"; "Sound"; "REAPER \(.input.info.props["port.name"]) is also fed by \(port_label(.from)), which is mixed into the call"),
            rec("hint"; "Sound"; "-f disconnects it\(if (.from.info.props["port.physical"] // false | tostring) == "true"
                                                     then ", as vc_connect.sh -c does" else "" end)"),
            rec("do"; "Sound"; "unlink \(.link.id)")
        end
    end )
EOF
)

###############################################################################
# Helpers
###############################################################################

# Judges a fresh snapshot of the graph; fills findings. Returns 1 when the graph cannot
# be read, for example while PipeWire restarts.
run_checks() {
  local dump out
  if [[ -n "$PW_DUMP_FILE" ]]; then
    dump=$(cat "$PW_DUMP_FILE") || return 1
  else
    dump=$(pw-dump 2>/dev/null) || return 1
  fi
  out=$(jq -r \
    --arg mic "$CALL_MIC_NAME" --arg capture "$CALL_MIC_CAPTURE_NAME" \
    --arg output "$OUTPUT_NAME" --arg programs "$PROGRAMS_PATTERN" \
    --arg vc "$VC_SINK_NAME" --arg reaper "$REAPER_NODE_PATTERN" \
    --arg left "$REAPER_LEFT_PORT" --arg right "$REAPER_RIGHT_PORT" \
    "$CHECKS_JQ" <<<"$dump") || return 1
  [[ -n "$out" ]] || return 1
  mapfile -t findings <<<"$out"
}

# From the findings: counts the faults, lists them as "section: text" in fault_texts,
# and collects the repairs (the "do" lines). hint_for maps each fault to its hint, and
# repairable marks the faults that have a repair.
tally() {
  local line kind section text fault=""
  faults=0
  fault_texts=()
  repairs=()
  declare -gA hint_for=() repairable=()
  hint_for=()
  repairable=()
  for line in "${findings[@]}"; do
    IFS=$'\t' read -r kind section text <<<"$line"
    case "$kind" in
      fault)
        faults=$((faults + 1))
        fault="$section: $text"
        fault_texts+=("$fault")
        ;;
      hint)
        if [[ -n "$fault" ]]; then hint_for["$fault"]="$text"; fi
        ;;
      do)
        repairs+=("$text")
        if [[ -n "$fault" ]]; then repairable["$fault"]=1; fi
        ;;
    esac
  done
}

# Prints the findings, section by section
report() {
  local line kind section text current=""
  for line in "${findings[@]}"; do
    IFS=$'\t' read -r kind section text <<<"$line"
    if [[ "$section" != "$current" ]]; then
      [[ -n "$current" ]] && echo
      echo "$section"
      current="$section"
    fi
    case "$kind" in
      ok) echo "  ok     $text" ;;
      fault) echo "  FAULT  $text" ;;
      note) echo "  --     $text" ;;
      hint) echo "         $text" ;;
    esac
  done
  echo
}

# Carries out repairs given as "link <out> <in>", "unlink <link>" or "default <node>"
apply_repairs() {
  local repair action first second
  for repair in "$@"; do
    read -r action first second <<<"$repair"
    case "$action" in
      link)
        echo "  pw-link $first $second"
        pw-link "$first" "$second" || echo "    failed"
        ;;
      unlink)
        echo "  pw-cli destroy $first"
        pw-cli destroy "$first" >/dev/null || echo "    failed"
        ;;
      default)
        echo "  wpctl set-default $first"
        wpctl set-default "$first" || echo "    failed"
        ;;
    esac
  done
}

# Prints a message with the time and writes it to the journal; given a title, also shows
# it as a desktop notification of the given urgency
announce() {
  local message="$1" title="${2:-}" urgency="${3:-normal}"
  echo "$(date '+%F %T')  $message"
  logger -t check_call_audio "$message" 2>/dev/null || true
  if [[ -n "$title" ]] && command -v notify-send >/dev/null; then
    notify-send -a check_call_audio -u "$urgency" "$title" "$message" 2>/dev/null || true
  fi
}

# The watchdog (-w): checks every WATCH_INTERVAL s and repairs what -f would, until
# stopped. A fault, and its repair, count only when a second check WATCH_SETTLE s later
# finds them too. Wrong defaults are repaired alone, and the links on the next round,
# after WirePlumber has moved the streams that follow the defaults.
watch_audio() {
  local repair fault hint defaults_round graph_lost=0
  local -a confirmed=() confirmed_faults=() defaults=()
  local -A first_repairs=() first_faults=() present=() notified=() kept=() times_repaired=()

  trap 'echo; announce "stopped watching"; exit 0' INT TERM
  announce "watching call audio every $WATCH_INTERVAL s; Ctrl+C stops"

  while :; do
    if ! run_checks; then
      if ((!graph_lost)); then
        announce "cannot read the PipeWire graph; trying again every $WATCH_INTERVAL s"
        graph_lost=1
      fi
      sleep "$WATCH_INTERVAL"
      continue
    fi
    if ((graph_lost)); then
      announce "reading the PipeWire graph again"
      graph_lost=0
    fi
    tally
    if ((faults == 0)); then
      notified=()
      sleep "$WATCH_INTERVAL"
      continue
    fi

    # Confirm: keep only the faults and repairs that a second check finds as well
    first_repairs=()
    first_faults=()
    for repair in "${repairs[@]}"; do first_repairs["$repair"]=1; done
    for fault in "${fault_texts[@]}"; do first_faults["$fault"]=1; done
    sleep "$WATCH_SETTLE"
    run_checks || continue
    tally
    confirmed=()
    confirmed_faults=()
    for repair in "${repairs[@]}"; do
      if [[ -n "${first_repairs["$repair"]:-}" ]]; then confirmed+=("$repair"); fi
    done
    for fault in "${fault_texts[@]}"; do
      if [[ -n "${first_faults["$fault"]:-}" ]]; then confirmed_faults+=("$fault"); fi
    done

    # Repair: wrong defaults alone, or else the links
    defaults_round=0
    if ((${#confirmed[@]} > 0)); then
      defaults=()
      for repair in "${confirmed[@]}"; do
        if [[ "$repair" == default* ]]; then defaults+=("$repair"); fi
      done
      if ((${#defaults[@]} > 0)); then
        apply_repairs "${defaults[@]}" >/dev/null
        defaults_round=1
      else
        apply_repairs "${confirmed[@]}" >/dev/null
      fi
      sleep "$WATCH_SETTLE"
      run_checks || continue
      tally
    fi

    # Announce each confirmed fault that is now gone, and each one still there that has
    # not been announced. In a defaults round the links were not tried yet, so their
    # faults wait for the next round.
    present=()
    for fault in "${fault_texts[@]}"; do present["$fault"]=1; done
    for fault in "${confirmed_faults[@]}"; do
      if [[ -z "${present["$fault"]:-}" ]]; then
        if ((${#confirmed[@]} > 0)); then
          times_repaired["$fault"]=$(( ${times_repaired["$fault"]:-0} + 1 ))
          case "${times_repaired["$fault"]}" in
            1) announce "repaired: $fault" "Call audio repaired" ;;
            3) announce "repaired for the third time: $fault" "Call audio keeps breaking" critical ;;
            *) announce "repaired again (${times_repaired["$fault"]} times): $fault" ;;
          esac
        fi
      elif [[ -n "${notified["$fault"]:-}" ]]; then
        continue
      elif [[ -n "${repairable["$fault"]:-}" ]]; then
        if ((defaults_round)) && [[ "$fault" != Defaults:* ]]; then
          continue
        fi
        announce "could not repair: $fault" "Call audio needs attention" critical
        notified["$fault"]=1
      else
        hint="${hint_for["$fault"]:-}"
        announce "needs attention: $fault; ${hint#by hand: }" "Call audio needs attention" critical
        notified["$fault"]=1
      fi
    done

    # Forget the notices of faults that have gone, so that a fault that returns is
    # announced again
    kept=()
    for fault in "${!notified[@]}"; do
      if [[ -n "${present["$fault"]:-}" ]]; then kept["$fault"]=1; fi
    done
    notified=()
    for fault in "${!kept[@]}"; do notified["$fault"]=1; done

    sleep "$WATCH_INTERVAL"
  done
}

###############################################################################
# Check; with -f repair and check again; with -w keep checking and repairing
###############################################################################

if ! run_checks; then
  echo "Cannot read the PipeWire graph." >&2
  exit 1
fi
tally
report

if ((watch)); then
  watch_audio
fi

if ((faults == 0)); then
  echo "All correct."
  exit 0
fi

if ((!fix)); then
  if ((${#repairs[@]} > 0)); then
    echo "$faults fault(s). check_call_audio.sh -f repairs those whose hint starts with \"-f\"."
  else
    echo "$faults fault(s), to be repaired by hand."
  fi
  exit 1
fi

if ((${#repairs[@]} == 0)); then
  echo "$faults fault(s), none of which -f can repair."
  exit 1
fi

echo "Repairing:"

# Defaults first: WirePlumber moves the streams that follow them, and the links are then
# judged again, so that only what WirePlumber left wrong is repaired
defaults=()
for repair in "${repairs[@]}"; do
  [[ "$repair" == default* ]] && defaults+=("$repair")
done
if ((${#defaults[@]} > 0)); then
  apply_repairs "${defaults[@]}"
  sleep 1
  run_checks || { echo "Cannot read the PipeWire graph." >&2; exit 1; }
  tally
fi

links=()
for repair in "${repairs[@]}"; do
  [[ "$repair" != default* ]] && links+=("$repair")
done
if ((${#links[@]} > 0)); then
  apply_repairs "${links[@]}"
fi

sleep 1
echo
echo "After the repairs:"
echo
run_checks || { echo "Cannot read the PipeWire graph." >&2; exit 1; }
tally
report

if ((faults == 0)); then
  echo "All correct."
  exit 0
fi
echo "$faults fault(s) remain."
exit 1
