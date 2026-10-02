# Studio 68c on Linux

Research carried out on 01/10/2026 on emily: Ubuntu 24.04.5, kernel 6.8.0-142-generic,
PipeWire 1.0.5, WirePlumber 0.4.17, alsa-lib 1.2.11, alsa-ucm-conf 1.2.10, Secure Boot
enabled. Interface: PreSonus Studio 68c, USB ID 194f:010b, firmware 2.21 (`bcdDevice`),
serial 0132B680.

## Summary

- No driver work is needed to reach the missing channels. The kernel's generic USB audio
  class driver, `snd-usb-audio`, already exposes all six inputs and all six outputs at every
  rate from 44.1 to 192 kHz. I verified this in `/proc/asound/card1/stream0` and with a raw
  six-channel recording in which channels 3 and 4 carried live analogue noise.
- PipeWire's choice of profile is what lost them. The 68c declares no channel layout, the
  kernel guesses 5.1 surround, and PipeWire built consumer surround devices on that guess.
  In the profile in use until 01/10/2026, input 4 was never captured and input 3 became a
  "centre" channel that stereo recordings fold into both sides. Line output 3 and S/PDIF out
  were never driven, and line output 4 carried a subwoofer channel. I traced this through the
  installed configuration, not with test signals.
- Configuration fixes it, and the fix is now in place and tested. PipeWire's Pro Audio
  profile opens the hardware directly with six channels each way, in hardware order. With it
  active, speech into inputs 3 and 4 arrived on channels AUX2 and AUX3. Test tones sent to
  AUX2 and AUX3 came out of playback streams 3 and 4, heard on headphones with Cue A/B
  pressed. Named virtual devices for calls sit on top.
- There is nothing to fork. The kernel's PreSonus-specific code exists because the Studio
  1810c and 1824c, and the older 1824, send every output through a DSP mixer that must be
  programmed over vendor USB requests. PreSonus documents no such mixer on the 68c: its
  outputs are wired to fixed playback streams.
- There is no case for a new driver; it would duplicate `snd-usb-audio`.
- One contribution is worth making later: a UCM profile in alsa-ucm-conf, so that every 68c
  owner gets named inputs and outputs without configuration. The channel order is now
  confirmed from the device's own channel names. The profile only works natively from
  PipeWire 1.4 and WirePlumber 0.5.8, which on Ubuntu means 26.04.

## The interface

| USB channel | Capture | Playback |
|---|---|---|
| 1 | Input 1 (front, mic/instrument/line) | Main out left; headphones with Cue A/B off |
| 2 | Input 2 (front, mic/instrument/line) | Main out right; headphones with Cue A/B off |
| 3 | Input 3 (rear, mic/line) | Line out 3; headphones with Cue A/B on |
| 4 | Input 4 (rear, mic/line) | Line out 4; headphones with Cue A/B on |
| 5 | S/PDIF in left | S/PDIF out left |
| 6 | S/PDIF in right | S/PDIF out right |

The playback assignments for channels 1 to 4 are from the owner's manual. Of the main outputs
it says "Playback streams 1 and 2 are routed to these outputs". Of the line outputs it says
"Each output has an independent playback stream (Playback streams 3 and 4)". The Cue A/B
button switches the single headphone output between the two pairs.

The device confirms the whole table in its own USB string descriptors, which
`tools/read_usb_strings.py` read on 01/10/2026 (output in `usb_strings.txt`):

- indices 14 to 19 (playback): "Main Out Left", "Main Out Right", "Line Out 3", "Line Out 4",
  "S/PDIF Out Left", "S/PDIF Out Right"
- indices 20 to 25 (capture): "Mic/Inst/Line 1", "Mic/Inst/Line 2", "Mic/Line 3",
  "Mic/Line 4", "S/PDIF In Left", "S/PDIF In Right"

The manual describes the front panel as hardware only. Phantom power is one button for all
four microphone inputs. Direct Monitor is an on/off button giving "a 50/50 blend of the
playback from your computer and input source signals" on the main and headphone outputs. The
Main knob attenuates the main outputs only.

Universal Control, PreSonus's configuration software, offers four settings for this model:
sample rate, clock source (internal or S/PDIF), buffer size, and "Loopback (Windows only)",
which the manual attributes to the Windows ASIO driver. Linux already covers all four. Sample
rate and clock source are standard USB audio class controls, and the kernel exposes the clock
source as the ALSA control "PreSonus Clock Selector Clock Source". The audio server sets the
buffer size, and PipeWire can itself feed one application's output into another's recording.

