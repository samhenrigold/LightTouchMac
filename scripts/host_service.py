"""Compile the same narrow service boundary used by the Xcode helper target."""
from pathlib import Path
import subprocess

SERVICE_SOURCES = ['DeviceServices', 'HostServiceTypes', 'HostServiceProtocol',
                   'HostServiceResources', 'HostServiceWorkers', 'AFC',
                   'InstallationProxy', 'SpringBoardServices', 'LockdownState']

def client_sources(root):
    root = Path(root)
    return [root / f'LightTouchMac/Services/{name}.swift' for name in SERVICE_SOURCES] + [
        root / f'LightTouchMac/Transport/{name}.swift' for name in ['DeviceExecution', 'IMobileDevice']]

def build_worker(root, destination, flags, *, log=None):
    root, destination = Path(root), Path(destination)
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', destination.parent / 'modules',
               *flags, *client_sources(root), root / 'LightTouchMac/Services/NotificationProxy.swift',
               root / 'LightTouchServices/ServiceMain.swift', '-o', destination]
    subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT if log else None)
