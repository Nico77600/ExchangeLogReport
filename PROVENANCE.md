# Public provenance declaration

- Repository: https://github.com/Nico77600/ExchangeLogReport
- Default branch: `main`
- Release: `v3.0.1` (`ExchangeLogReport-3.0.1-win-x64.zip`)
- Base of the release branch: public `main` at `6d77ed3b2e3e424fe623ce6b29b6758c1501910d` (merge of pull request #10, 2026-11-06, after tag `v3.0.0`)
- Audited revision: `3b88688454e84aaf0729f7394b23c163f5aea7d1` (release content of `release/3.0.1-20261117`; this provenance record is the next commit)
- Audit date: 2026-11-17
- Public commits inspected across branches and tags: 43 (39 before the release branch, on `main`, the 7 other public branches and the tags `v1.3.1`, `v1.4.0`, `v1.6.1`, `v2.0.0`, `v2.1.0`, `v2.1.1` and `v3.0.0`, plus the 4 commits of the release branch)
- `Co-authored-by: Copilot` findings: none (no `Co-authored-by` trailer at all in the 43 commits)
- Previous audit: `bb44b5e785ea229752d7fa2ad9e58359be3ccba8`, 2026-11-03, 33 public commits, no `Co-authored-by: Copilot` finding

This declaration records the public commit-history audit at the revision above. It is not a cryptographic signature and does not make claims about how source code was authored. Release assets are covered by the GitHub Actions workflow in `.github/workflows/attest-release.yml`; run it manually for an existing release when needed.

## Package integrity

The release ZIP (`ExchangeLogReport-3.0.1-win-x64.zip`, built by `tools/Build-Standalone.ps1`) is the user deliverable; the source archives of a release are not.

- The six PowerShell files that run first (`Invoke-ExchangeLogReport.ps1`, `Database-Storage.ps1`, `ExchangeLogReport.psm1`, `ExchangeLogReport.psd1`, `src/Test-PackageIntegrity.ps1`, `src/Get-ExlExchangeSettings.ps1`) and the manifest `PackageIntegrity.psd1` carry the owner's Authenticode signature with a trusted timestamp. The verifier hard-codes the signer thumbprint (`0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6`).
- The manifest lists the SHA-256 of every other protected file in two groups: `Files` (present in the repository and in the package: the C# sources compiled in memory, the SQLite libraries, the report template, the HTML guides, the launchers, the README and notices) and `DistributionFiles` (built binaries that exist in the package only: the PowerShell runtime `powershell/` and the SQLite tool `sqlite-tools/`). These are hash-protected by the signed manifest, not signed by the owner. The launchers (`.cmd`) cannot carry an Authenticode signature: the manifest protects them by hash.
- The launchers and the entry scripts run the verifier before any other code of the package; a file that is missing, changed, unknown or a reparse point stops the start. The configuration, the generated folders and the mail credential are the only unprotected places.
- The builder works in three steps so that the owner signs between them: build the folder (it refuses unsigned scripts), write the unsigned manifest, then seal the package once the signed manifest is in the repository. No key material is read by any tool of the repository.
- Continuous integration builds an unsigned package from the signed sources and verifies it with `-DevelopmentMode` (files and signatures; the built folders are assembled on the runner and are not compared with the manifest).

## Attesting the ZIP

`.github/workflows/attest-release.yml` downloads the published ZIP assets of an existing release tag, checks the inventory of the signed manifest against the bytes of the ZIP (without running any of it), checks that the signature blocks are present and that the report page template and its script are complete, and attests the ZIP bytes. Authenticode signatures are validated on Windows, at launch, by the verifier.
