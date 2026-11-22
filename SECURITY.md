# Security

ExchangeLogReport is a personal project, provided "AS-IS" and maintained on a best-effort basis. There is no guaranteed response time, fix time or support period. It is not an official Microsoft product, so no support can be expected from Microsoft.

## Supported versions

Only the [latest release](https://github.com/Nico77600/ExchangeLogReport/releases/latest) is supported: it is the only version that can receive a security fix. Earlier versions are not patched; the release notes of an older version point to the latest one.

A fix always comes as a new version of the whole package. You install it by replacing the package folder with the new release; the tool has no automatic update, by design, because it runs on servers that are often offline.

There is no guaranteed support period. If the project is ever no longer maintained, the README will carry a notice saying so and the final release will state it in its release notes.

## Reporting a vulnerability

Report it privately: open this repository's Security tab, then Report a vulnerability ([direct link](https://github.com/Nico77600/ExchangeLogReport/security/advisories/new)). This is the only channel for a vulnerability. Do not open a public issue, a pull request or a discussion about it, and do not publish credentials, personal data, customer configuration, or sensitive exploit details anywhere.

Include:

- the affected version, and the Windows and Exchange Server versions where you saw it;
- the expected and the observed behavior, and the impact you see;
- minimal reproduction steps, with sensitive values removed;
- whether you want to be credited, and under which name.

If a credential has been exposed, revoke or rotate it immediately; deleting a commit or file is not sufficient.

## What happens next

The steps below are the order of the work, not a schedule.

1. The report is acknowledged.
2. It is triaged in private: the maintainer confirms the problem, the affected versions and the severity.
3. The fix is written in a private fork attached to a draft GitHub security advisory. Nothing about it is public yet.
4. A new version is built and released with the usual code signature and provenance.
5. The GitHub security advisory is published, with a CVE requested through GitHub when the problem warrants one, and the release notes of the new version carry a security note.
6. The reporter is credited in the advisory if they wish.

## Bundled components

The release ZIP is self-contained and carries third-party components: PowerShell with its .NET runtime, SQLite (the command-line tools and the SQLite library), and the Microsoft.Data.Sqlite and SQLitePCLRaw libraries. Each release publishes an SBOM (`ExchangeLogReport-<version>-win-x64.zip.spdx.json`, next to the ZIP) that lists them with their versions and checksums.

- They are watched automatically for new releases and published vulnerabilities.
- When an upstream security fix affects what the tool uses (the local HTTP listener, TLS or SMTP, cryptography, parsing), a new release ships with the updated component.
- Installing it needs no database change and no configuration change, unless the release notes say otherwise: replace the package folder with the new version.

## Staying informed

Customers are told through GitHub only: new releases and published security advisories. Watch this repository on GitHub, then Custom, then Releases and Security alerts, and GitHub sends you a notification for each. There is no other mailing list. To check that a download is the official one before you extract it, follow [Verify the download](https://github.com/Nico77600/ExchangeLogReport/blob/main/package/docs/ExchangeLogReport-Guide.md#53-verify-the-download), which the [README](https://github.com/Nico77600/ExchangeLogReport#readme) links from its first lines.

## Release integrity

Obtain releases from the official Nico77600 repository. Verify available artifact attestations against the expected repository and verify any code signature against the expected publisher.

A checksum alone does not authenticate a file if the checksum and the file can both be replaced. A valid signature or attestation proves integrity or provenance, not the absence of vulnerabilities.

New immutable releases preserve their published assets and associated tag. Existing releases are not made immutable retroactively. Corrections are published as a new version rather than replacing a released file.
