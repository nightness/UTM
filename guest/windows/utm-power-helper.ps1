<#
.SYNOPSIS
    UTM power helper: tells UTM when Windows turns its display off or on.

.DESCRIPTION
    Used with QEMU > Tweaks > "Guest controls power" in UTM (Intel build). Windows reports its
    console display state (GUID_CONSOLE_DISPLAY_STATE); this helper writes "display off" or
    "display on" to the virtio-serial port com.utmapp.power.0, and UTM puts the Mac's display to
    sleep or keeps it awake to match. Needs the VirtIO serial driver from UTM's guest tools.

    Install (from an Administrator PowerShell):
        powershell -ExecutionPolicy Bypass -File .\utm-power-helper.ps1 -Install
    Remove:
        powershell -ExecutionPolicy Bypass -File .\utm-power-helper.ps1 -Uninstall

    Installing copies this script to "$env:ProgramFiles\UTM Power Helper" and registers a
    scheduled task that runs it as SYSTEM at startup, so it also covers the sign-in screen.
#>
param(
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$TaskName = 'UTM Power Helper'
$InstallDir = Join-Path $env:ProgramFiles 'UTM Power Helper'
$InstalledScript = Join-Path $InstallDir 'utm-power-helper.ps1'

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Install -or $Uninstall) {
    if (-not (Test-Administrator)) {
        throw 'Run this from an Administrator PowerShell.'
    }
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if ($Uninstall) {
        Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
        Write-Host 'UTM Power Helper removed.'
        return
    }
    # The helper talks to UTM over a VirtIO serial port. Install the driver, and the QEMU guest
    # agent UTM uses to put the guest to sleep, from the UTM Power Helper CD if they are missing.
    # VirtIO serial controller: PCI vendor 1AF4, device 1003 (legacy) or 1043 (modern)
    $serial = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^PCI\\VEN_1AF4&DEV_(1003|1043)' })
    if ($serial.Count -eq 0 -or ($serial | Where-Object { $_.Status -ne 'OK' })) {
        $os = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'w11' } else { 'w10' }
        $inf = Join-Path $PSScriptRoot "vioserial\$os\amd64\vioser.inf"
        if (Test-Path $inf) {
            Write-Host 'Installing the VirtIO serial driver...'
            pnputil.exe /add-driver $inf /install | Out-Host
        } else {
            Write-Warning 'The VirtIO serial driver is missing. Install it from UTM''s Windows guest tools, then run this again.'
        }
    }
    if (-not (Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue)) {
        $msi = Join-Path $PSScriptRoot 'qemu-ga-x86_64.msi'
        if (Test-Path $msi) {
            Write-Host 'Installing the QEMU guest agent...'
            Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
        }
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ($PSCommandPath -ne $InstalledScript) {
        Copy-Item -Force $PSCommandPath $InstalledScript
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Tells UTM when Windows turns its display off or on.' | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host 'UTM Power Helper installed and running.'
    return
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

public class UtmPowerHelper : NativeWindow, IDisposable
{
    const int WM_POWERBROADCAST = 0x0218;
    const int PBT_POWERSETTINGCHANGE = 0x8013;
    const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;
    const uint GENERIC_WRITE = 0x40000000;
    const uint OPEN_EXISTING = 3;
    static readonly Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
    const string PortPath = @"\\.\Global\com.utmapp.power.0";

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct POWERBROADCAST_SETTING
    {
        public Guid PowerSetting;
        public uint DataLength;
        public uint Data;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnregisterPowerSettingNotification(IntPtr Handle);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    IntPtr notification;
    FileStream port;
    string lastState = "display on";
    readonly System.Windows.Forms.Timer retryTimer = new System.Windows.Forms.Timer();

    public UtmPowerHelper()
    {
        CreateHandle(new CreateParams());
        Guid guid = GUID_CONSOLE_DISPLAY_STATE;
        notification = RegisterPowerSettingNotification(Handle, ref guid, DEVICE_NOTIFY_WINDOW_HANDLE);
        if (notification == IntPtr.Zero)
        {
            throw new InvalidOperationException("RegisterPowerSettingNotification failed: " + Marshal.GetLastWin32Error());
        }
        // Re-send the current state every 30 s, so UTM catches up after it restarts or the port reopens
        retryTimer.Interval = 30000;
        retryTimer.Tick += (s, e) => Send(lastState);
        retryTimer.Start();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_POWERBROADCAST && (int)m.WParam == PBT_POWERSETTINGCHANGE)
        {
            var setting = (POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(POWERBROADCAST_SETTING));
            if (setting.PowerSetting == GUID_CONSOLE_DISPLAY_STATE)
            {
                // 0 = off, 1 = on, 2 = dimmed (still on)
                lastState = setting.Data == 0 ? "display off" : "display on";
                Send(lastState);
            }
        }
        base.WndProc(ref m);
    }

    void Send(string state)
    {
        byte[] bytes = Encoding.ASCII.GetBytes(state + "\n");
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                if (port == null)
                {
                    var handle = CreateFile(PortPath, GENERIC_WRITE, 0, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (handle.IsInvalid)
                    {
                        return; // no port: not running under UTM, or the option is off
                    }
                    port = new FileStream(handle, FileAccess.Write);
                }
                port.Write(bytes, 0, bytes.Length);
                port.Flush();
                return;
            }
            catch (IOException)
            {
                ClosePort();
            }
        }
    }

    void ClosePort()
    {
        if (port != null)
        {
            try { port.Dispose(); } catch { }
            port = null;
        }
    }

    public void Dispose()
    {
        retryTimer.Stop();
        if (notification != IntPtr.Zero)
        {
            UnregisterPowerSettingNotification(notification);
            notification = IntPtr.Zero;
        }
        ClosePort();
        DestroyHandle();
    }
}
'@ -ReferencedAssemblies System.Windows.Forms

$helper = New-Object UtmPowerHelper
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $helper.Dispose()
}
