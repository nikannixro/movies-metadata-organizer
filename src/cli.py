"""Command-line interface and interactive configuration."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from .config import Config
from .prompts.questions import (
    _panel,
    prompt_audio_language,
    prompt_dry_run,
    prompt_english_subtitle_directory,
    prompt_output_directory,
    prompt_persian_subtitle_directory,
    prompt_source_directory,
)
from .services.orchestrator import BatchOrchestrator
from .utils.logger import get_logger, setup_logging
from .utils.validators import ValidationError, validate_ffprobe_available, validate_mkvtoolnix_available

log = get_logger(__name__)

REPO_URL = "https://github.com/nikannixro/kaelix.git"


# --- Version and update check ------------------------------------------------

def get_current_version() -> str | None:
    """Parse version from pyproject.toml."""
    try:
        import tomllib
        pyproject_path = Path(__file__).resolve().parent.parent / "pyproject.toml"
        with open(pyproject_path, "rb") as f:
            data = tomllib.load(f)
        return data["project"]["version"]
    except Exception:
        return None


def check_for_updates() -> str | None:
    """Check GitHub for a newer version. Returns latest tag if different, else None."""
    current = get_current_version()
    if not current:
        return None
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--tags", REPO_URL],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            tags = [
                line.split("refs/tags/")[-1]
                for line in result.stdout.strip().split("\n")
                if "refs/tags/" in line
            ]
            if tags:
                latest = max(tags)
                if latest != current:
                    return latest
    except Exception:
        pass
    return None


# --- Uninstall and upgrade ---------------------------------------------------

def uninstall_kaelix() -> int:
    """Uninstall Kaelix and remove repository."""
    print("Uninstalling Kaelix...")

    # Remove pip package
    subprocess.run(
        [sys.executable, "-m", "pip", "uninstall", "kaelix", "-y"],
        capture_output=True
    )

    # Remove repository if it exists in current directory
    repo_dir = Path.cwd() / "kaelix"
    if repo_dir.exists() and (repo_dir / ".git").exists():
        shutil.rmtree(repo_dir)
        print(f"  Removed {repo_dir}")

    # Remove log directory
    log_dir = Path.home() / ".kaelix"
    if log_dir.exists():
        shutil.rmtree(log_dir)
        print(f"  Removed {log_dir}")

    print("Kaelix uninstalled.")
    return 0


def upgrade_kaelix() -> int:
    """Update Kaelix to the latest version via git pull."""
    print("Updating Kaelix...")

    repo_dir = Path.cwd() / "kaelix"
    if not repo_dir.exists() or not (repo_dir / ".git").exists():
        print("Repository not found. Run the install script first.")
        return 1

    # Git pull
    result = subprocess.run(
        ["git", "-C", str(repo_dir), "pull"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("Failed to pull updates.")
        return 1

    # Reinstall package
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "-e", str(repo_dir)],
        capture_output=True
    )

    print("Kaelix updated successfully.")
    return 0


# --- Argument parser ---------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kaelix",
        description="Batch-edit MKV track metadata, languages, flags, subtitles, and filenames.",
    )
    parser.add_argument(
        "--source", "-s",
        help="Source directory containing .mkv files (interactive if omitted).",
    )
    parser.add_argument(
        "--output", "-o",
        help="Output directory for processed files (created if missing).",
    )
    parser.add_argument(
        "--persian-subs",
        help="Directory containing external Persian/Farsi subtitle files (optional).",
    )
    parser.add_argument(
        "--english-subs",
        help="Directory containing external English subtitle files (optional).",
    )
    parser.add_argument(
        "--audio-lang",
        default="en",
        help="Default audio language code (default: en).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate without writing any changes.",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Do not prompt; rely on CLI flags only.",
    )
    parser.add_argument(
        "--mkvmerge",
        help="Explicit path to mkvmerge binary (default: search PATH).",
    )
    parser.add_argument(
        "--mkvpropedit",
        help="Explicit path to mkvpropedit binary (default: search PATH).",
    )
    parser.add_argument(
        "--ffprobe",
        help="Explicit path to ffprobe binary (default: search PATH).",
    )
    parser.add_argument(
        "--uninstall", "-uninstall",
        action="store_true",
        help="Uninstall Kaelix and remove repository.",
    )
    parser.add_argument(
        "--upgrade", "-upgrade",
        action="store_true",
        help="Update Kaelix to the latest version.",
    )
    return parser


# --- Config helpers ----------------------------------------------------------

def gather_config_interactive() -> Config:
    """Prompt the user for all configuration values."""
    _panel("Kaelix", title="Welcome")
    source_dir = prompt_source_directory()
    output_dir = prompt_output_directory()
    persian_subs = prompt_persian_subtitle_directory()
    english_subs = prompt_english_subtitle_directory()
    audio_lang = prompt_audio_language()
    dry_run = prompt_dry_run()

    config = Config(
        source_dir=source_dir,
        output_dir=output_dir,
        persian_subtitle_dir=persian_subs,
        english_subtitle_dir=english_subs,
        audio_language=audio_lang,
        dry_run=dry_run,
    )
    _panel(config.describe(), title="Configuration summary")
    return config


def gather_config_from_args(args: argparse.Namespace) -> Config:
    """Build a Config purely from CLI arguments (non-interactive)."""
    if not args.source or not args.output:
        raise ValidationError("--source and --output are required in non-interactive mode.")
    return Config(
        source_dir=Path(args.source).expanduser().resolve(),
        output_dir=Path(args.output).expanduser().resolve(),
        persian_subtitle_dir=Path(args.persian_subs).expanduser().resolve() if args.persian_subs else None,
        english_subtitle_dir=Path(args.english_subs).expanduser().resolve() if args.english_subs else None,
        audio_language=args.audio_lang,
        dry_run=args.dry_run,
        non_interactive=True,
    )


# --- Entry point -------------------------------------------------------------

def run(args_list: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(args_list)

    # Handle uninstall
    if args.uninstall:
        return uninstall_kaelix()

    # Handle upgrade
    if args.upgrade:
        return upgrade_kaelix()

    # Check for updates (every run)
    latest = check_for_updates()
    if latest:
        print(f"\n  ⚠ A new version ({latest}) is available.")
        print(f"  Run 'kaelix --upgrade' to update.\n")

    project_root = Path(__file__).resolve().parent.parent
    log_path = setup_logging(project_root / "logs")

    # Resolve binaries first (fail fast before prompting the user).
    try:
        mkvmerge_path, mkvpropedit_path = validate_mkvtoolnix_available(
            args.mkvmerge, args.mkvpropedit
        )
        ffprobe_path = validate_ffprobe_available(args.ffprobe)
    except ValidationError as exc:
        log.error(str(exc))
        return 2

    try:
        if args.non_interactive:
            config = gather_config_from_args(args)
        else:
            config = gather_config_interactive()
    except ValidationError as exc:
        log.error(str(exc))
        return 2

    # Store resolved binary paths for the services to use.
    config.mkvmerge_path = mkvmerge_path
    config.mkvpropedit_path = mkvpropedit_path
    config.ffprobe_path = ffprobe_path

    log.info(f"Logging to: {log_path}")
    log.info(config.describe())

    if not config.dry_run and not args.non_interactive:
        from .prompts.questions import ask_confirm
        if not ask_confirm("Proceed with processing?", default=True):
            log.info("Aborted by user.")
            return 0

    orchestrator = BatchOrchestrator(config)
    try:
        stats = orchestrator.run()
    except KeyboardInterrupt:
        log.warning("Interrupted.")
        return 130

    return 0 if stats["failed"] == 0 else 1
