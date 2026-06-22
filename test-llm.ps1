#Requires -Version 7.0

<#
.SYNOPSIS
    Benchmark local LLM models via Foundry Local; results accumulate in output/{machine}.llm.yaml.

.DESCRIPTION
    Each script execution = one "session" appended to the YAML.
    Within a session, for each model: load once, then do $Runs repetitions of $Calls calls
    without restarting the Foundry server between repetitions.
    Server is restarted once per model (before load) to give each model a clean slate.

    The first call of run 1 is marked cold=true; all subsequent calls are warm.

.PARAMETER Models
    One or more Foundry model IDs to benchmark. Omit to pick interactively.

.PARAMETER Calls
    Completion calls per run. Default: 5.

.PARAMETER Runs
    How many runs per model without restarting. Default: ask interactively.

.PARAMETER MaxTokens
    Max tokens per call. Default: 512.

.PARAMETER Temperature
    Sampling temperature. Default: 0.7.

.PARAMETER TopP
    Top-P nucleus sampling. Default: 0.9.

.PARAMETER TimeoutSeconds
    Per-call HTTP timeout in seconds. Default: 300.

.EXAMPLE
    test-llm                            # full interactive mode
    test-llm phi-4 -Calls 5 -Runs 3    # non-interactive

.NOTES
    =========================================================================
    DESIGN RULES — read before touching this script
    =========================================================================

    ERROR HANDLING PHILOSOPHY
    -------------------------
    Set-StrictMode -Version Latest + ErrorActionPreference = Stop are both ON.
    This means any bug in this script will STOP execution immediately with a
    clear error. Do NOT add try/catch to hide bugs — fix the bug instead.

    The only legitimate try/catch blocks are:
      - Get-ThermalState: thermal sensor WMI is optional hardware; absence is not a bug.
      - Stop-UtilizationSampler: cleanup path; must not shadow an earlier real error.
      - Inner JSON chunk parsing loop in Invoke-StreamingCompletion: malformed SSE
        chunks from the API are expected and should be skipped, not crash the benchmark.
      - Streaming read loop in Invoke-StreamingCompletion: the Foundry server can drop
        the streaming HTTP connection ("The response ended prematurely / ResponseEnded"),
        most often on the cold first call while the model is still warming. This is a
        transient server condition, not a script bug, so it is retried (when it drops
        before any token) or accepted as a truncated measurement (when it drops after
        tokens have streamed). Test-TransientStreamError gates this so genuine script
        bugs still surface immediately. See that function and the retry loop.
      - Per-call crash recovery in the runs loop: the Foundry inference backend itself
        can crash mid-benchmark (HTTP frontend stays up and returns 200, then the body
        drops). When Invoke-StreamingCompletion's own retries are exhausted it throws;
        the call site catches ONLY transient errors (Test-TransientStreamError — real
        bugs are rethrown), restarts the server, reloads the model and retries once. If
        recovery still fails, the model is recorded as completed:false and the loop moves
        on to the next model rather than aborting the whole benchmark.

    If you find yourself adding try/catch to "fix" an error, you have a bug. Fix the code.

    STRICT MODE AND JSON PROPERTY ACCESS
    -------------------------------------
    Set-StrictMode -Version Latest makes accessing a missing property on ANY object
    a terminating error. ConvertFrom-Json objects only expose properties that are
    present in the JSON, so direct access ($obj.someField) will throw if the field
    is absent in that particular response.

    NEVER access JSON-parsed object properties directly. Always use Get-JsonProp:

        $value = Get-JsonProp $obj 'fieldName'           # returns $null if absent
        $value = Get-JsonProp $obj 'fieldName' 'default' # returns 'default' if absent

    The null-conditional operator ($obj?.Property) does NOT work under strict mode —
    it throws the same "cannot be retrieved" error. Do not use it.
    The null-coalescing operator ($a ?? $b) also does NOT help because the left side
    has already thrown before ?? can evaluate.

    FOUNDRY CLI — WHAT YOU CAN AND CANNOT PIPE
    -------------------------------------------
    Foundry CLI commands that display progress bars use Spectre Console, which writes
    directly to the terminal and DEADLOCKS if its stdout is redirected to a pipe.
    These commands MUST run raw with no pipe, no variable assignment, no Tee-Object:

        foundry server restart     # raw — deadlocks if piped
        foundry model load <id>    # raw — deadlocks if piped

    Commands that output plain JSON with -o json are safe to capture:

        foundry server status -o json   # safe
        foundry model info <id> -o json # safe
        foundry cache list -o json      # safe

    FOUNDRY SERVER URL
    ------------------
    Foundry uses a dynamic port chosen at startup. Never hardcode the port.
    Always read it from: foundry server status -o json
    The field is "webUrls" (plural, an array) — take index [0].
    Earlier versions used "webUrl" (singular) or "url" — Get-FoundryApiBase
    handles all variants via PSObject.Properties.Name inspection.

    UTILISATION SAMPLER
    -------------------
    CPU/GPU utilisation is sampled during each streaming call using a background
    PowerShell Runspace (not Start-Job, not Task.Run). Reasons:
      - Start-Job spawns a new process that does not inherit the current PATH,
        so foundry and other tools would not be found.
      - Task.Run / Thread pool threads have no PowerShell Runspace associated
        with them; calling Get-Counter or any cmdlet from a thread pool thread
        throws "No Runspace available".
      - An explicit Runspace created with RunspaceFactory runs in-process,
        inherits the environment, and has its own Runspace — Get-Counter works.

    Data is passed back via a ConcurrentQueue<PSObject> that both the Runspace
    and the main thread can access without locks. The CancellationTokenSource
    signals the Runspace loop to stop cleanly.

    YAML FILE — APPEND-ONLY
    ------------------------
    The output file is never deleted. Each script execution appends one
    "session" entry to the sessions: list. The machine/system header is written
    only once (when the file is first created). Session IDs are determined by
    counting existing "  - sessionId:" lines in the file.

    COLD / WARM CALLS
    -----------------
    cold=true is set only on run 1, call 1 (the first call after model load).
    All subsequent calls — including call 1 of run 2, 3, etc. — are warm=false
    because the model weights are already resident in the provider (GPU/NPU/CPU).

    ORT EXECUTION PROVIDER NAMES
    -----------------------------
    Foundry reports hardware labels like "GPU", "NPU", "CPU" in its model info.
    These are NOT the ONNX Runtime provider names. The mapping on Snapdragon X Elite:
      GPU  -> WebGpuExecutionProvider   (Adreno GPU via WebGPU)
      NPU  -> QNNExecutionProvider      (Hexagon NPU via Qualcomm QNN)
      CPU  -> CPUExecutionProvider
    Get-JsonProp + the switch in the model info section handles this mapping.
    =========================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Models,

    [int]$Calls = 5,

    [int]$Runs = 0,     # 0 = ask interactively

    [int]$MaxTokens = 512,

    [double]$Temperature = 0.7,

    [double]$TopP = 0.9,

    [int]$TimeoutSeconds = 300
)

