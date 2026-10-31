"""WCAG 2.x contrast of Lumen's colour pairs, current tokens (Theme.swift) and the proposal.

Run: python3 design/tools/contrast.py  →  prints tables and writes design/tools/contrast.json.
Colours with alpha are composited over the surface they sit on before measuring, as SwiftUI draws them.
"""
import json, os

def hex2rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

def over(fg, alpha, bg):
    """fg at `alpha` composited over opaque bg (sRGB, as Core Graphics blends by default)."""
    return tuple(alpha * f + (1 - alpha) * b for f, b in zip(fg, bg))

def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def lum(rgb):
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

def to_hex(rgb):
    return '#' + ''.join(f'{round(c * 255):02X}' for c in rgb)

WHITE = (1.0, 1.0, 1.0)

CURRENT = {
    'surfaces': {
        'backdrop': '0B0C0F', 'sidebar': '121419', 'surface': '161920', 'toolbar': '1A1D24',
        'card': '1B1F27', 'raised': '1E222A', 'raisedInset': '252A33', 'field': '0F1115',
    },
    'text': {'textPrimary': 'ECEEF2', 'textSecondary': 'A2A9B6', 'textTertiary': '7C8494', 'textDisabled': '555D6C'},
    'state': {'accent': '6F8FEA', 'accentFill': '5E84EB', 'running': '4CC38A', 'warning': 'D9A441', 'danger': 'E5635C'},
}

# The proposal changes as little as it can: tertiary text one step lighter so it holds 4.5:1 on every
# surface it is used on (sheets and their inset panels included), a darker fill for white-on-accent
# (selected chips, the highlighted menu item), and line tokens that make a field's edge visible.
PROPOSED = json.loads(json.dumps(CURRENT))
PROPOSED['text']['textTertiary'] = '8A93A3'
PROPOSED['state']['danger'] = 'EC6F68'
PROPOSED['state']['accentFillStrong'] = '4469D6'

def surface_rgb(tokens, name):
    return hex2rgb(tokens['surfaces'][name])

def text_rows(tokens):
    rows = []
    usage = {
        # where each text token is actually drawn (from the views)
        'textPrimary': ['backdrop', 'sidebar', 'surface', 'toolbar', 'card', 'raised', 'raisedInset', 'field'],
        'textSecondary': ['backdrop', 'sidebar', 'surface', 'toolbar', 'card', 'raised', 'raisedInset', 'field'],
        'textTertiary': ['backdrop', 'sidebar', 'surface', 'card', 'raised', 'raisedInset', 'field'],
        'textDisabled': ['backdrop', 'surface', 'raised'],
        'accent': ['sidebar', 'surface', 'raised', 'raisedInset'],
        'running': ['surface', 'raised', 'raisedInset'],
        'warning': ['sidebar', 'surface', 'raised', 'raisedInset'],
        'danger': ['surface', 'raised', 'raisedInset'],
    }
    for name, surfaces in usage.items():
        fg = hex2rgb(tokens['text'].get(name) or tokens['state'][name])
        for s in surfaces:
            r = ratio(fg, surface_rgb(tokens, s))
            rows.append({'fg': name, 'bg': s, 'ratio': round(r, 2)})
    return rows

