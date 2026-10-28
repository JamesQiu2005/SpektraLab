# Portable film imprint fonts

The unmodified **Liberation Sans 2.1.5** regular and bold fonts are embedded
in the Windows/Linux engine. Their full SIL Open Font License is in `LICENSE`.
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