# Strict mode + Stop: any script bug crashes immediately. Do not add try/catch to hide bugs.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
function Install-RequiredModule {
    param([string]$Name)
    $installed = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    $gallery   = Find-Module -Name $Name -Repository PSGallery -ErrorAction SilentlyContinue
    if (-not $installed) {
        Write-Host "  Installing $Name..." -ForegroundColor DarkGray
        Install-Module $Name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    elseif ($gallery -and ([version]$gallery.Version -gt [version]$installed.Version)) {
        Write-Host "  Updating $Name $($installed.Version) → $($gallery.Version)..." -ForegroundColor DarkGray
        Update-Module $Name -Scope CurrentUser -Force
    }
    else {
        Write-Host "  $Name $($installed.Version) — ok" -ForegroundColor DarkGray
    }
    Import-Module $Name -Force -ErrorAction Stop
}

Write-Host ""
Write-Host "Checking prerequisites..." -ForegroundColor Cyan
foreach ($mod in @('powershell-yaml', 'PwshSpectreConsole')) {
    Install-RequiredModule -Name $mod
}

if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing Microsoft.Foundry via winget..." -ForegroundColor Yellow
    winget install --id Microsoft.Foundry --silent --accept-package-agreements --accept-source-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
        throw "foundry CLI not found after install. Open a new terminal and retry."
    }
}
else {
    $fv = (foundry --version 2>&1) -join '' -replace '\s+', ' '
    Write-Host "  foundry $fv — ok" -ForegroundColor DarkGray
}
Write-Host ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Dynamic port — never hardcode. Field is "webUrls" (plural array) in current Foundry;
# older versions used "webUrl" or "url". PSObject.Properties.Name check handles all variants.
# -o json output is safe to capture; Foundry's rich-output commands are not (see NOTES).
function Get-FoundryApiBase {
    $json   = foundry server status -o json 2>&1 | Out-String
    $status = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
    $props  = $status.PSObject.Properties.Name
    $url    = if ($props -contains 'webUrls' -and $status.webUrls.Count -gt 0) { $status.webUrls[0] }
              elseif ($props -contains 'webUrl')  { $status.webUrl }
              elseif ($props -contains 'url')     { $status.url }
              elseif ($props -contains 'baseUrl') { $status.baseUrl }
              else { $null }
    if (-not $url) { throw "Cannot read API URL from 'foundry server status -o json'. Output: $json" }
    return "$($url.TrimEnd('/'))/v1"
}

function Restart-FoundryServer {
    # Run raw — no pipe, no variable assignment, no Tee-Object.
    # foundry server restart uses Spectre Console progress bars that deadlock when stdout is redirected.
    Write-Host "  foundry server restart" -ForegroundColor DarkCyan
    foundry server restart
    $script:ApiBase = Get-FoundryApiBase
    Write-Host "  API: $($script:ApiBase)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# YAML helpers — write immediately, never batch
# ---------------------------------------------------------------------------
function Format-YamlString {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "''" }
    if ($Value -match '[:#\[\]{}&*!|>''"%@`,]' -or $Value -match '^\s' -or $Value -match '\s$') {
        return "'" + ($Value -replace "'", "''") + "'"
    }
    return $Value
}

function Out-Yaml { param([string]$Line) Add-Content -Path $OutputFile -Value $Line -Encoding UTF8 }

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
function Get-SystemInfo {
    Write-Host "  OS / hardware..." -ForegroundColor DarkGray
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    $winBuild   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    $winRev     = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR

    Write-Host "  GPU / display adapters..." -ForegroundColor DarkGray
    $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.Name
            DriverVersion = $_.DriverVersion
            DriverDate    = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { 'unknown' }
        }
    })

    Write-Host "  NPU..." -ForegroundColor DarkGray
    $npuDevices = @(Get-PnpDevice -Class 'ComputeAccelerator','SoftwareDevice' -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -imatch 'NPU|Hexagon|QNN|Neural' } |
        ForEach-Object { $_.FriendlyName })
    if ($npuDevices.Count -eq 0) {
        $npuDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -imatch 'NPU|Hexagon|QNN|Neural' } |
            ForEach-Object { $_.FriendlyName })
    }

    Write-Host "  Memory..." -ForegroundColor DarkGray
    $memSticks = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        "$([math]::Round($_.Capacity/1GB,0))GB $($_.MemoryType) @ $($_.Speed)MHz"
    })

    $foundryVer = (foundry --version 2>&1) -join '' -replace '\s+', ' '

    [PSCustomObject]@{
        MachineMake    = "$($cs.Manufacturer) $($cs.Model)".Trim()
        OS             = "$($os.Caption) (Build $winBuild.$winRev)"
        CPU            = $cpu.Name.Trim()
        CPUCores       = $cpu.NumberOfCores
        CPULogical     = $cpu.NumberOfLogicalProcessors
        CPUMaxMhz      = $cpu.MaxClockSpeed
        RamGb          = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        FreeRamGb      = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        MemorySticks   = $memSticks
        GPUs           = $gpus
        NPUDevices     = $npuDevices
        FoundryVersion = $foundryVer
    }
}

