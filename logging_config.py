"""Shared logging configuration for all project processes."""

import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from concurrent_log_handler import ConcurrentRotatingFileHandler


PROJECT_ROOT = Path(__file__).resolve().parent
LOG_DIR = PROJECT_ROOT / "logs"
LOG_PATH = LOG_DIR / "app.log"
MAX_LOG_BYTES = 5 * 1024 * 1024
BACKUP_COUNT = 3


class UTCFormatter(logging.Formatter):
    """Format log timestamps as ISO-8601 UTC timestamps."""

    converter = time.gmtime

    def formatTime(self, record, datefmt=None):  # noqa: N802 - logging API name
        timestamp = datetime.fromtimestamp(record.created, timezone.utc)
        return timestamp.isoformat(timespec="milliseconds")


def configure_logging(process_name: str) -> logging.Logger:
    """Configure shared file logging and return the process logger.

    The configuration is idempotent so Flask's debug reloader does not add
    duplicate handlers. The file handler is safe for concurrent processes.
    """

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)

    if not any(
        getattr(handler, "_project_file_handler", False)
        for handler in root_logger.handlers
    ):
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        formatter = UTCFormatter(
            "%(asctime)s %(levelname)s %(name)s: %(message)s"
        )

        file_handler = ConcurrentRotatingFileHandler(
            LOG_PATH,
            maxBytes=MAX_LOG_BYTES,
            backupCount=BACKUP_COUNT,
            encoding="utf-8",
        )
        file_handler.setLevel(logging.INFO)
        file_handler.setFormatter(formatter)
        file_handler._project_file_handler = True
        root_logger.addHandler(file_handler)

    if not any(
        getattr(handler, "_project_console_handler", False)
        for handler in root_logger.handlers
    ):
        console_handler = logging.StreamHandler(sys.stderr)
        console_handler.setLevel(logging.ERROR)
        console_handler.setFormatter(
            UTCFormatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
        )
        console_handler._project_console_handler = True
        root_logger.addHandler(console_handler)

    logger = logging.getLogger(process_name)
    logger.setLevel(logging.INFO)

    # Flask/Werkzeug may install their own handlers. Let the shared root
    # handlers own formatting and routing to prevent duplicate output.
    for logger_name in ("flask.app", "werkzeug"):
        framework_logger = logging.getLogger(logger_name)
        framework_logger.handlers.clear()
        framework_logger.propagate = True

    return logger
