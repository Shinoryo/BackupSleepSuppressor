# カスタムルールの定義

# 自動変数一覧
$automaticVariables = [System.Collections.Generic.HashSet[string]]@(
    "$",
    "?",
    "^",
    "_",
    "args",
    "ConsoleFileName",
    "EnabledExperimentalFeatures",
    "Error",
    "Event",
    "EventArgs",
    "EventSubscriber",
    "ExecutionContext",
    "false",
    "foreach",
    "HOME",
    "Host",
    "input",
    "IsCoreCLR",
    "IsLinux",
    "IsMacOS",
    "IsWindows",
    "LASTEXITCODE",
    "Matches",
    "MyInvocation",
    "NestedPromptLevel",
    "null",
    "PID",
    "PROFILE",
    "PSBoundParameters",
    "PSCmdlet",
    "PSCommandPath",
    "PSCulture",
    "PSDebugContext",
    "PSEdition",
    "PSHOME",
    "PSItem",
    "PSScriptRoot",
    "PSSenderInfo",
    "PSUICulture",
    "PSVersionTable",
    "PWD",
    "Sender",
    "ShellId",
    "StackTrace",
    "switch",
    "this",
    "true"
)

# キャメルケースパターン
$camelCaseRegex = [regex]::new('^(?-i)[a-z][a-zA-Z0-9]*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# パスカルケースパターン
$pascalCaseRegex = [regex]::new('^(?-i)[A-Z][a-zA-Z0-9]*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# アッパースネークケースパターン
$upperSnakeCaseRegex = [regex]::new('^(?-i)[A-Z][A-Z0-9_]*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# 変数にキャメルケースまたはアッパースネークケースを使用するルール
function UseCamelCaseOrUpperSnakeCaseForVariables([System.Management.Automation.Language.ScriptBlockAst] $scriptBlockAst) {
    [CmdletBinding()]

    # 変数を検出するためのラムダ式
    $isVariableExpression = {
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst]
    }

    $diagnostics = New-Object System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]

    foreach ($variableNode in $scriptBlockAst.FindAll($isVariableExpression, $true)) {
        $variableName = $variableNode.VariablePath.UserPath -replace '^[a-z]+:', "" # スコープ修飾子を取り除く

        # 自動変数ならスキップ
        if ($script:automaticVariables.Contains($variableName)) {
            continue
        }

        # camelCase に従っている場合は何もしない
        if ($script:camelCaseRegex.IsMatch($variableName)) {
            continue
        }

        # UPPER_SNAKE_CASE に従っている場合は何もしない
        if ($script:upperSnakeCaseRegex.IsMatch($variableName)) {
            continue
        }

        $diagnostic = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
            Message = "変数 ""$variableName"" は camelCase または UPPER_SNAKE_CASE に従っていません。"
            Extent = $variableNode.Extent
            RuleName = "UseCamelCaseOrUpperSnakeCaseForVariables"
            Severity = 1 # Warning の整数値
        }

        $diagnostics.Add($diagnostic) | Out-Null
    }

    return $diagnostics
}

# 関数にパスカルケースを使用するルール
function UsePascalCaseForFunctions([System.Management.Automation.Language.ScriptBlockAst] $scriptBlockAst) {
    [CmdletBinding()]

    # 関数を検出するためのラムダ式
    $isFunctionExpression = {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }

    $diagnostics = New-Object System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]

    foreach ($functionNode in $scriptBlockAst.FindAll($isFunctionExpression, $true)) {
        $functionName = $functionNode.Name

        if ($pascalCaseRegex.IsMatch($functionName)) {
            # PascalCase に従っている場合は何もしない
            continue
        }

        $diagnostic = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
            Message = "関数 ""$functionName"" は PascalCase に従っていません。"
            Extent = $functionNode.Extent
            RuleName = "UsePascalCaseForFunctions"
            Severity = 1 # Warning の整数値
        }
        $diagnostics.Add($diagnostic) | Out-Null
    }

    return $diagnostics
}

# パラメーターに明示的な型を要求するルール
function RequireExplicitParamType([System.Management.Automation.Language.ScriptBlockAst] $scriptBlockAst) {
    [CmdletBinding()]

    # 関数を検出するためのラムダ式
    $isFunctionExpression = {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }

    # パラメーターに型が指定されているかどうかを確認するためのラムダ式
    $hasTypeConstraint = {
        param($param)
        $typeConstraints = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] }
        return $typeConstraints.Count -gt 0
    }

    $diagnostics = New-Object System.Collections.Generic.List[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]

    foreach ($functionNode in $scriptBlockAst.FindAll($isFunctionExpression, $true)) {
        foreach ($param in $functionNode.Parameters) {
            if ($hasTypeConstraint.Invoke($param)) {
                # パラメーターに型が指定されている場合は何もしない
                continue
            }

            $diagnostic = [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
                Message = "関数 ""$($functionNode.Name)"" 内のパラメーター ""$($param.Name.VariablePath.UserPath)"" に型が指定されていません。"
                Extent = $param.Extent
                RuleName = "RequireExplicitParamType"
                Severity = 1 # Warning の整数値
            }
            $diagnostics.Add($diagnostic) | Out-Null
        }
    }

    return $diagnostics
}

Export-ModuleMember -Function UseCamelCaseForVariables, UsePascalCaseForFunctions, RequireExplicitParamType
