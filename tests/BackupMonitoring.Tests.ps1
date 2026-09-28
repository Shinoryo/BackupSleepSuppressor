$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\BackupMonitoring.psm1'
Import-Module -Name $modulePath -Force

$script:requestStartedAt = [DateTimeOffset]::Parse('2026-09-27T10:00:01Z')
$script:targetTemplateId = '{4309e1ed-48ed-49a6-8989-7655a5f4c116}'
$script:otherTemplateId = '{6c10d7e7-492c-416f-b548-ad9fb49a6e2c}'

function NewBackupEventFixture {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Id,

        [Parameter(Mandatory = $true)]
        [long]$RecordId,

        [Parameter(Mandatory = $true)]
        [string]$TemplateId,

        [Parameter(Mandatory = $true)]
        [string]$TimeCreated,

        [Parameter()]
        [string]$BackupTime,

        [Parameter()]
        [string]$BackupTarget,

        [Parameter()]
        [string]$HResult,

        [Parameter()]
        [string]$DetailedHResult,

        [Parameter()]
        [string]$BackupState,

        [Parameter()]
        [int]$ProcessId = 33664,

        [Parameter()]
        [int]$ThreadId = 63208
    )

    $eventData = @{ BackupTemplateID = $TemplateId }
    if (-not [string]::IsNullOrWhiteSpace($BackupTime)) {
        $eventData.BackupTime = $BackupTime
    }
    if (-not [string]::IsNullOrWhiteSpace($BackupTarget)) {
        $eventData.BackupTarget = $BackupTarget
    }
    if (-not [string]::IsNullOrWhiteSpace($HResult)) {
        $eventData.HRESULT = $HResult
    }
    if (-not [string]::IsNullOrWhiteSpace($DetailedHResult)) {
        $eventData.DetailedHRESULT = $DetailedHResult
    }
    if (-not [string]::IsNullOrWhiteSpace($BackupState)) {
        $eventData.BackupState = $BackupState
    }

    return [PSCustomObject]@{
        LogName      = 'Microsoft-Windows-Backup'
        ProviderName = 'Microsoft-Windows-Backup'
        Id           = $Id
        RecordId     = $RecordId
        TimeCreated  = [DateTimeOffset]::Parse($TimeCreated)
        ProcessId    = $ProcessId
        ThreadId     = $ThreadId
        Data         = $eventData
    }
}

