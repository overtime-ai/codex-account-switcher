# Saved Claude pin settings

The macOS switcher embeds Google's LevelDB 1.23 and Snappy 1.2.2 to update Claude's Chromium local-storage database without UI automation. Only their build sources are included. Each directory records the upstream archive URL and SHA-256 in `UPSTREAM.txt` and retains its license; both licenses ship in the app bundle.

`Package.swift` enables Snappy for LevelDB because Claude's existing tables are compressed. The local module maps expose only the C APIs to Swift. Snappy's `snappy-stubs-public.h` is generated from the upstream template for macOS; `config.h` selects portable macOS implementations without requiring SIMD extensions. Database writes use the upstream implementation, not a custom LevelDB parser.
