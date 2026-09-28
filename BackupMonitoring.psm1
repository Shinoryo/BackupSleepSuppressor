$script:BackupEventLogName = 'Microsoft-Windows-Backup'
$script:BackupEventProviderName = 'Microsoft-Windows-Backup'
$script:BackupEventIds = @(1, 4, 5, 14)

function ConvertFromBackupEventXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Xml
    )

    $eventXml = [System.Xml.XmlDocument]::new()
    $eventXml.XmlResolver = $null
    $eventXml.LoadXml($Xml)

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($eventXml.NameTable)
    $namespaceManager.AddNamespace('event', 'http://schemas.microsoft.com/win/2004/08/events/event')

    $providerNode = $eventXml.SelectSingleNode('/event:Event/event:System/event:Provider', $namespaceManager)
    $eventIdNode = $eventXml.SelectSingleNode('/event:Event/event:System/event:EventID', $namespaceManager)
    $timeCreatedNode = $eventXml.SelectSingleNode('/event:Event/event:System/event:TimeCreated', $namespaceManager)
    $recordIdNode = $eventXml.SelectSingleNode('/event:Event/event:System/event:EventRecordID', $namespaceManager)
    $channelNode = $eventXml.SelectSingleNode('/event:Event/event:System/event:Channel', $namespaceManager)
    $executionNode = $eventXml.SelectSingleNode('/event:Event/event:System/event:Execution', $namespaceManager)

    if ($null -eq $providerNode -or $null -eq $eventIdNode -or $null -eq $timeCreatedNode -or $null -eq $recordIdNode -or $null -eq $channelNode) {
        throw 'Windowsバックアップイベントの必須フィールドを読み取れません。'
    }

    $eventData = @{}
    foreach ($dataNode in $eventXml.SelectNodes('/event:Event/event:EventData/event:Data', $namespaceManager)) {
        $dataName = $dataNode.GetAttribute('Name')
        if (-not [string]::IsNullOrWhiteSpace($dataName)) {
            $eventData[$dataName] = $dataNode.InnerText
        }
    }

    $createdAt = [DateTimeOffset]::Parse(
        $timeCreatedNode.GetAttribute('SystemTime'),
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )

    $processId = $null
    $threadId = $null
    $parsedId = 0
    if ($null -ne $executionNode -and [int]::TryParse($executionNode.GetAttribute('ProcessID'), [ref]$parsedId)) {
        $processId = $parsedId
    }

    $parsedId = 0
    if ($null -ne $executionNode -and [int]::TryParse($executionNode.GetAttribute('ThreadID'), [ref]$parsedId)) {
        $threadId = $parsedId
    }

    return [PSCustomObject]@{
        LogName      = $channelNode.InnerText
        ProviderName = $providerNode.GetAttribute('Name')
        Id           = [int]$eventIdNode.InnerText
        RecordId     = [long]$recordIdNode.InnerText
        TimeCreated  = $createdAt
        ProcessId    = $processId
        ThreadId     = $threadId
        Data         = $eventData
    }
}

function GetBackupEventCheckpoint {
    [CmdletBinding()]
    param()

    $logInformation = Get-WinEvent -ListLog $script:BackupEventLogName -ErrorAction Stop
    if (-not $logInformation.IsEnabled) {
        throw "イベントログ '$($script:BackupEventLogName)' が無効です。"
    }

    if ([long]$logInformation.RecordCount -eq 0) {
        return [long]0
    }

    $latestEvent = Get-WinEvent -LogName $script:BackupEventLogName -MaxEvents 1 -ErrorAction Stop
    if ($null -eq $latestEvent) {
        throw "イベントログ '$($script:BackupEventLogName)' の最新RecordIdを取得できません。"
    }

    return [long]$latestEvent.RecordId
}

function GetBackupEventsAfterRecordId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$RecordId
    )

    $filterHashtable = @{
        LogName = $script:BackupEventLogName
        Id      = $script:BackupEventIds
    }

    try {
        $eventRecords = @(Get-WinEvent -FilterHashtable $filterHashtable -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            return @()
        }

        throw
    }

    $events = @(
        foreach ($eventRecord in $eventRecords) {
            if ([long]$eventRecord.RecordId -gt $RecordId) {
                ConvertFromBackupEventXml -Xml $eventRecord.ToXml()
            }
        }
    )

    return @($events | Sort-Object -Property RecordId)
}

function GetBackupEventDataValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Event.Data -or -not ($Event.Data -is [System.Collections.IDictionary])) {
        return $null
    }

    foreach ($dataName in $Event.Data.Keys) {
        if ([string]$dataName -ieq $Name) {
            return [string]$Event.Data[$dataName]
        }
    }

    return $null
}

function ConvertToBackupEventTime {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsedTime = [DateTimeOffset]::MinValue
    $dateTimeStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $dateTimeStyles, [ref]$parsedTime)) {
        return $null
    }

    if ($parsedTime.Year -le 1601) {
        return $null
    }

    return $parsedTime
}

function ConvertToBackupHResult {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalizedValue = $Value.Trim()
    if ($normalizedValue.StartsWith('0x', [System.StringComparison]::OrdinalIgnoreCase)) {
        $parsedHexValue = [uint32]0
        if ([uint32]::TryParse(
                $normalizedValue.Substring(2),
                [System.Globalization.NumberStyles]::HexNumber,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsedHexValue
            )) {
            return [long]$parsedHexValue
        }

        return $null
    }

    $parsedDecimalValue = [long]0
    if ([long]::TryParse($normalizedValue, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedDecimalValue)) {
        return $parsedDecimalValue
    }

    return $null
}

function GetBackupSessionKey {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event
    )

    $templateId = GetBackupEventDataValue -Event $Event -Name 'BackupTemplateID'
    $processId = if ($null -eq $Event.ProcessId) { 'unknown-process' } else { [string]$Event.ProcessId }
    $threadId = if ($null -eq $Event.ThreadId) { 'unknown-thread' } else { [string]$Event.ThreadId }
    if ($processId -eq 'unknown-process' -and $threadId -eq 'unknown-thread') {
        return '{0}|record-{1}' -f $templateId, $Event.RecordId
    }

    return '{0}|{1}|{2}' -f $templateId, $processId, $threadId
}

function TestBackupEventMatchesStart {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StartEvent,

        [Parameter(Mandatory = $true)]
        [object]$TerminalEvent,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$RequestStartedAt,

        [Parameter(Mandatory = $true)]
        [int]$StartEventTimeoutSeconds
    )

    $startTemplateId = GetBackupEventDataValue -Event $StartEvent -Name 'BackupTemplateID'
    $terminalTemplateId = GetBackupEventDataValue -Event $TerminalEvent -Name 'BackupTemplateID'
    if ([string]::IsNullOrWhiteSpace($startTemplateId) -or $startTemplateId -ine $terminalTemplateId) {
        return $false
    }

    if ([long]$TerminalEvent.RecordId -le [long]$StartEvent.RecordId -or $TerminalEvent.TimeCreated -lt $StartEvent.TimeCreated) {
        return $false
    }

    if ($null -ne $StartEvent.ProcessId -and $null -ne $TerminalEvent.ProcessId -and [int]$StartEvent.ProcessId -ne [int]$TerminalEvent.ProcessId) {
        return $false
    }

    if ($null -ne $StartEvent.ThreadId -and $null -ne $TerminalEvent.ThreadId -and [int]$StartEvent.ThreadId -ne [int]$TerminalEvent.ThreadId) {
        return $false
    }

    $backupTime = ConvertToBackupEventTime -Value (GetBackupEventDataValue -Event $TerminalEvent -Name 'BackupTime')
    if ($null -ne $backupTime) {
        if ($backupTime -lt $RequestStartedAt.AddMinutes(-1) -or $backupTime -gt $RequestStartedAt.AddSeconds($StartEventTimeoutSeconds)) {
            return $false
        }

        return $true
    }

    if ([int]$TerminalEvent.Id -eq 5 -and $null -ne $StartEvent.ProcessId -and $null -ne $TerminalEvent.ProcessId -and $null -ne $StartEvent.ThreadId -and $null -ne $TerminalEvent.ThreadId) {
        return $true
    }

    return $false
}

function GetBackupTerminalOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event
    )

    if ([int]$Event.Id -eq 5) {
        return 'Failed'
    }

    $hresult = ConvertToBackupHResult -Value (GetBackupEventDataValue -Event $Event -Name 'HRESULT')
    $detailedHResult = ConvertToBackupHResult -Value (GetBackupEventDataValue -Event $Event -Name 'DetailedHRESULT')
    if (($null -ne $hresult -and $hresult -ne 0) -or ($null -ne $detailedHResult -and $detailedHResult -ne 0)) {
        return 'Failed'
    }

    $backupState = 0
    $backupStateText = GetBackupEventDataValue -Event $Event -Name 'BackupState'
    if ($null -eq $hresult -or $null -eq $detailedHResult -or -not [int]::TryParse($backupStateText, [ref]$backupState)) {
        return 'Incomplete'
    }

    if ($backupState -ne 14) {
        return 'Failed'
    }

    $backupTarget = GetBackupEventDataValue -Event $Event -Name 'BackupTarget'
    $backupTime = ConvertToBackupEventTime -Value (GetBackupEventDataValue -Event $Event -Name 'BackupTime')
    if ($hresult -eq 0 -and $detailedHResult -eq 0 -and -not [string]::IsNullOrWhiteSpace($backupTarget) -and $null -ne $backupTime) {
        return 'Succeeded'
    }

    return 'Incomplete'
}

function NewBackupMonitorDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [AllowNull()]
        [object]$StartEvent,

        [Parameter()]
        [AllowNull()]
        [object]$TerminalEvent
    )

    return [PSCustomObject]@{
        State         = $State
        Message       = $Message
        StartEvent    = $StartEvent
        TerminalEvent = $TerminalEvent
    }
}

