#!/usr/bin/env bash
# batch_ocr_pdfs.sh
# 超星PDG/PDF一括OCRスクリプト（macOS / Apple Silicon対応）
# 使い方:
#   dry-run:   ./batch_ocr_pdfs.sh
#   テスト5件: ./batch_ocr_pdfs.sh --run --limit 5
#   本番全件:  ./batch_ocr_pdfs.sh --run

set -euo pipefail

# ─── 設定 ────────────────────────────────────────────────────────────────────
SRC_DIR="/Volumes/Samsung8TB金/●文献類PDF"
DST_DIR="/Volumes/Samsung8TB金/●文献類PDF_OCR済"
LOG_DIR="${DST_DIR}/_ocr_logs"
OCR_LANGS="jpn+chi_sim+chi_tra+eng"
OCR_OPTS="--skip-text --deskew --rotate-pages --optimize 1"
TEXT_THRESHOLD=50   # テキスト文字数がこれ以上あればOCRスキップ

# ─── 引数解析 ─────────────────────────────────────────────────────────────────
DRY_RUN=true
LIMIT=0

for arg in "$@"; do
  case "$arg" in
    --run)    DRY_RUN=false ;;
    --limit)  shift ;;  # handled below
  esac
done

# --limit N の解析
for i in "$@"; do
  if [[ "$i" == "--limit" ]]; then
    shift
    LIMIT="${1:-0}"
  fi
done

# より堅牢な引数解析
LIMIT=0
i=1
for arg in "$@"; do
  if [[ "$arg" == "--limit" ]]; then
    next_i=$((i + 1))
    eval "LIMIT=\${${next_i}:-0}"
  fi
  i=$((i + 1))
done

# ─── カラー出力 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()      { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()       { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()     { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()    { echo -e "${RED}[ERROR]${NC} $*"; }
dryrun()   { echo -e "${CYAN}[DRY]${NC}   $*"; }

