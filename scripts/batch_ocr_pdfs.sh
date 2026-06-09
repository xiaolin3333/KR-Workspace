#!/usr/bin/env bash
# batch_ocr_pdfs.sh
# 外付けSSD内PDFを一括OCR処理するスクリプト
# 元ファイルは絶対に上書きしない / dry-runデフォルト / --run で実行

set -uo pipefail

# ===== 設定 =====
SRC_DIR="/Volumes/Samsung8TB金/●文献類PDF"
DST_DIR="/Volumes/Samsung8TB金/●文献類PDF_OCR済"
LOG_DIR="${DST_DIR}/_ocr_logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CSV_LOG="${LOG_DIR}/ocr_log_${TIMESTAMP}.csv"
ERR_LOG="${LOG_DIR}/ocr_errors_${TIMESTAMP}.log"
OCR_LANGS="jpn+chi_sim+chi_tra+eng"
TEXT_THRESHOLD=100   # この文字数以上あればOCR済みとみなす
DRY_RUN=true
LIMIT=0              # 0 = 無制限

# ===== カラー出力 =====
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLU}[INFO]${NC}  $*"; }
warn() { echo -e "${YEL}[WARN]${NC}  $*"; }
ok()   { echo -e "${GRN}[OK]${NC}    $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ===== 引数パース =====
usage() {
  cat <<EOF
使用方法:
  $0 [オプション]

オプション:
  --run          OCRを実際に実行する（デフォルトはdry-run）
  --limit N      最大N件だけ処理する（テスト用）
  --langs LANGS  OCR言語指定（デフォルト: ${OCR_LANGS}）
  --help         このヘルプを表示

例:
  $0                    # dry-run（処理予定を表示するだけ）
  $0 --run --limit 5    # 最大5件だけ実際にOCR実行
  $0 --run              # 全件OCR実行
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)    DRY_RUN=false ;;
    --limit)  LIMIT="${2:-0}"; shift ;;
    --langs)  OCR_LANGS="${2:-$OCR_LANGS}"; shift ;;
    --help)   usage ;;
    *)        err "不明なオプション: $1"; usage ;;
  esac
  shift
done

# ===== 前提チェック =====
check_prerequisites() {
  log "前提条件を確認中..."

  # ソースディレクトリ確認
  if [[ ! -d "$SRC_DIR" ]]; then
    err "ソースディレクトリが見つかりません: ${SRC_DIR}"
    err "外付けSSDがマウントされているか確認してください。"
    exit 1
  fi
  ok "ソースディレクトリ確認: ${SRC_DIR}"

  # ocrmypdf 確認
  if ! command -v ocrmypdf &>/dev/null; then
    err "ocrmypdf が見つかりません。"
    echo ""
    echo "  インストール方法:"
    echo "    brew install ocrmypdf"
    echo "    brew install tesseract-lang  # 多言語データ"
    exit 1
  fi
  ok "ocrmypdf: $(ocrmypdf --version 2>&1 | head -1)"

  # pdftotext または pdfinfo 確認
  if command -v pdftotext &>/dev/null; then
    TEXT_TOOL="pdftotext"
    ok "テキスト判定ツール: pdftotext"
  elif command -v pdfinfo &>/dev/null; then
    TEXT_TOOL="pdfinfo"
    warn "pdftotext が見つかりません。pdfinfo でフォールバックします。"
    warn "  brew install poppler  でより正確な判定が可能です。"
  else
    TEXT_TOOL="none"
    warn "pdftotext/pdfinfo が見つかりません。全PDFをOCR対象とします。"
    warn "  brew install poppler  を推奨します。"
  fi

  # Tesseract言語データ確認
  check_tesseract_langs
}

check_tesseract_langs() {
  if ! command -v tesseract &>/dev/null; then
    warn "tesseract コマンドが見つかりません。"
    return
  fi

  local available
  available=$(tesseract --list-langs 2>/dev/null | tail -n +2 | tr '\n' ' ')
  local missing=()

  IFS='+' read -ra required_langs <<< "$OCR_LANGS"
  for lang in "${required_langs[@]}"; do
    if ! echo "$available" | grep -qw "$lang"; then
      missing+=("$lang")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "不足しているTesseract言語データ: ${missing[*]}"
    warn "  インストール: brew install tesseract-lang"
    warn "  または個別: https://github.com/tesseract-ocr/tessdata"
    # 不足言語を除外して続行
    local filtered_langs="$OCR_LANGS"
    for lang in "${missing[@]}"; do
      filtered_langs=$(echo "$filtered_langs" | sed "s/+${lang}//g; s/${lang}+//g; s/${lang}//g")
    done
    filtered_langs=$(echo "$filtered_langs" | sed 's/^+//; s/+$//')
    warn "  利用可能な言語のみで処理します: ${filtered_langs}"
    OCR_LANGS="$filtered_langs"
  else
    ok "Tesseract言語データ確認: ${OCR_LANGS}"
  fi
}

# ===== テキスト層の判定 =====
has_sufficient_text() {
  local pdf="$1"
  case "$TEXT_TOOL" in
    pdftotext)
      local char_count
      char_count=$(pdftotext -q "$pdf" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
      [[ "$char_count" -ge "$TEXT_THRESHOLD" ]]
      ;;
    pdfinfo)
      # pdfinfo ではテキスト量は分からないため、ページ数のみ確認
      pdfinfo "$pdf" &>/dev/null
      return 1  # 常にOCR対象とする（保守的）
      ;;
    none)
      return 1  # 常にOCR対象
      ;;
  esac
}

