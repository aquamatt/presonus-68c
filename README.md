# PreSonus Studio 68c on Linux

## The problem

The PreSonus Studio 68c is a USB audio interface with four microphone inputs, two on the
front and two on the back, four line outputs (main out left and right, and line outs 3 and
4) and S/PDIF in and out. I bought one believing it was fully supported on Linux, because
other PreSonus models are. On Ubuntu 24.04, with its standard PipeWire sound system, I could
record from the two front inputs but not from the two on the back. I did not seem to have
access to all four line outputs either.

PipeWire presented the 68c as a surround sound device. Apart from one profile called Pro
Audio, every profile it offered was a combination of 2.1, 4.1, 5.0 and 5.1 surround, and
none was plain stereo.

The question was which of three routes would give access to every input and output:
configuring the existing driver, forking the Linux driver of another audio interface, or
writing a new driver.

## Summary

- Configuration is enough, and no driver needs forking or writing. Every channel is now
  reachable: four analogue inputs, main outs, line outs 3 and 4, and S/PDIF in and out.
  Inputs 3 and 4 and line outs 3 and 4 were tested with signals. S/PDIF was not, because
  nothing is connected to it.
- No PreSonus driver is involved or needed: the kernel's standard USB audio driver handles
  every channel the 68c has. The kernel's PreSonus-specific code exists for the Studio 1810c,
  1824c and 1824, which route every output through an internal mixer that the driver must
  program. PreSonus documents no such mixer on the 68c, whose outputs are wired to fixed
  playback streams, so a fork of that code would have nothing to program.
- The channels went missing because PipeWire treated the 68c as a 5.1 surround device. By my
  reading of its configuration, the surround profile in use until 01/10/2026 never captured
  input 4, folded input 3 into both sides of a stereo recording, sent nothing to line out 3
  and sent a subwoofer channel to line out 4.
