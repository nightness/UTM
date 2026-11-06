UTM Power Helper

Used with QEMU > Tweaks > "Guest controls power" in UTM for Intel Macs
(https://github.com/nightness/UTM). Windows' power settings then drive the Mac:
when Windows turns its screen off, the Mac's display sleeps; when Windows sleeps,
the Mac follows; any key or click wakes both.

To install, double-click install.cmd and allow it to make changes. It installs
the VirtIO serial driver and the QEMU guest agent if they are missing, then the
helper, which runs as SYSTEM at startup.

To remove, run in an Administrator PowerShell:
  powershell -ExecutionPolicy Bypass -File "C:\Program Files\UTM Power Helper\utm-power-helper.ps1" -Uninstall

The vioserial driver and qemu-ga come from the virtio-win project
(https://github.com/virtio-win), under their own licenses; see virtio-win_license.txt.
