"""Scrub playback credentials before records reach application/access handlers."""
import logging
import re
from urllib.parse import unquote

_QUERY = re.compile(r"([?&])([^\s=&#\"']+)=([^\s&#\"']+)")
_AUTH = re.compile(r"(?i)(\b(?:Bearer|Basic)\s+)[^\s,\"'}]+")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b")


def redact_sensitive(value: str) -> str:
    value = _QUERY.sub(lambda match: match[1] + match[2] + "=[REDACTED]"
                       if unquote(match[2]).lower() in {"token", "access_token", "sessiontoken"}
                       else match[0], value)
    value = _AUTH.sub(r"\1[REDACTED]", value)
    return _JWT.sub("[REDACTED]", value)


def install_log_redaction() -> None:
    """A record factory also covers Uvicorn handlers installed after app import.

    Preserve positional arguments (Uvicorn's access formatter unpacks them).
    Application exception text is additionally scrubbed in JSONFormatter.
    """
    previous = logging.getLogRecordFactory()
    if getattr(previous, "_peaceplayer_redacts", False):
        return

    def factory(*args, **kwargs):
        record = previous(*args, **kwargs)
        if isinstance(record.msg, str):
            record.msg = redact_sensitive(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(redact_sensitive(v) if isinstance(v, str) else v for v in record.args)
        elif isinstance(record.args, dict):
            record.args = {k: redact_sensitive(v) if isinstance(v, str) else v for k, v in record.args.items()}
        if record.exc_info:
            # Standard formatters reuse exc_text, including Uvicorn's error logger.
            record.exc_text = redact_sensitive(logging.Formatter().formatException(record.exc_info))
        return record

    factory._peaceplayer_redacts = True
    logging.setLogRecordFactory(factory)
