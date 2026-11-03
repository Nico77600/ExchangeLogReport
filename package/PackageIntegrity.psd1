@{
    SchemaVersion = 1
    Algorithm = 'SHA256'
    SignerThumbprint = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
    Version = '3.0.0'
    Files = @(
        @{ Path = 'CHANGELOG.md'; Sha256 = '990D966356329DFE71772D47FFDAC4B478A2B640199B9169ACFDFE6AA11EFD6B' }
        @{ Path = 'Database-Storage.cmd'; Sha256 = '23967707355C2AAB724B5CCA3F119A8B4E2C413CF4C59CF1CFF39350200F7E6B' }
        @{ Path = 'Database-Storage.ps1'; Sha256 = '920212C7FFDB47CD86DDAFF71B9DC75D511917E30A5118F0B3E5DA2108AE45C3' }
        @{ Path = 'docs\ExchangeLogReport-Guide.html'; Sha256 = '5E984EB6D5752D47033D74A54E068926DE3D7E2CDA88AF0FB23A8103EF2E1BB8' }
        @{ Path = 'docs\ExchangeLogReport-UserGuide.html'; Sha256 = '6FF44E25015FD52E6669411E5EDBDE99989D0839C8F40EE6FD647C061B86EC64' }
        @{ Path = 'ExchangeLogReport.psd1'; Sha256 = '7887E0E167D65FADEA1CDAA81F143CE78D68DBA71305F02D66F3F549B67721BD' }
        @{ Path = 'ExchangeLogReport.psm1'; Sha256 = 'EF90C622E8CAFC4E5C6B01FEC4FDBB60D8594FD37FB7B58172463BF0C71761A6' }
        @{ Path = 'Invoke-ExchangeLogReport.ps1'; Sha256 = 'D580D364F42AD92AE95C442EC6370E2285CCBE69D1FC6F7256B3EE81A2183987' }
        @{ Path = 'lib\sqlite\Microsoft.Data.Sqlite.dll'; Sha256 = 'B98D957462BE432895B00DCCCA012D3C127E118D3D4262418014B92C7BBD66CF' }
        @{ Path = 'lib\sqlite\runtimes\win-arm64\e_sqlite3.dll'; Sha256 = '4177542756BD94F75B55FB74367E0CF34E66A88FFAF95755489AF14C6CA2F792' }
        @{ Path = 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll'; Sha256 = 'B7385D722C83FB52142A00477A726723745916D22A555711EE89834C1111FB2E' }
        @{ Path = 'lib\sqlite\SQLitePCLRaw.batteries_v2.dll'; Sha256 = '815CE410C9EAB531DD219318E3BA16C5E38E83D361CFBBDBB4BBCA222C497B0B' }
        @{ Path = 'lib\sqlite\SQLitePCLRaw.core.dll'; Sha256 = 'AF340AC9EB9195795660D7FC1114F486B6AB63998F33176E2F24C8E0ACB9AA84' }
        @{ Path = 'lib\sqlite\SQLitePCLRaw.provider.e_sqlite3.dll'; Sha256 = '0BC1D8536C480C3FE66E8AD6DC796073FBE287961781F73A54AD13E59DF1359A' }
        @{ Path = 'LICENSE'; Sha256 = '58454E0F809A2CCB776B41855D27BA7581AE1AC1289F499341205FF4B829C3F6' }
        @{ Path = 'product.json'; Sha256 = '4DCA1EDD6DF347E5F7387E4399C7B9365DE3521E9B92D10D8BBB22E85B931F8F' }
        @{ Path = 'README.md'; Sha256 = 'B660A75F5574E1AA78350CC767DA07C5F28C418573F609F97009D4612B95EDEB' }
        @{ Path = 'Run-Collector.cmd'; Sha256 = '507B7CE93B3233F5D711395C4FE11901EAE3073AF3C539F3885DCEF2AAD4E85C' }
        @{ Path = 'SECURITY.md'; Sha256 = '7347A3F784AFA259EF610C2DD00305F9A68684DDE1A753B215D33DBE22716BBD' }
        @{ Path = 'sqlite-tools\NOTICE.txt'; Sha256 = 'A708436031BF89DE6A80FE2AE1EC3DB7C01A2A716BC85C474ECD0FAA14488E7E' }
        @{ Path = 'src\Engine.Collector.cs'; Sha256 = 'D73060A351D980A6D70E00F417942D14675C6C0F16B90F9339B3734EF253CF98' }
        @{ Path = 'src\Engine.Mail.cs'; Sha256 = 'A6CB311701256594FC49F9C0686AC763A0432B90893C9D4AB3EC0D9E6EF1FD9D' }
        @{ Path = 'src\Engine.Pipeline.cs'; Sha256 = '649E7941909CA65780A35A5EB2436B9299CACD733906C5035B4805528D1547F8' }
        @{ Path = 'src\Engine.Report.cs'; Sha256 = '3A8F14D255EC22FC460F5F515C201B77682CC301EC41654FB9DDF5FBD8CD83A7' }
        @{ Path = 'src\Engine.ReportExecution.cs'; Sha256 = 'DA7F8CC62D4467DB938C365851B33A8E5E9E760FA81A714E4415D662F2862181' }
        @{ Path = 'src\Engine.ReportHtml.cs'; Sha256 = 'DA79D32BAFF2DD68EEBDF449D8B8A28E5F51779640A7F2EEC7A52161422DD158' }
        @{ Path = 'src\Engine.ReportRoute.cs'; Sha256 = '497B22571734EC22352B061E983479F5754C15159E9175BE68553578524AA6FD' }
        @{ Path = 'src\Engine.ReportRows.cs'; Sha256 = '6BA61AB23E98C57BAD855C977CFA7517202E6DF4143880584D08CA77B50F3308' }
        @{ Path = 'src\Engine.ReportSessions.cs'; Sha256 = '5B3C355893EA6EE5C23F76CFD8F1C359D8D07CA3BCC8A750CC5D21819A94759E' }
        @{ Path = 'src\Engine.ReportTranscripts.cs'; Sha256 = 'B5F87D39B2080D25BE6ACB23639204BCAB5A2287B21FCBF8D43A525C8287A57D' }
        @{ Path = 'src\Engine.Serve.cs'; Sha256 = '43B3CD57FEF7BD091D6056BD9A4CD7EBEA86246818459725C960CFCDB87DC9FA' }
        @{ Path = 'src\Engine.ServeAggregates.cs'; Sha256 = 'A63B6EA5F2AD28D97C5A615C33515C8CEDA116E776C42AA7B9EFDC1183A2CA0E' }
        @{ Path = 'src\Engine.ServeDiagnostics.cs'; Sha256 = '0C06A74853572F565852780E8A68C48C028453A5148A0AE81C9A9F2E220C2CFD' }
        @{ Path = 'src\Engine.ServeFilterExpression.cs'; Sha256 = '4F1E469DBE8ED8AA16056EBE052D23FA79A4A668C3E523773EDAC7AA2C245B52' }
        @{ Path = 'src\Engine.ServeQuery.cs'; Sha256 = '4AA618753A462153FC4D8E5763FA018EF6932A4042280F5758AC276850FDD427' }
        @{ Path = 'src\Engine.ServeRollup.cs'; Sha256 = '79FDC340E68C97123C3ADD5BF83AED661E196552C463DA0B21978FF3CFB17003' }
        @{ Path = 'src\Engine.ServeScan.cs'; Sha256 = '1745C0E2FC48F45E2C076FAA1F4DD3DF7FA5A3C3E3AD2E478C4218D422694248' }
        @{ Path = 'src\Engine.ServeUsage.cs'; Sha256 = '465C02848A39886797DDD67CD709986694A18FC9DB8C2AA00E04A82BD4A165EB' }
        @{ Path = 'src\Engine.ServeVerification.cs'; Sha256 = 'FC3E47045CF0F80ECFB071CDC8E80BE85C0773F53929D5467735898C85D4B8E8' }
        @{ Path = 'src\Engine.Sessions.cs'; Sha256 = 'EC3AB383A01847A0C802493ADF4A227FFCBB7E95336B9EA46A95D467179750A9' }
        @{ Path = 'src\Engine.SmtpAuth.cs'; Sha256 = 'EE2400E57D7CEED7DB3B33E0993958258574678712A481CBE969213C028BB09D' }
        @{ Path = 'src\Engine.SmtpClients.cs'; Sha256 = '007BDE84010BF928B3D31DA6A179674A0A8C060C022511BCBB35365D43194A47' }
        @{ Path = 'src\Engine.Store.cs'; Sha256 = 'FAECA3B339AD92EE24C7B249DA84DF74BE9F34458A9246DA6AB55D4876B00903' }
        @{ Path = 'src\Engine.Text.cs'; Sha256 = '65FF3D110AB668DE5C8F85DF88178E47EC3DE11DD2387FE190438D8CCF3518E8' }
        @{ Path = 'src\Get-ExlExchangeSettings.ps1'; Sha256 = 'B2746FC94C5D22DB527FC2BBC435457F12B1822A29EFBCCF2ABE1BAAFE16B1A8' }
        @{ Path = 'src\Storage.Audit.cs'; Sha256 = '8633C0E29E2FAF9012AA8E65BB23149E8085426292CA956166CF62C719AE79B0' }
        @{ Path = 'src\Storage.Cli.cs'; Sha256 = '54E4BD4A7A3B6BD0BD696A090C34DCA70A007BF6DC1D5F2268A217824E8C029E' }
        @{ Path = 'src\Storage.Fingerprint.cs'; Sha256 = 'D8CC02EAE902D8D284815A13628C4FE8E2311B561FCA76E361FE1F988939068E' }
        @{ Path = 'src\Storage.LegacyRollup.cs'; Sha256 = '0E527E177F08D9984D70B3007C1F447CC5D25E950376549887031518FA3BD7FC' }
        @{ Path = 'src\Storage.Maintenance.cs'; Sha256 = '051E22C2127921B123A622C1E14C0F3C37687CD2E3D3241B2C665918C6DBEE93' }
        @{ Path = 'src\Storage.RollupVerification.cs'; Sha256 = '40D42D677655EEE09ACD6601BB943AF1EBB4460E2A527CC7F2069C2DBFE702EC' }
        @{ Path = 'src\Storage.Safety.cs'; Sha256 = '18944F85430A208F2E99B44C52D90D280B0A965D2B97373A7DA47551B0D78EB4' }
        @{ Path = 'src\Test-PackageIntegrity.ps1'; Sha256 = 'D622515605DE578C132AC1C7481E2ABCE0F15444C2DD5E853768249139498C04' }
        @{ Path = 'Start-Portal.cmd'; Sha256 = '4F3062AD8B025DDB983362A5E339C5B6F940C010164A3D6B95A0675735AD5929' }
        @{ Path = 'templates\Report.template.html'; Sha256 = '2E79AA9214C95C88816A4E2D7C8FFFEC8BAA0D4B89E9E45400E845F72967BFE3' }
        @{ Path = 'templates\Report.template.js'; Sha256 = '94AAB2CC40A0F4919886D524681108926CDA2FD990A5FDCD980D13902E80D253' }
        @{ Path = 'THIRD-PARTY-NOTICES.md'; Sha256 = 'E4A7153897836EB23927FABAAF0EFFCC2F5D31B5EBD04AADCCE71B3EA49040A8' }
    )
    DistributionFiles = @(
        @{ Path = 'powershell\Accessibility.dll'; Sha256 = 'C967A6C58C5C17B86800BE225C85C2D3FA11F5430D76D20FC568F09FBE78735A' }
        @{ Path = 'powershell\build.manifest'; Sha256 = '07368749F01394E1FF712194D4732A7691699DA25E17C0EB445688784E605F2E' }
        @{ Path = 'powershell\build.manifest.sig'; Sha256 = '2025D032FBC003EDFBC8B4C39EE57964E9A4BB9CB100346E5CDB8CE224423E5B' }
        @{ Path = 'powershell\clretwrc.dll'; Sha256 = '7D4ABB5DB80CAEB4E6047C19B1BDCF2466B87C8D97D4AF849480320B148073BA' }
        @{ Path = 'powershell\clrgc.dll'; Sha256 = 'DB5638D1C09F53A77EBF67DEA81A53AE5F939E9C194B8AE39AA89B9C200CBEAE' }
        @{ Path = 'powershell\clrgcexp.dll'; Sha256 = 'B5378D5EE01F16CA551583861050BFA4BDD3198F03914675DCDFF869DDA16439' }
        @{ Path = 'powershell\clrjit.dll'; Sha256 = '6B04EA7C74EA203CBBA522684F6673A3368546EFEEBCC1F79B16BDE70D46A38A' }
        @{ Path = 'powershell\coreclr.dll'; Sha256 = 'FEFC3EFC0A96BD40874BB6E91028B9D1A907DB37E1FACF5E337FC63986B7DEA2' }
        @{ Path = 'powershell\createdump.exe'; Sha256 = '0F13DE2C7A1A7CEC67285DB6E03481CE8B8444346D0E6E2F932F355E3AC016BD' }
        @{ Path = 'powershell\D3DCompiler_47_cor3.dll'; Sha256 = '730515903444589D2F229104CEBB74815F7B9171C02E54A766BF191A9D69C911' }
        @{ Path = 'powershell\DirectWriteForwarder.dll'; Sha256 = '9B6C45BD67DF427BFCF2188D2FF681F7DC064655B701B9AE3CC76E322DEB2607' }
        @{ Path = 'powershell\en-US\default.help.txt'; Sha256 = '5AD33AD117ECD78AD5E84AD745E69D45E6A6A10E68A0C7333C2CE95E102FD602' }
        @{ Path = 'powershell\getfilesiginforedist.dll'; Sha256 = '153EEFB2EAFA8B2B909854CC1F941350EFB1170E179A299DE8836B8EC5CE6A7A' }
        @{ Path = 'powershell\getfilesiginforedistwrapper.dll'; Sha256 = 'C750AA720606977A285BAAB504D600197DAFC5ED7D22E0DE57476B869A10184B' }
        @{ Path = 'powershell\hostfxr.dll'; Sha256 = '777E1C2032CF56DD5CAE35B7194BA4CA1E95ADDB1A7316D9CE4E1D8F4648E980' }
        @{ Path = 'powershell\hostpolicy.dll'; Sha256 = '185B3630BAFB120ED9A697D581E9BCCECCA385B2989937CF75BF2DBB0D63C435' }
        @{ Path = 'powershell\Humanizer.dll'; Sha256 = '513F690F1197854750B9B3CCB307E8C65E0F42D5E86B280E1C9E6D4D4C86F52B' }
        @{ Path = 'powershell\Install-PowerShellRemoting.ps1'; Sha256 = '2827ED2F91D293A8305321E7D5B68ABE55043DFFE46F9162D1DF1BBD4895CE15' }
        @{ Path = 'powershell\InstallPSCorePolicyDefinitions.ps1'; Sha256 = '6AB9C7F7357D48564E41DD6A874BADBEC1F36E6B6718520C48ABB41FEF3FA134' }
        @{ Path = 'powershell\Json.More.dll'; Sha256 = 'BF72BAC29B7853037ED5D92379F01CB9EA71B5D3B339B52D45D6AF4F52B3CE87' }
        @{ Path = 'powershell\JsonPointer.Net.dll'; Sha256 = '1C7AFCF205AD97D1AC7F5A862057A9E6832EE4FD160A1773F4ED6DE0D1F9BE18' }
        @{ Path = 'powershell\JsonSchema.Net.dll'; Sha256 = '7CE6F024EA3D79E77F0812461D787EC03709736C501C7EE6D4D730278548C5B2' }
        @{ Path = 'powershell\LICENSE.txt'; Sha256 = '296604F12546653ED97726DC5FC2F3945D4CCA1F07ABD2589F531647177B06FC' }
        @{ Path = 'powershell\Markdig.Signed.dll'; Sha256 = '9AEBE06C0C27A425F02462D00CBEE99A986DD92D9B54E4346BA2BE1057EA13D0' }
        @{ Path = 'powershell\Microsoft.ApplicationInsights.dll'; Sha256 = '3B456881571EEF8367D96C3557BEB0990CBBFF3568A7C8F079C0A7285EC44B81' }
        @{ Path = 'powershell\Microsoft.Bcl.AsyncInterfaces.dll'; Sha256 = '5965D2BC08896A18A70E077D32C56ACF35D870CCFFDDD178ABE4EA56FCF9023B' }
        @{ Path = 'powershell\Microsoft.CodeAnalysis.CSharp.dll'; Sha256 = '9DA18199A80C5892FE84F67F4FCE159A06259EBF9D3B73DF036B28249DBBB31F' }
        @{ Path = 'powershell\Microsoft.CodeAnalysis.dll'; Sha256 = '0C5159274EF1790BEEF54DD796B51933D2B9C05A5568F968ACCF32A3CBF6D0C0' }
        @{ Path = 'powershell\Microsoft.CSharp.dll'; Sha256 = '3AD628A3582D70D277B703E6882D5835D77630C94C5ECF4BB1AA495A9A431DFD' }
        @{ Path = 'powershell\Microsoft.Extensions.ObjectPool.dll'; Sha256 = '441929388AA1A7F94ED88DE4BF31F434B72F78BE29588007AB3A110E7A3BDBE1' }
        @{ Path = 'powershell\Microsoft.Management.Infrastructure.CimCmdlets.dll'; Sha256 = '45392AB7833C1695EF7B317C043CAD62C70534EF6138F315FA2B6D13744D3369' }
        @{ Path = 'powershell\microsoft.management.infrastructure.dll'; Sha256 = '100F3C7B677E2412451737C13198028ABA8FFC45C9F0594F3A3DA4D40AE45D40' }
        @{ Path = 'powershell\microsoft.management.infrastructure.native.dll'; Sha256 = 'B520FAA5A61F3C25001188A4AF2163E330C3CE2F1ECB5F5BE69130803C4F8B35' }
        @{ Path = 'powershell\microsoft.management.infrastructure.native.unmanaged.dll'; Sha256 = '9BEE4E35576355156F00E2E47EF57AA2C8CA64390C112F083A772F2219026293' }
        @{ Path = 'powershell\Microsoft.PowerShell.Commands.Diagnostics.dll'; Sha256 = 'AD4FDEFB2DABEE85417ADA3A4E33B480F9C3353CE910D990D346685F47930939' }
        @{ Path = 'powershell\Microsoft.PowerShell.Commands.Management.dll'; Sha256 = 'A0280E51AA1E3D0198971C6D2118F22DC8ECCCC722533F2AAEE0DC9D32A8C6DB' }
        @{ Path = 'powershell\Microsoft.PowerShell.Commands.Utility.dll'; Sha256 = 'C60425E232E6450F0759C96A0554B862AFB337040DB7F474212829431D080077' }
        @{ Path = 'powershell\Microsoft.PowerShell.ConsoleHost.dll'; Sha256 = '5E45D99784749CE65300CAB5668D662900796531B1E22BD7AAFC9B99E56FB25E' }
        @{ Path = 'powershell\Microsoft.PowerShell.CoreCLR.Eventing.dll'; Sha256 = 'D4638AA2C8C64A639FB8DB4746BE65A18E5DE6FA1F487674F0C60F8CA4C364D5' }
        @{ Path = 'powershell\Microsoft.PowerShell.GraphicalHost.dll'; Sha256 = '9F26DD8CE2EC2A3245147A6D387A09821017909DCA3823AD8D06F892495D9CCD' }
        @{ Path = 'powershell\Microsoft.PowerShell.GraphicalHost.dll.config'; Sha256 = '04EF1B37822130AE6AC35D2CA9CB5224C87FBEB3AD2B0C48F953C87B083CC26C' }
        @{ Path = 'powershell\Microsoft.PowerShell.MarkdownRender.dll'; Sha256 = '44BDEF28BB6D78E09D9C85FCD81749926B77F8F9A7C84171D05789F69BD1753C' }
        @{ Path = 'powershell\Microsoft.PowerShell.SDK.dll'; Sha256 = 'CC9FC70765F6C7E763C23F251F0C12171A946DF81CFF0AFD3E97F94630AF0A2C' }
        @{ Path = 'powershell\Microsoft.PowerShell.Security.dll'; Sha256 = '5F476F29F353ACAAB8C7928D30F90C67D2BE26E667BC8204BC68BC5C3D070D44' }
        @{ Path = 'powershell\Microsoft.VisualBasic.Core.dll'; Sha256 = 'F65112906CDC857FD3A70BA5ED7B11464143929429817B7C8551922CB31D80C3' }
        @{ Path = 'powershell\Microsoft.VisualBasic.dll'; Sha256 = '5DD563A309E00BDDEBAE3730674C1141443EC96885A8F2436EB4F2F8475C2AD1' }
        @{ Path = 'powershell\Microsoft.VisualBasic.Forms.dll'; Sha256 = '0CA9361DDD1F16DC8FEFC32455F71397B44A8069EEC32629FD7EB4B6DE75342D' }
        @{ Path = 'powershell\Microsoft.Win32.Primitives.dll'; Sha256 = 'BC36DEE1318D30232A6E534F84E7395AF92CDAAB81625A6581CFB0408BA467B9' }
        @{ Path = 'powershell\Microsoft.Win32.Registry.AccessControl.dll'; Sha256 = 'A98855B14FF977F7A6E91849A4DCCC3FAE47C44AA6EE61591B3DF219123F6A21' }
        @{ Path = 'powershell\Microsoft.Win32.Registry.dll'; Sha256 = 'E33BDA76513A0071FB2D0DCEECEBF7541100BA95596BD8F30C1B03517596716C' }
        @{ Path = 'powershell\Microsoft.Win32.SystemEvents.dll'; Sha256 = '91A56323D756DB65D850C8C283D3D4F907E23A42E68B9EF4DB6A49CBA92DE2C7' }
        @{ Path = 'powershell\Microsoft.WSMan.Management.dll'; Sha256 = 'CFC3B2D3464629C43B339F10AF4A13208E0DAE22F48CAEA617295A2A16D1CBEB' }
        @{ Path = 'powershell\Microsoft.WSMan.Runtime.dll'; Sha256 = 'D5033DEDBDF8B6E6B3E4FB39E1E45D8D570231D07E46153EE2B9E82534D2E6A3' }
        @{ Path = 'powershell\Modules\CimCmdlets\CimCmdlets.psd1'; Sha256 = 'FE85A8D8AE8F81C076BD9EF21820E4DBE1387B148984707E049F2F22C498F57A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\.signature.p7s'; Sha256 = '1C4EE42E1FA99A2768FA8FEDDAADF70A84F8EA8F273234061A6781D41DA0FAD4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\en-US\ArchiveResources.psd1'; Sha256 = '15C2C0874890E5C715AA513C744CA99803A2629466CBB3C62E41AE3CFC857D66' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psd1'; Sha256 = '95E193E52B66E19C8ACD007AB2958B5020B3FDFF52227162B09C5110F01E2685' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psm1'; Sha256 = '48F095C3A48F95AAB0714C06A6EFDB798C77F957948AAF02CAA16CF50692D2F7' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\Diagnostics.format.ps1xml'; Sha256 = 'CDCAC046F88FE94ACFD74BDE67708BF826526B07F6A286392A28ADAE0B52FFB2' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\Event.format.ps1xml'; Sha256 = 'A059A59CC27A0B17604536FF397CE96098FF19A5370C1CF7C8DD7C2A3CA8D090' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\GetEvent.types.ps1xml'; Sha256 = 'E37051B2591194101269FC5891129E26C398295C95C231D29DB47B8549C1DE84' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\Microsoft.PowerShell.Diagnostics.psd1'; Sha256 = '9FE804C2BA48333DD641ACC1B7CDEF64A2E4BB2341A43B22CC85462542A34889' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Host\Microsoft.PowerShell.Host.psd1'; Sha256 = '5B316D52BADE2DFAA0E7813787654689AA8C7F10083AA5C2BF3375DC872E87D3' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1'; Sha256 = '581C10FCC90901BF4C9364F1DA651E7C76AF55170D896E9BEA8D19A6EA07C993' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\.signature.p7s'; Sha256 = '882CEF83D74AD2226EC51479280913B0B6C919DA35BC7365438D6EC540FB1018' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Azure.Core.dll'; Sha256 = '0C85C8CC3856D5BEB91895D1A8E00F785453F2AA538D85EE9ACE030B537F0FC2' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Azure.Identity.dll'; Sha256 = 'B960AB88C55A7EDF0FF7A659CBC88FDA2DC8219221D46B7FCB92245B8E8EEFB4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Bcl.AsyncInterfaces.dll'; Sha256 = 'FD587EF95461251B8D4B3D493D77102120622B1FD32B87BB98E032E1365480A1' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Extensions.FileProviders.Abstractions.dll'; Sha256 = 'FA1FECF3C081A0EF366100169CD539AD03EE10CD18BCF89DE56E9CB8D3659D4F' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Extensions.FileSystemGlobbing.dll'; Sha256 = '152BEBA2D6F82210F17696B2BE9498ADC9C38D32B9E2FD03BA87810B838F811D' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Extensions.Primitives.dll'; Sha256 = '7C6BC24A7D6A1C3C1FB4FC521174CF43E931A19F8BB88754FB738A6402848E20' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Identity.Client.dll'; Sha256 = '924340C47CBC74B1B811059860DEFA3B136500BB97EF8B6DB95631F2391741D0' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Identity.Client.Extensions.Msal.dll'; Sha256 = 'B084586684B03456481A6AA0AC0B149F87EBBC6FB01735D8005F987031BD0343' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.IdentityModel.Abstractions.dll'; Sha256 = '7A77F7894D7F925C2E806737B8F4F036CD0D8B7E7843F824BA1139C10A0B3E25' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Newtonsoft.Json.dll'; Sha256 = '014709CB7419FF17D89B627EABA751B3018EEEF3BC71305680BB23600EC219C6' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Commands.dll'; Sha256 = '762988B531247A8AC282B85E0BC81004FA9D02B9118A24C3B18B3A97F1DADE48' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Common.dll'; Sha256 = 'E8932AC0C5D7E306551BC4B585F582BAEF7651F21C88D4976445C0BFDF29F227' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Configuration.dll'; Sha256 = '0BB37C45575CBCCCC279A4250FB7F0D87DE5C0A3DDC16565542A6ED0E5682C6B' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Credentials.dll'; Sha256 = 'E5F44DDC086A8F40989C70460E22E25095D75AC402FAF6FF436E6A08C9CEC71F' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.DependencyResolver.Core.dll'; Sha256 = '077951FEA107ED42180AA5EAAA0BE047070A0EFF32A62999A8280535CB5D4F3D' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Frameworks.dll'; Sha256 = 'C79E07959989FE7E99F31171EF712F9665474E652B4C16BC729160114697F8D4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.LibraryModel.dll'; Sha256 = 'EAF71D1D5DD771DAC1510C8779C2FDC98D539C8C07934EE114679D453FA60C21' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Packaging.dll'; Sha256 = '877E82582D7802ACA0B2FD53D34175B42D01BCF713A77D6D0A9E8A73C47EE2A4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.ProjectModel.dll'; Sha256 = '275A531DE109D62F71D745DB656D295511DD53CF0FD141CC0153AD357BFC8163' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Protocol.dll'; Sha256 = 'AB3FCF87ABA83AC429FB040D5C36A4B7E9AF334C923F8F27041C93046D2AF9CB' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\NuGet.Versioning.dll'; Sha256 = '77B3FAD9D3D369538F765035DD142D3D91785CE1308C40C5CA13BF84C9E78ECD' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Buffers.dll'; Sha256 = '1F070094B2200F161643DA3398F491676098471DF25D99403A8924C66F5FD632' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Diagnostics.DiagnosticSource.dll'; Sha256 = '1887592615FC08BBC91AD62307C8C11DFC14C45BF120D271D66BE4A0D1A149A7' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.IO.FileSystem.AccessControl.dll'; Sha256 = 'E6026501AD4056FF2F1655B0AFDFE8923BC6E8FBAD67E1E9EF56E3002F49FBB9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Memory.Data.dll'; Sha256 = '6CF06482F4FD82AF659C2EB4B7BDEAE51EC171AB1CA3B3CBF0328C6A4B882242' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Memory.dll'; Sha256 = 'DF841149E39CDDB2DE569CC72D606064F18B1C5A396CAA85E470E198ABA90031' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Numerics.Vectors.dll'; Sha256 = 'E5B1E3DEFA97A3AA29CC20BE0C9D525C86BB9C716F3B85F9A82CE1F30FF6310E' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Runtime.CompilerServices.Unsafe.dll'; Sha256 = 'F3B91791E4DAA53C929AED083C996ACF924C1F955F34AC824037B33912C3AAB9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Security.AccessControl.dll'; Sha256 = '1FDA491EEBDB19EA0A83CF6C16AB5DD004A1BFDFC845EDE017EBE0945BEB927F' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Security.Cryptography.ProtectedData.dll'; Sha256 = 'A79AD1E9E7205BD790F40D6C1900BAF1A9C8CAA06089878D24ED3599AC3228A9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Security.Principal.Windows.dll'; Sha256 = 'B4D8E15ADC235D0E858E39B5133E5D00A4BAA8C94F4F39E3B5E791B0F9C0C806' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Text.Encodings.Web.dll'; Sha256 = '37790AE5BC588DC2D4904DB656DD8E9B0155B802169F240762F9794458557024' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Text.Json.dll'; Sha256 = '0CF5A9763C98F09E94DFCDAA4437E9508EABE2E50B408BA421D5FAF734C5556A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Threading.Tasks.Extensions.dll'; Sha256 = '4F81FFD0DC7204DB75AFC35EA4291769B07C440592F28894260EEA76626A23C6' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.ValueTuple.dll'; Sha256 = 'E905D102585B22C6DF04F219AF5CBDBFA7BC165979E9788B62DF6DCC165E10F4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\InstallPSResourceGetPolicyDefinitions.ps1'; Sha256 = '7429201A7A4BE49FEB0456DEDBD47E9E753DDA4EE871A8E6B977A0917F96745D' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\LICENSE'; Sha256 = 'BE5723395260D4F07283D596F4B375810EB695653D48D52A5062C0F7070573A3' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Microsoft.PowerShell.PSResourceGet.dll'; Sha256 = 'C9ECCB0E5313CED30E7DA3903C27F1A97C6E8B0793A0A91160C4BEE346F3EE02' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Microsoft.PowerShell.PSResourceGet.psd1'; Sha256 = '13A0C3EA11F35E08DD1EE06A15EE9EE793062752EF5DA63B43E7C4BC64976328' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Microsoft.PowerShell.PSResourceGet.psm1'; Sha256 = '303A5B8DD3749DA6A7530E2F040DDC1ECFCCA280120DCEDA473EBB2285661CE8' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Notice.txt'; Sha256 = 'CB3714C1F7FC609FEE9264C5F7E87DF89121D09242A4DCCEFE4815E9D784AA65' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\PSGet.Format.ps1xml'; Sha256 = '097FE2BBE4C6BC7829C64114E46E51479574B5B9E4B2F84D148F29B2FAE0BE9A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\PSResourceRepository.adml'; Sha256 = '1C8163F8163797C4B91466A94207E356256B8F770A0C591C68CD1FADD015A79A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\PSResourceRepository.admx'; Sha256 = '37BCB0428C05343483E7B5AA2F76AD3F804BA87830526EC42E8F8A91736D4AA9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'; Sha256 = '30DDEB62F819FF81D4BA1AB6516B28C07E8A79960AD2C4A4166545EAA06D49DA' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Security\Security.types.ps1xml'; Sha256 = 'AB2656D172907323D48F6023296F1AE658E816425F0E1A71120840ABA9366034' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\.signature.p7s'; Sha256 = '3DB2F058A8F27F3E7BE0E22E8258944F9A6412A379DFFC66F99F3E592899DEC4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\en-us\Microsoft.PowerShell.ThreadJob.dll-Help.xml'; Sha256 = '6E5AA422BFDE0133D9FC12CAB32C404557CA7CDDDA1FF888BF69395595928003' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\LICENSE'; Sha256 = '296604F12546653ED97726DC5FC2F3945D4CCA1F07ABD2589F531647177B06FC' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\Microsoft.PowerShell.ThreadJob.dll'; Sha256 = 'F89AB468EC1329474288FB0FAAD81600005BE3DA88DC2B8A2631CFBDD64F394A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\Microsoft.PowerShell.ThreadJob.psd1'; Sha256 = '4E9CB7A6D8A94560F0025B807162BAAA9C4A6AF4254D3FA7E71B23E0DCC1FB25' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\ThirdPartyNotices.txt'; Sha256 = '296FF3E4A93BC8C20CA5C20D0E1A70B8C4622FADF0351A37845A63ED52585279' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'; Sha256 = 'C8EA25B1A69CF55C1A463F08D0E93189EAB8F1126EDA46B2C4DD9F3A9BC35998' }
        @{ Path = 'powershell\Modules\Microsoft.WSMan.Management\Microsoft.WSMan.Management.psd1'; Sha256 = '1AB9ACDC4CCBDC73E9AD437B2481E9042D35888910C30D7927CC26BF6D257762' }
        @{ Path = 'powershell\Modules\Microsoft.WSMan.Management\WSMan.format.ps1xml'; Sha256 = '993D864D8A54CE87D39FDA5E591A2FA6ECED452FBF2D04E12BB77508835AD32C' }
        @{ Path = 'powershell\Modules\PackageManagement\coreclr\netstandard2.0\Microsoft.PackageManagement.ArchiverProviders.dll'; Sha256 = '5A140EB9BFB2EBB42F02E75DA9A408A86BA6034EAA27AC57A10A534011EFD509' }
        @{ Path = 'powershell\Modules\PackageManagement\coreclr\netstandard2.0\Microsoft.PackageManagement.CoreProviders.dll'; Sha256 = '50CB7269866EC2E3663221662FD1649A0C1B2736525D65231E29B39B25BB2467' }
        @{ Path = 'powershell\Modules\PackageManagement\coreclr\netstandard2.0\Microsoft.PackageManagement.dll'; Sha256 = '23689DD357312F0924305C612AA41BE0BD592AD9712FED70A3DA72A9C40EB712' }
        @{ Path = 'powershell\Modules\PackageManagement\coreclr\netstandard2.0\Microsoft.PackageManagement.MetaProvider.PowerShell.dll'; Sha256 = '8F5BFD7FFFFE4930AD035194447B8FB24257C8C799302F04879CD5D5211A38C6' }
        @{ Path = 'powershell\Modules\PackageManagement\coreclr\netstandard2.0\Microsoft.PackageManagement.NuGetProvider.dll'; Sha256 = 'C0579B5BCA0ADFE99DC17C253F4F00D669AD008A60854D2508BF6D79A886B4B2' }
        @{ Path = 'powershell\Modules\PackageManagement\coreclr\netstandard2.0\Microsoft.PowerShell.PackageManagement.dll'; Sha256 = '10D3F4E3AA47CFC3AAC0E94C3B20000EA73CB0062E5037A79FCBE932112EB0A1' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\MSFT_PackageManagement\MSFT_PackageManagement.psm1'; Sha256 = 'B7CD11228923E8747B04AE8A03F246F1490B4D51C8A54B41D26CCB20164FE558' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\MSFT_PackageManagement\MSFT_PackageManagement.schema.mof'; Sha256 = '8D9E6819AF5265B47DC514F82EEEF657449C2F3DC72CE4F4F8531FC2FCCDECF0' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\MSFT_PackageManagement\MSFT_PackageManagement.strings.psd1'; Sha256 = '50EE9087694A8325E0BC6FF4E5AE008984D46FF84CB9BCC6ED655CFF1A8547A3' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\MSFT_PackageManagementSource\MSFT_PackageManagementSource.psm1'; Sha256 = '56BD33242E6D59F02514EB3B902F65B83A3EA8EA7E44099F57892AB640823C25' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\MSFT_PackageManagementSource\MSFT_PackageManagementSource.schema.mof'; Sha256 = 'ACD658401A6A84F29E091F6549F4AD6BC6E16B71005F542E4BE558C40B50EAFA' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\MSFT_PackageManagementSource\MSFT_PackageManagementSource.strings.psd1'; Sha256 = 'AB2DD00EE1AB028EF4C506CAC98E5407FB866DA40720C232A3426ADBB57EA67A' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\PackageManagementDscUtilities.psm1'; Sha256 = 'CA8EA0F3E2208FDEDD51C2F282EA9E9A50BE7D8A38C56EEF0141191F7E484776' }
        @{ Path = 'powershell\Modules\PackageManagement\DSCResources\PackageManagementDscUtilities.strings.psd1'; Sha256 = '24E1182E6F6E3EDDF2528EC6D335E0D584CE37995B0D849B5DD5F5EE75A558BB' }
        @{ Path = 'powershell\Modules\PackageManagement\PackageManagement.format.ps1xml'; Sha256 = '6CC6DA35A87357E213FA7A2CD0FAF9B1DB1BB83BDAAF9F73C952FE9AD2BB4596' }
        @{ Path = 'powershell\Modules\PackageManagement\PackageManagement.psd1'; Sha256 = 'EC633E756164C26D1154FAB722648E2737F3650399856D29C089F0C25B190D33' }
        @{ Path = 'powershell\Modules\PackageManagement\PackageManagement.psm1'; Sha256 = 'D484E31593FE26C8E670F8A0D72D4400A3E8EB75F587DF4B11554B8C000E128A' }
        @{ Path = 'powershell\Modules\PackageManagement\PackageManagement.Resources.psd1'; Sha256 = '734BFFF81999A08B4145399A6284B00E46F070A7038BB4C82AB79165FF15F543' }
        @{ Path = 'powershell\Modules\PackageManagement\PackageProviderFunctions.psm1'; Sha256 = '481FDED09BF8A376EC4BD53CF34C0D66C8D8B1D31AB2012A768227F92B099156' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSModule\en-US\MSFT_PSModule.strings.psd1'; Sha256 = '4081ABD182F805AB3B9705279478A2A8AF17A0E43F07887E3C68962BCD09C9E8' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSModule\MSFT_PSModule.psm1'; Sha256 = '6C724F3B86D5D5233C2906FE41206D6EB2279B6D053164F51AAF83B4891619EB' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSModule\MSFT_PSModule.schema.mfl'; Sha256 = 'CF126CC6FD7AFAEC54F07942F346F379725795625B80EC5FC32F547AB7B49BFC' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSModule\MSFT_PSModule.schema.mof'; Sha256 = '2107051FAB99F1E8545CC30F72FB089899B19A5BD4D33A6891FBF0DF794F573A' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSRepository\en-US\MSFT_PSRepository.strings.psd1'; Sha256 = '7520000BE81F281384AF99B787A4629E55269EF73D8FA162CF29390DC273A017' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSRepository\MSFT_PSRepository.psm1'; Sha256 = '627EDB8150EC8C52B33E363652D27E4FD71C1374D03C5B56D98AF244D3C1CC10' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSRepository\MSFT_PSRepository.schema.mfl'; Sha256 = 'B9F9A62A3D2D0497BF81CC69A456B9E0BDBF9D1F34909A0283F088940EFFFC34' }
        @{ Path = 'powershell\Modules\PowerShellGet\DscResources\MSFT_PSRepository\MSFT_PSRepository.schema.mof'; Sha256 = '6AA312F0A73494723FE4CAA98BD74CCF3724226BEE4BFE4EC0A7229BFAD7141C' }
        @{ Path = 'powershell\Modules\PowerShellGet\en-US\PSGet.Resource.psd1'; Sha256 = 'B5C9DA477EF0F8662708AC1A755C0B2611800805ABA861663ABB421E0C5F7CA4' }
        @{ Path = 'powershell\Modules\PowerShellGet\Modules\PowerShellGet.LocalizationHelper\PowerShellGet.LocalizationHelper.psm1'; Sha256 = '14A35134461ABCFAA7DFE393C7B3A16605032719F5EA0EE062B4655A181C0C76' }
        @{ Path = 'powershell\Modules\PowerShellGet\Modules\PowerShellGet.ResourceHelper\en-US\PowerShellGet.ResourceHelper.strings.psd1'; Sha256 = '1302F09514E514B4A2C5A2F8D4DFCFC5087070E211357319FB516E27994C88B0' }
        @{ Path = 'powershell\Modules\PowerShellGet\Modules\PowerShellGet.ResourceHelper\PowerShellGet.ResourceHelper.psm1'; Sha256 = '640240A2632C22E75AE372414BEE7136C2ADC932F92A0F656C436BE616B19CDA' }
        @{ Path = 'powershell\Modules\PowerShellGet\PowerShellGet.psd1'; Sha256 = 'B1315712ADE77AF6C5115D8C9AE2F9A5D8CCBFA5E9A5F00C19AB283A52057F2B' }
        @{ Path = 'powershell\Modules\PowerShellGet\PSGet.Format.ps1xml'; Sha256 = '4F12DD41E0FAB7B1A97AE83A84BDDB567CE9876F9E6C3496D833CFBB8E52BD7F' }
        @{ Path = 'powershell\Modules\PowerShellGet\PSGet.Resource.psd1'; Sha256 = 'B5C9DA477EF0F8662708AC1A755C0B2611800805ABA861663ABB421E0C5F7CA4' }
        @{ Path = 'powershell\Modules\PowerShellGet\PSModule.psm1'; Sha256 = '573D4A3861CB967E52EAF6155A41F930FCD4168368A6946F65D985F30DC357EC' }
        @{ Path = 'powershell\Modules\PSDiagnostics\PSDiagnostics.psd1'; Sha256 = '631297EBC545B82126156DD244B714F41DDF0B8EE3502E4CFA2042B8D8EF3CC6' }
        @{ Path = 'powershell\Modules\PSDiagnostics\PSDiagnostics.psm1'; Sha256 = 'B8C309F83137F71F6656D46241A54D492FC2FDAB38B74B2F894BB6BB97482E03' }
        @{ Path = 'powershell\Modules\PSReadLine\.signature.p7s'; Sha256 = 'ECDF2C3BC44D32AF003FD81BEF96E83F19D7EFC9658C07F7D78687F105F721A4' }
        @{ Path = 'powershell\Modules\PSReadLine\Changes.txt'; Sha256 = 'E18C4D35A40A544877378B36B7D86B5C79DAED0C6E7A55C3027C4F0F998426C0' }
        @{ Path = 'powershell\Modules\PSReadLine\License.txt'; Sha256 = '25C2FDFCDC653F65629233F5EF217A83287733D3C0299C207B0BCA865508C463' }
        @{ Path = 'powershell\Modules\PSReadLine\Microsoft.PowerShell.Pager.dll'; Sha256 = '451994C3D3E38D939B4FA5F8594D0207840F45E7A210AA75F81AEF85AA17C592' }
        @{ Path = 'powershell\Modules\PSReadLine\Microsoft.PowerShell.PSReadLine.dll'; Sha256 = 'F8E3A5B7E3E8CAD2130CE10647564A2A0EA15D98DB8A0CC8D589F80154C108E2' }
        @{ Path = 'powershell\Modules\PSReadLine\net6plus\Microsoft.PowerShell.PSReadLine.Polyfiller.dll'; Sha256 = '6D33EA289B405C64BF5DAA9C59E459596CAC59ECE399D0D215EE9F3D46AFD675' }
        @{ Path = 'powershell\Modules\PSReadLine\netstd\Microsoft.PowerShell.PSReadLine.Polyfiller.dll'; Sha256 = '2E63DC86D9240243CCFB07DA5D0B4FCE2BC5CE5F9952658A7CE68C26BCD3E14C' }
        @{ Path = 'powershell\Modules\PSReadLine\PSReadLine.format.ps1xml'; Sha256 = '1CA887463598D38AA18236A97A4193B2228D1D8434FA73CC8C7932F42A0565CF' }
        @{ Path = 'powershell\Modules\PSReadLine\PSReadLine.psd1'; Sha256 = 'DD8766BD4DB0C1D17111B81D145D32448F61F48451D51C780A79BE9CA98D837E' }
        @{ Path = 'powershell\Modules\PSReadLine\PSReadLine.psm1'; Sha256 = '9BC0252F616067CA5EF1D0328EC0B97C7D31C757F9FC80ADEE234EA6132A9C7E' }
        @{ Path = 'powershell\Modules\PSReadLine\SamplePSReadLineProfile.ps1'; Sha256 = '53B518B3D72AFEB6C8A3F4ABF079C93CEBAF7100A12C93668B83A4D4BCD45795' }
        @{ Path = 'powershell\mscordaccore_amd64_amd64_10.0.1326.46716.dll'; Sha256 = '6EF93F24AAF71C9D6E864CE5D92CD40DBFA8C418AD9A91DB13C5664090BFD21E' }
        @{ Path = 'powershell\mscordaccore.dll'; Sha256 = '6EF93F24AAF71C9D6E864CE5D92CD40DBFA8C418AD9A91DB13C5664090BFD21E' }
        @{ Path = 'powershell\mscordbi.dll'; Sha256 = '7BB48BF554B57DEC0B7C72FD6CBC1DADAC990A3F17033E938D24D14AC4E55F8B' }
        @{ Path = 'powershell\mscorlib.dll'; Sha256 = 'A3F37AF2963A3C7BA6306100226EB64D17EA9D6ADCE18A438BF91269DCDDA824' }
        @{ Path = 'powershell\mscorrc.dll'; Sha256 = '7379263F06B1AF66C421123A363CAB696CD3869CC0217BC568578460B2F2651E' }
        @{ Path = 'powershell\msquic.dll'; Sha256 = '1BD135FCDC91B16BB9736B0E56FB37224C730E655FF8E0963F870A6AE86AFF39' }
        @{ Path = 'powershell\netstandard.dll'; Sha256 = '180C044DB8E4E32A6751AFC211DDF0194F8264B503C30CD0460780805E9072A6' }
        @{ Path = 'powershell\Newtonsoft.Json.dll'; Sha256 = '570BCB67920BF95ED9A184189B9FC42CA94131B1CB49E7F147E65586DBD1ED78' }
        @{ Path = 'powershell\PenImc_cor3.dll'; Sha256 = '98F2EB96F1C5FDB426EE6A3027A4A6B82A10D748170CBCAB6271B7B9B9E7F43C' }
        @{ Path = 'powershell\powershell.config.json'; Sha256 = '98C0E5B6EE17EB8B8F4E4940C2B2528689CEC8470DB4BDE427AD16D90D6A52D4' }
        @{ Path = 'powershell\PowerShell.Core.Instrumentation.dll'; Sha256 = '3D341B3E9C71A4A843EDA0FE0D0D1B5B604F4BEABD64AC4E57C5B5D313C4428C' }
        @{ Path = 'powershell\PowerShell.Core.Instrumentation.man'; Sha256 = '8B2585E50EDE697905DFDB8E3878DA2AB42039135BA23E377207CC8D96E8125F' }
        @{ Path = 'powershell\PowerShellCoreExecutionPolicy.adml'; Sha256 = '2B8C4B7D5BD585431FBF918F223A9B932D80EB9703A1976A1CE3492D4DD26966' }
        @{ Path = 'powershell\PowerShellCoreExecutionPolicy.admx'; Sha256 = 'EE8EB99C1E66009D95AF46E4F6C8F5C13563C9A0AD827E631149176A1B8D34D2' }
        @{ Path = 'powershell\PresentationCore.dll'; Sha256 = 'AD3B02E9B1740A573057E106F6D1BFD3728FE05B1ACE2DDED90AD8ED025ED054' }
        @{ Path = 'powershell\PresentationFramework-SystemCore.dll'; Sha256 = 'C276D859DBE680C340E6657D2D90DB3591B74D244D5F3EB016DDB48F070D9079' }
        @{ Path = 'powershell\PresentationFramework-SystemData.dll'; Sha256 = 'CEBC346CF77DF00C0763BC745AB4A930B120D1F6B1E2C42E965CF6342AB0FF00' }
        @{ Path = 'powershell\PresentationFramework-SystemDrawing.dll'; Sha256 = '760BF70759CBD019861D084400CE4C2FCD6F96DC3B8B18F8732808151F4DD9D4' }
        @{ Path = 'powershell\PresentationFramework-SystemXml.dll'; Sha256 = '03D0B9BD1CD7A671A449B8D66277A1B84936A181ACCEA290290FAD12057DAB47' }
        @{ Path = 'powershell\PresentationFramework-SystemXmlLinq.dll'; Sha256 = '6345C4A8E6BD93146529BA7C6E81BE3BCD56BAF147F75503E07A58F1631C110D' }
        @{ Path = 'powershell\PresentationFramework.Aero.dll'; Sha256 = 'AACA6F544DF2B31D26543BA57EB37DFC0657D57667E438A13DE1E49D1EAD3473' }
        @{ Path = 'powershell\PresentationFramework.Aero2.dll'; Sha256 = '63C75866F496795C362AC95C1AE8A5A65D2F056C302A1B3BFB2A3103D0688AA6' }
        @{ Path = 'powershell\PresentationFramework.AeroLite.dll'; Sha256 = '86BC3EE37644934881452A30BF20D341FEF8FFA4C5B8D9931B421680B85D4498' }
        @{ Path = 'powershell\PresentationFramework.Classic.dll'; Sha256 = '4743EC56C5AC8C409AC865753BC3C2A4402A0F1B357DDD9D547CC0290A82C1A3' }
        @{ Path = 'powershell\PresentationFramework.dll'; Sha256 = '9259AB8374689B7B71E1005CC6D01D9BC5369339CA92BF6E2B426CABFCBD5196' }
        @{ Path = 'powershell\PresentationFramework.Fluent.dll'; Sha256 = '324FB3E7E9C77560ADF36E2F9218A479FBBCA5C1A44B105112E2962F8DA79A04' }
        @{ Path = 'powershell\PresentationFramework.Luna.dll'; Sha256 = '01357EB01DE30F2069B8C9D9F84B4C4A0CDC7F0705F207C81C635BCE8DD72592' }
        @{ Path = 'powershell\PresentationFramework.Royale.dll'; Sha256 = '83A52D74CDE7A03C9598A7F96B0DCEF46F2BEC229878FF004E196D0BC444721C' }
        @{ Path = 'powershell\PresentationNative_cor3.dll'; Sha256 = '091609705A031D5832F21548291C2670F06EADD781D465D3E1A5FAD3772ADC91' }
        @{ Path = 'powershell\PresentationUI.dll'; Sha256 = 'F85330C08A2459AB88DCF7A8E0D1E408659FFF44993B28B48A299244A2E0D4AC' }
        @{ Path = 'powershell\preview\pwsh-preview.cmd'; Sha256 = '7A24CB96B62009CFFB38C85B6ACBF48A5DB5746459B85FF3E727BD952FFD8832' }
        @{ Path = 'powershell\pwrshplugin.dll'; Sha256 = 'AB16ACC15BFE2EDC54793CF363DAA7C786317B592DCF8DEE33E1D433D8A254A5' }
        @{ Path = 'powershell\pwsh.deps.json'; Sha256 = 'A01883AEEB2217AEB1D7EC944D649376104E7A874CA4EA71E7F36448C1519DC2' }
        @{ Path = 'powershell\pwsh.dll'; Sha256 = 'A583A3721FEEBC4F9552A02358BC81BBDD41E2E18BB3F424226F2B1E0BF07DEB' }
        @{ Path = 'powershell\pwsh.exe'; Sha256 = 'FA2C8BB1E35CDD62AD15CD06A1D8F2C5961E9725A9BFA1E7CFD2C322F49E9619' }
        @{ Path = 'powershell\pwsh.profile.dsc.resource.json'; Sha256 = '378030311FCDD7A8D6C401142275BAEB6C031307EC2E12F51399B84851906380' }
        @{ Path = 'powershell\pwsh.profile.resource.ps1'; Sha256 = '89FC3BD3E985D88A81B973487FF4AE4CC16F15DEC73F1847B93025BF9477FA7F' }
        @{ Path = 'powershell\pwsh.runtimeconfig.json'; Sha256 = '8A6363FBA1F89C0688E3594EF4FE7B9036126F04957C5FE56858CBA020B76B33' }
        @{ Path = 'powershell\ReachFramework.dll'; Sha256 = '8C1F3532424C1CD1075B2FD48392EC3D5774D61AF922061F4BE5481696B86194' }
        @{ Path = 'powershell\ref\Microsoft.CSharp.dll'; Sha256 = 'FB50E93C2A4A22AA948034A35E574327FC3296085F7AB0082A691A146B5F18B3' }
        @{ Path = 'powershell\ref\Microsoft.VisualBasic.Core.dll'; Sha256 = '51D9BFB8E6BF011A67C053E6D2D52D2D5E35F4C4740BF18DBC870709B1A5C8C3' }
        @{ Path = 'powershell\ref\Microsoft.VisualBasic.dll'; Sha256 = '10D93E64FCED1CD163D2CEA75575D23F4FA98550D1B8A67FFD80780C12FA08D8' }
        @{ Path = 'powershell\ref\Microsoft.Win32.Primitives.dll'; Sha256 = '2AA6F59C6CD3355ED23F86C5B021BE30DAC267244B24FBA2F8B9DBF31D3EF854' }
        @{ Path = 'powershell\ref\Microsoft.Win32.Registry.dll'; Sha256 = '8BC6205FBB158740ED77842798EE377724EDF802B83465353F895958A97A15D1' }
        @{ Path = 'powershell\ref\mscorlib.dll'; Sha256 = '6BE747F707F2CE0D6C70D8304794ED0107DEB2B1D362BDDD9D1A4938809506C0' }
        @{ Path = 'powershell\ref\netstandard.dll'; Sha256 = '4F517955D84669B6C02C83FA5E20E5F9C80D58A0AA1F16967AF45DB5CCAFBFDB' }
        @{ Path = 'powershell\ref\System.AppContext.dll'; Sha256 = '614F3BC1601CF115E6CE5C4FB451EB3B1895EABB8D40702BDAF206F52F767559' }
        @{ Path = 'powershell\ref\System.Buffers.dll'; Sha256 = 'EA79E667C14C6A9B8D3C2945C81F5589CFDEB444492787100F99CD74ABE85FA9' }
        @{ Path = 'powershell\ref\System.Collections.Concurrent.dll'; Sha256 = '5ECAA05A00F033C5606308FE84A11975F91FFBCD2E5EEBF7338EDF9344E038B8' }
        @{ Path = 'powershell\ref\System.Collections.dll'; Sha256 = 'EDE750091091FF37BC319800D439706823E2E0C256DD3336445A17C662A0143D' }
        @{ Path = 'powershell\ref\System.Collections.Immutable.dll'; Sha256 = '5A0DCB7A520F1021A0C3CAE2A393A834F079F251392CF038336D1616423E5FFD' }
        @{ Path = 'powershell\ref\System.Collections.NonGeneric.dll'; Sha256 = '20C8BCCB7200DE45E94637283A8779675B581D5ADF9FF810110F3DF26CA9A67C' }
        @{ Path = 'powershell\ref\System.Collections.Specialized.dll'; Sha256 = '208724511E772EB93C78AF454E1100547787963C701E5E557183886C8778E0C7' }
        @{ Path = 'powershell\ref\System.ComponentModel.Annotations.dll'; Sha256 = '376208941A5BC6FFF13789C04F04C4D9A31497ADCD7EE9375BBBCBB3DB078A6B' }
        @{ Path = 'powershell\ref\System.ComponentModel.DataAnnotations.dll'; Sha256 = '6C90452506439BA7587AFEB2C648EEEC5B80C131E16C2F5B2C70A18C3E2BAE12' }
        @{ Path = 'powershell\ref\System.ComponentModel.dll'; Sha256 = '0F2A7F4293930013E2A5C896A89B851DC3A41B5AB81A9D83803BE29730A340D7' }
        @{ Path = 'powershell\ref\System.ComponentModel.EventBasedAsync.dll'; Sha256 = '945ADB7C415C7750D19206D20DE8E929F0329C1C2E20252B1245335C78090975' }
        @{ Path = 'powershell\ref\System.ComponentModel.Primitives.dll'; Sha256 = '3A77CDCAD16D531052B0DBF701CB2B704CC6326F8C755CFEA9E1419B8031F88F' }
        @{ Path = 'powershell\ref\System.ComponentModel.TypeConverter.dll'; Sha256 = '98821E975AAB34E67E0FB84EC9E2D3F0579FBE9C26538624C1FB6C08004B5555' }
        @{ Path = 'powershell\ref\System.Configuration.dll'; Sha256 = 'FC9B3FFF09B6DCCBBC07FE8225A0CF9DF94FCEAB50B54731CAA27969CC9C2E72' }
        @{ Path = 'powershell\ref\System.Console.dll'; Sha256 = '094597042B31E7CC3EE54385E80D218D62173287E158035E105AB16A55829C41' }
        @{ Path = 'powershell\ref\System.Core.dll'; Sha256 = '6758AF6C57FE08AB2EF3426AB4FB7510C5A7C13948AAEDF81339A33D8EE54250' }
        @{ Path = 'powershell\ref\System.Data.Common.dll'; Sha256 = 'A1020CEEA8F8C7447D25FBCC429C1B364B154640045E9A4E3D177E014B0C8252' }
        @{ Path = 'powershell\ref\System.Data.DataSetExtensions.dll'; Sha256 = '82D72011785A898BC122642D7BAE6A6828BAEF73D47B8ACB52D169FFE395F543' }
        @{ Path = 'powershell\ref\System.Data.dll'; Sha256 = '2F632BD31FDAB70F9ED0B5053A2DB37F3BBD7EBD9E8CF145CE754E86946B7C0D' }
        @{ Path = 'powershell\ref\System.Diagnostics.Contracts.dll'; Sha256 = 'F0A33AA33BEEFCE08D19FDA409844AAAB858239F686C0CEE665CEA899D8F084C' }
        @{ Path = 'powershell\ref\System.Diagnostics.Debug.dll'; Sha256 = 'C2CB62B25D91119705029C8E7ADBAC2AAD4EC4123C0C31799C44FAAB51DAEB2C' }
        @{ Path = 'powershell\ref\System.Diagnostics.DiagnosticSource.dll'; Sha256 = 'ADF3F3A610AC7C2648697CCE3926681BDA6D1C1F9A313205FF5006B832450C4F' }
        @{ Path = 'powershell\ref\System.Diagnostics.FileVersionInfo.dll'; Sha256 = '54E0773D86ABF4091420B19801D7B7064E366BF71C18A5A8CF52C4AC81725B9C' }
        @{ Path = 'powershell\ref\System.Diagnostics.Process.dll'; Sha256 = '5FA8E76299ED98615AB60449D1ADDB308A5A65C310740EE94B11287276496176' }
        @{ Path = 'powershell\ref\System.Diagnostics.StackTrace.dll'; Sha256 = '85963D684436E090C6F487061639F045C99C05C6167BFA3B0CDAE9CC74CBB842' }
        @{ Path = 'powershell\ref\System.Diagnostics.TextWriterTraceListener.dll'; Sha256 = 'C1D31DBB4A2095740283BE6752E0BCBFF3A06DF73A709CE0D79321B03493183B' }
        @{ Path = 'powershell\ref\System.Diagnostics.Tools.dll'; Sha256 = '2D638B02EACCDAEF5F5AF49A93CB368B3C4BD4EAA93F7034D99A2FBFB8268DFC' }
        @{ Path = 'powershell\ref\System.Diagnostics.TraceSource.dll'; Sha256 = '4DAD1326CFB2987D07E745FB671E65FA64DC17DE492E8E563F2DD592AB6DDC71' }
        @{ Path = 'powershell\ref\System.Diagnostics.Tracing.dll'; Sha256 = 'BEDF70185C487BE23F2F921E3F360559CB834883C7C39AC9D20814CBFE57FFE7' }
        @{ Path = 'powershell\ref\System.dll'; Sha256 = '9F2FA38F2774A7D199437E469AB32128CFACDDD212592CF67E33C9BD11FD2B51' }
        @{ Path = 'powershell\ref\System.Drawing.dll'; Sha256 = '22A80405468BF2060942DEADB320C366C439983A9672B847F51D586EFA7D4D60' }
        @{ Path = 'powershell\ref\System.Drawing.Primitives.dll'; Sha256 = 'D20E5B9B5CD7ED9B3D9B304D3A432F643092EF74E1BDD62E8A992BF48ED8D767' }
        @{ Path = 'powershell\ref\System.Dynamic.Runtime.dll'; Sha256 = '302DF5B559287CE390E1A066E58627EE22A32DF5B4E9F286C375DEB7C31BFF8E' }
        @{ Path = 'powershell\ref\System.Formats.Asn1.dll'; Sha256 = '0CE200F7AC08A121D00B8B6A553CE373B400308AA241219D642EFC33D6E5C72C' }
        @{ Path = 'powershell\ref\System.Formats.Tar.dll'; Sha256 = 'DC42F47A9FB410BD7B818EB741E76BB417A57CFFA1C17AE62597B377FE235517' }
        @{ Path = 'powershell\ref\System.Globalization.Calendars.dll'; Sha256 = 'C5F326AB1A865E38ADF4A6CFDDA89F66D931AA82A0A5D8355199CCF675D60414' }
        @{ Path = 'powershell\ref\System.Globalization.dll'; Sha256 = '323015A8CFC179B48CA65D855B8C8B7C05D917C761D0C448D91486D8215A3890' }
        @{ Path = 'powershell\ref\System.Globalization.Extensions.dll'; Sha256 = 'BA52FCA9B1F3EE501DAA106C144B3861B6E8B743FFC4AF4BF8EC47AA347C8F91' }
        @{ Path = 'powershell\ref\System.IO.Compression.Brotli.dll'; Sha256 = 'C23F91019FAA89149121DD1D52CE1F79D3F119DA8EBE9E4B44ADD858CAE1EC5D' }
        @{ Path = 'powershell\ref\System.IO.Compression.dll'; Sha256 = 'A897391C4F612441544B47385FD4D070D91662065BBB1EDB64F552AF5F361BD1' }
        @{ Path = 'powershell\ref\System.IO.Compression.FileSystem.dll'; Sha256 = 'FFFD597DED2176DF766705B5982FA837D532E6CC78525965BDA74B93D292E620' }
        @{ Path = 'powershell\ref\System.IO.Compression.ZipFile.dll'; Sha256 = '057AE31A567B1A6218741A37BF29E111538B047E21A62E9225101E889C839044' }
        @{ Path = 'powershell\ref\System.IO.dll'; Sha256 = 'C6374A8AA93D7B5937C54E26B7A0DBFA39C7756673C5C0AA0ABDF415C4D3A010' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.AccessControl.dll'; Sha256 = '75EB40DE78A07275F6CABC7DBAC3FBFE6896A9B1A9CF7C7DF1E1AF123B951B52' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.dll'; Sha256 = '0A24EB1C36225504EE6AFDEA82E28B5818C9145287305BF093F1FB24D44DC267' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.DriveInfo.dll'; Sha256 = 'C2A2B003B924C323F535799D4B45F310B702181597E49C4F4EDCC634AEEC426F' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.Primitives.dll'; Sha256 = '74F3416713E3F607884504D5A5E018E4E49E1E10A81FE71E7AB19327FC6A110D' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.Watcher.dll'; Sha256 = '3F55C80726816655E8020C3BD38EA072DB48A644CD912F5BB65AD5BB9F80373E' }
        @{ Path = 'powershell\ref\System.IO.IsolatedStorage.dll'; Sha256 = 'E1F786E60BBB89605EFEC9A1D4D45C9FCC5AB324A8766D5FB2E0F38BE779D364' }
        @{ Path = 'powershell\ref\System.IO.MemoryMappedFiles.dll'; Sha256 = 'E7B83621B691328E560A2DB792BB4BEA48C7E16492A34C3C274E42D1B036BF10' }
        @{ Path = 'powershell\ref\System.IO.Pipelines.dll'; Sha256 = 'DBD8E2DB1888BA2D15F09F7F5415DFE9B61B39C21F2DE42A984A380069600B89' }
        @{ Path = 'powershell\ref\System.IO.Pipes.AccessControl.dll'; Sha256 = '4446F335957DA6D380F3CB2CBCD3D10583A0ABC3947600560BEC5566CC251B81' }
        @{ Path = 'powershell\ref\System.IO.Pipes.dll'; Sha256 = 'D21876BCD06A3F76511997692DB266ED9FFBCC1342FB7B1B2544F2973FF5534C' }
        @{ Path = 'powershell\ref\System.IO.UnmanagedMemoryStream.dll'; Sha256 = '6F9D3AF10C7B3F51B4AF66BBF6DCD20D9842E66ECE169468E9CE029C9E84DF4C' }
        @{ Path = 'powershell\ref\System.Linq.AsyncEnumerable.dll'; Sha256 = '44F1B90C156B437FE7B5D10E2EA2E3CB609FA6190177FECF3E7A073E711B5F76' }
        @{ Path = 'powershell\ref\System.Linq.dll'; Sha256 = 'DD324912D0CB42406C2EE7F7E149B0F8F6F1FF0A2E880D21C2FC6603789AA613' }
        @{ Path = 'powershell\ref\System.Linq.Expressions.dll'; Sha256 = 'D3CA0823639875F31B981C3D89B495FBA81C8BF09D8F7EA9A87B712F006F0FEE' }
        @{ Path = 'powershell\ref\System.Linq.Parallel.dll'; Sha256 = 'AC995F9DE48E3AAE6A27E7EB5C5FEED73CDA9A8DB8DE6B667003FF8C7CE50A1C' }
        @{ Path = 'powershell\ref\System.Linq.Queryable.dll'; Sha256 = '592A202A0072DCF98EA287EF3E0E837A9A1A000FCA2C36DEB239B3146D68D12A' }
        @{ Path = 'powershell\ref\System.Memory.dll'; Sha256 = '580E2D1047C960FFE533719180856256B98F20389A02902095201FBB58D035F2' }
        @{ Path = 'powershell\ref\System.Net.dll'; Sha256 = '88766FB8832084E01C60C416AFF66BAA5FC246F5F9931ED33B498345D8E50D22' }
        @{ Path = 'powershell\ref\System.Net.Http.dll'; Sha256 = 'AA79A9CB6E47A73BD908954D6798B57AB264D6B2C206DAAD48F3707EA4D93696' }
        @{ Path = 'powershell\ref\System.Net.Http.Json.dll'; Sha256 = 'A49D26EE41611D7E3676B77CE9997640F03DEA3C05D380225239A6C4F47768AE' }
        @{ Path = 'powershell\ref\System.Net.HttpListener.dll'; Sha256 = 'D5A91F31C41F0A72F7EFE73F86ACE4A7706C694BAC9F58174D679A0A7A1AB6A1' }
        @{ Path = 'powershell\ref\System.Net.Mail.dll'; Sha256 = 'E20BA0FE14E7F1B9D774FA52A622AAA6D1DB5F9567305773C7812BB164DE71AE' }
        @{ Path = 'powershell\ref\System.Net.NameResolution.dll'; Sha256 = '3DFAAA2619F574334D1641E4E523BC7D2AD697EC9E1C463FDA0A3F7C33C79C69' }
        @{ Path = 'powershell\ref\System.Net.NetworkInformation.dll'; Sha256 = '1E2C69F29D27EB57CF919D1D39B397A108D3145A4AF3BA5E8413E4174B3CEBD7' }
        @{ Path = 'powershell\ref\System.Net.Ping.dll'; Sha256 = '8F5B17BA3B21C997BD31FC063D8BA12DC7B30F8FBC72C3BB8B03D147060E482D' }
        @{ Path = 'powershell\ref\System.Net.Primitives.dll'; Sha256 = '6F69B0F80E6FBB7BB2040F5A2BB4F3FAD54C6F8A43F2FBE3B6A2646521BE16F8' }
        @{ Path = 'powershell\ref\System.Net.Quic.dll'; Sha256 = 'A74726537FC54E616BCEFCD73ED0D7912AAF2B51AAB5517DA470C9D151AEBDFA' }
        @{ Path = 'powershell\ref\System.Net.Requests.dll'; Sha256 = 'FC03695CAEA908088CF2E76BD206264BC122AD936F87205A919404B55A1BF46C' }
        @{ Path = 'powershell\ref\System.Net.Security.dll'; Sha256 = '668473931D69455E596258A829F42BE70D21F38C2F01F118252C39E7ED149C63' }
        @{ Path = 'powershell\ref\System.Net.ServerSentEvents.dll'; Sha256 = 'FA81D09117D2C12C62E94A2BF0B9A54B74362CE86E248152C608EFE732335EA9' }
        @{ Path = 'powershell\ref\System.Net.ServicePoint.dll'; Sha256 = '3A021DDA4D96AB8A5CD22B456083D889F18CD332630760A6BC854D69E312041A' }
        @{ Path = 'powershell\ref\System.Net.Sockets.dll'; Sha256 = '6235F8621AB212A84828E9A9254E1A162953B93A14CF3F15D7E9A018D328F08D' }
        @{ Path = 'powershell\ref\System.Net.WebClient.dll'; Sha256 = '3B71B5094AA0BBEB69DF6633EEA6DEEB78900DABE40507210F79F0E430E34858' }
        @{ Path = 'powershell\ref\System.Net.WebHeaderCollection.dll'; Sha256 = '50F34FD15F0CD846C19F495A07BDE027AC4B84EBDB4346B47C5E522537A44C53' }
        @{ Path = 'powershell\ref\System.Net.WebProxy.dll'; Sha256 = '32BBBD574285C227145B8E60AF7ABDE4AC0DD58E96BC3EC581EE17730E89D1DA' }
        @{ Path = 'powershell\ref\System.Net.WebSockets.Client.dll'; Sha256 = '7247D6C19BABF766A8AD0D7D16D11F0162025B48D34AE76397FFAD2A6F8FF64C' }
        @{ Path = 'powershell\ref\System.Net.WebSockets.dll'; Sha256 = '0CDCE2838DDB7A75B3AC4AB31C23A1A65C6377C46BFED3863D5B09B29A69AC5D' }
        @{ Path = 'powershell\ref\System.Numerics.dll'; Sha256 = 'C3BAFD992B680B545C0AD7FB62CF9B91899783D78D8E2B6DA4628A202303C9E6' }
        @{ Path = 'powershell\ref\System.Numerics.Vectors.dll'; Sha256 = '0926CEAFDF3461B6B49E3F7F2EC2769C948BA757FD6B7291CEE2183010DC983F' }
        @{ Path = 'powershell\ref\System.ObjectModel.dll'; Sha256 = '6283354E2553BC0AD70F05E7B36BCE0BFA184F100EF7CFE600C1B97C3A5E0B94' }
        @{ Path = 'powershell\ref\System.Reflection.DispatchProxy.dll'; Sha256 = '87C6771E257834BF8718C03155483AD4A9F33EB09B78DB8FE49FC9C926EEA74A' }
        @{ Path = 'powershell\ref\System.Reflection.dll'; Sha256 = '604F110F2C183925535DB2D21EEB9D0E14B02EC3E2CA492ACF1A00681D8671D5' }
        @{ Path = 'powershell\ref\System.Reflection.Emit.dll'; Sha256 = 'B5F6FA2346D11ABCACB2A5D9CBBF9485F9017DF2C2874ADADD4985975761F951' }
        @{ Path = 'powershell\ref\System.Reflection.Emit.ILGeneration.dll'; Sha256 = '335B2FA3D55B30637EE746DD1B26101DA24F64C9A0CA6523F61F769A521EF229' }
        @{ Path = 'powershell\ref\System.Reflection.Emit.Lightweight.dll'; Sha256 = 'E15D2C904814FE3D3C60A7FEE5CACCB42C255BFA1A58B24DC2E3E22CC1091321' }
        @{ Path = 'powershell\ref\System.Reflection.Extensions.dll'; Sha256 = 'CD552FD8BB3F8A313627677568CBD2E1E251E39E3D8EF04995DE285AF596257B' }
        @{ Path = 'powershell\ref\System.Reflection.Metadata.dll'; Sha256 = 'EC8939033B710E91DD22C8111B38111BC92D1149F2C62FC3A6D49D03A632C039' }
        @{ Path = 'powershell\ref\System.Reflection.Primitives.dll'; Sha256 = '969715A3C581B54B50F48F9CD70D1ED52D7C11A4CA5B7D2F970C791EFAB2C281' }
        @{ Path = 'powershell\ref\System.Reflection.TypeExtensions.dll'; Sha256 = '8B9E8CEB9C68A93ECF4135443735820F4D22C34C3F11C44679D579B15BA7A8FC' }
        @{ Path = 'powershell\ref\System.Resources.Reader.dll'; Sha256 = '2DEAD871C83FA2668E18CE6F61E76734390115F37789E10C8182A98CA3D3ACAA' }
        @{ Path = 'powershell\ref\System.Resources.ResourceManager.dll'; Sha256 = '2E91F4000254EF1F34D7C4EF650A67E2521E381D5A4FA389BD1CBB38AAB3AE28' }
        @{ Path = 'powershell\ref\System.Resources.Writer.dll'; Sha256 = '220DA22096DDDCC9A3F9A8C6A52F8A31D98F75E137403B54EB7DE3BABDB314A1' }
        @{ Path = 'powershell\ref\System.Runtime.CompilerServices.Unsafe.dll'; Sha256 = '00204D3071F863624D6E7ED323579AADAC44191E2FDF7DC5BFE1896A59F48D68' }
        @{ Path = 'powershell\ref\System.Runtime.CompilerServices.VisualC.dll'; Sha256 = 'D31641E4AC2E523F985C9F1644527A4DEC9B63902B238436168CB2940F7F2F68' }
        @{ Path = 'powershell\ref\System.Runtime.dll'; Sha256 = 'F14458D03C0E944BA39CE0718EF7E5ECEDA598B48902A38F6FA2966748AE36A8' }
        @{ Path = 'powershell\ref\System.Runtime.Extensions.dll'; Sha256 = '2ACB1FAF01E3061BBF84CF60B4DE8116A821084D480E568FCBF337CDDAD44946' }
        @{ Path = 'powershell\ref\System.Runtime.Handles.dll'; Sha256 = '3A12926C9543CA46C4287A8E99BE2788275AE58672367AF7AFF60D52859DED6F' }
        @{ Path = 'powershell\ref\System.Runtime.InteropServices.dll'; Sha256 = '361B7938460DD6AD5CC99672A42C09C22FBBC16160FB15A89DB264D7BEBFAD96' }
        @{ Path = 'powershell\ref\System.Runtime.InteropServices.JavaScript.dll'; Sha256 = 'AE025A330886B15611D962F61B5E4C41300096AE8D92DBDACF179D7C7B55DF2B' }
        @{ Path = 'powershell\ref\System.Runtime.InteropServices.RuntimeInformation.dll'; Sha256 = '5B10A7935D44F9A279DF162DA405714D4667D044CFA25CDC88DDED1FDB0F1D53' }
        @{ Path = 'powershell\ref\System.Runtime.Intrinsics.dll'; Sha256 = 'FCE1E9442DA8522144ECDC3E85F31D75E979468DF0546DA308ED3BC75CE6F950' }
        @{ Path = 'powershell\ref\System.Runtime.Loader.dll'; Sha256 = '741E0F4CA9FFAE905D192C24EFB5082D5CE97F9FFAB547C09643A54CF1955356' }
        @{ Path = 'powershell\ref\System.Runtime.Numerics.dll'; Sha256 = 'AC5658182BF2C76ECFED233EF85882893AB2475700593F8F12AFAA2583123592' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.dll'; Sha256 = '4097D9D333FCA666495541A3AA106EF96A2E2C0141C1AE13AE9B18D029A21D82' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Formatters.dll'; Sha256 = 'E0D4C3F2B5CB93B95584A50EBFA67B92CD0CDF47C738263EE7C8A7425D30513A' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Json.dll'; Sha256 = '86F1F25E6FA7806D5C6A97289E7E10F9FB77E68A3A77FC3225B54EBB53C6193E' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Primitives.dll'; Sha256 = '77E7B946A1A6BD9D0C539690DC1EC76704EDC985E48BD80C083C10794D2F5E95' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Xml.dll'; Sha256 = '948ACFFE5646F0DB7439591926271CB9B0030E9AC063B587F0693AF66253BCD1' }
        @{ Path = 'powershell\ref\System.Security.AccessControl.dll'; Sha256 = '75EF0139FC05F618AC1EA260E2DEF2991CF557A9B043ED96D9E359BBE1B7ECF3' }
        @{ Path = 'powershell\ref\System.Security.Claims.dll'; Sha256 = '7DC19B0BA99000AAD7B552C715CF245B971011CBEE9066D7AB2BA2DCC2FC54A4' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Algorithms.dll'; Sha256 = '0D32E472EBCF3DF90731A8E0C0F2556D54A0DBC6B793AC2A6A252A4DA65A31C2' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Cng.dll'; Sha256 = '5764DF594CDFAF851E24C82CB0E416556F308B27B5A7C4A19BA43EDF9068F1E9' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Csp.dll'; Sha256 = '35FDEDA39D810A2C1C1728B6BBAA93DDB4593093DE4A80E247D03349F3B56D76' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.dll'; Sha256 = 'B9D140E03D0241331B48ED68AD25F8DF773916BBE410ABBEA3A90DA74D8D5662' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Encoding.dll'; Sha256 = 'AD4110CCFFDE277E12208BCF7809A2BD4AB7964141DD66EB2FA72B22CDD6C4C3' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.OpenSsl.dll'; Sha256 = 'DBCBD42868C37C0406D31F2B09F8922220C1D1CD48A3F952C7D4629A984DDB01' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Primitives.dll'; Sha256 = '57354FD66966F66086E04473D35FAB0669B09BEF7D096FCAF34D8354FE76CD32' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.X509Certificates.dll'; Sha256 = 'DF29CE12B35FB73BFC1D995C4AC239D581EDBAB0A29407C7E342392FFDF8CC56' }
        @{ Path = 'powershell\ref\System.Security.dll'; Sha256 = '30FC328A0ED390D32270515626C8FBCE8FBC4DFB98510FBAB473FBC64A101DBA' }
        @{ Path = 'powershell\ref\System.Security.Principal.dll'; Sha256 = '8E3D5D135ACE4195C0EF7A74EBF3788748D23417AEE0496712C02B99DAA4BE97' }
        @{ Path = 'powershell\ref\System.Security.Principal.Windows.dll'; Sha256 = '9614098DC489F67AA40C88A587DE7CB183CB95FECD1642FF970FA435EA4DE963' }
        @{ Path = 'powershell\ref\System.Security.SecureString.dll'; Sha256 = 'E060EEA5223C0C65D2BA658C21BA45FCAC7631546DA4C6339E67B42C74B2E840' }
        @{ Path = 'powershell\ref\System.ServiceModel.Web.dll'; Sha256 = '8040BDD3EB52F073E935DD701FB63970B78264136B8C0861F070A398ED406586' }
        @{ Path = 'powershell\ref\System.ServiceProcess.dll'; Sha256 = 'B4B2182496065356838AA3E2B35F610F851B38AF182566D6220C1100CFAD1E2C' }
        @{ Path = 'powershell\ref\System.Text.Encoding.CodePages.dll'; Sha256 = 'D6D75824562125BECAD8E0AB850E1D928628D271DCA32173AAC0DB5D20C8D458' }
        @{ Path = 'powershell\ref\System.Text.Encoding.dll'; Sha256 = 'D2B782EA81F033C69E337BD1A94F6C6E43A7BEEB3436538A21FF77B1DE9FCFED' }
        @{ Path = 'powershell\ref\System.Text.Encoding.Extensions.dll'; Sha256 = 'CD2191EAFE20A0C3FEE295950E995BA13F65C6F5555CDFA9283368B7D473E8BB' }
        @{ Path = 'powershell\ref\System.Text.Encodings.Web.dll'; Sha256 = 'F7150BFA0E00EB670C27B12E90562009EB6D52D08407C2905F7BAD5D48078279' }
        @{ Path = 'powershell\ref\System.Text.Json.dll'; Sha256 = 'AC815E6F37DC3163629BEB6792E35B93ED587534276A937FE586D8B33FF5A0B8' }
        @{ Path = 'powershell\ref\System.Text.RegularExpressions.dll'; Sha256 = '886C59BD2B3A05212E71CA8473ADAD1243FC4B103216049EB8DB6DEDF01C3AD9' }
        @{ Path = 'powershell\ref\System.Threading.AccessControl.dll'; Sha256 = '2CCA4A2CCD65F62ED7C718BCC0E196F0030C6BBAD21BFDCEA68E6FC5B19CE9CA' }
        @{ Path = 'powershell\ref\System.Threading.Channels.dll'; Sha256 = 'F4D166A335C7F3A820ECD32C85D94F1222F4B1704F11B95A051C8EF45951D3CF' }
        @{ Path = 'powershell\ref\System.Threading.dll'; Sha256 = 'F82231C0C563AF91B546F0326CEB0A6D598275CC755C78A870A592B75C8D8197' }
        @{ Path = 'powershell\ref\System.Threading.Overlapped.dll'; Sha256 = 'FE5284CC48895C92D4ABBAEC527A5905D07400016C536DE7D440BA21045AA829' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.Dataflow.dll'; Sha256 = '528706815067307ED2FC95A3F7D383BE3C09756507EBBACA53B959F9B430134C' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.dll'; Sha256 = '91E8C5FF79BAA8A063287E5EFCC1029D5E72CD09FEDAE9E7F03CC636F0E8C551' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.Extensions.dll'; Sha256 = 'E7B0AC7FC7AF5C4F11FF7327A6C82263EB8908EA62FF86CB93B0313286C4470C' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.Parallel.dll'; Sha256 = 'AFFA4B3C29675B7362B9198F288E3E9D17BAEE393EED06387CAA3992D6E84D19' }
        @{ Path = 'powershell\ref\System.Threading.Thread.dll'; Sha256 = '5627FD386F7619EFFDA7846BAF0EAB9A51BBBD5496E5B28FD9622ADF89F8C55C' }
        @{ Path = 'powershell\ref\System.Threading.ThreadPool.dll'; Sha256 = 'CB69A035023514E95DEA8D4F0DDA8CDDC687F6EE46E480553EEF69C69C991004' }
        @{ Path = 'powershell\ref\System.Threading.Timer.dll'; Sha256 = '9980F15602E3D865E4DA3085599C89CF9E5DD01D4FDF83220632AF24BF8B072E' }
        @{ Path = 'powershell\ref\System.Transactions.dll'; Sha256 = 'A134BA152E1041B84FC3DBE2A2C193FDC1FD2775F4122B91133D2D12E1746121' }
        @{ Path = 'powershell\ref\System.Transactions.Local.dll'; Sha256 = 'E09C285F21A97DED8078433CEBA81AA6C10E2718474F0FBAA06B1B61083296D2' }
        @{ Path = 'powershell\ref\System.ValueTuple.dll'; Sha256 = 'D7DE7FC8780A35D3CFBBA6E2F32A50569628D9088D11E32195CA361A3E142296' }
        @{ Path = 'powershell\ref\System.Web.dll'; Sha256 = '4B1D439F543040F01A240F9F8EA011A6A5311442AB3F2C7364A9C5FDE073EB66' }
        @{ Path = 'powershell\ref\System.Web.HttpUtility.dll'; Sha256 = 'B0A17F481F3E1ED1E3BC0225079A854F1C26BF0A5F70D1273CF14A87450ACD0F' }
        @{ Path = 'powershell\ref\System.Windows.dll'; Sha256 = '93573613B9FE6493C173844480AA60E8007293246021E3DC40BDD25D782D845F' }
        @{ Path = 'powershell\ref\System.Xml.dll'; Sha256 = '7B811308EE61840CCC69B447845446030D29C1C66BDB9842BA5A59A1C62A60CB' }
        @{ Path = 'powershell\ref\System.Xml.Linq.dll'; Sha256 = 'B0A5B461BF71412DF3CF98FA49AFE230859AC7E7F8872525821BDECCC44FFF89' }
        @{ Path = 'powershell\ref\System.Xml.ReaderWriter.dll'; Sha256 = 'AAC81C27A4033172C3E9077A33824264BA3A76F842A9F5D0E753894600CFA675' }
        @{ Path = 'powershell\ref\System.Xml.Serialization.dll'; Sha256 = '8CAE84633102182C4B3484BA5B456F63D06BC5D67F4EC9CAEE9B271EDF449B04' }
        @{ Path = 'powershell\ref\System.Xml.XDocument.dll'; Sha256 = '3BBC398F7217FAE090AFF20F6B61513DE372C6EA90DB5F865D4ACBE433F23AF3' }
        @{ Path = 'powershell\ref\System.Xml.XmlDocument.dll'; Sha256 = 'BF18C4A123B6344CD11AFB199B5013456A99CA216F99CE5BE905139DC7CB4319' }
        @{ Path = 'powershell\ref\System.Xml.XmlSerializer.dll'; Sha256 = '6296819EC5B90591E41E7A0CBB4B576BF915ECB36AA6F84965EC2D02E96D7435' }
        @{ Path = 'powershell\ref\System.Xml.XPath.dll'; Sha256 = '3351170020607A2A0925BE565D9663F1B13F1C6D39C2E88396A7166C8D332D36' }
        @{ Path = 'powershell\ref\System.Xml.XPath.XDocument.dll'; Sha256 = '5B92848B5B295C801895AE2368414C789B0C7F5FA3695951AD34A11A214886BA' }
        @{ Path = 'powershell\ref\WindowsBase.dll'; Sha256 = 'ED60CBCA325489CDC1ED615F5F8F63AA213B5ED9FCFDA39C58E985A12D12C9FB' }
        @{ Path = 'powershell\RegisterManifest.ps1'; Sha256 = 'BA5C72BA378ADCD6316776B5736E2571D84F09C2AF447B2A127C4D572328B2C8' }
        @{ Path = 'powershell\RegisterMicrosoftUpdate.ps1'; Sha256 = 'D8DFE3468B4E3640958639F741AC63F7D139CAFB32CFF220E15B7B2FC5ADD503' }
        @{ Path = 'powershell\Schemas\PSMaml\base.xsd'; Sha256 = 'B860EF30B01C57486A56948800E9B2DA116EC473CBECBB33FA9F71B8CEAB90AE' }
        @{ Path = 'powershell\Schemas\PSMaml\baseConditional.xsd'; Sha256 = 'D26D4EF29124B2F9107B167D73E611F649FB2021D30C48A8616C6CC96230DE81' }
        @{ Path = 'powershell\Schemas\PSMaml\block.xsd'; Sha256 = '9A8B3C184394711480C38D71DB4850659B87729DF9EAC5A2235BDCF37A2020CF' }
        @{ Path = 'powershell\Schemas\PSMaml\blockCommon.xsd'; Sha256 = '928717B190B014F271C09C2FFB7633C1E660B26F0ECBDD926662121914795789' }
        @{ Path = 'powershell\Schemas\PSMaml\blockSoftware.xsd'; Sha256 = '88AA3462598B7C394350F83EF366E5F83885C50A9C6966F02179228277358334' }
        @{ Path = 'powershell\Schemas\PSMaml\command.xsd'; Sha256 = 'A3DA7F8F2260A826CE253C33BDA8576246B4298794765EDC4F80A433357C6B87' }
        @{ Path = 'powershell\Schemas\PSMaml\conditionSet.xsd'; Sha256 = '506415CD77EDE25B33C3E28FB89012B282E90B5D01F266323A83FEA9625F8EAB' }
        @{ Path = 'powershell\Schemas\PSMaml\developer.xsd'; Sha256 = 'AB9A7DDB85084F331ED79CB34374509767D9A64C510B0264682D5E682DC59497' }
        @{ Path = 'powershell\Schemas\PSMaml\developerCommand.rld'; Sha256 = 'CD8A9A6B113DB5005F2A5C8321E52368411691B5F0C5EB90595E2A97B0FDEE89' }
        @{ Path = 'powershell\Schemas\PSMaml\developerCommand.xsd'; Sha256 = 'BBC9B2DD6D4473F09CE95A4E44B7F654A8D34A70197BEABACD1C9FF5233C3DEC' }
        @{ Path = 'powershell\Schemas\PSMaml\developerDscResource.xsd'; Sha256 = '7C22D9A1393062734E4923657C48D9117F6AC824D4E3F85EF88D8DE23F8C7BDF' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManaged.xsd'; Sha256 = '5585FD25ED4FA8D39B75E9A83082EAB1D305B00839E7BCF05A24530E3D91D6EA' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedClass.xsd'; Sha256 = '4CB1C23D86D22B4BCC5ACA98CD309C37F54A30358D673115D460FEEACB78DF9A' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedConstructor.xsd'; Sha256 = '0CA55A744AD968B537742ED37CD62852DF01CD96533D4E17874AD4F75271C8DC' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedDelegate.xsd'; Sha256 = '961DAA1C4B3513B83CF2E37FDB1361BE0D123E8B2CFE7F32510AD534FEA98E3D' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedEnumeration.xsd'; Sha256 = '3AB7329914D7A9A6D711A62405089E736CE714EE4DE72F3493222887A72FDD39' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedEvent.xsd'; Sha256 = '93EBD3AF5A078830839B10C9DB753CD445DC2D1A78A5449C90AC605E7FFC397C' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedField.xsd'; Sha256 = 'B17F73ADD6678C4BC259065ADD380A9070531BC24A66AF3C4CAD3CF3D811F3A5' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedInterface.xsd'; Sha256 = 'B851D8BE146F1F51E5857045C28726585CC96A29C5A5A57DFC86CF7C509D8234' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedMethod.xsd'; Sha256 = '36EB2BC76B2CDBFD908DF62E16CA915F7490CE75CF7BC386974EF89AA77B32FF' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedNamespace.xsd'; Sha256 = '68D68D8CEC8181C0C3046B419426EE1BD4D0371ABFDBF9A6789755B0F5764D91' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedOperator.xsd'; Sha256 = '053C18557BE353860222E14D7CE5E5844F5A746BA45347A9E08DA1D5A2B29F3B' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedOverload.xsd'; Sha256 = '7D2695D2F6AB6EB3C0BAB6125EEE415545C3EABE0923B1B37519F2D4A8B9251D' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedProperty.xsd'; Sha256 = '832A25485EAA9060868E9258AA1F93626804ED439EE2B43B2D74F9CB0DC438C4' }
        @{ Path = 'powershell\Schemas\PSMaml\developerManagedStructure.xsd'; Sha256 = 'B7D1F7DDBCFEF43BD171FD78D5A255089A97762AD67C116B6A6998815905901F' }
        @{ Path = 'powershell\Schemas\PSMaml\developerReference.xsd'; Sha256 = '42C585D48C418C7EB47CBA298A147923597B967E236997BB815301B57E31CB92' }
        @{ Path = 'powershell\Schemas\PSMaml\developerStructure.xsd'; Sha256 = 'D1C0E02BB7207095E49EFC216A574B596A82E97B88E686E1C7A9717362623C44' }
        @{ Path = 'powershell\Schemas\PSMaml\developerXaml.xsd'; Sha256 = '83ED2EE26CF6AB4C95A880F1424F7D5E09385B71239B84B3CFFB58288EEFF3B2' }
        @{ Path = 'powershell\Schemas\PSMaml\endUser.xsd'; Sha256 = '24CAEE5D0536ED81EB68D6FD836CF08849E056497B6064971A145397A04EB853' }
        @{ Path = 'powershell\Schemas\PSMaml\hierarchy.xsd'; Sha256 = 'D50D8096A11350A8E3B6873CF9CBC173B8A4322324B16F949538B1B98857C5B4' }
        @{ Path = 'powershell\Schemas\PSMaml\inline.xsd'; Sha256 = '5A1A2D4586203BB3D6A4E6EC93E4D09D0AB66D33539B88A2550A36100D1E16FD' }
        @{ Path = 'powershell\Schemas\PSMaml\inlineCommon.xsd'; Sha256 = '02071402B963966AD574AB09BB42719BDB1CE6CD7E9AF260A13FAF9EBB580C55' }
        @{ Path = 'powershell\Schemas\PSMaml\inlineSoftware.xsd'; Sha256 = 'C444CD1121A8B83B0FFE5A8467CC10D2D810C5A7765F4B4406D1EB329CD8901D' }
        @{ Path = 'powershell\Schemas\PSMaml\inlineUi.xsd'; Sha256 = 'E7FF025576E482632878709E208B95916CCDCA2AF108C1C7B9218FB8472C1AE3' }
        @{ Path = 'powershell\Schemas\PSMaml\ITPro.xsd'; Sha256 = '767328AD7B14EC90731E52D04EF27873EA674D34DD30297CB0FBA2A11242E96E' }
        @{ Path = 'powershell\Schemas\PSMaml\Maml_HTML_Style.xsl'; Sha256 = '99E1AD569C30396EFC7F37ACD08A8F0F41B20FF82E513D738E331C0EAC5DDC1C' }
        @{ Path = 'powershell\Schemas\PSMaml\Maml_HTML.xsl'; Sha256 = 'BDA0F195C928E6C18E226A83C77A1477DD88B70025D78F12D92605BBD10723BB' }
        @{ Path = 'powershell\Schemas\PSMaml\Maml.rld'; Sha256 = 'A711A691FDFDBEEEF09CB23543A8AC3D6BBF92AABEEC05939FCA51665229E710' }
        @{ Path = 'powershell\Schemas\PSMaml\Maml.tbr'; Sha256 = '0FFD2E7097B51E0C6E1C1A18867658312D39AC68D8179049521F9ECAEB2CBF08' }
        @{ Path = 'powershell\Schemas\PSMaml\Maml.xsd'; Sha256 = 'FDA94A92FE41A7280D7F5ECE13CFC0042D4E1049E8FF961717628412317F6AE2' }
        @{ Path = 'powershell\Schemas\PSMaml\Maml.xsx'; Sha256 = '639E5ED55BB9FD20672C74C20020C6C96B5FF721E45E9A337133AF858998B08C' }
        @{ Path = 'powershell\Schemas\PSMaml\ManagedDeveloper.xsd'; Sha256 = '3B89CB9A72549C46A56D9EA2EA12AC53CBC7DDD3392012FDD9D69EF261961AD2' }
        @{ Path = 'powershell\Schemas\PSMaml\ManagedDeveloperStructure.xsd'; Sha256 = '0FA8EACF615F4A726F846D2938E18E84BB641BB28579BD9E2AB83F3D46D505FA' }
        @{ Path = 'powershell\Schemas\PSMaml\ProviderHelp.xsd'; Sha256 = '0E6ADBE5B896F075BF55AE6F2C1966E0E5596F79BC282C2D17CC36CCF41C30CF' }
        @{ Path = 'powershell\Schemas\PSMaml\shellExecute.xsd'; Sha256 = '52F48B0830346E30C782AA5C379DC547D0F40265FF1504276C904B819446409E' }
        @{ Path = 'powershell\Schemas\PSMaml\structure.xsd'; Sha256 = 'F35E24830E9E1A6AC79DEDFBC3F2EF03EFF8D41EF8C2414E8BA1C1A52E527391' }
        @{ Path = 'powershell\Schemas\PSMaml\structureGlossary.xsd'; Sha256 = '4425E365BA3B646B11E5625644D5F98B0151F60ED2BA0A28316570D7D68F6FA5' }
        @{ Path = 'powershell\Schemas\PSMaml\structureList.xsd'; Sha256 = '176D55D7715DDECCCBE51330E9C012E09972AE3E4A9C9AC8D1C5869B9510540A' }
        @{ Path = 'powershell\Schemas\PSMaml\structureProcedure.xsd'; Sha256 = 'D323AEB14F98A01583E538DD92EF445E1094DB861DC7205D5D2062976DE539B3' }
        @{ Path = 'powershell\Schemas\PSMaml\structureTable.xsd'; Sha256 = '63D397B018E5D3783AE3057658D7ADCB44F968BFD81329D2FCEA1ABB91F2C7B8' }
        @{ Path = 'powershell\Schemas\PSMaml\structureTaskExecution.xsd'; Sha256 = 'C37308C8CDB9AC988C94A850A848FC79707FB5D268F7E17072D6D2FB8E83E852' }
        @{ Path = 'powershell\Schemas\PSMaml\task.xsd'; Sha256 = '808A13CEEEBDA94C0152B93A52A7825E20B5C01780A3EC6C2AE0C8AC0230ED74' }
        @{ Path = 'powershell\Schemas\PSMaml\troubleshooting.xsd'; Sha256 = 'FBA82FDA979C33074968ED01AD95970FCF1151F3E7C298955BD501D5CA554633' }
        @{ Path = 'powershell\sni.dll'; Sha256 = '68705C4EF9AB818F2956A78E05F3FEFCE501A1448793B073B46110BEB49B47D6' }
        @{ Path = 'powershell\System.AppContext.dll'; Sha256 = '92CFBD7D25FE50E98A0B7FC190AFFD2C8D74539F58C4A3F2DB98FBB40A69E59B' }
        @{ Path = 'powershell\System.Buffers.dll'; Sha256 = '8EE3A48619BD83F1ECF891174E948E0A6C26849F9CAE273E22416B147F58345E' }
        @{ Path = 'powershell\System.CodeDom.dll'; Sha256 = 'D7D7C3BF8B6F95A62CB374E88447AA97815A8585F0C49E62B02063D7D60E13CC' }
        @{ Path = 'powershell\System.Collections.Concurrent.dll'; Sha256 = 'BFBD0A111B55792F573F7AF10C71B6C71DC38C5E18E1A82EFD06CE93ED11ADC0' }
        @{ Path = 'powershell\System.Collections.dll'; Sha256 = 'C72D0E86C0A8D9F635E92B198F4DC23340C9118ADB8122FCFD2097E5AA51A083' }
        @{ Path = 'powershell\System.Collections.Immutable.dll'; Sha256 = '4A3F96642390F76E5120AD2F2C8E52897C1ACC9EBF57783392680B9BB9B9BBA6' }
        @{ Path = 'powershell\System.Collections.NonGeneric.dll'; Sha256 = '92FB1D15C9361F72A54CD28F4D06E8DA5D162DD7F9A142FBA02D1CA492DB4B9C' }
        @{ Path = 'powershell\System.Collections.Specialized.dll'; Sha256 = 'ADFDD0C329004D0B18E971E3FE6C1E441EE646A802CA1743AE550F7107DA0CA0' }
        @{ Path = 'powershell\System.ComponentModel.Annotations.dll'; Sha256 = '6C9664A496F83236DA958027BFD554901363562E3E47FDB058A5AE27FC8DE80E' }
        @{ Path = 'powershell\System.ComponentModel.Composition.dll'; Sha256 = 'D9173B7A627061423F1021A361A7325849A6B49F6046BDE549C89D9FD2FEB532' }
        @{ Path = 'powershell\System.ComponentModel.Composition.Registration.dll'; Sha256 = '4779C652B21A44A590266C32E2C116BDE7CDC27DDE122E0D1676148BF2253693' }
        @{ Path = 'powershell\System.ComponentModel.DataAnnotations.dll'; Sha256 = '054151BD1AAF55702FF58A32F8D92F8E532C964DD7BED2E6FDA9F992F945F33E' }
        @{ Path = 'powershell\System.ComponentModel.dll'; Sha256 = '69D5824C371A999900ED5C9A353C5286A15E074D2429A7348F2EDEEEEB0F2AD9' }
        @{ Path = 'powershell\System.ComponentModel.EventBasedAsync.dll'; Sha256 = 'B34E19D53B21155F75DBF5CE13D0FB54C7C2745E8007D3B51F9C24311FDD58F3' }
        @{ Path = 'powershell\System.ComponentModel.Primitives.dll'; Sha256 = 'B183D0D19507AA9478DD3C7BBDE36DCBB2B8AB4B31E26F511FDA2485862D2FD1' }
        @{ Path = 'powershell\System.ComponentModel.TypeConverter.dll'; Sha256 = '460947B9AA91510B1B6F61A68F978B0F983C807A715110DAC8F3A80C4D8B5E20' }
        @{ Path = 'powershell\System.Configuration.ConfigurationManager.dll'; Sha256 = '934B31166034A5A8E3AFB6F67C884D371206F0392610B553037CAC24D96BEA90' }
        @{ Path = 'powershell\System.Configuration.dll'; Sha256 = 'BFD15CEDBE02F3F952BB9AEE7A5BC28D8772936C8CF8DCC30F1581CB3C51C87A' }
        @{ Path = 'powershell\System.Console.dll'; Sha256 = 'EE649785683C94523E4E15B7D905A99312AD00615D02F47FF9E1FD436524EF03' }
        @{ Path = 'powershell\System.Core.dll'; Sha256 = '376EAD383E92368A3A30EF46584B5A6A6F128A12131D7ACC01DB269BE017B7D0' }
        @{ Path = 'powershell\System.Data.Common.dll'; Sha256 = '43DDB7A47CD9AF02E24D9D53A403535457176987A5D2074A16882F3A1C0201F3' }
        @{ Path = 'powershell\System.Data.DataSetExtensions.dll'; Sha256 = '23251418BE773AF323E8D9DC29A7A8D946683A6B434250F1D3F11DA61695DBE9' }
        @{ Path = 'powershell\System.Data.dll'; Sha256 = 'DB7F0D0423FB1EEDE7BEF1AA27A67515819C0B66BA1BB7494A75E0EEABFAE1FB' }
        @{ Path = 'powershell\System.Data.Odbc.dll'; Sha256 = 'FC18849F3147672A0D0E1436049E5709498DD0F09E494B4AAE396D7F24A226AB' }
        @{ Path = 'powershell\System.Data.OleDb.dll'; Sha256 = 'CC3C2C3848795DCC6154C689A7BFC294886C73C7A47BCC7F0F1299B0649E5244' }
        @{ Path = 'powershell\System.Data.SqlClient.dll'; Sha256 = '16D99079A1DBE49F19CFE95D40B8087271847CE17642AFF52509CB7606EC67EF' }
        @{ Path = 'powershell\System.Design.dll'; Sha256 = '665AC228890C2A24FC370A7D7D5545EAB781865D4C061A9F401F83EFB6D86AA7' }
        @{ Path = 'powershell\System.Diagnostics.Contracts.dll'; Sha256 = '4F105BE785CF78D8E5C46A0292F5DB8E659CC79D5AA705EA4EBCBECF2F119958' }
        @{ Path = 'powershell\System.Diagnostics.Debug.dll'; Sha256 = '603A6EF5519434A80FCFC36717354C3846B849275DD3899108B16D241393AEEC' }
        @{ Path = 'powershell\System.Diagnostics.DiagnosticSource.dll'; Sha256 = '71CB569CD64163D9D843A57FCB9C075F596E9A5C6AA32B5D3E4ED5968717A6EF' }
        @{ Path = 'powershell\System.Diagnostics.EventLog.dll'; Sha256 = '89F7D4EB8146728EF883406522799909626C1494FE3EA85DC207EF5F081B9B94' }
        @{ Path = 'powershell\System.Diagnostics.EventLog.Messages.dll'; Sha256 = 'EA51F80E2D12F970A660EE3403342A762EA474A7E7E0C1337D7F426A6D96251E' }
        @{ Path = 'powershell\System.Diagnostics.FileVersionInfo.dll'; Sha256 = 'EA7FB743AF87E11AEFB7DB777043C210DBCD45C09BFE6387D892E94B50AA8C90' }
        @{ Path = 'powershell\System.Diagnostics.PerformanceCounter.dll'; Sha256 = 'B7078E33E89B6B5E6BC6582C5E1896A98E3E1C7D5C2E7A07FDD306FDDE5C8F98' }
        @{ Path = 'powershell\System.Diagnostics.Process.dll'; Sha256 = '54EFD2B509ED5387A43DC5F9F2112B4C9AF126849CE385EDFE6755F24767CD02' }
        @{ Path = 'powershell\System.Diagnostics.StackTrace.dll'; Sha256 = '8DC5A20A79A11A6D9CF9B499DDD7B6DB9B72E021AE421C9479F454EA81D38895' }
        @{ Path = 'powershell\System.Diagnostics.TextWriterTraceListener.dll'; Sha256 = 'A8609DB8701DCD5B7FD8A45D378DF67E73D9EAEA1C295F78C1A993221D92DADA' }
        @{ Path = 'powershell\System.Diagnostics.Tools.dll'; Sha256 = 'F63E441318438A26ECB74FD198508C88C85D07BF8647514ACEED90D9D62BEE8E' }
        @{ Path = 'powershell\System.Diagnostics.TraceSource.dll'; Sha256 = '36EC44B04B86F28258AE11AD68B1CC84CD53F7FDACA5577316776E3D9674D109' }
        @{ Path = 'powershell\System.Diagnostics.Tracing.dll'; Sha256 = 'FC13829CED2DC058561FE59609C4B68E3617DB677ED6BE51E8DA8D9F4262EA63' }
        @{ Path = 'powershell\System.DirectoryServices.AccountManagement.dll'; Sha256 = '54B07FB881475033991978E34F1F8B1C4B1C8D98331F324ED2B6000A697A6E36' }
        @{ Path = 'powershell\System.DirectoryServices.dll'; Sha256 = '5400FA5DE6095FB4BD4F74B8CFC28E029C770FA01102D33031AD37FCD838DE47' }
        @{ Path = 'powershell\System.DirectoryServices.Protocols.dll'; Sha256 = 'F16A0CFA4EA46DF9C2FFB94ECBC9226B24162F4CC74D3333C01AFB2D3024F7D9' }
        @{ Path = 'powershell\System.dll'; Sha256 = 'CF9D2194D62CD47E1B477388B56DAE6D21B6ECB77F3ACA02A91B21313CA6A55B' }
        @{ Path = 'powershell\System.Drawing.Common.dll'; Sha256 = '25C64758B64C35617CDFC501692C7B7FA86BE97B3A7786A1599A6272C4CCD3A5' }
        @{ Path = 'powershell\System.Drawing.Design.dll'; Sha256 = '02992F9B8917BE12FF1CF69D1A2A78B2A268A5A95592CFB8868FD81D7131A055' }
        @{ Path = 'powershell\System.Drawing.dll'; Sha256 = 'E75046CB55CB1CAA87FFAF97D2467993D2278802BB85215B81C02284EECD95C8' }
        @{ Path = 'powershell\System.Drawing.Primitives.dll'; Sha256 = '8B8EBCFF60BAFC42845C08D3F5BC4D060F9D0119A3F8956753D397DC4C61DE6E' }
        @{ Path = 'powershell\System.Dynamic.Runtime.dll'; Sha256 = '5DD7EFC0050FAC3A47C62795FD701E3D6B0DCA91931F08586FD8A94B83D5780E' }
        @{ Path = 'powershell\System.Formats.Asn1.dll'; Sha256 = '23E0B0F7C5D7476317DDCB2709A9E330573F78ED1DBB663DAF221945F471AFD1' }
        @{ Path = 'powershell\System.Formats.Nrbf.dll'; Sha256 = 'E7DD8B4EE065404235A0F7B97841F154A174F0A3F4A0A900621B035ACA797754' }
        @{ Path = 'powershell\System.Formats.Tar.dll'; Sha256 = 'AE21341F883B6D08F3D3A109A84378655E9AE1DCAF2750392F88C1001E273AF4' }
        @{ Path = 'powershell\System.Globalization.Calendars.dll'; Sha256 = 'A1202F0731BC4C4B389E9C1BD67D31102EA04AE33338ED732C58A27C7673AB95' }
        @{ Path = 'powershell\System.Globalization.dll'; Sha256 = '3CA09671ACB8D991C8E1537164F73B0D55FF37D95EC78EC14E9D89693BB8AD61' }
        @{ Path = 'powershell\System.Globalization.Extensions.dll'; Sha256 = 'D730947BFD40A76B2C8D1C4FD2A1D4B92B7EC339C4E8FFBB703E46437A5E29F0' }
        @{ Path = 'powershell\System.IO.Compression.Brotli.dll'; Sha256 = '9AF6394E082EC9075584E594F09ED08D8090FF1AB1168D3D624EC56A68BB3A99' }
        @{ Path = 'powershell\System.IO.Compression.dll'; Sha256 = '9183872E401E908A22FB40311E414882E87B2CB2D8852FC6588FDA608433C928' }
        @{ Path = 'powershell\System.IO.Compression.FileSystem.dll'; Sha256 = 'BB8457E8AF51E7762FE036D0A93A69BA318D7DBBBEC84AB56E050E8E488F1926' }
        @{ Path = 'powershell\System.IO.Compression.Native.dll'; Sha256 = '5AF05866B30A06130EBD86610AD56F32BF2D3463AEE94D05F3889624CB36A07C' }
        @{ Path = 'powershell\System.IO.Compression.ZipFile.dll'; Sha256 = '6F947D0372AF74214B7C54FBCA340E74939DE0F69D6BCFD7FABAF25699FB7AB4' }
        @{ Path = 'powershell\System.IO.dll'; Sha256 = '7387EB4A38B8261D55921C096660489FDDDD0837C4F7F7F4A2676212453048F5' }
        @{ Path = 'powershell\System.IO.FileSystem.AccessControl.dll'; Sha256 = 'F4A99E35120265AA6DCAB682FB583F4357C9FF9B434FC1CB6C31D20B20C2F197' }
        @{ Path = 'powershell\System.IO.FileSystem.dll'; Sha256 = 'BEED30F8D821275277A73D7AA5BF026809C43943329F73831ABA99F075139D5C' }
        @{ Path = 'powershell\System.IO.FileSystem.DriveInfo.dll'; Sha256 = '7460178F1A8AB703096E3B98B63692E75439DDC34351557CB8366D0986C7DF7C' }
        @{ Path = 'powershell\System.IO.FileSystem.Primitives.dll'; Sha256 = '9ECAD7926349410E1B55D7C21A0E047BBE84E62DF45B639CE5F694179C30A483' }
        @{ Path = 'powershell\System.IO.FileSystem.Watcher.dll'; Sha256 = '3132B6728B9EC3EDE33A5871D42AD870C7780E63F815D5B906DBD59C948DF52D' }
        @{ Path = 'powershell\System.IO.IsolatedStorage.dll'; Sha256 = '56C17A828A5356AD0307CF5F5E12F573AF580369234806902126A6F33963CE20' }
        @{ Path = 'powershell\System.IO.MemoryMappedFiles.dll'; Sha256 = 'CBBCB72EEC3A0F0B91016A9773E0CC327E8D7E4BDD328DFB9A67BFB8AEA01B39' }
        @{ Path = 'powershell\System.IO.Packaging.dll'; Sha256 = 'EB104F7ECE1D972B2E7021947BCF2AE34FB91460F02AD9F798AA2AA361D99193' }
        @{ Path = 'powershell\System.IO.Pipelines.dll'; Sha256 = '440174162C63E6762465A18B32AE3A42B409E2104E93D82B51A7329916061327' }
        @{ Path = 'powershell\System.IO.Pipes.AccessControl.dll'; Sha256 = 'BCF169A4554F599D318D0CC5F1C65FB2EC0A28E4231126C546D7D9FA52483CB6' }
        @{ Path = 'powershell\System.IO.Pipes.dll'; Sha256 = 'BCB08AC30A5B852BE3460FCB4A38554ED38507EC14D7B07362FDB62DA34D8BFD' }
        @{ Path = 'powershell\System.IO.Ports.dll'; Sha256 = '0B74D8BCBFC650CAE1EF8C044D37CD8C0BED0C98A85390687F4C90526AF62CFD' }
        @{ Path = 'powershell\System.IO.UnmanagedMemoryStream.dll'; Sha256 = '2F37025402C3837CB20135F665BC9D78FA4F3131DC3B6212A718BCE64AB2E043' }
        @{ Path = 'powershell\System.Linq.AsyncEnumerable.dll'; Sha256 = 'FDE3F5E307C8F9ED9C84A51DE1006496343F134982C31192DFFF05944964F33F' }
        @{ Path = 'powershell\System.Linq.dll'; Sha256 = '6809B9AA00E1F28E6BA8F28AE88ABA79A037887922787360A32E96659B533716' }
        @{ Path = 'powershell\System.Linq.Expressions.dll'; Sha256 = '93976930FA5964E1F257C182C4E91F9751CE4F35C4F2378188665326F5151883' }
        @{ Path = 'powershell\System.Linq.Parallel.dll'; Sha256 = 'F27CE2AF691B64577CEE03315F388F2A117660566DDE6FCDC2AF3359394C7FEC' }
        @{ Path = 'powershell\System.Linq.Queryable.dll'; Sha256 = 'B22E13F51F40D1DAF5DF25C5CA026D417BA33BB0F832CC595A451B790428435E' }
        @{ Path = 'powershell\System.Management.Automation.dll'; Sha256 = '70701F20AFBBF4E763924C2BDD0C0E9A20EEC35A0E4EFF439E0CCF77F20D6B26' }
        @{ Path = 'powershell\System.Management.dll'; Sha256 = '45B4B0CF2861DA416F8087CA83CBFC5F3D4F3131993F574A88771B145AA81CDE' }
        @{ Path = 'powershell\System.Memory.dll'; Sha256 = 'E65841360BBFFBED60F81A2432E791A6624F7F46980EE7B31FE0B0975C3E3DF5' }
        @{ Path = 'powershell\System.Net.dll'; Sha256 = '0C27D5D878B771A38EABB54572F0B5660A40C61116E341136CDFA1D61F8F2A39' }
        @{ Path = 'powershell\System.Net.Http.dll'; Sha256 = '125EF3B11314553008F5746A3DE9F0260C57414A06C22C016DDB45D894E7D102' }
        @{ Path = 'powershell\System.Net.Http.Json.dll'; Sha256 = '486F5494950247756FF3A28095D9182CD8AAB0118356418922D1B0273EDFBACB' }
        @{ Path = 'powershell\System.Net.Http.WinHttpHandler.dll'; Sha256 = '8D1A6D6ECE76E184C349A75B07DBC3476805D59A7F223D9213D91A7AB5FF9E63' }
        @{ Path = 'powershell\System.Net.HttpListener.dll'; Sha256 = '5DBF98EDCC1654873E370F31ADD838ACC6A2029F64B54A2A8934533A9D47603C' }
        @{ Path = 'powershell\System.Net.Mail.dll'; Sha256 = '709D3F91871F34DD6838C4EFB388C014BF63934587E045CBCEC852BF36E0F31E' }
        @{ Path = 'powershell\System.Net.NameResolution.dll'; Sha256 = '6B2616E50F4C7642B2B3919BE556D9157A00C077EB37FD9D4554D4008AFC4CB2' }
        @{ Path = 'powershell\System.Net.NetworkInformation.dll'; Sha256 = 'C34B0038B5EA07B792EED35B52E456E240F062777128BB959A16496B2A65E59B' }
        @{ Path = 'powershell\System.Net.Ping.dll'; Sha256 = '8B14FCFC8885CB233D3D11A3E55EF041A63AC694564F0B40B371057CF7B0D614' }
        @{ Path = 'powershell\System.Net.Primitives.dll'; Sha256 = 'BD049D9C742A30AEAFDBD6A6B4771356EA84E6B1914E85015ABD3B895C026A43' }
        @{ Path = 'powershell\System.Net.Quic.dll'; Sha256 = '656EFBA347CECA2DB66D6CF3DD38A2E7848A54C9A95365FDD8BE4B908DD0E834' }
        @{ Path = 'powershell\System.Net.Requests.dll'; Sha256 = '4A530487D66BBDC36DD7E808E4E0E8F9FF26BF1653B2195462839024C8EFA500' }
        @{ Path = 'powershell\System.Net.Security.dll'; Sha256 = '1180ED1C3638743320278D381AA316E6ACE1C3481F2B8755FFFAFEAB8173EA32' }
        @{ Path = 'powershell\System.Net.ServerSentEvents.dll'; Sha256 = 'A6B29EE921B5CDD0E027AA2A979BE70E61FB26F64BA1A9794E3393FABDC24194' }
        @{ Path = 'powershell\System.Net.ServicePoint.dll'; Sha256 = '73CF027571E783A1A3D946BBFF5939A4A2398EDDDD382A2EEB349602380DDA26' }
        @{ Path = 'powershell\System.Net.Sockets.dll'; Sha256 = '5751E7F1D3888567AEA9147C4DE204244076D21B36DBFD96C961FE14545AC6F1' }
        @{ Path = 'powershell\System.Net.WebClient.dll'; Sha256 = '566BC8FC15252D736352967CE98F8EC1064278B5DDCBEE062A02327508C366D0' }
        @{ Path = 'powershell\System.Net.WebHeaderCollection.dll'; Sha256 = '2EBFA966DD6E7E031423ABD1DF8142CCE7582158E0C0C9186166F303B54A869D' }
        @{ Path = 'powershell\System.Net.WebProxy.dll'; Sha256 = '305438ADDD7F7A9226AA4C4873FC022767A09547F4084918E1F573DE0858231A' }
        @{ Path = 'powershell\System.Net.WebSockets.Client.dll'; Sha256 = '8A6B86E9BC85C3EF57896FF83A477539CCB47CEF5792581028F7A573F50FFA0F' }
        @{ Path = 'powershell\System.Net.WebSockets.dll'; Sha256 = '839D30CB75621BCB3355F7B7D32E058A2C9669FDD073FEA423A353E49FE56846' }
        @{ Path = 'powershell\System.Numerics.dll'; Sha256 = '269D37998030049BEEBE406ED0325FABA425D7EEF8F9DBA5D7D3528A00B19BFB' }
        @{ Path = 'powershell\System.Numerics.Vectors.dll'; Sha256 = '03165D25FF0E1F49D99CB7D388336F140BB38CF9191E9F43BAB70EA1F540FC78' }
        @{ Path = 'powershell\System.ObjectModel.dll'; Sha256 = '59A88DEDC13BC9EFF2C4A9C02B1639C26260170E3955E2FE1AF546B75DD65983' }
        @{ Path = 'powershell\System.Printing.dll'; Sha256 = '7A3CF11572DC0059D28DFE23C5C7A92C7F9A17B0AAA9D65E8670C1D8B9851689' }
        @{ Path = 'powershell\System.Private.CoreLib.dll'; Sha256 = '8DFC31DFB4783A981179036F492D2690303E6E6571C7F260901B1B9EBC9E64AE' }
        @{ Path = 'powershell\System.Private.DataContractSerialization.dll'; Sha256 = 'B4A18DDC442877D3959778DA1468ED1C9E5A019DE3945F1376BD3970972EA8F9' }
        @{ Path = 'powershell\System.Private.Uri.dll'; Sha256 = 'AF276BA5DF09BD4435B74843B6F33F9C7F72D4A52E9278F7BC090F0EB8B0CD4E' }
        @{ Path = 'powershell\System.Private.Windows.Core.dll'; Sha256 = '358E93FFF87FB5581FE6C178196F0BF7E550CB0874167C17A42AECFF607E6EF8' }
        @{ Path = 'powershell\System.Private.Windows.GdiPlus.dll'; Sha256 = '7C6A8278182A1218103283A978920AD7334F821D74A2FBCAF20F475BE488C488' }
        @{ Path = 'powershell\System.Private.Xml.dll'; Sha256 = '2A12FD3660E74C7DCB7D6BB4C6059650A076EEFFE112204926428514FAA73E1C' }
        @{ Path = 'powershell\System.Private.Xml.Linq.dll'; Sha256 = '77D0C91586DA6D304EA0B91DE9AB604721F42B5F8207DEF5CF406FC4DFD4966A' }
        @{ Path = 'powershell\System.Reflection.Context.dll'; Sha256 = '55BDA313C0A1D36A9057A30E12300ACC6DEC56013B1D736B67ECFC9B30F14AAE' }
        @{ Path = 'powershell\System.Reflection.DispatchProxy.dll'; Sha256 = 'C41199D4EC8F99316777ACB3A0E1A77495E8CABC6DEC3C6D33D4D62C9D15E9F4' }
        @{ Path = 'powershell\System.Reflection.dll'; Sha256 = 'DED96D8E07AB41112DAEAB522AAE8C4DCE165DB82204FC8477BF3011F8AA41CD' }
        @{ Path = 'powershell\System.Reflection.Emit.dll'; Sha256 = 'C73A09E836ECB95EBA3974A75A0C365AC414D3610A7C6BFE9F2C7D1F1C1D3ABD' }
        @{ Path = 'powershell\System.Reflection.Emit.ILGeneration.dll'; Sha256 = '8FB6B6C5C4F57356BEB2D54F003929BBE6E544F4825F647E16BCE60482D4D5D1' }
        @{ Path = 'powershell\System.Reflection.Emit.Lightweight.dll'; Sha256 = '243CA3AF5366FF11E8DEBDDDA8D4D8ADA2A7B32EAEBEA6D405885FC3AD25D0A6' }
        @{ Path = 'powershell\System.Reflection.Extensions.dll'; Sha256 = 'EA1065AE7514302527642648EEA0C50652373D0992BCFF53263D6BA8FBBD4C1D' }
        @{ Path = 'powershell\System.Reflection.Metadata.dll'; Sha256 = '566E4A7BE8DE41DEE2ADEA2813CBD00DB9EA0CA11C3A893C8AE259AC73DECDFF' }
        @{ Path = 'powershell\System.Reflection.Primitives.dll'; Sha256 = 'F22FB791C511CBF9FB8948F209180D871D75D2C0038E6D46C9C31BE05CF7FD4C' }
        @{ Path = 'powershell\System.Reflection.TypeExtensions.dll'; Sha256 = 'BB11A380E9D1A4C7B76C9E4F2E4CB7CEEA0135883FF9C99DE5EEA45EA327C1A4' }
        @{ Path = 'powershell\System.Resources.Extensions.dll'; Sha256 = 'C49BD20EF0E30969138F95D846088522AD0C503A236795CAE38FFA0703024F94' }
        @{ Path = 'powershell\System.Resources.Reader.dll'; Sha256 = 'D44FF6B67734C7F08FF6AF2E7D978E08A83E9A69DEE9F78A30DD0546B4EEA131' }
        @{ Path = 'powershell\System.Resources.ResourceManager.dll'; Sha256 = '0114CC1936DABFFBA9FD1B1DB421AF09F39BCB61D1C69EC13D60C2672C376F34' }
        @{ Path = 'powershell\System.Resources.Writer.dll'; Sha256 = '2F65DFDAC3D5B61077F217A2DDD990527EB362DFB95F384C62D6575098B22E8E' }
        @{ Path = 'powershell\System.Runtime.Caching.dll'; Sha256 = '6196EDC456E12613806781A2789417734B951452E4658F7DD86AF457BBD59F25' }
        @{ Path = 'powershell\System.Runtime.CompilerServices.Unsafe.dll'; Sha256 = 'E757B9ED064137268E7CBC1D06A672C47F20D3649F05FC4357FAB7BC67205871' }
        @{ Path = 'powershell\System.Runtime.CompilerServices.VisualC.dll'; Sha256 = 'F2D1D57F1294DAA8319F664BFB0BDA4D858A4986557EC0F9F9E1BF16A61BCDE9' }
        @{ Path = 'powershell\System.Runtime.dll'; Sha256 = 'C4DA0C1560B0544637FD686A520FA04D62CDCB50979D59526B0B720E91A6096D' }
        @{ Path = 'powershell\System.Runtime.Extensions.dll'; Sha256 = '474F3B30AA33F8B3BD2B415E358786F965AD386D0C8CEF9C5E639EF9CA6B5002' }
        @{ Path = 'powershell\System.Runtime.Handles.dll'; Sha256 = '1C5A644ABAE05FB1669DD25C2349255D5142234D8E27EC1E27CBDF5DFC016F06' }
        @{ Path = 'powershell\System.Runtime.InteropServices.dll'; Sha256 = '46ACF58A1EEAAF93184664FB000F983F142DE97216B73CA7356458A5FD088E1E' }
        @{ Path = 'powershell\System.Runtime.InteropServices.JavaScript.dll'; Sha256 = '46015675FA87423A2B95ACF831DA74006BA7C41C5F4E119EEF249ACE04C15F37' }
        @{ Path = 'powershell\System.Runtime.InteropServices.RuntimeInformation.dll'; Sha256 = 'F78084963169DA431DF7D6084BB62EFA3642A580FD24E67A7F8E075F2AA2B089' }
        @{ Path = 'powershell\System.Runtime.Intrinsics.dll'; Sha256 = '10D1082E78F0E8C5C0CB6A63EDF3443F3337990943FD63FD8AE232B0B08739FC' }
        @{ Path = 'powershell\System.Runtime.Loader.dll'; Sha256 = '9E628D99C168C59A1CFB8855DF077FEF247B03BDB6F8CB73F7CEA9740AFA8C17' }
        @{ Path = 'powershell\System.Runtime.Numerics.dll'; Sha256 = 'BBDFDE6C7E17C70E9D3CCD0B2A46C7D83B964CA26F2C02FDCDDE73B4F2C52CC5' }
        @{ Path = 'powershell\System.Runtime.Serialization.dll'; Sha256 = '2423BA669466A6BF77A78929CBB0B4E1AB54C29DEFFEA07BF2B4DE58EAC06417' }
        @{ Path = 'powershell\System.Runtime.Serialization.Formatters.dll'; Sha256 = '2C724210B66E8E4DBF5879E8DD3DE186E1ECDF8972B46E35A5050839E80B980B' }
        @{ Path = 'powershell\System.Runtime.Serialization.Json.dll'; Sha256 = 'E021B1661CC471006E9BDCA4922714E58D4B2161177DFCA49B7D3C99813F0ADF' }
        @{ Path = 'powershell\System.Runtime.Serialization.Primitives.dll'; Sha256 = 'D7205B7776B354DB523E8BEA4CB050429E5F561DC11A230BE59D8F9D2A67004E' }
        @{ Path = 'powershell\System.Runtime.Serialization.Xml.dll'; Sha256 = 'D50510AC916089D4D4BBEFDAB84277563D6CC79F8356106B8490185884D5AD47' }
        @{ Path = 'powershell\System.Security.AccessControl.dll'; Sha256 = 'A6D6BCFC6D4F9B943B3E6C483D3C75C0781E456EA823A68C43243AA7062E1CF8' }
        @{ Path = 'powershell\System.Security.Claims.dll'; Sha256 = '635C4B54EABCC052EE9BFCDFB14E79C5D88CD1D85BA7023599DF955A5ACF9C41' }
        @{ Path = 'powershell\System.Security.Cryptography.Algorithms.dll'; Sha256 = '3D46E9751E0E212BBDF863377BB3BFF225D4F608E70A64B0B9DD62157F9C9B92' }
        @{ Path = 'powershell\System.Security.Cryptography.Cng.dll'; Sha256 = '3ACAD651ED77C9FD05FD34EA1F7F260ACAB5FF39EF6AA289F69568C26CDDF69F' }
        @{ Path = 'powershell\System.Security.Cryptography.Csp.dll'; Sha256 = '9184931956ED40D56F900910FECDAE45A3575146A631D32BB868B6C23FA80E0A' }
        @{ Path = 'powershell\System.Security.Cryptography.dll'; Sha256 = '628B24CA9BD80EC9712BC258B75D4D6098D6760EB2580A8FC92AF7396B458F3B' }
        @{ Path = 'powershell\System.Security.Cryptography.Encoding.dll'; Sha256 = '52DE7DB81D4D0D8CA11F85B358CC67835BE1C9C440A1C72A7E0CF483339D4049' }
        @{ Path = 'powershell\System.Security.Cryptography.OpenSsl.dll'; Sha256 = '3BEC4A0D8C948E613E29B58C4C4B58B763B9A32FB5E60F0233A76B88E39072B3' }
        @{ Path = 'powershell\System.Security.Cryptography.Pkcs.dll'; Sha256 = 'DDA174D0135B4EF08A72F978672662C4466730C7AC3D8308E7BA363B64766B9A' }
        @{ Path = 'powershell\System.Security.Cryptography.Primitives.dll'; Sha256 = '544C8DC1BF23B906A9CC79E4101495A63EF4EEB9B3B14115BD15F2043D5A5BFB' }
        @{ Path = 'powershell\System.Security.Cryptography.ProtectedData.dll'; Sha256 = '75AA002785F25B27901487132F07B7633DDB904CD6017C423576EA61D4B4BFC9' }
        @{ Path = 'powershell\System.Security.Cryptography.X509Certificates.dll'; Sha256 = 'CB7295D498270AE4CA8D01250A37C30758C30E353D5DAFE3DF0DA50E57848867' }
        @{ Path = 'powershell\System.Security.Cryptography.Xml.dll'; Sha256 = '8E385F0BE857EAC277A93C20723989483A20BE43E93557B3B384A68BDC9E6D98' }
        @{ Path = 'powershell\System.Security.dll'; Sha256 = 'B0E15BBAF31CA9D12CEE7B42D3C2DD52FF32F2B9ADB3218DE9B207E8A19DF81A' }
        @{ Path = 'powershell\System.Security.Permissions.dll'; Sha256 = 'BEDB8857FE35DE85D6BB3C1D8C2377449ADA443239B2C1D8C41869982625E2A3' }
        @{ Path = 'powershell\System.Security.Principal.dll'; Sha256 = '029669DEADC971B2F5C28925EDCF80A5A0D52692B6003EC7A958A9AD4D7E0879' }
        @{ Path = 'powershell\System.Security.Principal.Windows.dll'; Sha256 = '5DFAA106A4DC07CABAB0031641DC849C6ECD9743B4B94C9A4738F77BCA391F1C' }
        @{ Path = 'powershell\System.Security.SecureString.dll'; Sha256 = 'A199A9F3D2B254EA5577E5D71AE8D354B3EA84691B04D1914E5C97B783F375E8' }
        @{ Path = 'powershell\System.ServiceModel.dll'; Sha256 = 'CF390C8379F3249937DA11DAD3A5BA88804A7453503A246BE01FC849B899653B' }
        @{ Path = 'powershell\System.ServiceModel.Duplex.dll'; Sha256 = '5E7D8985922C7D7D673D2D204C2F6D12E3F70F70D0E9FF15507FECD2026A8815' }
        @{ Path = 'powershell\System.ServiceModel.Http.dll'; Sha256 = '7429CAC54300ADA9CA27D94CE01845AA4A1D412D0B6FCAAF994B37BD389111DC' }
        @{ Path = 'powershell\System.ServiceModel.NetFramingBase.dll'; Sha256 = 'DB80FB935617FC02B273A3D789DFE142AC2D73278F239DA7C957FD3AB1CAA7FA' }
        @{ Path = 'powershell\System.ServiceModel.NetTcp.dll'; Sha256 = '3A369FAC852E4FA5F0B8C97EDCFF4D41212C93A3A30C79DD77A226446BE20B27' }
        @{ Path = 'powershell\System.ServiceModel.Primitives.dll'; Sha256 = '139FFA4BF7F56741C941B18A80CC32D910F5C1AE1EDA4CE73F81AF22DF00C624' }
        @{ Path = 'powershell\System.ServiceModel.Security.dll'; Sha256 = '99EC51765CF53B36DC1064A48DB4C910EDB17C92E176E03B947E5E200B82F7D2' }
        @{ Path = 'powershell\System.ServiceModel.Syndication.dll'; Sha256 = '02573DCE973E7E6F190BA8ACEB1C50E52863D27245EAF81F66F0C7B105487B8C' }
        @{ Path = 'powershell\System.ServiceModel.Web.dll'; Sha256 = 'D2D7DBB89EDE4F8C141FBA269363249B5C0A4061D584CDD501EFC762A826B627' }
        @{ Path = 'powershell\System.ServiceProcess.dll'; Sha256 = '17E5CB2929CD5752A12DFCDBB7B6C448919B02BC2CDFAAC1BFB75081742E650D' }
        @{ Path = 'powershell\System.ServiceProcess.ServiceController.dll'; Sha256 = '295FA93D331F604D1AC1F79F09C8582DDD5F3E53A3385E4B0A905DB43227B786' }
        @{ Path = 'powershell\System.Speech.dll'; Sha256 = '3893315C76A0CEDEEC4C9E77A98AB9932AE4C17D88491063B3F23FB4576E3FCB' }
        @{ Path = 'powershell\System.Text.Encoding.CodePages.dll'; Sha256 = '707854F03D77177A1738185902ED4477A57DCEE8ED91CA99AFA18C241595470D' }
        @{ Path = 'powershell\System.Text.Encoding.dll'; Sha256 = 'D10190D75B6B364367F1A660283E4EB810C1FAB33AB3454DC3F76C79B91B4CB0' }
        @{ Path = 'powershell\System.Text.Encoding.Extensions.dll'; Sha256 = '793BA7BBAEC67A6056156E6D7136655262DB60FE79C85523DC6594F3966BF25F' }
        @{ Path = 'powershell\System.Text.Encodings.Web.dll'; Sha256 = '37367C6BBD7CB654B9636BDA44BD3FC284D096D3BAAAEDC915EFE099FC33CAE4' }
        @{ Path = 'powershell\System.Text.Json.dll'; Sha256 = '83EF4B51A5F3A208659DA10829B13900C1B64736E2B15C9207FDA6528BE543C5' }
        @{ Path = 'powershell\System.Text.RegularExpressions.dll'; Sha256 = '309789E6B22C1F63F4B60C7811168915D066B8A79FB39AF38036468B6366473F' }
        @{ Path = 'powershell\System.Threading.AccessControl.dll'; Sha256 = '900DA724D3B446FF862B8303E23BEECDB0016AB308AA5B9447A6048754C2F7BD' }
        @{ Path = 'powershell\System.Threading.Channels.dll'; Sha256 = '78B3E963EA2A702126FC5C89886A1B667188FFAF1E6A611C810D8A8C499108CE' }
        @{ Path = 'powershell\System.Threading.dll'; Sha256 = '012F962538912651FD8013FB460A646D3B5405BB632A66E2DAE833D9F7461011' }
        @{ Path = 'powershell\System.Threading.Overlapped.dll'; Sha256 = '6F21A71B91F6167FD971834499897DAF78645E5F011A72129EAF68CC476569BE' }
        @{ Path = 'powershell\System.Threading.Tasks.Dataflow.dll'; Sha256 = '01FC8103BDF3C59EECC28B67B80DCEADFE0303352503AC4E2E1158AB87A83233' }
        @{ Path = 'powershell\System.Threading.Tasks.dll'; Sha256 = '25D7A7F8856D61A6A09369D5729E1CEEC5715AB81F524F368DCEB9DE1645FA97' }
        @{ Path = 'powershell\System.Threading.Tasks.Extensions.dll'; Sha256 = '35742F2FC01C751EE3D9EF5DC6C61C4316E2F3C3B288509C6E1BC905936E9398' }
        @{ Path = 'powershell\System.Threading.Tasks.Parallel.dll'; Sha256 = '8E8280CD2A5371BF9EB26DFBA8EDB7104BB61C8E25B8B28583555716BC180D7C' }
        @{ Path = 'powershell\System.Threading.Thread.dll'; Sha256 = '0D012F93321425132B06B04C8E3F1ABD7BA260E0FCD30DA7287DFC69CF66885C' }
        @{ Path = 'powershell\System.Threading.ThreadPool.dll'; Sha256 = 'AB69B75113EF6518EFDBEA4227D2FBB21757CF8E8947E02E94276F52CAA7EAB4' }
        @{ Path = 'powershell\System.Threading.Timer.dll'; Sha256 = '23C9B9BE6C36C0EB2C0EDAC445AF20EDD37F11532E3986F3368BDE25AFB2FB08' }
        @{ Path = 'powershell\System.Transactions.dll'; Sha256 = '797845A138286F6FD7654C28A644447492E26379BF41843C13DBF2044DFFBC47' }
        @{ Path = 'powershell\System.Transactions.Local.dll'; Sha256 = '770250304D6F681B86AD1842CDABAC74E64595489FFF629E2B9799F853DB6E04' }
        @{ Path = 'powershell\System.ValueTuple.dll'; Sha256 = '300CD716F11B293328C0D98985A134D0EA35117497D0635A834F03001DFD0F62' }
        @{ Path = 'powershell\System.Web.dll'; Sha256 = '2644C0E088242E3E4871A0C0B94467381052F4DD87CA4B8476D4B71048AB7E6A' }
        @{ Path = 'powershell\System.Web.HttpUtility.dll'; Sha256 = '81459676C61D28ADDCF40976D830C42B590BE3A5AF995A5F3AB337ED738FF62E' }
        @{ Path = 'powershell\System.Web.Services.Description.dll'; Sha256 = 'A67F65E0EFA4D6A87E36A39EBAFF308BEDF1A16037EFBDDB378E582F274DE6BC' }
        @{ Path = 'powershell\System.Windows.Controls.Ribbon.dll'; Sha256 = '991DB42598D2EE7744D4FE369314EF7209AFC11FB1E24B09D21DDC62506DCF2F' }
        @{ Path = 'powershell\System.Windows.dll'; Sha256 = 'D6455D8DB1F449BA213F748D7D842DCEC90FE55D97A09E69D1F52815372B0C62' }
        @{ Path = 'powershell\System.Windows.Extensions.dll'; Sha256 = 'AD11D20FB36C17524AD3803E06A752D8BBC31F638FD8C27082F3D6CD9929D617' }
        @{ Path = 'powershell\System.Windows.Forms.Design.dll'; Sha256 = '1195610766253FE2632CF7E8017A773ACC3D7F419414F93A5A434268F0591FA7' }
        @{ Path = 'powershell\System.Windows.Forms.Design.Editors.dll'; Sha256 = '53B1461240152180A8ED1FE49A5F0CCC2CB8E48F4B2ECDED527042316668D9BC' }
        @{ Path = 'powershell\System.Windows.Forms.dll'; Sha256 = '7EF379C8FDFF1B9B084E5DC9A7123471621217662A8CFC08E3CFDF690A956D2E' }
        @{ Path = 'powershell\System.Windows.Forms.Primitives.dll'; Sha256 = '26485FE9497AD23D39BCF697F38A685E7EFEE231D6C0F0A42A879E3CFFB9625A' }
        @{ Path = 'powershell\System.Windows.Input.Manipulations.dll'; Sha256 = '6EA1D778B49C8A0864C2D5CED278DE92DB45DB65BECE7D2773C5667E3C9143BD' }
        @{ Path = 'powershell\System.Windows.Presentation.dll'; Sha256 = 'A33A9C2393180FC85345822F9A45831638E318C4FD31D2C52DCFA71287881F51' }
        @{ Path = 'powershell\System.Windows.Primitives.dll'; Sha256 = '926F0CB175FB1957FF7DA93C1C44C13BD7ADCA1BB71B8D4A1B56DAD757CB4235' }
        @{ Path = 'powershell\System.Xaml.dll'; Sha256 = 'EC5035AE24F5E2B267E3F0175B4F017095B37B0CEFBCBB12D7E635CDB1C0C36C' }
        @{ Path = 'powershell\System.Xml.dll'; Sha256 = '6B27D93B7F152C849BC391506341143562E32085975E57882EEB1FEC83C2C226' }
        @{ Path = 'powershell\System.Xml.Linq.dll'; Sha256 = '8629214FCB2A333303C92BDFE823A799AD681652A1B9B6B9BF9EAE4350CA5152' }
        @{ Path = 'powershell\System.Xml.ReaderWriter.dll'; Sha256 = 'B0AE475373BCE46900E17E8DAAFA57361F1132F2BE2BE80BD67B944952FDEBDF' }
        @{ Path = 'powershell\System.Xml.Serialization.dll'; Sha256 = 'DE53558A934ACB946B334D370AC608E26A424F959FE541A9468611ABD5F8ADA9' }
        @{ Path = 'powershell\System.Xml.XDocument.dll'; Sha256 = '26F9AC1AE37EB4B19D4228F1BF7BE80E37071459D3D89DAEB9D060D2654B9870' }
        @{ Path = 'powershell\System.Xml.XmlDocument.dll'; Sha256 = '244F16E8D20DC1DEB62AF0C4BE8B5E3E5971F32EE88DFB3E9A115D474599FA88' }
        @{ Path = 'powershell\System.Xml.XmlSerializer.dll'; Sha256 = '20F9764CB829A5B5C3ECCDB93178EC71B0FB4A97EDC7D8CCCAE565071ABABC20' }
        @{ Path = 'powershell\System.Xml.XPath.dll'; Sha256 = 'C992A681D669B012080CC358AE0B62F6DF3187B180499CE636BFFC9FF7FB23D2' }
        @{ Path = 'powershell\System.Xml.XPath.XDocument.dll'; Sha256 = 'EB9F615987F44A7E55F39C573A064507EEDBB651DA0E1980B0F01A220DBA3921' }
        @{ Path = 'powershell\ThirdPartyNotices.txt'; Sha256 = '5A2D792AA9DAE45DA7579398CA08C0FBB47D78C563CCE492E311B9D5EB9A2142' }
        @{ Path = 'powershell\UIAutomationClient.dll'; Sha256 = '187DAAD800A385ED06156F698AEF0943A9C28688C93AA3AD795ECECDFFEC3EA6' }
        @{ Path = 'powershell\UIAutomationClientSideProviders.dll'; Sha256 = 'D1366A1F068789C74C777D0C07C946D1E9C94969B5738EC246D646E63B1F5A99' }
        @{ Path = 'powershell\UIAutomationProvider.dll'; Sha256 = '740A4491CC664BA17DA0B2879BE34C45F9CAE8B09DBBAD70AB67878EE3216E10' }
        @{ Path = 'powershell\UIAutomationTypes.dll'; Sha256 = '478A6F0D94E468314143870CD2FF53DD5A2B4A2354B8E6C000E1213BBB9C91C0' }
        @{ Path = 'powershell\vcruntime140_cor3.dll'; Sha256 = '6231672430D731FBF685548BE155B1B7E6538E989E664E5DFEC1D65BDDE5F365' }
        @{ Path = 'powershell\WindowsBase.dll'; Sha256 = 'A21B4F4B76FFEB0F0FA64CF488951338D9EEC158B320AF88EC3D1A166616FB8D' }
        @{ Path = 'powershell\WindowsFormsIntegration.dll'; Sha256 = '421ADB405C5DC9837C7C505C6A7622A8D7D6474783424C2A74F675C8A538AC12' }
        @{ Path = 'powershell\wpfgfx_cor3.dll'; Sha256 = 'F88327832949440A6F9037592E19676D07BE9B018B912F8FD152E4D73D0E9D4A' }
        @{ Path = 'sqlite-tools\sqlite3.exe'; Sha256 = '1D4DBBC37396C5DE744E1A732540B8BC83CD89888F47E86365B726E5A813C5E7' }
    )
}

# SIG # Begin signature block
# MIImJAYJKoZIhvcNAQcCoIImFTCCJhECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDS35ALeoER9ngo
# nU/3cmOukT53O7CTvdDgWIcMq3kHiKCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYCzCCGAcCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD+6bFA0k8l
# +8P/zneKcVGZOXBe7vEqmk59OjKsoDYnvjANBgkqhkiG9w0BAQEFAASCAgAIqP4Z
# 0GOXnds8ZE8xwKDETSNof89mRdwH/iv13hndV3HofGUVzyTscO629tW83IT8ffx3
# /d/yKmzfwlRzbzy+U5RmYzwcfJHbbed4w4wvxJK7zcOVvmEibvipVTMzrMk/jVEx
# d5WQ0zg7LFRwKOsz5VDcgfwuWhy1ItKvwj6b7VSbzGh+sJpfIKd6QV4q2zXhkVb3
# RQxjoPC09zbx3bF5U6aotJIxjHcl3h9IHYbIzCXJfi51MbDy4v81tGctzOJJS+ZS
# XaYsPXCt7yjnzVo62ObwFg+BizwOcFE49nAxm1dl7YBSIsQs5g/PYl2x06enodrQ
# nkOThgq+FOBacDth6IJxR1tsthLQ9+37leupTSxsuFubEujCtTzmf07+gPeUYok0
# efnIoV5eolMzpNL7WERV6j3VzkPATU3iX95Grqqs0FR7bU8UmzF5qtjHR/qQW8ha
# Ep1Vrg5CmsOQ3w07FF0IXt4TWPlDoEynoJ24IXRmENPqa3ibycHRuzVefO/l0LC2
# visYQP7nU3Xzi564SHCMy80Be/ZVFx599K7uBhk71tcXseODI7KCr3lQiBRzhrPS
# hRLg4Kiia+gTlchTqN6MZJX9I7uVl+zijFbn39Ibg/xTkhNdPlDIyYZmTjc3JJBM
# FX6tQe/55ktHw7aRg5nGWsFHyo+PeqFTtkr7o6GCFMgwghTEBgorBgEEAYI3AwMB
# MYIUtDCCFLAGCSqGSIb3DQEHAqCCFKEwghSdAgEDMQ0wCwYJYIZIAWUDBAIBMIGC
# BgsqhkiG9w0BCRABBKBzBHEwbwIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIDr6DEzPOJF/YUTxrKI7mqypQDahwkZNA5EwJhiTlzcrAggdjCiKCdgY
# HhgPMjAyNjExMDMwOTQxMDlaMAMCAQECCQDxVrgTesX/fqCCEacwggTzMIIC26AD
# AgECAhBUQ/g3vVruGAGEcrhc2o7jMA0GCSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYT
# AlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwI
# U1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0YW1waW5nIElzc3Vpbmcg
# UlNBIENBIDIwHhcNMjYwNjEyMTcyMjQ2WhcNMzYwNjA5MTcyMjQ1WjBuMQswCQYD
# VQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNV
# BAoMCFNTTCBDb3JwMSowKAYDVQQDDCFTU0wuY29tIFRpbWVzdGFtcGluZyBVbml0
# IDIwMjYgRTEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAToJYu4ZhMuSJI48ws2
# yQ4G2FewiFFIDjp945DC9ItwNo2Hq/FTMEoTHUp0UFEWzs4eucf8rRUDoxsNAgWl
# SDQ9o4IBUjCCAU4wHwYDVR0jBBgwFoAUcJplwUOAo/zpsWSJbvEwnAkhyXwwTQYI
# KwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2VydC5zc2wuY29tL1NT
# TC5jb20tdGltZVN0YW1waW5nLUktUjIuY2VyMFEGA1UdIARKMEgwPAYMKwYBBAGC
# qTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3Np
# dG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwQgYDVR0fBDsw
# OTA3oDWgM4YxaHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29tLXRpbWVTdGFtcGlu
# Zy1JLVIyLmNybDAdBgNVHQ4EFgQUJ6wDVrooaroXO4M9QH95qCTswzwwDgYDVR0P
# AQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBPdm7O/AOewhlNcGf6GOa4FeDM
# HXZ9tjFP25h7pm+G+ltlYpzINCBpwROQ/DyTrJ6qdgJjIVnTreUw8SoCEAPacwbr
# XhmHs+0db0Nap+yCK/Fs9gF4363tTGCRhPd7GltYx08SoG1ZXIc68twq8zGAlZ8m
# MA3BWTBUN+TL+Ptx/bz6KKY3w8pztL+7z8t6dFGdXZbZh+dxGeTP0J+zmdEPNpmC
# 6IeuunYbHCCc1BIfgYGMc6Xc/MuydVsahkqLhkSOBe6mziYYY4rv4YHYcCVCf45L
# 3jhweqWQfSASW3ZZ7OgI1GkQumH2prG4GeNISpdZZ+ATrIYHA7S7Eo2qlZVMeYDC
# vpK8E+h/G5tci4Sf2K9HgIs64DFRKsnjVkGD+qobSgmMXoaREpvGrtzJZKQRlgmG
# YoKDYeDl9cdqA7GLBuafkk9nW+FYKtuTe/91PHaC9Mrn56sLkf3+tNyWNQjvvrJ3
# at+GN+Sm/ICxu1ezgPueufDyL3Civn5921FIkFXGrMubKQV+2gvRSnZD763IoJR2
# uJt1yesHgcpLez63cCN1xsDToMIvwaJ9CL18vTJEFE2UDijoE/5KvvnkxoI2NRFh
# kO8PLEkcEFPtyqNkjCyJHyz7rzrSegVsEG12B7YjDsI8L/VDfUjbuFWiVLsHTJqj
# e/xfYy1bLeaxmVdNwTCCBd0wggPFoAMCAQICCHssm9MWgDKZMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0aW9uMTEwLwYDVQQDDChTU0wuY29t
# IFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkgUlNBMB4XDTE2MDIxMjE3Mzkz
# OVoXDTQxMDIxMjE3MzkzOVowfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFz
# MRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAv
# BgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0Ew
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQD5D92jK33L0Cr+7GeFpucu
# G7p34eP1r6Ts+kpdkcRXR2sYd2t28v2T5D0PwhaeC2bDVpSeF4OFzlbv8hb9AGL1
# IglU6GUXTkG54E9Gl6obyLhuYl5psV/bKgJ+/GzK80HY7dDo/D9hSO2wAxQdEA5L
# GeC7TuyGZf82815nAgudhlVh/Xo47f7iGQC3b6FQYnV0PKD6yCWStG56Isf4HqHj
# st2RMasrHQT/pUoEN+mFpDMr/eLWVTR8GaRKaMeyqNO3yqGTiOvBl7yM+R3ZIoQk
# dMcEPWqpKZPM67hb4f5fJao0WMjBI1SdG5gRwzicfj2GbKUPQIZ8AvRcAk8oy65x
# nw86yDP+ESU16vy6xWA92XwY1bKp03V4A3IiyjrDH+8s5S6p+p4stlFG/a8D1upg
# aOqFFjZrhekewLPdxCTcgCqBQW2UPsjgyYFBAJ5ev3/FCJiiGCxCQLP5bzgnS06A
# 9D2BR+CIfOoczrV1XFEuHCt/GnIo5wC10XTG1+SfrQeTtlM1Nfw35MP2XRa+IXPe
# kgr4oGNqvJaSaj74vGVVm971DYkmBPwlGqYlacvCbcp84llfl6zr7y7IvNcbWTwr
# zPIZyJNrJ2MZz/zpJvjKcZt/k/40Z4ROmev8s3gJM3C6ZqZ27Rtz6xqlDcQiEyCU
# VgpOLGxOsf3PnAm6ojPthwIDAQABo2MwYTAdBgNVHQ4EFgQU3QQJB6L1en1SUxKS
# le44gCUNplkwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTdBAkHovV6fVJT
# EpKV7jiAJQ2mWTAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBACAY
# EZQp+yadHB4ecGHxlXKTcSStaJNYjjKvG7NwA/wlK3SFkD14avS5i6WXO7UYkbse
# p/lAW5H5VZmvHhHQXB2nZuOxlAcMMjmm6huwedgdnHBE44rdxPmVH4o4Qz8BhaVH
# pz1GsrzlImj3e5zYLD4KIcgtM6y/xYGZMXTBdXHFvrHwI0X0nWv8GWOdo7wExhgL
# JbtTiQ+zgFDeRe5Ef6uUeGSY0/Yo3YfYcGV0+w65E+unD2GpMpbM3rvtY0wYu6lA
# 96BUbiCIcXUY6nq0NHLgIyd3XLaQ6oYlQKvvMw/Ln4K+oiD79rUtGubChbF0D/vI
# ZQKkUgFH3Ukiwb/Y62usft7sYzMVtyMIj8YPjUFa3Y7FuY/lRT9427rSG0Cx/nFN
# P+CBorpetOwV4JPdCB9+4VWZCyHek54K++ajSb02MP7nd7KgdZe1LYGIF2Ug99qQ
# AJ/JUswyyjV89T0P2CvX9SZsyQY0lhbqcFkaMnl5C7aIfw9SSD2/bNiiRC7RTrdy
# WNOJE5X+RKv414sbbpy8LKBb1WoAr1834dX6EAuYnIbnJo/O8OxuilcLgONOssCg
# Y2GQulVoN3RqtpLbn6GGIrZlJw7stp9CYORnwrXaQQvE04thG7z6H5Er10QHXrop
# rNnF6e9TSFrrgPEoWCHNsAZV+yc/U5BwqQQeVye5MIIGyzCCBLOgAwIBAgIQUp27
# wriJh/WDgOCw66IGNjANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwG
# A1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jw
# b3JhdGlvbjExMC8GA1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0
# aG9yaXR5IFJTQTAeFw0yNjA2MTIxNjQyMTVaFw00MTAyMTIxNzM5MzlaMHIxCzAJ
# BgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8G
# A1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0YW1waW5nIElz
# c3VpbmcgUlNBIENBIDIwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCf
# L6vmc02QvDFGmzYHeVpQY1T3Lu9aInnTXfJ/SJfPrltB3Br1uOPyX9KR5eocap9K
# HYWhp77zQTyYMR/3egjCOzLYJfZxeYrGq0XwckZgHh/rJGEoQPnTCRs7KwvTYhd/
# 78RmdrjiN9+GFXPg5T+TnbFD8+ciD+4WFzZaT5Jz8IeoCv6VhWQ/PsvLlGoH1/VE
# oav0kLftbUuBV0cLnR00h2xrdBc+GW1hm5tHeekTgFt+LSOhRbmfk7RrLB43jlH9
# hUvEDRgaWnU4dV9WeyperxuGfDUtziSMnpc6BeU6XD9rzN7ntO9t25mXd6F7BOa8
# 7QCTL+eo5YNL0g8/F3F0bq+msFtK4eXE0A0EBsdOIWCR9mZ/R1liVP8CdkigXECr
# Qcgs+iV/g6BaARPvpKJZKWbZdhEhfBWOl6obSmW9fBEhAHNKIQmPtB5AWcK8fHiB
# Awg283f7Ib/WvGERtqMa97S1M/eVfg884dUATRAmnhnM8jVhgmSFVGuJVXFVFTgW
# yDgE/A/oj5guYdvW1nhEvA4U0uH+AlgOA+UKEKjE6iAXFeDA9lmsPIRFgHRp457F
# bQ4ppw3hFG71yoXYoq78BvkAvt5gMtUZQ+sQTJhsgwClUqql5tzT+MNCeIL7euRq
# 5ECOBVzybWKn8JCAbUPDhn26VVEBj1VHplrbouxNtQIDAQABo4IBUTCCAU0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTBNBggrBgEFBQcBAQRBMD8wPQYIKwYBBQUHMAKGMWh0dHA6Ly9jZXJ0LnNzbC5j
# b20vU1NMY29tLVJvb3RDQS1SU0EtNDA5Ni1SMS5jZXIwPwYDVR0gBDgwNjA0BgRV
# HSAAMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9y
# eTATBgNVHSUEDDAKBggrBgEFBQcDCDBCBgNVHR8EOzA5MDegNaAzhjFodHRwOi8v
# Y3Jscy5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY3JsMB0GA1Ud
# DgQWBBRwmmXBQ4Cj/OmxZIlu8TCcCSHJfDAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAGUUW80x6YDqIGIFijnogpCNaFa5Bpgq6jiql/Qok0REC3WD
# P4ewDZIvfED9X4QDxJE80/1K9fSKz7mYOymli+krJgapg/fpgVbSZsXUXRm1fG6Y
# JRQ79lXmYE0oN/lDg9jtBvR5YB6lRzSs0mv8y+flmJd8k/ENvbGZyDxpEPrnb+ev
# 46uTZQE/QTjeIl0jgsXtWzb1HdIZEthk7EzXkMjhB5uwpGXQoOV/g6ZgYIpzu6ZP
# GJuRm03ULUpaCd/2Np1T8nCfJJpgQGDHr+/4VULpIY43OJjtNy8j0xX6pjEdQ+U6
# boBpA/Z1LhuNZeebzqV0JtSTG04AK6ZJ9P3vTvsk2JVrs9nUgGR3/Y8TUALyCztT
# 79iTUE31dE8iLXmT+4DXEX2h557koaPKIYqSohPtbxCSBRPnN4KKcUqRwpp9kxxE
# 5JVile2a1CoYZHaDi49ionQrWGazqAlese3/finwz0+tXyg1Z7RmXUSsMy1ed1SD
# eqEkvikDdlSWjvDmUzmaX4DuKOv/caTa/hBGgN4TZKGZNd0eC2qjwv99PXX2ZhwR
# PJwTY1gZFewGXc3SvMOwdGvw/dOumuqFGtfTiJLQ/t5D6UPGBLfKEafc7NYaEO30
# Z/bHWp7T+p2EUBU6RfHMxnPhRq3rGwB/NfT7+bwYQpbk6PD8dj6Qu9XDNI87MYIC
# VzCCAlMCAQEwgYYwcjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO
# 4zALBglghkgBZQMEAgGgggFgMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYxMTAzMDk0MTA5WjAoBgkqhkiG9w0BCTQxGzAZMAsG
# CWCGSAFlAwQCAaEKBggqhkjOPQQDAjAvBgkqhkiG9w0BCQQxIgQgcernmf5qsG1Z
# VzRSDNOECqTdYvnjhQogfv8T7KuOdcUwgcgGCyqGSIb3DQEJEAIvMYG4MIG1MIGy
# MIGvBCBXT+oXqvpefGormwjJmLFzXkULOHPKROaiTKCTDmPzsDCBijB2pHQwcjEL
# MAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREw
# DwYDVQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcg
# SXNzdWluZyBSU0EgQ0EgMgIQVEP4N71a7hgBhHK4XNqO4zAKBggqhkjOPQQDAgRI
# MEYCIQDopqHjoIkLhrbZK2wH3XomhFW+LuPx3s1CjL1j+3g50gIhAIvhWPxuXL56
# 5Z9VdjaIRwX6InyNy8rYeB+2OkZQxaJ5
# SIG # End signature block