# ---------------------------------------------------------------------------
# Power plan helpers
# ---------------------------------------------------------------------------
function Get-PowerPlans {
    $raw = powercfg /list 2>&1 | Out-String
    $plans = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($line in $raw -split "`n") {
        if ($line -match 'Power Scheme GUID:\s+([0-9a-f-]+)\s+\((.+?)\)\s*(\*)?') {
            $plans.Add([PSCustomObject]@{
                GUID   = $Matches[1].Trim()
                Name   = $Matches[2].Trim()
                Active = $Matches[3] -eq '*'
            })
        }
    }
    return $plans
}

function Get-ActivePowerPlan {
    $raw = powercfg /getactivescheme 2>&1 | Out-String
    if ($raw -match 'Power Scheme GUID.*\((.+?)\)') { return $Matches[1].Trim() }
    return $raw.Trim()
}

function Set-PowerPlan {
    param([string]$GUID)
    powercfg /setactive $GUID
}

# ---------------------------------------------------------------------------
# Safe property access on ConvertFrom-Json objects under Set-StrictMode.
# Direct access ($obj.field) throws if the field is absent in the JSON.
# $obj?.field also throws — the null-conditional does NOT help under strict mode.
# $a ?? $b also does NOT help — the left side throws before ?? evaluates.
# Always use Get-JsonProp for any property on a JSON-parsed object.
# ---------------------------------------------------------------------------
function Get-JsonProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

# ---------------------------------------------------------------------------
# Thermal state — legitimate try/catch: WMI thermal class is optional hardware,
# not present on all machines. Absence is not a script bug.
# ---------------------------------------------------------------------------
function Get-ThermalState {
    try {
        $zones = @(Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        if ($zones.Count -eq 0) { return $null }
        $temps = @($zones | ForEach-Object { [math]::Round(($_.CurrentTemperature - 2732) / 10.0, 1) })
        return [PSCustomObject]@{
            MaxCelsius = ($temps | Measure-Object -Maximum).Maximum
            AvgCelsius = [math]::Round(($temps | Measure-Object -Average).Average, 1)
        }
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# CPU/GPU utilisation sampler.
# Uses an explicit PowerShell Runspace, NOT Start-Job and NOT Task.Run:
#   - Start-Job: spawns a new process, does not inherit session PATH.
#   - Task.Run / thread pool: no PS Runspace on those threads, Get-Counter throws.
#   - Explicit Runspace: in-process, inherits environment, has its own Runspace.
# Data flows back via ConcurrentQueue — no locks needed between threads.
# CancellationTokenSource signals the sampler loop to stop cleanly.
# Stop-UtilizationSampler is wrapped in try/catch because it is a cleanup path —
# it must not shadow an earlier real error that caused an outer catch to run.
# ---------------------------------------------------------------------------
function Start-UtilizationSampler {
    $cts   = [System.Threading.CancellationTokenSource]::new()
    $queue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()
    $rs    = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Queue, $Token)
        while (-not $Token.IsCancellationRequested) {
            $cpu = $null; $gpu = $null
            try {
                $cpu = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue, 1)
            } catch { }
            try {
                $gc = Get-Counter '\GPU Engine(*engtype_3D*)\Utilization Percentage' -ErrorAction Stop
                if ($gc.CounterSamples.Count -gt 0) {
                    $gpu = [math]::Round(($gc.CounterSamples | Measure-Object -Property CookedValue -Average).Average, 1)
                }
            } catch {
                try {
                    $gc = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
                    if ($gc.CounterSamples.Count -gt 0) {
                        $gpu = [math]::Round(($gc.CounterSamples | Measure-Object -Property CookedValue -Sum).Sum, 1)
                    }
                } catch { }
            }
            $Queue.Enqueue([PSCustomObject]@{ CPU = $cpu; GPU = $gpu })
            if (-not $Token.IsCancellationRequested) { Start-Sleep -Milliseconds 500 }
        }
    }).AddArgument($queue).AddArgument($cts.Token)
    $async = $ps.BeginInvoke()
    return [PSCustomObject]@{ PS = $ps; RS = $rs; CTS = $cts; Queue = $queue; Async = $async }
}

function Stop-UtilizationSampler {
    param($Sampler)
    if ($null -eq $Sampler) { return $null }
    try {
        $Sampler.CTS.Cancel()
        try { $Sampler.PS.Stop() } catch { }
        $Sampler.RS.Close(); $Sampler.RS.Dispose(); $Sampler.CTS.Dispose()
        $samples = [System.Collections.Generic.List[PSObject]]::new()
        $item = $null
        while ($Sampler.Queue.TryDequeue([ref]$item)) { $samples.Add($item) }
        if ($samples.Count -eq 0) { return $null }
        $cpuS = @($samples | Where-Object { $null -ne $_.CPU } | ForEach-Object { $_.CPU })
        $gpuS = @($samples | Where-Object { $null -ne $_.GPU } | ForEach-Object { $_.GPU })
        return [PSCustomObject]@{
            SampleCount = $samples.Count
            AvgCpuPct   = if ($cpuS.Count -gt 0) { [math]::Round(($cpuS | Measure-Object -Average).Average, 1) } else { $null }
            MaxCpuPct   = if ($cpuS.Count -gt 0) { [math]::Round(($cpuS | Measure-Object -Maximum).Maximum, 1) } else { $null }
            AvgGpuPct   = if ($gpuS.Count -gt 0) { [math]::Round(($gpuS | Measure-Object -Average).Average, 1) } else { $null }
            MaxGpuPct   = if ($gpuS.Count -gt 0) { [math]::Round(($gpuS | Measure-Object -Maximum).Maximum, 1) } else { $null }
        }
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Transient streaming-failure detection
# ---------------------------------------------------------------------------
# Distinguishes a dropped/timed-out Foundry connection (worth retrying) from a
# real script bug (must surface). Walks the inner-exception chain because a
# .NET method failure reaches us wrapped in a MethodInvocationException whose
# real cause (IOException / WebException) is the InnerException.
function Test-TransientStreamError {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.Message -match 'response ended prematurely|ResponseEnded|transport connection|operation has timed out|actively refused|connection was closed|unexpectedly closed|forcibly closed') {
            return $true
        }
        $ex = $ex.InnerException
    }
    return $false
}