Firmware updates come only through Universal Control on macOS or Windows. The release notes
for Universal Control 5.1 (14/07/2026) list firmware for "Studio-series interfaces (Studio
24c, 26c, 68c, 1810c, 1824c)". The same release changes the USB vendor ID of Quantum HD
products only, so a firmware update should leave the 68c's ID at 194f:010b.

The 68c is very probably an XMOS processor running firmware derived from lib_xua, XMOS's USB
audio reference library. I infer this from the descriptors, which match lib_xua's defaults
in four respects:

- all eight audio entity IDs: clock selector 40, internal clock 41, S/PDIF clock 42,
  terminals 1, 2, 20 and 22, and feature unit 11
- the pattern of the clock-source strings
- the string index layout
- the firmware-update (DFU) attributes

A teardown of the sibling 1824c also found an XMOS processor. The practical consequence is
small. The DFU interface is standard, but PreSonus publishes no firmware images, so flashing
from Linux would mean extracting them from the Windows software, at a risk of bricking the
unit.

## What this machine shows

USB descriptors, from `lsusb -v`:

- USB Audio Class 2.0 at high speed, with one streaming alternate setting per direction: six
  channels, 24-bit samples in 32-bit slots, 44.1 to 192 kHz, asynchronous with an explicit
  feedback endpoint.
- `bmChannelConfig` is 0 in both directions, so the device declares no speaker positions.
- The capture feature unit (ID 11) has no controls and the playback path has no feature unit,
  so there are no hardware volume or mute controls to expose.
- A clock selector with internal and S/PDIF sources, a USB MIDI interface, and a DFU
  firmware-update interface.

Kernel: `snd-usb-audio` binds the interface as card 1 (`S68c`), with one six-channel capture
PCM and one six-channel playback PCM. The only ALSA controls are clock source and clock
validity. The kernel reports a channel map of FL FR FC LFE RL RR (front left, front right,
centre, subwoofer, rear left, rear right). That map is a guess: `sound/usb/stream.c` fills in
standard positions when `bmChannelConfig` is 0, with the comment "If we're missing
wChannelConfig, then guess something".

A two-second recording straight from `hw:1,0`, with nothing deliberately connected or played:

| Hardware channel | RMS level | Reading |
|---|---|---|
| 1 | -53 dBFS, peaks -40 dBFS | live signal; probably a connected microphone hearing the room |
| 2 | -99 dBFS | analogue noise floor |
| 3 | -115 dBFS | analogue noise floor |
| 4 | -115 dBFS | analogue noise floor |
| 5 | all samples zero | digital input with no source |
| 6 | all samples zero | digital input with no source |

PipeWire offers the card 25 profiles plus Off. All of them except Pro Audio are combinations
of 2.1, 4.1, 5.0 and 5.1 surround; there is no stereo profile. Until the switch to Pro Audio
on 01/10/2026, the active profile was "Analogue Surround 2.1 Output + Analogue Surround 5.0
Input".

WirePlumber's state file, last written on 11/04/2025, recorded that profile as the saved
choice. WirePlumber saves a profile only when a client asks it to, as GNOME Settings does, so I
infer it was chosen by hand.

No UCM profile exists for the card. `alsaucm` reports "UCM is not supported for this USB
device", so PipeWire falls back to its generic profile set.

A WirePlumber rule file already exists:
`~/.config/wireplumber/wireplumber.conf.d/50-alsa-config.conf` (14/10/2024), plus a symlink
to it named `wireplumber.conf`. It is written in WirePlumber 0.5 syntax, which this machine's
WirePlumber 0.4.17 does not read. It has had no effect: the live device and nodes carry none
of its descriptions or channel settings.

I expect it would not do what it intends under 0.5 either, for three reasons:

- it applies node properties (`audio.channels`, `audio.position`) to the device object
- it gives the same device two conflicting channel counts
- it uses channel names (`MIC0` to `MIC3`) that PipeWire does not define

Ubuntu 26.04 ships WirePlumber 0.5.13, so an LTS upgrade would start reading this file, with
untested effects.

## Why channels go missing

