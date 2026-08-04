# Release provenance

`final.json` is generated from the release-candidate commit by
`scripts/generate-provenance.cjs`. It records the source commit, dirty state,
pinned compiler/Node/SQLite/platform facts, canonical runtime and assembled
kernel hashes, deterministic package archive hash, and the verification command.

Reproduce from the repository root:

```sh
node scripts/verify.cjs
node scripts/generate-provenance.cjs
node scripts/verify-provenance.cjs
```

The archive builder fixes path ordering, timestamp, owner/group, and gzip header.
Two independent output paths must hash identically. `final.json` is excluded from
the package archive so provenance can name that stable archive without a
self-referential hash.

Binary integrity and source/archive reproducibility are claimed. Reproducible
builds of the Elm compiler and Node binaries themselves are not claimed.