# Unwraps a PowerShell ErrorRecord to the innermost .NET exception message — the
# one that actually says what went wrong. The outer layers are just
# "Exception calling ReadLine ..." wrappers that hide the real cause.
function Get-RootExceptionMessage {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    return $ex.Message
}

# ---------------------------------------------------------------------------
# Streaming completion — TTFT + utilisation + thermal + token counts
# ---------------------------------------------------------------------------
function Invoke-StreamingCompletion {
    param(
        [string]$ModelId,
        [string]$Prompt,
        [string]$ApiBase,
        [int]$MaxTokensArg,
        [double]$TemperatureArg,
        [double]$TopPArg,
        [bool]$IsCold
    )

    $thermal = Get-ThermalState

    $body = @{
        model          = $ModelId
        messages       = @(@{ role = 'user'; content = $Prompt })
        stream         = $true
        max_tokens     = $MaxTokensArg
        temperature    = $TemperatureArg
        top_p          = $TopPArg
        stream_options = @{ include_usage = $true }
    } | ConvertTo-Json -Compress -Depth 5

    # The Foundry server occasionally drops the streaming HTTP connection (see the
    # error-handling philosophy in .NOTES). We retry the whole call when it drops
    # before any token arrives; a drop after tokens have streamed is kept as a
    # (truncated) measurement. Test-TransientStreamError ensures genuine script bugs
    # are rethrown immediately instead of being retried away.
    $maxAttempts  = 3
    $attempt      = 0
    $sampler      = $null
    $swTotal      = $null
    $firstTokenMs = $null
    $tokenCount   = 0
    $promptTokens = $null
    $totalTokens  = $null
    $streamError  = $null

    while ($true) {
        $attempt++
        $sampler      = Start-UtilizationSampler
        $swTotal      = [System.Diagnostics.Stopwatch]::StartNew()
        $firstTokenMs = $null
        $tokenCount   = 0
        $promptTokens = $null
        $totalTokens  = $null
        $streamError  = $null

        try {
            $req             = [System.Net.HttpWebRequest]::Create("$ApiBase/chat/completions")
            $req.Method      = 'POST'
            $req.ContentType = 'application/json'
            $req.Timeout     = $TimeoutSeconds * 1000
            $reqBytes        = [System.Text.Encoding]::UTF8.GetBytes($body)
            $req.ContentLength = $reqBytes.Length
            $reqStream       = $req.GetRequestStream()
            $reqStream.Write($reqBytes, 0, $reqBytes.Length)
            $reqStream.Close()

            $resp   = $req.GetResponse()
            $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())

            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line -notmatch '^data: ') { continue }
                $data = $line.Substring(6).Trim()
                if ($data -eq '[DONE]') { break }
                try {
                    $chunk    = $data | ConvertFrom-Json -ErrorAction Stop
                    $usage    = Get-JsonProp $chunk 'usage'
                    if ($usage) {
                        $promptTokens = Get-JsonProp $usage 'prompt_tokens'
                        $totalTokens  = Get-JsonProp $usage 'total_tokens'
                    }
                    $choices  = Get-JsonProp $chunk 'choices'
                    $delta    = if ($choices -and $choices.Count -gt 0) { Get-JsonProp (Get-JsonProp $choices[0] 'delta') 'content' } else { $null }
                    if ($delta) {
                        if ($null -eq $firstTokenMs) { $firstTokenMs = $swTotal.Elapsed.TotalSeconds }
                        $tokenCount++
                    }
                } catch { }
            }
            $reader.Close(); $resp.Close()
        }
        catch {
            $streamError = $_
        }

        # Clean finish, or a drop after tokens already streamed: accept this attempt.
        if ($null -eq $streamError -or $tokenCount -gt 0) { break }

        # Zero tokens. Dispose this attempt's sampler before retrying so we don't leak
        # runspaces, then retry only on a recognised transient drop.
        Stop-UtilizationSampler -Sampler $sampler | Out-Null
        if (-not (Test-TransientStreamError $streamError) -or $attempt -ge $maxAttempts) {
            throw $streamError
        }
        $reason = Get-RootExceptionMessage $streamError
        Write-Host "      stream dropped before first token: $reason (attempt $attempt/$maxAttempts) — retrying..." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 750
    }

    $swTotal.Stop()
    $truncated    = ($null -ne $streamError)
    $util         = Stop-UtilizationSampler -Sampler $sampler
    $totalSec     = $swTotal.Elapsed.TotalSeconds
    $sustainedSec = if ($firstTokenMs) { $totalSec - $firstTokenMs } else { $totalSec }
    $sustainedTps = if ($sustainedSec -gt 0 -and $tokenCount -gt 1) {
        [math]::Round(($tokenCount - 1) / $sustainedSec, 2) } else { 0 }
    $overallTps   = if ($totalSec -gt 0 -and $tokenCount -gt 0) {
        [math]::Round($tokenCount / $totalSec, 2) } else { 0 }

    return [PSCustomObject]@{
        Prompt                = $Prompt
        Attempts              = $attempt
        Truncated             = $truncated
        PromptTokens          = $promptTokens
        CompletionTokens      = $tokenCount
        TotalTokens           = $totalTokens
        TotalDurationSec      = [math]::Round($totalSec, 3)
        TimeToFirstTokenSec   = if ($firstTokenMs) { [math]::Round($firstTokenMs, 3) } else { $null }
        SustainedTokensPerSec = $sustainedTps
        OverallTokensPerSec   = $overallTps
        ThermalMaxCelsius     = if ($thermal) { $thermal.MaxCelsius } else { $null }
        ThermalAvgCelsius     = if ($thermal) { $thermal.AvgCelsius } else { $null }
        UtilSampleCount       = if ($util) { $util.SampleCount } else { $null }
        AvgCpuPct             = if ($util) { $util.AvgCpuPct } else { $null }
        MaxCpuPct             = if ($util) { $util.MaxCpuPct } else { $null }
        AvgGpuPct             = if ($util) { $util.AvgGpuPct } else { $null }
        MaxGpuPct             = if ($util) { $util.MaxGpuPct } else { $null }
    }
}

