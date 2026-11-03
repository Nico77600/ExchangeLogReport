# Public provenance declaration

- Repository: https://github.com/Nico77600/ExchangeLogReport
- Default branch: `main`
- Release: `v3.0.0` (`ExchangeLogReport-3.0.0-win-x64.zip`)
- Base of the release branch: public `main` at `2e0998fc10f0974083ba0e4aa66b784490d84518` (tag `v2.1.1`, merge of pull request #8, 2026-10-14)
- Audited revision: **[TO RECORD AT PR TIME: the commit of the release branch that `v3.0.0` will point to]**
- Audit date: **[TO RECORD AT PR TIME]**
- Public commits inspected across branches and tags: **[TO RECORD AT PR TIME]** (30 before the release branch, on `main`, the 7 other public branches and the tags `v1.3.1`, `v1.4.0`, `v1.6.1`, `v2.0.0`, `v2.1.0` and `v2.1.1`)
- `Co-authored-by: Copilot` findings: **[TO RECORD AT PR TIME]** (none in the 30 public commits before the release branch, which carry no `Co-authored-by` trailer at all)
- Previous audit: `9777b682853ab322097f9a8be33f5774b1d05107`, 2026-10-07, 25 public commits, no `Co-authored-by: Copilot` finding

This declaration records the public commit-history audit at the revision above. It is not a cryptographic signature and does not make claims about how source code was authored. Release assets are covered by the GitHub Actions workflow in `.github/workflows/attest-release.yml`; run it manually for an existing release when needed.

## Package integrity

The release ZIP (`ExchangeLogReport-3.0.0-win-x64.zip`, built by `tools/Build-Standalone.ps1`) is the user deliverable; the source archives of a release are not.

- The six PowerShell files that run first (`Invoke-ExchangeLogReport.ps1`, `Database-Storage.ps1`, `ExchangeLogReport.psm1`, `ExchangeLogReport.psd1`, `src/Test-PackageIntegrity.ps1`, `src/Get-ExlExchangeSettings.ps1`) and the manifest `PackageIntegrity.psd1` carry the owner's Authenticode signature with a trusted timestamp. The verifier hard-codes the signer thumbprint (`0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6`).
- The manifest lists the SHA-256 of every other protected file in two groups: `Files` (present in the repository and in the package: the C# sources compiled in memory, the SQLite libraries, the report template, the HTML guides, the launchers, the README and notices) and `DistributionFiles` (built binaries that exist in the package only: the PowerShell runtime `powershell/` and the SQLite tool `sqlite-tools/`). These are hash-protected by the signed manifest, not signed by the owner. The launchers (`.cmd`) cannot carry an Authenticode signature: the manifest protects them by hash.
- The launchers and the entry scripts run the verifier before any other code of the package; a file that is missing, changed, unknown or a reparse point stops the start. The configuration, the generated folders and the mail credential are the only unprotected places.
- The builder works in three steps so that the owner signs between them: build the folder (it refuses unsigned scripts), write the unsigned manifest, then seal the package once the signed manifest is in the repository. No key material is read by any tool of the repository.
- Continuous integration builds an unsigned package from the signed sources and verifies it with `-DevelopmentMode` (files and signatures; the built folders are assembled on the runner and are not compared with the manifest).

## Attesting the ZIP

`.github/workflows/attest-release.yml` downloads the published ZIP assets of an existing release tag, checks the inventory of the signed manifest against the bytes of the ZIP (without running any of it), checks that the signature blocks are present and that the report page template and its script are complete, and attests the ZIP bytes. Authenticode signatures are validated on Windows, at launch, by the verifier.
