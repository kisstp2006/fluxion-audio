// SPDX-License-Identifier: CC0-1.0
//
// The other side of `web.zig`: a page's sound card, fed from fluxion-audio's
// mixer. Installed beside a program as `fluxion-audio.js` - one file, no
// dependencies, no build step - and handed to the platform's glue with the
// others:
//
//   import { Platform } from "./fluxion-platform.js";
//   import { Audio } from "./fluxion-audio.js";
//
//   await new Platform({ canvas }).run("./game.wasm", { with: [new Audio()] });
//
// The mixing is the module's. An AudioWorklet runs on the audio thread and
// cannot call into a module that lives on the page's, so it only plays what
// it is sent: this file asks the module for more (`fluxion_audio_pull`)
// whenever the worklet has less than `latency` seconds queued - when the
// worklet says how far it has played, and on a timer besides - and sends it
// over. All of that happens between the module's own calls.
//
// A page may make no sound before the person on it has done something, so
// the AudioContext starts suspended and is resumed on the next key, button or
// finger. Until it runs, the mixer is pulled by the clock and what it gives
// is thrown away: a voice still plays out, and says so, in its own time.

/// The most frames one pull mixes: `max_frames` in `web.zig`.
const MAX_FRAMES = 4096;

/// How often the queue is looked at besides when the worklet speaks, in
/// milliseconds: what keeps a suspended context's mixer moving.
const TICK = 20;

// The worklet, as text: a module of its own is a second file to install,
// and a page loads this one from a blob instead.
const PROCESSOR = `
class FluxionOutput extends AudioWorkletProcessor {
  constructor() {
    super();
    // What was sent and not yet played, oldest first: planar samples, how
    // many frames they are, and how many of those have been played.
    this.queue = [];
    this.played = 0;
    this.told = 0;
    this.dry = false;
    this.port.onmessage = (event) => this.queue.push({ samples: event.data, frames: 0, at: 0 });
  }

  process(inputs, outputs) {
    const out = outputs[0];
    const quantum = out[0].length;
    let done = 0;
    while (done < quantum && this.queue.length > 0) {
      const chunk = this.queue[0];
      if (chunk.frames === 0) chunk.frames = chunk.samples.length / out.length;
      const take = Math.min(quantum - done, chunk.frames - chunk.at);
      for (let channel = 0; channel < out.length; channel++) {
        const from = channel * chunk.frames + chunk.at;
        out[channel].set(chunk.samples.subarray(from, from + take), done);
      }
      chunk.at += take;
      done += take;
      if (chunk.at === chunk.frames) this.queue.shift();
    }
    for (const channel of out) channel.fill(0, done);
    this.played += done;

    // Said every few quanta, and once as it runs dry - not every quantum
    // it stays dry.
    const dry = done < quantum;
    if (this.played - this.told >= 512 || (dry && !this.dry)) {
      this.port.postMessage(this.played);
      this.told = this.played;
    }
    this.dry = dry;
    return true;
  }
}
registerProcessor("fluxion-output", FluxionOutput);
`;

export class Audio {
  /// `latency`: how much sound, in seconds, is kept queued ahead of what is
  /// playing - less answers sooner, more drops out less on a slow page.
  constructor({ latency = 0.06 } = {}) {
    this.latency = latency;
    // Slot 0 is no output: what `open` answers when there is no Web Audio.
    this.outputs = [null];
    this.memory = null;
    this.exports = null;
  }

  /// Every import `web.zig` declares, under `fluxion_audio`.
  imports() {
    return {
      fluxion_audio: {
        open: (mixer, channels) => this.open(mixer, channels),
        channels: (id) => this.outputs[id]?.channels ?? 0,
        sampleRate: (id) => this.outputs[id]?.context.sampleRate ?? 0,
        close: (id) => this.close(id),
      },
    };
  }

  open(mixer, channels) {
    const Context = globalThis.AudioContext ?? globalThis.webkitAudioContext;
    if (!Context || typeof AudioWorkletNode === "undefined") return 0;

    const context = new Context({ latencyHint: "interactive" });
    const output = {
      mixer,
      context,
      channels: Math.max(1, Math.min(channels, context.destination.maxChannelCount || 2)),
      node: null,
      // Frames sent to the worklet, and played by it.
      sent: 0,
      played: 0,
      // Where the clock had got to, for pulling while nothing plays.
      clock: performance.now(),
      timer: 0,
      wake: null,
    };
    const id = this.outputs.length;
    this.outputs.push(output);

    // The worklet loads as the module goes on; until it is there, the clock
    // pulls, as it does before the page may make a sound.
    const url = URL.createObjectURL(new Blob([PROCESSOR], { type: "text/javascript" }));
    context.audioWorklet
      .addModule(url)
      .then(() => {
        if (this.outputs[id] !== output) return;
        const node = new AudioWorkletNode(context, "fluxion-output", {
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: [output.channels],
        });
        node.port.onmessage = (event) => {
          output.played = event.data;
          this.feed(output);
        };
        node.connect(context.destination);
        output.node = node;
        this.feed(output);
      })
      .catch((error) => console.warn("fluxion-audio: the worklet did not load, so nothing will be heard", error))
      .finally(() => URL.revokeObjectURL(url));

    // A press of anything is what lets a page start its sound.
    output.wake = () => {
      if (context.state !== "running" && context.state !== "closed") context.resume().catch(() => {});
    };
    for (const kind of ["pointerdown", "keydown", "touchend"]) addEventListener(kind, output.wake, true);

    output.timer = setInterval(() => this.feed(output), TICK);
    return id;
  }

  close(id) {
    const output = this.outputs[id];
    if (!output) return;
    this.outputs[id] = null;
    clearInterval(output.timer);
    for (const kind of ["pointerdown", "keydown", "touchend"]) removeEventListener(kind, output.wake, true);
    output.node?.disconnect();
    output.context.close().catch(() => {});
  }

  /// Keep the worklet `latency` ahead, or, while it cannot play, the mixer
  /// with the clock.
  feed(output) {
    if (!this.exports) return;
    const rate = output.context.sampleRate;
    const now = performance.now();
    if (output.node && output.context.state === "running") {
      output.clock = now;
      let wanted = Math.ceil(this.latency * rate) - (output.sent - output.played);
      while (wanted >= 128) {
        const frames = Math.min(wanted, MAX_FRAMES);
        // A copy, handed over whole: the worklet keeps it until played.
        const samples = this.pull(output, frames).slice();
        output.node.port.postMessage(samples, [samples.buffer]);
        output.sent += frames;
        wanted -= frames;
      }
      return;
    }
    let frames = Math.floor(((now - output.clock) / 1000) * rate);
    output.clock += (frames / rate) * 1000;
    while (frames > 0) {
      const chunk = Math.min(frames, MAX_FRAMES);
      this.pull(output, chunk);
      frames -= chunk;
    }
  }

  /// `frames` mixed by the module, as a view of its memory.
  pull(output, frames) {
    const pointer = this.exports.fluxion_audio_pull(output.mixer, frames);
    return new Float32Array(this.memory.buffer, pointer, frames * output.channels);
  }
}
