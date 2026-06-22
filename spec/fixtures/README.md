# Test fixtures

This directory holds files used by the RSpec suite under `spec/`.

## Bundled example game (committed)

The snapshot, extracted JSON, mapping and English translation of the
example game **"El Espía"** ship with the public repository at
`games/espia.sna`, `games/espia.json`, `games/espia.mapping.json`,
`games/espia_en.json`, etc. The integration specs in `spec/` reference
these files directly (no symlink required), so the public test suite
runs out of the box on a fresh clone.

## Local game library (not committed)

`games/<other>.{sna,z80,sp,tap}` for any other game is ignored by
`.gitignore`. To exercise the engine against your own collection:

```bash
mkdir -p games                                  # your personal game library
# (already created in the public repo if you're checking out the example game)
```

Place your own copies inside `games/` and pass them to the CLI tools or
the regression specs under `.agents/specs/`. The `.agents/specs/fixtures/`
directory keeps the matching command/transcript files for those local
regressions and is itself gitignored.

The `spec/fixtures/games/` symlink (created locally with
`ln -s ../../games spec/fixtures/games`) is a convenience for
machine-local games and is **not** used by the public suite. The public
suite references `games/<file>` directly.

## Text fixtures (committed)

There are currently no committed text fixtures here — all game-specific
transcripts live under `.agents/specs/fixtures/` together with their
regression specs.
