# Chrome SDK

- Canonical source: https://github.com/ignaciojuarez/chrome-sdk. Develop and push here; do not maintain a private mirror.
- Swift API, Chromium overlay/patches, and native harness belong here. Cobble UI and persistence belong in `cobble-browser`.
- Preserve GPLv3 and upstream attribution. Do not copy private BSD headers over public files.
- Run `python3 -m unittest discover -s Tests -p "test_*.py"`, `node Tests/test_smoke_fixture.mjs`, `swift test`, and `swift build --product CobbleChromiumClient`.
- Native work/cache stays outside Git. Use one build writer, retain a matched rollback runtime, and never commit artifacts or local evidence.
- Changed native payloads require an incremental native rebuild, packaging provenance checks, and the isolated harness. Publish immutable development runtime archives with checksums; signing/notarization and app releases are separate.
- Cobble pins the exact public SDK revision. Keep ABI, source lock, native payload and runtime manifest matched; never bypass validation.
- Never mark release or real-site qualification complete from source checks or isolated fixtures.

## Before committing or publishing

Review the complete intended changes, not only filenames or a summary. Read
`git diff`, every new/untracked file you intend to include, and the final
`git diff --cached` after staging explicit paths. Inspect images/screenshots
visually and check generated files or archives before including them.

Exclude credentials, tokens, private signing keys/certificates, cookies,
browser profiles/history, personal or account data, private URLs, local machine
identifiers and unredacted logs/evidence. Use synthetic fixtures, placeholders,
ignored local configuration and Keychain instead. Preserve useful source/docs
when porting work; check every changed and new file against the destination.
`.gitignore` and automated scans do not replace this content review.
