# PeaceSwitch — portage PowerShell de peace_preamp.ahk
#
# Même fonctionnalités que le script AHK, mais SANS hook clavier/souris
# bas niveau ni injection de touches (ce qui faisait réagir l'anti-cheat) :
#   - raccourcis via RegisterHotKey (API standard, comme Discord/OBS)
#   - le switch casque/enceintes écrit directement peace.txt (lu par
#     Equalizer APO) à partir de modèles capturés depuis Peace, au lieu
#     d'envoyer Ctrl+Alt+F1/F2 à Peace
#
# Raccourcis:
#   F13              → baisser (step dB)
#   F14              → monter  (step dB)
#   F15              → toggle mute
#   Ctrl+Alt+F1      → profil enceintes
#   Ctrl+Alt+F2      → profil casque
#   Ctrl+Alt+B       → écran noir (Échap ou clic pour fermer)
#
# Les modèles (templates\*.txt) se mettent à jour tout seuls si tu modifies
# l'EQ dans Peace : la sync périodique recopie le nouveau peace.txt.

$ErrorActionPreference = 'Stop'

# Peace enregistre lui aussi Ctrl+Alt+F1/F2 : tant qu'il tourne, Windows
# refuse que ce script les réserve. Peace n'est pas nécessaire au son
# (c'est Equalizer APO qui applique peace.txt), donc on le ferme.
$ClosePeace = $true

# ============================================================
#  INSTANCE UNIQUE
# ============================================================
$mutex = New-Object System.Threading.Mutex($false, 'Local\PeaceSwitch')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PeaceSwitch {
    // Fenêtre invisible qui reçoit les WM_HOTKEY de RegisterHotKey
    public class HotkeyWindow : NativeWindow {
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
        [DllImport("user32.dll")]
        static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public event Action<int> Pressed;

        public HotkeyWindow() { CreateHandle(new CreateParams()); }

        // 0 = OK, sinon code d'erreur Win32 (1409 = déjà pris par une autre appli)
        public int Register(int id, uint mod, uint vk) {
            return RegisterHotKey(Handle, id, mod, vk) ? 0 : Marshal.GetLastWin32Error();
        }
        public void Unregister(int id) { UnregisterHotKey(Handle, id); }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) {
                var p = Pressed;
                if (p != null) p(m.WParam.ToInt32());
                return;
            }
            base.WndProc(ref m);
        }
    }

    // OSD : toujours au-dessus, ne prend jamais le focus, transparent aux clics
    public class OsdForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x00000008   // WS_EX_TOPMOST
                           |  0x00000020   // WS_EX_TRANSPARENT
                           |  0x00000080   // WS_EX_TOOLWINDOW
                           |  0x08000000;  // WS_EX_NOACTIVATE
                return cp;
            }
        }
    }

    // Écran noir : au-dessus de tout, absent de la barre des tâches / Alt+Tab
    public class BlackForm : Form {
        protected override CreateParams CreateParams {
            get {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x00000008 | 0x00000080;  // TOPMOST | TOOLWINDOW
                return cp;
            }
        }
    }

    // Interface COM non documentée IPolicyConfig (même mécanisme que
    // nircmd / EarTrumpet). Seul SetDefaultEndpoint est utilisé, les autres
    // méthodes ne sont là que pour occuper leur place dans la vtable.
    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig {
        void GetMixFormat(); void GetDeviceFormat(); void ResetDeviceFormat();
        void SetDeviceFormat(); void GetProcessingPeriod(); void SetProcessingPeriod();
        void GetShareMode(); void SetShareMode(); void GetPropertyValue();
        void SetPropertyValue();
        [PreserveSig]
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
    }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    class CPolicyConfigClient { }

    public static class Native {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        // DPI par écran (v2), sinon Windows redimensionne les fenêtres sur
        // les écrans dont la mise à l'échelle diffère de l'écran principal
        public static void EnableDpiAwareness() {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
            SetProcessDPIAware();
        }

        // Place la fenêtre en pixels physiques exacts, au-dessus de tout
        public static void PlaceTopmost(IntPtr hWnd, int x, int y, int w, int h) {
            SetWindowPos(hWnd, new IntPtr(-1), x, y, w, h, 0x0010 /* SWP_NOACTIVATE */);
        }
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        // Bascule la sortie par défaut pour les 3 rôles (console, multimédia, communications)
        public static int SetDefaultAudioDevice(string deviceId) {
            var pc = (IPolicyConfig)new CPolicyConfigClient();
            int hr = 0;
            try {
                for (int role = 0; role < 3; role++) {
                    int r = pc.SetDefaultEndpoint(deviceId, role);
                    if (r != 0) hr = r;
                }
            } finally { Marshal.ReleaseComObject(pc); }
            return hr;
        }
    }
}
'@

