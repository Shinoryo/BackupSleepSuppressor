@{
    CustomRulePath = "CustomRules.psm1"

    IncludeDefaultRules = $true

    IncludeRules = @(
        "PS*" # すべてのPSRuleを含める
        "UseCamelCaseOrUpperSnakeCaseForVariables" # 変数にキャメルケースまたはアッパースネークケースを使用するルール
        "UsePascalCaseForFunctions" # 関数にパスカルケースを使用するルール
        "RequireExplicitParamType" # パラメーターに明示的な型を要求するルール
    )

    ExcludeRules = @(
        "PSAvoidUsingDoubleQuotesForConstantString" # 定数文字列にダブルクォートを使用しないルールを除外
        "PSProvideCommentHelp" # コメントヘルプの提供を強制するルールを除外
        "PSUseOutputTypeCorrectly" # 出力タイプの正しい使用を強制するルールを除外(出力タイプの宣言も強制されるため)
        "PSUseSingularNouns" # 単数名詞のみを使用するルールを除外
    )

    Rules = @{
        # 閉じ括弧の配置ルール
        PSPlaceCloseBrace = @{
            Enable = $true
            NoEmptyLineBefore = $true # 閉じ括弧の前に空行を入れない
            IgnoreOneLineBlock = $true # 1行ブロックの場合は無視する
            NewLineAfter = $false # 閉じ括弧の後に改行を入れなくてもよい
        }

        # 開き括弧の配置ルール
        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $true # 開き括弧をキーワードと同じ行に配置する
            NewLineAfter = $true # 開き括弧の後に改行を入れる
            IgnoreOneLineBlock = $true # 1行ブロックの場合は無視する
        }

        # インデントの一貫性を保つルール
        PSUseConsistentIndentation = @{
            Enable = $true
            IndentationSize = 4 # インデントのサイズを4スペースに設定
            PipelineIndentation = "IncreaseIndentationForFirstPipeline" # パイプラインの最初の行でインデントを増やす
            Kind = "space" # スペースを使用してインデントする
        }

        # 空白の一貫性を保つルール
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckInnerBrace = $true # {の後、}の前にスペースを入れる
            CheckOpenBrace = $true # キーワードと{の間にスペースを入れる
            CheckOpenParen = $true # キーワードと(の間にスペースを入れる
            CheckOperator = $true # 演算子の前後にスペースを入れる
            CheckPipe = $true # パイプの前後にスペースを入れる
            CheckPipeForRedundantWhitespace = $true # パイプの前後に冗長なスペースがないかチェックする
            CheckSeparator = $true # セパレーターの後にスペースを入れる
            CheckParameter = $true # パラメーターと値の間に冗長なスペースがないかチェックする
            IgnoreAssignmentOperatorInsideHashTable = $true # ハッシュテーブル内の代入演算子を無視する
        }

        # 大文字小文字の一貫性を保つルール
        PSUseCorrectCasing = @{
            Enable = $true
            CheckCommands = $true # コマンドの大文字小文字をチェックする
            CheckKeyword = $true # キーワードを全て小文字にする
            CheckOperator = $true # 演算子を全て小文字にする
        }
    }
}
