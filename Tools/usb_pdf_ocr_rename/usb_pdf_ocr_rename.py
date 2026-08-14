#!/usr/bin/env python3
"""USBに入っているPDFをOCR処理し、内容に基づいてリネームするルーチンスクリプト。

使い方はこのディレクトリのREADME.mdを参照。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

DEFAULT_CONFIG = {
    # USBが自動マウントされる場所の候補（OSにより異なるので複数指定可）。
    # macOS/Linux: "/Volumes" 等の「複数ボリュームの親フォルダ」を指定。
    # Windows: "P:\\" のようにドライブレターそのものを指定（ボリューム自体として扱われる）。
    "watch_paths": ["/Volumes", "/media", "/mnt"],
    # ボリューム名を絞り込みたい場合の正規表現（Noneなら全ボリュームを対象）
    "volume_name_pattern": None,
    # ボリューム内でPDFを探すサブディレクトリ（"." はボリューム直下から再帰探索）
    "source_subdir": ".",
    # OCR済み・リネーム後のファイルを書き出す先
    "dest_dir": "~/Documents/USB_PDF_OCR",
    # OCRに使う言語（tesseract形式。日本語+英語がデフォルト）
    "ocr_language": "jpn+eng",
    # 処理済みファイルを記録する状態ファイル
    "state_file": "~/.usb_pdf_ocr_rename_state.json",
    # 監視モード時のポーリング間隔（秒）
    "poll_interval_seconds": 30,
    # リネーム後のファイル名テンプレート。{date} と {title} が使える
    "filename_template": "{date}_{title}.pdf",
    # タイトル抽出時の最大文字数
    "title_max_length": 40,
    # 元のファイル名(拡張子除く)がこのパターンに完全一致する場合のみ、
    # OCR内容に基づくリネームを行う。それ以外（既に人間が付けた名前など）は
    # OCR処理だけ行い、ファイル名はそのまま維持する。
    # 既定値はスキャナーが自動生成する日時形式のファイル名
    # （例: 20260814082611）を想定した「数字だけ」のパターン。
    "generic_name_pattern": r"^\d{6,}$",
    # 処理済みファイルのファイル名先頭に付ける目印。
    # dest_dir を元のUSBフォルダと同じ場所にする運用（その場保存）でも、
    # 未処理ファイルと見分けられるようにするためのもの。
    # このマーカーで始まるファイルは次回以降スキャン対象から除外される。
    "processed_marker": "◯",
}

DATE_PATTERNS = [
    re.compile(r"(20\d{2})[年./-](\d{1,2})[月./-](\d{1,2})日?"),
    re.compile(r"(\d{4})[./-](\d{1,2})[./-](\d{1,2})"),
]

INVALID_FILENAME_CHARS = re.compile(r'[\\/:*?"<>|\n\r\t]')

logger = logging.getLogger("usb_pdf_ocr_rename")


@dataclass
class Config:
    watch_paths: list[str] = field(default_factory=lambda: list(DEFAULT_CONFIG["watch_paths"]))
    volume_name_pattern: Optional[str] = None
    source_subdir: str = "."
    dest_dir: str = DEFAULT_CONFIG["dest_dir"]
    ocr_language: str = DEFAULT_CONFIG["ocr_language"]
    state_file: str = DEFAULT_CONFIG["state_file"]
    poll_interval_seconds: int = DEFAULT_CONFIG["poll_interval_seconds"]
    filename_template: str = DEFAULT_CONFIG["filename_template"]
    title_max_length: int = DEFAULT_CONFIG["title_max_length"]
    generic_name_pattern: str = DEFAULT_CONFIG["generic_name_pattern"]
    processed_marker: str = DEFAULT_CONFIG["processed_marker"]

    @classmethod
    def load(cls, path: Optional[Path]) -> "Config":
        data = dict(DEFAULT_CONFIG)
        if path is not None:
            with open(path, encoding="utf-8") as f:
                data.update(json.load(f))
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})


def sha256_of_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_state(state_file: Path) -> dict:
    if state_file.exists():
        with open(state_file, encoding="utf-8") as f:
            return json.load(f)
    return {"processed": {}}


def save_state(state_file: Path, state: dict) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = state_file.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    tmp.replace(state_file)


def discover_source_dirs(cfg: Config, explicit_source: Optional[Path]) -> list[Path]:
    if explicit_source is not None:
        return [explicit_source]

    volume_re = re.compile(cfg.volume_name_pattern) if cfg.volume_name_pattern else None
    dirs: list[Path] = []
    for root in cfg.watch_paths:
        root_path = Path(root).expanduser()
        if not root_path.is_dir():
            continue

        # ドライブレター (Windowsの "P:\\" 等) やファイルシステムのルートは、
        # それ自体が1つのUSBボリュームなので、直接対象に追加する。
        # macOSの "/Volumes" のような「複数ボリュームの親フォルダ」とは
        # root_path.parent == root_path (=自分自身がルート) かどうかで区別する。
        if root_path.parent == root_path:
            if volume_re and not volume_re.search(root_path.name or str(root_path)):
                continue
            source = root_path if cfg.source_subdir in (".", "") else root_path / cfg.source_subdir
            if source.is_dir():
                dirs.append(source)
            continue

        for entry in sorted(root_path.iterdir()):
            if not entry.is_dir():
                continue
            if volume_re and not volume_re.search(entry.name):
                continue
            source = entry if cfg.source_subdir in (".", "") else entry / cfg.source_subdir
            if source.is_dir():
                dirs.append(source)
    return dirs


def find_pdfs(source_dir: Path, processed_marker: str) -> list[Path]:
    return sorted(
        p
        for p in source_dir.rglob("*")
        if p.is_file()
        and p.suffix.lower() == ".pdf"
        # "._foo.pdf" はmacOSが外部ドライブ(exFAT/NTFS等)にコピーした際に
        # 作るAppleDouble形式のリソースフォーク管理ファイルで、実データではない
        and not p.name.startswith("._")
        # 処理済みマーカー付きのファイルは、保存先が元フォルダと同じ場合に
        # 再スキャンで拾われてしまうのを防ぐため対象外にする
        and not (processed_marker and p.name.startswith(processed_marker))
    )


def run_ocr(input_pdf: Path, output_pdf: Path, language: str) -> None:
    if shutil.which("ocrmypdf") is None:
        raise RuntimeError(
            "ocrmypdf が見つかりません。'pip install ocrmypdf' と "
            "OSのtesseract-ocr本体（例: brew install tesseract tesseract-lang / "
            "apt install tesseract-ocr tesseract-ocr-jpn）を導入してください。"
        )
    result = subprocess.run(
        [
            "ocrmypdf",
            "--language", language,
            "--skip-text",
            "--output-type", "pdf",
            str(input_pdf),
            str(output_pdf),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 6):  # 6 = PriorOcrFoundError, treated as already-OCR'd
        raise RuntimeError(f"ocrmypdf failed for {input_pdf}: {result.stderr.strip()}")
    if result.returncode == 6:
        shutil.copyfile(input_pdf, output_pdf)


def extract_text(pdf_path: Path, max_pages: int = 2) -> str:
    try:
        from pypdf import PdfReader
    except ImportError:
        logger.warning("pypdf が未インストールのため、内容からのタイトル抽出をスキップします。")
        return ""
    try:
        reader = PdfReader(str(pdf_path))
        pages = reader.pages[:max_pages]
        return "\n".join(page.extract_text() or "" for page in pages)
    except Exception as exc:  # noqa: BLE001 - OCR結果のPDFは壊れている場合があるため広く捕捉
        logger.warning("テキスト抽出に失敗しました (%s): %s", pdf_path, exc)
        return ""


def extract_date(text: str) -> Optional[str]:
    for pattern in DATE_PATTERNS:
        m = pattern.search(text)
        if m:
            year, month, day = m.groups()
            return f"{int(year):04d}-{int(month):02d}-{int(day):02d}"
    return None


def extract_title(text: str, max_length: int) -> str:
    for line in text.splitlines():
        candidate = line.strip()
        if len(candidate) >= 2:
            candidate = INVALID_FILENAME_CHARS.sub("", candidate)
            return candidate[:max_length]
    return "untitled"


def build_new_filename(cfg: Config, original: Path, text: str) -> str:
    date = extract_date(text) or time.strftime("%Y-%m-%d", time.localtime(original.stat().st_mtime))
    title = extract_title(text, cfg.title_max_length) if text else original.stem
    name = cfg.filename_template.format(date=date, title=title)
    return INVALID_FILENAME_CHARS.sub("_", name)


def unique_destination(dest_dir: Path, filename: str) -> Path:
    candidate = dest_dir / filename
    if not candidate.exists():
        return candidate
    stem, suffix = Path(filename).stem, Path(filename).suffix
    counter = 2
    while True:
        candidate = dest_dir / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


def process_pdf(cfg: Config, pdf_path: Path, dest_dir: Path, dry_run: bool) -> Optional[Path]:
    is_generic_name = bool(re.fullmatch(cfg.generic_name_pattern, pdf_path.stem))
    tmp_ocr_path = pdf_path.with_name(f".ocr_tmp_{pdf_path.name}")
    try:
        if dry_run:
            logger.info("[dry-run] OCR: %s", pdf_path)
            text = extract_text(pdf_path) if is_generic_name else ""
        else:
            run_ocr(pdf_path, tmp_ocr_path, cfg.ocr_language)
            text = extract_text(tmp_ocr_path) if is_generic_name else ""

        if is_generic_name:
            new_filename = build_new_filename(cfg, pdf_path, text)
        else:
            # 既に意味のある名前が付いているファイルは、OCRだけ適用してファイル名は維持する
            new_filename = pdf_path.name
        new_filename = f"{cfg.processed_marker}{new_filename}"
        dest_path = unique_destination(dest_dir, new_filename)

        if dry_run:
            logger.info("[dry-run] %s -> %s", pdf_path, dest_path)
            return dest_path

        dest_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(tmp_ocr_path), str(dest_path))
        logger.info("処理完了: %s -> %s", pdf_path, dest_path)
        return dest_path
    finally:
        if tmp_ocr_path.exists():
            tmp_ocr_path.unlink()


def run_once(cfg: Config, explicit_source: Optional[Path], dry_run: bool) -> int:
    state_file = Path(cfg.state_file).expanduser()
    state = load_state(state_file)
    dest_dir = Path(cfg.dest_dir).expanduser()

    source_dirs = discover_source_dirs(cfg, explicit_source)
    if not source_dirs:
        logger.info("対象となるUSBボリューム/フォルダが見つかりませんでした。")
        return 0

    processed_count = 0
    for source_dir in source_dirs:
        logger.info("スキャン中: %s", source_dir)
        for pdf_path in find_pdfs(source_dir, cfg.processed_marker):
            file_hash = sha256_of_file(pdf_path)
            if file_hash in state["processed"]:
                continue
            try:
                dest_path = process_pdf(cfg, pdf_path, dest_dir, dry_run)
            except Exception as exc:  # noqa: BLE001 - 1ファイルの失敗で全体を止めない
                logger.error("処理失敗: %s (%s)", pdf_path, exc)
                continue

            if not dry_run:
                state["processed"][file_hash] = {
                    "source": str(pdf_path),
                    "dest": str(dest_path),
                    "processed_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                }
                save_state(state_file, state)
            processed_count += 1

    logger.info("完了: %d件処理しました。", processed_count)
    return processed_count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="設定JSONファイルのパス")
    parser.add_argument("--source", type=Path, help="USB自動検出の代わりに使う入力ディレクトリ")
    parser.add_argument("--dest", type=Path, help="config の dest_dir を上書き")
    parser.add_argument("--watch", action="store_true", help="ポーリングしながら常駐監視する")
    parser.add_argument("--dry-run", action="store_true", help="実際のOCR/リネームを行わずログのみ出力")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    cfg = Config.load(args.config)
    if args.dest:
        cfg.dest_dir = str(args.dest)

    if args.watch:
        logger.info("監視モードを開始します（%d秒間隔）。Ctrl+Cで停止。", cfg.poll_interval_seconds)
        try:
            while True:
                run_once(cfg, args.source, args.dry_run)
                time.sleep(cfg.poll_interval_seconds)
        except KeyboardInterrupt:
            logger.info("監視を停止しました。")
    else:
        run_once(cfg, args.source, args.dry_run)


if __name__ == "__main__":
    sys.exit(main() or 0)
