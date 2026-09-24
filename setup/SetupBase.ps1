<#
    Base setup for every Windows Sandbox scenario. Runs at logon via SandboxBase.wsb <LogonCommand>.
    Scenario scripts (Setup<Scenario>.ps1) should call this first:  & "$PSScriptRoot\SetupBase.ps1" -Scenario '<Scenario>'

    Taskbar: left-aligned, never combine buttons, hide Task View. Explorer is restarted to apply.
    Desktop: removes the Edge shortcut, adds shortcuts to the shared, setup and prereqs folders.
    Wallpaper: plain blue with "Sandbox: <Scenario>" in the centre.
    Recycle Bin: asks for confirmation before deleting. Desktop icons: auto-arranged from the top left.

    Log: every step is timed and written to logs\SetupBase-<yyyyMMdd-HHmmss>.log. The logs folder is mapped
    read/write (setup and prereqs are read-only), so the host can see what happened after the sandbox closes.
    The log is written even if a step fails, with the failing step and its error at the bottom.
#>

param([string]$Scenario = 'Base')

$ErrorActionPreference = 'Stop'

# --- Timing and logging ------------------------------------------------------------------------------------

$scriptStart = Get-Date
$sandboxRoot = Split-Path -Parent $PSScriptRoot   # C:\sandbox inside the sandbox
$logFolder = Join-Path $sandboxRoot 'logs'
$logPath = Join-Path $logFolder "SetupBase-$($scriptStart.ToString('yyyyMMdd-HHmmss')).log"

# Startup latency: boot time is derived from TickCount (ms since boot; Int32 is fine for a fresh sandbox,
# and TickCount64 isn't available in Windows PowerShell 5.1), PowerShell start from this process.
$bootTime = $scriptStart.AddMilliseconds(-[Environment]::TickCount)
$psStart = (Get-Process -Id $PID).StartTime

$steps = New-Object System.Collections.Generic.List[object]
$stepTimer = New-Object System.Diagnostics.Stopwatch
$currentStep = $null

# Closes the step in progress (recording its duration) and starts timing the next one.
function Start-Step([string]$Name) {
    if ($script:currentStep) { $script:steps.Add([pscustomobject]@{ Name = $script:currentStep; Ms = $stepTimer.ElapsedMilliseconds }) }
    $script:currentStep = $Name
    $stepTimer.Restart()
}

# One line per timing: label padded to 32 characters, milliseconds right-aligned in 10.
function Format-Line([string]$Label, [double]$Ms) { '{0,-32}{1,10:N0} ms' -f $Label, $Ms }

function Write-Log([string]$Failure) {
    $lines = @(
        "SetupBase ($Scenario) - $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))"
        ''
        Format-Line 'Sandbox boot -> PowerShell start' ($psStart - $bootTime).TotalMilliseconds
        Format-Line 'PowerShell start -> script start' ($scriptStart - $psStart).TotalMilliseconds
        ''
    )
    $lines += $steps | ForEach-Object { Format-Line $_.Name $_.Ms }
    $lines += ''
    $lines += Format-Line 'Script total' ((Get-Date) - $scriptStart).TotalMilliseconds
    if ($Failure) { $lines += '', $Failure }

    try {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null   # -Force on a folder is safe (no wipe)
        Set-Content -Path $logPath -Value $lines -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write log to ${logPath}: $_"
    }
}

# --- Setup steps -------------------------------------------------------------------------------------------