def special_rows(tokens):
    st, t = tokens['state'], tokens['text']
    surf = surface_rgb(tokens, 'surface')
    raised = surface_rgb(tokens, 'raised')
    sidebar = surface_rgb(tokens, 'sidebar')
    rows = []
    def add(label, fg, bg, kind='text'):
        rows.append({'pair': label, 'ratio': round(ratio(fg, bg), 2), 'kind': kind, 'fgHex': to_hex(fg), 'bgHex': to_hex(bg)})
    selected_row = over(hex2rgb(st['accentFill']), 0.14, surf)
    hover_row = over(WHITE, 0.04, surf)
    sidebar_sel = over(WHITE, 0.08, sidebar)
    accent_tint = over(hex2rgb(st['accent']), 0.14, surf)
    add('textPrimary on rowSelected (surface)', hex2rgb(t['textPrimary']), selected_row)
    add('textSecondary on rowSelected (surface)', hex2rgb(t['textSecondary']), selected_row)
    add('textTertiary on rowSelected (surface)', hex2rgb(t['textTertiary']), selected_row)
    add('textSecondary on rowHover (surface)', hex2rgb(t['textSecondary']), hover_row)
    add('textTertiary on rowHover (surface)', hex2rgb(t['textTertiary']), hover_row)
    add('textPrimary on sidebar selection', hex2rgb(t['textPrimary']), sidebar_sel)
    add('textTertiary (counts) on sidebar selection', hex2rgb(t['textTertiary']), sidebar_sel)
    add('accent on accentTint (exit pill, chip)', hex2rgb(st['accent']), accent_tint)
    add('white on accentFill (selected chip)', WHITE, hex2rgb(st['accentFill']))
    if 'accentFillStrong' in st:
        add('white on accentFillStrong (proposed chip)', WHITE, hex2rgb(st['accentFillStrong']))
    add('primaryText on primaryFill (primary button)', hex2rgb('121419'), hex2rgb('E6E8ED'))
    add('textTertiary placeholder on field', hex2rgb(t['textTertiary']), surface_rgb(tokens, 'field'))
    # a sealing row is drawn at 60 % opacity (ProfileRow): its secondary line over the surface
    sec60 = over(hex2rgb(t['textSecondary']), 0.6, surf)
    pri60 = over(hex2rgb(t['textPrimary']), 0.6, surf)
    add('textPrimary at 60 % (sealing row) on surface', pri60, surf)
    add('textSecondary at 60 % (sealing row) on surface', sec60, surf)
    # a disabled button: the whole control at 45 %
    add('textPrimary at 45 % (disabled secondary button) on raised', over(hex2rgb(t['textPrimary']), 0.45, raised), raised)
    # non-text: WCAG 1.4.11 asks 3:1 for what identifies a control or a state
    add('fieldBorder (white 10 %) edge vs raised', over(WHITE, 0.10, raised), raised, 'non-text')
    add('field fill vs raised', surface_rgb(tokens, 'field'), raised, 'non-text')
    add('strongBorder (white 14 %) vs raised', over(WHITE, 0.14, raised), raised, 'non-text')
    add('white 24 % edge vs raised', over(WHITE, 0.24, raised), raised, 'non-text')
    add('white 30 % edge vs raised', over(WHITE, 0.30, raised), raised, 'non-text')
    add('focus ring accent vs raised', hex2rgb(st['accent']), raised, 'non-text')
    add('focus ring accent vs surface', hex2rgb(st['accent']), surf, 'non-text')
    add('focus ring accent at 30 % (field halo) vs raised', over(hex2rgb(st['accent']), 0.30, raised), raised, 'non-text')
    add('running dot vs surface', hex2rgb(st['running']), surf, 'non-text')
    add('progress track (white 10 %) vs surface', over(WHITE, 0.10, surf), surf, 'non-text')
    add('progress fill accentFill vs track', hex2rgb(st['accentFill']), over(WHITE, 0.10, surf), 'non-text')
    add('toggle on (accentFill) vs raised', hex2rgb(st['accentFill']), raised, 'non-text')
    add('hairline (white 8 %) vs surface', over(WHITE, 0.08, surf), surf, 'non-text')
    add('rowSelected vs surface', selected_row, surf, 'non-text')
    add('controlFill (white 6 %) button vs raised', over(WHITE, 0.06, raised), raised, 'non-text')
    return rows

out = {}
for label, tokens in (('current', CURRENT), ('proposed', PROPOSED)):
    out[label] = {'text': text_rows(tokens), 'special': special_rows(tokens)}

