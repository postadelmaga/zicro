//! Design tokens — i colori, i raggi, le spaziature e la scala tipografica di un'app zicro.
//!
//! Non è un widget toolkit in più: è il *vocabolario*. Un'app che scrive `t.surface_2` o
//! `t.radius.lg` invece di `Color.rgba(28, 34, 42, 1)` e `16` ottiene tre cose che un
//! numero magico non dà mai: coerenza fra le schermate, un tema chiaro gratis (basta
//! scambiare la tabella), e la possibilità di ritoccare l'aspetto di TUTTA l'app in un
//! posto solo. Le convenzioni sono quelle che gli utenti già conoscono — i ruoli di
//! superficie di Material 3 (surface/on-surface/outline, con le superfici che schiariscono
//! man mano che l'elemento "si alza") e la palette di sistema di iOS per gli accenti, che
//! è tarata per restare leggibile su fondo scuro.
//!
//! Uso tipico:
//! ```zig
//! const t = zicro.theme.dark;
//! canvas.fillRoundedRect(x, y, w, h, t.radius.lg, t.surface_2);
//! canvas.drawText(font, x, y, "Titolo", .{ .size = t.type.title, .color = t.on_surface });
//! ```

const paint = @import("paint.zig");
const Color = paint.Color;

fn hex(comptime s: []const u8) Color {
    @setEvalBranchQuota(4000); // parseInt a comptime, moltiplicato per i colori della tabella
    // "#RRGGBB" → Color opaco. Comptime: nessun costo a runtime, e un colore scritto male
    // non compila invece di diventare nero a schermo.
    const v = @import("std").fmt.parseInt(u24, s[1..], 16) catch unreachable;
    return Color.rgba(@intCast(v >> 16), @truncate(v >> 8), @truncate(v), 1.0);
}

/// Un colore con l'alpha sostituito — per le tinte (accento al 16% su una superficie) e
/// per gli scrim, dove il colore è lo stesso ma la presenza no.
pub fn alpha(c: Color, a: f32) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// Raggi degli angoli. Crescono con l'importanza dell'elemento: un chip è quasi quadrato,
/// un foglio modale è francamente tondo — è così che l'occhio capisce la gerarchia.
pub const Radius = struct {
    xs: f32 = 6,
    sm: f32 = 10,
    md: f32 = 14,
    lg: f32 = 18,
    xl: f32 = 26,
    /// Pillola: passare un raggio ≥ metà altezza dà i capi semicircolari.
    pill: f32 = 999,
};

/// Griglia di spaziatura a passo 4: tutte le distanze dell'interfaccia sono multipli di
/// questi. Un layout con margini presi a caso si vede, anche da chi non saprebbe dire perché.
pub const Space = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,
    xxl: f32 = 32,
};

/// Scala tipografica (px a scala 1). Pochi gradini, ben distanziati: se due testi hanno
/// misure quasi uguali sembrano un errore, non una gerarchia.
pub const Type = struct {
    display: u16 = 28,
    title: u16 = 20,
    headline: u16 = 17,
    body: u16 = 15,
    label: u16 = 13,
    caption: u16 = 11,
};

/// Gli accenti di sistema di iOS (varianti scure): saturi ma non fluorescenti, e scelti per
/// essere distinguibili tra loro anche da chi confonde rosso e verde. Servono a colorare
/// *categorie* (un tipo di file, uno stato), mai le superfici.
pub const Accent = struct {
    blue: Color,
    green: Color,
    indigo: Color,
    orange: Color,
    pink: Color,
    purple: Color,
    red: Color,
    teal: Color,
    yellow: Color,
    gray: Color,
};