$failure = $null
try {
    Start-Step 'Taskbar registry'
    # Explorer only reads these at startup, so they take effect when it is restarted at the end.
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    New-ItemProperty -Path $advanced -Name TaskbarAl -Value 0 -PropertyType DWord -Force | Out-Null           # 0 = left, 1 = centre
    New-ItemProperty -Path $advanced -Name TaskbarGlomLevel -Value 2 -PropertyType DWord -Force | Out-Null    # 2 = never combine
    New-ItemProperty -Path $advanced -Name ShowTaskViewButton -Value 0 -PropertyType DWord -Force | Out-Null  # 0 = hidden

    Start-Step 'Remove Edge shortcut'
    # Normally on the Public desktop; check the user desktop too
    Remove-Item -Path "$env:PUBLIC\Desktop\Microsoft Edge.lnk", "$env:USERPROFILE\Desktop\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue

    Start-Step 'Folder shortcuts'
    # Desktop shortcuts to the mapped folders under C:\sandbox
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($name in 'shared', 'setup', 'prereqs') {
        $shortcut = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
        $shortcut.TargetPath = Join-Path $sandboxRoot $name
        $shortcut.Save()
    }

    Start-Step 'Load Drawing + WinForms'
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms

    Start-Step 'Draw wallpaper'
    # Draw "Sandbox: <Scenario>" on plain blue. The desktop colour is the same blue and the image is centred
    # (not stretched), so resizing the sandbox window just shows more plain blue around the label.
    $blue = [System.Drawing.Color]::FromArgb(0, 99, 177)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $graphics.Clear($blue)
    $font = New-Object System.Drawing.Font 'Segoe UI', 32
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $area = New-Object System.Drawing.RectangleF 0, 0, $bounds.Width, $bounds.Height
    $graphics.DrawString("Sandbox: $Scenario", $font, [System.Drawing.Brushes]::White, $area, $format)
    $wallpaper = Join-Path $env:TEMP 'SandboxWallpaper.bmp'   # setup is read-only, so write inside the sandbox
    $bitmap.Save($wallpaper, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $font.Dispose(); $graphics.Dispose(); $bitmap.Dispose()

    Start-Step 'Compile C# (Add-Type)'
    # Win32 calls with no PowerShell equivalent. Add new signatures here rather than compiling a second type.
    Add-Type -Namespace Sandbox -Name Desktop -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool SystemParametersInfo(int action, int param, string value, int flags);
[DllImport("user32.dll")]
public static extern bool SetSysColors(int count, int[] elements, int[] colours);
[DllImport("shell32.dll")]
public static extern void SHGetSetSettings(byte[] state, int mask, bool set);

// COM interfaces for reaching the live desktop view (ShellWindows -> desktop browser -> IFolderView2).
// Methods are declared in vtable order; the _Name placeholders are slots that are never called.
[ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
public interface IShellWindows {
    void _Count(); void _Item(); void _NewEnum(); void _Register(); void _RegisterPending(); void _Revoke(); void _OnNavigate(); void _OnActivated();
    [PreserveSig] int FindWindowSW([In] ref object loc, [In] ref object locRoot, int swClass, out int hwnd, int options, [MarshalAs(UnmanagedType.IDispatch)] out object disp);
}
[ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IComServiceProvider {
    [return: MarshalAs(UnmanagedType.IUnknown)] object QueryService([In] ref Guid service, [In] ref Guid riid);
}
[ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellBrowser {
    void _GetWindow(); void _ContextSensitiveHelp(); void _InsertMenusSB(); void _SetMenuSB(); void _RemoveMenusSB(); void _SetStatusTextSB();
    void _EnableModelessSB(); void _TranslateAcceleratorSB(); void _BrowseObject(); void _GetViewStateStream(); void _GetControlWindow(); void _SendControlMsg();
    [return: MarshalAs(UnmanagedType.IUnknown)] object QueryActiveShellView();
}
[ComImport, Guid("1AF3A467-214F-4298-908E-06B03E0B39F9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IFolderView2 {
    void _GetCurrentViewMode(); void _SetCurrentViewMode(); void _GetFolder(); void _Item(); void _ItemCount(); void _Items(); void _GetSelectionMarkedItem();
    void _GetFocusedItem(); void _GetItemPosition(); void _GetSpacing(); void _GetDefaultSpacing(); void _GetAutoArrange(); void _SelectItem(); void _SelectAndPositionItems();
    void _SetGroupBy(); void _GetGroupBy(); void _SetViewProperty(); void _GetViewProperty(); void _SetTileViewProperties(); void _SetExtendedTileViewProperties(); void _SetText();
    void SetCurrentFolderFlags(uint mask, uint flags);
    void GetCurrentFolderFlags(out uint flags);
}

// Sets folder flags (FWF_*) on the live desktop view and returns the flags now in effect,
// or -1 if Explorer hasn't registered its desktop window yet.
public static long SetDesktopFolderFlags(uint mask, uint flags) {
    var windows = (IShellWindows)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39")));  // CLSID_ShellWindows
    object loc = 0, root = null, disp; int hwnd;   // loc 0 = CSIDL_DESKTOP
    if (windows.FindWindowSW(ref loc, ref root, 8, out hwnd, 1, out disp) != 0 || disp == null) return -1;  // 8 = SWC_DESKTOP, 1 = SWFO_NEEDDISPATCH
    Guid service = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837"), riid = typeof(IShellBrowser).GUID;  // SID_STopLevelBrowser
    var browser = (IShellBrowser)((IComServiceProvider)disp).QueryService(ref service, ref riid);
    var view = (IFolderView2)browser.QueryActiveShellView();
    view.SetCurrentFolderFlags(mask, flags);
    uint current; view.GetCurrentFolderFlags(out current);
    return current;
}
'@

    Start-Step 'Apply wallpaper + colour'
    # The registry values persist the choice; the API calls apply it now without a logoff.
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '0'   # 0 + TileWallpaper 0 = centre
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value "$($blue.R) $($blue.G) $($blue.B)"
    [Sandbox.Desktop]::SetSysColors(1, @(1), @($blue.R + ($blue.G -shl 8) + ($blue.B -shl 16))) | Out-Null  # 1 = COLOR_DESKTOP
    [Sandbox.Desktop]::SystemParametersInfo(0x14, 0, $wallpaper, 0x3) | Out-Null  # SPI_SETDESKWALLPAPER, save + broadcast

    Start-Step 'Recycle Bin confirmation'
    # Tick "Display delete confirmation dialog". A zeroed SHELLSTATE has fNoConfirmRecycle = 0,
    # and mask 0x8000 (SSF_NOCONFIRMRECYCLE) means only that field is written.
    [Sandbox.Desktop]::SHGetSetSettings((New-Object byte[] 64), 0x8000, $true)

    Start-Step 'Desktop auto-arrange'
    # Auto-arrange + align to grid, so icons stack from the top left. Written before Explorer is killed
    # (not closed), so Explorer can't overwrite it with its own saved view state on the way out. This alone
    # isn't reliable (Explorer may save its view state first), so it is also applied live after the restart.
    $desktopBag = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
    if (-not (Test-Path $desktopBag)) { New-Item -Path $desktopBag -Force | Out-Null }  # -Force on an existing key would wipe it
    New-ItemProperty -Path $desktopBag -Name FFlags -Value 0x40200225 -PropertyType DWord -Force | Out-Null  # 0x1 = auto-arrange

    Start-Step 'Restart Explorer (process back)'
    # Explorer restarts itself automatically after being stopped; wait for the new process so the timing
    # covers the restart and a scenario script calling this one doesn't race a missing shell.
    $oldExplorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | ForEach-Object Id)
    Stop-Process -Name explorer -Force
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $oldExplorer -notcontains $_.Id })) {
        if ((Get-Date) -gt $deadline) { throw 'Explorer did not restart within 30 seconds' }
        Start-Sleep -Milliseconds 50
    }

    Start-Step 'Desktop auto-arrange (live)'
    # Turn auto-arrange + align to grid on in the new Explorer's desktop view, so it doesn't depend on
    # Explorer reading the registry value above. The desktop window registers a moment after the process
    # starts, and COM calls can fail until it does, so retry until it's there.
    $arrange = 0x5   # FWF_AUTOARRANGE (0x1) | FWF_SNAPTOGRID (0x4)
    $deadline = (Get-Date).AddSeconds(30)
    $flags = -1
    while ($flags -lt 0) {
        try { $flags = [Sandbox.Desktop]::SetDesktopFolderFlags($arrange, $arrange) } catch { $flags = -1 }
        if ($flags -lt 0) {
            if ((Get-Date) -gt $deadline) { throw 'Explorer desktop view not available within 30 seconds' }
            Start-Sleep -Milliseconds 100
        }
    }
    if (($flags -band $arrange) -ne $arrange) { throw ('Auto-arrange not applied (desktop flags 0x{0:X8})' -f $flags) }

    Start-Step $null   # close the last step
}
catch {
    $failure = "FAILED in step '$currentStep': $_"
    Start-Step $null   # record how long the failing step ran before it threw
    throw
}
finally {
    Write-Log $failure
}