1. The 68c declares no speaker positions, so the kernel labels its six channels as 5.1.
2. The hardware accepts exactly six channels. PipeWire's stereo profile needs a two-channel
   device and fails its probe, as does 4.0. The 2.1, 4.1, 5.0 and 5.1 profiles pass because
   alsa-lib reaches them through routing plugins that map a smaller layout onto six channels.
3. alsa-lib's USB 5.1 device reorders channels. Its front left, front right, rear left, rear
   right, centre and subwoofer land on hardware channels 1, 2, 5, 6, 3 and 4 respectively
   (`/usr/share/alsa/cards/USB-Audio.conf`).
4. Under the surround profile in use until 01/10/2026, that gave:

| Hardware channel | Connector | Old 5.0 input | Old 2.1 output |
|---|---|---|---|
| 1 | Input 1 / main out left | front left | front left |
| 2 | Input 2 / main out right | front right | front right |
| 3 | Input 3 / line out 3 | centre, folded into both sides when an application records stereo | not used |
| 4 | Input 4 / line out 4 | not captured | subwoofer |
| 5 | S/PDIF left | rear left | not used |
| 6 | S/PDIF right | rear right | not used |

Other 68c owners have reported the same pattern without finding the cause:

- An AskUbuntu question of 09/08/2022 found recording fine through ALSA and JACK, but the mic
  level too low through PulseAudio.
- A Manjaro thread of 11/04/2023 reported "I can only choose between: 2.1, 4.1, 5.0, 5.1" and
  "the mic is too quiet".
- A Linux Mint thread of 23/07/2024 shows a 2.1 output and a six-channel surround-mapped
  input.

None of them tried Pro Audio. In a PipeWire issue of 05/01/2022 about a different interface,
the reporter mentioned that their Studio 26c, a smaller sibling, "works well in Pro Mode".

## Option 1: configuration

This is the route I recommend. It has four parts:

- the Pro Audio profile, active since 01/10/2026
- a named source for the call microphone, still to do
- Reaper through PipeWire's JACK layer, already in place
- removing the old rule file, still to do

### Pro Audio profile

Pro Audio opens `hw:1,0` directly, with no routing plugin, and labels the channels AUX0 to
AUX5 in hardware order (`spa/plugins/alsa/acp/acp.c` in PipeWire 1.0.5). After the switch,
`pw-dump` showed the two expected nodes, each with six channels AUX0 to AUX5 on `hw:1,0`:
`alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0` and
`alsa_output.usb-PreSonus_Studio_68c_0132B680-00.pro-output-0`.

According to PipeWire's FAQ, stereo applications are then connected to AUX0 and AUX1. For
playback that means the main outputs; for recording it means inputs 1 and 2, as left and
right. Applications using the JACK interface, such as Reaper started with `pw-jack`, see all
six capture and six playback ports.

The profile must be selected with the save flag. WirePlumber 0.4.17 applies a saved profile
before it consults any rule (`policy-device-profile.lua`), and `wpctl set-profile` does not
save, so either a rule or `wpctl` would lose to the profile saved in April 2025. These
commands select and save it:

```sh
card=alsa_card.usb-PreSonus_Studio_68c_0132B680-00
dev=$(pw-dump | jq --arg c "$card" '.[] | select(.info.props["device.name"]? == $c) | .id')
idx=$(pw-dump | jq --argjson d "$dev" '.[] | select(.id == $d) | .info.params.EnumProfile[] | select(.name == "pro-audio") | .index')
pw-cli set-param "$dev" Profile "{ index: $idx, save: true }"
```

On 01/10/2026 these resolved to device 54 and profile 25; both numbers can change between
sessions, hence the lookup. WirePlumber's state file then recorded `pro-audio` as the saved
profile. To go back, run the same commands with
`output:analog-surround-21+input:analog-surround-50` in place of `pro-audio`.

The switch removed the nodes WirePlumber had been using as defaults, so it fell back to the
webcam microphone and the HDMI output. Setting the Pro Audio nodes as defaults with
`wpctl set-default` restored the 68c for desktop sound and calls; WirePlumber stores that
choice too.

### Call microphone

Matthew uses the interface for calls and for Reaper. Reaper reaches all six inputs directly
through PipeWire's JACK layer and needs no virtual devices.

Calls need one. Under Pro Audio, an application that records a single microphone, such as
Signal, takes inputs 1 and 2 as a stereo pair, while the call microphone lives on input 4. A
mono virtual source reading only AUX3, made the default source, is what calls should pick up.

