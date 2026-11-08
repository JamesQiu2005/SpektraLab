# Copyable assignment for one DeepSeek agent

You are extending SpektraLab v2 minilab coverage to **every compatible film/paper
pair**, not only default pairs or the four films used in earlier research.
Read `engine/minilab-coverage/SOP.md` completely and follow it. It distinguishes
existing commands from harness functionality you still need to implement.

Start from the engine-performance branch containing engine commit `unpublished-revision`
and this SOP. Create your **own worktree and branch**, for example
`research/minilab-all-pairs`. Do not change the owner's active checkout, the
engine-performance worktree, the original research files, or other agents'
edits. Commit your work on your branch; do not merge, push, install or release.

The inventory currently contains 225 combinations: 136 colour-minilab pairs
(272 production tables: sRGB + ProPhoto), 4 silver-path pairs, 36 positive-film
paper-bypass rows and 49 incompatible rows. Reconcile all rows. Include the
CineStill alias even if the app's current stock catalog omits it. Only one colour
pair is already catalogued. Generate the inventory with the supplied standard-
library `engine/tools/minilab_inventory.py`; it is not a baker or a QA certificate.

Preserve the approved model: 65³ float32 trilinear log-positive-to-paper-CMY,
r=1, optical L/C retention, E1-C3 hue reading and hybrid gamut mapping, separate
space calibrations, EV=0 production tables. Preserve measured material profiles,
`scene_curve`, public wire, DI export, existing B&W/reversal paths and scheduler
semantics. No quality reduction, matrix borrowing, r=0 substitution or silent
fallback for a broken catalogued calibration.

First inspect the actual research implementation and dependencies. Generalize
its Portra-only paths, matrix selection, missing film anchors, caches and dataset
sampling in your private research copy. Freeze hashes and prove the old Portra
canary in both spaces before a full sweep. Use the generalized `e1x.Data` and
`c3_lib.build` scientific functions described in the SOP, with explicit pair and
recipe arguments. Do not run a fixed-Portra script repeatedly with renamed files.

Use one bake/render child process at a time and an atomic, resumable ledger.
Run numerical, direct-versus-LUT, native parity, tone/detail, visual, cache,
resource-failure and memory gates per pair. Default every failed or uninspected
job to pending/blocked; never relax gates to get a green count. Continue other
independent pairs when one fails. Report genuinely missing inputs rather than
inventing them. This needs local Mac/Metal tools, research Python and the local
reference datasets; do not upload them to a model service.

Stage each successful pair with both calibration spaces and complete provenance.
Before alias promotion, close and test the documented inherited-profile hash
validation gap. Keep runtime table loading lazy. Measure the final bundle-size
and cold/RAM cost: the full raw table payload is about 855 MiB, so do not eagerly
load every pair. Verify the built bundle and regress the existing qualified pair.

Return commits, an exact reproducible procedure, the complete coverage ledger,
per-pair evidence and explicit unresolved rows. Full qualified coverage means
136/136 eligible pairs pass, not merely that 272 files were generated. Do not
claim the 4 silver or 36 reversal rows used a colour minilab transform.
