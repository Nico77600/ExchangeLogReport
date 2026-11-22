@{
    SchemaVersion = 1
    Algorithm = 'SHA256'
    SignerThumbprint = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
    Version = '3.1.0'
    Files = @(
        @{ Path = 'CHANGELOG.md'; Sha256 = 'F87EED54A9DCD77F7CAF1279F47BC370EAF96FA2E9D4AFB6AD572FBE24A01546' }
        @{ Path = 'Database-Storage.cmd'; Sha256 = 'F7F29B9185FB1FC0852B2369F17617BB3BE2BAFCD6482061F63FD984C8C49A6C' }
        @{ Path = 'Database-Storage.ps1'; Sha256 = 'EFFA1005F3FD549A12BFAF0D51A55AE21B4AF61BB65E6947420A34504B6974DD' }
        @{ Path = 'docs\ExchangeLogReport-Guide.html'; Sha256 = '7E7CA38DC0355415D90BC534CA504CFBC436BBD7776EEDFC95F3180A46C5D993' }
        @{ Path = 'docs\ExchangeLogReport-UserGuide.html'; Sha256 = '2872254164ADD0B1E9A5B04701502074922E1F71C21D5A599949046166DF17B4' }
        @{ Path = 'ExchangeLogReport.psd1'; Sha256 = '0B42BBBBDF66C2042A14FFD7F3F692A4BCB151351137185C31F7277182BCD4BA' }
        @{ Path = 'ExchangeLogReport.psm1'; Sha256 = 'DB3FE86B5D40A00979DDFCDA7A0A528B30B40B433567E3C8653297EC4D8EC874' }
        @{ Path = 'Invoke-ExchangeLogReport.ps1'; Sha256 = '478FBE1EAFBBFBF436501EB97D5450D78E66585F9277EC7D4A1B498C63A6961D' }
        @{ Path = 'lib\sqlite\Microsoft.Data.Sqlite.dll'; Sha256 = 'B98D957462BE432895B00DCCCA012D3C127E118D3D4262418014B92C7BBD66CF' }
        @{ Path = 'lib\sqlite\runtimes\win-arm64\e_sqlite3.dll'; Sha256 = 'E3D17B136B58E9E3F768F97DDB406CFF3595632126371AD97546BE368603BFF6' }
        @{ Path = 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll'; Sha256 = 'B082E8A72AD4CE908234EAC970B09B7D328D16157CEC34A3EBCCFD9DFE2221C6' }
        @{ Path = 'lib\sqlite\SQLitePCLRaw.batteries_v2.dll'; Sha256 = '29C9CF3060789066682BA5FBF81DEA584563E6AB60B5D9861C73BA8B29ED1142' }
        @{ Path = 'lib\sqlite\SQLitePCLRaw.core.dll'; Sha256 = 'E60E22452BA79C306A59ECC01A97C29BAFE69D9FA612F40253852ED450AD27E8' }
        @{ Path = 'lib\sqlite\SQLitePCLRaw.provider.e_sqlite3.dll'; Sha256 = '35A7FB876526E1F1DE65D6FD8938F82DBC8E00EFCCD0CA58F364C68C26BA08A3' }
        @{ Path = 'LICENSE'; Sha256 = '58454E0F809A2CCB776B41855D27BA7581AE1AC1289F499341205FF4B829C3F6' }
        @{ Path = 'product.json'; Sha256 = 'E251F927F48F4C7B84ABA34D54B45D6302A4162253704517CA9B4926254695F8' }
        @{ Path = 'README.md'; Sha256 = 'CB22CB141F0769A6EAC08E9A649FA297DFD5B0779E22E61630A5E15D1C9E0B0E' }
        @{ Path = 'Run-Collector.cmd'; Sha256 = '277E757A6F57BC9AA6A0480D35B825015B57AE23E6EE81F7818A8FC907D647B6' }
        @{ Path = 'SECURITY.md'; Sha256 = 'A756A854B5E106D63B2FA6E63F59E5F2761D4AD52D7E0B1F56018998317790C7' }
        @{ Path = 'sqlite-tools\NOTICE.txt'; Sha256 = 'C0BB1191252301D1F5BE0BE6808215D2541A68664904712F345A764FDF9DC658' }
        @{ Path = 'src\Engine.Collector.cs'; Sha256 = 'A8CB684E3B32A72494D521F0DEBDBB73FDA2F120E11002F72C58EA25EFB75387' }
        @{ Path = 'src\Engine.Mail.cs'; Sha256 = '16296437F62D99A7B19A1BD492F9F80E6EECCA18636F9752169A059BC17CC8B4' }
        @{ Path = 'src\Engine.Pipeline.cs'; Sha256 = '3A41F817230D215B0060ECCFF2F3DD7D2E5489CB338DE678D6994E9351B49762' }
        @{ Path = 'src\Engine.Report.cs'; Sha256 = 'F9DF86D9E2E378997C27C9DEE8BED234D93200E9EB8812824378F9BBE1F80805' }
        @{ Path = 'src\Engine.ReportExecution.cs'; Sha256 = 'DA7F8CC62D4467DB938C365851B33A8E5E9E760FA81A714E4415D662F2862181' }
        @{ Path = 'src\Engine.ReportHtml.cs'; Sha256 = '2F7512ED767BED502648879A809152BD8FEE01993BD7C1C42ADC7F608A3333EA' }
        @{ Path = 'src\Engine.ReportRoute.cs'; Sha256 = '497B22571734EC22352B061E983479F5754C15159E9175BE68553578524AA6FD' }
        @{ Path = 'src\Engine.ReportRows.cs'; Sha256 = '6BA61AB23E98C57BAD855C977CFA7517202E6DF4143880584D08CA77B50F3308' }
        @{ Path = 'src\Engine.ReportSessions.cs'; Sha256 = 'C1098BAA448D5F1D2E8C605D3469A29C6989E8A1D283E369574AFC93A7CEEF41' }
        @{ Path = 'src\Engine.ReportTranscripts.cs'; Sha256 = 'B5F87D39B2080D25BE6ACB23639204BCAB5A2287B21FCBF8D43A525C8287A57D' }
        @{ Path = 'src\Engine.Serve.cs'; Sha256 = 'B4972DB8D8AECBFD60B58C17D5A758773C4726D4A4CA0429D25593CDD3EFB43F' }
        @{ Path = 'src\Engine.ServeAggregates.cs'; Sha256 = 'A63B6EA5F2AD28D97C5A615C33515C8CEDA116E776C42AA7B9EFDC1183A2CA0E' }
        @{ Path = 'src\Engine.ServeDiagnostics.cs'; Sha256 = '0C06A74853572F565852780E8A68C48C028453A5148A0AE81C9A9F2E220C2CFD' }
        @{ Path = 'src\Engine.ServeFilterExpression.cs'; Sha256 = '4F1E469DBE8ED8AA16056EBE052D23FA79A4A668C3E523773EDAC7AA2C245B52' }
        @{ Path = 'src\Engine.ServeQuery.cs'; Sha256 = '44584E84DFE9B0B23A9E2A75B610A2F0B5F55500551A8663BD2A3BD959C31F75' }
        @{ Path = 'src\Engine.ServeRollup.cs'; Sha256 = '79FDC340E68C97123C3ADD5BF83AED661E196552C463DA0B21978FF3CFB17003' }
        @{ Path = 'src\Engine.ServeScan.cs'; Sha256 = '1745C0E2FC48F45E2C076FAA1F4DD3DF7FA5A3C3E3AD2E478C4218D422694248' }
        @{ Path = 'src\Engine.ServeUsage.cs'; Sha256 = '465C02848A39886797DDD67CD709986694A18FC9DB8C2AA00E04A82BD4A165EB' }
        @{ Path = 'src\Engine.ServeVerification.cs'; Sha256 = 'FC3E47045CF0F80ECFB071CDC8E80BE85C0773F53929D5467735898C85D4B8E8' }
        @{ Path = 'src\Engine.Sessions.cs'; Sha256 = '0159DB4734D67CB7C960BA7ED421798E62B4DE4F62834FC4125D03AF300BB653' }
        @{ Path = 'src\Engine.SmtpAuth.cs'; Sha256 = '1A9D34BD0783A4918B02ED4EDB45957DFDC070199073A1BC3847287AB8C7D618' }
        @{ Path = 'src\Engine.SmtpClients.cs'; Sha256 = '007BDE84010BF928B3D31DA6A179674A0A8C060C022511BCBB35365D43194A47' }
        @{ Path = 'src\Engine.Store.cs'; Sha256 = '14B445725E934745725595E92F294690F5C29C00D29CA1EF90C59F6AF37B4539' }
        @{ Path = 'src\Engine.Text.cs'; Sha256 = 'B02792D2B056E3FBE0D8653487E1546185C7CA19E59FFC830F6FD9FEDC05C099' }
        @{ Path = 'src\Get-ExlExchangeSettings.ps1'; Sha256 = 'C3D183A09B681FD1BE94C733B0CDEFAE0EBADF0B8A70A6942B084EDA0002571F' }
        @{ Path = 'src\Storage.Audit.cs'; Sha256 = 'E4A0EFE76A64BF284146425C98229C0FFAACCE01E32A1F88753C486F9D4FC854' }
        @{ Path = 'src\Storage.Cli.cs'; Sha256 = 'E374E958838EB67C68393ECC86CA909B0150D17DE95380F7D7671257EE0287FB' }
        @{ Path = 'src\Storage.Fingerprint.cs'; Sha256 = 'D8CC02EAE902D8D284815A13628C4FE8E2311B561FCA76E361FE1F988939068E' }
        @{ Path = 'src\Storage.LegacyRollup.cs'; Sha256 = '0E527E177F08D9984D70B3007C1F447CC5D25E950376549887031518FA3BD7FC' }
        @{ Path = 'src\Storage.Maintenance.cs'; Sha256 = '051E22C2127921B123A622C1E14C0F3C37687CD2E3D3241B2C665918C6DBEE93' }
        @{ Path = 'src\Storage.RollupVerification.cs'; Sha256 = '40D42D677655EEE09ACD6601BB943AF1EBB4460E2A527CC7F2069C2DBFE702EC' }
        @{ Path = 'src\Storage.Safety.cs'; Sha256 = '18944F85430A208F2E99B44C52D90D280B0A965D2B97373A7DA47551B0D78EB4' }
        @{ Path = 'src\Test-PackageIntegrity.ps1'; Sha256 = '9F981548BB2E49F7A225186EBE158BCC8E58FF8B19F47E52EC51B8F79364DB18' }
        @{ Path = 'Start-Portal.cmd'; Sha256 = '0FD6C04D1ADA74137A4D8A997EB3B28901EBABFA58A9C3A2EC2201C5D512FEC9' }
        @{ Path = 'templates\Report.template.html'; Sha256 = 'A1FA02790CC2AA69E3672C915BBCC50D77AEE16C914B7F8213BB2A3351F34729' }
        @{ Path = 'templates\Report.template.js'; Sha256 = 'A1DF99131ABC32F575280E91C620797612E10EA64ACDC2AFE06C66D9A90C03F3' }
        @{ Path = 'THIRD-PARTY-NOTICES.md'; Sha256 = 'C2A861045C29BDCDD9484E6B8EDE443966C02460F1BF1A594EA8AC894AE3F049' }
    )
    DistributionFiles = @(
        @{ Path = 'powershell\Accessibility.dll'; Sha256 = '88ED9AF391301B919B254C321A7081C50E78485E57F1725878459322D3C3AFDB' }
        @{ Path = 'powershell\build.manifest'; Sha256 = '07368749F01394E1FF712194D4732A7691699DA25E17C0EB445688784E605F2E' }
        @{ Path = 'powershell\build.manifest.sig'; Sha256 = '2025D032FBC003EDFBC8B4C39EE57964E9A4BB9CB100346E5CDB8CE224423E5B' }
        @{ Path = 'powershell\clretwrc.dll'; Sha256 = 'F25A11D20B069B3BAB1279CFEF14D46C058BC2DFE8D2FE8FE8D74FEFE52448A0' }
        @{ Path = 'powershell\clrgc.dll'; Sha256 = '20A907670CDF3162D9B300914991D10BA28FC3C6B704377B58322C2886D9B8B3' }
        @{ Path = 'powershell\clrgcexp.dll'; Sha256 = 'B574745F1CEBAB1A7479B184A0299A5E284508F4095C7C0AF72651DE80461C53' }
        @{ Path = 'powershell\clrjit.dll'; Sha256 = '22231EC740134103C575C7869B060B4BA2250B4AB9B5F964B93E94298B53A1E1' }
        @{ Path = 'powershell\coreclr.dll'; Sha256 = 'A6988FC77326C245873986446DE4F15218DF929664750D333CB2D42486C071DA' }
        @{ Path = 'powershell\createdump.exe'; Sha256 = '5161F24CCBE3AF9FF224CAB8D667F87920A58136DD045B054999E19AC29004F3' }
        @{ Path = 'powershell\D3DCompiler_47_cor3.dll'; Sha256 = 'FF9ED4CDD8C76AB9FB4A218998CD27063FE0A1949704E5A5A449DC60B5373713' }
        @{ Path = 'powershell\DirectWriteForwarder.dll'; Sha256 = '43D9D2AC0BA4F67B5E0A1BF08F5E247ED44BADF5227B1B3DD85B2BF962C7CA24' }
        @{ Path = 'powershell\en-US\default.help.txt'; Sha256 = '5AD33AD117ECD78AD5E84AD745E69D45E6A6A10E68A0C7333C2CE95E102FD602' }
        @{ Path = 'powershell\getfilesiginforedist.dll'; Sha256 = '153EEFB2EAFA8B2B909854CC1F941350EFB1170E179A299DE8836B8EC5CE6A7A' }
        @{ Path = 'powershell\getfilesiginforedistwrapper.dll'; Sha256 = 'B2D16F930CDCFF0F5777B432D56130CDF9F57C57A5B0BB671AE9E9B6F841F19D' }
        @{ Path = 'powershell\hostfxr.dll'; Sha256 = '2C14E9B4A540D98971B60CBAFFCDDE4F22328BD24BF75B68AA9E6BEE13C2CA25' }
        @{ Path = 'powershell\hostpolicy.dll'; Sha256 = '20405152B719CCB8D4E0361F3259DB8875D8D4F3C97D1FBEA4E1CA6CC6D21902' }
        @{ Path = 'powershell\Humanizer.dll'; Sha256 = 'AD2F0DFB42146B3F5D4621289D0344D912523809E940158AC2656FBB3ECD39A3' }
        @{ Path = 'powershell\Install-PowerShellRemoting.ps1'; Sha256 = '5E9DE96AA18D3421E52E16B387B1E65463CD5D09983DF0D9132A4614F0551209' }
        @{ Path = 'powershell\InstallPSCorePolicyDefinitions.ps1'; Sha256 = '8C999EFE3398841938B9CFEBC84135668C1A8B16447688BC7A03FC20211150AB' }
        @{ Path = 'powershell\Json.More.dll'; Sha256 = '810446860710D003CA8DC79709DFFAC6093C1EAC346F733049357C2A6C9DDE26' }
        @{ Path = 'powershell\JsonPointer.Net.dll'; Sha256 = '33C996DF300DCA254556A5751D0B1B56A3D71549AF757E131278DE46E3EEC992' }
        @{ Path = 'powershell\JsonSchema.Net.dll'; Sha256 = '596FAF06D24BEDEAEB936AB034100B60F08931449BBA6130D896BC7A4641C8BE' }
        @{ Path = 'powershell\LICENSE.txt'; Sha256 = '296604F12546653ED97726DC5FC2F3945D4CCA1F07ABD2589F531647177B06FC' }
        @{ Path = 'powershell\Markdig.Signed.dll'; Sha256 = '27337080B4D381B8516D3F5187820407AD6807A456D7DF2FDFFF8D8FD94E9A59' }
        @{ Path = 'powershell\Microsoft.ApplicationInsights.dll'; Sha256 = '2D5DB1533EF37F3C81194D8EBFDED2CD3005BEB020604B3C10C4AD2D1A81A875' }
        @{ Path = 'powershell\Microsoft.Bcl.AsyncInterfaces.dll'; Sha256 = 'EB0B687D52F9B13285C759E517F7612458D39AAC667795B9F77A1A1C4E1D68DF' }
        @{ Path = 'powershell\Microsoft.CodeAnalysis.CSharp.dll'; Sha256 = '350E40B634E27D5CC090532654D97F2EA7E0575122C5A2ED35ADD40A5DD16334' }
        @{ Path = 'powershell\Microsoft.CodeAnalysis.dll'; Sha256 = '486F04CC9162FAB717C97E443030761A25D82E183C1C845B3241F6FA2324EA0C' }
        @{ Path = 'powershell\Microsoft.CSharp.dll'; Sha256 = 'B48D497A3EC9EF5CF7FD1EEAF01E6F77673D8852C9C04A25B3B513B09E1F1C0B' }
        @{ Path = 'powershell\Microsoft.Extensions.ObjectPool.dll'; Sha256 = '9DBB7C211BE66DD42A5212A11E98FBF870B6D152554A63DC98AA5871120365C8' }
        @{ Path = 'powershell\Microsoft.Management.Infrastructure.CimCmdlets.dll'; Sha256 = '60D9F269798DF4B2380C53959F9D1235443EEB281CAB26D3F48F9BC56613F9BD' }
        @{ Path = 'powershell\microsoft.management.infrastructure.dll'; Sha256 = 'EF20875F2D304959D71FE286D3443EA6865FF7E289F305A7D1A654F563A72C55' }
        @{ Path = 'powershell\microsoft.management.infrastructure.native.dll'; Sha256 = 'CBBEB01F4F7DE85BFFE20CB51A21188E1AE6DB108A9F282E7EBDD62365FD4308' }
        @{ Path = 'powershell\microsoft.management.infrastructure.native.unmanaged.dll'; Sha256 = '9BEE4E35576355156F00E2E47EF57AA2C8CA64390C112F083A772F2219026293' }
        @{ Path = 'powershell\Microsoft.PowerShell.Commands.Diagnostics.dll'; Sha256 = '16C48C4A7C44FFF1D736E5860C9811B1A0CBE8E3303F935466E235D71504547F' }
        @{ Path = 'powershell\Microsoft.PowerShell.Commands.Management.dll'; Sha256 = 'D4A12685486505BA637DDCBF0DD2B8DC70690E0EE863BB33DB10275BEBE7763D' }
        @{ Path = 'powershell\Microsoft.PowerShell.Commands.Utility.dll'; Sha256 = '6839C773FA6970B54A1954F35202A15E98A8CA1A54B17D13424C671300DD18FE' }
        @{ Path = 'powershell\Microsoft.PowerShell.ConsoleHost.dll'; Sha256 = 'C67863FBBF70E3DF8C3F5570C2F8F91D53B807AE6F0A43D202850BDB1A5F5204' }
        @{ Path = 'powershell\Microsoft.PowerShell.CoreCLR.Eventing.dll'; Sha256 = '44F83171BBF9AE4D0A5A9C944F62450FAA197C29308C9A846304150A5217A74D' }
        @{ Path = 'powershell\Microsoft.PowerShell.GraphicalHost.dll'; Sha256 = 'D2060249304A8EEA338142D49A7766433174E23AAB113A7A21196C24FC077078' }
        @{ Path = 'powershell\Microsoft.PowerShell.GraphicalHost.dll.config'; Sha256 = '04EF1B37822130AE6AC35D2CA9CB5224C87FBEB3AD2B0C48F953C87B083CC26C' }
        @{ Path = 'powershell\Microsoft.PowerShell.MarkdownRender.dll'; Sha256 = 'CFE02D0D5DC672DB6B0CCE0CF90E9C88649935268BB7BE59F541EB9522125131' }
        @{ Path = 'powershell\Microsoft.PowerShell.SDK.dll'; Sha256 = '4DF907FA9E3237D00FE1DF260BBE99BF0B87514FE1A8330157D169672BF6F093' }
        @{ Path = 'powershell\Microsoft.PowerShell.Security.dll'; Sha256 = '938425C042035B0E48E56A9F1BE6FDC84F76A62DE8AD0A170520177E9B03D51B' }
        @{ Path = 'powershell\Microsoft.VisualBasic.Core.dll'; Sha256 = 'C22B26A9B48EEA35EA5411E97208D82B0D5B247701E2BE676BF61A1DB0952672' }
        @{ Path = 'powershell\Microsoft.VisualBasic.dll'; Sha256 = '563423F7703EB2CEBFE739EEBE82A664F2E251CF4958DB498E8F9F927858FD95' }
        @{ Path = 'powershell\Microsoft.VisualBasic.Forms.dll'; Sha256 = '9EC2B355DC54744AD583B95301E7B98E16A7398FD73A91E09DA141CD4338F235' }
        @{ Path = 'powershell\Microsoft.Win32.Primitives.dll'; Sha256 = '01E04C9BAE28F15661D0DA411E959E305EF6D0D78A28EB938B3322E0473E0018' }
        @{ Path = 'powershell\Microsoft.Win32.Registry.AccessControl.dll'; Sha256 = '4B1A0CA7289B0FAC3C3B2271C136E15C36D99D48A25DD8DF838CF61BAD4553C6' }
        @{ Path = 'powershell\Microsoft.Win32.Registry.dll'; Sha256 = '0D904208BA30D8808A4BBEDD8E000BACF1A56417F6F725FC144F81A0C1D6097A' }
        @{ Path = 'powershell\Microsoft.Win32.SystemEvents.dll'; Sha256 = 'CA7C2BE566D070F4E8D61058DBB662C5FA17164B56AFEF51B2A4B1046629358A' }
        @{ Path = 'powershell\Microsoft.WSMan.Management.dll'; Sha256 = '9E0BEF022454A02AEB7D30B3576A4B042561A2CA2F7C311F7BCBA9657366742E' }
        @{ Path = 'powershell\Microsoft.WSMan.Runtime.dll'; Sha256 = 'E435EE9103B0487D18E1F3E897EA085C94A7707F410F8B78473C037E72CC980C' }
        @{ Path = 'powershell\Modules\CimCmdlets\CimCmdlets.psd1'; Sha256 = 'D22F1FF483D52AA2429847D34A7132B4DE7BFD9248F36FE6AF1C9445FF4F2947' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\.signature.p7s'; Sha256 = 'E50478CEB34D18FD56CA7E0BDF15C834496BB9A205BCA52807766A69C975FD63' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\en-US\ArchiveResources.psd1'; Sha256 = '3C0955F619DD11873D5BDA857CAFD808FFB03D98D58D43B36735DCEF4661832B' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psd1'; Sha256 = 'B18D43C59CB0150ED5F6B881E257420A869DFF4CE57A8AE545D75C7B1F4AFEBF' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psm1'; Sha256 = 'CD074C5FAA453A282E8B046967B90ADE769B2575CF46CCE6DB4659AC29198C27' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\Diagnostics.format.ps1xml'; Sha256 = 'AEDE68F275D8E21D62466707636869F8A711C0DCE42ABC20E2FC3BC5EC917AC0' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\Event.format.ps1xml'; Sha256 = 'DE7FCCB062138C49DC96C167B89E671523C4E8DD553B961AD7D471D02223A0DC' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\GetEvent.types.ps1xml'; Sha256 = '2D0E829FFF014B683DE5457613FB7B9A300B67753434A490FA9D90F987662253' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Diagnostics\Microsoft.PowerShell.Diagnostics.psd1'; Sha256 = 'D80F22AB60E8882748C4CF0BAAF161CEDFC2B870BACC497D0215891E2176D489' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Host\Microsoft.PowerShell.Host.psd1'; Sha256 = '0471269053AEA21D309BC1364E741F185B60965A6A891817476B3451E8EE0E51' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1'; Sha256 = '6FF48D2D950D40208C5A5DE6FF6152E5157AB5A662C71C3E5899920F7183EEDF' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\.signature.p7s'; Sha256 = 'C94BC2A7767DAFC13347E3AD792227FCA10698E035B6FB6921DA27AFE7FED513' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Azure.Core.dll'; Sha256 = '0C85C8CC3856D5BEB91895D1A8E00F785453F2AA538D85EE9ACE030B537F0FC2' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Azure.Identity.dll'; Sha256 = 'B960AB88C55A7EDF0FF7A659CBC88FDA2DC8219221D46B7FCB92245B8E8EEFB4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Bcl.AsyncInterfaces.dll'; Sha256 = '4D5D9217443DF6066EA17039B0BFA51BF3BDAD555FC9EC3934250F6CA4B89AFB' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Extensions.FileProviders.Abstractions.dll'; Sha256 = '304314295E5735F7A3303C07AB813947FCFC22B4F290A842BF07A0C63378F8B1' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Extensions.FileSystemGlobbing.dll'; Sha256 = 'EF8B47DF8D279F424606BAD39757FB18022106903B04BCB2C02E845CA05F6879' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Extensions.Primitives.dll'; Sha256 = 'CC34AEBA059E07E03AFEF9EEA465B301AF9127120B4C5952D0D8F14BE0C822AE' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Identity.Client.dll'; Sha256 = '2ED576986194356A0E6DC5FEC646D9E147CCA6E96AB59BB80E26BE1058DFB51A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.Identity.Client.Extensions.Msal.dll'; Sha256 = 'E5066A0DEECEDA489FE96F65EFA43F88034ABD18B9745A68961E49159898A462' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Microsoft.IdentityModel.Abstractions.dll'; Sha256 = 'AAFD29BAC76B4F731EF1554EFC36FD55BE0B5F5403D7D042DFAF0D49A15616F6' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\Newtonsoft.Json.dll'; Sha256 = 'F2D7A327A731DDAE4A7593418A913C81B3D1BC8D571EED9F1E9EFDB810279F78' }
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
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Buffers.dll'; Sha256 = 'DEC2F27953172B6FE026743FB9E235C412BF6F51E19B19BAE347B446E042CEAE' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Diagnostics.DiagnosticSource.dll'; Sha256 = '1887592615FC08BBC91AD62307C8C11DFC14C45BF120D271D66BE4A0D1A149A7' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.IO.FileSystem.AccessControl.dll'; Sha256 = 'E6026501AD4056FF2F1655B0AFDFE8923BC6E8FBAD67E1E9EF56E3002F49FBB9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Memory.Data.dll'; Sha256 = '6CF06482F4FD82AF659C2EB4B7BDEAE51EC171AB1CA3B3CBF0328C6A4B882242' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Memory.dll'; Sha256 = '3B8940E394C8E8534D7CA20972E53881A4FC0F7FB250663AE63B534AB56312BF' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Numerics.Vectors.dll'; Sha256 = '1D3EF8698281E7CF7371D1554AFEF5872B39F96C26DA772210A33DA041BA1183' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Runtime.CompilerServices.Unsafe.dll'; Sha256 = '1BC42E57F7959337134A30661DA234C63AE2A905375B4A52CCC7567F6764C359' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Security.AccessControl.dll'; Sha256 = '1FDA491EEBDB19EA0A83CF6C16AB5DD004A1BFDFC845EDE017EBE0945BEB927F' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Security.Cryptography.ProtectedData.dll'; Sha256 = 'A79AD1E9E7205BD790F40D6C1900BAF1A9C8CAA06089878D24ED3599AC3228A9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Security.Principal.Windows.dll'; Sha256 = 'B4D8E15ADC235D0E858E39B5133E5D00A4BAA8C94F4F39E3B5E791B0F9C0C806' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Text.Encodings.Web.dll'; Sha256 = '211A0003B016236477947FA57B4308E25BAE4B0A6E081D417C75AEA067A00AAF' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Text.Json.dll'; Sha256 = '0CF5A9763C98F09E94DFCDAA4437E9508EABE2E50B408BA421D5FAF734C5556A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.Threading.Tasks.Extensions.dll'; Sha256 = '4F81FFD0DC7204DB75AFC35EA4291769B07C440592F28894260EEA76626A23C6' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\dependencies\System.ValueTuple.dll'; Sha256 = 'E905D102585B22C6DF04F219AF5CBDBFA7BC165979E9788B62DF6DCC165E10F4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\InstallPSResourceGetPolicyDefinitions.ps1'; Sha256 = '523EEFB2F7F6ECAA21BC16F068BA2968CB1088A524E33669A253029D0DA5106C' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\LICENSE'; Sha256 = 'BE5723395260D4F07283D596F4B375810EB695653D48D52A5062C0F7070573A3' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Microsoft.PowerShell.PSResourceGet.dll'; Sha256 = '0E118649D518720175010039FCAC1D9CDFFA9B0D0D4BF83F4EEFCF49AAB95F63' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Microsoft.PowerShell.PSResourceGet.psd1'; Sha256 = 'EBB27BDC2F765B85A7AFB87938115E2686133A050C33C16AC3ED28E9C2D8B6E5' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Microsoft.PowerShell.PSResourceGet.psm1'; Sha256 = '81EA91E7F43C29FA4BF8F39DA736D26842D09B8BD4E3FC20D96682AA20A92576' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\Notice.txt'; Sha256 = 'CB3714C1F7FC609FEE9264C5F7E87DF89121D09242A4DCCEFE4815E9D784AA65' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\PSGet.Format.ps1xml'; Sha256 = '0DCF2DAC99234C831F40C394FDEFD01C827EF0A1D622B29FFB6081ADF9829B37' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\PSResourceRepository.adml'; Sha256 = '1C8163F8163797C4B91466A94207E356256B8F770A0C591C68CD1FADD015A79A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.PSResourceGet\PSResourceRepository.admx'; Sha256 = '37BCB0428C05343483E7B5AA2F76AD3F804BA87830526EC42E8F8A91736D4AA9' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'; Sha256 = 'BAF13CC3A1E0D8542178ECB021F7CFC0BE78C5F37217B8635065A241CC02197C' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Security\Security.types.ps1xml'; Sha256 = 'ACA4DD5DBA6C89D3BBF34CFDDB39CE206CA29099E263128CB8F39A5386510847' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\.signature.p7s'; Sha256 = '3DB2F058A8F27F3E7BE0E22E8258944F9A6412A379DFFC66F99F3E592899DEC4' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\en-us\Microsoft.PowerShell.ThreadJob.dll-Help.xml'; Sha256 = '6E5AA422BFDE0133D9FC12CAB32C404557CA7CDDDA1FF888BF69395595928003' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\LICENSE'; Sha256 = '296604F12546653ED97726DC5FC2F3945D4CCA1F07ABD2589F531647177B06FC' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\Microsoft.PowerShell.ThreadJob.dll'; Sha256 = 'F89AB468EC1329474288FB0FAAD81600005BE3DA88DC2B8A2631CFBDD64F394A' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\Microsoft.PowerShell.ThreadJob.psd1'; Sha256 = '4E9CB7A6D8A94560F0025B807162BAAA9C4A6AF4254D3FA7E71B23E0DCC1FB25' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.ThreadJob\ThirdPartyNotices.txt'; Sha256 = '296FF3E4A93BC8C20CA5C20D0E1A70B8C4622FADF0351A37845A63ED52585279' }
        @{ Path = 'powershell\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'; Sha256 = '7071824B97E56EB981CB63A61E9577F7AB0F68E99898B12BEA415611208A95C8' }
        @{ Path = 'powershell\Modules\Microsoft.WSMan.Management\Microsoft.WSMan.Management.psd1'; Sha256 = '9D48FA85513627C8EEFAD9F4B1179A0EBBE2DBD304A6F8BD663BE3CB917A65AD' }
        @{ Path = 'powershell\Modules\Microsoft.WSMan.Management\WSMan.format.ps1xml'; Sha256 = '467B9EC5EF9893EBE52E40C7BF6C02AC1D02EE09786F11459B395F7E96A0F732' }
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
        @{ Path = 'powershell\Modules\PSDiagnostics\PSDiagnostics.psd1'; Sha256 = '5DA311FE08E04C8E4F20944010CDA8B43400C8FB31A3552046D0D3E942F31CF7' }
        @{ Path = 'powershell\Modules\PSDiagnostics\PSDiagnostics.psm1'; Sha256 = 'AD258F003D31C23CE3901E11ED9C47F6E69DF3756C5C382D31506CEB1611C30D' }
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
        @{ Path = 'powershell\mscordaccore_amd64_amd64_10.0.1526.53008.dll'; Sha256 = 'C63D4B8AF8E5E96E79401B44E964B3AE0F954127ABAB76F0487AFE98A75DC14C' }
        @{ Path = 'powershell\mscordaccore.dll'; Sha256 = 'C63D4B8AF8E5E96E79401B44E964B3AE0F954127ABAB76F0487AFE98A75DC14C' }
        @{ Path = 'powershell\mscordbi.dll'; Sha256 = '9120FFCBE0D9BA0F5213277D546785EDFE6E564F8519BD7E5D21968882BF14DC' }
        @{ Path = 'powershell\mscorlib.dll'; Sha256 = '3B72DD3231822316D3F4D649A7C6DB115C7829E40978D564B543C4D34F5C5C16' }
        @{ Path = 'powershell\mscorrc.dll'; Sha256 = '41EE8D8DA7BE90058AC9CF3BE848871A9B78F60FE6CAF82777EA9776AC85F75C' }
        @{ Path = 'powershell\msquic.dll'; Sha256 = 'D363DE7B6B08B3C68F0BC87AE74843CB152067A9EA589A265631895F41A0CA45' }
        @{ Path = 'powershell\netstandard.dll'; Sha256 = '6B7A22CCE7004DEA2D1747DB1F150E2809AFA7D41508B1B288F967EC1332F2F5' }
        @{ Path = 'powershell\Newtonsoft.Json.dll'; Sha256 = 'CDE85EBD253CE8CE04CB1816C36D69C06DDA21F8494387EEF68016418A3768A5' }
        @{ Path = 'powershell\PenImc_cor3.dll'; Sha256 = '7ABBBF1F9C64C08E69DEE3340B56623FF4809297BCBA42D7C92FB3C3DECF11D0' }
        @{ Path = 'powershell\powershell.config.json'; Sha256 = '98C0E5B6EE17EB8B8F4E4940C2B2528689CEC8470DB4BDE427AD16D90D6A52D4' }
        @{ Path = 'powershell\PowerShell.Core.Instrumentation.dll'; Sha256 = '3D341B3E9C71A4A843EDA0FE0D0D1B5B604F4BEABD64AC4E57C5B5D313C4428C' }
        @{ Path = 'powershell\PowerShell.Core.Instrumentation.man'; Sha256 = '8B2585E50EDE697905DFDB8E3878DA2AB42039135BA23E377207CC8D96E8125F' }
        @{ Path = 'powershell\PowerShellCoreExecutionPolicy.adml'; Sha256 = '2B8C4B7D5BD585431FBF918F223A9B932D80EB9703A1976A1CE3492D4DD26966' }
        @{ Path = 'powershell\PowerShellCoreExecutionPolicy.admx'; Sha256 = 'EE8EB99C1E66009D95AF46E4F6C8F5C13563C9A0AD827E631149176A1B8D34D2' }
        @{ Path = 'powershell\PresentationCore.dll'; Sha256 = 'DD98B4B78DEF920FC60026AD6FF84237A729FE0A698237107AEC625043A69FF7' }
        @{ Path = 'powershell\PresentationFramework-SystemCore.dll'; Sha256 = '8EDB4073D02E3C3B488DFEED1467E4C16C350A2F51C3711E15CAB212C9537381' }
        @{ Path = 'powershell\PresentationFramework-SystemData.dll'; Sha256 = 'A5A1138E8556F714C61320F76D336F985C363A72234D605BAB8E66B36C99B0DA' }
        @{ Path = 'powershell\PresentationFramework-SystemDrawing.dll'; Sha256 = '8B8E3881B31B7B6042FB416DDDB77F32C9E7BC39F79E22143B01C769E0595663' }
        @{ Path = 'powershell\PresentationFramework-SystemXml.dll'; Sha256 = '980C50CB01AE8A805B0396DCCD1C858FB241A3E6FED1FDAE0F1813A62B125BC4' }
        @{ Path = 'powershell\PresentationFramework-SystemXmlLinq.dll'; Sha256 = '1C16720792CF6221C6B659D7FE3EF536695D4064F2F18D99846A862A5D317315' }
        @{ Path = 'powershell\PresentationFramework.Aero.dll'; Sha256 = '3BD6AB48E3D628CC39C66DE139E72FDCC981D504496403BCDD23EE29A696654B' }
        @{ Path = 'powershell\PresentationFramework.Aero2.dll'; Sha256 = 'D09D44EAFCBC49C647FEEAE25661D3052ACB54AC7D07698FF714A76819A5D127' }
        @{ Path = 'powershell\PresentationFramework.AeroLite.dll'; Sha256 = 'D0FF5AD7B8610FE20B54264956C8B47825D1A463EF7AAC04F7023004657C3406' }
        @{ Path = 'powershell\PresentationFramework.Classic.dll'; Sha256 = '4FDB51FA0BB95702BAF7538A89E1338ECFA645B71283EA8E415F59409528F089' }
        @{ Path = 'powershell\PresentationFramework.dll'; Sha256 = '98FC9302E6D4C5116E6DFA27B5C88E373C13941BA3515F85C4520B86164D0883' }
        @{ Path = 'powershell\PresentationFramework.Fluent.dll'; Sha256 = 'A7B4967A1DBB49CA618B432F7882E0463D24B2E141C26E11DEAE3589D17D5A13' }
        @{ Path = 'powershell\PresentationFramework.Luna.dll'; Sha256 = '18B18E9ED3FB501D5BED1A1C0F733417E719C2898BA59721244CBCF981686BAE' }
        @{ Path = 'powershell\PresentationFramework.Royale.dll'; Sha256 = '203E7094B7DAFD3F367563206F8733976D486D9CA368D318EAE423FFEB02B16B' }
        @{ Path = 'powershell\PresentationNative_cor3.dll'; Sha256 = '931AE412F521932B91DB1FAC7A10C1A5690721B08A5F6C86B767B5855F8B57DB' }
        @{ Path = 'powershell\PresentationUI.dll'; Sha256 = '89F61EA3FE70DBF0E8B49891ACF16E1DF70EC5629F758D033B819D52FC07DF98' }
        @{ Path = 'powershell\preview\pwsh-preview.cmd'; Sha256 = '7A24CB96B62009CFFB38C85B6ACBF48A5DB5746459B85FF3E727BD952FFD8832' }
        @{ Path = 'powershell\pwrshplugin.dll'; Sha256 = 'AB16ACC15BFE2EDC54793CF363DAA7C786317B592DCF8DEE33E1D433D8A254A5' }
        @{ Path = 'powershell\pwsh.deps.json'; Sha256 = 'D483965B02B32E10FDDC902451781397E38716074594F0E2095A383090FC858A' }
        @{ Path = 'powershell\pwsh.dll'; Sha256 = 'E54C91D2DB5F9A3FBA99AF20A847036130DB7EDA16215A9D6028CE682B7D29C8' }
        @{ Path = 'powershell\pwsh.exe'; Sha256 = 'E94166ED9F376559C1359BAFB08BC49E463A494C330F67644EC1D9F1FFEB5EE5' }
        @{ Path = 'powershell\pwsh.profile.dsc.resource.json'; Sha256 = '378030311FCDD7A8D6C401142275BAEB6C031307EC2E12F51399B84851906380' }
        @{ Path = 'powershell\pwsh.profile.resource.ps1'; Sha256 = 'A95A2B87E6BB92D11267018B6CC654D890DEC0654631C8ABC4C8943AF3DA601E' }
        @{ Path = 'powershell\pwsh.runtimeconfig.json'; Sha256 = 'A654D34D6234407378785E9856C170A32C7338FFE55D69BBF09C37026408CA04' }
        @{ Path = 'powershell\ReachFramework.dll'; Sha256 = '9781BBA218AC677414787441F71F83C98E1D6361F4FD2A7C627F674EBC7B8987' }
        @{ Path = 'powershell\ref\Microsoft.CSharp.dll'; Sha256 = 'A1C03FCCD3C9311DD531C7D7E5EA3FA2DF2C12427E9903A21227409239F482DB' }
        @{ Path = 'powershell\ref\Microsoft.VisualBasic.Core.dll'; Sha256 = '36C921BB6FE5245CDD230204E8EDBBA1DF920FC76E17B52DBE027EC13ADD77A7' }
        @{ Path = 'powershell\ref\Microsoft.VisualBasic.dll'; Sha256 = '1AF2D7C70E0C1E8829587D681E064B1DF337B9FAE69BFC954172490FB830367C' }
        @{ Path = 'powershell\ref\Microsoft.Win32.Primitives.dll'; Sha256 = '96E89F2DA46204011880789BC641500CF74B9A43F5D7FFFD141D4A60A779BB89' }
        @{ Path = 'powershell\ref\Microsoft.Win32.Registry.dll'; Sha256 = '76E7223F5CB685498173EB4F378C8046A4F0FEF9FC457B05A9A93605C7986076' }
        @{ Path = 'powershell\ref\mscorlib.dll'; Sha256 = '2129B26E6F011805E03FDCFB65D56F2A968C2A783E32EEA9EC6678AF106CDD48' }
        @{ Path = 'powershell\ref\netstandard.dll'; Sha256 = '6B7A22CCE7004DEA2D1747DB1F150E2809AFA7D41508B1B288F967EC1332F2F5' }
        @{ Path = 'powershell\ref\System.AppContext.dll'; Sha256 = '5824233C5A6129F5741E1E0BD14F60A58A38600BAC384DC8B3CD09F969D67543' }
        @{ Path = 'powershell\ref\System.Buffers.dll'; Sha256 = 'B569DB17C9A66433310A3B71A86157F025AE573F60D4BB4E20E5D1C3CAC94896' }
        @{ Path = 'powershell\ref\System.Collections.Concurrent.dll'; Sha256 = 'CF050DCABBD2EFB8B8E47D377160250FAD44D32EC501AD8B6DB82E8349C68DBA' }
        @{ Path = 'powershell\ref\System.Collections.dll'; Sha256 = '5291A8080CEC5CE08703A7E2B0DA5CA3E1E61C9A1EAD9A9C5384A4BE1F4CCFA5' }
        @{ Path = 'powershell\ref\System.Collections.Immutable.dll'; Sha256 = '9BC9A7D36725D9A07A02770633870BE8D62BEA0584E224BE839EA58E5108CDD5' }
        @{ Path = 'powershell\ref\System.Collections.NonGeneric.dll'; Sha256 = '47356302F3EC77DAB8B52BE626DD24EF384F5EAB6C2DFEB6E879EF61FC2E2708' }
        @{ Path = 'powershell\ref\System.Collections.Specialized.dll'; Sha256 = 'E715F6CC3A9FCE2BF6D4C383C367EB585240DF214B1DEC97B9B6355836CDE05B' }
        @{ Path = 'powershell\ref\System.ComponentModel.Annotations.dll'; Sha256 = '6DF9941244D2CA015BE5EA99F3E4045A4BCC732B1518BA6BD07DE4926C2B5B98' }
        @{ Path = 'powershell\ref\System.ComponentModel.DataAnnotations.dll'; Sha256 = '0B47479C27B050E90CC0C232561781F71A85DF75686758EFF459890E73045D81' }
        @{ Path = 'powershell\ref\System.ComponentModel.dll'; Sha256 = '6AB65AC403C6A1BF8392B24D098D2734F4A8EA3F6C674B64C9219B01D8F09991' }
        @{ Path = 'powershell\ref\System.ComponentModel.EventBasedAsync.dll'; Sha256 = '355F17680E4BDE9FC2C3151E0A7BBD73E80FE0EE8C29B9384ACA656F880BAF73' }
        @{ Path = 'powershell\ref\System.ComponentModel.Primitives.dll'; Sha256 = '778FFD5F0B0969AEF963AFC617817D3356E3C21FFB7E1F2A86A405FD491156CD' }
        @{ Path = 'powershell\ref\System.ComponentModel.TypeConverter.dll'; Sha256 = '70B250ED0D33AF1D351D9FA6E60922F3B3B45D6C211B8E56EB1D26BC6294F950' }
        @{ Path = 'powershell\ref\System.Configuration.dll'; Sha256 = '1F7C4F09BD5EEBB988C7F6B16DB293260A7FFDAF30E407EE44D1E492E83AE78F' }
        @{ Path = 'powershell\ref\System.Console.dll'; Sha256 = '33FFF2ACC52BF04FB8398AFC33BF1BA1E8035E97D0FF37FD195ADA6390B2B86A' }
        @{ Path = 'powershell\ref\System.Core.dll'; Sha256 = '7828FA13325F9B97DDD8D8E6DCB1CC54DE1AFC5FB2DC69A29F86CA686FB8E04C' }
        @{ Path = 'powershell\ref\System.Data.Common.dll'; Sha256 = '4836BD8F950FDCD3AC6675E16D2DBDF0A55DD4B1BD5C33C6A7891E9E014D0027' }
        @{ Path = 'powershell\ref\System.Data.DataSetExtensions.dll'; Sha256 = 'F7DEC6629D252F03E1C90E0A2EAD24E482A2A24914101710391ABA6DC8A453C7' }
        @{ Path = 'powershell\ref\System.Data.dll'; Sha256 = 'C9CA5F24741A7170E509BA00A589C13AC43DFC497C94B88D7D265E7D87A8C4FB' }
        @{ Path = 'powershell\ref\System.Diagnostics.Contracts.dll'; Sha256 = 'ABB02620F56EABFB67697204B7849BB2B60A46590C5837AB2A976CB279793D41' }
        @{ Path = 'powershell\ref\System.Diagnostics.Debug.dll'; Sha256 = '54340793A5D2F86AEDC1573F0C438BB53FF810C13AD839362FE153A560ACB9BC' }
        @{ Path = 'powershell\ref\System.Diagnostics.DiagnosticSource.dll'; Sha256 = 'ED71A190D5BDD55F8F6B9200DBEECEC4C0A81DB4986F3E3C4F629FA8AE88F21A' }
        @{ Path = 'powershell\ref\System.Diagnostics.FileVersionInfo.dll'; Sha256 = '8C2A28DD6013A27D92817035528A677349E947D80380AAC10912DE487CFB0110' }
        @{ Path = 'powershell\ref\System.Diagnostics.Process.dll'; Sha256 = '47F5B8565653B349A18F7D9FEAEFC66A9F845F362043531C82F585362F4E227C' }
        @{ Path = 'powershell\ref\System.Diagnostics.StackTrace.dll'; Sha256 = 'AA7B33EBA0D9296C0B156BB8A1A9680C3F3F07285984DE90FBF9FD036C3AD04C' }
        @{ Path = 'powershell\ref\System.Diagnostics.TextWriterTraceListener.dll'; Sha256 = 'F02EB8967D3C14E4699766F69A34CAD4316F94A6F5849DD02545702BFAB15A0A' }
        @{ Path = 'powershell\ref\System.Diagnostics.Tools.dll'; Sha256 = 'A39E302A28F1F35CD9CD975C52358C7796330080920DDC4DCD3B336760B769FC' }
        @{ Path = 'powershell\ref\System.Diagnostics.TraceSource.dll'; Sha256 = '440CBA0BA25E80AC99566384B77AFA7C2FA51C73D82D73994430C5755468FAD4' }
        @{ Path = 'powershell\ref\System.Diagnostics.Tracing.dll'; Sha256 = 'D1786A8092C2BE01AA8E91EDDA3988608540A0D3C0FE4258D3B4B9B54B373F3D' }
        @{ Path = 'powershell\ref\System.dll'; Sha256 = '97A1F413D77E9C3D92C9A36C6DE8E1608BBAC801B75046785516AE1E82C397ED' }
        @{ Path = 'powershell\ref\System.Drawing.dll'; Sha256 = '76163A1B4918236BF2041036E76D83D75E0405A7A7022168121D21B3AA80E30D' }
        @{ Path = 'powershell\ref\System.Drawing.Primitives.dll'; Sha256 = 'CEAAE74E826A88C7C88D5CF8A3BD9865F4E2B4019CDEB9A4EAFFA3AE8A13F5C1' }
        @{ Path = 'powershell\ref\System.Dynamic.Runtime.dll'; Sha256 = '02B2C3FD58F793718FD4A0707993B3CFAC272541166ADA7B0373902FE5FC6384' }
        @{ Path = 'powershell\ref\System.Formats.Asn1.dll'; Sha256 = '84E99937864D91F673EA8E00A8FF2E405488F6C7DB98FDE33F119D823A835464' }
        @{ Path = 'powershell\ref\System.Formats.Tar.dll'; Sha256 = '92AA7FE2D10E6CFB56C799EF730FF3BDC755621742D75E52DB90D9A75DA84ECA' }
        @{ Path = 'powershell\ref\System.Globalization.Calendars.dll'; Sha256 = 'D169ED333B4BAB2D6F9BA6A0FC9E4F1A8301E97E9C265A46D949EA5651080C0D' }
        @{ Path = 'powershell\ref\System.Globalization.dll'; Sha256 = 'BDEB8D26D917976915190C6213907967B5A2CE83B7C575B67A71D121993DFD24' }
        @{ Path = 'powershell\ref\System.Globalization.Extensions.dll'; Sha256 = '4A5FF15607BB3AF1016A471EB2E3E93B94AB60DA4B862DE5DE9AEA27FB1DDF8A' }
        @{ Path = 'powershell\ref\System.IO.Compression.Brotli.dll'; Sha256 = '984CEC8F8D2EE4110329858D3F3FEBB0257D1AEF60F170E30D0AF540AE71716D' }
        @{ Path = 'powershell\ref\System.IO.Compression.dll'; Sha256 = '105158FB3A4C19A89311BB52ED077A65425584B676100EFBBE8E6EF5CC423929' }
        @{ Path = 'powershell\ref\System.IO.Compression.FileSystem.dll'; Sha256 = '889ECC7A7C5B44071AAB2826FD6D6B8DAD8B88EA04119870A3E4F2CAAAE95009' }
        @{ Path = 'powershell\ref\System.IO.Compression.ZipFile.dll'; Sha256 = '6CA63F9D9C20494A1141C1FB4E377AF0B3C9A6788F33897FE3EC03A7874517DC' }
        @{ Path = 'powershell\ref\System.IO.dll'; Sha256 = '2699CE957E080E2FA5F87CFEDFC0D469475FD8D1ADA1F5DB09C48A085C2282E3' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.AccessControl.dll'; Sha256 = 'B4EAC01472984530EE36144C4ECA4C9C6674A7DBA11F17DA2CFEDBA79B61617B' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.dll'; Sha256 = 'B2B09F39E7CB61DDDB3658D95A4FEB62498D25A9A477A1E11F5FAF36D829A19B' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.DriveInfo.dll'; Sha256 = '0783900DD2BB403901CD972151BE3566C3511535FD3C4BEE66C207DCE8B11091' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.Primitives.dll'; Sha256 = '0602E2F6227D8A0842BBA942FB84C9A68331266802C449AF9E11AEB45F9193FE' }
        @{ Path = 'powershell\ref\System.IO.FileSystem.Watcher.dll'; Sha256 = 'C2B72568A947FC1FA7060432FD46655CF952CEDA0B75E5C087EC6513CA40D2A1' }
        @{ Path = 'powershell\ref\System.IO.IsolatedStorage.dll'; Sha256 = '965A2656D5DB2F5B6ACD91EE70A99AC9BCC50C7759CBB12C68D949C2BD1EC28F' }
        @{ Path = 'powershell\ref\System.IO.MemoryMappedFiles.dll'; Sha256 = '6B4DC4A0A68536169FB2967D9BB2919BC3D44097843860C706AB577DFE6F9C84' }
        @{ Path = 'powershell\ref\System.IO.Pipelines.dll'; Sha256 = '4F831CAA8151C80EA14AD38CEB34B36B2D3488DAFEB923ED3235069144C755CC' }
        @{ Path = 'powershell\ref\System.IO.Pipes.AccessControl.dll'; Sha256 = '1DE44FCA45B74A3B69961CC36D3BA3E998B20F3839DF0094AB39775468427C72' }
        @{ Path = 'powershell\ref\System.IO.Pipes.dll'; Sha256 = 'E3AB3D906FDD75F6B12256B8E893112A8D582DA42032FBCAD28C74195F60E1F7' }
        @{ Path = 'powershell\ref\System.IO.UnmanagedMemoryStream.dll'; Sha256 = 'E3B1BA5A4FF28EE788F1E88DFBB50762135A7C29F0ADB93DBAC9AC5284DEC769' }
        @{ Path = 'powershell\ref\System.Linq.AsyncEnumerable.dll'; Sha256 = '8375FAB8F6479CFEA92D13414A54C8026DCFD28406E9CC57A66A893D21ACEC3C' }
        @{ Path = 'powershell\ref\System.Linq.dll'; Sha256 = '545EA2E23B03EA42A29D4BE1E8DBB61227F350ABB999AB61E425CFB0CEF0AA1A' }
        @{ Path = 'powershell\ref\System.Linq.Expressions.dll'; Sha256 = 'AB2C42702A6AF263C97EE1072B7CECE5A3AB9B468DFE50C5403D47EDCC270897' }
        @{ Path = 'powershell\ref\System.Linq.Parallel.dll'; Sha256 = '39B059129C5B8CCCB666C3E26A536E1C906E3B4EC0AA71C05536C8E3992B6F97' }
        @{ Path = 'powershell\ref\System.Linq.Queryable.dll'; Sha256 = 'E30982CD8E8651CC72E04B5CD73CCFE069C0FA22C97495FF5FBD671FE8D3C27B' }
        @{ Path = 'powershell\ref\System.Memory.dll'; Sha256 = '141DF53B6BC61607943D4C3639F49B1F8ED543682AD5E7A257F8079CEFB81AA1' }
        @{ Path = 'powershell\ref\System.Net.dll'; Sha256 = '9966E1605FDA50D083BEAA307BCDB9DAF0D8B7BAE84771265D8C44534748FFD8' }
        @{ Path = 'powershell\ref\System.Net.Http.dll'; Sha256 = '30DCBCF51DE34AE5EECFA3F3807ADD014D7C13CA99738DB7C3A8E95F49A234D3' }
        @{ Path = 'powershell\ref\System.Net.Http.Json.dll'; Sha256 = '67E38B320C4E279325863D8F8C4D638B1EDACA929878F91E315CD03264E67C83' }
        @{ Path = 'powershell\ref\System.Net.HttpListener.dll'; Sha256 = 'A606C3CCE5D3548F8FAC0DD594AA4DA333DC604DCE0090AB121E08493333DEA3' }
        @{ Path = 'powershell\ref\System.Net.Mail.dll'; Sha256 = '13A1FE1DB1F2168C505621016BA81E92648726FC30B8E7A4DDEC8A7CB35AF424' }
        @{ Path = 'powershell\ref\System.Net.NameResolution.dll'; Sha256 = '36B1FEEB7885FCEB071FE90B6A837F7466552A16597C99F4A131D23BACD96A64' }
        @{ Path = 'powershell\ref\System.Net.NetworkInformation.dll'; Sha256 = '4B95A66B9229538824F1B52EC80E91521ECC5FE71AD46DBF684DB9AB76739305' }
        @{ Path = 'powershell\ref\System.Net.Ping.dll'; Sha256 = 'C767B9DCFC934111CDBF9EDE9CF7661FD7714AB09C3E1D4C453C4F069A0B29C8' }
        @{ Path = 'powershell\ref\System.Net.Primitives.dll'; Sha256 = '3E88EE6C92068131255C360FD223B75FEF4BEF2552DA753566765C192153917F' }
        @{ Path = 'powershell\ref\System.Net.Quic.dll'; Sha256 = 'EECF4C24A351BEAACFCC9FC65BF370A8D532237C2288363B45D409E10CE1E240' }
        @{ Path = 'powershell\ref\System.Net.Requests.dll'; Sha256 = 'C580834C795C6309423F0B4641FB2687983CC869AF43702EDB4D4630F2DAEA96' }
        @{ Path = 'powershell\ref\System.Net.Security.dll'; Sha256 = '0EAB0DE08B38EA93245EEA0E5018E423174A99F3C43E1DB776CC8F251CFC32C9' }
        @{ Path = 'powershell\ref\System.Net.ServerSentEvents.dll'; Sha256 = 'FDF13AE2B83C6FFF01744BF11FCF3629EEB5ECB2E48FD3546873BA27243AB09E' }
        @{ Path = 'powershell\ref\System.Net.ServicePoint.dll'; Sha256 = '678104FE7E696B9B182734ED4BBDE61F23E8466C942A68BAA9F9E504781AA978' }
        @{ Path = 'powershell\ref\System.Net.Sockets.dll'; Sha256 = '105CC2F2BDF353CF23388FF249313B9374C8EB3EF7C3806579DEA7664B0F724F' }
        @{ Path = 'powershell\ref\System.Net.WebClient.dll'; Sha256 = '8E8C426DDCDCB951424A59E2C941557665710893FE59909CA26FFFC5BB4B537C' }
        @{ Path = 'powershell\ref\System.Net.WebHeaderCollection.dll'; Sha256 = '6AF525F8D80F69246CA78C8F3E6E3A5AF39595407B35EB9772D8118A4E24D4FC' }
        @{ Path = 'powershell\ref\System.Net.WebProxy.dll'; Sha256 = '6484198EE216BC68869BE85A3282D51A6B76D38A1B2194181F2ACCC927E30963' }
        @{ Path = 'powershell\ref\System.Net.WebSockets.Client.dll'; Sha256 = 'FF4580761EDAC0F2ECA7A97F9867CC54300B109A487B40173F7152A6A2E1E923' }
        @{ Path = 'powershell\ref\System.Net.WebSockets.dll'; Sha256 = '743D430175C51DBCEDA3485B3E4550178C9BE59A13286C5B89A8DAE19463A192' }
        @{ Path = 'powershell\ref\System.Numerics.dll'; Sha256 = 'DA30DDC2FBFED6382C9A029F4AB19ECA96A60CE36BDA432F2FEB5E209CCD2457' }
        @{ Path = 'powershell\ref\System.Numerics.Vectors.dll'; Sha256 = '56892956CADCCB1AF8A7A2BFE0D7F469C33B896BD746AA5A77C0F3A544536D0A' }
        @{ Path = 'powershell\ref\System.ObjectModel.dll'; Sha256 = 'B867DB3A4F84D0F54C7456710AD5B80070DA9B52362FD46B5FF13B04A8B01DCD' }
        @{ Path = 'powershell\ref\System.Reflection.DispatchProxy.dll'; Sha256 = 'CF1DA354467D9CC3A050F8528F6AC08D04BC4B6A858E3C5B3121FE98095F4D2E' }
        @{ Path = 'powershell\ref\System.Reflection.dll'; Sha256 = '9AA8ACB636611BA2324BEDD4DD9650BC9E7A1F016CF7ACC4C2A69051C0CBED4B' }
        @{ Path = 'powershell\ref\System.Reflection.Emit.dll'; Sha256 = 'E7985117CD85ED442D605D493D52946A9472FB1F7818770BCE21B04C7A7A2B66' }
        @{ Path = 'powershell\ref\System.Reflection.Emit.ILGeneration.dll'; Sha256 = 'DE43E116C1A4798AA34418F7A107FB3DBEFEA48DF61964ABC620C7D36A2E523B' }
        @{ Path = 'powershell\ref\System.Reflection.Emit.Lightweight.dll'; Sha256 = 'DF90F0EACDE94718F4E5B4CFE1598EB4D2F21A88051AAAA2E17A1B83682D0409' }
        @{ Path = 'powershell\ref\System.Reflection.Extensions.dll'; Sha256 = '1ACBC49DEB1A9410CFA6B357C1F2E185E8183584CF4AB237961DDD7A561A0EFB' }
        @{ Path = 'powershell\ref\System.Reflection.Metadata.dll'; Sha256 = 'D5B1EF32F8D005A176351A6FD49BB90DE8E9D7EE3E101803063431FA2F6FA7A8' }
        @{ Path = 'powershell\ref\System.Reflection.Primitives.dll'; Sha256 = 'BF3B0BC3DDAB81463629E78210EB530743F4D6202D2AB02331DDE09821216185' }
        @{ Path = 'powershell\ref\System.Reflection.TypeExtensions.dll'; Sha256 = 'B7648913409545097ABF4936F62C96660B25F15C51ADDA3C96152543CA40B141' }
        @{ Path = 'powershell\ref\System.Resources.Reader.dll'; Sha256 = 'C72A47E82365921B09A61F1CA72B722E4D28683D085035937DBFCE32BA4503E2' }
        @{ Path = 'powershell\ref\System.Resources.ResourceManager.dll'; Sha256 = '41B34AA003A48C68FBA186CD7B5EA4F68E8F6CE4418BD5A68A158A79AD58293C' }
        @{ Path = 'powershell\ref\System.Resources.Writer.dll'; Sha256 = '55A20CDEA691B6C1964A30B9E14D7BF59A7F59E86D9D1AB66B586A9FEF68A2AC' }
        @{ Path = 'powershell\ref\System.Runtime.CompilerServices.Unsafe.dll'; Sha256 = '0C2A4E77F62BC47E73EE4868364D7DE3013CC41B42F71989F601C0CFB2EF8C8D' }
        @{ Path = 'powershell\ref\System.Runtime.CompilerServices.VisualC.dll'; Sha256 = 'DB0E148B84F883B0B9620112BD69D4FC305834C5592D8DB69A656B12260A8AA0' }
        @{ Path = 'powershell\ref\System.Runtime.dll'; Sha256 = 'FC8507281669095A338EEB3CC2A4C0C752F330CE1BAFDD9A3CD89311D4EADFE9' }
        @{ Path = 'powershell\ref\System.Runtime.Extensions.dll'; Sha256 = '95B093657B594177EF20472048C926BB9AE39FEAE5783D6C630F56183937C433' }
        @{ Path = 'powershell\ref\System.Runtime.Handles.dll'; Sha256 = 'DDEDBBB02981ACDE482BD310B3B48FE9A7003DEC68D0CC4B9BCC3663F187A2A8' }
        @{ Path = 'powershell\ref\System.Runtime.InteropServices.dll'; Sha256 = 'ECE82B0872CEB4A4B7111C765ACD21C05B0B3398356B1C9580848719438B93D3' }
        @{ Path = 'powershell\ref\System.Runtime.InteropServices.JavaScript.dll'; Sha256 = '125A105E7AEBA4925D38C6430FDB75C29CC9E69D18B2DCBF7AAFBDF87B44E831' }
        @{ Path = 'powershell\ref\System.Runtime.InteropServices.RuntimeInformation.dll'; Sha256 = '499C566F61B78A68D0F48EBB3A6D431C4F3875A1067943D903EAB1E7D43FEDC0' }
        @{ Path = 'powershell\ref\System.Runtime.Intrinsics.dll'; Sha256 = '9BA92E69CA92189D1AC537962FA0F6B699E0FAB96348F2FB040DAA6284E615DF' }
        @{ Path = 'powershell\ref\System.Runtime.Loader.dll'; Sha256 = 'BD1F897F4035B7D8830B387A68EF3D5D929F947CAA3015C9966E0599C8931043' }
        @{ Path = 'powershell\ref\System.Runtime.Numerics.dll'; Sha256 = 'B8DF2E8F15BA21A37176F1D7487F02450220DA37CFCCAE02467B210C180E256E' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.dll'; Sha256 = '20C4A3E000268704D5A9FA72E10DDEC5A462F2ED5ECD18E24D53C0B6929D15ED' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Formatters.dll'; Sha256 = '5A224498EDBABDF2030DA4FF8048E61E41AF44C02097EAB8A28592187218A9C0' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Json.dll'; Sha256 = 'DB031F12AF5B04A1939131EFC14CA89676427AFAC1CDA4475E273E24F95DDD1A' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Primitives.dll'; Sha256 = 'B4721E1F40F799C055C2ACC4AE5629C49A6C699CCEEAB1AEFD679F55D8D3DAB7' }
        @{ Path = 'powershell\ref\System.Runtime.Serialization.Xml.dll'; Sha256 = 'DA0C57CBC659BBCB7DE413E72ED92B2543E9699B2F8F99C728816AB07A40DFCA' }
        @{ Path = 'powershell\ref\System.Security.AccessControl.dll'; Sha256 = 'AF8430EA420055774C935AEA0DF079ADCCCED58FA5B09F10DABCB30AEF21538C' }
        @{ Path = 'powershell\ref\System.Security.Claims.dll'; Sha256 = '20D79F18812C3BAA78F38902E0DE9B52A45169C77E486A03FC1AAD3AE99C0296' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Algorithms.dll'; Sha256 = 'BFEBCC7308E202B1971D621883574A203ECAB74AE992A152DD4071ED08FA00D7' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Cng.dll'; Sha256 = 'A238BC58DABF109AA46685CD4AA3D18A8CC35F4B1E3788710465F2AFE5813C9C' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Csp.dll'; Sha256 = '3737F8EA4D0A41D83E3E2D860E74B3CA2AAB7349F9A265577B0F66FAAA6EF109' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.dll'; Sha256 = '39447F3A09B6E9CAE88B79750078728E414DCEDF257787180D6E15F5383E4726' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Encoding.dll'; Sha256 = '75B36584506DBD64B68E0D60A2189F70F03262D620CDF26B394B0ABC97FE52FD' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.OpenSsl.dll'; Sha256 = 'DC856022EBDEC7F030817C7A6A5FCDA06AEFAA7E2C7B4CD83D8525DB476D9823' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.Primitives.dll'; Sha256 = '2D4F209F4B2F7BC0AF1E7FB39C99349F6AD081689E89028A8DCE1D580E1F39D9' }
        @{ Path = 'powershell\ref\System.Security.Cryptography.X509Certificates.dll'; Sha256 = '6FE5848BAFD502672FD206E4208B64E1ACA84627427E131E33167B0795309207' }
        @{ Path = 'powershell\ref\System.Security.dll'; Sha256 = '4887E93D7FBF6C6F0909579400EF892D42896A2123CC1A0C702F7C555E9E9D98' }
        @{ Path = 'powershell\ref\System.Security.Principal.dll'; Sha256 = '089428925C94B2CD5A5FAEDE9BF7799FFA144E899A1E56F1C2C05159660DA580' }
        @{ Path = 'powershell\ref\System.Security.Principal.Windows.dll'; Sha256 = 'CA3CB2EC3365FC9E2921C9436560F801F94F0612DB4DB4189042C85CB55095A7' }
        @{ Path = 'powershell\ref\System.Security.SecureString.dll'; Sha256 = 'F51D458BDE0A367EBEC626CC1C2247A374F5145170FD5DF9FD501426F2CC2C4B' }
        @{ Path = 'powershell\ref\System.ServiceModel.Web.dll'; Sha256 = '9AF5E984ADF9989A462618C55DE79429563EE20F583E40AD9D001F5022D0B4BD' }
        @{ Path = 'powershell\ref\System.ServiceProcess.dll'; Sha256 = 'E40FC253A50BEE22E6E20E1AF1140BDEB5E92F4459F0427BC8A05A0E81E74821' }
        @{ Path = 'powershell\ref\System.Text.Encoding.CodePages.dll'; Sha256 = '2393C81B85F4F40E2D96AD4E0E4E8F0E2C4A466CC35C4AB6ABDF8B390003D482' }
        @{ Path = 'powershell\ref\System.Text.Encoding.dll'; Sha256 = '677FEF60BE9ACB153BE1CCAAC221ECC93C358231D21CBFD69C98AE98FA71929B' }
        @{ Path = 'powershell\ref\System.Text.Encoding.Extensions.dll'; Sha256 = '1C5E1912E64A8D42566C50FC7B6DA7C34F07562D0AD5B3D0F14829D63CF0EAB4' }
        @{ Path = 'powershell\ref\System.Text.Encodings.Web.dll'; Sha256 = 'C8F11B47779BA611464F2E0328920F3C8DCD4C3D7C85CEF458D397687388EDAB' }
        @{ Path = 'powershell\ref\System.Text.Json.dll'; Sha256 = 'A611C809A9D4076027687D4C951202CB06B714E8A178F4B7583566012E345111' }
        @{ Path = 'powershell\ref\System.Text.RegularExpressions.dll'; Sha256 = '3B1E0EAB651B23C1993FF2E18BE73C1E561CDF7A0CFEA449CE0D8C8D7FD1D096' }
        @{ Path = 'powershell\ref\System.Threading.AccessControl.dll'; Sha256 = '8AA7CB9F234797A4D07E20F7D67DC72CABC6E52AE29250B4B509E8EEBC1D4130' }
        @{ Path = 'powershell\ref\System.Threading.Channels.dll'; Sha256 = 'BDD9A16F583CCCEC51D1ACC52A795EE56C1597B1C3896F38F23E90676924A9BA' }
        @{ Path = 'powershell\ref\System.Threading.dll'; Sha256 = '5564A826E8DB99386C1E6678E4EF663DAA8CD415F48D465EC65D210DFC326685' }
        @{ Path = 'powershell\ref\System.Threading.Overlapped.dll'; Sha256 = '64258773CF1D90E7CDE2E720C4FDA5346253B7FEAC73EC2670D62403D0DEF3D6' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.Dataflow.dll'; Sha256 = 'D305D6EC83FDCB436EDFB481DE3EEB0A0F9087570D0A071735BFA75B3D9912B7' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.dll'; Sha256 = 'F0BB5A82E4F78A07499688319BA0BF5078758DDDD5C6007028D65A18BAEFF45E' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.Extensions.dll'; Sha256 = 'C5273C4E16BE5914A4975A7FE8C63D5DB054931FE9BBB8FCEF249E83ED246EB0' }
        @{ Path = 'powershell\ref\System.Threading.Tasks.Parallel.dll'; Sha256 = '6D68830D67DA12F6C2ADF0E8A96B693D3557CBCDA8556ED664C11FE4AEFDD3B8' }
        @{ Path = 'powershell\ref\System.Threading.Thread.dll'; Sha256 = '5A8FC87073E7AE33249740C7AA2A32963B5CE6ACBFFE8D57A4F4A62EF02C22F6' }
        @{ Path = 'powershell\ref\System.Threading.ThreadPool.dll'; Sha256 = 'E32047C6A5FD3D871E0822AAFD445A4E06D0F01A113C8443A9F8D20627F5B512' }
        @{ Path = 'powershell\ref\System.Threading.Timer.dll'; Sha256 = 'AF0370E66F201115B9CC2BC774EE6E54858647381ED55BB72E44095478D03A44' }
        @{ Path = 'powershell\ref\System.Transactions.dll'; Sha256 = '32C9035D0D0425AC81823E0DCF390DA9873AF970D0C2856F584AC2470D806550' }
        @{ Path = 'powershell\ref\System.Transactions.Local.dll'; Sha256 = '7FA63222ED5D1C315A59A5D9F283685133D0D0CD441963D795A75BCA11A7D595' }
        @{ Path = 'powershell\ref\System.ValueTuple.dll'; Sha256 = 'E6EC3E8C2013A3387978258AA60E947B46EF1D0BDB97D26F860609E696E1365E' }
        @{ Path = 'powershell\ref\System.Web.dll'; Sha256 = '86C80FB864EECF77CD27C40BBA62C5385E44BB689C4FC3C123769ECF4D77EFC2' }
        @{ Path = 'powershell\ref\System.Web.HttpUtility.dll'; Sha256 = 'A518164132E4D9833B05D74F2586BB8B0D4AE34AA507FADA43C837C419338339' }
        @{ Path = 'powershell\ref\System.Windows.dll'; Sha256 = '32DCB5C5F2DBD85B744FF708F39E3A703F5A75E96BB715569452601DE11F1B4F' }
        @{ Path = 'powershell\ref\System.Xml.dll'; Sha256 = '28F10F4FFAD07B173AF6114E74C5F57E8E02ACCB59850EF22ABC4C6351EF349E' }
        @{ Path = 'powershell\ref\System.Xml.Linq.dll'; Sha256 = 'DAC823176F31B117DBAC2AD9576F59607425ECA50C73D02331AC3BC4852BB32E' }
        @{ Path = 'powershell\ref\System.Xml.ReaderWriter.dll'; Sha256 = '398C0FBB0655CC800F95EC24D451072EC4946D4D04B2F902B71B1F3963ACC127' }
        @{ Path = 'powershell\ref\System.Xml.Serialization.dll'; Sha256 = '3DB5344FC841410D44647DD5A1FEF3B1D543501D59DED9EBBC96BE2372913191' }
        @{ Path = 'powershell\ref\System.Xml.XDocument.dll'; Sha256 = '1DA029AE5199D5AA7EE31B188825F5FCEE46C26C7DB0288D154253085E862E50' }
        @{ Path = 'powershell\ref\System.Xml.XmlDocument.dll'; Sha256 = 'DD70D2A5487DA1FD127582DCE7F9981DCBA248D50683052055643DC9E321126B' }
        @{ Path = 'powershell\ref\System.Xml.XmlSerializer.dll'; Sha256 = '74E81C4D9FAF979E1385AEE18BC46639C79E265FDFD13CAB645F5D08F5532EDA' }
        @{ Path = 'powershell\ref\System.Xml.XPath.dll'; Sha256 = '7F5631A042F9E83FD8D00424183680F3DAC61B7BC07698C7DA4E40F460D54096' }
        @{ Path = 'powershell\ref\System.Xml.XPath.XDocument.dll'; Sha256 = '7DF88B906B2BE9B8F354EDCA23048C2A3B461E52A261521E169C2EEE79B6C6C6' }
        @{ Path = 'powershell\ref\WindowsBase.dll'; Sha256 = '79D27FE8E5F0B9EEF211809D683141A7FBE1AF2D920CA7E37456E9870856821E' }
        @{ Path = 'powershell\RegisterManifest.ps1'; Sha256 = 'E1977263D56BE983EB6F5B7DFFCE290B2C1B1F47161B67C82107742488DC3FEE' }
        @{ Path = 'powershell\RegisterMicrosoftUpdate.ps1'; Sha256 = '1983FB178B1948C1A2CB574240045CF640603F2A756BEAFDAE7647AA61B5CE82' }
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
        @{ Path = 'powershell\System.AppContext.dll'; Sha256 = '5824233C5A6129F5741E1E0BD14F60A58A38600BAC384DC8B3CD09F969D67543' }
        @{ Path = 'powershell\System.Buffers.dll'; Sha256 = 'B569DB17C9A66433310A3B71A86157F025AE573F60D4BB4E20E5D1C3CAC94896' }
        @{ Path = 'powershell\System.CodeDom.dll'; Sha256 = '011438B9D99D189DDECFAEB6F5439A447A186D6C8F90C1AE20FFEA8E707CE01D' }
        @{ Path = 'powershell\System.Collections.Concurrent.dll'; Sha256 = '00DCF6500D5A0796EC5878E5CFF60F15BBA20BAE3C6D574E0A194E4C2089839C' }
        @{ Path = 'powershell\System.Collections.dll'; Sha256 = '07DEDB131E9D8707A8025669F2B394CE512BE868817FD47BC107DC9E8E4645D3' }
        @{ Path = 'powershell\System.Collections.Immutable.dll'; Sha256 = '9BF7F6C680BBB73D4412A3319368DDB8E7B58C6A6358802B738E3C2CDC5574D2' }
        @{ Path = 'powershell\System.Collections.NonGeneric.dll'; Sha256 = '61BB3DDB69A1649AB3A77D5C9680532E41CF0596D347FDB9E43CB4729B2A6CDD' }
        @{ Path = 'powershell\System.Collections.Specialized.dll'; Sha256 = '1340913256353E85E0032196D5BA93507A190CD252686FFC19D5A5FC6AFBB3D4' }
        @{ Path = 'powershell\System.ComponentModel.Annotations.dll'; Sha256 = 'B3321A78A4D201096915EF125DD71579E88AE7E91DC8717245710F2DD2588476' }
        @{ Path = 'powershell\System.ComponentModel.Composition.dll'; Sha256 = '95596EB7EEF98FDE26EA4BB77DE9E513F6138316E608D87CE8B818812ADFC723' }
        @{ Path = 'powershell\System.ComponentModel.Composition.Registration.dll'; Sha256 = '024A80BAAA8EB1C713475619FD285DC6CB80FDC14E1BC9E689C7A95E7A8E0AF7' }
        @{ Path = 'powershell\System.ComponentModel.DataAnnotations.dll'; Sha256 = '0B47479C27B050E90CC0C232561781F71A85DF75686758EFF459890E73045D81' }
        @{ Path = 'powershell\System.ComponentModel.dll'; Sha256 = 'E6A85FF45D7EA39B809610331D1350275515FF840BC2CEC5A4D352F76A000F8F' }
        @{ Path = 'powershell\System.ComponentModel.EventBasedAsync.dll'; Sha256 = '0DEBE0EB6A38FB8F92EC7B58DF01C742ABB300AC71679E17A6BD42A9740499F2' }
        @{ Path = 'powershell\System.ComponentModel.Primitives.dll'; Sha256 = '088544116F6C6FC7C2D06ED33D580A0143FCEA73C1F14AA9B83E54D441F6E2EC' }
        @{ Path = 'powershell\System.ComponentModel.TypeConverter.dll'; Sha256 = 'CB58D0133E1DB4E85FF6502A55AC80160B7F06BEF147B3970D01926075D0B588' }
        @{ Path = 'powershell\System.Configuration.ConfigurationManager.dll'; Sha256 = '9A1E33236D4A74C76241A91ACBA60522FC2E10E4F6DD8753C1C756E1A761FC92' }
        @{ Path = 'powershell\System.Configuration.dll'; Sha256 = '1F7C4F09BD5EEBB988C7F6B16DB293260A7FFDAF30E407EE44D1E492E83AE78F' }
        @{ Path = 'powershell\System.Console.dll'; Sha256 = 'E406F27A12FABB43798D5B32238AB1C34EE10739102C150EEE50BC646A51E042' }
        @{ Path = 'powershell\System.Core.dll'; Sha256 = '7828FA13325F9B97DDD8D8E6DCB1CC54DE1AFC5FB2DC69A29F86CA686FB8E04C' }
        @{ Path = 'powershell\System.Data.Common.dll'; Sha256 = '92F99D39C9DF497047C2A1A5ED126A5025E79D03908170BE6DC6505453A27A1D' }
        @{ Path = 'powershell\System.Data.DataSetExtensions.dll'; Sha256 = 'F7DEC6629D252F03E1C90E0A2EAD24E482A2A24914101710391ABA6DC8A453C7' }
        @{ Path = 'powershell\System.Data.dll'; Sha256 = '5F1D2575F0A94826B2CC722BE1548929A2756A5D9F8009C3E2235DA400FDDD9F' }
        @{ Path = 'powershell\System.Data.Odbc.dll'; Sha256 = 'C895D4F5A0A48BA502FB01F75DC32DC4F41FB80B604626973CEBE8618BBDF44E' }
        @{ Path = 'powershell\System.Data.OleDb.dll'; Sha256 = 'F57A338E6A74F72E250B64102A1A58CD85265A5C5030B4E90B5857DFFE319DA7' }
        @{ Path = 'powershell\System.Data.SqlClient.dll'; Sha256 = '91A8304BA7CE009D6346AF7AD88D1988E53C9E4683DB1740550B8B1E54E19345' }
        @{ Path = 'powershell\System.Design.dll'; Sha256 = '38E1692B3A318305E414E1A90DDFC50C31F7E94B2F359507E95C8EE2FF865F31' }
        @{ Path = 'powershell\System.Diagnostics.Contracts.dll'; Sha256 = '7D564319C9C214C9B0C023FA3152242A1CB57B1BA1859A4B04DADC78C332D51E' }
        @{ Path = 'powershell\System.Diagnostics.Debug.dll'; Sha256 = '54340793A5D2F86AEDC1573F0C438BB53FF810C13AD839362FE153A560ACB9BC' }
        @{ Path = 'powershell\System.Diagnostics.DiagnosticSource.dll'; Sha256 = '8048C2AF87406C3573D09C78696171CA6F3BB155FAC3F7684E01406BBA61E700' }
        @{ Path = 'powershell\System.Diagnostics.EventLog.dll'; Sha256 = '963A6784919C68F7578A6D1763520BC80DCE329143B2FD6E18D972845C87CC56' }
        @{ Path = 'powershell\System.Diagnostics.EventLog.Messages.dll'; Sha256 = 'C03238DC0843945462D9EC0ABB80478EAFBCB71E94E254DFDDF15854D1DD1233' }
        @{ Path = 'powershell\System.Diagnostics.FileVersionInfo.dll'; Sha256 = '16257D9FD42996B0E12E7A0A2DA8DCEBAF05CC75CA6CF33E591790A10A69598A' }
        @{ Path = 'powershell\System.Diagnostics.PerformanceCounter.dll'; Sha256 = 'BD12A3657AF54E66CD26D2DD7709ED3E040C9365D2798FE58BAE9CC954558D6B' }
        @{ Path = 'powershell\System.Diagnostics.Process.dll'; Sha256 = '126BD07FB3A59D1880D1D5AC11ADE6E161932535EB5104550C4EBA1D0ABBFEF0' }
        @{ Path = 'powershell\System.Diagnostics.StackTrace.dll'; Sha256 = 'D1E815E1FA1AEBDB63BAB5C1878DDBA84DD4C0E837545FF83D593620E054CCA4' }
        @{ Path = 'powershell\System.Diagnostics.TextWriterTraceListener.dll'; Sha256 = 'A2CC28D05D8B7A2F0D224B6C9A77D9A546D69029AAD266A1A6EF33C4DDE33F4F' }
        @{ Path = 'powershell\System.Diagnostics.Tools.dll'; Sha256 = 'A39E302A28F1F35CD9CD975C52358C7796330080920DDC4DCD3B336760B769FC' }
        @{ Path = 'powershell\System.Diagnostics.TraceSource.dll'; Sha256 = 'B2663087D8CF28CA42851A67213A44B6D608F5676E2E0DDA0B1DA14F371DA723' }
        @{ Path = 'powershell\System.Diagnostics.Tracing.dll'; Sha256 = 'A6DCCAE8D2C8ECDDBC6C53D70F58DAEC02B45431EDB4AFFD74D9626CFE073D07' }
        @{ Path = 'powershell\System.DirectoryServices.AccountManagement.dll'; Sha256 = '7E5E9B6C49C6E2C8C499307C379EF5BAFEC6233792FA4E1366A25A6EF993F790' }
        @{ Path = 'powershell\System.DirectoryServices.dll'; Sha256 = '3516B5024C20C9BD91C0DD0031B71E20DAD648757E38CCEAF3E3896C0916B74C' }
        @{ Path = 'powershell\System.DirectoryServices.Protocols.dll'; Sha256 = '065A6BE070A467BDEB53FC0035D1A8B4088504304BF8521063122D846BB01A10' }
        @{ Path = 'powershell\System.dll'; Sha256 = '22226DEBB0D6601D54F69CA122FD65AF07BB869A6F8CB3141374BCE0705E859D' }
        @{ Path = 'powershell\System.Drawing.Common.dll'; Sha256 = 'AC603599F35D7D8389CF91FD407F72CBBC5896274B4F8383CB47DC67F671F03D' }
        @{ Path = 'powershell\System.Drawing.Design.dll'; Sha256 = '2EA6EEF09FEF23D0BA0704C21B5A76C342006E4FB9CEA9BDC948CC7927EB61AF' }
        @{ Path = 'powershell\System.Drawing.dll'; Sha256 = '790A6025CAAFC9D21CD9CBBE438B70C4B0AD781B4FB9E210E1F50868A4DFF42F' }
        @{ Path = 'powershell\System.Drawing.Primitives.dll'; Sha256 = 'F86FECB7B6D545D57F4584F1C6DD499A747C760AFC408B5D4F33A0A22813257F' }
        @{ Path = 'powershell\System.Dynamic.Runtime.dll'; Sha256 = '02B2C3FD58F793718FD4A0707993B3CFAC272541166ADA7B0373902FE5FC6384' }
        @{ Path = 'powershell\System.Formats.Asn1.dll'; Sha256 = 'DDDDE5E0942E6ED249F905D5D58BBA797756477FE3424C94BD60ABB73E95BC8F' }
        @{ Path = 'powershell\System.Formats.Nrbf.dll'; Sha256 = '7ADF49F2D9D995A8B5DF5C5345DF23D78B33666579EEA906329D18D8852F59BA' }
        @{ Path = 'powershell\System.Formats.Tar.dll'; Sha256 = '0A49E083ED13E4DDE812DC870E26F87E1E86A1B0592A661ED498EE49A274C2F3' }
        @{ Path = 'powershell\System.Globalization.Calendars.dll'; Sha256 = 'D169ED333B4BAB2D6F9BA6A0FC9E4F1A8301E97E9C265A46D949EA5651080C0D' }
        @{ Path = 'powershell\System.Globalization.dll'; Sha256 = 'BDEB8D26D917976915190C6213907967B5A2CE83B7C575B67A71D121993DFD24' }
        @{ Path = 'powershell\System.Globalization.Extensions.dll'; Sha256 = '4A5FF15607BB3AF1016A471EB2E3E93B94AB60DA4B862DE5DE9AEA27FB1DDF8A' }
        @{ Path = 'powershell\System.IO.Compression.Brotli.dll'; Sha256 = '4453592A0674B86B0CD41BF3E021B22B3E118B7598926D5DF4676DA1A8CE24E6' }
        @{ Path = 'powershell\System.IO.Compression.dll'; Sha256 = '8637CDEE8CB539B4DC492B775805C6611B3A21226F13FAA91BABBB427E931FCF' }
        @{ Path = 'powershell\System.IO.Compression.FileSystem.dll'; Sha256 = '889ECC7A7C5B44071AAB2826FD6D6B8DAD8B88EA04119870A3E4F2CAAAE95009' }
        @{ Path = 'powershell\System.IO.Compression.Native.dll'; Sha256 = '68D68E5AAD37470310F2B723AFEDA6447CF53746AD8E3FFABF44CDA8CDCDA6BD' }
        @{ Path = 'powershell\System.IO.Compression.ZipFile.dll'; Sha256 = '5534BFE9BCCFB28357B85BB4B9F8692A25AEFF40C03951813F55621F333BC5B4' }
        @{ Path = 'powershell\System.IO.dll'; Sha256 = '2699CE957E080E2FA5F87CFEDFC0D469475FD8D1ADA1F5DB09C48A085C2282E3' }
        @{ Path = 'powershell\System.IO.FileSystem.AccessControl.dll'; Sha256 = 'C692A48AB5D7EF5389AF22FBEAFAF44A7A495EAC4D0E9D18F5CEDD8A691818B8' }
        @{ Path = 'powershell\System.IO.FileSystem.dll'; Sha256 = 'B2B09F39E7CB61DDDB3658D95A4FEB62498D25A9A477A1E11F5FAF36D829A19B' }
        @{ Path = 'powershell\System.IO.FileSystem.DriveInfo.dll'; Sha256 = 'B590790F7378243ADEB02003911506491A9B76DC3D2B01ACD5B7DC485A0C76BB' }
        @{ Path = 'powershell\System.IO.FileSystem.Primitives.dll'; Sha256 = '0602E2F6227D8A0842BBA942FB84C9A68331266802C449AF9E11AEB45F9193FE' }
        @{ Path = 'powershell\System.IO.FileSystem.Watcher.dll'; Sha256 = '0FFC38C087054451077A66E4C7F3C5B35869EF7911B5CC1598E7939EF3879A07' }
        @{ Path = 'powershell\System.IO.IsolatedStorage.dll'; Sha256 = 'AAC0D8B2736EC46166BEF6F2796B6F621AF686552326F3E7E73921B7792989DD' }
        @{ Path = 'powershell\System.IO.MemoryMappedFiles.dll'; Sha256 = 'EB75D6A39E2BABC14F70C12B1DBCDB57FB8763BD79D038C80B21182689B70F50' }
        @{ Path = 'powershell\System.IO.Packaging.dll'; Sha256 = '677D1647C54627E092A898F3CE63740F3CA7335834312411835BE950A9AEE698' }
        @{ Path = 'powershell\System.IO.Pipelines.dll'; Sha256 = '876F3FF1E05892226C1F0363468CDFDA8F023B21400EE6177A56A1405914E1AA' }
        @{ Path = 'powershell\System.IO.Pipes.AccessControl.dll'; Sha256 = 'E34322B26EA5ACA715C6F92C3177556A02083E82D561EA90F37A12CAAEBE90D3' }
        @{ Path = 'powershell\System.IO.Pipes.dll'; Sha256 = 'AD25EC1FD00DEF55631C6EC891B3BD270B80CE1754F90D4190F2CAEA28B8B842' }
        @{ Path = 'powershell\System.IO.Ports.dll'; Sha256 = '4E9EE3EEBC4C184E5575B52586DDAEC34F521E3CC85F3DB8DE4B49230875588B' }
        @{ Path = 'powershell\System.IO.UnmanagedMemoryStream.dll'; Sha256 = 'E3B1BA5A4FF28EE788F1E88DFBB50762135A7C29F0ADB93DBAC9AC5284DEC769' }
        @{ Path = 'powershell\System.Linq.AsyncEnumerable.dll'; Sha256 = 'E4A6FCC5BFC7D9B9038E3A2D26E17AA9244B7B6A25B10C4CE3CF205689661040' }
        @{ Path = 'powershell\System.Linq.dll'; Sha256 = 'DC992BA1C1BAC514D14CC923C154A6466BE5A250C2B02C220F8F5D63074718E9' }
        @{ Path = 'powershell\System.Linq.Expressions.dll'; Sha256 = 'A4FCBD909BB6FDD8A058C06F23BD149A9DFB0B9462C2F757DBBC1DA9DFD583E4' }
        @{ Path = 'powershell\System.Linq.Parallel.dll'; Sha256 = 'ADEA4CF143F5DA17A6D34BBD786DEB47EC299DD6010F844DC9D53C386F4740D4' }
        @{ Path = 'powershell\System.Linq.Queryable.dll'; Sha256 = '600E77C705BF8550DBF0D1C3965020046424537362C3F76234FEAEB12CC69844' }
        @{ Path = 'powershell\System.Management.Automation.dll'; Sha256 = 'A689B32ADCEA9A781CAA0FBAE25CA55ED40F084247FC877D2CBBC8278D283C01' }
        @{ Path = 'powershell\System.Management.dll'; Sha256 = '1CAF406DE6A3706E9E0870443CDC9618DA17CA877E47C81CE2A23B63C3644D01' }
        @{ Path = 'powershell\System.Memory.dll'; Sha256 = 'AD367E1B7B733AA840CD6595EAD967ACB9FD9969CF644E06689BF2E841B515A0' }
        @{ Path = 'powershell\System.Net.dll'; Sha256 = '9966E1605FDA50D083BEAA307BCDB9DAF0D8B7BAE84771265D8C44534748FFD8' }
        @{ Path = 'powershell\System.Net.Http.dll'; Sha256 = '2DB574037FE8CB2465043D080677D64C2B0AC0E4BB3944E6B6E84218C65D691C' }
        @{ Path = 'powershell\System.Net.Http.Json.dll'; Sha256 = '354C0900786B9614BD89130888542B2098B1968EBB1A3BF838C82BBC0FB0211F' }
        @{ Path = 'powershell\System.Net.Http.WinHttpHandler.dll'; Sha256 = '723F01670301E20F7264D8AEF2F679DA751DB7C0F426EC4DB5507890E53028EA' }
        @{ Path = 'powershell\System.Net.HttpListener.dll'; Sha256 = '3FF234307783F345D9B11946BF1B8CDCAC1F761E58526563D96392ACB2612FF7' }
        @{ Path = 'powershell\System.Net.Mail.dll'; Sha256 = 'BE2372646D6BF42AFEF16F9FE5C3514577CA8AA99B3D667FE7C808A5999CAB9A' }
        @{ Path = 'powershell\System.Net.NameResolution.dll'; Sha256 = '7BBEBA9120A3ECE73BD39FA2539750695F37815C8C6411C190CD20D3493BFDCA' }
        @{ Path = 'powershell\System.Net.NetworkInformation.dll'; Sha256 = '499F0D2788382E9E628C3C82F57BF0DD8E86D7CC00B70765BCA5153315EAA10F' }
        @{ Path = 'powershell\System.Net.Ping.dll'; Sha256 = 'CE93405CF2004EFC69DA60F2EBA371BF6461631E8D37365209F74516DD917113' }
        @{ Path = 'powershell\System.Net.Primitives.dll'; Sha256 = '607BCBF14BEBE5643257D26D67968E16CBE6B02180E7FF8D337B428AAA80D52B' }
        @{ Path = 'powershell\System.Net.Quic.dll'; Sha256 = '01F534DF790AC9E11CF79E0E69C42CFC2DFAB44C3DA8C87D7D4AF69188FF9307' }
        @{ Path = 'powershell\System.Net.Requests.dll'; Sha256 = '83586745515C0FD0E5D48248871FD9F7225657DE5595C8B48E4D6A88BF4EFEEC' }
        @{ Path = 'powershell\System.Net.Security.dll'; Sha256 = '5CA4924950689ADE61055DAEC5FD99D9F617ACAFABDD5B21C09E4329195909A7' }
        @{ Path = 'powershell\System.Net.ServerSentEvents.dll'; Sha256 = '324B0F8D305C967ADCCCE3F126BF470E8AAA0A62D84695F71FEB700F741D0ABF' }
        @{ Path = 'powershell\System.Net.ServicePoint.dll'; Sha256 = '678104FE7E696B9B182734ED4BBDE61F23E8466C942A68BAA9F9E504781AA978' }
        @{ Path = 'powershell\System.Net.Sockets.dll'; Sha256 = '6EE2E8C007D307D94DCDB9B1864C0894CA1621C51F43D2683981CAC4F7823B7E' }
        @{ Path = 'powershell\System.Net.WebClient.dll'; Sha256 = '6D34F1715CBBB24445B88D3FA62BDE425835471B72B04A6A20E2F96DC356A96F' }
        @{ Path = 'powershell\System.Net.WebHeaderCollection.dll'; Sha256 = '31E1EE3AD85465B84E818A903E0E87AB86B7B9C8943FEA7136E13884F555CF8F' }
        @{ Path = 'powershell\System.Net.WebProxy.dll'; Sha256 = '3E0FFF6D5A0F0FCD6FAC449EC6F81AB4BBB65BF4D1844097264DE03C6A9E12B5' }
        @{ Path = 'powershell\System.Net.WebSockets.Client.dll'; Sha256 = '3929ECBF7FE9730AA09087CE1B0B95F7AD488700ED297A7B1DB9BCDFFD379EB7' }
        @{ Path = 'powershell\System.Net.WebSockets.dll'; Sha256 = 'E53874D48ACEC015893A570BBF02502905985FA66CA75B4F5F864EFF219F5F87' }
        @{ Path = 'powershell\System.Numerics.dll'; Sha256 = 'DA30DDC2FBFED6382C9A029F4AB19ECA96A60CE36BDA432F2FEB5E209CCD2457' }
        @{ Path = 'powershell\System.Numerics.Vectors.dll'; Sha256 = '1A2E6F7979950300C1BD28A8EA82D37BBF361D83FB2265B1577513B0D6DF9633' }
        @{ Path = 'powershell\System.ObjectModel.dll'; Sha256 = 'E10EE7CE6C29FB120F6609C74AB7D15732BC9EECCA99E2341D955799F6A33216' }
        @{ Path = 'powershell\System.Printing.dll'; Sha256 = '88273C8779147BB044BE4AD0F7447B14B4088C3A42349DE7F516D119A96C39B1' }
        @{ Path = 'powershell\System.Private.CoreLib.dll'; Sha256 = '983F5C8957437AA38FCD239606E60DC2A4A6F551605311591A72E5B285EAE957' }
        @{ Path = 'powershell\System.Private.DataContractSerialization.dll'; Sha256 = '708714C803EC517C49F88A367E973E4C8A9B818D1A040F67D0A99CA1863E50FB' }
        @{ Path = 'powershell\System.Private.Uri.dll'; Sha256 = 'E13E63BEE843AAB6B4D21A4913001E9233397FA0C499B9131A63B75FEACF3D5E' }
        @{ Path = 'powershell\System.Private.Windows.Core.dll'; Sha256 = 'DC096F18E2B6AF06160D3772CD2D04281F9FD63F3BC2CE5620541601806BEC89' }
        @{ Path = 'powershell\System.Private.Windows.GdiPlus.dll'; Sha256 = '2C758B2425726D0C10F62E09C14CA7ADF1A62FBFB8212129AF8EBAF0E32079BE' }
        @{ Path = 'powershell\System.Private.Xml.dll'; Sha256 = 'E821F3686BC217CA44FE3A41C1B1C87ED4074651C8A95640B7B7BC567AB029FC' }
        @{ Path = 'powershell\System.Private.Xml.Linq.dll'; Sha256 = '18C4E66A11DDC87AD9783439FE8097658ACBC363E637B64CE65EC3574E84B057' }
        @{ Path = 'powershell\System.Reflection.Context.dll'; Sha256 = '5460BE1AEA0C09CEEBB1A0C16D4691509C7C8B827C02DFB92A69A169289F36C5' }
        @{ Path = 'powershell\System.Reflection.DispatchProxy.dll'; Sha256 = 'AA7216F50F0729958763CB49931E74369C689C22618A0EBAC4F92C7DF5B1ED52' }
        @{ Path = 'powershell\System.Reflection.dll'; Sha256 = '9AA8ACB636611BA2324BEDD4DD9650BC9E7A1F016CF7ACC4C2A69051C0CBED4B' }
        @{ Path = 'powershell\System.Reflection.Emit.dll'; Sha256 = '98ECC074B2E42194DAABC81DDAFB55A7B3552EA18E8218442301BEEE0D5556E1' }
        @{ Path = 'powershell\System.Reflection.Emit.ILGeneration.dll'; Sha256 = '04B1BF369E833D65C35EA84ECEA7F69D125DF2C5A224962B95AC43372790BD1A' }
        @{ Path = 'powershell\System.Reflection.Emit.Lightweight.dll'; Sha256 = '70D3E152E9C235B5D2945EBC8AD1DF3C06A815677097A9DF9CB192C33E4B1C38' }
        @{ Path = 'powershell\System.Reflection.Extensions.dll'; Sha256 = '1ACBC49DEB1A9410CFA6B357C1F2E185E8183584CF4AB237961DDD7A561A0EFB' }
        @{ Path = 'powershell\System.Reflection.Metadata.dll'; Sha256 = '4130C090AA1ED9A026EA6473BE258B9E07DCB05097836AC569853272679A5C97' }
        @{ Path = 'powershell\System.Reflection.Primitives.dll'; Sha256 = '8B2327CA2DFFB76764610D6DCDE98416DF67F18891AEA728E1259CFC001E73A9' }
        @{ Path = 'powershell\System.Reflection.TypeExtensions.dll'; Sha256 = '380E0B37748C77A120F42EF91453099520BC45AF1B0C65B0D3FA6B88F0FA4738' }
        @{ Path = 'powershell\System.Resources.Extensions.dll'; Sha256 = '0313434EA8678F32A42C8F96F84AC32AF44AE73B6A5E393724D59DF32861B6F0' }
        @{ Path = 'powershell\System.Resources.Reader.dll'; Sha256 = 'C72A47E82365921B09A61F1CA72B722E4D28683D085035937DBFCE32BA4503E2' }
        @{ Path = 'powershell\System.Resources.ResourceManager.dll'; Sha256 = '41B34AA003A48C68FBA186CD7B5EA4F68E8F6CE4418BD5A68A158A79AD58293C' }
        @{ Path = 'powershell\System.Resources.Writer.dll'; Sha256 = 'F4DD1D6FC7F69848F36FF753727331B10D49A5F58D089E18E5D0C10EAF5A0AFA' }
        @{ Path = 'powershell\System.Runtime.Caching.dll'; Sha256 = '2E4B3C6D91CEB13543AAE4F56A89AC71D5E951B8B375A47B280AA0961ED319A8' }
        @{ Path = 'powershell\System.Runtime.CompilerServices.Unsafe.dll'; Sha256 = '0C2A4E77F62BC47E73EE4868364D7DE3013CC41B42F71989F601C0CFB2EF8C8D' }
        @{ Path = 'powershell\System.Runtime.CompilerServices.VisualC.dll'; Sha256 = '3ED2279DECBA500727A9CB1D810C08148BDA497975EFDC5DB21D636B4B78F9EF' }
        @{ Path = 'powershell\System.Runtime.dll'; Sha256 = 'D610A5690AB8F3AB8329C06517694C51AEC0E31CD4D7E375584DDCFF7C844751' }
        @{ Path = 'powershell\System.Runtime.Extensions.dll'; Sha256 = '95B093657B594177EF20472048C926BB9AE39FEAE5783D6C630F56183937C433' }
        @{ Path = 'powershell\System.Runtime.Handles.dll'; Sha256 = 'DDEDBBB02981ACDE482BD310B3B48FE9A7003DEC68D0CC4B9BCC3663F187A2A8' }
        @{ Path = 'powershell\System.Runtime.InteropServices.dll'; Sha256 = '5AB8804E4FBD1A5A54AFD9E674AF544642B73916E25EE672E7B99ADC3161ADFC' }
        @{ Path = 'powershell\System.Runtime.InteropServices.JavaScript.dll'; Sha256 = 'AC07E7DF59A35BF4EE5EF78502CE187A1880B83612A7BAC427F78255C172D35C' }
        @{ Path = 'powershell\System.Runtime.InteropServices.RuntimeInformation.dll'; Sha256 = '499C566F61B78A68D0F48EBB3A6D431C4F3875A1067943D903EAB1E7D43FEDC0' }
        @{ Path = 'powershell\System.Runtime.Intrinsics.dll'; Sha256 = '422F93053057449C08DAA91B49F2EB7503FA4CCC1462EF5556CFE0E1FA5B0003' }
        @{ Path = 'powershell\System.Runtime.Loader.dll'; Sha256 = '20660CE31358FE64B0A44AA0BB08022E1081F7D8E1C24A27673E74123000908E' }
        @{ Path = 'powershell\System.Runtime.Numerics.dll'; Sha256 = '53B5BF64FD79C665ADC58607116D33C4B2BE3AE12E22360267E263E695886E57' }
        @{ Path = 'powershell\System.Runtime.Serialization.dll'; Sha256 = '20C4A3E000268704D5A9FA72E10DDEC5A462F2ED5ECD18E24D53C0B6929D15ED' }
        @{ Path = 'powershell\System.Runtime.Serialization.Formatters.dll'; Sha256 = '771BC4A61A546CD4A24332FA9161A94D2E55FA08600F8BF9250F6EB08A9AFB77' }
        @{ Path = 'powershell\System.Runtime.Serialization.Json.dll'; Sha256 = '025A34F5DBFF2489BD101924ACA35A01BFA1F9D842598E2E041B6EDB8FF6845D' }
        @{ Path = 'powershell\System.Runtime.Serialization.Primitives.dll'; Sha256 = 'ACF3DE0F2562FC05D70627944453443B1A9396A1D0A6ED598BEEAC35CA266057' }
        @{ Path = 'powershell\System.Runtime.Serialization.Xml.dll'; Sha256 = '347900EBBBA53A24797599363BF10070580FC970A9A6CE8D84DC95F416FEBFEA' }
        @{ Path = 'powershell\System.Security.AccessControl.dll'; Sha256 = '2081ED669EEC7431786A8529506F60D2C2ED3B83523EEA0D4FD627DAC29E2F4A' }
        @{ Path = 'powershell\System.Security.Claims.dll'; Sha256 = 'BC239918DECBBD1E90F16C30F0182507342A5B0A82DC2D095E9B365AE0A391AB' }
        @{ Path = 'powershell\System.Security.Cryptography.Algorithms.dll'; Sha256 = 'BFEBCC7308E202B1971D621883574A203ECAB74AE992A152DD4071ED08FA00D7' }
        @{ Path = 'powershell\System.Security.Cryptography.Cng.dll'; Sha256 = 'A238BC58DABF109AA46685CD4AA3D18A8CC35F4B1E3788710465F2AFE5813C9C' }
        @{ Path = 'powershell\System.Security.Cryptography.Csp.dll'; Sha256 = '3737F8EA4D0A41D83E3E2D860E74B3CA2AAB7349F9A265577B0F66FAAA6EF109' }
        @{ Path = 'powershell\System.Security.Cryptography.dll'; Sha256 = 'BEA35C3EAF37895B32FF2B90D4B077D61732A7BCC7C9178AA441719D72503BE0' }
        @{ Path = 'powershell\System.Security.Cryptography.Encoding.dll'; Sha256 = '75B36584506DBD64B68E0D60A2189F70F03262D620CDF26B394B0ABC97FE52FD' }
        @{ Path = 'powershell\System.Security.Cryptography.OpenSsl.dll'; Sha256 = 'DC856022EBDEC7F030817C7A6A5FCDA06AEFAA7E2C7B4CD83D8525DB476D9823' }
        @{ Path = 'powershell\System.Security.Cryptography.Pkcs.dll'; Sha256 = '5F636C5B1AC88857C417EDD4EEA592C87D24F1C57B2F8BF1A588D36B1005FAB6' }
        @{ Path = 'powershell\System.Security.Cryptography.Primitives.dll'; Sha256 = '2D4F209F4B2F7BC0AF1E7FB39C99349F6AD081689E89028A8DCE1D580E1F39D9' }
        @{ Path = 'powershell\System.Security.Cryptography.ProtectedData.dll'; Sha256 = '4538DB41590E506E3BEDC9D3F0A55230DD8ABD0ECFBC0DBCC49DC904BB14E6C5' }
        @{ Path = 'powershell\System.Security.Cryptography.X509Certificates.dll'; Sha256 = '6FE5848BAFD502672FD206E4208B64E1ACA84627427E131E33167B0795309207' }
        @{ Path = 'powershell\System.Security.Cryptography.Xml.dll'; Sha256 = 'A6881FB32D9318EDEF94694958DC06C15BCF162AC6BCF5D1792325F73E7BF23A' }
        @{ Path = 'powershell\System.Security.dll'; Sha256 = '4887E93D7FBF6C6F0909579400EF892D42896A2123CC1A0C702F7C555E9E9D98' }
        @{ Path = 'powershell\System.Security.Permissions.dll'; Sha256 = 'E56984C7C415F3D06503A8BC30B434269FACD7D172AF6A0287CC677EC1B55583' }
        @{ Path = 'powershell\System.Security.Principal.dll'; Sha256 = '089428925C94B2CD5A5FAEDE9BF7799FFA144E899A1E56F1C2C05159660DA580' }
        @{ Path = 'powershell\System.Security.Principal.Windows.dll'; Sha256 = '6D8813FB7478E09D1411E48143D05306A11C88E2D7B48CED68B527C3E3BC97DB' }
        @{ Path = 'powershell\System.Security.SecureString.dll'; Sha256 = 'F51D458BDE0A367EBEC626CC1C2247A374F5145170FD5DF9FD501426F2CC2C4B' }
        @{ Path = 'powershell\System.ServiceModel.dll'; Sha256 = 'CF390C8379F3249937DA11DAD3A5BA88804A7453503A246BE01FC849B899653B' }
        @{ Path = 'powershell\System.ServiceModel.Duplex.dll'; Sha256 = '5E7D8985922C7D7D673D2D204C2F6D12E3F70F70D0E9FF15507FECD2026A8815' }
        @{ Path = 'powershell\System.ServiceModel.Http.dll'; Sha256 = 'FCF12F97A1D17C773B964C8DE58A82B97E9BB2936C55EAF7F301C9A6BBAF0DD7' }
        @{ Path = 'powershell\System.ServiceModel.NetFramingBase.dll'; Sha256 = 'EAE6FAAC554424BA528786752A123BE2795CD4A119B1434CFFB2863500A054BD' }
        @{ Path = 'powershell\System.ServiceModel.NetTcp.dll'; Sha256 = '568512C4520F6E8421F63924C89869A226547C74673174E3B767DF4A8033715A' }
        @{ Path = 'powershell\System.ServiceModel.Primitives.dll'; Sha256 = '66645440E6BA51A1FCC67BC6521F5AA8717CA2148FEAB7165A1F78A37FD33B35' }
        @{ Path = 'powershell\System.ServiceModel.Security.dll'; Sha256 = '99EC51765CF53B36DC1064A48DB4C910EDB17C92E176E03B947E5E200B82F7D2' }
        @{ Path = 'powershell\System.ServiceModel.Syndication.dll'; Sha256 = '6066407E247D1A75E77991191B42FF08921F71F02357C7FC2EB12AFC8D30B018' }
        @{ Path = 'powershell\System.ServiceModel.Web.dll'; Sha256 = '9AF5E984ADF9989A462618C55DE79429563EE20F583E40AD9D001F5022D0B4BD' }
        @{ Path = 'powershell\System.ServiceProcess.dll'; Sha256 = 'E40FC253A50BEE22E6E20E1AF1140BDEB5E92F4459F0427BC8A05A0E81E74821' }
        @{ Path = 'powershell\System.ServiceProcess.ServiceController.dll'; Sha256 = 'C0EB8D0DFB68AE03329691D69921CC97340C7FBEB4B3654C583785765CB08338' }
        @{ Path = 'powershell\System.Speech.dll'; Sha256 = '2892BDA2288BAE4290E12FCA8A59023D0CCC32C096AC61735B880325C648F8FC' }
        @{ Path = 'powershell\System.Text.Encoding.CodePages.dll'; Sha256 = '372A3490AA5E4F6A56625A34615597590475E75588DBF27A20202CE5C12AE998' }
        @{ Path = 'powershell\System.Text.Encoding.dll'; Sha256 = '677FEF60BE9ACB153BE1CCAAC221ECC93C358231D21CBFD69C98AE98FA71929B' }
        @{ Path = 'powershell\System.Text.Encoding.Extensions.dll'; Sha256 = '3FC0097CE6E2D9F30F180EC390213593B778C04668BB882F860157BA7F6E956D' }
        @{ Path = 'powershell\System.Text.Encodings.Web.dll'; Sha256 = '34236C5DDBADBD3F96D0AAEB20E4525E88534FC28F1CA0B016D83848529F1167' }
        @{ Path = 'powershell\System.Text.Json.dll'; Sha256 = '24556D153C5C00AF2F5722A36AAF76939849676BCA64FCE21AD9B30ECC1A7F64' }
        @{ Path = 'powershell\System.Text.RegularExpressions.dll'; Sha256 = '19CC43F776292F988FE33ABB15FE5CDD1F0540E97A2EC631161C9207E30DA6EF' }
        @{ Path = 'powershell\System.Threading.AccessControl.dll'; Sha256 = 'CF3CD1099D2BF0D14D2663413EFA99EF35ED934D3515BE1C7264DF58FF79C1E2' }
        @{ Path = 'powershell\System.Threading.Channels.dll'; Sha256 = '91748936A96442FAD345CCEDA65225708729950E3E19AB1259522F24F70BDC5A' }
        @{ Path = 'powershell\System.Threading.dll'; Sha256 = 'EBAA9BD6123C18B401B0A6606D5BE5275A4BB3FE73FF623698C07DF256DD5E3E' }
        @{ Path = 'powershell\System.Threading.Overlapped.dll'; Sha256 = '3042C32BB00BC3F4C182B29B39043B8BFE519DBC15AE31F1B7A57B8231958A58' }
        @{ Path = 'powershell\System.Threading.Tasks.Dataflow.dll'; Sha256 = 'E17E81E9395F0620F8F19653A4E10CABDC968BFC2B4F8F0BFBFA729A1042537A' }
        @{ Path = 'powershell\System.Threading.Tasks.dll'; Sha256 = 'F0BB5A82E4F78A07499688319BA0BF5078758DDDD5C6007028D65A18BAEFF45E' }
        @{ Path = 'powershell\System.Threading.Tasks.Extensions.dll'; Sha256 = 'C5273C4E16BE5914A4975A7FE8C63D5DB054931FE9BBB8FCEF249E83ED246EB0' }
        @{ Path = 'powershell\System.Threading.Tasks.Parallel.dll'; Sha256 = '52AAF2BB3024068F062E92DB12B6913B5C9AD3B92122B1AC0370FE0F40F06753' }
        @{ Path = 'powershell\System.Threading.Thread.dll'; Sha256 = 'CD8833667E8F837040194EE9CCA2E3E047C50A897E1514F59049C9D95E354A42' }
        @{ Path = 'powershell\System.Threading.ThreadPool.dll'; Sha256 = '5D6B7A66161BCA76C646C3EF954386BDDEF60070317D7381BD1F3CAE3B6ED4CB' }
        @{ Path = 'powershell\System.Threading.Timer.dll'; Sha256 = 'AF0370E66F201115B9CC2BC774EE6E54858647381ED55BB72E44095478D03A44' }
        @{ Path = 'powershell\System.Transactions.dll'; Sha256 = '32C9035D0D0425AC81823E0DCF390DA9873AF970D0C2856F584AC2470D806550' }
        @{ Path = 'powershell\System.Transactions.Local.dll'; Sha256 = '2D43FF58649A8B680A95731321A172473381A54FB18BD78063702ECD1804DF6F' }
        @{ Path = 'powershell\System.ValueTuple.dll'; Sha256 = 'E6EC3E8C2013A3387978258AA60E947B46EF1D0BDB97D26F860609E696E1365E' }
        @{ Path = 'powershell\System.Web.dll'; Sha256 = '86C80FB864EECF77CD27C40BBA62C5385E44BB689C4FC3C123769ECF4D77EFC2' }
        @{ Path = 'powershell\System.Web.HttpUtility.dll'; Sha256 = 'A8228332990BAE9EA580DC61CAB15AC7A9D3BA02FC0CA66D88658FC9A60A1299' }
        @{ Path = 'powershell\System.Web.Services.Description.dll'; Sha256 = 'B5B76A07613419A50C8478C186775B47CD50AD4942ED7B27AC91010731B08C91' }
        @{ Path = 'powershell\System.Windows.Controls.Ribbon.dll'; Sha256 = '02BDB12DB731E0B882AD4004E06F18B418F8072E4BFE14C8EC0F4CF1A10F45B5' }
        @{ Path = 'powershell\System.Windows.dll'; Sha256 = '32DCB5C5F2DBD85B744FF708F39E3A703F5A75E96BB715569452601DE11F1B4F' }
        @{ Path = 'powershell\System.Windows.Extensions.dll'; Sha256 = 'D1FD61D926DE0CEEE305BCE6AD639829CBAFACF9E91C4999B999CFD88955CAD6' }
        @{ Path = 'powershell\System.Windows.Forms.Design.dll'; Sha256 = 'F15D79F9C205A8189A38C753CAA5A2C556BF601099D889D96DF4B6C9BC86D1AE' }
        @{ Path = 'powershell\System.Windows.Forms.Design.Editors.dll'; Sha256 = 'C6CE67B9A2E53C1ABDD6791209E83BE2ED72E34D52643EC55F96B23F6ABB756F' }
        @{ Path = 'powershell\System.Windows.Forms.dll'; Sha256 = 'E64A7D4CC4988DC78F8231C8B2A2A501D3464F70E461FC72253207B194B3901D' }
        @{ Path = 'powershell\System.Windows.Forms.Primitives.dll'; Sha256 = 'DAC7659C0440B15657F3500F17B7C54D97E7E40E43DD8563904090D43A93E947' }
        @{ Path = 'powershell\System.Windows.Input.Manipulations.dll'; Sha256 = '06AB63ADD1F3C0E1E355A44E568D615B5BB5DB5F7965FA880FE686D3FD79FCDD' }
        @{ Path = 'powershell\System.Windows.Presentation.dll'; Sha256 = '500549D35B85D7D1860D1A55475DC63E2187563806A34A4D627A0072FC8C0717' }
        @{ Path = 'powershell\System.Windows.Primitives.dll'; Sha256 = 'CB33B5F0D10EB3E1F03CC74B6F68C40C828C7C9A0240A216DFA3599BACC6736A' }
        @{ Path = 'powershell\System.Xaml.dll'; Sha256 = '75B4D598E3DDCFF1C78994F694FBF9A6AA6C505F762D11BE828BD19011ED2918' }
        @{ Path = 'powershell\System.Xml.dll'; Sha256 = '28F10F4FFAD07B173AF6114E74C5F57E8E02ACCB59850EF22ABC4C6351EF349E' }
        @{ Path = 'powershell\System.Xml.Linq.dll'; Sha256 = 'DAC823176F31B117DBAC2AD9576F59607425ECA50C73D02331AC3BC4852BB32E' }
        @{ Path = 'powershell\System.Xml.ReaderWriter.dll'; Sha256 = '2C0D73CEB380F0BF0E2620DD3C270D926C903DC563A5E8879333EAAE5F57BD49' }
        @{ Path = 'powershell\System.Xml.Serialization.dll'; Sha256 = '3DB5344FC841410D44647DD5A1FEF3B1D543501D59DED9EBBC96BE2372913191' }
        @{ Path = 'powershell\System.Xml.XDocument.dll'; Sha256 = '30651001959F0B6DFCCD4432CBCFD0D07DA0C5948D8914A109F108A9517D3B8B' }
        @{ Path = 'powershell\System.Xml.XmlDocument.dll'; Sha256 = 'DD70D2A5487DA1FD127582DCE7F9981DCBA248D50683052055643DC9E321126B' }
        @{ Path = 'powershell\System.Xml.XmlSerializer.dll'; Sha256 = 'D7A56B018CD7419E83B60AECBC5AB01A1BBCC2B17F6C29E31E1CEC8D3B1C08F8' }
        @{ Path = 'powershell\System.Xml.XPath.dll'; Sha256 = 'EADCA97DE5FB0750E725C7E1F02BA20636FCE6E0F8417E67D72F0A66E709A86F' }
        @{ Path = 'powershell\System.Xml.XPath.XDocument.dll'; Sha256 = '2DFFEDF3B83AB6C74F09EB71E0AF6ABC577D9DF70545A09297546D2AD9C75EFF' }
        @{ Path = 'powershell\ThirdPartyNotices.txt'; Sha256 = '5A2D792AA9DAE45DA7579398CA08C0FBB47D78C563CCE492E311B9D5EB9A2142' }
        @{ Path = 'powershell\UIAutomationClient.dll'; Sha256 = '8CE3FFCF3D0761326E58481281868D59540D4057188F59E12FA27D662D1BBC44' }
        @{ Path = 'powershell\UIAutomationClientSideProviders.dll'; Sha256 = '55534151555A2DD8052B7D4D3D97BCB6F5CB726CCBB7DCD833A8B0550F900418' }
        @{ Path = 'powershell\UIAutomationProvider.dll'; Sha256 = '024A82A1F44CDDC9762607D61A55AD73BEAF09811F2686493CEFE02378260907' }
        @{ Path = 'powershell\UIAutomationTypes.dll'; Sha256 = 'C336708AEEF1A9254CF685D76600891142C252B7CC2019E00CC764FE2B37BA44' }
        @{ Path = 'powershell\vcruntime140_cor3.dll'; Sha256 = '4552F05C1FB02F268369F29DC23C02EC1F79DA6E820F27052F7EE7893E1B7C7D' }
        @{ Path = 'powershell\WindowsBase.dll'; Sha256 = 'D0D5387034E8D0625A2FA9830DCD52CF1F591D9AFF5F8689FE2CC00DB7A49EC8' }
        @{ Path = 'powershell\WindowsFormsIntegration.dll'; Sha256 = 'D2D133C35FE183F6924D8502D73AB3EE4D341A99D0B44DBFBB6AF71AF7B132D1' }
        @{ Path = 'powershell\wpfgfx_cor3.dll'; Sha256 = '4032BB15F41399123C77A7F02BB19037F213CB32A66159CF1B536BF5F9F1FF92' }
        @{ Path = 'sqlite-tools\sqlite3.exe'; Sha256 = '3627C4CE2632949EE6D795C92E0A33F68FB30235F0A55A7719F0636414D8E1D3' }
    )
}

# SIG # Begin signature block
# MIImKgYJKoZIhvcNAQcCoIImGzCCJhcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB3Xe7qAcu0NuCg
# xMjV6Fjqq+b3kgxq2DXZGmwoGclh46CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYIYETCCGA0CAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCB6JmFow+Q1
# tZ5eqk3Q5yahx8nLinW7om+pNCHOqRzOyzANBgkqhkiG9w0BAQEFAASCAgA1vQaP
# Gg1zSXlw/OxJ3VQQaI50Z2xsFRSNGszAYipNlLETkjEeyBRAHjwOGSEHDKKJEAHY
# qawujERExK2/oPuvO6a1QO78ReUpAafuu1VF9mmNxou8FkbIwpXZFONQhw+iaZjs
# 5px6YkPYnk/FloKB0REkEKvdcffysTPoIXSgHPJgLcl8/Gm7o1S44Rn+N7tw8xiI
# s3OrhyEpLXYezJxtzzFrYnYHsmuN//XzbY4H4OOMFSqnIe54sQIQSnTBHFLK9jt5
# XPqHim28YRTsM0ocLcRe9zAXjdhBPeUDoslMp2bu3vnoegM4K5WJfo80K5Q6MAnk
# tmJTZtFv/T/rwVJEA1S0cazYhvGwk4VkpqvmqhQ9YygSEizngMlbylVhv/wA3pmq
# MVDl6YhJVhyvdTDsF6PByOQq+Aw8HWtl9kZonuSF15ASddeb2TlQYXZsMl6/b/Qo
# nmmktAgUE+0UacTL2dQn6/gVlPLjzGvKP3f9AMSa4ROHTANxHZHb1USyWzc/DkfT
# YRVVuEZD7PFrSCxvzs1diUg5bOtlu6o/t2Q2v9jmHBw9QK0ZVXCnYOccnmU1sJHd
# NhWsgn0Xp58dX/IB0LYhNxVVjRRSJzhRgO1KQtuMatnoruNrmfC1TesxPlWz6DI/
# JngVxgb8AF6PIltxCbYyuwX2Piwxg9vKqwSmE6GCFM4wghTKBgorBgEEAYI3AwMB
# MYIUujCCFLYGCSqGSIb3DQEHAqCCFKcwghSjAgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIA8SbFwalHN0H32IwjoiKMmUTXz+a8ZpTxYtHMF+dJSgAggaFjxu6/0X
# oRgPMjAyNjExMjIxNDI2MTlaMAMCAQECEGN/XRlZONQE+h5QUG6uUvKgghGnMIIE
# 8zCCAtugAwIBAgIQVEP4N71a7hgBhHK4XNqO4zANBgkqhkiG9w0BAQsFADByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyMB4XDTI2MDYxMjE3MjI0NloXDTM2MDYwOTE3MjI0NVow
# bjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MREwDwYDVQQKDAhTU0wgQ29ycDEqMCgGA1UEAwwhU1NMLmNvbSBUaW1lc3RhbXBp
# bmcgVW5pdCAyMDI2IEUxMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6CWLuGYT
# LkiSOPMLNskOBthXsIhRSA46feOQwvSLcDaNh6vxUzBKEx1KdFBRFs7OHrnH/K0V
# A6MbDQIFpUg0PaOCAVIwggFOMB8GA1UdIwQYMBaAFHCaZcFDgKP86bFkiW7xMJwJ
# Icl8ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3Ns
# LmNvbS9TU0wuY29tLXRpbWVTdGFtcGluZy1JLVIyLmNlcjBRBgNVHSAESjBIMDwG
# DCsGAQQBgqkwAQMGATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29t
# L3JlcG9zaXRvcnkwCAYGZ4EMAQQCMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMEIG
# A1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmxzLnNzbC5jb20vU1NMLmNvbS10aW1l
# U3RhbXBpbmctSS1SMi5jcmwwHQYDVR0OBBYEFCesA1a6KGq6FzuDPUB/eagk7MM8
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAT3ZuzvwDnsIZTXBn
# +hjmuBXgzB12fbYxT9uYe6ZvhvpbZWKcyDQgacETkPw8k6yeqnYCYyFZ063lMPEq
# AhAD2nMG614Zh7PtHW9DWqfsgivxbPYBeN+t7UxgkYT3expbWMdPEqBtWVyHOvLc
# KvMxgJWfJjANwVkwVDfky/j7cf28+iimN8PKc7S/u8/LenRRnV2W2YfncRnkz9Cf
# s5nRDzaZguiHrrp2GxwgnNQSH4GBjHOl3PzLsnVbGoZKi4ZEjgXups4mGGOK7+GB
# 2HAlQn+OS944cHqlkH0gElt2WezoCNRpELph9qaxuBnjSEqXWWfgE6yGBwO0uxKN
# qpWVTHmAwr6SvBPofxubXIuEn9ivR4CLOuAxUSrJ41ZBg/qqG0oJjF6GkRKbxq7c
# yWSkEZYJhmKCg2Hg5fXHagOxiwbmn5JPZ1vhWCrbk3v/dTx2gvTK5+erC5H9/rTc
# ljUI776yd2rfhjfkpvyAsbtXs4D7nrnw8i9wor5+fdtRSJBVxqzLmykFftoL0Up2
# Q++tyKCUdribdcnrB4HKS3s+t3AjdcbA06DCL8GifQi9fL0yRBRNlA4o6BP+Sr75
# 5MaCNjURYZDvDyxJHBBT7cqjZIwsiR8s+6860noFbBBtdge2Iw7CPC/1Q31I27hV
# olS7B0yao3v8X2MtWy3msZlXTcEwggXdMIIDxaADAgECAgh7LJvTFoAymTANBgkq
# hkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8GA1UEAwwo
# U1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAeFw0xNjAy
# MTIxNzM5MzlaFw00MTAyMTIxNzM5MzlaMHwxCzAJBgNVBAYTAlVTMQ4wDAYDVQQI
# DAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBvcmF0
# aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRob3Jp
# dHkgUlNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA+Q/doyt9y9Aq
# /uxnhabnLhu6d+Hj9a+k7PpKXZHEV0drGHdrdvL9k+Q9D8IWngtmw1aUnheDhc5W
# 7/IW/QBi9SIJVOhlF05BueBPRpeqG8i4bmJeabFf2yoCfvxsyvNB2O3Q6Pw/YUjt
# sAMUHRAOSxngu07shmX/NvNeZwILnYZVYf16OO3+4hkAt2+hUGJ1dDyg+sglkrRu
# eiLH+B6h47LdkTGrKx0E/6VKBDfphaQzK/3i1lU0fBmkSmjHsqjTt8qhk4jrwZe8
# jPkd2SKEJHTHBD1qqSmTzOu4W+H+XyWqNFjIwSNUnRuYEcM4nH49hmylD0CGfAL0
# XAJPKMuucZ8POsgz/hElNer8usVgPdl8GNWyqdN1eANyIso6wx/vLOUuqfqeLLZR
# Rv2vA9bqYGjqhRY2a4XpHsCz3cQk3IAqgUFtlD7I4MmBQQCeXr9/xQiYohgsQkCz
# +W84J0tOgPQ9gUfgiHzqHM61dVxRLhwrfxpyKOcAtdF0xtfkn60Hk7ZTNTX8N+TD
# 9l0WviFz3pIK+KBjaryWkmo++LxlVZve9Q2JJgT8JRqmJWnLwm3KfOJZX5es6+8u
# yLzXG1k8K8zyGciTaydjGc/86Sb4ynGbf5P+NGeETpnr/LN4CTNwumamdu0bc+sa
# pQ3EIhMglFYKTixsTrH9z5wJuqIz7YcCAwEAAaNjMGEwHQYDVR0OBBYEFN0ECQei
# 9Xp9UlMSkpXuOIAlDaZZMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU3QQJ
# B6L1en1SUxKSle44gCUNplkwDgYDVR0PAQH/BAQDAgGGMA0GCSqGSIb3DQEBCwUA
# A4ICAQAgGBGUKfsmnRweHnBh8ZVyk3EkrWiTWI4yrxuzcAP8JSt0hZA9eGr0uYul
# lzu1GJG7Hqf5QFuR+VWZrx4R0Fwdp2bjsZQHDDI5puobsHnYHZxwROOK3cT5lR+K
# OEM/AYWlR6c9RrK85SJo93uc2Cw+CiHILTOsv8WBmTF0wXVxxb6x8CNF9J1r/Blj
# naO8BMYYCyW7U4kPs4BQ3kXuRH+rlHhkmNP2KN2H2HBldPsOuRPrpw9hqTKWzN67
# 7WNMGLupQPegVG4giHF1GOp6tDRy4CMnd1y2kOqGJUCr7zMPy5+CvqIg+/a1LRrm
# woWxdA/7yGUCpFIBR91JIsG/2OtrrH7e7GMzFbcjCI/GD41BWt2OxbmP5UU/eNu6
# 0htAsf5xTT/ggaK6XrTsFeCT3QgffuFVmQsh3pOeCvvmo0m9NjD+53eyoHWXtS2B
# iBdlIPfakACfyVLMMso1fPU9D9gr1/UmbMkGNJYW6nBZGjJ5eQu2iH8PUkg9v2zY
# okQu0U63cljTiROV/kSr+NeLG26cvCygW9VqAK9fN+HV+hALmJyG5yaPzvDsbopX
# C4DjTrLAoGNhkLpVaDd0araS25+hhiK2ZScO7LafQmDkZ8K12kELxNOLYRu8+h+R
# K9dEB166KazZxenvU0ha64DxKFghzbAGVfsnP1OQcKkEHlcnuTCCBsswggSzoAMC
# AQICEFKdu8K4iYf1g4DgsOuiBjYwDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9T
# U0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20gUm9vdCBDZXJ0aWZpY2F0
# aW9uIEF1dGhvcml0eSBSU0EwHhcNMjYwNjEyMTY0MjE1WhcNNDEwMjEyMTczOTM5
# WjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFt
# cGluZyBJc3N1aW5nIFJTQSBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAny+r5nNNkLwxRps2B3laUGNU9y7vWiJ5013yf0iXz65bQdwa9bjj8l/S
# keXqHGqfSh2Foae+80E8mDEf93oIwjsy2CX2cXmKxqtF8HJGYB4f6yRhKED50wkb
# OysL02IXf+/EZna44jffhhVz4OU/k52xQ/PnIg/uFhc2Wk+Sc/CHqAr+lYVkPz7L
# y5RqB9f1RKGr9JC37W1LgVdHC50dNIdsa3QXPhltYZubR3npE4Bbfi0joUW5n5O0
# ayweN45R/YVLxA0YGlp1OHVfVnsqXq8bhnw1Lc4kjJ6XOgXlOlw/a8ze57TvbduZ
# l3ehewTmvO0Aky/nqOWDS9IPPxdxdG6vprBbSuHlxNANBAbHTiFgkfZmf0dZYlT/
# AnZIoFxAq0HILPolf4OgWgET76SiWSlm2XYRIXwVjpeqG0plvXwRIQBzSiEJj7Qe
# QFnCvHx4gQMINvN3+yG/1rxhEbajGve0tTP3lX4PPOHVAE0QJp4ZzPI1YYJkhVRr
# iVVxVRU4Fsg4BPwP6I+YLmHb1tZ4RLwOFNLh/gJYDgPlChCoxOogFxXgwPZZrDyE
# RYB0aeOexW0OKacN4RRu9cqF2KKu/Ab5AL7eYDLVGUPrEEyYbIMApVKqpebc0/jD
# QniC+3rkauRAjgVc8m1ip/CQgG1Dw4Z9ulVRAY9VR6Za26LsTbUCAwEAAaOCAVEw
# ggFNMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKS
# le44gCUNplkwTQYIKwYBBQUHAQEEQTA/MD0GCCsGAQUFBzAChjFodHRwOi8vY2Vy
# dC5zc2wuY29tL1NTTGNvbS1Sb290Q0EtUlNBLTQwOTYtUjEuY2VyMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwQgYDVR0fBDswOTA3oDWgM4Yx
# aHR0cDovL2NybHMuc3NsLmNvbS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNy
# bDAdBgNVHQ4EFgQUcJplwUOAo/zpsWSJbvEwnAkhyXwwDgYDVR0PAQH/BAQDAgGG
# MA0GCSqGSIb3DQEBCwUAA4ICAQBlFFvNMemA6iBiBYo56IKQjWhWuQaYKuo4qpf0
# KJNERAt1gz+HsA2SL3xA/V+EA8SRPNP9SvX0is+5mDsppYvpKyYGqYP36YFW0mbF
# 1F0ZtXxumCUUO/ZV5mBNKDf5Q4PY7Qb0eWAepUc0rNJr/Mvn5ZiXfJPxDb2xmcg8
# aRD652/nr+Ork2UBP0E43iJdI4LF7Vs29R3SGRLYZOxM15DI4QebsKRl0KDlf4Om
# YGCKc7umTxibkZtN1C1KWgnf9jadU/JwnySaYEBgx6/v+FVC6SGONziY7TcvI9MV
# +qYxHUPlOm6AaQP2dS4bjWXnm86ldCbUkxtOACumSfT97077JNiVa7PZ1IBkd/2P
# E1AC8gs7U+/Yk1BN9XRPIi15k/uA1xF9oeee5KGjyiGKkqIT7W8QkgUT5zeCinFK
# kcKafZMcROSVYpXtmtQqGGR2g4uPYqJ0K1hms6gJXrHt/34p8M9PrV8oNWe0Zl1E
# rDMtXndUg3qhJL4pA3ZUlo7w5lM5ml+A7ijr/3Gk2v4QRoDeE2ShmTXdHgtqo8L/
# fT119mYcETycE2NYGRXsBl3N0rzDsHRr8P3TrprqhRrX04iS0P7eQ+lDxgS3yhGn
# 3OzWGhDt9Gf2x1qe0/qdhFAVOkXxzMZz4Uat6xsAfzX0+/m8GEKW5Ojw/HY+kLvV
# wzSPOzGCAlYwggJSAgEBMIGGMHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhh
# czEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMM
# JVNTTC5jb20gVGltZXN0YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4Y
# AYRyuFzajuMwCwYJYIZIAWUDBAIBoIIBYDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTEyMjE0MjYxOVowKAYJKoZIhvcNAQk0
# MRswGTALBglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIOoT
# FrOUlwrnYE+TBb+BxOGd7sU/Vx8l/qvn4Ljs5YH2MIHIBgsqhkiG9w0BCRACLzGB
# uDCBtTCBsjCBrwQgV0/qF6r6XnxqK5sIyZixc15FCzhzykTmokygkw5j87AwgYow
# dqR0MHIxCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91
# c3RvbjERMA8GA1UECgwIU1NMIENvcnAxLjAsBgNVBAMMJVNTTC5jb20gVGltZXN0
# YW1waW5nIElzc3VpbmcgUlNBIENBIDICEFRD+De9Wu4YAYRyuFzajuMwCgYIKoZI
# zj0EAwIERzBFAiAZMs8r0Jq2jC/GEkZ539SJ9Hnd/Ik5Q9VjyZtr2BJ+eAIhAITP
# E5qnBsDWBj8Vb0qW8Cao9R3KW2/iOSPVD7famq23
# SIG # End signature block