- The fix is PipeWire's Pro Audio profile, which on its own exposes all six inputs and all six
  outputs (step 3 of [Setting it up from scratch](#setting-it-up-from-scratch)). On top of it,
  this setup adds a mono "Studio 68c Call Mic" input for calls, REAPER started through
  `pw-jack`, `vc_connect.sh` for recording call and browser audio in REAPER, and
  `phone_connect.sh` for recording calls made on my Android phone, which connects to the
  computer over Bluetooth as a hands-free kit.

The rest of this document describes how the 68c is set up on my machine (Ubuntu 24.04.5) as of
01/10/2026, how to rebuild that setup, and what to check after moving to Ubuntu 26.04 or later.
The research behind it, the options rejected and the test measurements are in `findings.md`;
`CLAUDE.md` briefs Claude Code sessions working on the repository.

## Channels

Pro Audio names the six channels in each direction AUX0 to AUX5, in hardware order. The input
and output names are the device's own, read from its USB descriptors (`usb_strings.txt`).

| Channel | Input | Output | REAPER input |
|---|---|---|---|
| AUX0 | Mic/Inst/Line 1 (front) | Main Out Left | in1 |
| AUX1 | Mic/Inst/Line 2 (front) | Main Out Right | in2 |
| AUX2 | Mic/Line 3 (rear) | Line Out 3 | in3 |
| AUX3 | Mic/Line 4 (rear), the call microphone | Line Out 4 | in4 |
| AUX4 | S/PDIF In Left | S/PDIF Out Left | in5 |
| AUX5 | S/PDIF In Right | S/PDIF Out Right | in6 |

According to the owner's manual, the front panel works in hardware only:

- Cue A/B switches the headphones between the main outs (button off) and line outs 3 and 4
  (button on).
- Direct Monitor blends the inputs 50/50 with computer playback on the main and headphone
  outputs.
- The Main knob sets the level of the main outputs only.
- One phantom power button serves all four microphone inputs.

## How it works

```
                          Studio 68c (USB)
                                 |
           snd-usb-audio: ALSA card S68c, six channels in, six out
                                 |
                  PipeWire, card profile "Pro Audio"
                   |                              |
    "Studio 68c Pro" input            "Studio 68c Pro" output
    AUX0-AUX5                         AUX0-AUX5, default output
      |          |                                ^
      |      AUX3 only                            | AUX0/AUX1
      |          |                                |
      |   "Studio 68c Call Mic"          desktop sound and calls
      |   mono, default input
      |          |
      |   Signal and other call programs
      |
    REAPER in1-in6, through pw-jack

    Chrome, Zoom, Zen -> "Vidconf to REAPER" (vc_connect.sh) -> REAPER in7/in8

    Android phone, over Bluetooth:
      far end of a call -> "Phone to REAPER" (phone_connect.sh) -> REAPER in9
      "Studio 68c Call Mic" -> the phone
```

### Driver

The 68c is a USB Audio Class 2.0 device. The kernel's generic `snd-usb-audio` driver presents
it as ALSA card `S68c`, with one six-channel input and one six-channel output, at 44.1 to
192 kHz. PreSonus's Universal Control has no Linux version, and nothing here needs it: Linux
covers its sample rate, clock source and buffer size settings. Firmware updates do need it, on
Windows or macOS.

### Pro Audio profile

The 68c does not say which channel is which, so the kernel labels its six channels as 5.1
surround, and every PipeWire profile apart from Pro Audio is a surround layout built on that
guess. Pro Audio ignores the guess and opens the hardware directly, six channels each way in
hardware order. It creates an input and an output, both called "Studio 68c Pro" in
`wpctl status`:

- input: `alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0`
- output: `alsa_output.usb-PreSonus_Studio_68c_0132B680-00.pro-output-0`

WirePlumber, PipeWire's session manager, saves the profile in
`~/.local/state/wireplumber/default-profile` and restores it every time it starts. The profile
was selected with an explicit save flag, because WirePlumber 0.4 applies a saved profile before
any rule, and the surround profile saved in April 2025 would otherwise have come back.

The Pro Audio output is the default output, so desktop sound and calls play on AUX0/AUX1: the
main outs, and the headphones with Cue A/B off.

The 68c offers no volume control over USB, so the volume slider for "Studio 68c Pro" is applied
in software to all six outputs. The slider and the Main knob are separate controls in series:
the slider scales the signal before it leaves the computer, then the knob sets the main
outputs' level inside the interface, and neither can see or move the other. The slider was at
40%, about -24 dB, on 01/10/2026. I infer that it
scales REAPER's output as well, because PipeWire applies a device's volume to everything
connected to it; I have not measured this. If REAPER sounds quiet, or line outs 3 and 4 feed
other equipment at too low a level, check that slider first.

### Call microphone

A program that wants one microphone, such as Signal, would take inputs 1 and 2 from the Pro
Audio input as a stereo pair. The call microphone is on input 4, so
`~/.config/pipewire/pipewire.conf.d/60-studio68c.conf` creates a mono input, "Studio 68c Call
Mic" (node `s68c_call_mic`), that reads only AUX3. It is the default input, so call programs
pick it up without any per-program setting. To use another input for calls, change `AUX3` in
the file (AUX0 is input 1) and restart PipeWire.

The call mic works only under Pro Audio. Under any other profile the device it reads from does
not exist, and according to the PipeWire wiki it attaches to some other input instead.

Input 4's gain knob was set on 01/10/2026 so that call speech peaks between -22 and -11 dBFS
without clipping. With the knob turned down, as it was before, the call mic peaked at -82 dBFS
and was close to silent.

### REAPER

REAPER uses JACK for audio, with 9 inputs and 6 outputs, and is started with `pw-jack` in front
of its command. `pw-jack` points REAPER at PipeWire's JACK library, so REAPER shares the 68c
with calls and desktop sound. Without it, REAPER would load the system JACK library, which on
this machine is the real JACK from `jackd2`, and look for a real JACK server. A JACK server
holds its interface exclusively, shutting PipeWire out. Other JACK programs used alongside
REAPER need the same prefix.

REAPER connects its inputs automatically, in order: in1-in6 to the 68c's six inputs, and
in7/in8 to the built-in analogue input until `vc_connect.sh` re-wires them. in9 is for the
phone; I have not checked what REAPER connects it to on its own, and `phone_connect.sh`
removes any such connection. With REAPER running on 02/10/2026, its outputs out1-out6 were
connected to the 68c's six outputs in order; with REAPER running, `pw-link -l` lists them.

### Recording call and browser audio in REAPER

`vc_connect.sh` sends the sound of Chrome, Zoom and Zen into REAPER's in7 and in8. Run with
REAPER open, it:

1. creates a virtual output, "Vidconf to REAPER" (node `vc_to_reaper`), and connects its
   monitor to REAPER in7 (left) and in8 (right), removing the built-in input's connections to
   them.
2. moves every open Chrome, Zoom and Zen playback stream into that output. If none is open, it
   waits, checking every second, until one starts, then moves it and exits.

WirePlumber remembers the move for each program, so later streams from the same program, such
as a new tab or the video after a YouTube advert, also reach REAPER without running the script
again.

`vc_connect.sh -k` reverses it: open streams go back to the default output, WirePlumber forgets
the move, and the virtual output is removed. `vc_connect.sh -h` lists the environment variables
that change its behaviour.

While the routing is in place, those programs play only into REAPER, so they are audible only
if REAPER monitors in7/in8. Run the script again whenever REAPER restarts its audio engine,
because REAPER then recreates its ports. If browser audio goes silent after a recording
session, the routing is probably still in place: run `vc_connect.sh -k`.

### Recording phone calls in REAPER

My Android phone is paired with the computer over Bluetooth, and the computer acts as the
phone's hands-free kit, as a car kit would. PipeWire provides that role by itself with
WirePlumber's default settings, so nothing needs installing or configuring for it. During a
call, PipeWire creates two mono streams for the phone: the far end, which WirePlumber plays on
the default output, and the stream to the phone, which it feeds from the default input, the
call mic.

`phone_connect.sh` sends the far end into REAPER. Run with REAPER open, it:

1. finds the phone, the one paired device that Bluetooth lists as a phone, and connects it
   unless it is connected already.
2. creates a virtual output, "Phone to REAPER" (node `phone_to_reaper`), and connects it to
   REAPER in9, removing any other connection to in9.
3. waits for a call to start, then moves its far end into "Phone to REAPER". Up to a second
   of the call plays on the default output first.

in9 then carries the phone alone, and the far end is audible only if REAPER monitors in9.
My voice needs no routing: it reaches the phone from the call mic, and REAPER records it on
in4.

WirePlumber remembers the move, so later calls reach REAPER without running the script again.
It files the move under the stream's role, "Communication", so while "Phone to REAPER" exists,
any other program that plays with that role lands there too.

`phone_connect.sh -k` sends a call in progress back to the default output, removes "Phone to
REAPER" and disconnects the phone, which while connected sends every call to the computer.
Run the script again whenever REAPER restarts its audio engine. `phone_connect.sh -h` lists
the environment variables that change its behaviour.

About Bluetooth calls:

- The audio is mono, at 8 kHz (CVSD) or 16 kHz (mSBC). The far-end track sounds like a phone
  call whatever the computer does; only my side is recorded at full quality.
- Calls are answered and ended on the phone. On Ubuntu 24.04 nothing on the computer can do
  it, because PipeWire 1.0.5 has no call-control interface.
- While the phone is connected, its other sound, such as music and notifications, plays on
  the default output, unless "Media audio" is turned off for the computer in the phone's
  Bluetooth settings.
- The phone's call-volume buttons change the far end's level before it reaches REAPER, in
  15 steps: step n gives (n/15)^3 of full level, so one step below maximum is about -1.8 dB
  and step 8 about -16 dB. I keep the call volume at maximum when recording.
- Tested with calls on 02/10/2026: the phone used mSBC, the far end reached REAPER only
  through "Phone to REAPER", the call mic fed the phone, a new call stream went to "Phone to
  REAPER" without the script, and `-k` removed the routing and disconnected the phone.

## Files

| Location | Purpose | Copy in this project |
|---|---|---|
| `~/.local/state/wireplumber/default-profile` | Saved profile: `pro-audio` for the 68c. Written by WirePlumber. | none |
| `~/.local/state/wireplumber/default-nodes` | Saved default output and input. Written by WirePlumber. | none |
| `~/.local/state/wireplumber/restore-stream` | Per-program output choices, including those `vc_connect.sh` makes. Written by WirePlumber. | none |
| `~/.config/pipewire/pipewire.conf.d/60-studio68c.conf` | Defines "Studio 68c Call Mic". | `dot_config/pipewire/pipewire.conf.d/60-studio68c.conf` |
| `~/.config/REAPER/reaper.ini` | REAPER's settings, including `linux_audio_nch_in=9` and `linux_audio_nch_out=6`. | none |
| `~/scripts/vc_connect.sh` | Routes call and browser audio into REAPER. | `tools/vc_connect.sh` |
| `~/scripts/phone_connect.sh` | Connects the phone over Bluetooth and routes its calls into REAPER. | `tools/phone_connect.sh` |

Also in this project:

- `findings.md`: the research, the options considered and the test results.
- `tools/read_usb_strings.py`: reads the device's channel names (run with `sudo`). Its output is
  in `usb_strings.txt`.
- `CLAUDE.md`: the briefing for Claude Code sessions working on the repository.
- `LICENSE`: the MIT licence, which covers everything here.

## Setting it up from scratch

These steps rebuild the setup on Ubuntu 24.04 with the standard desktop audio. The PipeWire
restart in step 4 cuts any call in progress and REAPER's audio.

Run them from the root of a clone of this repository, because steps 4 and 7 copy files from it:

```sh
git clone https://github.com/aquamatt/presonus-68c.git
cd presonus-68c
```

The device and node names in this document and in `60-studio68c.conf` contain my unit's serial
number, `0132B680`. On any other 68c, replace it with that unit's serial in the commands, and in
`60-studio68c.conf` before installing it. With the 68c connected, `ls /dev/snd/by-id/` shows
the serial in a name of the form `usb-PreSonus_Studio_68c_0132B680-00`.

1. Make sure `pw-jack` and `jq` are installed. The rest of PipeWire comes with the desktop.

   ```sh
   sudo apt install pipewire-jack jq
   ```

2. Connect the 68c and check that the kernel has found it. One line of the output should name
   `S68c` and `Studio 68c`.

   ```sh
   cat /proc/asound/cards
   ```

3. Select and save the Pro Audio profile. The device and profile numbers change between
   sessions, hence the lookups. Use this rather than `wpctl set-profile`, which on WirePlumber
   0.4 switches the profile without saving it.

   ```sh
   card=alsa_card.usb-PreSonus_Studio_68c_0132B680-00
   dev=$(pw-dump | jq --arg c "$card" '.[] | select(.info.props["device.name"]? == $c) | .id')
   idx=$(pw-dump | jq --argjson d "$dev" '.[] | select(.id == $d) | .info.params.EnumProfile[] | select(.name == "pro-audio") | .index')
   pw-cli set-param "$dev" Profile "{ index: $idx, save: true }"
   ```

4. Install the call mic and restart PipeWire:

   ```sh
   mkdir -p ~/.config/pipewire/pipewire.conf.d
   cp dot_config/pipewire/pipewire.conf.d/60-studio68c.conf ~/.config/pipewire/pipewire.conf.d/
   systemctl --user restart pipewire pipewire-pulse wireplumber
   ```

5. Make the Pro Audio output the default output and the call mic the default input. WirePlumber
   saves both.

   ```sh
   id_of() { pw-dump | jq --arg n "$1" '.[] | select(.info.props["node.name"]? == $n) | .id'; }
   wpctl set-default "$(id_of alsa_output.usb-PreSonus_Studio_68c_0132B680-00.pro-output-0)"
   wpctl set-default "$(id_of s68c_call_mic)"
   ```

6. Set REAPER's audio device to JACK with 9 inputs and 6 outputs, and start REAPER with
   `pw-jack /path/to/REAPER/reaper`. A desktop launcher needs the same prefix in its `Exec=`
   line.

7. Install `vc_connect.sh` and `phone_connect.sh` in a directory on `PATH`. `~/scripts` is on
   `PATH` on this machine; on another, add it.

   ```sh
   mkdir -p ~/scripts
   install -m 755 tools/vc_connect.sh tools/phone_connect.sh ~/scripts/
   ```

8. Pair the phone in GNOME Settings > Bluetooth. In the phone's Bluetooth settings for the
   computer, leave "Phone calls" on; turning "Media audio" off keeps the phone's other sound
   off the 68c.

## Checking it

- The active profile. This prints `pro-audio`:

  ```sh
  pw-dump | jq -r '.[] | select(.info.props["device.name"]? == "alsa_card.usb-PreSonus_Studio_68c_0132B680-00") | .info.params.Profile[0].name'
  ```

- The defaults. `wpctl status` marks "Studio 68c Pro" under Sinks and "Studio 68c Call Mic"
  under Sources with `*`.
- The call mic's feed. This command:

  ```sh
  pw-link -l | grep -A1 '^capture.s68c_call_mic'
  ```

  prints:

  ```
  capture.s68c_call_mic:input_AUX3
    |<- alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0:capture_AUX3
  ```

- The inputs. Record all six while speaking into each input in turn, and stop with Ctrl+C.
  Channel n of the file carries input n, and channels 5 and 6 carry S/PDIF.

  ```sh
  pw-record --target alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0 \
    --rate 48000 --channels 6 --channel-map AUX0,AUX1,AUX2,AUX3,AUX4,AUX5 --format s32 test.wav
  ```

- Whether anything is using the 68c. When it is idle, this prints `closed` twice; check it
  before restarting PipeWire.

  ```sh
  head -1 /proc/asound/S68c/pcm0*/sub0/status
  ```

## Things to know

- Changing the 68c's profile anywhere that saves the choice, such as the profile setting in
  GNOME Settings' Sound panel, replaces Pro Audio. The missing channels then return and the
  call mic attaches to another input, until step 3 is repeated.
- The device and node names contain the unit's serial number, `0132B680`. A replacement 68c
  would have different names, so `60-studio68c.conf` and the commands in this file would need
  its serial, which `ls /dev/snd/by-id/` shows.
- After a firmware update, repeat the checks. I know of no change that would affect this
  setup, but new firmware could describe the device differently.
- Untested: S/PDIF in and out, and line outs 3 and 4 at their own jacks. The line outs were
  tested through the headphones with Cue A/B on, which the manual says carry the same signals.

## Upgrading to Ubuntu 26.04 or later

Ubuntu 26.04 ships PipeWire 1.6.2, WirePlumber 0.5.13 and alsa-lib 1.2.15; 24.04 has 1.0.5,
0.4.17 and 1.2.11. The kernel side needs no work, as the setup relies only on the generic
driver. Nothing in this section has been tried on 26.04: it lists what I expect to matter and
how to check it. The same checks apply to later releases.

### What changes

- WirePlumber 0.5 reads its configuration as SPA-JSON files in
  `~/.config/wireplumber/wireplumber.conf.d/` and ignores the Lua files in
  `~/.config/wireplumber/main.lua.d/` that 0.4 reads. This setup has no WirePlumber rules, so
  there is nothing to convert. An old 0.5-format file, which 0.5 would have started reading
  with untested effects, was deleted on 01/10/2026, and `wireplumber.conf.d/` is now empty.
  Any rule written later must suit the installed WirePlumber.
- The call mic is PipeWire configuration, not WirePlumber configuration, and its format has
  not changed, so I expect `60-studio68c.conf` to load as it is.
- I do not know whether WirePlumber 0.5 reads the profile and defaults that 0.4 saved. If it
  does not, steps 3 and 5 recreate them.
- On 26.04 a UCM profile for the 68c would work natively (last item below).

### After the upgrade

1. `cat /proc/asound/cards` still lists `S68c`.
2. The profile check prints `pro-audio`. If not, repeat step 3. Its `pw-cli` command sets the
   save flag explicitly, so it does not depend on how `wpctl set-profile` behaves in
   WirePlumber 0.5.
3. `wpctl status` shows the two defaults. If not, repeat step 5.
4. The call mic's feed check shows `capture_AUX3` of the Pro Audio input. If the call mic reads
   from anything else, the Pro Audio input's node name has changed: put the new name, from
   `wpctl status` or `pw-dump`, into `target.object` in `60-studio68c.conf` and in its copy
   here, then restart PipeWire.
5. `pw-jack` is still installed (package `pipewire-jack`). `ldconfig -p | grep libjack.so.0`
   shows which JACK library programs load. If its path contains `pipewire`, JACK programs reach
   PipeWire even without `pw-jack`; otherwise keep the prefix.
6. With REAPER running, in1-in6 still connect to the 68c and `vc_connect.sh` still moves a
   browser stream into REAPER. Check too that a reloaded page lands in REAPER and that `-k`
   restores normal playback, because the remembering is WirePlumber behaviour tested only on
   0.4.
7. With REAPER running and a call in progress, `phone_connect.sh` still moves the far end into
   REAPER, and the next call follows without the script. PipeWire 1.4 added a telephony
   interface on D-Bus, which could let the script answer and end calls.
8. Revisit the UCM profile, deferred on 01/10/2026. A UCM profile describes the card to
   alsa-lib, and on 26.04 PipeWire would turn it into separate named devices such as "Line Out
   3" and "Mic/Line 4". That could replace the call mic file, and contributed to alsa-ucm-conf
   it would give every 68c owner named inputs and outputs without configuration. The agreed design is in `CLAUDE.md`, the
   background in `findings.md`.
   - First check whether a newer alsa-ucm-conf already has one. On 24.04,
     `alsaucm -c hw:S68c list _verbs` reports "UCM is not supported for this USB device".
   - If one appears, PipeWire still offers Pro Audio alongside it, so I expect the saved choice
     to hold. Repeat checks 2 to 4.
