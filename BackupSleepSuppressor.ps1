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
$backupStartupTimeoutSeconds = 300

function TestBackupEngineActive {
    $runningEngineProcess = Get-Process -Name $backupProcessName -ErrorAction SilentlyContinue
    if ($null -ne $runningEngineProcess) {
        return $true
    }

    return $false
}

function GetWbadminStatus {
    $statusText = ''

    try {
        $statusText = (& wbadmin get status 2>&1 | Out-String)
    } catch {
        return [PSCustomObject]@{
            State = 'Unknown'
            IsAvailable = $false
            StatusText = $_.Exception.Message
        }
    }

    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{
            State = 'Unknown'
            IsAvailable = $false
            StatusText = $statusText.Trim()
        }
    }

    if ($statusText -match '(?i)no\s+operation\s+in\s+progress' -or $statusText -match '実行中の操作はありません') {
        return [PSCustomObject]@{
            State = 'NotRunning'
            IsAvailable = $true
            StatusText = $statusText.Trim()
        }
    }

    if ($statusText -match '(?i)in\s+progress' -or $statusText -match '実行中') {
        return [PSCustomObject]@{
            State = 'Running'
            IsAvailable = $true
            StatusText = $statusText.Trim()
        }
    }

    return [PSCustomObject]@{
        State = 'Unknown'
        IsAvailable = $true
        StatusText = $statusText.Trim()
    }
}

function TestBackupActive {
    $wbadminStatus = GetWbadminStatus
    if ($wbadminStatus.State -eq 'Running' -or $wbadminStatus.State -eq 'NotRunning') {
        return [PSCustomObject]@{
            PrimaryState = $wbadminStatus.State
            EffectiveState = $wbadminStatus.State
            Source = 'wbadmin'
            StatusText = $wbadminStatus.StatusText
        }
    }

    # wbadmin 判定が Unknown の場合のみプロセス監視にフォールバックする
    if (TestBackupEngineActive) {
        return [PSCustomObject]@{
            PrimaryState = 'Unknown'
            EffectiveState = 'Running'
            Source = 'wbengine'
            StatusText = $wbadminStatus.StatusText
        }
    }

    return [PSCustomObject]@{
        PrimaryState = 'Unknown'
        EffectiveState = 'NotRunning'
        Source = 'wbengine'
        StatusText = $wbadminStatus.StatusText
    }
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

    $phase = 'enableSleepSuppression'
    $executionStateFlags = [uint32]($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
    $setResult = [PowerStateNativeMethods]::SetThreadExecutionState($executionStateFlags)
    if ($setResult -eq 0) {
        throw 'SetThreadExecutionState の呼び出しに失敗しました。'
    }

    $isSleepSuppressionEnabled = $true
    & $writeLog -Level 'INFO' -Message 'スリープ抑止を有効化しました'

    $phase = 'startBackup'
    Start-Process -FilePath 'sdclt.exe' -ArgumentList '/kickoffjob' -WindowStyle Hidden
    & $writeLog -Level 'INFO' -Message ("バックアップを開始しました: {0}" -f $backupCommand)

    $phase = 'waitBackupProcessStart'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $backupStartupTimeoutSeconds) {
        $backupState = TestBackupActive
        if ($backupState.EffectiveState -eq 'Running') {
            break
        }

        Start-Sleep -Seconds 1
    }

    $finalBackupState = TestBackupActive
    if ($finalBackupState.EffectiveState -ne 'Running') {
        if ($finalBackupState.PrimaryState -eq 'Unknown') {
            throw ("バックアップジョブの開始を {0} 秒以内に確認できませんでした。wbadmin 判定不可、wbengine 未検出。wbadmin 状態: {1}" -f $backupStartupTimeoutSeconds, $finalBackupState.StatusText)
        }

        throw ("バックアップジョブの開始を {0} 秒以内に確認できませんでした。wbadmin 状態: {1}" -f $backupStartupTimeoutSeconds, $finalBackupState.StatusText)
    }

    $phase = 'monitorBackupProcess'
    while ($true) {
        $backupState = TestBackupActive
        if ($backupState.EffectiveState -ne 'Running') {
            break
        }

        if ($backupState.Source -eq 'wbengine') {
            & $writeLog -Level 'INFO' -Message 'バックアップ監視中: wbadmin 判定不可のため wbengine を使用して監視中'
        } else {
            & $writeLog -Level 'INFO' -Message 'バックアップ監視中: バックアップ処理 実行中'
        }

        Start-Sleep -Seconds $monitorIntervalSeconds
    }

    & $writeLog -Level 'INFO' -Message 'バックアップ完了を検知しました'
    $exitCode = 0
} catch {
    if ($phase -eq 'startBackup' -or $phase -eq 'waitBackupProcessStart') {
        & $writeLog -Level 'ERROR' -Message ("バックアップ開始に失敗しました: {0}" -f $_.Exception.Message)
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
