// SPDX-License-Identifier: CC0-1.0

//! The C boundary around the vendored mixer graph, brought in with
//! `@cImport` rather than hand-written `extern` declarations - see
//! `native/bridge.h` for what it actually declares.

pub const c = @cImport({
    @cInclude("bridge.h");
});