[PeaceSwitch.Native]::EnableDpiAwareness()
[System.Windows.Forms.Application]::EnableVisualStyles()

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ============================================================
#  CHEMINS / ÉTAT
# ============================================================
$S = @{
    PeaceDir     = 'C:\Program Files\EqualizerAPO\config'
    PeaceFile    = 'C:\Program Files\EqualizerAPO\config\peace.txt'
    TemplatesDir = Join-Path $PSScriptRoot 'templates'
    LogFile      = Join-Path $env:TEMP 'peace_switch.log'
    Active       = 'enceintes'
    Muted        = $false
    Black        = @()
    OsdHideAt    = [DateTime]::MinValue
}

# ============================================================
#  JOURNAL DE DIAGNOSTIC
# ============================================================
function Log([string]$msg) {
    try {
        if ((Test-Path $S.LogFile) -and (Get-Item $S.LogFile).Length -gt 262144) {
            Remove-Item $S.LogFile -Force
        }
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        [IO.File]::AppendAllText($S.LogFile, "$ts  $msg`r`n", $Utf8NoBom)
    } catch { }
}

# Tout ce qui est appelé depuis un raccourci / timer passe par ici : une
# exception ne doit jamais faire tomber la boucle de messages.
function Safe([scriptblock]$sb) {
    try { & $sb } catch { Log "ERREUR: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
}

# ============================================================
#  CONFIGURATION DES PROFILS
# ============================================================
# Plafond (Max) = -(plus gros boost de l'EQ du profil), pour que le preamp
# compense toujours le boost et que le signal ne sature jamais :
#   Casque    : +8 dB (filtre grave) -> -8 dB
#   Enceintes : +5 dB (filtre grave) -> -5 dB
$S.Profiles = @{
    casque = @{
        Label = 'Casque'; Default = -15.0; Cur = -15.0
        Min = -30.0; Max = -8.0; Step = 0.5; WarnZone = 1.5
        PeaceProfile = Join-Path $S.PeaceDir 'Casque.peace'
        Template     = Join-Path $S.TemplatesDir 'casque.txt'
    }
    enceintes = @{
        Label = 'Enceintes'; Default = -10.0; Cur = -10.0
        Min = -30.0; Max = -5.0; Step = 0.5; WarnZone = 1.5
        PeaceProfile = Join-Path $S.PeaceDir 'Enceintes.peace'
        Template     = Join-Path $S.TemplatesDir 'enceintes.txt'
    }
}

function Fmt([double]$v) { $v.ToString('0.0', $Inv) }
function GetProfile { $S.Profiles[$S.Active] }

# ============================================================
#  LECTURE / ÉCRITURE peace.txt
# ============================================================
function Read-PeaceLines { [IO.File]::ReadAllLines($S.PeaceFile) }

function Write-PeaceLines([string[]]$lines) {
    [IO.File]::WriteAllText($S.PeaceFile, (($lines -join "`r`n") + "`r`n"), $Utf8NoBom)
}

# Les fichiers de Peace sont en ANSI avec quelques octets invalides : Latin-1
# relit/réécrit chaque octet à l'identique.
$Latin1 = [Text.Encoding]::GetEncoding(28591)

# À son ouverture, Peace ne recharge pas le profil sélectionné mais
# "Last Configuration.peace" (l'état sauvé à sa dernière fermeture), puis
# réécrit peace.txt avec. On y recopie donc le profil appliqué, après avoir
# corrigé son GUID (DAC USB qui change d'identité) comme le faisait l'AHK.
function Sync-PeaceProfileFiles($p, [string]$guid) {
    $text = [IO.File]::ReadAllText($p.PeaceProfile, $Latin1)
    $fixed = [regex]::Replace($text, '(?m)^Device GUID=\{[0-9a-fA-F-]+\}', "Device GUID=$guid")
    if ($fixed -ne $text) {
        [IO.File]::WriteAllText($p.PeaceProfile, $fixed, $Latin1)
        Log "GUID corrigé dans $($p.PeaceProfile) (dérive détectée)"
    }
    Copy-Item $p.PeaceProfile (Join-Path $S.PeaceDir 'Last Configuration.peace') -Force
}

function Set-PeaceSelectedConfiguration([string]$name) {
    $ini = Join-Path $S.PeaceDir 'peace.ini'
    if (-not (Test-Path $ini)) { return }
    $enc = $Latin1
    $lines = [IO.File]::ReadAllLines($ini, $enc)
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Selected Configuration=' -and $lines[$i] -ne "Selected Configuration=$name") {
            $lines[$i] = "Selected Configuration=$name"
            $changed = $true
        }
    }
    if ($changed) {
        [IO.File]::WriteAllLines($ini, $lines, $enc)
        Log "peace.ini : profil sélectionné -> $name"
    }
}