Describe 'Backup event monitoring' {
    It 'parses event XML fields used for correlation' {
        $eventXml = @'
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='Microsoft-Windows-Backup'/><EventID>14</EventID><TimeCreated SystemTime='2026-09-27T16:03:13.7563617Z'/><EventRecordID>39</EventRecordID><Execution ProcessID='33664' ThreadID='63208'/><Channel>Microsoft-Windows-Backup</Channel></System><EventData><Data Name='BackupTemplateID'>{4309e1ed-48ed-49a6-8989-7655a5f4c116}</Data><Data Name='HRESULT'>0x0</Data><Data Name='DetailedHRESULT'>0x0</Data><Data Name='BackupState'>14</Data><Data Name='BackupTime'>2026-09-27T15:50:53.5095464Z</Data><Data Name='BackupTarget'>D:</Data></EventData></Event>
'@

        $backupEvent = ConvertFromBackupEventXml -Xml $eventXml

        $backupEvent.Id | Should Be 14
        $backupEvent.RecordId | Should Be 39
        $backupEvent.ProcessId | Should Be 33664
        $backupEvent.ThreadId | Should Be 63208
        $backupEvent.Data.BackupTarget | Should Be 'D:'
    }

    It 'accepts the target job terminal event and ignores a later different template' {
        $events = @(
            (NewBackupEventFixture -Id 1 -RecordId 34 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T10:11:32Z'),
            (NewBackupEventFixture -Id 4 -RecordId 35 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T11:34:49Z' -BackupTime '2026-09-27T10:00:09Z' -BackupTarget 'D:' -HResult '0x0' -DetailedHResult '0x0' -BackupState '14'),
            (NewBackupEventFixture -Id 14 -RecordId 36 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T11:34:49Z' -BackupTime '2026-09-27T10:00:09Z' -BackupTarget 'D:' -HResult '0x0' -DetailedHResult '0x0' -BackupState '14'),
            (NewBackupEventFixture -Id 1 -RecordId 37 -TemplateId $script:otherTemplateId -TimeCreated '2026-09-27T15:57:08Z' -ProcessId 33664 -ThreadId 77660),
            (NewBackupEventFixture -Id 14 -RecordId 39 -TemplateId $script:otherTemplateId -TimeCreated '2026-09-27T16:03:13Z' -BackupTime '2026-09-27T15:50:53Z' -BackupTarget 'D:' -HResult '0x0' -DetailedHResult '0x0' -BackupState '14' -ProcessId 33664 -ThreadId 77660)
        )

        $decision = GetBackupMonitorDecision -Events $events -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 600

        $decision.State | Should Be 'Succeeded'
        $decision.StartEvent.Data.BackupTemplateID | Should Be $script:targetTemplateId
        $decision.TerminalEvent.RecordId | Should Be 35
    }

    It 'does not accept a terminal event at or before the checkpoint' {
        $events = @(
            (NewBackupEventFixture -Id 1 -RecordId 34 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T10:11:32Z'),
            (NewBackupEventFixture -Id 14 -RecordId 33 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T11:34:49Z' -BackupTime '2026-09-27T10:00:09Z' -BackupTarget 'D:' -HResult '0x0' -DetailedHResult '0x0' -BackupState '14')
        )

        $decision = GetBackupMonitorDecision -Events $events -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 600

        $decision.State | Should Be 'WaitingForTerminal'
    }

    It 'does not accept another template terminal event' {
        $events = @(
            (NewBackupEventFixture -Id 1 -RecordId 34 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T10:11:32Z'),
            (NewBackupEventFixture -Id 14 -RecordId 35 -TemplateId $script:otherTemplateId -TimeCreated '2026-09-27T11:34:49Z' -BackupTime '2026-09-27T10:00:09Z' -BackupTarget 'D:' -HResult '0x0' -DetailedHResult '0x0' -BackupState '14' -ThreadId 77660)
        )

        $decision = GetBackupMonitorDecision -Events $events -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 600

        $decision.State | Should Be 'WaitingForTerminal'
    }

    It 'classifies a matching failure event as failed' {
        $events = @(
            (NewBackupEventFixture -Id 1 -RecordId 34 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T10:11:32Z'),
            (NewBackupEventFixture -Id 5 -RecordId 35 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T11:34:49Z' -BackupTime '2026-09-27T10:00:09Z' -BackupTarget 'D:' -HResult '0x80070005' -DetailedHResult '0x80070005' -BackupState '5')
        )

        $decision = GetBackupMonitorDecision -Events $events -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 600

        $decision.State | Should Be 'Failed'
    }

    It 'fails closed when distinct backup starts overlap before a terminal event' {
        $events = @(
            (NewBackupEventFixture -Id 1 -RecordId 34 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T10:11:32Z'),
            (NewBackupEventFixture -Id 1 -RecordId 35 -TemplateId $script:otherTemplateId -TimeCreated '2026-09-27T10:12:00Z' -ThreadId 77660),
            (NewBackupEventFixture -Id 14 -RecordId 36 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T11:34:49Z' -BackupTime '2026-09-27T10:00:09Z' -BackupTarget 'D:' -HResult '0x0' -DetailedHResult '0x0' -BackupState '14')
        )

        $decision = GetBackupMonitorDecision -Events $events -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 600

        $decision.State | Should Be 'Ambiguous'
    }

    It 'times out when no start event appears before the correlation deadline' {
        $decision = GetBackupMonitorDecision -Events @() -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 1200

        $decision.State | Should Be 'StartTimedOut'
    }

    It 'times out when the terminal event never appears' {
        $events = @(
            (NewBackupEventFixture -Id 1 -RecordId 34 -TemplateId $script:targetTemplateId -TimeCreated '2026-09-27T10:11:32Z')
        )

        $decision = GetBackupMonitorDecision -Events $events -RecordIdBaseline 33 -RequestStartedAt $script:requestStartedAt -ElapsedSeconds 10800

        $decision.State | Should Be 'TimedOut'
    }
}
