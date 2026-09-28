[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$logsDirectoryPath = Join-Path -Path $scriptRoot -ChildPath 'logs'
if (-not (Test-Path -Path $logsDirectoryPath)) {
    New-Item -Path $logsDirectoryPath -ItemType Directory -Force | Out-Null
}

$logFilePath = Join-Path -Path $logsDirectoryPath -ChildPath ("app_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$monitorIntervalSeconds = 5
$backupCommand = 'sdclt.exe /kickoffjob'
$backupProcessName = 'wbengine'
$backupEngineHintTimeoutSeconds = 300
$backupStartEventTimeoutSeconds = 1200
$backupMonitorTimeoutSeconds = 10800

Import-Module -Name (Join-Path -Path $scriptRoot -ChildPath 'BackupMonitoring.psm1') -Force -ErrorAction Stop

function TestBackupEngineActive {
    $runningEngineProcess = Get-Process -Name $backupProcessName -ErrorAction SilentlyContinue
    if ($null -ne $runningEngineProcess) {
        return $true
    }

    return $false
}

function WriteLogLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFilePath,

        [Parameter(Mandatory = $true)]
        [string]$LogLine
    )

    $maxRetryCount = 5
    $retryIntervalMilliseconds = 200

    for ($attempt = 1; $attempt -le $maxRetryCount; $attempt++) {
        try {
            $fileStream = [System.IO.File]::Open(
                $LogFilePath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )

            try {
                $utf8Encoding = [System.Text.UTF8Encoding]::new($false)
                $streamWriter = [System.IO.StreamWriter]::new($fileStream, $utf8Encoding)

                try {
                    $streamWriter.WriteLine($LogLine)
                } finally {
                    $streamWriter.Dispose()
                }
            } finally {
                $fileStream.Dispose()
            }

            return
        } catch [System.IO.IOException] {
            if ($attempt -eq $maxRetryCount) {
                throw
            }

            Start-Sleep -Milliseconds $retryIntervalMilliseconds
        }
    }
}

$writeLog = {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "{0} [{1}] {2}" -f $timestamp, $Level, $Message
    WriteLogLine -LogFilePath $logFilePath -LogLine $logLine
    Write-Output $logLine
}

$assertAdministrator = {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    $isAdministrator = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdministrator) {
        throw '管理者権限で実行してください。'
    }
}