function Read-Preamp {
    foreach ($l in Read-PeaceLines) {
        if ($l -match '^Preamp:\s*([-\d.]+)') { return [double]::Parse($Matches[1], $Inv) }
    }
    return 0.0
}

function Write-Preamp([double]$val) {
    # Filet de sécurité matériel : jamais au-dessus du plafond du profil actif
    $val = [Math]::Min($val, (GetProfile).Max)
    $lines = foreach ($l in Read-PeaceLines) {
        if ($l -match '^Preamp:') { "Preamp: $(Fmt $val) dB" } else { $l }
    }
    Write-PeaceLines $lines
}

# ============================================================
#  DEVICES AUDIO — anti-dérive GUID (DAC USB qui change d'identité)
# ============================================================
$MMRenderKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$PKEY_JackName    = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$PKEY_ProductName = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'

# Lit "Device=<jack>, <produit>" dans le fichier .peace du profil
function Get-DeviceRef($p) {
    foreach ($l in [IO.File]::ReadAllLines($p.PeaceProfile)) {
        if ($l -match '^Device=([^,]+),\s*(.+)$') {
            return @{ Jack = $Matches[1].Trim(); Product = $Matches[2].Trim() }
        }
    }
    return $null
}

# Cherche parmi les endpoints AUDIO ACTIFS celui dont jack+produit correspondent
function Find-ActiveDeviceGuid($ref) {
    foreach ($k in Get-ChildItem $MMRenderKey) {
        try {
            $state = (Get-ItemProperty $k.PSPath -Name DeviceState).DeviceState
            if (($state -band 0xF) -ne 1) { continue }   # pas "Active"
            $props = Get-ItemProperty (Join-Path $k.PSPath 'Properties')
            if ($props.$PKEY_JackName -eq $ref.Jack -and $props.$PKEY_ProductName -eq $ref.Product) {
                return $k.PSChildName
            }
        } catch { continue }
    }
    return $null
}

# Un DAC USB qui vient d'être branché/réveillé met parfois un instant avant
# d'être marqué "Active" dans le registre : on retente quelques centaines de ms.
function Find-ActiveDeviceGuidRetry($ref, [int]$maxWaitMs = 1200, [int]$intervalMs = 150) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $g = Find-ActiveDeviceGuid $ref
        if ($g) { return $g }
        if ($sw.ElapsedMilliseconds -ge $maxWaitMs) { return $null }
        Start-Sleep -Milliseconds $intervalMs
    }
}

# Quel profil correspond à la ligne "Device:" actuelle de peace.txt ?
function Detect-ProfileFromPeace([string[]]$lines) {
    $dev = $lines | Where-Object { $_ -match '^Device:' } | Select-Object -First 1
    if (-not $dev) { return $null }
    foreach ($key in $S.Profiles.Keys) {
        $ref = Get-DeviceRef $S.Profiles[$key]
        if ($ref -and $dev.Contains($ref.Product) -and $dev.Contains($ref.Jack)) { return $key }
    }
    return $null
}