# ---------------------------------------------------------------------------
# Benchmark prompts — three categories matching the target table
# ---------------------------------------------------------------------------
$PromptsShort = @(
    'What is the capital of France? Answer in one sentence.',
    'Name the three primary colours of light.',
    'What does CPU stand for?',
    'Who wrote Romeo and Juliet?',
    'What is 2 to the power of 10?'
)

$Prompts256 = @(
    'Explain the difference between RAM and a hard drive in exactly two sentences.',
    'Describe the water cycle in plain English in about two paragraphs.',
    'What are the three laws of thermodynamics? Give a one-line example of each.',
    'Explain what an API is as if explaining to a 10-year-old. Use about 150 words.',
    'Summarise the plot of Romeo and Juliet. Be concise but cover the key events.'
)

$Prompts512 = @(
    'List five advantages and five disadvantages of using a statically typed programming language. Explain each point briefly.',
    'Describe how a binary search algorithm works in plain English, then walk through an example with a sorted list of 10 items.',
    'Write a detailed haiku collection about software development — five haiku, each with a brief explanation of what it represents.',
    'Explain the OSI model layers. For each layer, name it, describe its role, and give a real-world protocol example.',
    'Compare REST and GraphQL APIs. Cover design philosophy, use cases, pros, cons, and give a concrete example request for each.'
)

# Interleave prompt types for variety across calls
function Get-PromptPool {
    param([int]$Count)
    $pool = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($pool.Count -lt $Count) {
        $pool.Add($PromptsShort[$i  % $PromptsShort.Count])
        if ($pool.Count -lt $Count) { $pool.Add($Prompts256[$i  % $Prompts256.Count]) }
        if ($pool.Count -lt $Count) { $pool.Add($Prompts512[$i  % $Prompts512.Count]) }
        $i++
    }
    return @($pool)
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot   = $PSScriptRoot
$OutputDir  = Join-Path $RepoRoot 'output'
$Machine    = $env:COMPUTERNAME
$OutputFile = Join-Path $OutputDir "$Machine.llm.yaml"

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# ---------------------------------------------------------------------------
# Start Foundry so cache list works, read initial API base
# ---------------------------------------------------------------------------
$ApiBase = Get-FoundryApiBase

# ---------------------------------------------------------------------------
# Interactive selections (model, runs, power plan)
# ---------------------------------------------------------------------------
$IsInteractive = -not $Models -or $Models.Count -eq 0

if ($IsInteractive) {
    Write-Host "No model specified — listing cached models..." -ForegroundColor DarkGray
    foundry server start
    Write-Host ""
    Write-Host "  foundry cache list -o json" -ForegroundColor DarkCyan
    $json    = foundry cache list -o json 2>&1 | Out-String
    $parsed  = $json | ConvertFrom-Json -ErrorAction Stop
    $entries = if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) { $parsed }
               elseif ($parsed.PSObject.Properties.Name -contains 'models') { $parsed.models }
               elseif ($parsed.PSObject.Properties.Name -contains 'items')  { $parsed.items  }
               else { @($parsed) }

    $discovered = @(
        $entries | ForEach-Object { $_.alias ?? $_.modelId ?? $_.id ?? $_.name ?? $null } |
        Where-Object { $_ } | Select-Object -Unique
    )
    if ($discovered.Count -eq 0) {
        throw "No cached models found. Run 'foundry model download <id>' first."
    }

    $allOption = '*** All models ***'
    Write-Host ""
    $selectedModel = Read-SpectreSelection `
        -Title "[cyan]Select a model to benchmark[/]" `
        -Choices (@($allOption) + $discovered) `
        -PageSize 11
    if (-not $selectedModel) { Write-Host "No model selected. Exiting." -ForegroundColor Yellow; return }
    $Models = if ($selectedModel -eq $allOption) { $discovered } else { @($selectedModel) }
    Write-Host ""
}

# Runs picker
if ($Runs -le 0) {
    Write-Host ""
    $runsChoice = Read-SpectreSelection `
        -Title "[cyan]How many runs per model? (no restart between runs)[/]" `
        -Choices @('1', '2', '3', '5', '10') `
        -PageSize 5
    $Runs = [int]$runsChoice
    Write-Host ""
}

# Power plan picker
Write-Host "Reading power plans..." -ForegroundColor DarkGray
$powerPlans   = Get-PowerPlans
$activePlan   = $powerPlans | Where-Object { $_.Active } | Select-Object -First 1
$activePlanName = if ($activePlan) { $activePlan.Name } else { Get-ActivePowerPlan }

Write-Host "  Current power plan: $activePlanName" -ForegroundColor DarkGray
Write-Host ""

