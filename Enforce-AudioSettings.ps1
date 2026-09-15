#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Enforce', 'CaptureConfig', 'Check')]
    [string]$Mode = 'Enforce',

    [string]$ConfigPath = "C:\Skripts\AudioRecovery\AudioConfig.json",
    [string]$LogPath    = "C:\Logs\audio-enforce.csv",

    [switch]$SkipServiceRestart
)

# Parallele Ausführung verhindern (Mutex)
$mutexName = "Global\AudioEnforceHandler_Mutex"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Host "Ein anderer Lauf ist bereits aktiv – breche ab." -ForegroundColor Yellow
    exit 2
}

# Log-Verzeichnis anlegen + Log-Rotation
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 200KB)) {
    $archive = "$LogPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').old"
    Move-Item -Path $LogPath -Destination $archive -Force
}

# ===============================================================
# 0) CORE-AUDIO-API (per-device Lautstärke & Mute)
# ===============================================================
if (-not ('CoreAudioApiV4' -as [type])) {

Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class CoreAudioApiV4
{
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int pcDevices);
        [PreserveSig] int Item(int nDevice, out IMMDevice ppDevice);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid id, int clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr pNotify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr pNotify);
        [PreserveSig] int GetChannelCount(out int pnChannelCount);
        [PreserveSig] int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float pfLevelDB);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float pfLevel);
        [PreserveSig] int SetChannelVolumeLevel(uint nChannel, float fLevelDB, Guid pguidEventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, Guid pguidEventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
        [PreserveSig] int GetMute(out bool pbMute);
        [PreserveSig] int GetVolumeStepInfo(out uint pnStep, out uint pnStepCount);
        [PreserveSig] int VolumeStepUp(Guid pguidEventContext);
        [PreserveSig] int VolumeStepDown(Guid pguidEventContext);
        [PreserveSig] int QueryHardwareSupport(out uint pdwHardwareSupportMask);
        [PreserveSig] int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
    }

    private static IMMDeviceEnumerator CreateEnumerator()
    {
        var clsid   = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        var comType = Type.GetTypeFromCLSID(clsid);
        return (IMMDeviceEnumerator)Activator.CreateInstance(comType);
    }

    private static void SafeRelease(object comObject)
    {
        if (comObject != null && Marshal.IsComObject(comObject))
        {
            try { Marshal.ReleaseComObject(comObject); } catch { }
        }
    }

    public static float GetVolume(string deviceId)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object volObj = null;
        try
        {
            enumerator = CreateEnumerator();
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 0, IntPtr.Zero, out volObj);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            var v = (IAudioEndpointVolume)volObj;
            float level;
            hr = v.GetMasterVolumeLevelScalar(out level);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            return level * 100f;
        }
        finally
        {
            SafeRelease(volObj);
            SafeRelease(device);
            SafeRelease(enumerator);
        }
    }

    public static bool GetMute(string deviceId)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object volObj = null;
        try
        {
            enumerator = CreateEnumerator();
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 0, IntPtr.Zero, out volObj);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            var v = (IAudioEndpointVolume)volObj;
            bool muted;
            hr = v.GetMute(out muted);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            return muted;
        }
        finally
        {
            SafeRelease(volObj);
            SafeRelease(device);
            SafeRelease(enumerator);
        }
    }

    public static void SetVolume(string deviceId, float percent)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object volObj = null;
        try
        {
            enumerator = CreateEnumerator();
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 0, IntPtr.Zero, out volObj);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            var v = (IAudioEndpointVolume)volObj;
            hr = v.SetMasterVolumeLevelScalar(percent / 100f, Guid.Empty);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            SafeRelease(volObj);
            SafeRelease(device);
            SafeRelease(enumerator);
        }
    }

    public static void SetMute(string deviceId, bool mute)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object volObj = null;
        try
        {
            enumerator = CreateEnumerator();
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 0, IntPtr.Zero, out volObj);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            var v = (IAudioEndpointVolume)volObj;
            hr = v.SetMute(mute, Guid.Empty);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            SafeRelease(volObj);
            SafeRelease(device);
            SafeRelease(enumerator);
        }
    }

    public static System.Collections.Generic.List<string> GetAllDeviceIds(int dataFlow)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDeviceCollection collection = null;
        try
        {
            enumerator = CreateEnumerator();

            IntPtr collectionPtr;
            int hr = enumerator.EnumAudioEndpoints(dataFlow, 0x0000000F, out collectionPtr);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            collection = (IMMDeviceCollection)Marshal.GetObjectForIUnknown(collectionPtr);
            Marshal.Release(collectionPtr);

            int count;
            hr = collection.GetCount(out count);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);

            var ids = new System.Collections.Generic.List<string>();
            for (int i = 0; i < count; i++)
            {
                IMMDevice dev = null;
                try
                {
                    hr = collection.Item(i, out dev);
                    if (hr != 0) continue;
                    string id;
                    hr = dev.GetId(out id);
                    if (hr == 0) ids.Add(id);
                }
                finally
                {
                    SafeRelease(dev);
                }
            }
            return ids;
        }
        finally
        {
            SafeRelease(collection);
            SafeRelease(enumerator);
        }
    }

    public static int GetDeviceState(string deviceId)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        try
        {
            enumerator = CreateEnumerator();
            int hr = enumerator.GetDevice(deviceId, out device);
            if (hr != 0) return -1;

            int state;
            hr = device.GetState(out state);
            if (hr != 0) return -1;
            return state;
        }
        finally
        {
            SafeRelease(device);
            SafeRelease(enumerator);
        }
    }
}
"@
}


if (-not ('PolicyConfigClient' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class PolicyConfigClient
{
    [Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string pszDeviceName, IntPtr ppFormat);
        [PreserveSig] int GetDeviceFormat(string pszDeviceName, bool bDefault, IntPtr ppFormat);
        [PreserveSig] int ResetDeviceFormat(string pszDeviceName);
        [PreserveSig] int SetDeviceFormat(string pszDeviceName, IntPtr pEndpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod(string pszDeviceName, bool bDefault, IntPtr pmftDefaultPeriod, IntPtr pmftMinimumPeriod);
        [PreserveSig] int SetProcessingPeriod(string pszDeviceName, IntPtr pmftPeriod);
        [PreserveSig] int GetShareMode(string pszDeviceName, IntPtr pMode);
        [PreserveSig] int SetShareMode(string pszDeviceName, IntPtr mode);
        [PreserveSig] int GetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        [PreserveSig] int SetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        [PreserveSig] int SetDefaultEndpoint(string pszDeviceName, int role);
        [PreserveSig] int SetEndpointVisibility(string pszDeviceName, bool bVisible);
    }

    public static bool SetVisibility(string deviceId, bool visible)
    {
        object clientObj = null;
        try
        {
            var clsid   = new Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9");
            var comType = Type.GetTypeFromCLSID(clsid);
            clientObj   = Activator.CreateInstance(comType);
            var client  = (IPolicyConfig)clientObj;

            int hr = client.SetEndpointVisibility(deviceId, visible);
            return hr == 0;
        }
        finally
        {
            if (clientObj != null && Marshal.IsComObject(clientObj))
            {
                try { Marshal.ReleaseComObject(clientObj); } catch { }
            }
        }
    }
}
"@
}

# ===============================================================
# 0b) PRIVILEGE-HELPER (SeTakeOwnershipPrivilege etc. aktivieren)
# ===============================================================
if (-not ('PrivilegeHelper' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class PrivilegeHelper
{
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const uint TOKEN_QUERY = 0x0008;
    const uint SE_PRIVILEGE_ENABLED = 0x0002;

    public static bool Enable(string privilegeName)
    {
        IntPtr hToken = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hToken))
                return false;

            LUID luid;
            if (!LookupPrivilegeValue(null, privilegeName, out luid))
                return false;

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;

            return AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally
        {
            if (hToken != IntPtr.Zero) CloseHandle(hToken);
        }
    }
}
"@
}

