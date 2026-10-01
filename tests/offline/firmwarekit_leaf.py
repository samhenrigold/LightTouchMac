"""Compile the same Foundation capacity leaf used by the GUI and FirmwareKit."""

def capacity_sources(root, tmp):
    return [str(root / "Packages/FirmwareKit/Sources/FirmwareKit/StorageCapacity/StorageCapacity.swift")]


def schema_sources():
    from pathlib import Path
    root = Path(__file__).resolve().parents[2]
    return [str(root / "Packages/FirmwareKit/Sources/FirmwareSchema/FirmwareWire.swift")]
