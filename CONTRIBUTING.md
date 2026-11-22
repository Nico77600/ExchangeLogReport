# Contributing

ExchangeLogReport is a personal project with a single maintainer. The maintainer alone holds write and release access to the repository, and alone builds, signs and publishes the releases. It is provided "AS-IS" and maintained on a best-effort basis, with no guaranteed response time.

## Bug reports and suggestions

They are welcome as [issues](https://github.com/Nico77600/ExchangeLogReport/issues). Use the bug report form, and remove personal data, credentials and customer configuration from anything you paste: issues are public.

## Security reports

Report a vulnerability only through private vulnerability reporting (the Security tab, then Report a vulnerability), never in an issue or a pull request. See [SECURITY.md](SECURITY.md).

## Pull requests

Pull requests are reviewed case by case and are not guaranteed to be merged, or to be answered within any time. Open an issue first for anything larger than a small fix, so that the work is not lost. Keep a pull request to one change, add or update the tests that cover it, and run the existing tests (`tests` folder, Pester) before you submit it.

Every commit of a pull request must carry a `Signed-off-by` line, which certifies that you have the right to submit the code under the project's [MIT license](LICENSE), as the [Developer Certificate of Origin](https://developercertificate.org/) (version 1.1) states. Git adds it with `git commit -s`:

```text
Signed-off-by: Your Name <you@example.com>
```

A pull request that changes the signed package files cannot be merged as it is: the maintainer re-signs them when preparing a release.