# Contenu "EQ" d'un peace.txt, sans les lignes Device/Preamp qu'on réécrit
function Get-EqSignature([string[]]$lines) {
    ($lines | Where-Object { $_ -notmatch '^(Device|Preamp):' -and $_.Trim() } | ForEach-Object { $_.Trim() }) -join "`n"
}

# ============================================================
#  SWITCH DE PROFIL
# ============================================================
function Switch-Profile([string]$key) {
    $p = $S.Profiles[$key]
    Log "$($p.Label) demandé"

    $ref = Get-DeviceRef $p
    if (-not $ref) {
        Log "ÉCHEC: pas de ligne Device= dans $($p.PeaceProfile)"
        Show-Osd "⚠ $($p.Label)" 'Profil illisible' 3000 '801010'
        return
    }
    $guid = Find-ActiveDeviceGuidRetry $ref
    if (-not $guid) {
        Log "ÉCHEC: '$($ref.Jack)' / '$($ref.Product)' introuvable parmi les endpoints actifs (après retry)"
        Show-Osd "⚠ $($p.Label)" 'Non détecté' 3000 '801010'
        return
    }
    if (-not (Test-Path $p.Template)) {
        Log "ÉCHEC: modèle manquant $($p.Template)"
        Show-Osd "⚠ $($p.Label)" 'Modèle manquant' 3000 '801010'
        return
    }

    # Sortie Windows par défaut
    $hr = [PeaceSwitch.Native]::SetDefaultAudioDevice("{0.0.0.00000000}.$guid")
    if ($hr -ne 0) { Log ("SetDefaultAudioDevice HRESULT=0x{0:X8}" -f $hr) }

    # peace.txt = modèle du profil, avec le GUID actuel du device (anti-dérive)
    # et le preamp par défaut du profil
    $lines = foreach ($l in [IO.File]::ReadAllLines($p.Template)) {
        if     ($l -match '^Device:') { "Device: $($ref.Product) $($ref.Jack) $guid" }
        elseif ($l -match '^Preamp:') { "Preamp: $(Fmt $p.Default) dB" }
        else   { $l }
    }
    Write-PeaceLines $lines

    # Peace ne lit pas peace.txt : il recharge "Last Configuration.peace" et
    # affiche "Selected Configuration=" de peace.ini, puis réécrit peace.txt
    # à son ouverture. Sans ça, ouvrir Peace annulerait le switch.
    Sync-PeaceProfileFiles $p $guid
    Set-PeaceSelectedConfiguration ([IO.Path]::GetFileNameWithoutExtension($p.PeaceProfile))

    $S.Active = $key
    $S.Muted  = $false
    $p.Cur    = $p.Default

    # Relecture pour confirmer que l'écriture est bien passée
    $check = (Read-PeaceLines) -join "`n"
    if ($check.Contains($guid)) {
        Log "✓ Switch $($p.Label) appliqué ($guid), Preamp=$(Fmt $p.Cur) dB"
        Show-Osd $p.Label "$(Fmt $p.Cur) dB" 2500
    } else {
        Log "⚠ Switch $($p.Label) : relecture de peace.txt incohérente"
        Show-Osd "⚠ $($p.Label)" 'Non confirmé' 3000 '804000'
    }
}

# ============================================================
#  SYNC PÉRIODIQUE
# ============================================================
# - suit les changements faits ailleurs (Peace ouvert à la main, etc.)
# - met à jour le modèle du profil si l'EQ a été modifié dans Peace
function Sync-Peace {
    if ($S.Muted) { return }   # peace.txt est à -60, Cur est la valeur pré-mute
    $lines = Read-PeaceLines

    $key = Detect-ProfileFromPeace $lines
    if ($key -and $key -ne $S.Active) {
        Log "Sync: peace.txt est sur $($S.Profiles[$key].Label), profil actif ajusté"
        $S.Active = $key
    }

    $p = GetProfile
    if ($key -and (Test-Path $p.Template)) {
        $tpl = [IO.File]::ReadAllLines($p.Template)
        if ((Get-EqSignature $lines) -ne (Get-EqSignature $tpl)) {
            [IO.File]::WriteAllLines($p.Template, $lines)
            Log "Sync: EQ $($p.Label) modifié hors script, modèle mis à jour"
        }
    }

    $actual = Read-Preamp
    if ([Math]::Abs($actual - $p.Cur) -ge 0.5) {
        $p.Cur = $actual
        Show-Osd "⚠ Sync ($($p.Label))" "$(Fmt $actual) dB" 2500 '804000'
    }
}