def changes():
    """Each pair the proposal changes: what is drawn now, what would be drawn instead, both measured."""
    surf, raised, inset = (hex2rgb(CURRENT['surfaces'][k]) for k in ('surface', 'raised', 'raisedInset'))
    sidebar = hex2rgb(CURRENT['surfaces']['sidebar'])
    t_now, t_new = hex2rgb('7C8494'), hex2rgb('8A93A3')
    sel = over(hex2rgb('5E84EB'), 0.14, surf)
    rows = [
        ('text', 'Подсказка в листе (EditorNote) · textTertiary на raised', 'Hint in a sheet (EditorNote) · textTertiary on raised',
         ratio(t_now, raised), 'textTertiary #8A93A3', ratio(t_new, raised)),
        ('text', 'Подпись в панели листа · textTertiary на raisedInset', 'Caption in a sheet panel · textTertiary on raisedInset',
         ratio(t_now, inset), 'textTertiary #8A93A3', ratio(t_new, inset)),
        ('text', 'Число в выбранном пункте боковой панели', 'Count in the selected sidebar item',
         ratio(t_now, over(WHITE, 0.08, sidebar)), 'textTertiary #8A93A3', ratio(t_new, over(WHITE, 0.08, sidebar))),
        ('text', 'Мета в выбранной строке · textTertiary на rowSelected', 'Meta in a selected row · textTertiary on rowSelected',
         ratio(t_now, sel), 'textTertiary #8A93A3', ratio(t_new, sel)),
        ('text', 'Ошибка в панели листа · danger на raisedInset', 'Error in a sheet panel · danger on raisedInset',
         ratio(hex2rgb('E5635C'), inset), 'danger #EC6F68', ratio(hex2rgb('EC6F68'), inset)),
        ('text', 'Белый на выбранном чипе прогрева · accentFill', 'White on a selected warm-up chip · accentFill',
         ratio(WHITE, hex2rgb('5E84EB')), 'accentFillStrong #4469D6', ratio(WHITE, hex2rgb('4469D6'))),
        ('text', 'Строка «Шифрование…» приглушена до 60 % · вторичный текст', 'Sealing row dimmed to 60 % · secondary text',
         ratio(over(hex2rgb('A2A9B6'), 0.6, surf), surf), 'без приглушения, статус словом / no dimming, a status', ratio(hex2rgb('A2A9B6'), surf)),
        ('non-text', 'Выбранная строка: заливка rowSelected против surface', 'Selected row: rowSelected fill vs surface',
         ratio(sel, surf), 'полоска accentFill + чекбокс / accentFill bar + checkbox', ratio(hex2rgb('5E84EB'), sel)),
        ('non-text', 'Фокус поля: ореол accent 30 %', 'Field focus: 30 % accent halo',
         ratio(over(hex2rgb('6F8FEA'), 0.30, raised), raised), 'кольцо 2 pt accent / 2 pt accent ring', ratio(hex2rgb('6F8FEA'), raised)),
        ('non-text', 'Фокус кнопки, строки, пункта меню', 'Focus on a button, row, sidebar item',
         1.0, 'кольцо 2 pt accent / 2 pt accent ring', ratio(hex2rgb('6F8FEA'), surf)),
        ('non-text', 'Край поля: fieldBorder белый 10 %', 'Field edge: fieldBorder white 10 %',
         ratio(over(WHITE, 0.10, raised), raised), '«Увеличить контраст»: белый 36 % / Increase Contrast: white 36 %', ratio(over(WHITE, 0.36, raised), raised)),
    ]
    return [{'kind': k, 'ru': ru, 'en': en, 'now': round(a, 2), 'instead': instead, 'next': round(b, 2)} for k, ru, en, a, instead, b in rows]

out['changes'] = changes()

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, 'contrast.json'), 'w') as f:
    json.dump(out, f, indent=1)
# The same numbers for the prototypes (a classic script: pages opened from file:// cannot fetch JSON).
with open(os.path.join(here, '..', 'prototypes', 'kit', 'contrast-data.js'), 'w') as f:
    f.write('// Generated by design/tools/contrast.py — WCAG contrast of Lumen colour pairs. Do not edit.\n')
    f.write('(function (L) { L.contrast = ' + json.dumps(out) + '; })(globalThis.Lumen = globalThis.Lumen || {});\n')

for label in ('current', 'proposed'):
    print(f'== {label}: text tokens on surfaces (AA body text needs 4.5)')
    rows = out[label]['text']
    fgs = list(dict.fromkeys(r['fg'] for r in rows))
    for fg in fgs:
        cells = [f"{r['bg']} {r['ratio']:.2f}{'' if r['ratio'] >= 4.5 else ' ✗'}" for r in rows if r['fg'] == fg]
        print(f'  {fg:14} ' + ' | '.join(cells))
    print(f'== {label}: special pairs')
    for r in out[label]['special']:
        need = 4.5 if r['kind'] == 'text' else 3.0
        mark = '' if r['ratio'] >= need else ' ✗'
        print(f"  {r['ratio']:5.2f}{mark:3} {r['kind']:8} {r['pair']}  ({r['fgHex']} on {r['bgHex']})")
