# UTM for Intel Macs (unofficial build)

**This is an unofficial build of [UTM](https://github.com/utmapp/UTM) by Josh Guyette
([@nightness](https://github.com/nightness)). It is not made, signed or supported by the UTM
developers (Turing Software, LLC).** Report problems with this build at
[nightness/UTM](https://github.com/nightness/UTM/issues), not on utmapp/UTM.

It is UTM tuned for running Windows 11 x64 on Intel Macs with the Apple Hypervisor (HVF). It was
developed and tested on a 2017 MacBook Pro (i7-7700HQ, Radeon Pro 555, macOS 15 via OpenCore Legacy
Patcher). Version numbers follow upstream with an `-intel.N` suffix, for example `5.0.8-intel.1`.

## What is different from UTM

**Signing and app identity.** The app is signed with Josh Guyette's Developer ID (team
`WT957SC7MJ`). Its bundle identifiers start with `com.nightness` instead of `com.utmapp`, so
it has its own settings, VM list and sandbox container. It can be installed next to the official UTM.
To use a VM you already have, open its `.utm` file in this app. Don't run the same VM in both apps
at once.

**Components:**

- **QEMU:** [nightness/qemu `utm-win11`](https://github.com/nightness/qemu/tree/utm-win11), which
  is UTM's QEMU (utmapp/qemu `utm-edition`) plus these fixes:
  - **3D on Intel:** HVF no longer maps GPU blob memory as executable. Without this, Intel HVF
    rejects the mapping and 3D acceleration fails
    ([utmapp/UTM#8036](https://github.com/utmapp/UTM/issues/8036)).
  - **No blank boot screen:** virtio-gpu keeps showing the VGA framebuffer until the Windows driver
    sets up a real scanout. Before, the screen went blank for about 12 s during boot.
  - **Steadier audio:** HDA playback pacing and recovery from a full ring, plus a jitter buffer in
    the CoreAudio backend.
  - **vTPM:** the TPM PPI region is mapped as a whole page, and `-overcommit mem-lock` works.
- **DXMT:** [nightness/dxmt `intel-mac-native`](https://github.com/nightness/dxmt/tree/intel-mac-native)
  is the Direct3D 11 to Metal translator that Windows 3D uses (through Neptune). It has two fixes:
  - It now uses the Microsoft x64 calling convention, so D3D11 devices no longer hang on x86_64.
  - It registers the R32Sint format on Mac2-family GPUs, so device creation no longer fails and DWM
    no longer crash-loops.

  Apple's D3DMetal requires Apple silicon, so this build always uses DXMT on Intel. D3D12 is not
  available.

**Defaults for x86_64 guests on Intel HVF.** These apply only when the Mac has an Intel CPU, the guest
is x86_64 and the hypervisor is in use:

- **Interrupt remapping (x2APIC).** On the q35 machine, UTM adds
  `-device intel-iommu,intremap=on,eim=on,dma-translation=off`. The guest's APIC then runs in x2APIC
  mode, so APIC accesses become cheap MSR exits instead of MMIO exits that hold QEMU's global lock.
  On the test machine this halved lock contention, and audio dropouts under video went from 1 to 6 s
  per 30 s down to none. DMA translation stays off, so devices still use direct DMA. To turn it off,
  clear **QEMU → Tweaks → Interrupt remapping (x2APIC)** in the VM's settings.
- **CPU clock flags.** With **System → CPU** left at *Default*, UTM still picks the CPU model that
  matches the Mac's generation, and now adds `+invtsc,-hypervisor`. With an invariant TSC and no
  hypervisor bit, Windows uses the TSC as its clock instead of reading timers through VM exits. On the
  test machine, idle host CPU fell from 90% to 53% and a WebGL benchmark went from 42 to 56 fps. If
  you pick a CPU model yourself, add these flags under *CPU Flags*.
- **Lock guest memory.** UTM adds `-overcommit mem-lock=on`, which keeps the guest's RAM resident, so
  macOS doesn't compress or swap it and the guest doesn't stall on page faults. The Mac needs enough
  free memory for the whole guest. If the lock fails, QEMU logs a warning and the VM still starts. To
  turn it off, clear **QEMU → Tweaks → Lock guest memory**.
- **Audio: CoreAudio.** With **Settings → Sound → QEMU sound backend** left at *Default*, these VMs use
  CoreAudio, set to `timer-period=5000,out.frequency=48000,out.buffer-length=5000,out.buffer-count=40`.
  That means 48 kHz with no resampling, 5 ms buffers and a 200 ms ring. Our QEMU's jitter buffer
  starts at half the ring, which rides out stalls in the main loop. CoreAudio is output only. To
  give the guest a microphone, choose *SPICE with GStreamer*, which still gets the HDA pacing fix but
  not the jitter buffer.
- **QEMU main loop priority.** QEMU's main loop now runs at user-interactive QoS. It feeds the sound
  card and runs virgl; at the lower default QoS it waits behind the vCPU threads. To keep the old
  behaviour, set the environment variable `QEMU_MAIN_LOOP_QOS=default`. This one applies to every VM.

**Networking.** Shared and Bridged networking use Apple's vmnet, which needs the
`com.apple.vm.networking` entitlement. Apple grants that entitlement only through a provisioning
profile, which this build doesn't have. New VMs therefore default to *Emulated VLAN*, which works for
normal internet access and port forwarding. An existing VM set to Shared or Bridged must be switched
to Emulated VLAN.

## Windows 11 on an Intel Mac

1. **Create the VM.** Choose Virtualize → Windows, and keep the hypervisor on. In Hardware, turn on
   GPU acceleration (display `virtio-vga-gl`). Turn on TPM 2.0; Secure Boot keys are enrolled
   automatically on first boot. Attach a Windows 11 x64 ISO.
2. **Set the vCPU count.** Use as many vCPUs as the Mac has *physical* cores. On a 4-core / 8-thread
   i7, set System → CPU Cores to 4. By default UTM gives the guest every hyperthread, and Intel Macs
   ran Windows better with one vCPU per physical core.
3. **Install the drivers.** After setup, install UTM's guest tools. They include the signed viogpu3d
   3D driver.
4. **Enable x2APIC in the guest.** In an Administrator command prompt, run this once, then restart
   Windows:

   ```
   bcdedit /set {current} x2apicpolicy enable
   ```

   With interrupt remapping available, Windows may switch to x2APIC on its own. The setting is
   harmless either way and makes sure the guest uses it.

### Letting Windows control the Mac's power

With **QEMU → Tweaks → Guest controls power** on (it's off by default), Windows' power settings
decide what the Mac's display does:

- **While Windows is running,** UTM keeps the Mac's own display and sleep timers from firing.
  Windows' timers are the only ones that count.
- **When Windows turns its screen off** (Settings → System → Power → *Turn my screen off after*),
  the Mac's display sleeps too. When Windows' screen comes back on, the Mac's display wakes.
- **Any key, click or trackpad touch** wakes both.
- **The Mac doesn't idle-sleep** while the VM runs, since Windows has no Sleep to hand it to (see
  below). Closing the lid or choosing Sleep still works. When the VM stops, the Mac's own settings
  apply again.

Windows' *Sleep* (ACPI S3) is still unavailable. On Intel Macs, resuming a Windows VM that uses 3D
acceleration from S3 crashes QEMU, so UTM keeps S3 off. When it works, UTM is ready for it: the Mac
will follow Windows to sleep and wake it again.

**The UTM power helper** reports Windows' display state to UTM over a virtio-serial port. If the
option is on and the helper hasn't checked in two minutes after the VM starts, UTM puts the
*UTM Power Helper* CD into the VM's empty CD drive and tells you. Open the CD in Windows and
double-click `install.cmd`. It installs the VirtIO serial driver and the QEMU guest agent if they're
missing (both from [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts)), then the
helper. The helper installs to `C:\Program Files\UTM Power Helper` and runs as SYSTEM at startup, so
it also covers the sign-in screen. To remove it, run its `utm-power-helper.ps1 -Uninstall` from an
Administrator PowerShell. Without the helper, UTM still holds the Mac's timers off, but can't follow Windows' screen.

**No Mac password on wake.** macOS asks for your password when its display wakes if System
Settings → Lock Screen → *Require password after screen saver begins or display is turned off* is
set. No app can skip that prompt. To let Windows' own sign-in settings decide, set it to *Never*.
After the Mac itself has slept, macOS may still ask.

### Using an existing disk image

A sandboxed app can't open a disk outside the `.utm` bundle, and that includes the backing file of a
qcow2 overlay. Put a copy inside the bundle instead. On APFS, `cp -c` makes a clone, which is
instant, takes no extra space and leaves the original untouched:

```sh
# with the VM that owns the disk shut down
cp -c /path/to/disk.qcow2 "Windows 11.utm/Data/windows.qcow2"
```

The VM gets its own new TPM and UEFI variables. Windows accepts that, but BitLocker will ask for its
recovery key.

## Building

On a Mac with Xcode, Homebrew (`meson`, `ninja`, `pkg-config`, `python3`) and a Developer ID
certificate, run:

```sh
./scripts/build_intel_release.sh
```

The script does the following:

1. Downloads UTM's CI sysroot for macOS x86_64, if there isn't one already.
2. Rebuilds QEMU and DXMT into it from the commits in `patches/sources`
   (`build_dependencies.sh -u qemu,dxmt`).
3. Archives UTM.app for x86_64.
4. Signs every nested binary with the hardened runtime.
5. Builds a signed DMG.
6. Notarizes and staples the app and the DMG. This step needs a `notarytool` keychain profile named
   `notary`.

To run only some of these, set `STEPS`, for example `STEPS="sign dmg"`. A full dependency build
(`build_dependencies.sh -p macos -a x86_64`) also uses our QEMU and DXMT.

## License

UTM is licensed under the Apache License 2.0, and QEMU under the GPL v2. The source for the QEMU in
this build is the commit pinned as `QEMU_COMMIT` in `patches/sources`, at
https://github.com/nightness/qemu.
