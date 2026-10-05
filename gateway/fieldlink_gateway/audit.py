from __future__ import annotations

import json
import threading
from pathlib import Path

from .models import CommissioningEvent


class AuditLog:
    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()
        self._events: list[CommissioningEvent] = []
        self._load()

    def record(self, event: CommissioningEvent) -> CommissioningEvent:
        with self._lock:
            self._events.insert(0, event)
            self._save()
        return event

    def newest_first(self) -> list[CommissioningEvent]:
        with self._lock:
            return list(self._events)

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            payload = json.loads(self.path.read_text())
        except json.JSONDecodeError:
            return
        events = []
        for item in payload:
            events.append(
                CommissioningEvent(
                    id=item["id"],
                    kind=item["kind"],
                    detail=item["detail"],
                    device_name=item.get("deviceName"),
                    successful=bool(item.get("successful", True)),
                )
            )
        self._events = events

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps([event.to_json() for event in self._events], indent=2) + "\n")
