<#
.SYNOPSIS
    Runs every CB App Control health-check SQL script in this folder and
    exports the results in the exact formats the health-check report tool
    expects (CSV for single-result scripts, raw fixed-width .rpt text for
    multi-result scripts), with an option to zip the output folder.

.DESCRIPTION
    Replaces the manual SSMS export workflow described in README.md:
      - Single-result scripts are exported as UTF-8 CSV with column headers.
      - Multi-result scripts are exported as one .rpt file per script in the
        same fixed-width "header + dash separator" layout as SSMS
        "Results to File", including PRINT diagnostic output.
      - UnapprovedFileAnalysis is run over a configurable reporting period
        and automatically split into smaller non-overlapping time chunks
        whenever a window exceeds the script's row cap.
      - The two App Control console exports (Computers, Custom Rules) cannot
        be collected from SQL; the script prompts for their file paths (or
        accepts them as parameters) and copies them into the output folder.

    Scripts are run one at a time, in sequence, per the production guidance
    in this folder's README.md. Run against a readable Availability Group
    secondary when possible (see -ReadOnlyIntent), or during a low-activity
    window.

.PARAMETER Server
    SQL Server instance hosting the App Control database,
    e.g. "SQLHOST01" or "SQLHOST01\INSTANCE".

.PARAMETER Database
    Initial database. Default: das. (The scripts themselves switch to the
    das database.)

.PARAMETER OutputFolder
    Folder to write the exports into. Default: .\HealthCheckExport_<timestamp>
    in the current directory. Created if missing.

.PARAMETER SqlCredential
    Optional SQL login credential (Get-Credential). When omitted, Windows
    integrated authentication is used.

.PARAMETER UnapprovedStart
    Start (inclusive) of the UnapprovedFileAnalysis reporting period.
    Default: 7 days ago.

.PARAMETER UnapprovedEnd
    End (exclusive) of the UnapprovedFileAnalysis reporting period.
    Default: now.

.PARAMETER ComputersExport
    Optional path to the console "Computers" page export (CSV/TXT). Copied
    into the output folder. If omitted and the session is interactive, the
    script prompts for it.

.PARAMETER CustomRulesExport
    Optional path to the console "Custom Rules" page export (CSV/TXT).
    Copied into the output folder. If omitted and the session is
    interactive, the script prompts for it.

.PARAMETER Zip
    Compress the output folder to <OutputFolder>.zip after collection.

.PARAMETER ReadOnlyIntent
    Adds ApplicationIntent=ReadOnly to the connection so an Availability
    Group listener routes the session to a readable secondary.

.PARAMETER CommandTimeoutSec
    Per-batch SQL command timeout in seconds. 0 = unlimited. Default: 3600.

.PARAMETER NonInteractive
    Never prompt (for scheduled runs). Missing console exports are reported
    as warnings instead.

.EXAMPLE
    .\Collect-HealthCheckData.ps1 -Server SQLHOST01 -Zip

.EXAMPLE
    .\Collect-HealthCheckData.ps1 -Server AGLISTENER -ReadOnlyIntent `
        -SqlCredential (Get-Credential) `
        -UnapprovedStart (Get-Date).AddDays(-14) `
        -ComputersExport C:\Exports\Computers_20260915.csv `
        -CustomRulesExport C:\Exports\CustomRules_20260915.csv -Zip
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Database = "das",
    [string]$OutputFolder,
    [System.Management.Automation.PSCredential]$SqlCredential,
    [datetime]$UnapprovedStart = (Get-Date).AddDays(-7),
    [datetime]$UnapprovedEnd = (Get-Date),
    [string]$ComputersExport,
    [string]$CustomRulesExport,
    [switch]$Zip,
    [switch]$ReadOnlyIntent,
    [int]$CommandTimeoutSec = 3600,
    [switch]$NonInteractive,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:RowCapMessage = "exceeds RowsToRetrieve"
$script:MinChunkMinutes = 5