The file follows the pattern on PipeWire's Guide-Split wiki page:

```
# ~/.config/pipewire/pipewire.conf.d/60-studio68c.conf
context.modules = [
  { name = libpipewire-module-loopback
    args = {
      node.description = "Studio 68c Call Mic"
      capture.props = {
        node.name = "capture.s68c_call_mic"
        audio.position = [ AUX3 ]
        stream.dont-remix = true
        target.object = "alsa_input.usb-PreSonus_Studio_68c_0132B680-00.pro-input-0"
        node.passive = true
      }
      playback.props = {
        node.name = "s68c_call_mic"
        media.class = "Audio/Source"
        audio.position = [ MONO ]
      }
    }
  }
]
```

The file takes effect after `systemctl --user restart pipewire pipewire-pulse wireplumber`,
which interrupts any audio in progress, Reaper included. The source is only correct while
Pro Audio is active: under another profile, the PipeWire wiki notes that a loopback "will move
to some other device until the named device reappears". The same pattern gives any other
channel a name, for example a stereo "Line Out 3/4" sink feeding AUX2 and AUX3.

The rear-input test on 01/10/2026 also showed the call microphone barely registering, at
-82 dBFS at best. Matthew found the input's hardware gain turned down. The gain knob for
input 4 should be set so that speech peaks somewhere around -20 to -10 dBFS.

### Reaper and JACK

On this machine `libjack.so.0` resolves to the real JACK library from `jackd2`, not to
PipeWire's. A JACK program started normally therefore looks for a real JACK server, which
would take the 68c for itself and cut off calls. Matthew starts Reaper with `pw-jack`, which
points it at PipeWire's library instead, so Reaper shares the interface with everything else.
That is the right arrangement; other JACK tools used alongside Reaper need the same prefix.

A system-wide alternative is available. Copying
`/usr/share/doc/pipewire/examples/ld.so.conf.d/pipewire-jack-x86_64-linux-gnu.conf` into
`/etc/ld.so.conf.d/` and running `sudo ldconfig` makes every JACK program use PipeWire. I do
not recommend it here, because `pw-jack` already does the job for Reaper and the switch has
side effects:

- It changes about a dozen installed packages, among them guitarix, hydrogen, sooperlooper,
  the Calf plugins, meterbridge, jack-capture, qjackctl, OBS and anything built on
  PortAudio, ffmpeg or fluidsynth.
- The real JACK server stays installed and its D-Bus service (`jackdbus`) starts with each
  login. On 01/10/2026 its engine was stopped and held no device. Once the switch is made,
  programs can no longer reach that server.
- It is reversible by deleting the file and running `sudo ldconfig` again.

### The old rule file

Delete `~/.config/wireplumber/wireplumber.conf.d/50-alsa-config.conf` and its
`wireplumber.conf` symlink, for the reasons given above.

### Alternatives considered

I do not recommend either of these on Ubuntu 24.04.

- **Custom ACP profile set.** A file in `~/.config/alsa-card-profile/mixer/profile-sets/`,
  which PipeWire has honoured since 0.3.85, could label outputs 1 and 2 as left and right and
  rename the devices. One hardware PCM still backs one node per direction, though, so separate
  devices still need the loopbacks above.
- **UCM profile with SplitPCM.** This creates separate named devices directly, but on
  PipeWire 1.0.5 it works through alsa-lib's dshare and dsnoop plugins. The ALSA maintainer
  notes (alsa-ucm-conf issue 333) that opening one split device "fixes" the parameters for all
  of them. The profile must also live in the package-owned `/usr/share/alsa/ucm2`.

  Native support arrived in PipeWire 1.4.0 (06/03/2025) and needs WirePlumber 0.5.8 or later.
  Ubuntu 26.04 ships PipeWire 1.6.2 and WirePlumber 0.5.13.

  alsa-ucm-conf has no 68c profile; its only PreSonus profile, for the Revelator io44, uses
  this mechanism. A 68c profile is worth contributing once the channel order is confirmed. The
  project takes pull requests on GitHub, each with a Signed-off-by line and the output of
  `alsa-info.sh`.

## Option 2: fork an existing driver

The kernel's only substantial PreSonus code is `sound/usb/mixer_s1810c.c`, plus sample-rate
and alternate-setting filters for the 1810c in `format.c` and `quirks.c`. Nick Kossifidis wrote
it for the Studio 1810c "based on reverse engineering of the communication protocol between
the windows driver / Univeral Control (UC) program and the device, through usbmon". Mainline
has since extended it to the Studio 1824 and 1824c.

