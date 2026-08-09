# Community CI builds

This fork adds a GitHub Actions pipeline that compiles Cheat Engine from source and
publishes the result as a GitHub Release. Nothing about the program itself is changed —
the only additions are `.github/workflows/` and `.github/build/`.

## Why

The download page on cheatengine.org has been returning an error for months. The
community mirror linked from its fallback page ships the executable inside a
third-party installer whose UAC prompt names an unrelated publisher, which is not
something worth trusting with a tool that attaches a debugger to your processes.
Building from upstream source sidesteps both problems: the input is a public git
commit and the build steps are in this repository.

Upstream's own GitHub Releases page still has 7.5 (February 2023), and that remains
the best choice if you want a build signed by the actual developer. This pipeline is
for tracking `master` past that point.

## What gets built

`.github/build/build.ps1` drives `lazbuild` over the Lazarus projects in the tree.
Output lands in `Cheat Engine/bin`, alongside the Lua runtime, language files and
prebuilt helper DLLs that are already committed there — so that folder becomes the
portable distribution once the build finishes.

**Required** (the build fails without them):

| Target | Build mode | Output |
| --- | --- | --- |
| `cheatengine.lpi` | Release 64-Bit | `bin/cheatengine-x86_64.exe` |
| `cheatengine.lpi` | Release 32-Bit | `bin/cheatengine-i386.exe` |
| `launcher/cheatengine.lpi` | release | `bin/Cheat Engine.exe` |

**Best effort** (a failure is reported in the job summary but does not fail the build):
the AVX2 variant of the main executable, Runtime Modifier, and the
`speedhack`, `luaclient`, `vehdebug`, `winhook`, `allochook`, `tutorial` and `cepack`
projects in both architectures.

### What is *not* built

- **DBVM** — the kernel-level debugger driver. It needs its own build and a self-signed
  driver, plus test-signing enabled on the target machine. Out of scope here; memory
  scanning, pointer scanning, disassembly and the Lua engine do not depend on it.
- **The Visual Studio projects** — `DirectXMess`, `DotNetcompiler`, `monodatacollector`,
  `dotnetdatacollector`, `dotnetinvasivedatacollector`, `cejvmti`, `tcclib` and
  `dbkkernel` are `.sln` projects. The DLLs that upstream already commits under
  `Cheat Engine/bin` are shipped as-is; anything not committed there is absent, so
  .NET/Mono/Java inspection and `{$C}` script support may be limited.

## Toolchain

Lazarus 2.2.2 with FPC 3.2.2 — the versions the upstream README specifies. Pinning to
them avoids the compatibility patches newer Lazarus releases would need.

They are **not** obtained the way the README describes, because that route no longer
works from a script. Every SourceForge download host redirects to
`downloads.sourceforge.net`, which now answers non-browser clients with a Cloudflare
"Just a moment…" challenge and HTTP 403. That happens on GitHub runners and on ordinary
machines, across every mirror host, with browser-like headers, and through the
`/download` interstitial. There is no header combination that gets past it.

`install-toolchain.ps1` therefore assembles the same toolchain from hosts that are
reachable:

- **FPC 3.2.2** — native `i386-win32` plus the `x86_64-win64` cross compiler, from
  `downloads.freepascal.org`, which serves plain HTTP with no bot wall.
- **Lazarus 2.2.2** — source from its GitLab tag, then `make lazbuild`.

`lazbuild` is built as a native i386-win32 binary and drives 64-bit builds through the
cross compiler, which is how the official "32-bit Lazarus + cross-x86_64 add-on"
combination has always worked.

One wrinkle worth remembering if you touch that script: FPC's fpcmake-generated
Makefiles switch to Unix mode when they find a Unix shell on `PATH`, and the runner
image ships Git's `sh.exe`. `PATH` is trimmed to FPC plus Windows for the duration of
the `make` run.

Two details in `build.ps1` are easy to get wrong when editing the target table:

- Build modes marked `Default="True"` in the `.lpi` files generally carry no explicit
  `<TargetCPU>`. On a 64-bit host that resolves to `x86_64`, which would quietly turn
  the "32-bit" modes into 64-bit builds. Every target therefore passes `--cpu` and
  `--os` explicitly.
- Output filenames embed `$(TargetCPU)`, so the two architectures of one project do not
  overwrite each other.

Every download is checked for plausible size and correct magic bytes before it is used.
A blocked or rate-limited host hands back an HTML error page with a 200, and an
"installer" that is secretly HTML fails much later and much more confusingly.

## Running a build

Every push to `master` builds and uploads the portable zip as a workflow artifact
(30-day retention). `Actions → Build → Run workflow` does the same on demand, with an
optional `--build-all` full recompile.

## Cutting a release

```bash
git tag ci-7.5-001
git push origin ci-7.5-001
```

`release.yml` calls `build.yml` (with a full recompile), then publishes a GitHub
Release containing:

- `CheatEngine-<version>-portable-unsigned.zip`
- `SHA256SUMS.txt` — covering the archive and every executable inside it

`Actions → Release → Run workflow` does the same without pushing a tag.

## Caveats for anyone downloading these

- **Unsigned.** No code-signing certificate is involved. SmartScreen will warn, and some
  antivirus products flag Cheat Engine even when it is signed. Check the published
  SHA256 against your download and read the workflow log if you want to see how the
  binary was produced.
- **Unsupported.** Not an official release, not endorsed by the Cheat Engine developer.
  Problems with these builds belong in this repository's issue tracker, not the
  upstream forum.
- Extract the whole archive and keep the folder intact. `Cheat Engine.exe` is a launcher
  that picks the 32- or 64-bit build; the surrounding Lua scripts and DLLs are required.

## Keeping up with upstream

```bash
git remote add upstream https://github.com/cheat-engine/cheat-engine.git
git fetch upstream
git merge upstream/master
```

CI lives entirely in `.github/`, and `docs/CI-BUILDS.md` plus a short block at the top
of `README.md` are the only additions outside it, so merge conflicts should be rare.
