"""Generate checked-in public fonts. Usage: python build-public-fonts.py FONT_SOURCE_DIR.
Requires fonttools[woff]==4.66.1. Font sources and OFL licenses: public/fonts/README.md.
Normal npm builds use the generated assets and need no Python runtime.
"""
from pathlib import Path
import hashlib, json, sys
from fontTools.ttLib import TTFont
from fontTools.subset import Options, Subsetter
from fontTools.varLib.instancer import instantiateVariableFont

root = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1])
out = root / 'public/fonts'
text = ''.join(p.read_text() for p in (root / 'src').rglob('*') if p.suffix in {'.js', '.jsx', '.css'})
# All current UI characters, Latin letters, punctuation and Traditional Chinese numerals.
requested = {ord(c) for c in text} | set(range(0x20, 0x250)) | set(range(0x2000, 0x2070))
manifest = {}
for filename, target, latin_only in [('NotoSerifTC.ttf', 'rou-serif-tc-v1.woff2', False), ('CormorantGaramond.ttf', 'cormorant-garamond-v1.woff2', True)]:
    font = TTFont(source / filename)
    original_cmap = set(font.getBestCmap())
    wanted = {cp for cp in requested if not latin_only or cp < 0x3000}
    missing_cjk = sorted(cp for cp in wanted - original_cmap if 0x3400 <= cp <= 0x9fff)
    if missing_cjk:
        raise ValueError(f'{filename}: missing CJK characters {missing_cjk}')
    options = Options()
    options.flavor = 'woff2'
    options.layout_features = ['*']
    subset = Subsetter(options=options)
    subset.populate(unicodes=wanted & original_cmap)
    subset.subset(font)
    instantiateVariableFont(font, {'wght': (300, 700)}, inplace=True)
    font.flavor = 'woff2'
    font.save(out / target)
    saved = TTFont(out / target)
    manifest[target] = {'sha256': hashlib.sha256((out / target).read_bytes()).hexdigest(), 'source_sha256': hashlib.sha256((source / filename).read_bytes()).hexdigest(), 'bytes': (out / target).stat().st_size, 'codepoints': sorted(saved.getBestCmap()), 'weight': [300, 700]}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print({name: {'bytes': f['bytes'], 'characters': len(f['codepoints'])} for name, f in manifest.items()})