# ============================================================
#  OSD
# ============================================================
$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$Scale = $g.DpiX / 96.0
$g.Dispose()
function Px([double]$v) { [int][Math]::Round($v * $Scale) }

# Alpha entier comme WinSetTransparent d'AHK (242, puis -27 par tick de fondu).
# +0.5 : WinForms tronque Opacity*255 en octet, ça garantit la valeur exacte.
$OsdAlpha = 242
function Set-OsdAlpha([int]$a) { $S.Alpha = $a; $osd.Opacity = ($a + 0.5) / 255.0 }
$osd = New-Object PeaceSwitch.OsdForm
$osd.FormBorderStyle = 'None'
$osd.StartPosition   = 'Manual'
$osd.ShowInTaskbar   = $false
$osd.TopMost         = $true
$osd.Opacity         = ($OsdAlpha + 0.5) / 255.0
$osd.BackColor       = [System.Drawing.ColorTranslator]::FromHtml('#202020')
# Tailles de l'OSD AHK (unités AHK mises à l'échelle DPI). Centré sur la
# largeur réelle (AHK centrait sur 300 px bruts, donc décalé à droite en
# DPI > 100 %) ; y = hauteur écran - 165 comme AHK.
$osd.ClientSize      = New-Object System.Drawing.Size((Px 300.8), (Px 106.4))
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$osd.Location = New-Object System.Drawing.Point(
    [int]($scr.X + [Math]::Floor(($scr.Width - $osd.Width) / 2)),
    [int]($scr.Y + $scr.Height - 165))

$txtLabel = New-Object System.Windows.Forms.Label
$txtLabel.AutoSize  = $false
$txtLabel.FlatStyle = 'System'   # rendu natif (repli de police pour les symboles)
$txtLabel.TextAlign = 'MiddleCenter'
$txtLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
$txtLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#AAAAAA')
$txtLabel.Bounds    = New-Object System.Drawing.Rectangle((Px 10), (Px 12), (Px 280), (Px 22))
$osd.Controls.Add($txtLabel)

$txtValue = New-Object System.Windows.Forms.Label
$txtValue.AutoSize  = $false
$txtValue.FlatStyle = 'System'   # rendu natif, sinon 🔇 s'affiche en carré
$txtValue.TextAlign = 'MiddleCenter'
$txtValue.Font      = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$txtValue.ForeColor = [System.Drawing.Color]::White
$txtValue.Bounds    = New-Object System.Drawing.Rectangle((Px 10), (Px 54), (Px 280), (Px 40))
$osd.Controls.Add($txtValue)

# Coins arrondis Windows 11 + ombre
$osd.add_HandleCreated({
    $v = 2
    [PeaceSwitch.Native]::DwmSetWindowAttribute($osd.Handle, 33, [ref]$v, 4) | Out-Null
    [PeaceSwitch.Native]::DwmSetWindowAttribute($osd.Handle, 2,  [ref]$v, 4) | Out-Null
})

$osdTimer = New-Object System.Windows.Forms.Timer
$osdTimer.Interval = 25
$osdTimer.add_Tick({ Safe {
    if ([DateTime]::Now -lt $S.OsdHideAt) { return }
    $a = $S.Alpha - 27
    if ($a -le 0) {
        $osdTimer.Stop()
        $osd.Hide()
        Set-OsdAlpha $OsdAlpha
    } else {
        Set-OsdAlpha $a
    }
}})

function Show-Osd([string]$label, [string]$value, [int]$durationMs = 0, [string]$bgColor = '202020') {
    $dur = if ($durationMs -gt 0) { $durationMs } else { 2000 }
    $osd.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#$bgColor")
    $txtLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($(if ($bgColor -eq '801010') { '#FFCCCC' } else { '#AAAAAA' }))
    $txtLabel.Text = $label
    $txtValue.Text = $value
    Set-OsdAlpha $OsdAlpha
    $S.OsdHideAt   = [DateTime]::Now.AddMilliseconds($dur)
    if (-not $osd.Visible) { $osd.Show() }
    $osd.TopMost = $true
    $osdTimer.Start()
}