# ─── 依存チェック ─────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  command -v ocrmypdf  >/dev/null 2>&1 || missing+=("ocrmypdf")
  command -v pdftotext >/dev/null 2>&1 || missing+=("pdftotext (poppler)")
  command -v pdfinfo   >/dev/null 2>&1 || missing+=("pdfinfo (poppler)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "以下のツールが見つかりません："
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo ""
    echo "インストールコマンド："
    echo "  brew install ocrmypdf"
    echo "  brew install poppler"
    echo ""
    echo "Tesseract言語データ確認："
    echo "  tesseract --list-langs"
    echo ""
    echo "不足言語があれば："
    echo "  brew install tesseract-lang"
    exit 1
  fi

  # Tesseract言語データ確認
  local missing_langs=()
  for lang in jpn chi_sim chi_tra eng; do
    if ! tesseract --list-langs 2>/dev/null | grep -q "^${lang}$"; then
      missing_langs+=("$lang")
    fi
  done
  if [[ ${#missing_langs[@]} -gt 0 ]]; then
    warn "以下のTesseract言語データが見つかりません："
    for l in "${missing_langs[@]}"; do echo "  - $l"; done
    warn "  brew install tesseract-lang で追加してください"
    warn "  不足言語を除いてOCR_LANGSを調整します"
    # 不足言語を除外
    local available_langs=()
    for lang in jpn chi_sim chi_tra eng; do
      if tesseract --list-langs 2>/dev/null | grep -q "^${lang}$"; then
        available_langs+=("$lang")
      fi
    done
    OCR_LANGS=$(IFS=+; echo "${available_langs[*]}")
    warn "使用言語: ${OCR_LANGS}"
  fi
}

# ─── テキスト層判定 ───────────────────────────────────────────────────────────
has_enough_text() {
  local pdf="$1"
  local char_count
  char_count=$(pdftotext "$pdf" - 2>/dev/null | wc -c | tr -d ' ')
  [[ "$char_count" -ge "$TEXT_THRESHOLD" ]]
}

# ─── ログ初期化 ───────────────────────────────────────────────────────────────
init_logs() {
  mkdir -p "$LOG_DIR"
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  CSV_LOG="${LOG_DIR}/ocr_log_${TIMESTAMP}.csv"
  ERR_LOG="${LOG_DIR}/ocr_errors_${TIMESTAMP}.log"
  echo "status,src_path,dst_path,reason,timestamp" > "$CSV_LOG"
}

write_csv() {
  local status="$1" src="$2" dst="$3" reason="$4"
  local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
  printf '%s,"%s","%s","%s","%s"\n' "$status" "$src" "$dst" "$reason" "$ts" >> "$CSV_LOG"
}

# ─── メイン処理 ───────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "=========================================="
  echo "  PDG/PDF 一括OCRスクリプト"
  echo "  $(date)"
  echo "=========================================="
  echo ""

  # ソースディレクトリ確認
  if [[ ! -d "$SRC_DIR" ]]; then
    error "対象フォルダが見つかりません: $SRC_DIR"
    exit 1
  fi
  ok "対象フォルダ確認: $SRC_DIR"

  # PDF件数と容量
  log "PDF件数と容量を確認中..."
  local total_count total_size
  total_count=$(find "$SRC_DIR" -type f -iname "*.pdf" | wc -l | tr -d ' ')
  total_size=$(find "$SRC_DIR" -type f -iname "*.pdf" -print0 | xargs -0 du -sk 2>/dev/null | awk '{sum+=$1} END {printf "%.1fGB", sum/1024/1024}')
  log "PDF件数: ${total_count}件 / 総容量: ${total_size}"
  echo ""

  # 依存チェック
  check_deps

  # ログ初期化
  init_logs

  if $DRY_RUN; then
    warn "=== DRY-RUN モード（実際のOCR処理は行いません）==="
    echo ""
  else
    log "=== 実行モード（OCR処理を開始します）==="
    mkdir -p "$DST_DIR"
    echo ""
  fi

  local count=0 skipped=0 processed=0 failed=0 already_done=0

  while IFS= read -r -d '' src_pdf; do
    # --limit チェック
    if [[ "$LIMIT" -gt 0 && "$processed" -ge "$LIMIT" ]]; then
      log "--limit ${LIMIT} に達しました。処理を停止します。"
      break
    fi

    # 出力先パスを構築（相対パス保持）
    local rel_path="${src_pdf#${SRC_DIR}/}"
    local dst_pdf="${DST_DIR}/${rel_path}"
    local dst_dir; dst_dir=$(dirname "$dst_pdf")

    count=$((count + 1))

    # 既にOCR済みがあればスキップ
    if [[ -f "$dst_pdf" ]]; then
      already_done=$((already_done + 1))
      if $DRY_RUN; then
        dryrun "[スキップ/既存] ${rel_path}"
      fi
      write_csv "SKIP_EXISTS" "$src_pdf" "$dst_pdf" "出力済みファイルあり"
      continue
    fi

    # テキスト層判定
    if has_enough_text "$src_pdf"; then
      skipped=$((skipped + 1))
      if $DRY_RUN; then
        dryrun "[スキップ/テキスト層あり] ${rel_path}"
      else
        log "[スキップ/テキスト層あり] ${rel_path}"
      fi
      write_csv "SKIP_HAS_TEXT" "$src_pdf" "$dst_pdf" "テキスト層が十分"
      continue
    fi

    # OCR対象
    if $DRY_RUN; then
      dryrun "[OCR予定] ${rel_path}"
      dryrun "  → ${dst_pdf}"
      processed=$((processed + 1))
    else
      log "[OCR開始] ${rel_path}"
      mkdir -p "$dst_dir"

      if ocrmypdf $OCR_OPTS -l "$OCR_LANGS" "$src_pdf" "$dst_pdf" 2>>"$ERR_LOG"; then
        ok "[完了] ${rel_path}"
        write_csv "SUCCESS" "$src_pdf" "$dst_pdf" "OCR完了"
        processed=$((processed + 1))
      else
        failed=$((failed + 1))
        error "[失敗] ${rel_path}"
        write_csv "FAILED" "$src_pdf" "$dst_pdf" "ocrmypdfエラー（${ERR_LOG}参照）"
        # 失敗しても継続
      fi
    fi

  done < <(find "$SRC_DIR" -type f -iname "*.pdf" -print0 | sort -z)

  echo ""
  echo "=========================================="
  echo "  処理完了サマリー"
  echo "  合計PDF:         ${count}件"
  if $DRY_RUN; then
  echo "  OCR予定:         ${processed}件"
  else
  echo "  OCR処理済:       ${processed}件"
  echo "  失敗:            ${failed}件"
  fi
  echo "  スキップ(既存):  ${already_done}件"
  echo "  スキップ(テキスト層あり): ${skipped}件"
  if ! $DRY_RUN; then
  echo "  ログ: ${CSV_LOG}"
  echo "  エラーログ: ${ERR_LOG}"
  fi
  echo "=========================================="
}

main "$@"
