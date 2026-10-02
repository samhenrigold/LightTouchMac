"""Link the real host/session runtime packages into standalone Swift probes."""
import device_runtime


def swift_flags(root, *, target=None):
    """DeviceRuntime's product includes its real HostRuntime dependency.

    GUI files can expose typed session values even in an offline probe; make
    both defining modules available for the requested target without compiling
    another copy of the helper owner, link, or reaper into each driver.
    """
    return device_runtime.swift_flags(root, target=target)