function Show-Usage {
    Write-Host @"
Collect-HealthCheckData.ps1 - CB App Control health-check data collection

Runs every health-check SQL script in this folder against the App Control
database and writes the exports (CSV/.rpt) in the format the health-check
report tool expects, with an option to zip the output folder.

USAGE
  powershell -ExecutionPolicy Bypass -File .\Collect-HealthCheckData.ps1 -Server <instance> [options]

REQUIRED
  -Server <name>            SQL Server instance hosting the App Control database,
                            e.g. SQLHOST01, SQLHOST01\INSTANCE, or an AG listener.

OPTIONS
  -Database <name>          Initial database for the connection (default: das).
  -OutputFolder <path>      Where to write the exports
                            (default: .\HealthCheckExport_<timestamp>).
  -SqlCredential <cred>     SQL login, e.g. -SqlCredential (Get-Credential).
                            Omit to use Windows integrated authentication.
  -ReadOnlyIntent           Route the session to a readable Availability Group
                            secondary (recommended for production).
  -UnapprovedStart <date>   Start (inclusive) of the Unapproved File Analysis
                            period (default: 7 days ago).
  -UnapprovedEnd <date>     End (exclusive) of that period (default: now).
                            Windows over the row cap split automatically.
  -ComputersExport <path>   Console "Computers" page export (CSV/TXT) to copy
                            into the output folder (prompted if omitted).
  -CustomRulesExport <path> Console "Custom Rules" page export (CSV/TXT) to copy
                            into the output folder (prompted if omitted).
  -Zip                      Compress the output folder to <folder>.zip. Data
                            over 2 GB must be zipped manually instead.
  -CommandTimeoutSec <n>    Per-batch SQL timeout in seconds, 0 = unlimited
                            (default: 3600).
  -NonInteractive           Never prompt (for scheduled runs).
  -Help                     Show this message and exit.

EXAMPLES
  powershell -ExecutionPolicy Bypass -File .\Collect-HealthCheckData.ps1 -Server SQLHOST01 -Zip

  powershell -ExecutionPolicy Bypass -File .\Collect-HealthCheckData.ps1 ``
      -Server AGLISTENER -ReadOnlyIntent -SqlCredential (Get-Credential) ``
      -UnapprovedStart (Get-Date).AddDays(-14) ``
      -ComputersExport C:\Exports\Computers.csv ``
      -CustomRulesExport C:\Exports\CustomRules.csv -Zip

See README.md in this folder for the full workflow and production guidance.
"@
}

function New-SqlConnection {
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $Server
    $builder["Initial Catalog"] = $Database
    $builder["Connect Timeout"] = 30
    if ($ReadOnlyIntent) { $builder["ApplicationIntent"] = "ReadOnly" }
    if ($SqlCredential) {
        $pwd = $SqlCredential.Password.Copy()
        $pwd.MakeReadOnly()
        $cred = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $pwd)
        $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString, $cred)
    } else {
        $builder["Integrated Security"] = $true
        $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    }
    $conn.Open()
    return $conn
}

function Split-SqlBatches {
    param([string]$SqlText)
    $batches = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    foreach ($line in ($SqlText -split "\r?\n")) {
        if ($line -match '^\s*GO\s*$') {
            if ($current.ToString().Trim()) { $batches.Add($current.ToString()) }
            $current = New-Object System.Text.StringBuilder
        } else {
            [void]$current.AppendLine($line)
        }
    }
    if ($current.ToString().Trim()) { $batches.Add($current.ToString()) }
    return ,$batches
}

function Format-SqlValue {
    # Renders one reader value the way SSMS text output does.
    param($Value)
    if ($Value -eq $null -or $Value -is [System.DBNull]) { return "NULL" }
    if ($Value -is [bool]) { if ($Value) { return "1" } else { return "0" } }
    if ($Value -is [datetime]) { return $Value.ToString("yyyy-MM-dd HH:mm:ss.fff", $script:Invariant) }
    if ($Value -is [byte[]]) { return "0x" + (($Value | ForEach-Object { $_.ToString("X2") }) -join "") }
    if ($Value -is [System.IConvertible]) { return [System.Convert]::ToString($Value, $script:Invariant) }
    return [string]$Value
}

function Format-CsvField {
    param($Value)
    if ($Value -eq $null -or $Value -is [System.DBNull]) { return "" }
    $text = Format-SqlValue $Value
    if ($text -match '[,"\r\n]') { return '"' + ($text -replace '"', '""') + '"' }
    return $text
}

