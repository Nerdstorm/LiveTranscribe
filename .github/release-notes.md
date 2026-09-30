## Installing

### Mac

For Macs with Apple silicon and macOS 14 or later. Open `LiveTranscribe.dmg` and drag Live Transcribe to Applications. It's signed with Developer ID and notarized by Apple, and it keeps itself up to date.

### Linux

For x86-64 computers with glibc 2.35 or later. Dictation types on COSMIC, and on wlroots desktops such as Sway and Hyprland (untested). GNOME, KDE Plasma and X11 desktops come in later versions; there the app starts, and its Settings window says why it can't type yet.

- Ubuntu 22.04 or later, Debian 12 or later: `sudo apt install ./live-transcribe_@VERSION@_amd64.deb`
- Fedora: `sudo dnf install ./live-transcribe-@VERSION@-1.x86_64.rpm`. Fedora Atomic: `rpm-ostree install ./live-transcribe-@VERSION@-1.x86_64.rpm`, then restart.
- openSUSE: `sudo zypper install ./live-transcribe-@VERSION@-1.x86_64.rpm`
- Any other distribution: the AppImage. It can't install the udev rule that lets it read the keyboard; [README.Linux](https://github.com/Nerdstorm/LiveTranscribe/blob/main/linux-windows/packaging/linux/README.Linux) gives the commands that do.

The first start downloads the speech model, 1.1 GB, and the cleanup model, 1.2 GB, from Hugging Face. Cleanup runs on the CPU; **Clean up transcripts with the LLM** in Settings › Advanced turns it off.

**The NPU.** With Intel's NPU driver installed, the model runs on the NPU of an Intel Core Ultra: `intel-npu-driver` on Fedora, Arch and openSUSE, or Intel's packages from [linux-npu-driver](https://github.com/intel/linux-npu-driver/releases) on Ubuntu and Debian. Without it, the model runs on the CPU, more slowly.

**Reading the keyboard.** The deb and rpm install a udev rule that lets whoever is logged in at the machine read the keyboards, which hold-to-talk needs to watch for its key. Any program that user runs can then read what they type, as any X11 program always could. Removing the package removes the rule.

The Linux packages carry Intel's OpenVINO runtime, under the Intel OpenVINO Distribution License (`/usr/lib/live-transcribe/openvino/licenses`).

### Windows

For x86-64 PCs with Windows 10 or 11. Run `live-transcribe_@VERSION@_x64-setup.exe`; it installs for your account, without administrator rights. It isn't signed yet, so SmartScreen warns about an unrecognised app: choose More info, then Run anyway.

The first start downloads the speech model, 1.1 GB, and the cleanup model, 1.2 GB, from Hugging Face. With an Intel Core Ultra the speech model runs on its NPU (the driver comes from Windows Update or the PC's maker), otherwise on the CPU; cleanup runs on the CPU.

Dictation types into any app. Apps running as administrator don't accept typing from other apps, so there the text is left on the clipboard to paste.

**Password fields.** The app recognises a password field only in Windows' own controls. In browsers, Office and Electron apps it can't tell, so don't dictate while a password field has focus.

The installer carries Intel's OpenVINO runtime (Apache-2.0) and Microsoft's C++ runtime.

SHA256SUMS lists each download's checksum.
