"""
Cross-language interop tests for Compliance's secure channel.
Locked against scripts/channel-vector.json at the umbrella root.
"""

import base64
import json
import os
import sys

import pytest


VEC_KEY_B64 = "ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8="
VEC_IV_B64 = "CgsMDQ4PEBESExQV"
VEC_PLAINTEXT_B64 = "eyJoZWxsbyI6IndvcmxkIiwidGVuYW50IjoiZGVtbyIsIm4iOjQyfQ=="
VEC_CIPHERTEXT_B64 = "HA/jiyD9Ct203QHgmTq3vFe0VYYm5ynGin9Xn7B3QVGAZkDXaJLrEQ=="
VEC_TAG_B64 = "XjADTXgk4M//4jqs0Cu05g=="


@pytest.fixture
def enabled_channel():
    os.environ["BACKEND_CHANNEL_KEY"] = VEC_KEY_B64
    os.environ["BACKEND_CHANNEL_ENABLED"] = "true"
    sys.modules.pop("channel", None)
    import channel  # noqa: WPS433
    channel.init_from_env()
    yield channel
    os.environ.pop("BACKEND_CHANNEL_KEY", None)
    os.environ.pop("BACKEND_CHANNEL_ENABLED", None)
    sys.modules.pop("channel", None)


def test_vector_decrypts_to_known_plaintext(enabled_channel):
    env = {"v": 1, "iv": VEC_IV_B64, "ct": VEC_CIPHERTEXT_B64, "tag": VEC_TAG_B64}
    plain = enabled_channel.open_envelope(env)
    assert plain == base64.b64decode(VEC_PLAINTEXT_B64)


def test_roundtrip_preserves_payload(enabled_channel):
    payload = b'{"a":1,"b":"x"}'
    env = enabled_channel.seal(payload)
    assert enabled_channel.open_envelope(env) == payload


def test_tampered_ciphertext_fails(enabled_channel):
    raw = bytearray(base64.b64decode(VEC_CIPHERTEXT_B64))
    raw[0] ^= 0x01
    env = {
        "v": 1,
        "iv": VEC_IV_B64,
        "ct": base64.b64encode(bytes(raw)).decode("ascii"),
        "tag": VEC_TAG_B64,
    }
    with pytest.raises(enabled_channel.ChannelError) as exc:
        enabled_channel.open_envelope(env)
    assert "AEAD" in str(exc.value)