Upstream 6.8 had only the 1810c, but Ubuntu has backported 1824c work into its 6.8 kernel. Its
changelog lists "ALSA: usb-audio: add mono main switch to Presonus S1824c" from 6.8.0-103, and
the running module contains that control's name.

It does two things. On connection it programs the interface's internal mixer to a "bypass"
routing, so that each playback stream reaches its own output. It also exposes front-panel
switches (phantom power, line or microphone input, mute, mono, headphone source) as ALSA
controls. It uses three vendor requests: 160 sends a command, and 161 then 162 exchange a
block of 63 32-bit words that holds the device state.

That code exists because those models route every output through a software mixer. PreSonus's
iOS compatibility article (updated 22/09/2025) lists the "Studio 1824c, Studio 1810c, Studio
192, Studio 192 Mobile" as having "software controlled mixers that send all outputs to 1/2 by
default". It lists the 68c among compatible devices but not among those with a mixer, and the
68c manual describes fixed routing. A fork would have nothing to program.

I cannot rule out that the 68c answers the same vendor requests with its front-panel state. I
see no reason to want that, because every button works in hardware.

## Option 3: a new driver

There is no case for one. `snd-usb-audio` already handles streaming, clock selection and MIDI.
The only function Linux lacks is firmware updating, which depends on PreSonus's images rather
than on a driver.

## How Linux audio drivers fit together

The stack on this machine, bottom up:

1. **Kernel.** The USB core enumerates the interface, and `snd-usb-audio` (part of ALSA)
   binds to any interface of the audio class. It parses the class descriptors and creates the
   ALSA PCM devices (`hw:1,0`), the control device and the raw MIDI device.
2. **alsa-lib.** The userspace library layers configuration on top. `USB-Audio.conf` defines
   devices such as `front` and `surround51` for every USB card, plugins reshape streams
   (`route`, `plug`, `dmix`, `dshare`, `dsnoop`), and UCM2 profiles describe the devices of a
   specific card.
3. **PipeWire's ACP.** The ALSA card profile code, inherited from PulseAudio, turns a card
   into profiles and nodes. It uses a UCM profile if one matches the card, otherwise the
   profile sets in `/usr/share/alsa-card-profile/mixer/profile-sets/`, and it always adds Pro
   Audio.
4. **WirePlumber.** The session manager chooses each card's profile, restores saved state and
   links application streams to nodes.
5. **Applications.** They reach PipeWire through its PulseAudio, JACK or ALSA compatibility
   layers, or natively.

A fault is fixed at the layer where it occurs, and the 68c's fault is at layer 3. For a
class-compliant interface, "writing a driver" usually means one of three things, from least
to most work:

1. A userspace description of the card, as a UCM profile or an ACP profile set: device names,
   channel splits and defaults, with no compilation.
2. A quirk in `snd-usb-audio` for a device that describes itself wrongly. This is an entry in
   `quirks-table.h` or a `QUIRK_FLAG_*` bit. Many flags can be tried without compiling,
   through the `quirk_flags` and `device_setup` module options, which the running 6.8 module
   accepts. Mainline has such an entry for the PreSonus AudioBox USB (194f:0301), which needs
   its sample format declared explicitly.
3. A mixer quirk for vendor-specific controls, such as `mixer_s1810c.c` or Focusrite's
   `mixer_scarlett2.c`. This needs the vendor protocol reverse-engineered and a kernel build.

The 68c needs only the first.

## Kernel development on this machine

None of this is needed for the 68c. It describes what extending `snd-usb-audio` would involve
if another device or feature ever required it.

### Precedent

The PreSonus code shows the scale of such work. Nick Kossifidis's Studio 1810c support,
committed on 15/02/2020, first shipped in Linux 5.7. Amin Dandache's 1824c support
(27/02/2025) shipped in 6.15, and Frederic Popp's Studio 1824 support (08/03/2026) in 7.1. A
research agent's reading of the mailing-list archive found small usb-audio patches accepted
within hours to a few days of posting.

The 68c appears in no kernel commit or mailing-list subject that the agent found. Its only
appearance in this context is in fenugrec's Wireshark dissector for the PreSonus protocol.
That dissector lists the 68c among the devices driven by the same Windows library as the
1824c, which suggests a shared protocol family. Nobody has captured the 68c's traffic to
prove it.

