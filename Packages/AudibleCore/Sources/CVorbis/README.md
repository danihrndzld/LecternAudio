# CVorbis

Unmodified `lib/` sources and `include/vorbis/codec.h`, `vorbisenc.h` from libvorbis 1.3.7
(https://xiph.org/vorbis, `libvorbis-1.3.7.tar.gz`, SHA-256
`0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab`).
Licensed under the BSD 3-clause license, see `COPYING`.

Left out: `vorbisfile.c` (decoder API), `barkmel.c`, `psytune.c`, `tone.c` (tools), build files.
No `config.h`: `HAVE_ALLOCA_H` is defined in `Package.swift` instead.
`include/module.modulemap` is ours.
