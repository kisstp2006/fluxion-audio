# Fluxion Audio

Clips, voices, and one mixer graph underneath, on whichever sound API the
machine has. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Device` | One backend, the clips loaded on it, and the voices playing. |
| `types` | Everything a program says to a device, backend-free. |
| `backend` | What a backend has to answer to - the seam a new one is written against. |

```zig
const audio = @import("fluxion_audio");

var device = try audio.Device.init(gpa, .{ .backend = .wasapi });
defer device.deinit();

const clip = try device.loadClip(.{ .format = .vorbis, .bytes = ogg_bytes });
const voice = try device.play(clip, .{ .volume = 0.8 });
defer device.stop(voice);
```

```zig
const music = try device.loadClip(.{ .format = .mp3, .bytes = mp3_bytes });
const seconds = device.clipInfo(music).?.seconds();
const voice = try device.play(music, .{ .loop = true, .start = 12.5, .speed = 1.1 });
try device.setPaused(voice, true);
try device.seek(voice, 0);
const status = device.status(voice); // playing, position in seconds, and how often it ended
```

The backends: `none`, which opens on every machine and plays nothing, for
the tests that need no sound device; `mixer`, the real graph - a bus per voice
with its own gain, pan and pitch-shift, mixing into a buffer a caller pulls by
hand, which is what the rest are built on; `wasapi` (Windows only), which
pumps that same graph to the sound card from its own thread; `alsa`/`opensl`
(Linux and Android), each doing the same on their own platform; and `web`, a
browser's Web Audio. `zig build example-tone` plays a second of tone through
it.

The output backends are the `mixer` backend with an `Output` attached to it -
what pulls from the graph and feeds the sound card - so every call but opening
and closing is the mixer's.

**In a browser.** The target is `wasm32-wasi` (the decoders are C, and want a C
library). A page has one thread for the program, so nothing mixes on a thread
of its own: `fluxion-audio.js` - `src/backend/web.js`, which a dependant takes
from the build as `dep.namedLazyPath("fluxion-audio.js")` and installs beside
its module - keeps an AudioWorklet about 60 ms ahead, calling the module's
`fluxion_audio_pull` between the page's frames. It is one more glue for the
platform's:

```js
import { Platform } from "./fluxion-platform.js";
import { Audio } from "./fluxion-audio.js";

await new Platform({ canvas }).run("./game.wasm", { with: [new Audio()] });
```

A page may make no sound until the person on it has pressed something, so it
starts silent and begins on the first key, button or finger. Until then the
graph is pulled by the clock and what it gives is thrown away: a voice still
plays out, and says so, in its own time.

**ALSA is opened, not linked.** The `alsa` backend loads `libasound.so.2`
when its first output opens, so a Linux build needs neither its headers nor
the library - it cross-compiles from any machine - and a machine without it
opens no output, the way one without a sound card does. Its output keeps
time with the device, and with the clock where the device does not: the null
device takes any amount of sound at once, and the mix still goes no further
ahead of what would be heard than a buffer, so voices end when they should.

**Choosing a backend without the enum.** `Device.init` picks from the backends
above. A program that wants to decide some other way - by name, from a
configuration file, from what a registry holds - uses openers:
`Device.opener(tag)` returns the `Opener` of a built-in backend (its `name`
and the function that opens it), or null if this build does not bring it, and
`Device.initWith(gpa, desc, opener)` opens a device on any opener. `Device.init`
is `initWith` on the opener it chose.

A backend written elsewhere - Core Audio, say - fills `backend.Vtable` and
makes an `Opener`; `initWith` takes it from anywhere, and the device reports
it as `Backend.other`, with the opener's `name` in `info()`. A backend that
lives here also gets a case in `Device.opener`.

A clip is either bytes to decode or a waveform with nothing to decode at
all (`loadOscillator`: sine, square, sawtooth or triangle, for a given length
or forever). The bytes are:

- **WAVE** (`.wav`): 8, 16, 24 and 32-bit integers and 32 and 64-bit floats,
  read in whole in Zig (`wav.zig`).
- **Ogg Vorbis** and **MP3**: kept as the file's bytes and decoded as they
  play, so a long piece of music is never all samples at once. An MP3's
  frames are indexed when it is loaded, so seeking is quick, and the silence
  its encoder put before and after the music - when its LAME tag says how
  much - is left out, so one that loops goes round without a gap.
- **Raw samples**: 16-bit interleaved (`pcm_s16`), or planar floats a program
  made itself (`pcm_f32`).

`clipInfo` says what a clip is: its channels, its rate and its length.

**A voice**, once playing, is paused and resumed (`setPaused`), moved
(`seek`), looped or not (`setLooping`), and turned up and down, panned and
pitched. `speed` resamples the clip - twice as fast is an octave up - which
costs next to nothing, what a game wants for a sound that is a little
different each time; `pitch` keeps the clip's time through a phase vocoder,
which is not cheap. `status` says whether it plays, where it is, and how many
times it has come to its end: the mixing thread writes it and any thread
reads it, without waiting on the mix, so a game hears a sound finish from its
own frame.

A voice can also feed a submix instead of the master bus directly -
`createSubmix` for a "music" bus or a "sfx" bus with its own volume,
`PlayDesc.output` to route a voice into one, and submixes can feed each
other before either reaches the master.

**The mixer is Zig, on every target** (`src/mixer`): the bus graph, the
resampling and channel conversion, the clips and the processors, and one queue
of changes between the thread that calls `Device` and the one that mixes -
the only seam between them. The handles a program holds are eight bytes from
`fluxion-id`, same as everywhere else in this ecosystem. The pitch shift is a
phase vocoder, one per channel on the voice bus, alongside gain and pan - set
through `PlayDesc.pitch` or `Device.setPitch`, a no-op at `1.0` that skips the
FFT round trip entirely. What is C is the two decoders (`src/native/vorbis.c`
and `mp3.c`); what is C++ is the ALSA and OpenSL ES outputs, which call the
mixer back through `src/native/output.h`.

## License

This package is CC0-1.0 (see `LICENSE`) - public domain, no attribution
required. Three pieces are someone else's work and keep their own license:

| File | What it is | License |
| --- | --- | --- |
| `src/native/third_party/stb_vorbis.c` | The Ogg Vorbis decoder, unmodified. | The Unlicense (public domain) - one of the two licences it ships under, the MIT one the other; this project uses the Unlicense. Its text is in `stb_vorbis-UNLICENSE.txt` beside it, which the build hands on as `stb_vorbis.txt` for a program's notices. |
| `src/native/third_party/minimp3.h` | The MP3 decoder, unmodified ([lieff/minimp3](https://github.com/lieff/minimp3)). | CC0-1.0 |
| `src/mixer/effects.zig` (`Shifter`) | `smbPitchShift` 1.2 carried over to Zig, the pitch-shift processor. Its notice is kept beside it. | The Wide Open License (Copyright 1999-2015 Stephan M. Bernsee) |