if ($powerPlans.Count -gt 1) {
    $planChoices = @($powerPlans | ForEach-Object { "$($_.Name)$(if ($_.Active) { ' (active)' } else { '' })" })
    $planChoice  = Read-SpectreSelection `
        -Title "[cyan]Power plan for this session[/]" `
        -Choices $planChoices `
        -PageSize 8
    # Extract just the name (strip " (active)" suffix)
    $chosenName = $planChoice -replace ' \(active\)$', ''
    $chosenPlan = $powerPlans | Where-Object { $_.Name -eq $chosenName } | Select-Object -First 1
    if ($chosenPlan -and (-not $activePlan -or $chosenPlan.GUID -ne $activePlan.GUID)) {
        Write-Host "  Applying power plan: $($chosenPlan.Name)" -ForegroundColor Yellow
        Set-PowerPlan -GUID $chosenPlan.GUID
        Start-Sleep -Milliseconds 500
    }
    $activePlanName = if ($chosenPlan) { $chosenPlan.Name } else { $activePlanName }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
Write-Host "Collecting system info..." -ForegroundColor DarkGray
$sysInfo = Get-SystemInfo

Write-Host ""
Write-Host "  Machine  : $($sysInfo.MachineMake)"   -ForegroundColor DarkGray
Write-Host "  OS       : $($sysInfo.OS)"             -ForegroundColor DarkGray
Write-Host "  CPU      : $($sysInfo.CPU) ($($sysInfo.CPUCores)c/$($sysInfo.CPULogical)t @ $($sysInfo.CPUMaxMhz)MHz)" -ForegroundColor DarkGray
Write-Host "  RAM      : $($sysInfo.RamGb) GB total, $($sysInfo.FreeRamGb) GB free" -ForegroundColor DarkGray
foreach ($g in $sysInfo.GPUs) {
    Write-Host "  GPU      : $($g.Name) (driver $($g.DriverVersion) $($g.DriverDate))" -ForegroundColor DarkGray
}
if ($sysInfo.NPUDevices.Count -gt 0) {
    Write-Host "  NPU      : $($sysInfo.NPUDevices -join ', ')" -ForegroundColor DarkGray
}
Write-Host "  Power    : $activePlanName"            -ForegroundColor DarkGray
Write-Host "  Foundry  : $($sysInfo.FoundryVersion)" -ForegroundColor DarkGray
Write-Host ""

Write-Host "LLM Benchmark — $Machine" -ForegroundColor Cyan
Write-Host "  Models : $($Models -join ', ')" -ForegroundColor Cyan
Write-Host "  Runs   : $Runs   Calls: $Calls   (total $(($Runs * $Calls)) calls per model)" -ForegroundColor Cyan
Write-Host "  Params : temp=$Temperature  topP=$TopP  maxTokens=$MaxTokens" -ForegroundColor Cyan
Write-Host "  Output : $OutputFile" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# YAML file — append-only. Never delete or overwrite.
# machine/system block written once on first creation.
# Session ID derived by counting existing "  - sessionId:" lines; no file parsing needed.
# ---------------------------------------------------------------------------
$isNewFile = -not (Test-Path $OutputFile)

if ($isNewFile) {
    Out-Yaml "machine: $Machine"
    Out-Yaml "system:"
    Out-Yaml "  make: $(Format-YamlString $sysInfo.MachineMake)"
    Out-Yaml "  os: $(Format-YamlString $sysInfo.OS)"
    Out-Yaml "  cpu:"
    Out-Yaml "    name: $(Format-YamlString $sysInfo.CPU)"
    Out-Yaml "    cores: $($sysInfo.CPUCores)"
    Out-Yaml "    logicalProcessors: $($sysInfo.CPULogical)"
    Out-Yaml "    maxMhz: $($sysInfo.CPUMaxMhz)"
    Out-Yaml "  memory:"
    Out-Yaml "    totalGb: $($sysInfo.RamGb)"
    Out-Yaml "    sticks:"
    foreach ($s in $sysInfo.MemorySticks) { Out-Yaml "      - $(Format-YamlString $s)" }
    Out-Yaml "  gpus:"
    foreach ($g in $sysInfo.GPUs) {
        Out-Yaml "    - name: $(Format-YamlString $g.Name)"
        Out-Yaml "      driverVersion: $(Format-YamlString $g.DriverVersion)"
        Out-Yaml "      driverDate: $($g.DriverDate)"
    }
    if ($sysInfo.NPUDevices.Count -gt 0) {
        Out-Yaml "  npu:"
        foreach ($n in $sysInfo.NPUDevices) { Out-Yaml "    - $(Format-YamlString $n)" }
    }
    Out-Yaml "sessions:"
}

# Determine next session ID from existing file
$sessionId = 1
if (-not $isNewFile) {
    $existingContent = Get-Content $OutputFile -Raw -ErrorAction SilentlyContinue
    $sessionId = ([regex]::Matches($existingContent, '  - sessionId:')).Count + 1
}

# Write session header
Out-Yaml "  - sessionId: $sessionId"
Out-Yaml "    date: $([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Out-Yaml "    foundryVersion: $(Format-YamlString $sysInfo.FoundryVersion)"
Out-Yaml "    powerPlan: $(Format-YamlString $activePlanName)"
Out-Yaml "    freeRamGbAtTest: $($sysInfo.FreeRamGb)"
Out-Yaml "    samplingDefaults:"
Out-Yaml "      temperature: $Temperature"
Out-Yaml "      topP: $TopP"
Out-Yaml "      maxTokens: $MaxTokens"
Out-Yaml "    models:"

# ---------------------------------------------------------------------------
# Per-model benchmark
# ---------------------------------------------------------------------------
$promptPool = Get-PromptPool -Count ($Calls * $Runs)

foreach ($model in $Models) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "Model: $model" -ForegroundColor Yellow
    Write-Host ""

    # --- Restart for clean load ---
    Restart-FoundryServer

    # --- Load model — run raw, no pipe (Spectre Console deadlock, see NOTES) ---
    $loadTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ""
    Write-Host "  foundry model load $model" -ForegroundColor DarkCyan
    foundry model load $model
    $loadOk = $LASTEXITCODE -eq 0
    $loadTimer.Stop()
    $loadSec = [math]::Round($loadTimer.Elapsed.TotalSeconds, 3)

    # --- Resolve the friendly name to the actual API model id, plus variant /
    #     ORT provider / quantisation.
    #
    #     CRITICAL: foundry's /v1/chat/completions endpoint does NOT accept the
    #     friendly alias ("phi-4"), nor the variant id with its ":N" suffix
    #     ("Phi-4-cuda-gpu:2"). It accepts ONLY the displayName ("Phi-4-cuda-gpu").
    #     Sending the alias makes the server return 200 then immediately drop the
    #     connection ("The response ended prematurely / ResponseEnded") — which is
    #     exactly the cold-call failure that aborted benchmarks. We therefore load
    #     by friendly name (what the user passes) but CALL by displayName.
    #
    #     JSON shape: { "model": { alias, id, displayName, device,
    #       variants: [ { id, displayName, executionProvider, ... } ] } }.
    #     Use Get-JsonProp for all access — direct $obj.field throws under strict mode
    #     when the field is absent. foundry model info -o json is safe to capture;
    #     without -o json it uses Spectre Console and must run raw. ---
    $apiModelId   = $model     # fallback: friendly name (only kept if info parse fails)
    $variant      = $null
    $provider     = $null
    $quantization = $null

    Write-Host ""
    Write-Host "  foundry model info $model -o json" -ForegroundColor DarkCyan
    try {
        $infoJson = foundry model info $model -o json 2>&1 | Out-String
        $info     = $infoJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        $m        = Get-JsonProp $info 'model'
        if (-not $m) { $m = $info }   # tolerate a flat (non-nested) shape

        # API model id: displayName is the only id the endpoint accepts.
        $displayName     = Get-JsonProp $m 'displayName'
        $loadedVariantId = Get-JsonProp $m 'id'
        if ($displayName)         { $apiModelId = $displayName }
        elseif ($loadedVariantId) { $apiModelId = $loadedVariantId }

        $variant = if ($displayName) { $displayName }
                   elseif ($loadedVariantId) { $loadedVariantId }
                   else { Get-JsonProp $m 'alias' }

        # Execution provider: prefer the loaded variant's real ORT provider name
        # (e.g. CUDAExecutionProvider) over the coarse "device" label, which would
        # otherwise mis-map a CUDA GPU to WebGpuExecutionProvider.
        $variants = Get-JsonProp $m 'variants'
        $hwLabel  = $null
        if ($variants) {
            $vmatch = @($variants) | Where-Object { (Get-JsonProp $_ 'id') -eq $loadedVariantId } | Select-Object -First 1
            if ($vmatch) { $hwLabel = Get-JsonProp $vmatch 'executionProvider' }
        }
        if ($hwLabel) {
            $provider = $hwLabel   # already a full *ExecutionProvider name
        } else {
            $deviceLabel = Get-JsonProp $m 'device'
            $provider = switch -Wildcard ($deviceLabel) {
                '*NPU*' { 'QNNExecutionProvider' }
                '*GPU*' { 'WebGpuExecutionProvider' }
                '*CPU*' { 'CPUExecutionProvider' }
                default { $deviceLabel }
            }
        }

        $quantization = Get-JsonProp $m 'quantization'
        if (-not $quantization) { $quantization = Get-JsonProp $m 'quantType' }
        if (-not $quantization) { $quantization = Get-JsonProp $m 'quant' }
        if (-not $quantization) { $quantization = Get-JsonProp $m 'dtype' }
        if ($null -ne $quantization -and $quantization -isnot [string]) { $quantization = [string]$quantization }
    } catch { }

    if (-not $loadOk) {
        Write-Warning "  Failed to load '$model' — skipping."
        Out-Yaml "      - id: $(Format-YamlString $model)"
        Out-Yaml "        loadSucceeded: false"
        Out-Yaml "        loadTimeSec: $loadSec"
        continue
    }

    Write-Host "  Loaded in ${loadSec}s  apiModelId: $apiModelId  provider: $provider  variant: $variant  quant: $quantization" -ForegroundColor Green

    Out-Yaml "      - id: $(Format-YamlString $model)"
    Out-Yaml "        loadSucceeded: true"
    Out-Yaml "        loadTimeSec: $loadSec"
    if ($apiModelId)   { Out-Yaml "        apiModelId: $(Format-YamlString $apiModelId)" }
    if ($provider)     { Out-Yaml "        executionProvider: $(Format-YamlString $provider)" }
    if ($variant)      { Out-Yaml "        variant: $(Format-YamlString $variant)" }
    if ($quantization) { Out-Yaml "        quantization: $(Format-YamlString $quantization)" }
    Out-Yaml "        runs:"

    # --- Runs loop (no restart between runs) ---
    $modelOverallTps   = [System.Collections.Generic.List[double]]::new()
    $modelSustainedTps = [System.Collections.Generic.List[double]]::new()
    $modelCrashed      = $false

    for ($run = 1; $run -le $Runs; $run++) {
        Write-Host ""
        Write-Host "  --- Run $run/$Runs ---" -ForegroundColor DarkCyan
        Out-Yaml "          - runId: $run"
        Out-Yaml "            calls:"

        $runOverallTps   = [System.Collections.Generic.List[double]]::new()
        $runSustainedTps = [System.Collections.Generic.List[double]]::new()

        for ($i = 0; $i -lt $Calls; $i++) {
            $globalCallIndex = ($run - 1) * $Calls + $i
            $prompt          = $promptPool[$globalCallIndex % $promptPool.Count]
            $shortPrompt     = if ($prompt.Length -gt 50) { $prompt.Substring(0, 47) + '...' } else { $prompt }
            # cold=true only for run 1 / call 1 — first call after model load.
            # All subsequent calls (including call 1 of run 2+) are warm; weights are resident.
            $isCold          = ($run -eq 1 -and $i -eq 0)
            $coldLabel       = if ($isCold) { ' [cold]' } else { '' }

            Write-Host "    Call $($i+1)/$Calls$coldLabel '$shortPrompt'" -ForegroundColor DarkGray

            # The Foundry inference backend can crash mid-run (the HTTP frontend stays
            # up and returns 200, then drops the body — "ResponseEnded"). When the
            # in-process retries in Invoke-StreamingCompletion are exhausted it throws;
            # we catch ONLY transient/connection errors (Test-TransientStreamError) so
            # real script bugs still surface, then recover by restarting the server and
            # reloading the model on a fresh backend/port and retrying the call once.
            # If recovery also fails we record the crash and abandon THIS model, so one
            # flaky model can no longer abort the entire benchmark.
            $r         = $null
            $callError = $null
            try {
                $r = Invoke-StreamingCompletion `
                    -ModelId $apiModelId -Prompt $prompt -ApiBase $ApiBase `
                    -MaxTokensArg $MaxTokens -TemperatureArg $Temperature -TopPArg $TopP `
                    -IsCold $isCold
            } catch {
                if (-not (Test-TransientStreamError $_)) { throw }   # real bug: surface it
                $callError = $_
            }

            if ($null -eq $r) {
                $reason = Get-RootExceptionMessage $callError
                Write-Host "      call failed: $reason" -ForegroundColor Red
                Write-Host "      Foundry backend appears to have crashed — restarting server and reloading '$model'..." -ForegroundColor Yellow
                Restart-FoundryServer            # updates $script:ApiBase to the new port
                Write-Host "  foundry model load $model" -ForegroundColor DarkCyan
                foundry model load $model
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $r = Invoke-StreamingCompletion `
                            -ModelId $apiModelId -Prompt $prompt -ApiBase $ApiBase `
                            -MaxTokensArg $MaxTokens -TemperatureArg $Temperature -TopPArg $TopP `
                            -IsCold $isCold
                    } catch {
                        if (-not (Test-TransientStreamError $_)) { throw }
                        $callError = $_
                    }
                }
            }

            if ($null -eq $r) {
                $reason = Get-RootExceptionMessage $callError
                Write-Host "      crash recovery failed — abandoning '$model' and moving on: $reason" -ForegroundColor Red
                Out-Yaml "              - call: $($i+1)"
                Out-Yaml "                failed: true"
                Out-Yaml "                error: $(Format-YamlString $reason)"
                $modelCrashed = $true
                break
            }

            Out-Yaml "              - call: $($i+1)"
            Out-Yaml "                cold: $(if ($isCold) { 'true' } else { 'false' })"
            Out-Yaml "                temperature: $Temperature"
            Out-Yaml "                topP: $TopP"
            Out-Yaml "                maxTokens: $MaxTokens"
            Out-Yaml "                prompt: $(Format-YamlString $r.Prompt)"
            if ($r.Attempts -gt 1) { Out-Yaml "                attempts: $($r.Attempts)" }
            if ($r.Truncated)      { Out-Yaml "                truncated: true" }
            if ($null -ne $r.PromptTokens) { Out-Yaml "                promptTokens: $($r.PromptTokens)" }
            Out-Yaml "                completionTokens: $($r.CompletionTokens)"
            if ($null -ne $r.TotalTokens)  { Out-Yaml "                totalTokens: $($r.TotalTokens)" }
            Out-Yaml "                totalDurationSec: $($r.TotalDurationSec)"
            Out-Yaml "                timeToFirstTokenSec: $($r.TimeToFirstTokenSec)"
            Out-Yaml "                sustainedTokensPerSec: $($r.SustainedTokensPerSec)"
            Out-Yaml "                overallTokensPerSec: $($r.OverallTokensPerSec)"
            if ($null -ne $r.ThermalMaxCelsius) {
                Out-Yaml "                thermalMaxCelsius: $($r.ThermalMaxCelsius)"
                Out-Yaml "                thermalAvgCelsius: $($r.ThermalAvgCelsius)"
            }
            if ($null -ne $r.UtilSampleCount -and $r.UtilSampleCount -gt 0) {
                Out-Yaml "                utilization:"
                Out-Yaml "                  sampleCount: $($r.UtilSampleCount)"
                if ($null -ne $r.AvgCpuPct) {
                    Out-Yaml "                  avgCpuPct: $($r.AvgCpuPct)"
                    Out-Yaml "                  maxCpuPct: $($r.MaxCpuPct)"
                }
                if ($null -ne $r.AvgGpuPct) {
                    Out-Yaml "                  avgGpuPct: $($r.AvgGpuPct)"
                    Out-Yaml "                  maxGpuPct: $($r.MaxGpuPct)"
                }
            }

            $runOverallTps.Add($r.OverallTokensPerSec)
            $runSustainedTps.Add($r.SustainedTokensPerSec)
            $modelOverallTps.Add($r.OverallTokensPerSec)
            $modelSustainedTps.Add($r.SustainedTokensPerSec)

            $cpuTxt   = if ($r.AvgCpuPct)        { "  cpu:$($r.AvgCpuPct)%/$($r.MaxCpuPct)%" } else { '' }
            $gpuTxt   = if ($r.AvgGpuPct)        { "  gpu:$($r.AvgGpuPct)%/$($r.MaxGpuPct)%" } else { '' }
            $thermTxt = if ($r.ThermalMaxCelsius) { "  $($r.ThermalMaxCelsius)°C" } else { '' }
            $truncTxt = if ($r.Truncated)         { '  [truncated]' } else { '' }
            Write-Host ("      TTFT:{0}s  sust:{1}t/s  total:{2}t/s  ({3}tok){4}{5}{6}{7}" -f `
                $r.TimeToFirstTokenSec, $r.SustainedTokensPerSec, $r.OverallTokensPerSec,
                $r.CompletionTokens, $cpuTxt, $gpuTxt, $thermTxt, $truncTxt) -ForegroundColor Green
        }

        # Run-level averages
        if ($runOverallTps.Count -gt 0) {
            $rAvgOverall   = [math]::Round(($runOverallTps   | Measure-Object -Average).Average, 2)
            $rAvgSustained = [math]::Round(($runSustainedTps | Measure-Object -Average).Average, 2)
            Out-Yaml "            averageOverallTokensPerSec: $rAvgOverall"
            Out-Yaml "            averageSustainedTokensPerSec: $rAvgSustained"
            Write-Host ("    Run $run avg: overall {0} t/s  sustained {1} t/s" -f $rAvgOverall, $rAvgSustained) -ForegroundColor Cyan
        }

        if ($modelCrashed) { break }
    }

    # Model-level summary (across all runs)
    if ($modelOverallTps.Count -gt 0) {
        $mAvgOverall   = [math]::Round(($modelOverallTps   | Measure-Object -Average).Average, 2)
        $mAvgSustained = [math]::Round(($modelSustainedTps | Measure-Object -Average).Average, 2)
        # "Warm" = exclude run 1 call 1
        $warmList = $modelOverallTps | Select-Object -Skip 1
        $mWarm    = if (@($warmList).Count -gt 0) {
            [math]::Round((@($warmList) | Measure-Object -Average).Average, 2) } else { $mAvgOverall }
        Out-Yaml "        averageOverallTokensPerSec: $mAvgOverall"
        Out-Yaml "        averageSustainedTokensPerSec: $mAvgSustained"
        Out-Yaml "        averageWarmOverallTokensPerSec: $mWarm"

        Write-Host ""
        Write-Host ("  Model total: overall {0} t/s  sustained {1} t/s  warm {2} t/s  load {3}s" -f `
            $mAvgOverall, $mAvgSustained, $mWarm, $loadSec) -ForegroundColor Cyan
    }

    if ($modelCrashed) {
        Out-Yaml "        completed: false"
        Write-Host "  '$model' did not complete — results above are partial." -ForegroundColor Yellow
    }

    Write-Host ""
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
Write-Host "Session $sessionId complete. Results appended to:" -ForegroundColor Green
Write-Host "  $OutputFile" -ForegroundColor White
Write-Host ""
