# The Mermaid GitHub renders, for the specs only

`spec/diagrams/github_mermaid_spec.rb` (tag `github_mermaid`, opt in with
`WOODS_RUN_GITHUB_MERMAID=1`) parses every text `Woods::Diagrams` builds with
the Mermaid build that GitHub uses to draw a ```` ```mermaid ```` block
(woods#826). Agents paste these texts into pull requests.

These files are test-time tools. They are not in the gem (`spec.files` leaves
`spec/` out), and Woods never loads them. Both are gzipped, so no plain
vendored JavaScript sits in the tree. Woods Map vendors the same files, with
the same checksums, for its own copy of the spec.

| File | What | Version | License | Source |
|---|---|---|---|---|
| `mermaid-11.16.1.min.js.gz` | `dist/mermaid.min.js` of the npm package, unmodified, `gzip -9 -n` | 11.16.1: npm integrity `sha512-TQsq6u22fAn3rek5VOubrhKPo1g5hwC3FXUN9hiyupTckcYiGuuKGkNQrKYwGJkXUxZdojwRG46gsSCFZMDp4g==`; SHA-256 of the uncompressed file `18327bef70d96fb505fe7287d9f6a7362ebf07ff6576ddfaffb1a06f3e1a2954`, which the spec checks | MIT (`mermaid.LICENSE.md`) | https://www.npmjs.com/package/mermaid |
| `linkedom-0.18.14.mjs.gz` | linkedom's `parseHTML` and its runtime dependencies, bundled into one ES module (`esbuild --bundle --format=esm --platform=node --minify`), `gzip -9 -n` | linkedom 0.18.14: npm integrity `sha512-BRUnkOm4YR5vo+qI3j0EbungB0vZPSCue5AdnTQRaxAGSbsOZiBFRO0rh4zlo8qXUhli8pxvnpEXDklMnlq2Rg==`; SHA-256 of the uncompressed bundle `3489a30ac21f1508a9e4ae711b04594b8445e8130fcc7404206508c75ff47e53` | ISC, with MIT, BSD-2-Clause and ISC dependencies (`linkedom.LICENSES.md`) | https://www.npmjs.com/package/linkedom |

**Why a DOM.** The browser build of Mermaid sanitizes labels with DOMPurify
while it parses, and DOMPurify needs a document. The runner
(`spec/support/github_mermaid_parse.mjs`) evaluates the build in a Node VM
whose global is a linkedom window. Woods Map checked these results against
jsdom.

## Which version GitHub renders

GitHub does not publish it. Its documentation (*Creating diagrams*, "Checking
your version of Mermaid") says to render an `info` diagram in a comment. The
latest such check on record is GitHub Community discussion
[#70672](https://github.com/orgs/community/discussions/70672). On 20 August
2026 it read "GitHub is running Mermaid v11.16.1 (checked via the `info`
diagram)".

## Updating

1. Paste ```` ```mermaid ```` / `info` into a GitHub comment and read the version.
2. `npm pack mermaid@<version>`, then `gzip -9 -n -c package/dist/mermaid.min.js > mermaid-<version>.min.js.gz` here. Replace `mermaid.LICENSE.md`.
3. Update `BUILD` and `BUILD_SHA256` in the spec, and this table.
4. Run `WOODS_RUN_GITHUB_MERMAID=1 bin/rspec spec/diagrams/github_mermaid_spec.rb`.