function Write-RptTable {
    # Emits one result set in the SSMS fixed-width layout that
    # healthcheck/rpt_parser.py expects: header line, dash separator line
    # (single space between dash runs), space-padded data rows, blank line.
    param(
        [System.IO.StreamWriter]$Writer,
        [string[]]$Columns,
        [System.Collections.Generic.List[string[]]]$Rows
    )
    $widths = @()
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        $w = [Math]::Max(1, $Columns[$c].Length)
        foreach ($row in $Rows) {
            if ($row[$c].Length -gt $w) { $w = $row[$c].Length }
        }
        $widths += $w
    }
    $Writer.WriteLine()
    $Writer.WriteLine((($Columns | ForEach-Object -Begin { $i = 0 } -Process { $_.PadRight($widths[$i]); $i++ }) -join " "))
    $Writer.WriteLine((($widths | ForEach-Object { "-" * $_ }) -join " "))
    foreach ($row in $Rows) {
        $Writer.WriteLine((($row | ForEach-Object -Begin { $i = 0 } -Process { $_.PadRight($widths[$i]); $i++ }) -join " "))
    }
    $Writer.WriteLine()
}

function Invoke-SqlScriptToRpt {
    # Runs all batches of a multi-result script and writes every result set
    # plus PRINT/error messages to one .rpt file, mimicking SSMS
    # "Results to File". Statement errors (e.g. missing VIEW SERVER STATE)
    # are written as messages and the run continues, like SSMS.
    param(
        [string]$SqlPath,
        [string]$RptPath
    )
    $batches = Split-SqlBatches ([System.IO.File]::ReadAllText($SqlPath))
    $writer = New-Object System.IO.StreamWriter($RptPath, $false, $script:Utf8Bom)
    $script:RptMessages = New-Object System.Collections.Generic.List[string]
    $conn = $null
    try {
        $writer.WriteLine("Collected by Collect-HealthCheckData.ps1 from [$Server] at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
        $conn = New-SqlConnection
        $conn.FireInfoMessageEventOnUserErrors = $true
        $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
            param($sender, $e)
            foreach ($err in $e.Errors) {
                if ($err.Class -gt 0) {
                    $script:RptMessages.Add(("Msg {0}, Level {1}, State {2}, Line {3}" -f $err.Number, $err.Class, $err.State, $err.LineNumber))
                }
                $script:RptMessages.Add($err.Message)
            }
        }
        $conn.add_InfoMessage($handler)
        try {
            foreach ($batch in $batches) {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $cmd.CommandTimeout = $CommandTimeoutSec
                $reader = $cmd.ExecuteReader()
                try {
                    do {
                        if ($reader.FieldCount -gt 0) {
                            $columns = @()
                            for ($c = 0; $c -lt $reader.FieldCount; $c++) { $columns += [string]$reader.GetName($c) }
                            $rows = New-Object System.Collections.Generic.List[string[]]
                            while ($reader.Read()) {
                                $row = New-Object string[] $reader.FieldCount
                                for ($c = 0; $c -lt $reader.FieldCount; $c++) {
                                    # Keep rows single-line so the fixed-width layout stays parseable.
                                    $row[$c] = (Format-SqlValue $reader.GetValue($c)) -replace "[\r\n\t]", " "
                                }
                                $rows.Add($row)
                            }
                            foreach ($msg in $script:RptMessages) { $writer.WriteLine($msg) }
                            $script:RptMessages.Clear()
                            Write-RptTable -Writer $writer -Columns $columns -Rows $rows
                        }
                    } while ($reader.NextResult())
                } finally {
                    $reader.Dispose()
                }
                foreach ($msg in $script:RptMessages) { $writer.WriteLine($msg) }
                $script:RptMessages.Clear()
            }
        } finally {
            $conn.remove_InfoMessage($handler)
        }
    } finally {
        if ($conn) { $conn.Dispose() }
        $writer.Dispose()
    }
}

