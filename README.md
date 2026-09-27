# Backup Sleep Suppressor

Windows バックアップの実行中にシステムのスリープを抑止し、バックアップジョブの終了後に解除する PowerShell スクリプトです。

## 必要条件

- Windows 10 または Windows 11
- Windows PowerShell 5.1
- 管理者権限
- Windows バックアップが利用でき、バックアップジョブが設定されていること

## 実行

管理者として起動した Windows PowerShell 5.1 で、スクリプトを実行します。

```powershell
.\BackupSleepSuppressor.ps1
```

引数や対話入力は不要です。

タスク スケジューラから実行する場合は、操作に `powershell.exe` を指定し、引数に `-NoProfile -File "<スクリプトのフルパス>"` を設定します。「最上位の特権で実行する」を有効にしてください。

## 動作とログ

- `sdclt.exe /kickoffjob` でバックアップを開始します。
- `wbadmin get status` で状態を監視し、判定できない場合は `wbengine.exe` の稼働状態を使います。
- ログは `logs/app_yyyyMMdd.log` に出力します。
- 正常終了・エラー終了のどちらでも、終了時にスリープ抑止の解除を試みます。

> [!NOTE]
> ログの「バックアップ完了」は、監視対象の処理が終了したことを示します。バックアップデータの成功や復元可能性を検証するものではありません。
