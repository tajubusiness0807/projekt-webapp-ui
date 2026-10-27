"""Abschätzung des Akkustands aus der Spannung.

Der Ladezustand eines Li-Ionen-Akkus lässt sich aus der Spannung nur grob schätzen; unter Last sinkt
die Spannung deutlich. Die Anzeige wird deshalb als „geschätzt" gekennzeichnet. Die Stützpunkte sind
eine typische Entladekurve für NMC-Zellen und werden auf die konfigurierten Grenzen „leer"/„voll" skaliert.
"""

from __future__ import annotations

from ..models.settings import BatterySettings

# (relative Zellspannung 0…1 zwischen leer und voll, Ladezustand 0…1)
_CURVE: tuple[tuple[float, float], ...] = (
    (0.00, 0.00),
    (0.12, 0.05),
    (0.30, 0.15),
    (0.45, 0.30),
    (0.55, 0.45),
    (0.65, 0.60),
    (0.78, 0.75),
    (0.90, 0.90),
    (1.00, 1.00),
)


def estimate_percent(pack_voltage: float, battery: BatterySettings) -> float:
    cell = pack_voltage / battery.cells_series
    span = battery.cell_full_v - battery.cell_empty_v
    rel = (cell - battery.cell_empty_v) / span if span > 0 else 0.0
    if rel <= 0:
        return 0.0
    if rel >= 1:
        return 100.0
    for (x0, y0), (x1, y1) in zip(_CURVE, _CURVE[1:]):
        if x0 <= rel <= x1:
            t = (rel - x0) / (x1 - x0)
            return round((y0 + t * (y1 - y0)) * 100.0, 1)
    return 0.0  # pragma: no cover - durch die Grenzen oben ausgeschlossen


def pack_limits(battery: BatterySettings) -> dict[str, float]:
    n = battery.cells_series
    return {
        "full_v": round(battery.cell_full_v * n, 2),
        "warning_v": round(battery.cell_warning_v * n, 2),
        "critical_v": round(battery.cell_critical_v * n, 2),
        "empty_v": round(battery.cell_empty_v * n, 2),
    }
