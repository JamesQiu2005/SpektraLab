// strip.hpp -- the plan's geometry, in its own header because two layers need
// to agree about it.
//
// `StripSpan` was declared in `pipeline.hpp` until class R: the executor plans
// with it, and now the sweeps inside a `Swept` stage iterate with it, and
// `blur.hpp` sits below `pipeline.hpp` in the include order. Moving the type
// down rather than letting either layer re-spell `(y0, rows)` as a pair of
// integers -- a pair of loose values is the shape that lets an origin drift by
// one, which is the trap RFC-020 §4.5 names.
#pragma once

#include <cstdint>

namespace spk {

/// One strip of a run: a full-width band of the plane the executor is cutting,
/// as `(y0, rows)` in that plane's own rows.
///
/// **The plan is over the plane the strips partition**, which is the plane
/// entering the striped segment -- the film side's, that is after `geometry`,
/// which is whole-frame in v1 and changes the dimensions. It is the frame's
/// own height only when geometry is a no-op, and calling it "the frame" loosely
/// is how a crop ends up off by its own offset.
struct StripSpan {
    uint32_t y0 = 0;
    uint32_t rows = 0;
};

}  // namespace spk
