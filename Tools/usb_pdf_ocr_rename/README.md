# USB PDF OCR & Rename ルーチン

USBメモリに入っているPDF（スキャン画像PDFなど）を自動でOCR処理し、
中身（日付・タイトルらしき文字列）に基づいてリネームしながら指定フォルダへ
書き出すためのルーチン化スクリプトです。

## できること

- 指定したフォルダ（USBの自動マウント先など）を再帰的に走査してPDFを検出
- `ocrmypdf` でOCR（テキストレイヤー付与）を実行
- OCR結果の先頭ページから日付・タイトルらしき文字列を抽出
- `{日付}_{タイトル}.pdf` の形式で書き出し先フォルダにリネーム保存
- 一度処理したファイルはハッシュで記録し、二重処理しない
- `--watch` で常駐させれば、USB挿入のたびに手動実行しなくても定期的に処理

## セットアップ

1. OCR本体（Tesseract）を導入
   - macOS: `brew install tesseract tesseract-lang ghostscript`
   - Debian/Ubuntu: `sudo apt install tesseract-ocr tesseract-ocr-jpn ghostscript`
2. Pythonパッケージを導入
   ```bash
   pip install -r requirements.txt
   ```
3. 設定ファイルを作成
   ```bash
   cp config.example.json config.json
   ```
   `config.json` を編集し、`watch_paths`（USBがマウントされる場所）や
   `dest_dir`（OCR後のPDFを保存する場所）を環境に合わせて変更してください。

## 使い方

一回だけ実行（USBが挿さっている状態で）:

```bash
python3 usb_pdf_ocr_rename.py --config config.json
```

内容を確認するだけ（実際にはOCR・リネームしない）:

```bash
python3 usb_pdf_ocr_rename.py --config config.json --dry-run
```

USBの自動検出を使わず、特定フォルダを対象にする:

```bash
python3 usb_pdf_ocr_rename.py --config config.json --source /path/to/folder
```

常駐して定期的に監視する（`poll_interval_seconds` 間隔でポーリング）:

```bash
python3 usb_pdf_ocr_rename.py --config config.json --watch
```

## ルーチン化（自動実行）

### macOS（launchd）

`com.krworkspace.usbpdfocr.plist.example` を参考に、ログイン時から
バックグラウンドで `--watch` モードを起動させておく設定例を用意しています。

```bash
cp com.krworkspace.usbpdfocr.plist.example ~/Library/LaunchAgents/com.krworkspace.usbpdfocr.plist
# ファイル内のパスを環境に合わせて編集してから
launchctl load ~/Library/LaunchAgents/com.krworkspace.usbpdfocr.plist
```

### Linux/その他（cron）

USBを挿すたびに実行したい場合はudevルール、定期的に確認したい場合はcronが
簡単です。5分おきにチェックする例:

```
*/5 * * * * /usr/bin/python3 /path/to/usb_pdf_ocr_rename.py --config /path/to/config.json >> /tmp/usb_pdf_ocr_rename.log 2>&1
```

## 設定項目 (`config.json`)

| キー | 説明 |
| --- | --- |
| `watch_paths` | USBが自動マウントされる場所の候補（複数可） |
| `volume_name_pattern` | ボリューム名を絞り込む正規表現（`null`で全て対象） |
| `source_subdir` | ボリューム内でPDFを探すサブディレクトリ（`"."` で直下から再帰探索） |
| `dest_dir` | OCR後・リネーム後のPDFを保存する場所 |
| `ocr_language` | OCR言語（tesseract形式。既定は `jpn+eng`） |
| `state_file` | 処理済みファイルの記録先 |
| `poll_interval_seconds` | `--watch` 時のポーリング間隔（秒） |
| `filename_template` | 出力ファイル名テンプレート（`{date}`, `{title}` が使用可） |
| `title_max_length` | タイトル部分の最大文字数 |

## 注意点

- 日付が本文から見つからない場合は、元ファイルの更新日時を代わりに使用します。
- タイトルが抽出できない場合は `untitled` になります。必要に応じて
  `dest_dir` に書き出された後、内容を確認・手動修正してください。
- 元のUSB上のファイルは変更・削除しません（読み取りのみ）。書き出しは
  常に `dest_dir` への新規ファイルとして行われます。
