/* stb_truetype for the wasm32-freestanding web build.
 *
 * Freestanding wasm has no libc, so predefine every STBTT_* hook BEFORE including the
 * header — that suppresses its <math.h>/<stdlib.h>/<string.h> includes. The inlinable
 * math lowers to wasm opcodes via __builtin_*; malloc/free and the non-opcode libm calls
 * (pow/cos/acos/fmod) route to the Zig shims in src/wasm_shim.zig. */
#include <stddef.h>

#define STBTT_ifloor(x)   ((int) __builtin_floor(x))
#define STBTT_iceil(x)    ((int) __builtin_ceil(x))
#define STBTT_sqrt(x)     __builtin_sqrt(x)
#define STBTT_fabs(x)     __builtin_fabs(x)
#define STBTT_pow(x, y)   zig_pow(x, y)
#define STBTT_fmod(x, y)  zig_fmod(x, y)
#define STBTT_cos(x)      zig_cos(x)
#define STBTT_acos(x)     zig_acos(x)
#define STBTT_malloc(x, u) ((void)(u), zig_malloc(x))
#define STBTT_free(x, u)   ((void)(u), zig_free(x))
#define STBTT_assert(x)   ((void)0)
#define STBTT_strlen(x)   __builtin_strlen(x)
#define STBTT_memcpy      __builtin_memcpy
#define STBTT_memset      __builtin_memset

double zig_pow(double, double);
double zig_fmod(double, double);
double zig_cos(double);
double zig_acos(double);
void *zig_malloc(size_t);
void  zig_free(void *);

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
