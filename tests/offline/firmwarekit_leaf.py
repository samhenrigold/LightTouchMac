"""Compile the same Foundation capacity leaf used by the GUI and FirmwareKit."""

def capacity_sources(root, tmp):
    return [str(root / "Packages/FirmwareKit/Sources/FirmwareKit/StorageCapacity/StorageCapacity.swift")]
