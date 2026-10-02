"""Link the profile-neutral HostRuntime package into standalone host probes."""
from swift_package import product_flags


def swift_flags(root, *, target=None):
    return [*product_flags(root, package='Packages/HostRuntime', product='HostRuntime',
                           cache='host-runtime', target=target),
            '-Xfrontend', '-import-module', '-Xfrontend', 'HostRuntime']
