# What this is

This is the PRD alongside with the new UI system for both better fit for desktop app and more professional style, and a smoother SpektraLab Desktop userflow and mind model. The main page svg and screenshot reference is at modern_UI/reference_layout, and the export page is at modern_UI/reference_layout/Export_Page

## What is changed

Unlike the current version frontend, it is reworked to less 圆角矩形 and took more inspiration from codex / capture one's frontend, with white lines separating different functions (this is important, as the grid and token system would also incorporate that), and the main page expandable tab, except the bottom gallery view remains unchanged, moved to become sidebar.left and sidebar.right (all SF pro symbols) and clicking them would expand /collapse the side bars, hence these two buttons must also remain on the screen at any given time, but moves according to a good way. 

Also note that tone changed to AE methods in the new frontend, and it is now wired with the Film Exposure right beneath it. It's behavior is: take the linearized baseline as the +0.0 baseline (also "As Shot", clicking this automatically switches AE method to custom), and the different AE methods just adjust the exposure based on it.

How Temperature and Tint is wired remain unchanged.

The new Lens Correction works like this:
1. only RAW files can apply lens correction
2. If the RAW carries lens correction information already, i.e. Nikon NEFs, otherwise let core image handles it based on EXIF (The standard way). This option is non-selectable and the select button and the text greys themself.

Note that if one option is non-selectable, both the text and the input pill is greyed across the app.

The way to display selected film and print profile is also changed. As the screenshot, selected entries has shallow, instead of framed square around it, and the text turns from white to black.

Also note that the cinematic film rolls and the cinematic print profile now has an orange "CINE" pill follows it.

Now the film type, this is very important, as it goes straight into the grain, halation and glare calculation pipeline.
1. Film type: what type of film it is, includes the cine format (also has the orange pill behind it), the still format (110, APS, 135, 120, custom)
2. Side: decides whether the short side or the long side of the image in the pipeline is at the edge of each type of film (Should be easy to understand)
3. edge length (change the name to Side Length): cannot be changed unless custom is selected. Shows the actual Side length if non-custom film type is selected. Side Length also follows the side above, short means altering the short side width. mm, cm, and inch are provided, with input number below. Note that if a crop happens, user can decide in settings if the effects are recalculated.

I didn't draw the crop, since it just need to change it's layout to the new system, everything else works fine there.