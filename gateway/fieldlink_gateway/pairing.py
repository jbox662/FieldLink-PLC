from __future__ import annotations

import hashlib
import secrets
import threading
import time
from dataclasses import dataclass


@dataclass
class Session:
    token: str
    created_at: float
    expires_at: float


class PairingState:
    def __init__(self, pairing_code: str, window_seconds: float = 15 * 60, session_seconds: float = 12 * 60 * 60):
        self._lock = threading.Lock()
        self._pairing_code = pairing_code
        self._window_seconds = window_seconds
        self._session_seconds = session_seconds
        self._window_until = time.time() + window_seconds
        self._session: Session | None = None

    def open_window(self) -> float:
        with self._lock:
            self._window_until = time.time() + self._window_seconds
            return self._window_until

    def window_open(self) -> bool:
        with self._lock:
            return time.time() <= self._window_until

    def set_pairing_code(self, pairing_code: str) -> None:
        with self._lock:
            self._pairing_code = pairing_code

    def pair(self, pairing_code: str, certificate_pin_base64: str) -> str:
        with self._lock:
            if time.time() > self._window_until:
                raise PermissionError("The pairing window is closed. Open pairing on the gateway and try again.")
            if not pairing_code or pairing_code.strip() != self._pairing_code:
                raise PermissionError("The pairing code is incorrect.")
            token = secrets.token_urlsafe(32)
            now = time.time()
            self._session = Session(token=token, created_at=now, expires_at=now + self._session_seconds)
            self._window_until = now
            return token

    def authenticate(self, authorization: str | None) -> None:
        with self._lock:
            if self._session is None:
                raise PermissionError("Pair a FieldLink Gateway before running this operation.")
            if time.time() > self._session.expires_at:
                self._session = None
                raise PermissionError("The paired gateway session has expired. Pair the gateway again.")
            expected = f"Bearer {self._session.token}"
            if not authorization or not secrets.compare_digest(authorization, expected):
                raise PermissionError("The gateway rejected the session credential.")

    def reset(self) -> None:
        with self._lock:
            self._session = None
            self._window_until = 0


def stable_device_id(serial: str, ip: str, mac: str = "") -> str:
    digest = hashlib.md5(f"{serial}|{ip}|{mac}".encode("utf-8"), usedforsecurity=False).digest()
    return f"{digest[0]:02x}{digest[1]:02x}{digest[2]:02x}{digest[3]:02x}-{digest[4]:02x}{digest[5]:02x}-{digest[6]:02x}{digest[7]:02x}-{digest[8]:02x}{digest[9]:02x}-{digest[10]:02x}{digest[11]:02x}{digest[12]:02x}{digest[13]:02x}{digest[14]:02x}{digest[15]:02x}"