if (-not ('PowerStateNativeMethods' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class PowerStateNativeMethods
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@
}

$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1

$exitCode = 1
$phase = 'initialize'
$isSleepSuppressionEnabled = $false

& $writeLog -Level 'INFO' -Message 'アプリケーションを開始しました'

try {
    & $assertAdministrator

    $phase = 'captureBackupEventCheckpoint'
    $backupEventRecordId = GetBackupEventCheckpoint
    & $writeLog -Level 'INFO' -Message ("Windows Backupイベント監視を準備しました: RecordId={0}" -f $backupEventRecordId)

    $phase = 'enableSleepSuppression'
    $executionStateFlags = [uint32]($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
    $setResult = [PowerStateNativeMethods]::SetThreadExecutionState($executionStateFlags)
    if ($setResult -eq 0) {
        throw 'SetThreadExecutionState の呼び出しに失敗しました。'
    }

    $isSleepSuppressionEnabled = $true
    & $writeLog -Level 'INFO' -Message 'スリープ抑止を有効化しました'

    $phase = 'startBackup'
    $backupRequestedAt = [DateTimeOffset]::Now
    $backupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath 'sdclt.exe' -ArgumentList '/kickoffjob' -WindowStyle Hidden
    & $writeLog -Level 'INFO' -Message ("バックアップを開始しました: {0}" -f $backupCommand)

    $phase = 'monitorBackupProcess'
    $hasObservedBackupEngine = $false
    $hasLoggedEngineDetectionTimeout = $false
    $lastLoggedMonitorState = ''
    while ($true) {
        $backupEvents = GetBackupEventsAfterRecordId -RecordId $backupEventRecordId
        if (-not $hasObservedBackupEngine -and (TestBackupEngineActive)) {
            $hasObservedBackupEngine = $true
            & $writeLog -Level 'INFO' -Message 'wbengineを検知しました。イベントID 1で対象バックアップを確認します'
        }

        $elapsedSeconds = $backupStopwatch.Elapsed.TotalSeconds
        $backupDecision = GetBackupMonitorDecision `
            -Events $backupEvents `
            -RecordIdBaseline $backupEventRecordId `
            -RequestStartedAt $backupRequestedAt `
            -ElapsedSeconds $elapsedSeconds `
            -StartEventTimeoutSeconds $backupStartEventTimeoutSeconds `
            -OverallTimeoutSeconds $backupMonitorTimeoutSeconds

        if ($backupDecision.State -eq 'Succeeded') {
            $terminalEvent = $backupDecision.TerminalEvent
            $templateId = $terminalEvent.Data['BackupTemplateID']
            $backupTime = $terminalEvent.Data['BackupTime']
            $backupTarget = $terminalEvent.Data['BackupTarget']
            & $writeLog -Level 'INFO' -Message ("バックアップの正常終了をイベントで確認しました: TemplateID={0}, BackupTarget={1}, BackupTime(UTC)={2}" -f $templateId, $backupTarget, $backupTime)
            $exitCode = 0
            break
        }

        if ($backupDecision.State -eq 'Failed' -or $backupDecision.State -eq 'Ambiguous' -or $backupDecision.State -eq 'StartTimedOut' -or $backupDecision.State -eq 'TimedOut') {
            $terminalEvent = $backupDecision.TerminalEvent
            if ($null -ne $terminalEvent) {
                $templateId = $terminalEvent.Data['BackupTemplateID']
                $hresult = $terminalEvent.Data['HRESULT']
                $detailedHResult = $terminalEvent.Data['DetailedHRESULT']
                throw ("{0} EventId={1}, TemplateID={2}, HRESULT={3}, DetailedHRESULT={4}" -f $backupDecision.Message, $terminalEvent.Id, $templateId, $hresult, $detailedHResult)
            }

            throw $backupDecision.Message
        }

        if ($backupDecision.State -eq 'WaitingForStart' -and -not $hasObservedBackupEngine -and -not $hasLoggedEngineDetectionTimeout -and $elapsedSeconds -ge $backupEngineHintTimeoutSeconds) {
            & $writeLog -Level 'WARN' -Message ("{0} 秒以内にwbengineを検知できませんでした。開始イベントの確認を継続します" -f $backupEngineHintTimeoutSeconds)
            $hasLoggedEngineDetectionTimeout = $true
        }

        if ($backupDecision.State -ne $lastLoggedMonitorState) {
            if ($backupDecision.State -eq 'WaitingForStart') {
                & $writeLog -Level 'INFO' -Message '今回のバックアップ開始イベントを待機中です'
            } else {
                $templateId = $backupDecision.StartEvent.Data['BackupTemplateID']
                & $writeLog -Level 'INFO' -Message ("バックアップ監視中: TemplateID={0} の終了イベントを待機中です" -f $templateId)
            }

            $lastLoggedMonitorState = $backupDecision.State
        }

        Start-Sleep -Seconds $monitorIntervalSeconds
    }
} catch {
    if ($phase -eq 'startBackup' -or $phase -eq 'waitBackupProcessStart') {
        & $writeLog -Level 'ERROR' -Message ("バックアップ開始に失敗しました: {0}" -f $_.Exception.Message)
    } elseif ($phase -eq 'captureBackupEventCheckpoint') {
        & $writeLog -Level 'ERROR' -Message ("Windows Backupイベント監視を準備できませんでした: {0}" -f $_.Exception.Message)
    } elseif ($phase -eq 'monitorBackupProcess') {
        & $writeLog -Level 'ERROR' -Message ("監視中にエラーが発生しました: {0}" -f $_.Exception.Message)
    } else {
        & $writeLog -Level 'ERROR' -Message ("処理中にエラーが発生しました: {0}" -f $_.Exception.Message)
    }
} finally {
    if ($isSleepSuppressionEnabled) {
        try {
            $resetResult = [PowerStateNativeMethods]::SetThreadExecutionState([uint32]$ES_CONTINUOUS)
            if ($resetResult -eq 0) {
                throw 'SetThreadExecutionState による復元に失敗しました。'
            }

            & $writeLog -Level 'INFO' -Message 'スリープ抑止を解除しました'
        } catch {
            & $writeLog -Level 'WARN' -Message ("スリープ抑止解除処理で警告が発生しました: {0}" -f $_.Exception.Message)
        }
    }

    & $writeLog -Level 'INFO' -Message 'アプリケーションを終了します'
}

exit $exitCode
