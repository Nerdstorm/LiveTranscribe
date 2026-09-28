#!/bin/sh
# After removing or upgrading (the deb's postrm, the rpm's %postun): takes the keyboard rule's
# access away from the keyboards plugged in now, if the rule is gone.
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=input --action=change >/dev/null 2>&1 || true
fi
# The rpm owns only its files, so once it's gone (not upgraded: $1 is 0) its folders are left
# empty. dpkg removes the deb's itself.
if [ "${1:-}" = 0 ]; then
    rmdir /usr/lib/live-transcribe/openvino/licenses /usr/lib/live-transcribe/openvino \
        /usr/lib/live-transcribe /usr/share/doc/live-transcribe 2>/dev/null || true
fi
exit 0