function Invoke-SqlScriptToCsv {
    # Runs all batches of a single-result script and streams its result set
    # to CSV (UTF-8, headers, standard quoting). Returns the row count.
    param(
        [string]$SqlPath,
        [string]$CsvPath,
        [datetime]$ChunkStart,
        [datetime]$ChunkEnd
    )
    $batches = Split-SqlBatches ([System.IO.File]::ReadAllText($SqlPath))
    $conn = New-SqlConnection
    $writer = $null
    $rowCount = 0
    try {
        $first = $true
        foreach ($batch in $batches) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            $cmd.CommandTimeout = $CommandTimeoutSec
            $reader = $cmd.ExecuteReader()
            try {
                do {
                    if ($reader.FieldCount -gt 0 -and $writer -eq $null) {
                        $writer = New-Object System.IO.StreamWriter($CsvPath, $false, $script:Utf8Bom)
                        $header = @()
                        for ($c = 0; $c -lt $reader.FieldCount; $c++) { $header += Format-CsvField ([string]$reader.GetName($c)) }
                        $writer.WriteLine(($header -join ","))
                        while ($reader.Read()) {
                            $fields = New-Object string[] $reader.FieldCount
                            for ($c = 0; $c -lt $reader.FieldCount; $c++) { $fields[$c] = Format-CsvField ($reader.GetValue($c)) }
                            $writer.WriteLine(($fields -join ","))
                            $rowCount++
                        }
                    }
                } while ($reader.NextResult())
            } finally {
                $reader.Dispose()
            }
            if ($first) {
                $first = $false
                if ($PSBoundParameters.ContainsKey("ChunkStart")) {
                    # UnapprovedFileAnalysis reads its reporting window from
                    # #Variables (filled by the first batch); override it for
                    # this chunk without editing the .sql file.
                    $upd = $conn.CreateCommand()
                    $upd.CommandText = "UPDATE #Variables SET startDate = @s, endDate = @e;"
                    [void]$upd.Parameters.AddWithValue("@s", $ChunkStart)
                    [void]$upd.Parameters.AddWithValue("@e", $ChunkEnd)
                    [void]$upd.ExecuteNonQuery()
                }
            }
        }
    } finally {
        if ($writer) { $writer.Dispose() }
        $conn.Dispose()
    }
    return $rowCount
}

function Export-UnapprovedFileAnalysis {
    # Runs the script per time window; when a window trips the script's row
    # cap, bisects it into two smaller windows and retries. Each successful
    # window becomes one non-overlapping CSV chunk.
    param(
        [string]$SqlPath,
        [string]$OutFolder
    )
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($UnapprovedStart, $UnapprovedEnd))
    $chunks = 0
    while ($queue.Count -gt 0) {
        $window = $queue.Dequeue()
        $start = [datetime]$window[0]
        $end = [datetime]$window[1]
        $name = "UnapprovedFileAnalysis_{0:yyyyMMdd-HHmmss}_{1:yyyyMMdd-HHmmss}.csv" -f $start, $end
        $path = Join-Path $OutFolder $name
        Write-Host ("    chunk {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm} ..." -f $start, $end)
        try {
            $rows = Invoke-SqlScriptToCsv -SqlPath $SqlPath -CsvPath $path -ChunkStart $start -ChunkEnd $end
            Write-Host "      OK ($rows rows)"
            $chunks++
        } catch {
            # SqlException may be wrapped (e.g. MethodInvocationException);
            # detect the script's row-cap RAISERROR by message text.
            $msg = $_.Exception.Message
            if ($_.Exception.InnerException) { $msg += " " + $_.Exception.InnerException.Message }
            if ($msg -notmatch $script:RowCapMessage) { throw }
            if (Test-Path $path) { Remove-Item $path }
            if (($end - $start).TotalMinutes -le $script:MinChunkMinutes) {
                throw "UnapprovedFileAnalysis window $start -> $end exceeds the row cap even at the minimum chunk size ($($script:MinChunkMinutes) min). Raise @rowsToRetrieve in the script or narrow the period."
            }
            $mid = $start.AddTicks([long](($end - $start).Ticks / 2))
            Write-Host "      row cap exceeded; splitting window"
            $queue.Enqueue(@($start, $mid))
            $queue.Enqueue(@($mid, $end))
        }
    }
    return $chunks
}

function Resolve-ScriptFile {
    # Version-tolerant lookup; newest version name sorts last.
    param([string]$Folder, [string]$Pattern)
    $found = @(Get-ChildItem -Path $Folder -Filter $Pattern -File | Sort-Object Name)
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) {
        Write-Warning "Multiple files match '$Pattern'; using '$($found[-1].Name)'"
    }
    return $found[-1].FullName
}

