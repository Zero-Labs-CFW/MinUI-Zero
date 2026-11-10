# Loader decompressor

Unmodified decompression-only files from libdeflate v1.26, commit
`92e6a0db9fa848d742f9eb286c92afc60f2c3dda` (https://github.com/ebiggers/libdeflate).
The MIT license is retained in COPYING. x86 sources support native host tests only.

Built freestanding with explicit per-instance allocators and no FP/SIMD on the loader.
CRC calls use the loader's runtime-gated ARM CRC implementation and portable fallback,
not libdeflate's CPU dispatch. The loader wrapper additionally validates gzip FHCRC,
which upstream skips, and refuses nonzero trailing data or concatenated members.
