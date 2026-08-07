# Demo proofs

Each file checks one part of the Otlet contract close to its SQL, even when that repeats setup and assertions

Run the full native suite from the repository root:

```sh
./scripts/otlet-setup.sh
./scripts/otlet-demo.sh
```

`otlet-demo.sh` sources these files in order. Most files share setup and database state, so do not run them as standalone scripts. These files can also be used as docs and/or tests at some point