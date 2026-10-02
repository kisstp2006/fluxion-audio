/* SPDX-License-Identifier: CC0-1.0 */

/* stb_vorbis, which the mixer reads Ogg Vorbis clips with. It is only ever
   given bytes already in memory, so it has no stdio. minimp3 is in a file of
   its own (`mp3.c`): the two have static functions of the same name. */

#if defined(__GNUC__)
#  pragma GCC diagnostic ignored "-Wunused-function"
#  pragma GCC diagnostic ignored "-Wunused-value"
#endif

#define STB_VORBIS_NO_STDIO
#include "third_party/stb_vorbis.c"
