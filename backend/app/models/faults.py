"""Fehlerkatalog mit Codes, Schweregrad und verständlichen deutschen Erklärungen.

* ``E…`` – kritisch, sperrt den Antrieb. Muss nach Wegfall der Ursache quittiert werden.
* ``W…`` – Warnung, Fahrt bleibt (ggf. eingeschränkt) möglich.
* ``I…`` – Information.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from .common import Severity


class FaultCode(StrEnum):
    NO_CONTROLLER = "E001"
    SINGLE_CONTROLLER = "E002"
    COMMUNICATION_ERROR = "E003"
    INVALID_TELEMETRY = "E004"
    OVER_TEMPERATURE = "E005"
    LOW_BATTERY = "E006"
    CONNECTION_LOST = "E007"
    WATCHDOG = "E008"
    HARDWARE_NOT_INITIALIZED = "E009"
    EMERGENCY_STOP = "E010"
    CONFIG_INVALID = "E011"
    TEMPERATURE_WARNING = "W005"
    BATTERY_WARNING = "W006"
    COMMAND_STALE = "W012"
    INVALID_COMMAND = "W013"
    SPEED_UNAVAILABLE = "W014"
    COMMISSIONING = "W015"
    CONTROL_TAKEN_OVER = "I016"


@dataclass(frozen=True)
class FaultDefinition:
    code: FaultCode
    severity: Severity
    blocking: bool
    title: str
    description: str
    remedy: str

    def to_dict(self) -> dict[str, object]:
        return {
            "code": self.code.value,
            "severity": self.severity.value,
            "blocking": self.blocking,
            "title": self.title,
            "description": self.description,
            "remedy": self.remedy,
        }


FAULT_CATALOG: dict[FaultCode, FaultDefinition] = {
    d.code: d
    for d in (
        FaultDefinition(
            FaultCode.NO_CONTROLLER,
            Severity.CRITICAL,
            True,
            "Kein Controller verbunden",
            "Von keinem der beiden Motorcontroller kommen gültige Rückmeldungen.",
            "Stromversorgung, Hauptschalter, serielle Verbindung und Firmware beider Controller prüfen.",
        ),
        FaultDefinition(
            FaultCode.SINGLE_CONTROLLER,
            Severity.CRITICAL,
            True,
            "Nur ein Controller verbunden",
            "Einer der beiden Motorcontroller antwortet nicht. Das Fahrzeug darf nicht mit nur einer Achse betrieben werden.",
            "Verbindung und Versorgung des ausgefallenen Controllers prüfen, danach Fehler quittieren.",
        ),
        FaultDefinition(
            FaultCode.COMMUNICATION_ERROR,
            Severity.CRITICAL,
            True,
            "Kommunikationsfehler",
            "Die Rückmeldungen eines Controllers sind ausgeblieben oder fehlerhaft (Zeitüberschreitung, Prüfsummenfehler).",
            "Kabel, Masseverbindung, Baudrate und Signalpegel prüfen. Störquellen (Motorleitungen) räumlich trennen.",
        ),
        FaultDefinition(
            FaultCode.INVALID_TELEMETRY,
            Severity.CRITICAL,
            True,
            "Ungültige Messdaten",
            "Ein Controller liefert Werte außerhalb des plausiblen Bereichs.",
            "Firmware-Konfiguration (Feedback-Format, Odometrie) und Kalibrierung prüfen.",
        ),
        FaultDefinition(
            FaultCode.OVER_TEMPERATURE,
            Severity.CRITICAL,
            True,
            "Übertemperatur",
            "Controller- oder Motortemperatur hat den kritischen Grenzwert überschritten.",
            "Fahrzeug abkühlen lassen, Kühlung und Last prüfen.",
        ),
        FaultDefinition(
            FaultCode.LOW_BATTERY,
            Severity.CRITICAL,
            True,
            "Akkuspannung kritisch",
            "Die Akkuspannung liegt unter dem kritischen Grenzwert. Weiterfahren schädigt den Akku oder löst das BMS aus.",
            "Fahrzeug abstellen und Akku laden.",
        ),
        FaultDefinition(
            FaultCode.CONNECTION_LOST,
            Severity.CRITICAL,
            True,
            "Verbindungsverlust",
            "Die Verbindung zum steuernden Gerät ist während der Fahrt abgebrochen. Die Fahranforderung wurde auf null gesetzt.",
            "Verbindung wiederherstellen, Fehler quittieren und Motoren bewusst neu freigeben.",
        ),
        FaultDefinition(
            FaultCode.WATCHDOG,
            Severity.CRITICAL,
            True,
            "Watchdog ausgelöst",
            "Eine interne Steuerungsaufgabe hat ihr Zeitlimit überschritten.",
            "Systemlast und Protokoll prüfen. Bei Wiederholung Dienst neu starten.",
        ),
        FaultDefinition(
            FaultCode.HARDWARE_NOT_INITIALIZED,
            Severity.CRITICAL,
            True,
            "Hardware nicht initialisiert",
            "Der Hardwaremodus ist angefordert, aber Konfiguration oder Freigabe-Checkliste sind unvollständig.",
            "Checkliste in der Systemansicht abarbeiten oder in den Simulationsmodus wechseln.",
        ),
        FaultDefinition(
            FaultCode.EMERGENCY_STOP,
            Severity.CRITICAL,
            True,
            "Not-Aus aktiv",
            "Der Software-Not-Aus wurde ausgelöst. Er ersetzt keinen unabhängigen Hardware-Not-Aus.",
            "Ursache klären, Not-Aus zurücksetzen und Motoren bewusst neu freigeben.",
        ),
        FaultDefinition(
            FaultCode.CONFIG_INVALID,
            Severity.CRITICAL,
            True,
            "Konfiguration ungültig",
            "Die gespeicherte Konfiguration konnte nicht validiert werden. Es wurden sichere Standardwerte geladen.",
            "Einstellungen prüfen und neu speichern.",
        ),
        FaultDefinition(
            FaultCode.TEMPERATURE_WARNING,
            Severity.WARNING,
            False,
            "Temperatur erhöht",
            "Eine Temperatur liegt über der Warnschwelle. Die Leistung wird reduziert.",
            "Last verringern und abkühlen lassen.",
        ),
        FaultDefinition(
            FaultCode.BATTERY_WARNING,
            Severity.WARNING,
            False,
            "Akkuspannung niedrig",
            "Die Akkuspannung liegt unter der Warnschwelle. Bei aktivem Batterie-Schutz wird die Leistung reduziert.",
            "Fahrt beenden und Akku laden.",
        ),
        FaultDefinition(
            FaultCode.COMMAND_STALE,
            Severity.WARNING,
            False,
            "Steuerbefehl veraltet",
            "Es kamen kurzzeitig keine aktuellen Fahranforderungen an. Gas wurde auf null gesetzt (Neutralverriegelung).",
            "Gas loslassen. Danach nimmt das Fahrzeug wieder Befehle an. WLAN-Empfang prüfen.",
        ),
        FaultDefinition(
            FaultCode.INVALID_COMMAND,
            Severity.WARNING,
            False,
            "Ungültiger Steuerbefehl",
            "Ein Steuerbefehl wurde abgelehnt (Format, Reihenfolge, Alter, Rate oder Widerspruch).",
            "Seite neu laden. Bei Wiederholung Diagnoseprotokoll prüfen.",
        ),
        FaultDefinition(
            FaultCode.SPEED_UNAVAILABLE,
            Severity.WARNING,
            False,
            "Geschwindigkeit nicht messbar",
            "Ohne gültige Geschwindigkeitsmessung kann die Geschwindigkeitsbegrenzung nicht überwacht werden. Gas ist gesperrt.",
            "Controller-Rückmeldungen und Raddurchmesser prüfen.",
        ),
        FaultDefinition(
            FaultCode.COMMISSIONING,
            Severity.WARNING,
            False,
            "Inbetriebnahme-Modus",
            "Der Test mit aufgebockten Rädern ist noch nicht bestätigt. Leistung und Geschwindigkeit sind stark begrenzt.",
            "Test gemäß docs/hardware.md durchführen und in den Hardware-Einstellungen bestätigen.",
        ),
        FaultDefinition(
            FaultCode.CONTROL_TAKEN_OVER,
            Severity.INFO,
            False,
            "Steuerung übernommen",
            "Ein anderes Gerät hat die Steuerung übernommen. Die Motoren wurden gesperrt.",
            "Bei Bedarf Steuerung zurückholen.",
        ),
    )
}


def fault_definition(code: FaultCode) -> FaultDefinition:
    return FAULT_CATALOG[code]
