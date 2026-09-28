# Backup Sleep Suppressor

Windows バックアップの実行中にシステムのスリープを抑止し、バックアップジョブの終了後に解除する PowerShell スクリプトです。

## 必要条件

- Windows 10 または Windows 11
- Windows PowerShell 5.1
- 管理者権限
- Windows バックアップが利用でき、バックアップジョブが設定されていること
- `Microsoft-Windows-Backup` イベントログが有効で、管理者から読み取れること

## 実行

管理者として起動した Windows PowerShell 5.1 で、スクリプトを実行します。

```powershell
.\BackupSleepSuppressor.ps1
```

引数や対話入力は不要です。

タスク スケジューラから実行する場合は、操作に `powershell.exe` を指定し、引数に `-NoProfile -File "<スクリプトのフルパス>"` を設定します。「最上位の特権で実行する」を有効にしてください。

## 動作とログ

- `sdclt.exe /kickoffjob` でバックアップを開始します。
- `wbengine.exe` は起動の早期検知にだけ使い、完了判定には使いません。
- `Microsoft-Windows-Backup` の開始イベント ID 1 と終端イベント ID 4/14/5 を照合します。対象ジョブは `BackupTemplateID`、`BackupTime`、バックアップ先、HRESULTで特定します。
- 正常終了は HRESULT と DetailedHRESULT が 0 で BackupState が 14 の場合です。イベント ID 5 または失敗HRESULTはエラーとして扱います。
- 開始イベントは起動後20分、バックアップ全体は3時間を上限に監視します。イベントログを読めない、対象を特定できない、または期限を超えた場合は成功扱いにせず、終了コード1で終了します。
- ログは `logs/app_yyyyMMdd.log` に出力します。
- 正常終了・エラー終了のどちらでも、終了時にスリープ抑止の解除を試みます。

> [!NOTE]
> ログの「バックアップ完了」は、監視対象の処理が終了したことを示します。バックアップデータの成功や復元可能性を検証するものではありません。
