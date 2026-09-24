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

Four backends today: `none`, which opens on every machine and plays
nothing, for the tests that need no sound device; `mixer`, the real graph -
a bus per voice with its own gain, pan and pitch-shift, mixing into a buffer
a caller pulls by hand, which is what the other three are built on; `wasapi`
(Windows only), which pumps that same graph to the sound card from its own
thread; and `alsa`/`opensl` (Linux and Android), each doing the same on
their own platform. `zig build example-tone` plays a second of tone through
it.

The three output backends are the `mixer` backend with an `Output` attached
to it - the thread of their own that pulls from the graph and feeds the sound
card - so every call but opening and closing is the mixer's.

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

**Where the mixing logic comes from.** The bus graph, the resampling and
channel conversion, and the PCM and Ogg Vorbis decoders are a proven,
from-scratch real-time audio engine, not something built here from a blank
page - compiled as native C++ through Zig's own C++ toolchain and never
exposed past `Device`. Nothing outside `src/native/` touches a raw pointer
or an unsafe cast; the handles a program holds are eight bytes from
`fluxion-id`, same as everywhere else in this ecosystem. The pitch-shift DSP
that came with it is wired to its own processor now, one `smb::PitchShift`
per channel on the voice bus, alongside gain and pan - set through
`PlayDesc.pitch` or `Device.setPitch`, a no-op at `1.0` that skips the FFT
round trip entirely.

## License

This package is CC0-1.0 (see `LICENSE`) - public domain, no attribution
required. Three files under `src/native/third_party/` are someone else's work
and keep their own license, unmodified:

| File | What it is | License |
| --- | --- | --- |
| `stb_vorbis.c` | The Ogg Vorbis decoder `VorbisClip` decodes through. | MIT (Copyright (c) 2017 Sean Barrett) - one of two licenses it ships under; this project uses the MIT one. |
| `smbPitchShift.hpp` | The phase-vocoder pitch shifter behind the pitch-shift processor. | The Wide Open License (Copyright 1999-2015 Stephan M. Bernsee) |
| `minimp3.h` | The MP3 decoder `Mp3Clip` decodes through ([lieff/minimp3](https://github.com/lieff/minimp3)). | CC0-1.0 |
