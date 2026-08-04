# Provenance gate

Final release provenance must be generated after the implementation commit and
must record: commit, compiler commit and SHA-256, Node/SQLite versions,
architecture, canonical runtime source hashes, generated kernel hash, all test
commands/results, and package archive SHA-256. Two clean isolated archive builds
must be byte-identical. Generated application artifacts must contain the
production worker/supervisor and must not contain feasibility or fault hooks.

No provenance file in this directory currently claims final release acceptance.