# ============================================================
#  ÉCRAN NOIR (anti burn-in OLED pendant une absence courte)
# ============================================================
# Couvre tous les écrans de noir opaque sans couper le signal vidéo.
# Se ferme sur Échap (raccourci réservé seulement pendant l'écran noir)
# ou sur clic gauche.
function Show-BlackScreen {
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object PeaceSwitch.BlackForm
        $f.FormBorderStyle = 'None'
        $f.StartPosition   = 'Manual'
        $f.ShowInTaskbar   = $false
        $f.BackColor       = [System.Drawing.Color]::Black
        $f.Bounds          = $screen.Bounds
        $f.add_MouseDown({ param($src, $e) if ($e.Button -eq 'Left') { Safe { Hide-BlackScreen } } })
        $f.Show()
        # Le déplacement vers un écran à autre DPI peut redimensionner la
        # fenêtre : on réimpose les dimensions physiques de l'écran.
        $b = $screen.Bounds
        [PeaceSwitch.Native]::PlaceTopmost($f.Handle, $b.X, $b.Y, $b.Width, $b.Height)
        $S.Black += $f
    }
    $err = $S.Hk.Register(100, 0, 0x1B)   # Échap
    if ($err) { Log "Échap non réservable pendant l'écran noir (err $err)" }
}

function Hide-BlackScreen {
    $S.Hk.Unregister(100)
    foreach ($f in $S.Black) { $f.Close(); $f.Dispose() }
    $S.Black = @()
}

# ============================================================
#  RACCOURCIS
# ============================================================
function Volume-Down {
    $p = GetProfile
    $new = $p.Cur - $p.Step
    $S.Muted = $false
    if ($new -lt $p.Min) {
        $p.Cur = $p.Min
        Write-Preamp $p.Cur
        Show-Osd $p.Label "$(Fmt $p.Cur) dB  [MIN]"
        return
    }
    $p.Cur = $new
    Write-Preamp $p.Cur
    if ($p.Cur -gt $p.Max) {
        Show-Osd "Plafond dépassé ($(Fmt $p.Max) dB)" "⚠   $(Fmt $p.Cur) dB" 0 '801010'
    } elseif ($p.Cur -ge $p.Max - $p.WarnZone) {
        Show-Osd $p.Label "⚠   $(Fmt $p.Cur) dB"
    } else {
        Show-Osd $p.Label "$(Fmt $p.Cur) dB"
    }
}

function Volume-Up {
    $p = GetProfile
    $new = $p.Cur + $p.Step
    $S.Muted = $false
    if ($new -gt $p.Max) {
        $p.Cur = $p.Max
        Write-Preamp $p.Cur
        Show-Osd "Plafond ($(Fmt $p.Max) dB)" "⚠   $(Fmt $p.Cur) dB" 0 '801010'
        return
    }
    $p.Cur = $new
    Write-Preamp $p.Cur
    if ($p.Cur -ge $p.Max - $p.WarnZone) {
        Show-Osd $p.Label "⚠   $(Fmt $p.Cur) dB"
    } else {
        Show-Osd $p.Label "$(Fmt $p.Cur) dB"
    }
}

function Toggle-Mute {
    $p = GetProfile
    $S.Muted = -not $S.Muted
    if ($S.Muted) { Write-Preamp -60.0 } else { Write-Preamp $p.Cur }
    Show-Osd $p.Label $(if ($S.Muted) { '🔇' } else { "$(Fmt $p.Cur) dB" })
}

function On-Hotkey([int]$id) {
    # 11..73 = variantes Maj/Ctrl/Alt de F13-F15 (id de base + 10 x combinaison)
    if ($id -gt 10 -and $id -lt 100) { $id = $id % 10 }
    switch ($id) {
        1   { Volume-Down }
        2   { Volume-Up }
        3   { Toggle-Mute }
        4   { Switch-Profile 'enceintes' }
        5   { Switch-Profile 'casque' }
        6   { if ($S.Black.Count) { Hide-BlackScreen } else { Show-BlackScreen } }
        100 { Hide-BlackScreen }
    }
}

