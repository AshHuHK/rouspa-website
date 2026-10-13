# ROU SPA typography assets — 思源宋體

The public site serves these fonts from its own origin. It does not request Google Fonts stylesheets or split glyph files at runtime.

- Active source: Adobe Source Han Serif, Taiwan variable TTF, release 2.003R.
- Pinned source: https://github.com/adobe-fonts/source-han-serif/blob/7889f11bf31170b5d092a083b357c8c8130f89e0/Variable/TTF/Subset/SourceHanSerifTW-VF.ttf
- Original OFL notice: `SourceHanSerif-OFL.txt`.
- Subsets have the distinct internal/CSS family `ROU Songti TC` to respect the reserved font name. The outlines and variable weights come from 思源宋體, not an OS substitute.

`rou-songti-tc-core-v1.woff2` is preloaded and includes static UI, Latin letters, punctuation and the currently published treatment vocabulary. `rou-songti-tc-00-v1.woff2` and subsequent files provide the rest of the Taiwan source's 20,750 codepoints through disjoint CSS `unicode-range` faces. A browser downloads only the ranges needed by the current page. New catalogue text and names therefore have the same typeface within the official source's coverage. Unsupported Unicode scripts still use the specified fallback.

The shared `src/typography.css` controls homepage/card/price/form/member/admin typography. Treatment titles use weight 600, subtitles 400, and the hero 700; the source retains true weights 250–900. Both 90- and 120-minute seals have the same layout dimensions and type size while keeping their distinct outlines/backgrounds. Numeric fields use tabular figures where available.

`manifest.json` records source/asset hashes, codepoints and weights. To regenerate, download the pinned Taiwan TTF, install `fonttools[woff]==4.66.1` in a temporary Python environment, then run `python scripts/build-source-han-fonts.py /path/to/SourceHanSerifTW-VF.ttf`. Normal npm builds use committed assets; Python is not a production dependency. `npm test` validates coverage, hashes, source provenance and current treatment vocabulary.

The previous `rou-serif-tc-v1.woff2`, Cormorant font and their licenses remain only for compatibility with cached older pages. New pages do not request them. `scripts/build-public-fonts.py` is a historical builder and must not replace the active Source Han manifest.
