# Third-party components

The folder `lib\sqlite` contains unmodified binaries from nuget.org. Each file is the file of the official package named below, at the exact version, and its SHA-256 is pinned in `product.json` and checked when the package is built. The package check (`PackageIntegrity.psd1`) hashes the same files at every start.

**Why the binaries are committed.** The repository keeps these seven third-party binaries so that a package can be built offline and reproduced from the repository alone, and so that the code analysis compiles the engine against the exact assemblies that ship, without a package restore. What replaces a review of the binaries is control of their origin: every file has its upstream package and its SHA-256 pinned in `product.json`, and the package builder (`tools\Test-SqliteLibraries.ps1`) stops when a file differs from its pin, at every phase of the build. The signed manifest then hashes the same files in the package.

## SQLite libraries (`lib\sqlite`)

| Component | Version | Upstream source | File in the package (file in the NuGet package) | SHA-256 of the file | License |
|---|---|---|---|---|---|
| Microsoft.Data.Sqlite.Core (Microsoft) | 10.0.12 | https://www.nuget.org/api/v2/package/Microsoft.Data.Sqlite.Core/10.0.12 | `Microsoft.Data.Sqlite.dll` (`lib/net8.0/Microsoft.Data.Sqlite.dll`) | `b98d957462be432895b00dccca012d3c127e118d3d4262418014b92c7bbd66cf` | MIT: https://github.com/dotnet/efcore/blob/main/LICENSE.txt |
| SQLitePCLRaw.core (Eric Sink) | 2.1.14 | https://www.nuget.org/api/v2/package/SQLitePCLRaw.core/2.1.14 | `SQLitePCLRaw.core.dll` (`lib/netstandard2.0/SQLitePCLRaw.core.dll`) | `e60e22452ba79c306a59ecc01a97c29bafe69d9fa612f40253852ed450ad27e8` | Apache-2.0: https://github.com/ericsink/SQLitePCL.raw/blob/master/LICENSE.TXT |
| SQLitePCLRaw.provider.e_sqlite3 (Eric Sink) | 2.1.14 | https://www.nuget.org/api/v2/package/SQLitePCLRaw.provider.e_sqlite3/2.1.14 | `SQLitePCLRaw.provider.e_sqlite3.dll` (`lib/netstandard2.0/SQLitePCLRaw.provider.e_sqlite3.dll`) | `35a7fb876526e1f1de65d6fd8938f82dbc8e00efccd0ca58f364c68c26ba08a3` | Apache-2.0 |
| SQLitePCLRaw.bundle_e_sqlite3 (Eric Sink) | 2.1.14 | https://www.nuget.org/api/v2/package/SQLitePCLRaw.bundle_e_sqlite3/2.1.14 | `SQLitePCLRaw.batteries_v2.dll` (`lib/netstandard2.0/SQLitePCLRaw.batteries_v2.dll`) | `29c9cf3060789066682ba5fbf81dea584563e6ab60b5d9861c73ba8b29ed1142` | Apache-2.0 |
| SQLitePCLRaw.lib.e_sqlite3 (Eric Sink), SQLite 3.54.0 | 2.1.14 | https://www.nuget.org/api/v2/package/SQLitePCLRaw.lib.e_sqlite3/2.1.14 | `runtimes\win-x64\e_sqlite3.dll` (`runtimes/win-x64/native/e_sqlite3.dll`) | `b082e8a72ad4ce908234eac970b09b7d328d16157cec34a3ebccfd9dfe2221c6` | Apache-2.0 (packaging); SQLite itself is in the public domain: https://sqlite.org/copyright.html |
| SQLitePCLRaw.lib.e_sqlite3 (Eric Sink), SQLite 3.54.0 | 2.1.14 | the same package | `runtimes\win-arm64\e_sqlite3.dll` (`runtimes/win-arm64/native/e_sqlite3.dll`) | `e3d17b136b58e9e3f768f97ddb406cff3595632126371ad97546be368603bff6` | the same |

SHA-256 of the NuGet packages themselves (the `.nupkg` downloaded from the URL above):

| Package | SHA-256 of the `.nupkg` |
|---|---|
| Microsoft.Data.Sqlite.Core 10.0.12 | `5e8ed353006dadf55d5c7f56d237321c20bb10c786262e6b25526756e1036332` |
| SQLitePCLRaw.core 2.1.14 | `699d899a12951f8a790cff8cfd03bc4bb4ca5b8b069f8fa3ca1e8d6a5c19360b` |
| SQLitePCLRaw.provider.e_sqlite3 2.1.14 | `d870df546696a372330d592e462fa48d81dccd21ba38277495112905f2147869` |
| SQLitePCLRaw.bundle_e_sqlite3 2.1.14 | `68b2e8062a383bdce8a0bccac87d19493d2797fd5f8d2745b464644bbc076a3b` |
| SQLitePCLRaw.lib.e_sqlite3 2.1.14 | `b7e9e18df72c812df2c4769b6ab685de0447f8080f39c5a28ab11145d79a36f0` |

## SQLite command-line tool (`sqlite-tools`)

| Component | Version | Upstream source | File | SHA-256 |
|---|---|---|---|---|
| SQLite command-line shell (Windows x64) | 3.54.1 | https://www.sqlite.org/2026/sqlite-tools-win-x64-3540100.zip | the archive | `fb20997ade5583a5fbf1e36db7bc3c82c9416b3f314f16961e1572aa4e49487d` (SHA3-256 published by sqlite.org: `e171f3993a992edf076746926dd52b5e2ebfabaee38818e74987e1d8112ab987`) |
| | | | `sqlite3.exe`, the only file taken from it | `3627c4ce2632949ee6d795c92e0a33f68fb30235f0a55a7719f0636414d8e1d3` |

SQLite is in the public domain: https://sqlite.org/copyright.html. The tool is used for the read-only measure of `Database-Storage.cmd`; see `sqlite-tools\NOTICE.txt`.
