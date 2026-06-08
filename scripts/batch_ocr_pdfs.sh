#!/usr/bin/env bash
# batch_ocr_pdfs.sh
# PDF一括OCRスクリプト（元ファイル上書き方式）
# 使い方:
#   dry-run:   ./batch_ocr_pdfs.sh
#   テスト5件: ./batch_ocr_pdfs.sh --run --limit 5
#   本番全件:  ./batch_ocr_pdfs.sh --run

set -uo pipefail

# ─── 設定 ────────────────────────────────────────────────────────────────────
SRC_DIR="/Volumes/Samsung8TB金/●文献類PDF"
LOG_DIR="/Volumes/Samsung8TB金/●文献類PDF_ocr_logs"
OCR_LANGS="jpn+chi_sim+chi_tra+eng"
OCR_OPTS="--skip-text --deskew --rotate-pages --optimize 1"
TEXT_THRESHOLD=50

# ─── 引数解析 ─────────────────────────────────────────────────────────────────
DRY_RUN=true
LIMIT=0
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --run)   DRY_RUN=false ;;
    --limit) LIMIT="${args[$((i+1))]:-0}"; i=$((i+1)) ;;
  esac
done

# ─── カラー出力 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }
dryrun() { echo -e "${CYAN}[DRY]${NC}   $*"; }

# ─── 依存チェック ─────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  command -v ocrmypdf  >/dev/null 2>&1 || missing+=("ocrmypdf")
  command -v pdftotext >/dev/null 2>&1 || missing+=("pdftotext (poppler)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "以下のツールが見つかりません："
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo "  brew install ocrmypdf poppler"
    exit 1
  fi

  # Tesseract言語データ確認・調整
  local available_langs=()
  for lang in jpn chi_sim chi_tra eng; do
    if tesseract --list-langs 2>/dev/null | grep -q "^${lang}$"; then
      available_langs+=("$lang")
    else
      warn "Tesseract言語データなし: $lang"
    fi
  done
  if [[ ${#available_langs[@]} -eq 0 ]]; then
    error "利用可能なTesseract言語データがありません。brew install tesseract-lang"
    exit 1
  fi
  OCR_LANGS=$(IFS=+; echo "${available_langs[*]}")
  log "使用言語: ${OCR_LANGS}"
}

# ─── テキスト層判定 ───────────────────────────────────────────────────────────
has_enough_text() {
  local char_count
  char_count=$(pdftotext "$1" - 2>/dev/null | wc -c | tr -d ' ')
  [[ "$char_count" -ge "$TEXT_THRESHOLD" ]]
}

# ─── ログ初期化 ───────────────────────────────────────────────────────────────
init_logs() {
  mkdir -p "$LOG_DIR"
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  CSV_LOG="${LOG_DIR}/ocr_log_${TIMESTAMP}.csv"
  ERR_LOG="${LOG_DIR}/ocr_errors_${TIMESTAMP}.log"
  echo "status,path,reason,timestamp" > "$CSV_LOG"
}

write_csv() {
  local status="$1" path="$2" reason="$3"
  local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
  printf '%s,"%s","%s","%s"\n' "$status" "$path" "$reason" "$ts" >> "$CSV_LOG"
}

# ─── メイン処理 ───────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "=========================================="
  echo "  PDF 一括OCRスクリプト（元ファイル上書き）"
  echo "  $(date)"
  echo "=========================================="
  echo ""

  if [[ ! -d "$SRC_DIR" ]]; then
    error "対象フォルダが見つかりません: $SRC_DIR"
    exit 1
  fi
  ok "対象フォルダ: $SRC_DIR"

  log "PDF件数を確認中..."
  local total_count
  total_count=$(find "$SRC_DIR" -type f -iname "*.pdf" | wc -l | tr -d ' ')
  log "PDF件数: ${total_count}件"
  echo ""

  check_deps
  init_logs

  if $DRY_RUN; then
    warn "=== DRY-RUN モード（実際のOCR処理は行いません）==="
  else
    warn "=== 実行モード: 元ファイルを上書きします ==="
  fi
  echo ""

  local count=0 skipped=0 processed=0 failed=0 attempted=0

  while IFS= read -r -d '' src_pdf; do
    if [[ "$LIMIT" -gt 0 && "$attempted" -ge "$LIMIT" ]]; then
      log "--limit ${LIMIT} に達しました。"
      break
    fi

    count=$((count + 1))
    local rel_path="${src_pdf#${SRC_DIR}/}"

    # テキスト層判定
    if has_enough_text "$src_pdf"; then
      skipped=$((skipped + 1))
      if $DRY_RUN; then
        dryrun "[スキップ/テキスト層あり] ${rel_path}"
      fi
      write_csv "SKIP_HAS_TEXT" "$src_pdf" "テキスト層が十分"
      continue
    fi

    # OCR処理
    if $DRY_RUN; then
      dryrun "[OCR予定] ${rel_path}"
      processed=$((processed + 1))
      attempted=$((attempted + 1))
    else
      attempted=$((attempted + 1))
      log "[OCR開始] ${rel_path}"
      local tmp_pdf; tmp_pdf="${src_pdf%.pdf}_ocr_tmp.pdf"

      if ocrmypdf $OCR_OPTS -l "$OCR_LANGS" "$src_pdf" "$tmp_pdf" 2>>"$ERR_LOG"; then
        mv "$tmp_pdf" "$src_pdf"
        ok "[完了] ${rel_path}"
        write_csv "SUCCESS" "$src_pdf" "OCR完了・上書き"
        processed=$((processed + 1))
      else
        rm -f "$tmp_pdf"
        failed=$((failed + 1))
        error "[失敗] ${rel_path}"
        write_csv "FAILED" "$src_pdf" "ocrmypdfエラー"
      fi
    fi

  done < <(find "$SRC_DIR" -type f -iname "*.pdf" ! -name "._*" -print0 | sort -z)

  echo ""
  echo "=========================================="
  echo "  処理完了サマリー"
  echo "  合計PDF:                   ${count}件"
  if $DRY_RUN; then
  echo "  OCR予定:                   ${processed}件"
  echo "  スキップ(テキスト層あり): ${skipped}件"
  else
  echo "  OCR処理済:                 ${processed}件"
  echo "  失敗:                      ${failed}件"
  echo "  スキップ(テキスト層あり): ${skipped}件"
  echo "  ログ: ${CSV_LOG}"
  echo "  エラーログ: ${ERR_LOG}"
  fi
  echo "=========================================="
}

main "$@"
