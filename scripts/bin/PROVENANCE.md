# Bundled jq binaries

These are the official, unmodified static binaries published by the jq
project, bundled so this plugin never requires the user to install `jq`
themselves. `jq` on the user's own `PATH` is always preferred when present;
these are only used as a fallback.

- **Source:** https://github.com/jqlang/jq/releases/tag/jq-1.8.2
- **Version:** 1.8.2

| File | SHA-256 |
| --- | --- |
| `jq-macos-arm64` | `2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e` |
| `jq-macos-amd64` | `e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0` |
| `jq-linux-amd64` | `b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f` |
| `jq-linux-arm64` | `8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309` |

Verify with `shasum -a 256 <file>` against the table above. No Windows binary
is bundled yet — Windows support is tracked separately.

To update: download the new release's binaries and `sha256sum.txt` from the
jq GitHub releases page, verify the hashes, replace these files, and update
this table.
