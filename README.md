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

Four backends today: `none`, which opens on every machine and plays
nothing, for the tests that need no sound device; `mixer`, the real graph -
a bus per voice with its own gain, pan and pitch-shift, mixing into a buffer
a caller pulls by hand, which is what the other three are built on; `wasapi`
(Windows only), which pumps that same graph to the sound card from its own
thread; and `alsa`/`opensl` (Linux and Android), each doing the same on
their own platform. `zig build example-tone` plays a second of tone through
it.

A clip is either bytes to decode (`loadClip`, PCM or Ogg Vorbis) or a
waveform with nothing to decode at all (`loadOscillator`: sine, square,
sawtooth or triangle, for a given length or forever).

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
required. Two files under `src/native/third_party/` are someone else's work
and keep their own license, unmodified:

| File | What it is | License |
| --- | --- | --- |
| `stb_vorbis.c` | The Ogg Vorbis decoder `VorbisClip` decodes through. | MIT (Copyright (c) 2017 Sean Barrett) - one of two licenses it ships under; this project uses the MIT one. |
| `smbPitchShift.hpp` | The phase-vocoder pitch shifter behind the pitch-shift processor. | The Wide Open License (Copyright 1999-2015 Stephan M. Bernsee) |
