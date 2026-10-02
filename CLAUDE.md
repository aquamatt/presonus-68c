# PreSonus Studio 68c on Linux

Configuration, scripts and research for running a PreSonus Studio 68c USB audio interface on
the owner's Ubuntu 24.04 desktop with PipeWire. No driver is involved: the kernel's generic
`snd-usb-audio` driver handles every channel, and the channels that had gone missing came back
through PipeWire configuration. The repository is public on GitHub (`aquamatt/presonus-68c`)
under the MIT licence.

## Layout

- `README.md`: the document for Presonus 68c owners: the problem, how the
  setup works, rebuilding it, checking it and upgrading Ubuntu. It is written in the first
  person as the owner's own. Update it whenever the setup changes.
- `findings.md`: the research report of 01/10/2026 (diagnosis, options rejected, measurements,
  sources). It records what was true then.
- `dot_config/pipewire/pipewire.conf.d/60-studio68c.conf`: defines the "Studio 68c Call Mic"
  source.
- `tools/vc_connect.sh`: routes Chrome, Zoom and Zen audio into REAPER; `-h` documents it.
- `tools/read_usb_strings.py`: prints the device's USB string descriptors, including its
  channel names (needs `sudo`). Its output is `usb_strings.txt`.

`60-studio68c.conf` and `vc_connect.sh` are copies of installed files, which are the ones in
use: `~/.config/pipewire/pipewire.conf.d/60-studio68c.conf` and `~/scripts/vc_connect.sh` (on
`PATH`). Keep each pair identical; when one side changes, change the other in the same piece of
work.

## Device

- USB ID 194f:010b, firmware 2.21, USB Audio Class 2.0. ALSA card `S68c` (`hw:S68c,0`): one
  six-channel PCM each way, S32_LE (24-bit), 44.1 to 192 kHz. There is no hardware volume or
  mute; the only ALSA controls are clock source and clock validity.
- It declares no channel positions, so the kernel guesses 5.1, and every PipeWire profile except
  Pro Audio is a surround layout. Pro Audio labels the channels AUX0-AUX5 in hardware order.
  Capture: Mic/Inst/Line 1, Mic/Inst/Line 2 (front), Mic/Line 3, Mic/Line 4 (rear), S/PDIF In
  L/R. Playback: Main Out L/R, Line Out 3, Line Out 4, S/PDIF Out L/R.
- PreSonus documents no software mixer for the 68c, unlike the 1810c and 1824c: each playback
  stream goes to a fixed output. With Cue A/B pressed, the headphones carry playback 3/4.
- Device and node names contain the unit's serial, `0132B680`: card
  `alsa_card.usb-PreSonus_Studio_68c_0132B680-00`, Pro Audio nodes
  `alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0` and
  `alsa_output.usb-PreSonus_Studio_68c_0132B680-00.pro-output-0`.
- Tested with signals: inputs 3 and 4, and line outs 3 and 4 through the headphones. Untested:
  S/PDIF, and the line-out jacks themselves.

## Machine

- Ubuntu 24.04.5 with PipeWire 1.0.5, WirePlumber 0.4.17 and alsa-lib 1.2.11. WirePlumber 0.4
  reads Lua rules from `~/.config/wireplumber/main.lua.d/` and ignores the SPA-JSON
  `wireplumber.conf.d` format, which arrives with 0.5. Ubuntu 26.04 ships PipeWire 1.6.2,
  WirePlumber 0.5.13 and alsa-lib 1.2.15.
- Current state: Pro Audio is the saved profile, its output is the default sink, and "Studio 68c
  Call Mic" (node `s68c_call_mic`, reading only AUX3, where the call microphone is) is the
  default source. There are no WirePlumber rules. WirePlumber keeps the saved profile, the
  defaults and per-application targets in `~/.local/state/wireplumber/`.
- In WirePlumber 0.4 a saved profile beats any rule, and `wpctl set-profile` does not save.
  Change the profile with `pw-cli set-param <device-id> Profile '{ index: <n>, save: true }'`;
  step 3 of "Setting it up from scratch" in `README.md` looks up the ids.
