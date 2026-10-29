# Portable film imprint fonts

The unmodified **Liberation Sans 2.1.5** regular and bold fonts, and
**DejaVu Sans Mono Bold 2.37** (below), are embedded in the Windows/Linux engine. Their full SIL Open Font License is in `LICENSE`.
They render factory edge lettering as physical exposure before development;
they are not an overlay on the output image. Date-back LCD/dot faces and the
measured Fujifilm dot faces remain the engine's own vector drawings.

Source: [Liberation Fonts 2.1.5 release](https://github.com/liberationfonts/liberation-fonts/releases/tag/2.1.5)
and its [original TTF archive](https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz).

SHA-256:

- Archive: `7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0`
- `LiberationSans-Regular.ttf`: `76d04c18ea243f426b7de1f3ad208e927008f961dc5945e5aad352d0dfde8ee8`
- `LiberationSans-Bold.ttf`: `788abee4c806d660e8aee46689dd8540cd4bb98da03dcc9d171ce3efd99a9173`
- `LICENSE`: `93fed46019c38bbe566b479d22148e2e8a1e85ada614accb0211c37b2c61c19b`

The macOS path still uses Helvetica Neue through CoreText. The portable path
maps its regular/medium faces to Liberation Sans regular and its bold face to
Liberation Sans bold. Glyph contours, advances/kerning and antialiasing may
differ slightly; this is a documented typeface difference, not a claim of
pixel-identical CoreText output. Film-space positions, sizes, tracking,
horizontal scaling, transforms, exposure, blur, and subsequent processing
remain shared. No installed fonts or font downloads are needed at runtime.

## Monospaced bold: DejaVu Sans Mono Bold 2.37 (CineStill 800T's 135 edge)

1.3.4's CineStill 800T edge print asks CoreText for **Menlo Bold** (its
frame numbers "N" and "NA" on 135). Menlo is Apple's and is not
redistributable; it is itself derived from Bitstream Vera Sans Mono through
DejaVu Sans Mono, so the portable path embeds the unmodified
**DejaVu Sans Mono Bold** from DejaVu Fonts 2.37. The two share the advance
(0.602 em) and the cap height (0.73 em, Menlo Bold measured through CoreText
on macOS); glyph details differ (DejaVu's "1" and "2" are close to Menlo's but
not identical). Licence: the Bitstream Vera / DejaVu licence, in
`DejaVu-LICENSE` (permissive; the fonts may be embedded and redistributed).

Source: [DejaVu Fonts 2.37 release](https://github.com/dejavu-fonts/dejavu-fonts/releases/tag/version_2_37),
archive `dejavu-fonts-ttf-2.37.tar.bz2`.

SHA-256:

- Archive: `fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7`
- `DejaVuSansMono-Bold.ttf`: `bce60f1b4421acd9ea51ba6623d7024ecbe6817a953e3654df62a5e6bdf8f769`
- `DejaVu-LICENSE`: `7a083b136e64d064794c3419751e5c7dd10d2f64c108fe5ba161eae5e5958a93`

## Narrow sans: Arial Narrow -> Liberation Sans Regular at 0.82 across

CineStill 800T's 120 edge asks for **ArialNarrow** (the name and the batch
number). Arial Narrow's advances are Arial's times 0.8200 on every string the
edge prints (measured through CoreText), and Liberation Sans is metric-
compatible with Arial, so the portable path draws Liberation Sans Regular
condensed horizontally by 0.82 (outlines and advances). Liberation Sans
Narrow is not part of the 2.1.5 release and is not embedded. Stroke weights
of a condensed regular are thinner across than Arial Narrow's own; this is a
declared typeface difference like the Helvetica Neue one above.