# ============================================================
#  DÉMARRAGE
# ============================================================
if ($ClosePeace) {
    $peace = Get-Process -Name Peace -ErrorAction SilentlyContinue
    if ($peace) {
        Log 'Fermeture de Peace (conflit sur Ctrl+Alt+F1/F2, inutile au son)'
        try {
            $peace | Stop-Process -Force
            $peace | Wait-Process -Timeout 3 -ErrorAction SilentlyContinue
        } catch {
            # Peace lancé en admin : impossible de le fermer sans élévation
            Log "Impossible de fermer Peace : $($_.Exception.Message)"
        }
    }
}

$S.Hk = New-Object PeaceSwitch.HotkeyWindow
$S.Hk.add_Pressed({ param($id) Safe { On-Hotkey $id } })

$MOD_ALT = 0x1; $MOD_CONTROL = 0x2; $MOD_NOREPEAT = 0x4000
$hotkeys = @(
    @{ Id = 1; Mod = 0;                                   Vk = 0x7C; Name = 'F13' }
    @{ Id = 2; Mod = 0;                                   Vk = 0x7D; Name = 'F14' }
    @{ Id = 3; Mod = $MOD_NOREPEAT;                       Vk = 0x7E; Name = 'F15' }
    @{ Id = 4; Mod = $MOD_CONTROL -bor $MOD_ALT -bor $MOD_NOREPEAT; Vk = 0x70; Name = 'Ctrl+Alt+F1' }
    @{ Id = 5; Mod = $MOD_CONTROL -bor $MOD_ALT -bor $MOD_NOREPEAT; Vk = 0x71; Name = 'Ctrl+Alt+F2' }
    @{ Id = 6; Mod = $MOD_CONTROL -bor $MOD_ALT -bor $MOD_NOREPEAT; Vk = 0x42; Name = 'Ctrl+Alt+B' }
)
$failed = @()
foreach ($h in $hotkeys) {
    $err = $S.Hk.Register($h.Id, $h.Mod, $h.Vk)
    if ($err) { $failed += $h.Name; Log "Raccourci $($h.Name) non réservé (err $err, déjà pris par une autre appli ?)" }
}

# RegisterHotKey exige les modificateurs exacts : sans ces variantes, F13-F15
# ne marchent plus en jeu quand Maj (sprint), Ctrl (accroupi) ou Alt est tenu.
$MOD_SHIFT = 0x4
foreach ($h in $hotkeys | Where-Object { $_.Id -le 3 }) {
    foreach ($m in 1..7) {
        $mod = $h.Mod
        if ($m -band 1) { $mod = $mod -bor $MOD_SHIFT }
        if ($m -band 2) { $mod = $mod -bor $MOD_CONTROL }
        if ($m -band 4) { $mod = $mod -bor $MOD_ALT }
        $err = $S.Hk.Register($h.Id + 10 * $m, $mod, $h.Vk)
        if ($err) { Log "Variante de $($h.Name) (mod 0x$('{0:X}' -f $mod)) non réservée (err $err)" }
    }
}

# Profil actif = celui qui est réellement dans peace.txt
$lines = Read-PeaceLines
$detected = Detect-ProfileFromPeace $lines
if ($detected) { $S.Active = $detected }
(GetProfile).Cur = Read-Preamp

# Éteint en mute (Preamp à -60) : on repart démuté, au volume par défaut
if ((GetProfile).Cur -le -59.95) {
    (GetProfile).Cur = (GetProfile).Default
    Write-Preamp (GetProfile).Cur
    Log "Démarrage : éteint en mute, volume remis par défaut ($(Fmt (GetProfile).Cur) dB)"
}

$syncTimer = New-Object System.Windows.Forms.Timer
$syncTimer.Interval = 5000
$syncTimer.add_Tick({ Safe { Sync-Peace } })
$syncTimer.Start()

Log "Démarrage script — profil actif détecté : $((GetProfile).Label) ($(Fmt (GetProfile).Cur) dB)"
if ($failed.Count) {
    Show-Osd '⚠ Raccourcis indisponibles' ($failed -join ', ') 5000 '801010'
} else {
    Show-Osd "Démarrage — $((GetProfile).Label)" "$(Fmt (GetProfile).Cur) dB" 3500
}

[System.Windows.Forms.Application]::Run()
