#!/bin/sh
# After installing or upgrading (the deb's postinst, the rpm's %post): applies the keyboard rule to
# the keyboards plugged in now, so hold-to-talk works without a restart. Where udev isn't running
# (a container, an image being built), the rule applies at the next boot.
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=input --action=change >/dev/null 2>&1 || true
fi
exit 0
