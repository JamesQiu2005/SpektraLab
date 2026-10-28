# stb_truetype

Unmodified `stb_truetype.h` v1.26, from
[`nothings/stb` commit `2c980bb59875b0d32144a71867fbdebb2f77cd20`](https://github.com/nothings/stb/tree/2c980bb59875b0d32144a71867fbdebb2f77cd20).
Distributed under the MIT option in the included `LICENSE` (also present in
the header).

SHA-256:

- `stb_truetype.h`: `ecd30b05e0dd4fea3a13c26810dd9e1992dc379049482c393d5a19e6b5090aab`
- `LICENSE`: `bebfe904b14301657e4e5d655c811d51fd31b97c455b9cc2d8600d6bac6cff63`

Only the pinned Liberation Sans font bytes compiled into the engine reach
this parser. It must not be used to open external font files; upstream
explicitly gives no security guarantee for untrusted fonts.
