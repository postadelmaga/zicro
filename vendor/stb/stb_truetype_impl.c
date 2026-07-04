/* Implementazione di stb_truetype compilata dentro zuer-gui: rasterizzazione
   nativa di glifi TrueType (font Hack embeddato) per la resa del testo, senza
   ImageMagick. Usa malloc/free e math di libc (link_libc attivo). */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
