# --- Konfiguration ---
$TaskName   = "Audio-Restore-Manager"
$TaskPath   = "\Scripts\"
$ScriptPath = "C:\Skripts\AudioRecovery\Enforce-AudioSettings.ps1"

# --- Task-Aktion ---
$TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# --- Trigger mit 15s Delay ---
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Trigger.Delay = "PT15S"

# --- Principal & Settings ---
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$Settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

# --- Registrieren ---
Register-ScheduledTask `
    -TaskName   $TaskName `
    -TaskPath   $TaskPath `
    -Action     $TaskAction `
    -Trigger    $Trigger `
    -Principal  $Principal `
    -Settings   $Settings `
    -Description "Restore all Audio configs at systems starts." `
    -Force
