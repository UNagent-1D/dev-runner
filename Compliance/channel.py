"""
Secure-channel primitives for Compliance (FastAPI).

Same AES-256-GCM envelope as every other service in the stack. Wire format:

    { "v": 1, "iv": <b64 12B>, "ct": <b64>, "tag": <b64 16B> }

Detected via Content-Type: application/vnd.unagent.secure+json +
X-Secure-Channel: aes256gcm/1. Header-driven so the FrontEnd-facing routes
(/stats/kpis, /stats/timeseries) keep working as plaintext while the
chat-orch-facing routes (/conversation/chat, /feedback/csat) are encrypted
end to end.
"""

from __future__ import annotations

import base64
import json
import os
from typing import Any, Optional, Tuple

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


HEADER_NAME = "x-secure-channel"
HEADER_VALUE = "aes256gcm/1"
CONTENT_TYPE = "application/vnd.unagent.secure+json"
IV_LEN = 12
TAG_LEN = 16


class ChannelError(Exception):
    """Raised when the channel envelope is malformed or AEAD verification fails."""


_state: dict[str, Any] = {"aesgcm": None, "enabled": False}


def init_from_env() -> None:
    enabled = os.environ.get("BACKEND_CHANNEL_ENABLED", "false").lower() == "true"
    key_b64 = os.environ.get("BACKEND_CHANNEL_KEY", "").strip()
    if not key_b64:
        if enabled:
            raise RuntimeError(
                "BACKEND_CHANNEL_ENABLED=true but BACKEND_CHANNEL_KEY is empty"
            )
        _state["aesgcm"] = None
        _state["enabled"] = False
        return
    decoded = base64.b64decode(key_b64)
    if len(decoded) != 32:
        raise RuntimeError(
            f"BACKEND_CHANNEL_KEY must decode to 32 bytes, got {len(decoded)}"
        )
    _state["aesgcm"] = AESGCM(decoded)
    _state["enabled"] = enabled


def active() -> bool:
    return bool(_state["enabled"] and _state["aesgcm"] is not None)


def seal(plaintext: bytes) -> dict[str, Any]:
    if _state["aesgcm"] is None:
        raise ChannelError("channel not initialised")
    iv = os.urandom(IV_LEN)
    sealed = _state["aesgcm"].encrypt(iv, plaintext, None)
    ct = sealed[:-TAG_LEN]
    tag = sealed[-TAG_LEN:]
    return {
        "v": 1,
        "iv": base64.b64encode(iv).decode("ascii"),
        "ct": base64.b64encode(ct).decode("ascii"),
        "tag": base64.b64encode(tag).decode("ascii"),
    }


def open_envelope(env: dict[str, Any]) -> bytes:
    if _state["aesgcm"] is None:
        raise ChannelError("channel not initialised")
    if env.get("v") != 1:
        raise ChannelError(f"unsupported envelope version {env.get('v')!r}")
    try:
        iv = base64.b64decode(env["iv"])
        ct = base64.b64decode(env["ct"])
        tag = base64.b64decode(env["tag"])
    except (KeyError, ValueError) as e:
        raise ChannelError(f"envelope field invalid base64: {e}") from e
    if len(iv) != IV_LEN:
        raise ChannelError(f"iv must be {IV_LEN} bytes, got {len(iv)}")
    if len(tag) != TAG_LEN:
        raise ChannelError(f"tag must be {TAG_LEN} bytes, got {len(tag)}")
    try:
        return _state["aesgcm"].decrypt(iv, ct + tag, None)
    except Exception as e:
        raise ChannelError(f"AEAD verification failed: {e}") from e


def seal_json(value: Any) -> Tuple[bytes, str, bool]:
    plain = json.dumps(value, separators=(",", ":")).encode("utf-8")
    if not active():
        return plain, "application/json", False
    env = seal(plain)
    return json.dumps(env, separators=(",", ":")).encode("utf-8"), CONTENT_TYPE, True


def open_bytes(content_type: Optional[str], data: bytes) -> bytes:
    if content_type is None or not content_type.startswith(CONTENT_TYPE):
        return data
    env = json.loads(data.decode("utf-8"))
    return open_envelope(env)
