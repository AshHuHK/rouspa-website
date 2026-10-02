# Public typography assets

The public site serves these fonts from its own origin. It does not request Google Fonts stylesheets or split glyph files at runtime.

- Noto Serif TC variable source: https://github.com/google/fonts/tree/main/ofl/notoseriftc
- Cormorant Garamond variable source: https://github.com/google/fonts/tree/main/ofl/cormorantgaramond
- Original OFL notices are included alongside the generated assets.

`rou-serif-tc-v1.woff2` covers the site's current static Chinese text, Latin letters and punctuation, including every treatment heading and step. It retains the variable weight range 300–700. All treatment names use weight 500; the hero retains weight 700. User-entered or future catalog characters outside this subset use the specified local serif fallback.

`manifest.json` records each source digest, generated asset digest, covered codepoints and weights. To refresh, download the two upstream TTF files as `NotoSerifTC.ttf` and `CormorantGaramond.ttf`, retain the licenses, install `fonttools[woff]==4.66.1` in a temporary Python environment, then run `python scripts/build-public-fonts.py SOURCE_DIRECTORY`. The normal website build uses committed WOFF2 files; Python is not a production dependency. Run `npm test` after changing public text; its typography check detects missing static Chinese glyphs and stale assets.
