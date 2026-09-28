Live Transcribe for Linux @VERSION@: hold a key, speak, and let go, and what you said is typed into the app you're using. Speech-to-text runs on your computer, on the NPU of an Intel Core Ultra or on the CPU, with the Mac app's model for Sinhala and English.

**Where it types.** On COSMIC, and on wlroots desktops such as Sway and Hyprland (untested). GNOME, KDE Plasma and X11 desktops come in later versions; there the app starts, and its Settings window says why it can't type yet.

**Installing**
- Ubuntu 22.04 or later, Debian 12 or later: `sudo apt install ./live-transcribe_@VERSION@_amd64.deb`
- Fedora: `sudo dnf install ./live-transcribe-@VERSION@-1.x86_64.rpm`; Fedora Atomic: `rpm-ostree install ./live-transcribe-@VERSION@-1.x86_64.rpm`, then restart. openSUSE: `sudo zypper install ./live-transcribe-@VERSION@-1.x86_64.rpm`
- Any other distribution with glibc 2.35 or later: the AppImage. It can't install the udev rule that lets it read the keyboard; [README.Linux](https://github.com/Nerdstorm/LiveTranscribe/blob/main/linux-windows/packaging/linux/README.Linux) gives the commands that do.

The first start downloads the speech model, 1.1 GB, from Hugging Face.

**The NPU.** With Intel's NPU driver installed, the model runs on the NPU: `intel-npu-driver` on Fedora, Arch and openSUSE, or Intel's packages from [linux-npu-driver](https://github.com/intel/linux-npu-driver/releases) on Ubuntu and Debian. Without it, the model runs on the CPU, more slowly.

**Reading the keyboard.** The deb and rpm install a udev rule that lets whoever is logged in at the machine read the keyboards, which hold-to-talk needs to watch for its key. Any program that user runs can then read what they type, as any X11 program always could. Removing the package removes the rule.

The packages carry Intel's OpenVINO runtime, under the Intel OpenVINO Distribution License (`/usr/lib/live-transcribe/openvino/licenses`). SHA256SUMS lists each download's checksum.
