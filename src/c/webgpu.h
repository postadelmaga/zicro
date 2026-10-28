// Umbrella header for the translate-c step behind src/gpu_wgpu.zig.
//
// Zig 0.17 removed `@cImport`. The header itself comes from somewhere else in
// each of the two forms of this binding: the DESKTOP one takes it from the
// prebuilt wgpu-native dependency (build.zig adds that include path to the
// step); the BROWSER one takes it from the consumer's emsdk cache, which this
// repo cannot know — see `zicro_wgpu_browser` in build.zig for how a consumer
// wires its own translate-c step.
#include "webgpu/webgpu.h"