# ===============================================================
# 1) HILFSFUNKTIONEN
# ===============================================================
function Write-Log {
    param([string]$Message, [string]$Status = "INFO")
    $entry = [pscustomobject]@{
        Zeitpunkt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Status    = $Status
        Meldung   = $Message
    }
    Write-Host "[$Status] $Message"
    if ($LogPath) {
        try {
            $entry | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
        } catch {
            Write-Host "Log konnte nicht geschrieben werden: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Set-ProtectedRegistryValue {
    param(
        [Parameter(Mandatory=$true)][string]$SubKeyPath,
        [Parameter(Mandatory=$true)][string]$ValueName,
        [Parameter(Mandatory=$true)]$Value,
        [Microsoft.Win32.RegistryValueKind]$ValueKind = [Microsoft.Win32.RegistryValueKind]::String
    )

    [void][PrivilegeHelper]::Enable("SeTakeOwnershipPrivilege")
    [void][PrivilegeHelper]::Enable("SeRestorePrivilege")
    [void][PrivilegeHelper]::Enable("SeBackupPrivilege")

    $hklm   = [Microsoft.Win32.Registry]::LocalMachine
    $admins = New-Object System.Security.Principal.SecurityIdentifier(
                  [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

    $addedRule = $null
    try {
        $ownerKey = $hklm.OpenSubKey($SubKeyPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if (-not $ownerKey) { throw "Registry-Schlüssel nicht gefunden: HKLM\$SubKeyPath" }

        $ownAcl = New-Object System.Security.AccessControl.RegistrySecurity
        $ownAcl.SetOwner($admins)
        $ownerKey.SetAccessControl($ownAcl)
        $ownerKey.Close()

        $permKey = $hklm.OpenSubKey($SubKeyPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        $permAcl = $permKey.GetAccessControl()
        $addedRule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $permAcl.SetAccessRule($addedRule)
        $permKey.SetAccessControl($permAcl)
        $permKey.Close()

        $writeKey = $hklm.OpenSubKey($SubKeyPath, $true)
        $writeKey.SetValue($ValueName, $Value, $ValueKind)
        $writeKey.Close()

        return $true
    }
    catch {
        Write-Log "FEHLER beim Schreiben von HKLM\$SubKeyPath [$ValueName]: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        if ($addedRule) {
            try {
                $cleanupKey = $hklm.OpenSubKey($SubKeyPath,
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [System.Security.AccessControl.RegistryRights]::ChangePermissions)
                if ($cleanupKey) {
                    $cleanupAcl = $cleanupKey.GetAccessControl()
                    [void]$cleanupAcl.RemoveAccessRule($addedRule)
                    $cleanupKey.SetAccessControl($cleanupAcl)
                    $cleanupKey.Close()
                }
            } catch {
                Write-Log "WARNUNG: Eigene ACE konnte nicht entfernt werden: $($_.Exception.Message)" "WARN"
            }
        }
    }
}

function Set-AudioEndpointFriendlyName {
    param(
        [Parameter(Mandatory=$true)][string]$DeviceId,
        [Parameter(Mandatory=$true)][string]$NewName,
        [Parameter(Mandatory=$true)][ValidateSet('Render','Capture')][string]$Flow
    )

    try {
        $guid = $DeviceId.Substring($DeviceId.LastIndexOf('.') + 1)
        $mmDevicesPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$Flow\$guid\Properties"
        $propOk = Set-ProtectedRegistryValue -SubKeyPath $mmDevicesPath `
            -ValueName '{a45c254e-df1c-4efd-8020-67d146a850e0},2' `
            -Value $NewName -ValueKind String

        if ($propOk) {
            Write-Log "Properties-Key ($Flow) für '$DeviceId' auf '$NewName' gesetzt." "INFO"
            return $true
        } else {
            Write-Log "Properties-Key ($Flow) für '$DeviceId' konnte NICHT gesetzt werden." "WARN"
            return $false
        }
    } catch {
        Write-Log "FEHLER beim Setzen des Registry-Namens für '$DeviceId': $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# --- Volume & Mute pro Gerät über die Core-Audio-API ---
function Get-PerDeviceVolume {
    param([string]$DeviceId)
    try {
        return [math]::Round([CoreAudioApiV4]::GetVolume($DeviceId), 0)
    } catch {
        Write-Log "Volume für ID '$DeviceId' nicht lesbar: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Get-PerDeviceMute {
    param([string]$DeviceId)
    try {
        return [CoreAudioApiV4]::GetMute($DeviceId)
    } catch {
        Write-Log "Mute-Status für ID '$DeviceId' nicht lesbar: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Set-PerDeviceVolume {
    param([string]$DeviceId, [int]$Percent)
    try {
        [CoreAudioApiV4]::SetVolume($DeviceId, [float]$Percent)
        return $true
    } catch {
        Write-Log "Setzen der Lautstärke für ID '$DeviceId' fehlgeschlagen: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Set-PerDeviceMute {
    param([string]$DeviceId, [bool]$Mute)
    try {
        [CoreAudioApiV4]::SetMute($DeviceId, $Mute)
        return $true
    } catch {
        Write-Log "Setzen des Mute-Status für ID '$DeviceId' fehlgeschlagen: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Convert-ToRoundedNumber {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [decimal]) {
        return [math]::Round([double]$Value, 0)
    }
    $clean = [string]$Value
    $clean = $clean -replace '%', ''
    $clean = $clean.Trim()
    $clean = $clean -replace ',', '.'
    $number = $null
    if ([double]::TryParse($clean,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$number)) {
        return [math]::Round($number, 0)
    }
    if ([double]::TryParse($clean, [ref]$number)) {
        return [math]::Round($number, 0)
    }
    return $null
}

# Entfernt den von Windows automatisch angehängten Adapter-Suffix " (...)" vom Gerätenamen.
function Get-ShortDeviceName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }

    return ($Name -replace '\s*\([^()]*\)\s*$', '').Trim()
}


# ===============================================================
# Config-Reparatur nach Windows-Update
# ===============================================================
function Repair-ConfigDeviceIds {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)]$CurrentPlayback,
        [Parameter(Mandatory=$true)]$CurrentRecording,
        [Parameter(Mandatory=$true)]$AllPlaybackIds,
        [Parameter(Mandatory=$true)]$AllRecordingIds
    )

    $repairs = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[object]]::new()

    # --- Wiedergabegeräte prüfen ---
    foreach ($allowed in $Config.AllowedPlaybackDevices) {
        $current = $CurrentPlayback | Where-Object { $_.ID -eq $allowed.ID }
        if ($current) { continue }

        $byName = $CurrentPlayback | Where-Object {
            (Get-ShortDeviceName $_.Name) -eq $allowed.Name -and
            $_.ID -notin $Config.AllowedPlaybackDevices.ID
        } | Select-Object -First 1

        if ($byName) {
            $repairs.Add([pscustomobject]@{
                Typ     = 'Playback'
                Name    = $allowed.Name
                AlteID  = $allowed.ID
                NeueID  = $byName.ID
                Methode = 'Name-Match'
            })
            $allowed.ID = $byName.ID
            continue
        }

        $missing.Add([pscustomobject]@{
            Typ  = 'Playback'
            Name = $allowed.Name
            ID   = $allowed.ID
        })
    }

    # --- Aufnahmegeräte prüfen ---
    foreach ($allowed in $Config.AllowedRecordingDevices) {
        $current = $CurrentRecording | Where-Object { $_.ID -eq $allowed.ID }
        if ($current) { continue }

        $byName = $CurrentRecording | Where-Object {
            (Get-ShortDeviceName $_.Name) -eq $allowed.Name -and
            $_.ID -notin $Config.AllowedRecordingDevices.ID
        } | Select-Object -First 1

        if ($byName) {
            $repairs.Add([pscustomobject]@{
                Typ     = 'Recording'
                Name    = $allowed.Name
                AlteID  = $allowed.ID
                NeueID  = $byName.ID
                Methode = 'Name-Match'
            })
            $allowed.ID = $byName.ID
            continue
        }

        $missing.Add([pscustomobject]@{
            Typ  = 'Recording'
            Name = $allowed.Name
            ID   = $allowed.ID
        })
    }

    # --- Deaktivierte Wiedergabegeräte ---
    if ($Config.PSObject.Properties.Name -contains 'DisabledPlaybackDevices' -and $Config.DisabledPlaybackDevices) {
        foreach ($disabled in $Config.DisabledPlaybackDevices) {
            # FIX: Existenz gegen Registry-Liste prüfen (Disabled-Geräte sind absichtlich unsichtbar)
            if ($disabled.ID -in $AllPlaybackIds) { continue }

            $byName = $CurrentPlayback | Where-Object {
                (Get-ShortDeviceName $_.Name) -eq $disabled.Name -and
                $_.ID -notin $Config.AllowedPlaybackDevices.ID -and
                $_.ID -notin @($Config.DisabledPlaybackDevices.ID)
            } | Select-Object -First 1

            if ($byName) {
                $repairs.Add([pscustomobject]@{
                    Typ     = 'Disabled-Playback'
                    Name    = $disabled.Name
                    AlteID  = $disabled.ID
                    NeueID  = $byName.ID
                    Methode = 'Name-Match'
                })
                $disabled.ID = $byName.ID
                continue
            }

            $missing.Add([pscustomobject]@{
                Typ  = 'Disabled-Playback'
                Name = $disabled.Name
                ID   = $disabled.ID
            })
        }
    }

    # --- Deaktivierte Aufnahmegeräte ---
    if ($Config.PSObject.Properties.Name -contains 'DisabledRecordingDevices' -and $Config.DisabledRecordingDevices) {
        foreach ($disabled in $Config.DisabledRecordingDevices) {
            # FIX: Existenz gegen Registry-Liste prüfen
            if ($disabled.ID -in $AllRecordingIds) { continue }

            $byName = $CurrentRecording | Where-Object {
                (Get-ShortDeviceName $_.Name) -eq $disabled.Name -and
                $_.ID -notin $Config.AllowedRecordingDevices.ID -and
                $_.ID -notin @($Config.DisabledRecordingDevices.ID)
            } | Select-Object -First 1

            if ($byName) {
                $repairs.Add([pscustomobject]@{
                    Typ     = 'Disabled-Recording'
                    Name    = $disabled.Name
                    AlteID  = $disabled.ID
                    NeueID  = $byName.ID
                    Methode = 'Name-Match'
                })
                $disabled.ID = $byName.ID
                continue
            }

            $missing.Add([pscustomobject]@{
                Typ  = 'Disabled-Recording'
                Name = $disabled.Name
                ID   = $disabled.ID
            })
        }
    }

    # --- Exception Wiedergabegeräte ---
    if ($Config.PSObject.Properties.Name -contains 'ExceptionPlaybackDevices' -and $Config.ExceptionPlaybackDevices) {
        foreach ($exception in $Config.ExceptionPlaybackDevices) {
            # FIX: Existenz gegen Registry-Liste prüfen
            if ($exception.ID -in $AllPlaybackIds) { continue }

            $byName = $CurrentPlayback | Where-Object {
                (Get-ShortDeviceName $_.Name) -eq $exception.Name -and
                $_.ID -notin $Config.AllowedPlaybackDevices.ID -and
                $_.ID -notin @($Config.ExceptionPlaybackDevices.ID)
            } | Select-Object -First 1

            if ($byName) {
                $repairs.Add([pscustomobject]@{
                    Typ     = 'Exception-Playback'
                    Name    = $exception.Name
                    AlteID  = $exception.ID
                    NeueID  = $byName.ID
                    Methode = 'Name-Match'
                })
                $exception.ID = $byName.ID
            }
            # Missing-Einträge für Exceptions NICHT hinzufügen – sie sind unkritisch.
        }
    }

    # --- Exception Aufnahmegeräte ---
    if ($Config.PSObject.Properties.Name -contains 'ExceptionRecordingDevices' -and $Config.ExceptionRecordingDevices) {
        foreach ($exception in $Config.ExceptionRecordingDevices) {
            # FIX: Existenz gegen Registry-Liste prüfen
            if ($exception.ID -in $AllRecordingIds) { continue }

            $byName = $CurrentRecording | Where-Object {
                (Get-ShortDeviceName $_.Name) -eq $exception.Name -and
                $_.ID -notin $Config.AllowedRecordingDevices.ID -and
                $_.ID -notin @($Config.ExceptionRecordingDevices.ID)
            } | Select-Object -First 1

            if ($byName) {
                $repairs.Add([pscustomobject]@{
                    Typ     = 'Exception-Recording'
                    Name    = $exception.Name
                    AlteID  = $exception.ID
                    NeueID  = $byName.ID
                    Methode = 'Name-Match'
                })
                $exception.ID = $byName.ID
            }
        }
    }

    return [pscustomobject]@{
        Config  = $Config
        Repairs = $repairs
        Missing = $missing
    }
}

# ===============================================================
# Notfall-Wiederherstellung: macht ALLE Endpoints sichtbar
# ===============================================================
function Enable-AllAudioEndpoints {
    Write-Log "--- NOTFALL: Keine Audio-Geräte sichtbar. Mache alle Endpoints sichtbar. ---" "WARN"

    $playbackIds  = [CoreAudioApiV4]::GetAllDeviceIds(0)
    $recordingIds = [CoreAudioApiV4]::GetAllDeviceIds(1)

    Write-Log "In der Registry registrierte Playback-Endpoints : $($playbackIds.Count)" "INFO"
    Write-Log "In der Registry registrierte Recording-Endpoints: $($recordingIds.Count)" "INFO"

    if ($playbackIds.Count -eq 0 -and $recordingIds.Count -eq 0) {
        Write-Log "Auch in der Registry keine Endpoints gefunden – Audio-Stack möglicherweise nicht initialisiert." "ERROR"
        return $false
    }

    $ok = 0
    $fail = 0
    foreach ($id in $playbackIds) {
        if ([PolicyConfigClient]::SetVisibility($id, $true)) { $ok++ } else { $fail++ }
    }
    foreach ($id in $recordingIds) {
        if ([PolicyConfigClient]::SetVisibility($id, $true)) { $ok++ } else { $fail++ }
    }

    Write-Log "$ok Endpoints wieder sichtbar gemacht, $fail Fehler." "INFO"

    try {
        Restart-Service Audiosrv, AudioEndpointBuilder -Force -ErrorAction Stop
        Write-Log "Audio-Dienste neu gestartet." "OK"
    } catch {
        Write-Log "FEHLER beim Neustart der Audio-Dienste: $($_.Exception.Message)" "ERROR"
    }

    return $true
}


# ===============================================================
# 2) MODUL PRÜFEN
# ===============================================================
if (-not (Get-Module -ListAvailable -Name AudioDeviceCmdlets)) {
    Write-Log "FEHLER: Modul 'AudioDeviceCmdlets' ist nicht installiert. Bitte mit 'Install-Module AudioDeviceCmdlets -Scope AllUsers' nachinstallieren." "ERROR"
    $mutex.ReleaseMutex()
    exit 1
}
Import-Module AudioDeviceCmdlets -ErrorAction Stop

# ===============================================================
# 3) KONFIGURATION LADEN ODER ERSTELLEN
# ===============================================================
if ($Mode -eq 'CaptureConfig' -or -not (Test-Path $ConfigPath)) {

    if (-not (Test-Path $ConfigPath)) {
        Write-Log "Keine Konfiguration gefunden. Erstelle neue Konfiguration." "INFO"
    } else {
        Write-Log "Modus 'CaptureConfig': Erfasse aktuellen Zustand als neuen Soll-Zustand." "INFO"
    }

    # --- Sichtbare Geräte (Allowed) ---
    $visibleNow       = Get-AudioDevice -List
    $visiblePlayback  = @($visibleNow | Where-Object { $_.Type -eq 'Playback' })
    $visibleRecording = @($visibleNow | Where-Object { $_.Type -eq 'Recording' })

    $visiblePlaybackIds  = @($visiblePlayback  | ForEach-Object { $_.ID })
    $visibleRecordingIds = @($visibleRecording | ForEach-Object { $_.ID })

    Write-Log "Sichtbar: $($visiblePlayback.Count) Playback, $($visibleRecording.Count) Recording" "INFO"

    # --- Alle Endpoints aus der Registry (inkl. unsichtbarer, nicht angeschlossener) ---
    $allPlaybackIds  = @([CoreAudioApiV4]::GetAllDeviceIds(0))
    $allRecordingIds = @([CoreAudioApiV4]::GetAllDeviceIds(1))

    Write-Log "In Registry registriert: $($allPlaybackIds.Count) Playback, $($allRecordingIds.Count) Recording" "INFO"

    # --- Disabled = alles in der Registry, das NICHT sichtbar ist ---
    $hiddenPlaybackIds  = @($allPlaybackIds  | Where-Object { $_ -notin $visiblePlaybackIds })
    $hiddenRecordingIds = @($allRecordingIds | Where-Object { $_ -notin $visibleRecordingIds })

    Write-Log "Als deaktiviert erkannt: $($hiddenPlaybackIds.Count) Playback, $($hiddenRecordingIds.Count) Recording" "INFO"

    # --- PnP-Endpoints cachen (für Namen der unsichtbaren Geräte) ---
    $cachedPnpEndpoints = Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue

    # --- Default-Geräte ---
    $defaultPlayback  = Get-AudioDevice -Playback
    $defaultRecording = Get-AudioDevice -Recording

    $config = [pscustomobject]@{
        CreatedAt                 = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        DefaultPlaybackDeviceID   = $defaultPlayback.ID
        DefaultPlaybackDeviceName = Get-ShortDeviceName $defaultPlayback.Name
        DefaultRecordingDeviceID  = $defaultRecording.ID
        DefaultRecordingDeviceName= Get-ShortDeviceName $defaultRecording.Name
        DefaultPlaybackVolume     = Get-PerDeviceVolume -DeviceId $defaultPlayback.ID
        DefaultRecordingVolume    = Get-PerDeviceVolume -DeviceId $defaultRecording.ID
        AllowedPlaybackDevices    = @()
        AllowedRecordingDevices   = @()
        DisabledPlaybackDevices   = @()
        DisabledRecordingDevices  = @()
        ExceptionPlaybackDevices  = @()
        ExceptionRecordingDevices = @()
    }

    # --- Allowed aus sichtbaren Geräten ---
    foreach ($dev in $visiblePlayback) {
        $config.AllowedPlaybackDevices += [pscustomobject]@{
            ID     = $dev.ID
            Name   = Get-ShortDeviceName $dev.Name
            Volume = Get-PerDeviceVolume -DeviceId $dev.ID
            Muted  = Get-PerDeviceMute   -DeviceId $dev.ID
        }
    }
    foreach ($dev in $visibleRecording) {
        $config.AllowedRecordingDevices += [pscustomobject]@{
            ID     = $dev.ID
            Name   = Get-ShortDeviceName $dev.Name
            Volume = Get-PerDeviceVolume -DeviceId $dev.ID
            Muted  = Get-PerDeviceMute   -DeviceId $dev.ID
        }
    }

    # --- Disabled aus Registry-Differenz ---
    foreach ($id in $hiddenPlaybackIds) {
        $pnp  = $cachedPnpEndpoints | Where-Object { $_.InstanceId -like "*$id*" } | Select-Object -First 1
        $name = if ($pnp) { Get-ShortDeviceName $pnp.FriendlyName } else { $id }
        $config.DisabledPlaybackDevices += [pscustomobject]@{
            ID   = $id
            Name = $name
        }
    }
    foreach ($id in $hiddenRecordingIds) {
        $pnp  = $cachedPnpEndpoints | Where-Object { $_.InstanceId -like "*$id*" } | Select-Object -First 1
        $name = if ($pnp) { Get-ShortDeviceName $pnp.FriendlyName } else { $id }
        $config.DisabledRecordingDevices += [pscustomobject]@{
            ID   = $id
            Name = $name
        }
    }

    $config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Log "Config gespeichert: Allowed-P=$($config.AllowedPlaybackDevices.Count), Allowed-R=$($config.AllowedRecordingDevices.Count), Disabled-P=$($config.DisabledPlaybackDevices.Count), Disabled-R=$($config.DisabledRecordingDevices.Count)" "INFO"

    if ($Mode -eq 'CaptureConfig') {
        Write-Log "Soll-Zustand erfasst. Beende." "INFO"
        $mutex.ReleaseMutex()
        exit 0
    }
}

try {
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    Write-Log "Konfiguration geladen (erstellt am $($config.CreatedAt))." "INFO"
} catch {
    Write-Log "FEHLER beim Laden der Konfiguration: $($_.Exception.Message)" "ERROR"
    $mutex.ReleaseMutex()
    exit 1
}

# ===============================================================
# 4) IST-ZUSTAND ERFASSEN + CONFIG-REPARATUR
# ===============================================================
$allDevices       = Get-AudioDevice -List
$playbackDevices  = $allDevices | Where-Object { $_.Type -eq 'Playback' }
$recordingDevices = $allDevices | Where-Object { $_.Type -eq 'Recording' }

# --- PRE-ENABLE ---
function Test-ConfigDevicesVisible {
    param($Playback, $Recording, $Config)

    $currentPlaybackNames  = @($Playback  | ForEach-Object { Get-ShortDeviceName $_.Name })
    $currentRecordingNames = @($Recording | ForEach-Object { Get-ShortDeviceName $_.Name })

    $missingPlayback  = @($Config.AllowedPlaybackDevices  |
                          Where-Object { $_.Name -notin $currentPlaybackNames })
    $missingRecording = @($Config.AllowedRecordingDevices |
                          Where-Object { $_.Name -notin $currentRecordingNames })

    return [pscustomobject]@{
        MissingPlayback  = $missingPlayback
        MissingRecording = $missingRecording
        TotalMissing     = $missingPlayback.Count + $missingRecording.Count
    }
}

# Prüft, ob Config-IDs überhaupt noch im System existieren (Registry-basiert).
function Test-AnyConfigIdStale {
    param($Config)

    $allPb = [CoreAudioApiV4]::GetAllDeviceIds(0)
    $allRc = [CoreAudioApiV4]::GetAllDeviceIds(1)

    $stalePb = 0
    $staleRc = 0

    foreach ($d in $Config.AllowedPlaybackDevices) {
        if ($d.ID -notin $allPb) { $stalePb++ }
    }
    foreach ($d in $Config.AllowedRecordingDevices) {
        if ($d.ID -notin $allRc) { $staleRc++ }
    }
    if ($Config.PSObject.Properties.Name -contains 'DisabledPlaybackDevices' -and $Config.DisabledPlaybackDevices) {
        foreach ($d in $Config.DisabledPlaybackDevices) {
            if ($d -and $d.ID -notin $allPb) { $stalePb++ }
        }
    }
    if ($Config.PSObject.Properties.Name -contains 'DisabledRecordingDevices' -and $Config.DisabledRecordingDevices) {
        foreach ($d in $Config.DisabledRecordingDevices) {
            if ($d -and $d.ID -notin $allRc) { $staleRc++ }
        }
    }

    if ($Config.PSObject.Properties.Name -contains 'ExceptionPlaybackDevices' -and $Config.ExceptionPlaybackDevices) {
        foreach ($d in $Config.ExceptionPlaybackDevices) {
            if ($d -and $d.ID -notin $allPb) { $stalePb++ }
        }
    }
    if ($Config.PSObject.Properties.Name -contains 'ExceptionRecordingDevices' -and $Config.ExceptionRecordingDevices) {
        foreach ($d in $Config.ExceptionRecordingDevices) {
            if ($d -and $d.ID -notin $allRc) { $staleRc++ }
        }
    }

    return [pscustomobject]@{
        StalePlayback  = $stalePb
        StaleRecording = $staleRc
        Total          = $stalePb + $staleRc
    }
}

$visibility = Test-ConfigDevicesVisible -Playback $playbackDevices `
    -Recording $recordingDevices -Config $config

$staleCheck = Test-AnyConfigIdStale -Config $config

$needsEnable = ($visibility.TotalMissing -gt 0) -or ($staleCheck.Total -gt 0)

if ($needsEnable) {
    if ($staleCheck.Total -gt 0) {
        Write-Log "PRE-ENABLE: $($staleCheck.Total) stale Config-IDs erkannt (Allowed+Disabled+Exception)." "WARN"
    }
    if ($visibility.TotalMissing -gt 0) {
        Write-Log "PRE-ENABLE: $($visibility.TotalMissing) Config-Geräte aktuell nicht sichtbar." "WARN"
    }
    Write-Log "PRE-ENABLE: Mache alle Endpoints sichtbar, damit die Reparatur arbeiten kann." "WARN"

    $recovered = Enable-AllAudioEndpoints

        if ($recovered) {
        $retries    = 0
        $waitMs     = 200
        $lastCount  = -1
        $stableRuns = 0

        while ($retries -lt 15) {
            Start-Sleep -Milliseconds $waitMs

            $allDevices       = Get-AudioDevice -List
            $playbackDevices  = $allDevices | Where-Object { $_.Type -eq 'Playback' }
            $recordingDevices = $allDevices | Where-Object { $_.Type -eq 'Recording' }

            $currentCount = $playbackDevices.Count + $recordingDevices.Count

            # Ausstieg, sobald die Geräte-Anzahl 2x hintereinander gleich ist
            if ($currentCount -eq $lastCount) {
                $stableRuns++
                if ($stableRuns -ge 2) { break }
            } else {
                $stableRuns = 0
                $lastCount  = $currentCount
            }

            $retries++

            # Progressives Warten: 200 → 400 → 800 → 1000 → 1000 ... (max 1 s)
            $waitMs = [Math]::Min($waitMs * 2, 1000)
        }

        # Nach der Loop: Aktuellen Visibility-Status einmal frisch auswerten
        $visibility = Test-ConfigDevicesVisible -Playback $playbackDevices `
            -Recording $recordingDevices -Config $config

        Write-Log "PRE-ENABLE: Nach Wiederherstellung: $($visibility.TotalMissing) Namen fehlend, $($staleCheck.Total) IDs stale." "INFO"
        Write-Log "PRE-ENABLE: Playback=$($playbackDevices.Count), Recording=$($recordingDevices.Count) sichtbar." "INFO"
    } else {
        Write-Log "PRE-ENABLE: Wiederherstellung fehlgeschlagen." "ERROR"
    }
} else {
    Write-Log "PRE-ENABLE: Alle Config-Geräte (Allowed+Disabled+Exception) sind gültig und sichtbar." "OK"
}

# --- Config-Reparatur aufrufen ---
# Registry-basierte Gesamtliste für Existenz-Check (inkl. unsichtbarer)
$allPlaybackIdsForRepair  = @([CoreAudioApiV4]::GetAllDeviceIds(0))
$allRecordingIdsForRepair = @([CoreAudioApiV4]::GetAllDeviceIds(1))

$repairResult = Repair-ConfigDeviceIds -Config $config `
    -CurrentPlayback $playbackDevices `
    -CurrentRecording $recordingDevices `
    -AllPlaybackIds  $allPlaybackIdsForRepair `
    -AllRecordingIds $allRecordingIdsForRepair

if ($repairResult.Repairs.Count -gt 0) {
    Write-Log "--- Config-Reparatur: $($repairResult.Repairs.Count) IDs aktualisiert ---" "INFO"
    foreach ($r in $repairResult.Repairs) {
        Write-Log "[$($r.Typ)] '$($r.Name)' : $($r.AlteID) -> $($r.NeueID) ($($r.Methode))" "CHANGED"
    }
    $repairResult.Config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Log "Konfiguration mit korrigierten IDs gespeichert." "INFO"
}

if ($repairResult.Missing.Count -gt 0) {
    # FIX: Exception-Typen werden wie Disabled behandelt (unkritisch)
    $missingAllowed   = @($repairResult.Missing | Where-Object { $_.Typ -notmatch '^(Disabled|Exception)-' })
    $missingDisabled  = @($repairResult.Missing | Where-Object { $_.Typ -match    '^(Disabled|Exception)-' })

    if ($missingAllowed.Count -gt 0) {
        Write-Log "--- Config-Reparatur: $($missingAllowed.Count) Allowed-Geräte nicht zuordenbar ---" "WARN"
        foreach ($m in $missingAllowed) {
            Write-Log "[$($m.Typ)] '$($m.Name)' (ID: $($m.ID)) existiert nicht mehr." "WARN"
        }
    }

    if ($missingDisabled.Count -gt 0) {
        Write-Log "--- Config-Reparatur: $($missingDisabled.Count) Disabled/Exception-Geräte nicht mehr vorhanden (normal) ---" "INFO"
        foreach ($m in $missingDisabled) {
            Write-Log "[$($m.Typ)] '$($m.Name)' (ID: $($m.ID)) nicht mehr im System – Eintrag wird ignoriert." "INFO"
        }
    }
}

$config = $repairResult.Config
$allowedPlaybackIDs  = $config.AllowedPlaybackDevices  | ForEach-Object { $_.ID }
$allowedRecordingIDs = $config.AllowedRecordingDevices | ForEach-Object { $_.ID }

# --- Sicherheitsbremse ---
# Nur Allowed-Devices zählen – Disabled/Exception-Devices dürfen "verschwinden"
$totalAllowed       = $config.AllowedPlaybackDevices.Count + $config.AllowedRecordingDevices.Count
# FIX: Exception-Typen ebenfalls aus der Bremse ausschließen
$missingAllowedOnly = @($repairResult.Missing |
                        Where-Object { $_.Typ -notmatch '^(Disabled|Exception)-' }).Count

if ($totalAllowed -gt 0 -and $missingAllowedOnly -ge [math]::Ceiling($totalAllowed / 2)) {
    Write-Log "SICHERHEITSBREMSE: $missingAllowedOnly von $totalAllowed Allowed-Geräten nicht zuordenbar." "ERROR"
    Write-Log "Deaktivierung wird NICHT ausgeführt. Bitte -Mode CaptureConfig neu einfrieren." "ERROR"
    $mutex.ReleaseMutex()
    exit 3
}

# PnP-Endpoints einmalig cachen
$cachedPnpEndpoints = Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue

$changes = [System.Collections.Generic.List[object]]::new()

function Add-Change {
    param([string]$Kategorie, [string]$Detail, [string]$Status = "CHANGED")
    $entry = [pscustomobject]@{
        Kategorie = $Kategorie
        Detail    = $Detail
        Status    = $Status
    }
    $changes.Add($entry)
    Write-Log "$Kategorie : $Detail" $Status
}

# ===============================================================
# 5) STANDARD-WIEDERGABEGERÄT PRÜFEN
# ===============================================================
$currentDefaultPlayback = Get-AudioDevice -Playback -ErrorAction SilentlyContinue

$expectedPlaybackId = $config.DefaultPlaybackDeviceID
$configChanged = $false

$repairedPlayback = $repairResult.Repairs | Where-Object {
    $_.Typ -eq 'Playback' -and $_.AlteID -eq $expectedPlaybackId
} | Select-Object -First 1
if ($repairedPlayback) {
    $expectedPlaybackId = $repairedPlayback.NeueID
    Write-Log "DefaultPlaybackDeviceID via Repair aktualisiert: $($repairedPlayback.AlteID) -> $expectedPlaybackId" "INFO"
    $config.DefaultPlaybackDeviceID = $expectedPlaybackId
    $configChanged = $true
}

$allowedMatch = $config.AllowedPlaybackDevices | Where-Object {
    $_.Name -eq $config.DefaultPlaybackDeviceName
} | Select-Object -First 1
if ($allowedMatch -and $allowedMatch.ID -ne $expectedPlaybackId) {
    Write-Log "DefaultPlaybackDeviceID via Name-Match ('$($config.DefaultPlaybackDeviceName)') korrigiert: $expectedPlaybackId -> $($allowedMatch.ID)" "INFO"
    $expectedPlaybackId = $allowedMatch.ID
    $config.DefaultPlaybackDeviceID = $expectedPlaybackId
    $configChanged = $true
}

if ($configChanged) {
    $config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Log "Config mit korrigierter DefaultPlaybackDeviceID gespeichert." "INFO"
}

if ($null -eq $currentDefaultPlayback) {
    Write-Log "Playback-Default: Kein Standardgerät ermittelbar." "WARN"
} elseif ($currentDefaultPlayback.ID -ne $expectedPlaybackId) {
    Add-Change "Playback-Default" "'$(Get-ShortDeviceName $currentDefaultPlayback.Name)' -> soll '$($config.DefaultPlaybackDeviceName)'"
    if ($Mode -eq 'Enforce') {
        try {
            Set-AudioDevice -ID $expectedPlaybackId -ErrorAction Stop
            Add-Change "Playback-Default" "Zurückgesetzt auf '$($config.DefaultPlaybackDeviceName)'"
        } catch {
            Add-Change "Playback-Default" "FEHLER beim Zurücksetzen: $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    Write-Log "Playback-Default OK: '$(Get-ShortDeviceName $currentDefaultPlayback.Name)'" "OK"
}

# ===============================================================
# 6) STANDARD-AUFNAHMEGERÄT PRÜFEN
# ===============================================================
$currentDefaultRecording = Get-AudioDevice -Recording -ErrorAction SilentlyContinue

$expectedRecordingId = $config.DefaultRecordingDeviceID
$configChanged = $false

$repairedRecording = $repairResult.Repairs | Where-Object {
    $_.Typ -eq 'Recording' -and $_.AlteID -eq $expectedRecordingId
} | Select-Object -First 1
if ($repairedRecording) {
    $expectedRecordingId = $repairedRecording.NeueID
    Write-Log "DefaultRecordingDeviceID via Repair aktualisiert: $($repairedRecording.AlteID) -> $expectedRecordingId" "INFO"
    $config.DefaultRecordingDeviceID = $expectedRecordingId
    $configChanged = $true
}

$allowedMatch = $config.AllowedRecordingDevices | Where-Object {
    $_.Name -eq $config.DefaultRecordingDeviceName
} | Select-Object -First 1
if ($allowedMatch -and $allowedMatch.ID -ne $expectedRecordingId) {
    Write-Log "DefaultRecordingDeviceID via Name-Match ('$($config.DefaultRecordingDeviceName)') korrigiert: $expectedRecordingId -> $($allowedMatch.ID)" "INFO"
    $expectedRecordingId = $allowedMatch.ID
    $config.DefaultRecordingDeviceID = $expectedRecordingId
    $configChanged = $true
}

if ($configChanged) {
    $config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Log "Config mit korrigierter DefaultRecordingDeviceID gespeichert." "INFO"
}

if ($null -eq $currentDefaultRecording) {
    Write-Log "Recording-Default: Kein Standardgerät ermittelbar." "WARN"
} elseif ($currentDefaultRecording.ID -ne $expectedRecordingId) {
    Add-Change "Recording-Default" "'$(Get-ShortDeviceName $currentDefaultRecording.Name)' -> soll '$($config.DefaultRecordingDeviceName)'"
    if ($Mode -eq 'Enforce') {
        try {
            Set-AudioDevice -ID $expectedRecordingId -ErrorAction Stop
            Add-Change "Recording-Default" "Zurückgesetzt auf '$($config.DefaultRecordingDeviceName)'"
        } catch {
            Add-Change "Recording-Default" "FEHLER beim Zurücksetzen: $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    Write-Log "Recording-Default OK: '$(Get-ShortDeviceName $currentDefaultRecording.Name)'" "OK"
}

# ===============================================================
# 7) LAUTSTÄRKE & MUTE FÜR ALLE ERLAUBTEN GERÄTE PRÜFEN
# ===============================================================
Write-Log "--- Prüfe Wiedergabegeräte ---" "INFO"
foreach ($allowed in $config.AllowedPlaybackDevices) {

    $current = $playbackDevices | Where-Object { $_.ID -eq $allowed.ID }
    if (-not $current) {
        Write-Log "Wiedergabegerät '$($allowed.Name)' nicht (mehr) vorhanden – überspringe." "WARN"
        continue
    }

    $currentVol   = Get-PerDeviceVolume -DeviceId $allowed.ID
    $desiredVol   = Convert-ToRoundedNumber $allowed.Volume

    if ($null -ne $desiredVol -and $null -ne $currentVol -and
        [math]::Abs($currentVol - $desiredVol) -ge 1) {

        Add-Change "Playback-Volume" "'$($allowed.Name)': $currentVol% -> $desiredVol%"
        if ($Mode -eq 'Enforce') {
            [void](Set-PerDeviceVolume -DeviceId $allowed.ID -Percent $desiredVol)
        }
    } else {
        $volText = if ($null -ne $currentVol) { "$currentVol%" } else { "n/a" }
        Write-Log "Playback-Volume OK: '$($allowed.Name)' = $volText (soll $desiredVol%)" "OK"
    }

    $isMuted = Get-PerDeviceMute -DeviceId $allowed.ID
    if ($isMuted -eq $true -and $allowed.Muted -ne $true) {
        Add-Change "Playback-Mute" "'$($allowed.Name)' ist stumm -> soll aktiv sein"
        if ($Mode -eq 'Enforce') {
            [void](Set-PerDeviceMute -DeviceId $allowed.ID -Mute $false)
        }
    } else {
        Write-Log "Playback-Mute OK: '$($allowed.Name)' (mute=$isMuted)" "OK"
    }
}

Write-Log "--- Prüfe Aufnahmegeräte ---" "INFO"
foreach ($allowed in $config.AllowedRecordingDevices) {

    $current = $recordingDevices | Where-Object { $_.ID -eq $allowed.ID }
    if (-not $current) {
        Write-Log "Aufnahmegerät '$($allowed.Name)' nicht (mehr) vorhanden – überspringe." "WARN"
        continue
    }

    $currentVol = Get-PerDeviceVolume -DeviceId $allowed.ID
    $desiredVol = Convert-ToRoundedNumber $allowed.Volume

    if ($null -ne $desiredVol -and $null -ne $currentVol -and
        [math]::Abs($currentVol - $desiredVol) -ge 1) {

        Add-Change "Recording-Volume" "'$($allowed.Name)': $currentVol% -> $desiredVol%"
        if ($Mode -eq 'Enforce') {
            [void](Set-PerDeviceVolume -DeviceId $allowed.ID -Percent $desiredVol)
        }
    } else {
        $volText = if ($null -ne $currentVol) { "$currentVol%" } else { "n/a" }
        Write-Log "Recording-Volume OK: '$($allowed.Name)' = $volText (soll $desiredVol%)" "OK"
    }

    $isMuted = Get-PerDeviceMute -DeviceId $allowed.ID
    if ($isMuted -eq $true -and $allowed.Muted -ne $true) {
        Add-Change "Recording-Mute" "'$($allowed.Name)' ist stumm -> soll aktiv sein"
        if ($Mode -eq 'Enforce') {
            [void](Set-PerDeviceMute -DeviceId $allowed.ID -Mute $false)
        }
    } else {
        Write-Log "Recording-Mute OK: '$($allowed.Name)' (mute=$isMuted)" "OK"
    }
}

# --- Namenskorrektur für Wiedergabegeräte ---
foreach ($allowed in $config.AllowedPlaybackDevices) {
    $current = $playbackDevices | Where-Object { $_.ID -eq $allowed.ID }
    if (-not $current) { continue }

    $currentShortName = Get-ShortDeviceName $current.Name
    if ($currentShortName -cne $allowed.Name) {
        Add-Change "Playback-Name" "'$currentShortName' -> '$($allowed.Name)'"
        if ($Mode -eq 'Enforce') {
            $ok = Set-AudioEndpointFriendlyName -DeviceId $allowed.ID -NewName $allowed.Name -Flow 'Render'
            if (-not $ok) {
                Add-Change "Playback-Name" "FEHLER bei der Korrektur von '$($allowed.Name)'" "ERROR"
            }
        }
    } else {
        Write-Log "Playback-Name OK: '$($allowed.Name)'" "OK"
    }
}

# --- Namenskorrektur für Aufnahmegeräte ---
foreach ($allowed in $config.AllowedRecordingDevices) {
    $current = $recordingDevices | Where-Object { $_.ID -eq $allowed.ID }
    if (-not $current) { continue }

    $currentShortName = Get-ShortDeviceName $current.Name
    if ($currentShortName -cne $allowed.Name) {
        Add-Change "Recording-Name" "'$currentShortName' -> '$($allowed.Name)'"
        if ($Mode -eq 'Enforce') {
            $ok = Set-AudioEndpointFriendlyName -DeviceId $allowed.ID -NewName $allowed.Name -Flow 'Capture'
            if (-not $ok) {
                Add-Change "Recording-Name" "FEHLER bei der Korrektur von '$($allowed.Name)'" "ERROR"
            }
        }
    } else {
        Write-Log "Recording-Name OK: '$($allowed.Name)'" "OK"
    }
}

# ===============================================================
# 7b) SERVICE-NEUSTART NACH NAMENSÄNDERUNGEN
# ===============================================================
# Die neuen Namen werden im Property Store gespeichert, aber erst
# nach einem Audio-Dienst-Neustart von Sound-Panel und
# Get-AudioDevice -List übernommen.
$namesChanged = @($changes | Where-Object { $_.Kategorie -in @('Playback-Name','Recording-Name') })

if ($namesChanged.Count -gt 0 -and $Mode -eq 'Enforce' -and -not $SkipServiceRestart) {
    Write-Log "Namen geändert – starte Audio-Dienste einmalig neu." "INFO"
    try {
        Restart-Service Audiosrv, AudioEndpointBuilder -Force -ErrorAction Stop
        Start-Sleep -Seconds 1
        Write-Log "Audio-Dienste neu gestartet." "OK"
    } catch {
        Write-Log "FEHLER beim Neustart der Audio-Dienste: $($_.Exception.Message)" "ERROR"
    }
}

# ===============================================================
# 8) DEAKTIVIERUNGS-LISTE DURCHSETZEN + NEUE GERÄTE ALS AUSNAHME ERFASSEN
# ===============================================================
Write-Log "--- Prüfe Deaktivierungs-Liste + erfasse neue Geräte als Ausnahme ---" "INFO"

# Bestehende Listen aus Config laden (nach Reparatur)
$configDisabledPlaybackIds   = @()
$configDisabledRecordingIds  = @()
$configExceptionPlaybackIds  = @()
$configExceptionRecordingIds = @()

if ($config.PSObject.Properties.Name -contains 'DisabledPlaybackDevices' -and $config.DisabledPlaybackDevices) {
    $configDisabledPlaybackIds = @($config.DisabledPlaybackDevices | ForEach-Object { $_.ID })
}
if ($config.PSObject.Properties.Name -contains 'DisabledRecordingDevices' -and $config.DisabledRecordingDevices) {
    $configDisabledRecordingIds = @($config.DisabledRecordingDevices | ForEach-Object { $_.ID })
}
if ($config.PSObject.Properties.Name -contains 'ExceptionPlaybackDevices' -and $config.ExceptionPlaybackDevices) {
    $configExceptionPlaybackIds = @($config.ExceptionPlaybackDevices | ForEach-Object { $_.ID })
}
if ($config.PSObject.Properties.Name -contains 'ExceptionRecordingDevices' -and $config.ExceptionRecordingDevices) {
    $configExceptionRecordingIds = @($config.ExceptionRecordingDevices | ForEach-Object { $_.ID })
}

Write-Log "Disabled-Listen (vor Lauf): $($configDisabledPlaybackIds.Count) Playback, $($configDisabledRecordingIds.Count) Recording" "INFO"
Write-Log "Exception-Listen (vor Lauf): $($configExceptionPlaybackIds.Count) Playback, $($configExceptionRecordingIds.Count) Recording" "INFO"

$configChanged = $false

$allPlaybackIds  = [CoreAudioApiV4]::GetAllDeviceIds(0)
$allRecordingIds = [CoreAudioApiV4]::GetAllDeviceIds(1)

# ╔══════════════════════════════════════════════════════════════╗
# ║ FIX: Direkt über Disabled-Listen iterieren, immer            ║
# ║ SetVisibility($false) aufrufen – unabhängig vom State.       ║
# ║ So werden auch Geräte erfasst, die nicht in GetAllDeviceIds  ║
# ║ auftauchen, und State 8 (UNPLUGGED) wird trotzdem versteckt. ║
# ╚══════════════════════════════════════════════════════════════╝

# --- Wiedergabegeräte: Disabled-Liste durchsetzen ---
foreach ($disabled in $config.DisabledPlaybackDevices) {
    $id = $disabled.ID
    $state = [CoreAudioApiV4]::GetDeviceState($id)
    $isReallyVisible = (($state -band 0x1) -ne 0)

    if ($Mode -eq 'Enforce') {
        if ([PolicyConfigClient]::SetVisibility($id, $false)) {
            if ($isReallyVisible) {
                Add-Change "Disabled-Playback" "'$($disabled.Name)' (State: $state) war sichtbar -> deaktiviert"
            } else {
                Write-Log "Disabled-Playback OK: '$($disabled.Name)' (State: $state) erneut ausgeblendet" "OK"
            }
        } else {
            Add-Change "Disabled-Playback" "FEHLER beim Deaktivieren von '$($disabled.Name)' (ID: $id)" "ERROR"
        }
    } else {
        if ($isReallyVisible) {
            Add-Change "Disabled-Playback" "'$($disabled.Name)' (State: $state) würde deaktiviert" "CHANGED"
        }
    }
}

# --- Aufnahmegeräte: Disabled-Liste durchsetzen ---
foreach ($disabled in $config.DisabledRecordingDevices) {
    $id = $disabled.ID
    $state = [CoreAudioApiV4]::GetDeviceState($id)
    $isReallyVisible = (($state -band 0x1) -ne 0)

    if ($Mode -eq 'Enforce') {
        if ([PolicyConfigClient]::SetVisibility($id, $false)) {
            if ($isReallyVisible) {
                Add-Change "Disabled-Recording" "'$($disabled.Name)' (State: $state) war sichtbar -> deaktiviert"
            } else {
                Write-Log "Disabled-Recording OK: '$($disabled.Name)' (State: $state) erneut ausgeblendet" "OK"
            }
        } else {
            Add-Change "Disabled-Recording" "FEHLER beim Deaktivieren von '$($disabled.Name)' (ID: $id)" "ERROR"
        }
    } else {
        if ($isReallyVisible) {
            Add-Change "Disabled-Recording" "'$($disabled.Name)' (State: $state) würde deaktiviert" "CHANGED"
        }
    }
}

# --- Neue Geräte als Ausnahme erfassen (Registry-Differenz) ---
foreach ($id in $allPlaybackIds) {
    if ($id -in $allowedPlaybackIDs)    { continue }
    if ($id -in $configDisabledPlaybackIds)  { continue }
    if ($id -in $configExceptionPlaybackIds) { continue }

    $state     = [CoreAudioApiV4]::GetDeviceState($id)
    $isVisible = (($state -band 0x1) -ne 0) -or (($state -band 0x8) -ne 0)
    if (-not $isVisible) { continue }

    $pnp       = $cachedPnpEndpoints | Where-Object { $_.InstanceId -like "*$id*" } | Select-Object -First 1
    $name      = if ($pnp) { $pnp.FriendlyName } else { $id }
    $shortName = Get-ShortDeviceName $name

    Add-Change "New-Playback" "'$shortName' (State: $state) ist neu -> wird als Ausnahme eingetragen (bleibt unangetastet)"

    if ($Mode -eq 'Enforce') {
        if (-not $config.ExceptionPlaybackDevices) {
            $config | Add-Member -NotePropertyName 'ExceptionPlaybackDevices' -NotePropertyValue @() -Force
        }
        $config.ExceptionPlaybackDevices += [pscustomobject]@{
            ID   = $id
            Name = $shortName
        }
        $configExceptionPlaybackIds += $id
        $configChanged = $true
    }
}

foreach ($id in $allRecordingIds) {
    if ($id -in $allowedRecordingIDs)       { continue }
    if ($id -in $configDisabledRecordingIds)  { continue }
    if ($id -in $configExceptionRecordingIds) { continue }

    $state     = [CoreAudioApiV4]::GetDeviceState($id)
    $isVisible = (($state -band 0x1) -ne 0) -or (($state -band 0x8) -ne 0)
    if (-not $isVisible) { continue }

    $pnp       = $cachedPnpEndpoints | Where-Object { $_.InstanceId -like "*$id*" } | Select-Object -First 1
    $name      = if ($pnp) { $pnp.FriendlyName } else { $id }
    $shortName = Get-ShortDeviceName $name

    Add-Change "New-Recording" "'$shortName' (State: $state) ist neu -> wird als Ausnahme eingetragen (bleibt unangetastet)"

    if ($Mode -eq 'Enforce') {
        if (-not $config.ExceptionRecordingDevices) {
            $config | Add-Member -NotePropertyName 'ExceptionRecordingDevices' -NotePropertyValue @() -Force
        }
        $config.ExceptionRecordingDevices += [pscustomobject]@{
            ID   = $id
            Name = $shortName
        }
        $configExceptionRecordingIds += $id
        $configChanged = $true
    }
}

if ($configChanged) {
    $config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Log "Config um neue Ausnahme-Geräte erweitert und gespeichert." "INFO"
}

# ===============================================================
# 9) ZUSAMMENFASSUNG
# ===============================================================
Write-Host ""
Write-Host "=== Zusammenfassung ===" -ForegroundColor Cyan
Write-Host "Änderungen vorgenommen : $($changes.Count)" -ForegroundColor Yellow
Write-Host "Modus                  : $Mode" -ForegroundColor Cyan

if ($changes.Count -gt 0) {
    Write-Host ""
    $changes | Format-Table Kategorie, Detail, Status -AutoSize
}

if ($Mode -eq 'Check') {
    Write-Host "HINWEIS: Modus 'Check' hat nichts geändert." -ForegroundColor Magenta
}

Write-Log "=== Skript beendet ==="

$mutex.ReleaseMutex()

$errors = ($changes | Where-Object Status -eq 'ERROR').Count
if ($errors -gt 0) { exit 1 } else { exit 0 }