function Copy-ConsoleExport {
    param(
        [string]$Label,
        [string]$ProvidedPath,
        [string]$RequiredKeyword,
        [string]$OutFolder
    )
    $path = $ProvidedPath
    if (-not $path -and -not $NonInteractive) {
        $path = Read-Host "Path to the console '$Label' export (CSV/TXT), or Enter to skip"
    }
    if (-not $path) {
        Write-Warning "$Label console export not provided. Export it from the App Control console and add it to the output folder before running the report."
        return $false
    }
    if (-not (Test-Path $path)) {
        Write-Warning "$Label export not found at '$path'. Skipping."
        return $false
    }
    $fileName = Split-Path $path -Leaf
    if ($fileName.ToLowerInvariant() -notlike "*$($RequiredKeyword.ToLowerInvariant())*") {
        $fileName = "$RequiredKeyword`_$fileName"
    }
    Copy-Item -Path $path -Destination (Join-Path $OutFolder $fileName)
    Write-Host "  OK  $Label export -> $fileName"
    return $true
}

function Invoke-Collection {
    if ($Help) {
        Show-Usage
        return
    }
    if (-not $Server) {
        Show-Usage
        Write-Warning "The -Server parameter is required."
        exit 1
    }
    if ($UnapprovedStart -ge $UnapprovedEnd) {
        throw "-UnapprovedStart must be earlier than -UnapprovedEnd."
    }

    $scriptFolder = $PSScriptRoot
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outFolder = $OutputFolder
    if (-not $outFolder) { $outFolder = Join-Path (Get-Location) "HealthCheckExport_$stamp" }
    if (-not (Test-Path $outFolder)) { New-Item -ItemType Directory -Path $outFolder | Out-Null }
    $outFolder = (Resolve-Path $outFolder).Path

    Write-Host "CB App Control health-check data collection"
    Write-Host "  Server : $Server  (database: $Database$(if ($ReadOnlyIntent) { ', read-only intent' }))"
    Write-Host "  Output : $outFolder"
    Write-Host ""

    Write-Host "Testing connection ..."
    $test = New-SqlConnection
    $test.Dispose()
    Write-Host "  OK"
    Write-Host ""

    # Output filenames contain the keywords healthcheck/config.py matches on.
    $csvJobs = @(
        @{ Label = "Approval Metrics";       Pattern = "Approval Metrics*.sql";          Out = "Approval Metrics_$stamp.csv" },
        @{ Label = "Rule Analysis";          Pattern = "RuleAnalysis*.sql";              Out = "RuleAnalysis_$stamp.csv" },
        @{ Label = "Approval Events";        Pattern = "ApprovalEventsForRulename*.sql"; Out = "ApprovalEvents_$stamp.csv" },
        @{ Label = "Block Analysis";         Pattern = "BlockAnalysis*.sql";             Out = "BlockAnalysis_$stamp.csv" },
        @{ Label = "Database Error Analysis"; Pattern = "DatabaseErrorAnalysis*.sql";    Out = "DatabaseErrorAnalysis_$stamp.csv" }
    )
    $rptJobs = @(
        @{ Label = "CbP Analysis (SAFE)";    Pattern = "CbP_Analysis_Script SAFE*.sql";     Out = "CbP_Analysis_$stamp.rpt" },
        @{ Label = "Daily Prune Scope";      Pattern = "DailyPrune_Debug_Scope*.sql";       Out = "DailyPrune_$stamp.rpt" },
        @{ Label = "FilePath Pruning Scope"; Pattern = "FilePath_Pruning_Scope*.sql";       Out = "FilePath_Pruning_$stamp.rpt" },
        @{ Label = "Purge Antibodies Scope"; Pattern = "PurgeAntibodiesPeriodDays*.sql";    Out = "PurgeAntibodiesPeriodDays_$stamp.rpt" }
    )

    $failures = @()
    foreach ($job in $csvJobs) {
        $sqlPath = Resolve-ScriptFile -Folder $scriptFolder -Pattern $job.Pattern
        if (-not $sqlPath) { Write-Warning "$($job.Label): no script matching '$($job.Pattern)' in $scriptFolder"; $failures += $job.Label; continue }
        Write-Host "Running $($job.Label) ($(Split-Path $sqlPath -Leaf)) ..."
        try {
            $rows = Invoke-SqlScriptToCsv -SqlPath $sqlPath -CsvPath (Join-Path $outFolder $job.Out)
            Write-Host "  OK  $($job.Out) ($rows rows)"
        } catch {
            Write-Warning "$($job.Label) failed: $($_.Exception.Message)"
            $failures += $job.Label
        }
    }

    foreach ($job in $rptJobs) {
        $sqlPath = Resolve-ScriptFile -Folder $scriptFolder -Pattern $job.Pattern
        if (-not $sqlPath) { Write-Warning "$($job.Label): no script matching '$($job.Pattern)' in $scriptFolder"; $failures += $job.Label; continue }
        Write-Host "Running $($job.Label) ($(Split-Path $sqlPath -Leaf)) ..."
        try {
            Invoke-SqlScriptToRpt -SqlPath $sqlPath -RptPath (Join-Path $outFolder $job.Out)
            Write-Host "  OK  $($job.Out)"
        } catch {
            Write-Warning "$($job.Label) failed: $($_.Exception.Message)"
            $failures += $job.Label
        }
    }

    $sqlPath = Resolve-ScriptFile -Folder $scriptFolder -Pattern "UnapprovedFileAnalysis*.sql"
    if (-not $sqlPath) {
        Write-Warning "Unapproved File Analysis: no script matching 'UnapprovedFileAnalysis*.sql' in $scriptFolder"
        $failures += "Unapproved File Analysis"
    } else {
        Write-Host ("Running Unapproved File Analysis ({0}) for {1:yyyy-MM-dd HH:mm} -> {2:yyyy-MM-dd HH:mm} ..." -f (Split-Path $sqlPath -Leaf), $UnapprovedStart, $UnapprovedEnd)
        try {
            $chunks = Export-UnapprovedFileAnalysis -SqlPath $sqlPath -OutFolder $outFolder
            Write-Host "  OK  $chunks chunk file(s)"
        } catch {
            Write-Warning "Unapproved File Analysis failed: $($_.Exception.Message)"
            $failures += "Unapproved File Analysis"
        }
    }

    Write-Host ""
    Write-Host "Console UI exports (cannot be collected from SQL):"
    $haveComputers = Copy-ConsoleExport -Label "Computers" -ProvidedPath $ComputersExport -RequiredKeyword "Computers" -OutFolder $outFolder
    $haveCustom = Copy-ConsoleExport -Label "Custom Rules" -ProvidedPath $CustomRulesExport -RequiredKeyword "CustomRules" -OutFolder $outFolder

    if ($Zip) {
        # Compress-Archive on Windows PowerShell 5.1 fails on archives
        # larger than ~2 GB; fall back to manual zipping above that.
        $totalBytes = (Get-ChildItem -Path $outFolder -File -Recurse | Measure-Object -Property Length -Sum).Sum
        if ($totalBytes -gt 2GB) {
            Write-Warning ("Collected data is {0:N1} GB, which exceeds the 2 GB Compress-Archive limit. Zip the output folder manually (e.g. with 7-Zip or Windows Explorer): $outFolder" -f ($totalBytes / 1GB))
        } else {
            $zipPath = "$outFolder.zip"
            if (Test-Path $zipPath) { Remove-Item $zipPath }
            Compress-Archive -Path (Join-Path $outFolder "*") -DestinationPath $zipPath
            Write-Host ""
            Write-Host "Zipped: $zipPath"
        }
    }

    Write-Host ""
    Write-Host "Done. Output folder: $outFolder"
    if (-not $haveComputers -or -not $haveCustom) {
        Write-Warning "Add the missing console export(s) to the folder$(if ($Zip) { ' and re-zip' }) before running the health-check report."
    }
    if ($failures.Count -gt 0) {
        Write-Warning ("{0} collection(s) failed: {1}. The report tool skips missing inputs, but those sections will be empty." -f $failures.Count, ($failures -join ", "))
        exit 1
    }
}

# Skip execution when dot-sourced (e.g. for testing individual functions).
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Collection
}