### Workflow on Ubuntu 24.04

1. **Source.** The exact source of the running kernel is tagged `Ubuntu-6.8.0-142.142` in
   Ubuntu's noble kernel repository on Launchpad, and a shallow clone of that tag avoids the
   full history. Work meant for upstream should start from a current kernel instead, because
   patches go against Takashi Iwai's sound tree. Ubuntu offers a 7.0 hardware-enablement
   kernel for 24.04 (`linux-generic-hwe-24.04`, 7.0.0-34), not installed here.
2. **Build.** Copy `sound/usb` out of the tree and build it against the installed headers
   with `make -C /lib/modules/$(uname -r)/build M=$PWD`. A module installed under
   `/lib/modules/$(uname -r)/updates/` takes priority over Ubuntu's, because
   `/etc/depmod.d` searches `updates` first.
3. **DKMS**, to rebuild the module on kernel updates. On this machine DKMS is set to build for
   every installed kernel (`autoinstall_all_kernels="yes"`). Unless the package is restricted
   with `BUILD_EXCLUSIVE_KERNEL`, a frozen copy of `sound/usb` would replace Ubuntu's own fixes
   in later kernels.
4. **Secure Boot**, which is enabled here. Ubuntu's DKMS signs modules with the Machine Owner
   Key in `/var/lib/shim-signed/mok/`, and `mokutil --test-key` confirms that key is already
   enrolled. A DKMS-built module would therefore load without a new enrolment. A module built
   by hand must be signed with the same key using the kernel's `scripts/sign-file`.
5. **Reverse engineering.** The kernel sources record the same method for the 1810c, the
   Focusrite Scarlett mixers and the MOTU MicroBook II. You run the vendor's Windows software
   in a virtual machine with the interface passed through, and capture with `usbmon` and
   Wireshark on the Linux host. For the 1824c, fenugrec found that he could "capture USB
   traffic just fine" on the host, while capture inside the VM had "issues with dropped
   packets and limited capture size".
   - None of the tools is ready on this machine. VirtualBox is not installed (only the
     `vboxusers` group remains), Wireshark is not installed, and the `usbmon` module is not
     loaded. The 68c is on USB bus 3.
   - Universal Control offers firmware updates, and fenugrec's copy offered to replace a newer
     firmware with an older one. Snapshot the VM, decline the offers, and record the unit's
     firmware version (2.21) first.
6. **Prototyping.** A protocol can be tested from userspace before any kernel code exists.
   The usbfs code in `drivers/usb/core/devio.c` exempts vendor-type requests from the
   interface-claim check. A Python or Rust tool can therefore talk to the interface while
   `snd-usb-audio` keeps it bound. According to its source, Roy Vegard Ovesen's Baton mixer for
   the 1824c works this way. It needs a udev rule granting write access to the device node.
7. **Submission.** Run `scripts/checkpatch.pl` and `scripts/get_maintainer.pl`, then send
   the patches with `git send-email` to linux-sound@vger.kernel.org. The maintainers are
   Takashi Iwai and Jaroslav Kysela. Each patch needs a Signed-off-by line under the author's
   real name. The kernel's policy on coding assistants says "AI agents MUST NOT add
   Signed-off-by tags"; AI help is declared with an `Assisted-by:` tag instead.

## Status and next steps

Done on 01/10/2026:

- Channel names read from the device (`usb_strings.txt`).
- Pro Audio selected and saved; the Pro Audio nodes set as the default sink and source.
- Inputs 3 and 4 tested by speaking into each while recording all six channels. The speech
  appeared on AUX2 and AUX3 respectively.
- Line outputs 3 and 4 tested with tones on AUX2 and AUX3. Matthew heard the low tone left
  and the high tone right on headphones with Cue A/B pressed.

- Call-microphone file installed at `~/.config/pipewire/pipewire.conf.d/60-studio68c.conf`
  and PipeWire restarted. Pro Audio was restored from saved state, and the only link into
  "Studio 68c Call Mic" comes from the hardware's `capture_AUX3`, which is input 4. The
  source is now the saved default.
- WirePlumber 0.5-format rule file and its symlink deleted.

- Input 4's gain set and checked with 25 seconds of call-style speech recorded from "Studio
  68c Call Mic". Speech peaked between -22 and -11 dBFS, its RMS ran at about -28 to
  -36 dBFS, nothing clipped, and the background noise sat at -67 dBFS.