# ===== メイン処理 =====
main() {
  check_prerequisites

  echo ""
  echo "========================================="
  echo "  PDF一括OCR処理スクリプト"
  echo "========================================="
  echo "  ソース    : ${SRC_DIR}"
  echo "  出力先    : ${DST_DIR}"
  echo "  OCR言語   : ${OCR_LANGS}"
  echo "  テキスト閾値: ${TEXT_THRESHOLD}文字"
  echo "  モード    : $(${DRY_RUN} && echo 'DRY-RUN（実行なし）' || echo '実行モード')"
  [[ "$LIMIT" -gt 0 ]] && echo "  上限件数  : ${LIMIT}件"
  echo "========================================="
  echo ""

  # PDF件数・容量調査
  log "PDFを検索中..."
  local total_count total_size
  total_count=$(find "$SRC_DIR" -type f -iname "*.pdf" 2>/dev/null | wc -l | tr -d ' ') || total_count=0
  total_size=$(du -sh "$SRC_DIR" 2>/dev/null | awk '{print $1}') || total_size="不明"
  log "発見したPDF: ${total_count}件 / ソースフォルダ合計サイズ: ${total_size}"
  echo ""

  # ログディレクトリ作成（dry-runでも作成して一覧表示）
  mkdir -p "$LOG_DIR"

  # CSVヘッダ
  if ! $DRY_RUN; then
    echo "timestamp,file,status,reason,output_path,duration_sec" > "$CSV_LOG"
  fi

  # カウンタ
  local count_skip_text=0
  local count_skip_exists=0
  local count_ocr=0
  local count_err=0
  local count_processed=0

  # PDF一覧を処理
  while IFS= read -r -d '' pdf; do
    # リミットチェック
    if [[ "$LIMIT" -gt 0 && "$count_processed" -ge "$LIMIT" ]]; then
      warn "上限件数 ${LIMIT}件 に達しました。処理を停止します。"
      break
    fi

    # 相対パス計算
    local rel_path="${pdf#${SRC_DIR}/}"
    local dst_path="${DST_DIR}/${rel_path}"
    local dst_dir
    dst_dir=$(dirname "$dst_path")

    echo "---"
    log "対象: ${rel_path}"

    # 1. 出力先に既に存在するならスキップ
    if [[ -f "$dst_path" ]]; then
      ok "スキップ（出力済）: ${dst_path}"
      ((count_skip_exists++)) || true
      if ! $DRY_RUN; then
        echo "$(date +%T),\"${rel_path}\",SKIP,already_exists,\"${dst_path}\",-" >> "$CSV_LOG"
      fi
      continue
    fi

    # 2. テキスト層チェック
    if has_sufficient_text "$pdf"; then
      ok "スキップ（テキスト層あり / ${TEXT_THRESHOLD}文字以上）"
      ((count_skip_text++)) || true
      if ! $DRY_RUN; then
        echo "$(date +%T),\"${rel_path}\",SKIP,has_text,\"${dst_path}\",-" >> "$CSV_LOG"
      fi
      continue
    fi

    # 3. OCR対象
    log "OCR予定 → ${dst_path}"
    ((count_ocr++)) || true
    ((count_processed++)) || true

    if $DRY_RUN; then
      echo "  [DRY-RUN] ocrmypdf --skip-text --deskew --rotate-pages --optimize 1 -l ${OCR_LANGS} \"${pdf}\" \"${dst_path}\""
      continue
    fi

    # 実行モード: ディレクトリ作成 & OCR実行
    mkdir -p "$dst_dir"
    local start_time end_time duration
    start_time=$(date +%s)

    if ocrmypdf \
        --skip-text \
        --deskew \
        --rotate-pages \
        --optimize 1 \
        -l "$OCR_LANGS" \
        "$pdf" \
        "$dst_path" \
        2>>"$ERR_LOG"; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      ok "完了 (${duration}秒): ${rel_path}"
      echo "$(date +%T),\"${rel_path}\",SUCCESS,,\"${dst_path}\",${duration}" >> "$CSV_LOG"
    else
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      err "失敗: ${rel_path}"
      echo "$(date +%T),\"${rel_path}\",ERROR,ocrmypdf_failed,\"${dst_path}\",${duration}" >> "$CSV_LOG"
      echo "[$(date +%T)] ERROR: ${rel_path}" >> "$ERR_LOG"
      ((count_err++)) || true
      # 失敗しても続行
    fi

  done < <(find "$SRC_DIR" -type f -iname "*.pdf" -print0 | sort -z)

  # ===== サマリー =====
  echo ""
  echo "========================================="
  echo "  処理サマリー"
  echo "========================================="
  echo "  スキップ（テキスト層あり） : ${count_skip_text}件"
  echo "  スキップ（出力済）         : ${count_skip_exists}件"
  echo "  OCR対象                   : ${count_ocr}件"
  if ! $DRY_RUN; then
    echo "  エラー                    : ${count_err}件"
    echo "  CSVログ: ${CSV_LOG}"
    echo "  エラーログ: ${ERR_LOG}"
  fi
  echo "========================================="

  if $DRY_RUN; then
    echo ""
    warn "これはDRY-RUNです。実際のOCR処理は行われていません。"
    warn "実行するには: $0 --run"
    warn "テスト実行:   $0 --run --limit 5"
  fi
}

main "$@"