pub const Theme = struct {
    /// Il fondo dell'app. `surface_1..3` sono i piani sopra di esso: più un elemento è
    /// "alzato" (scheda → pannello → foglio modale), più la sua superficie schiarisce —
    /// l'ombra da sola, su fondo scuro, non basta a staccarlo.
    surface: Color,
    surface_1: Color,
    surface_2: Color,
    surface_3: Color,
    /// Sfumatura del fondo (da `surface` a questo): appena percettibile, dà profondità a una
    /// schermata altrimenti piatta. Opaca — così il rasterizzatore la riempie a memset.
    surface_tint: Color,

    /// Testo e icone SOPRA le superfici. `_var` è il secondario (didascalie, metadati):
    /// stesso colore smorzato, non un grigio a caso.
    on_surface: Color,
    on_surface_var: Color,
    /// Bordi sottili e separatori: un capello, non una linea.
    outline: Color,

    /// L'azione: il pulsante primario, la selezione, il cursore.
    primary: Color,
    on_primary: Color,
    /// Il primario "tonale": il primario diluito nella superficie, per gli stati (premuto,
    /// selezionato) dove un pieno saturo urlerebbe.
    primary_container: Color,

    /// Velo sotto i modali: nasconde il contenuto senza cancellarlo.
    scrim: Color,

    accent: Accent,
    radius: Radius = .{},
    space: Space = .{},
    type: Type = .{},

    /// Superficie del piano `n` (0..3) — comodo quando l'elevazione è calcolata, non scritta.
    pub fn surfaceAt(self: Theme, n: u2) Color {
        return switch (n) {
            0 => self.surface,
            1 => self.surface_1,
            2 => self.surface_2,
            3 => self.surface_3,
        };
    }
};

/// Tema scuro: il default di zicro (le app di questa famiglia sono visualizzatori, e un
/// fondo scuro toglie di mezzo la cornice per lasciare il contenuto). Neutri leggermente
/// freddi, non neri: il nero puro su OLED "sfarfalla" ai bordi degli elementi e schiaccia
/// ogni ombra.
pub const dark = Theme{
    .surface = hex("#0E1116"),
    .surface_1 = hex("#161A21"),
    .surface_2 = hex("#1E242D"),
    .surface_3 = hex("#28303B"),
    .surface_tint = hex("#0A0D12"),

    .on_surface = hex("#E8ECF2"),
    .on_surface_var = hex("#9AA4B2"),
    .outline = hex("#2B3340"),

    .primary = hex("#0A84FF"),
    .on_primary = hex("#FFFFFF"),
    .primary_container = hex("#123A66"),

    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 0.55 },

    .accent = .{
        .blue = hex("#0A84FF"),
        .green = hex("#30D158"),
        .indigo = hex("#5E5CE6"),
        .orange = hex("#FF9F0A"),
        .pink = hex("#FF375F"),
        .purple = hex("#BF5AF2"),
        .red = hex("#FF453A"),
        .teal = hex("#64D2FF"),
        .yellow = hex("#FFD60A"),
        .gray = hex("#98989D"),
    },
};

/// Tema chiaro: stessi ruoli, tabella scambiata. Le superfici qui SCURISCONO salendo
/// (l'ombra fa il resto), e gli accenti sono le varianti chiare di iOS — le stesse tinte,
/// ma con la luminanza abbassata quanto basta a restare leggibili su bianco.
pub const light = Theme{
    .surface = hex("#F6F7F9"),
    .surface_1 = hex("#FFFFFF"),
    .surface_2 = hex("#FFFFFF"),
    .surface_3 = hex("#FFFFFF"),
    .surface_tint = hex("#E9ECF1"),

    .on_surface = hex("#111418"),
    .on_surface_var = hex("#5F6875"),
    .outline = hex("#D8DDE4"),

    .primary = hex("#007AFF"),
    .on_primary = hex("#FFFFFF"),
    .primary_container = hex("#D8E9FF"),

    .scrim = .{ .r = 0, .g = 0, .b = 0, .a = 0.35 },

    .accent = .{
        .blue = hex("#007AFF"),
        .green = hex("#28A745"),
        .indigo = hex("#5856D6"),
        .orange = hex("#F09000"),
        .pink = hex("#FF2D55"),
        .purple = hex("#AF52DE"),
        .red = hex("#FF3B30"),
        .teal = hex("#0FA3C7"),
        .yellow = hex("#C79A00"),
        .gray = hex("#8E8E93"),
    },
};
