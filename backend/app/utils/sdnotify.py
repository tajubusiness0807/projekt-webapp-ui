"""Minimale sd_notify-Implementierung ohne Zusatzabhängigkeit.

Wird der Dienst von systemd mit ``Type=notify`` und ``WatchdogSec=`` gestartet, meldet das Backend
damit Bereitschaft und sendet regelmäßig ein Lebenszeichen aus der Regelschleife. Hängt die Schleife,
startet systemd den Dienst neu – nach dem Neustart ist der Antrieb wieder gesperrt.
"""

from __future__ import annotations

import logging
import os
import socket

log = logging.getLogger(__name__)


class SystemdNotifier:
    def __init__(self) -> None:
        self._address = os.environ.get("NOTIFY_SOCKET")
        self._socket: socket.socket | None = None
        if self._address:
            if self._address.startswith("@"):
                self._address = "\0" + self._address[1:]
            try:
                self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            except OSError as exc:  # pragma: no cover - nur auf Systemen ohne AF_UNIX
                log.warning("sd_notify nicht verfügbar: %s", exc)
                self._socket = None

    @property
    def enabled(self) -> bool:
        return self._socket is not None

    def notify(self, state: str) -> None:
        if not self._socket or not self._address:
            return
        try:
            self._socket.sendto(state.encode("utf-8"), self._address)
        except OSError as exc:  # pragma: no cover - abhängig von systemd
            log.debug("sd_notify fehlgeschlagen: %s", exc)

    def ready(self) -> None:
        self.notify("READY=1")

    def watchdog(self) -> None:
        self.notify("WATCHDOG=1")

    def stopping(self) -> None:
        self.notify("STOPPING=1")