- REAPER uses JACK with 8 inputs and 6 outputs (`linux_audio_nch_in`/`_out` in
  `~/.config/REAPER/reaper.ini`) and is started with `pw-jack`. The system `libjack.so.0` is the
  real JACK library, so a JACK program started without `pw-jack` bypasses PipeWire. `jackdbus`
  starts at login with its engine stopped. REAPER connects in1-in6 to the 68c's inputs and
  in7/in8 to the built-in analogue input.
- `vc_connect.sh` wires the monitor of a null sink, "Vidconf to REAPER" (`vc_to_reaper`), to
  REAPER in7/in8, and moves the applications' streams into it by setting
  `target.node`/`target.object` metadata, as pipewire-pulse does. WirePlumber's restore-stream
  then remembers the sink per application, which has been tested only on WirePlumber 0.4.
- `pactl` and pavucontrol are not installed: use `wpctl`, `pw-dump | jq`, `pw-cli` and
  `pw-link`. `wpctl status` shows descriptions; `wpctl status -n` shows node names.

## Working on the live setup

- The workstation user takes calls, plays videos and records in REAPER on the 68c. Before touching it or the
  audio configuration, check it is idle: `head -1 /proc/asound/S68c/pcm0*/sub0/status` prints
  `closed` twice. Ask before restarting PipeWire (`systemctl --user restart pipewire
  pipewire-pulse wireplumber`), which cuts calls and REAPER; a change to `60-studio68c.conf`
  takes effect only after one.
- Tests with signals need a human at the interface. Start the capture or tone in the background
  with a lead-in, then tell them what to do. Pass the channel map so that channels link one to
  one, and record noise measurements as s32, because in s16 the rear inputs' noise floor rounds
  to zero:
  - record all six inputs: `pw-record --target
    alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0 --rate 48000 --channels 6
    --channel-map AUX0,AUX1,AUX2,AUX3,AUX4,AUX5 --format s32 out.wav`
  - play a six-channel file: `pw-play --target
    alsa_output.usb-PreSonus_Studio_68c_0132B680-00.pro-output-0 --channel-map
    AUX0,AUX1,AUX2,AUX3,AUX4,AUX5 file.wav`
- Keep recordings and other scratch output out of the repository.

## Publishing

The repository is public. Check every change for credentials and personal data before it is
committed. The repository is specific to this setup and is published not as a
generic solution, but so that others can learn from it (02/10/2026) and get
information that elluded the owner for so long! Never commit recordings, or raw
`pw-dump`, `pw-cli` or `wpctl` output: it lists every device and client on the
machine, with the user and host names.

## Decisions

- No kernel work (01/10/2026). `snd-usb-audio` already does everything the 68c needs, and the
  kernel's PreSonus code programs a mixer the 68c does not have. Should kernel work ever be
  needed for something else, `findings.md` describes the workflow on this machine (Secure Boot
  is on and the DKMS MOK key is enrolled).
- UCM profile for alsa-ucm-conf: deferred until after the upgrade to Ubuntu 26.04
  (01/10/2026). When created it may be contributed it upstream. On 24.04 it would not load: alsa-lib 1.2.11
  reads UCM syntax up to 6, and upstream needs 8. PipeWire 1.0.5 would also build its split
  devices from dsnoop/dshare; native split devices need PipeWire 1.4 and WirePlumber 0.5.8.
  Agreed design:
  - devices named after the 68c's channel strings (Main Out, Line Out 3/4, S/PDIF Out,
    Mic/Inst/Line 1-2, Mic/Line 3-4, S/PDIF In)
  - a "Direct" use case for DAWs
  - input 1 as the default microphone for other users
  - files under `ucm2/USB-Audio/Presonus/`, plus a `Macro.*.StringMatch` line for `194f:010b`
    in `ucm2/USB-Audio/USB-Audio.conf`
  - testing through `ALSA_CONFIG_UCM2` in a Docker container with `/dev/snd` passed through

## After upgrading to Ubuntu 26.04

Work through "Upgrading to Ubuntu 26.04 or later" in `README.md`. From then on, WirePlumber
rules are SPA-JSON files in `~/.config/wireplumber/wireplumber.conf.d/`, not Lua, and the UCM
decision is due for review: native split devices could replace the call mic file.