function GetBackupMonitorDecision {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Events = @(),

        [Parameter(Mandatory = $true)]
        [long]$RecordIdBaseline,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$RequestStartedAt,

        [Parameter(Mandatory = $true)]
        [double]$ElapsedSeconds,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$StartEventTimeoutSeconds = 1200,

        [Parameter()]
        [ValidateRange(1, 604800)]
        [int]$OverallTimeoutSeconds = 10800
    )

    $eventsAfterBaseline = @(
        $Events |
            Where-Object {
                $_.LogName -eq $script:BackupEventLogName -and
                $_.ProviderName -eq $script:BackupEventProviderName -and
                [long]$_.RecordId -gt $RecordIdBaseline
            } |
            Sort-Object -Property RecordId
    )

    $startDeadline = $RequestStartedAt.AddSeconds($StartEventTimeoutSeconds)
    $overallDeadline = $RequestStartedAt.AddSeconds($OverallTimeoutSeconds)
    $startEvents = @(
        $eventsAfterBaseline |
            Where-Object {
                [int]$_.Id -eq 1 -and
                -not [string]::IsNullOrWhiteSpace((GetBackupEventDataValue -Event $_ -Name 'BackupTemplateID')) -and
                $_.TimeCreated -ge $RequestStartedAt.AddMinutes(-1) -and
                $_.TimeCreated -le $startDeadline
            }
    )

    if ($startEvents.Count -eq 0) {
        if ($ElapsedSeconds -ge $OverallTimeoutSeconds) {
            return NewBackupMonitorDecision -State 'TimedOut' -Message 'バックアップ監視の全体期限を超過しました。' -StartEvent $null -TerminalEvent $null
        }

        if ($ElapsedSeconds -ge $StartEventTimeoutSeconds) {
            return NewBackupMonitorDecision -State 'StartTimedOut' -Message '新しいバックアップ開始イベントを期限内に確認できませんでした。' -StartEvent $null -TerminalEvent $null
        }

        return NewBackupMonitorDecision -State 'WaitingForStart' -Message '今回のバックアップ開始イベントを待機しています。' -StartEvent $null -TerminalEvent $null
    }

    $terminalOutcomes = @(
        foreach ($startEvent in $startEvents) {
            foreach ($terminalEvent in $eventsAfterBaseline) {
                if ([int]$terminalEvent.Id -notin @(4, 5, 14) -or $terminalEvent.TimeCreated -gt $overallDeadline) {
                    continue
                }

                if (-not (TestBackupEventMatchesStart -StartEvent $startEvent -TerminalEvent $terminalEvent -RequestStartedAt $RequestStartedAt -StartEventTimeoutSeconds $StartEventTimeoutSeconds)) {
                    continue
                }

                $terminalOutcome = GetBackupTerminalOutcome -Event $terminalEvent
                if ($terminalOutcome -ne 'Incomplete') {
                    [PSCustomObject]@{
                        SessionKey    = GetBackupSessionKey -Event $startEvent
                        StartEvent    = $startEvent
                        TerminalEvent = $terminalEvent
                        Outcome       = $terminalOutcome
                    }
                }
            }
        }
    )

    if ($terminalOutcomes.Count -gt 0) {
        $firstOutcome = $terminalOutcomes | Sort-Object -Property { $_.TerminalEvent.RecordId } | Select-Object -First 1
        $outcomesForRecord = @($terminalOutcomes | Where-Object { [long]$_.TerminalEvent.RecordId -eq [long]$firstOutcome.TerminalEvent.RecordId })
        $matchingSessionKeys = @($outcomesForRecord | ForEach-Object { $_.SessionKey } | Select-Object -Unique)
        if ($matchingSessionKeys.Count -gt 1) {
            return NewBackupMonitorDecision -State 'Ambiguous' -Message '終端イベントを一意のバックアップ開始イベントに対応付けられません。' -StartEvent $null -TerminalEvent $firstOutcome.TerminalEvent
        }

        $interleavedStarts = @(
            $startEvents |
                Where-Object {
                    [long]$_.RecordId -gt [long]$firstOutcome.StartEvent.RecordId -and
                    [long]$_.RecordId -lt [long]$firstOutcome.TerminalEvent.RecordId -and
                    (GetBackupSessionKey -Event $_) -ne $firstOutcome.SessionKey
                }
        )
        if ($interleavedStarts.Count -gt 0) {
            return NewBackupMonitorDecision -State 'Ambiguous' -Message '対象ジョブの監視中に別のバックアップ開始イベントがあり、結果を特定できません。' -StartEvent $firstOutcome.StartEvent -TerminalEvent $firstOutcome.TerminalEvent
        }

        if ($firstOutcome.Outcome -eq 'Succeeded') {
            return NewBackupMonitorDecision -State 'Succeeded' -Message '対象バックアップの正常終了を確認しました。' -StartEvent $firstOutcome.StartEvent -TerminalEvent $firstOutcome.TerminalEvent
        }

        return NewBackupMonitorDecision -State 'Failed' -Message '対象バックアップの失敗イベントまたは失敗HRESULTを確認しました。' -StartEvent $firstOutcome.StartEvent -TerminalEvent $firstOutcome.TerminalEvent
    }

    $startSessionKeys = @($startEvents | ForEach-Object { GetBackupSessionKey -Event $_ } | Select-Object -Unique)
    if ($startSessionKeys.Count -gt 1) {
        return NewBackupMonitorDecision -State 'Ambiguous' -Message '新しいバックアップ開始イベントが複数あり、対象ジョブを特定できません。' -StartEvent $null -TerminalEvent $null
    }

    if ($ElapsedSeconds -ge $OverallTimeoutSeconds) {
        return NewBackupMonitorDecision -State 'TimedOut' -Message 'バックアップ監視の全体期限を超過しました。' -StartEvent $startEvents[0] -TerminalEvent $null
    }

    return NewBackupMonitorDecision -State 'WaitingForTerminal' -Message '対象バックアップの終了イベントを待機しています。' -StartEvent $startEvents[0] -TerminalEvent $null
}

Export-ModuleMember -Function ConvertFromBackupEventXml, GetBackupEventCheckpoint, GetBackupEventsAfterRecordId, GetBackupMonitorDecision
