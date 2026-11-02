// Umbrella header for the translate-c step that feeds src/text.zig.
//
// Zig 0.17 removed the `@cImport` builtin, so the headers text.zig used to pull
// in-line are translated by a build step instead (`addTextC` in build.zig) and
// imported as the module "text_c". The HarfBuzz half is gated by a macro the
// build defines from `Features` (build.zig) — the single source of truth, which
// text.zig reads back by checking what this header declared: macOS/Windows/wasm/
// Android have no hb.h on their include path.
#include "stb_truetype.h"
#ifdef ZICRO_HAVE_HARFBUZZ
#include <hb.h>
#endif