Still to do, optionally: write a UCM profile for alsa-ucm-conf.

## Limits of this research

- The table of what happened to each channel under the old surround profile comes from
  tracing configuration files. I did not observe it with test signals before switching.
- The line outputs were tested through the headphone output with Cue A/B pressed, which the
  manual says carries the same streams as outputs 3 and 4. The line output jacks themselves
  were not measured.
- The S/PDIF input and output were not tested; nothing was connected to them.
- I read the Studio 26c and 68c owner's manual from a mirror, because PreSonus's own servers
  block automated fetching.
- The research agents could not search the LinuxMusicians forum or Reddit, so reports posted
  only there are missing.

## Sources

Local, on emily: `lsusb -v -d 194f:010b`, `/proc/asound/card1/stream0`, `pw-dump`,
`/usr/share/alsa/cards/USB-Audio.conf`, `/usr/share/alsa/pcm/surround*.conf`,
`/usr/share/alsa-card-profile/mixer/profile-sets/default.conf`,
`/usr/share/wireplumber/scripts/policy-device-profile.lua`,
`~/.local/state/wireplumber/default-profile`.

Kernel:

- https://github.com/torvalds/linux/blob/master/sound/usb/mixer_s1810c.c
- https://github.com/torvalds/linux/blob/v6.8/sound/usb/mixer_s1810c.c
- https://github.com/torvalds/linux/blob/v6.8/sound/usb/stream.c (`convert_chmap`)
- https://github.com/torvalds/linux/blob/master/sound/usb/quirks-table.h (AudioBox USB entry)
- Commits https://github.com/torvalds/linux/commit/8dc5efe3d17c (1810c),
  https://github.com/torvalds/linux/commit/080564558eb1 (1824c) and
  https://github.com/torvalds/linux/commit/c4791ce96b88 (1824)
- https://github.com/torvalds/linux/blob/v6.8/drivers/usb/core/devio.c (vendor requests)
- https://github.com/torvalds/linux/blob/master/Documentation/process/coding-assistants.rst
- https://docs.kernel.org/process/submitting-patches.html
- https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/noble
- Ubuntu kernel changelog: `apt-get changelog linux-modules-6.8.0-142-generic`
- https://github.com/fenugrec/presonus_wireshark
- https://github.com/royvegard/baton

PipeWire and WirePlumber:

- https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/1.0.5/spa/plugins/alsa/acp/acp.c
- https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/1.0.5/spa/plugins/alsa/alsa-acp-device.c
- https://gitlab.freedesktop.org/pipewire/pipewire/-/wikis/FAQ
- https://gitlab.freedesktop.org/pipewire/pipewire/-/wikis/Guide-Split
- https://gitlab.freedesktop.org/pipewire/pipewire/-/blob/master/NEWS (1.4.0 entry)
- https://gitlab.freedesktop.org/pipewire/pipewire/-/commit/dcccfcab7fb5cb2348fe567d6a08d9fc3a8644bc
- https://gitlab.freedesktop.org/pipewire/wireplumber/-/blob/0.4.17/src/scripts/policy-device-profile.lua
- https://gitlab.freedesktop.org/pipewire/wireplumber/-/blob/0.4.17/modules/module-default-profile.c
- https://github.com/alsa-project/alsa-ucm-conf

PreSonus and Fender:

- Studio 26c and Studio 68c owner's manual (mirror):
  https://img.audiomania.ru/data/presonus_studio_26c.pdf
- https://support.presonus.com/hc/en-us/articles/360059975732-PreSonus-Hardware-iOS-iPadOS-Compatibility
- https://www.fmicassets.com/Damroot/Original/10151/Fender_Universal_Control_v5_1_Milestone_Release_Notes.pdf

Hardware background:

- https://github.com/xmos/lib_xua/blob/29a100983f6f9e0c9bb84f630f1af5dcad2b5c09/lib_xua/api/xua_conf_default.h
- http://www.qcte.ca/audio/presonus_1824c/ (1824c teardown)

User reports:

- https://askubuntu.com/questions/1422789
- https://forum.manjaro.org/t/pipewire-wrong-profile-for-audio-interface/138478
- https://forums.linuxmint.com/viewtopic.php?t=424801
- https://gitlab.freedesktop.org/pipewire/pipewire/-/issues/1982
