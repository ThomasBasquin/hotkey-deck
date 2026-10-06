# hotkey-deck — raccourcis clavier et deck à l'écran pour le PC
#
# Né comme portage PowerShell de peace_preamp.ahk (preamp de Peace / Equalizer
# APO), sans hook clavier/souris bas niveau ni injection de touches (ce qui
# faisait réagir l'anti-cheat) :
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
#   ²                → deck à l'écran (voir deck.ps1)
#
# Micro HyperX QuadCast S : icône dans la zone de notification (verte = actif,
# rouge barrée = coupé, grise = débranché/inconnu). Le micro n'expose pas son
# état, mais en capture "raw" (sans les effets Windows type Voice Clarity) il
# envoie des zéros exacts quand il est coupé, et toujours un souffle de fond
# quand il est actif. On l'écoute ~0,4 s au démarrage, à chaque appui sur le
# capteur (rapport HID) et sur clic gauche de l'icône.
#
# Les modèles (templates\*.txt) se mettent à jour tout seuls si tu modifies
# l'EQ dans Peace : la sync périodique recopie le nouveau peace.txt.

$ErrorActionPreference = 'Stop'

# Peace enregistre lui aussi Ctrl+Alt+F1/F2 : tant qu'il tourne, Windows
# refuse que ce script les réserve. Peace n'est pas nécessaire au son
# (c'est Equalizer APO qui applique peace.txt), donc on le ferme.
$ClosePeace = $true

# Affiche l'OSD ~1 s quand le micro change d'état (l'icône reste dans tous les cas)
$MicOsd = $true

# ============================================================
#  INSTANCE UNIQUE
# ============================================================
$mutex = New-Object System.Threading.Mutex($false, 'Local\HotkeyDeck')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace HotkeyDeck {
    // ---- WASAPI (capture "raw" du micro pour lire son état de mute) ----
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection col);
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out int n);
        int Item(int i, out IMMDevice dev);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        int OpenPropertyStore(int access, out IPropertyStore ps);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out int n);
        int GetAt(int i, out PropKey k);
        int GetValue(ref PropKey k, out PropVariant v);
    }
    [StructLayout(LayoutKind.Sequential)] struct PropKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Sequential)] struct PropVariant { public ushort vt, r1, r2, r3; public IntPtr p, p2; }
    [ComImport, Guid("726778CD-F60A-4eda-82DE-E47610CD78AA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient2 {
        int Initialize(int share, int flags, long dur, long period, IntPtr fmt, IntPtr session);
        int GetBufferSize(out uint n);
        int GetStreamLatency(out long l);
        int GetCurrentPadding(out uint p);
        int IsFormatSupported(int share, IntPtr fmt, out IntPtr closest);
        int GetMixFormat(out IntPtr fmt);
        int GetDevicePeriod(out long d, out long m);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr h);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        int IsOffloadCapable(int cat, out int cap);
        int SetClientProperties(ref AudioClientProperties p);
    }
    [StructLayout(LayoutKind.Sequential)] struct AudioClientProperties { public int cbSize, bIsOffload, eCategory, Options; }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient {
        int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong pos, out ulong qpc);
        int ReleaseBuffer(uint frames);
        int GetNextPacketSize(out uint n);
    }

    // Suit l'état de mute du QuadCast S, qui ne l'expose pas directement :
    //  - un thread lit l'interface HID, qui envoie un rapport (01 80 ...) à
    //    chaque appui sur le capteur de mute (bascule, sans l'état)
    //  - un second thread écoute alors le micro ~0,4 s en capture "raw"
    //    (sans les effets Windows) : coupé = zéros exacts, actif = souffle
    // Le script relit State/Version depuis un timer (pas d'appel inter-thread).
    public class MicWatcher {
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_Device_Interface_List_Size(out int len, ref Guid g, string devId, int flags);
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_Device_Interface_List(ref Guid g, string devId, char[] buf, int len, int flags);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFile(string n, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);

        static Guid HidGuid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        const string HidMatch  = "vid_0951&pid_171d&mi_03&col01";
        const string NameMatch = "QuadCast";

        public const int Unknown = 0, Active = 1, Muted = 2;
        public volatile int State;        // dernier état vérifié
        public volatile int Version;      // +1 à chaque vérification
        public volatile int Toggles;      // +1 à chaque appui (affichage immédiat)
        public volatile int CheckedToggles; // valeur de Toggles au début de la vérification
        public volatile bool Connected;
        public volatile string LastError;

        readonly AutoResetEvent wake = new AutoResetEvent(false);

        public void Start() {
            foreach (ThreadStart f in new ThreadStart[] { HidLoop, CheckLoop }) {
                var t = new Thread(f);
                t.IsBackground = true;
                t.Start();
            }
        }

        // Clic sur l'icône : revérifier tout de suite
        public void Recheck() { wake.Set(); }

        static string FindHidPath() {
            int len;
            if (CM_Get_Device_Interface_List_Size(out len, ref HidGuid, null, 0) != 0 || len < 2) return null;
            var buf = new char[len];
            if (CM_Get_Device_Interface_List(ref HidGuid, null, buf, len, 0) != 0) return null;
            foreach (var p in new string(buf).Split('\0'))
                if (p.ToLowerInvariant().Contains(HidMatch)) return p;
            return null;
        }

        void HidLoop() {
            while (true) {
                try {
                    string path = FindHidPath();
                    if (path != null) {
                        var h = CreateFile(path, 0x80000000 /* GENERIC_READ */, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                        if (!h.IsInvalid) {
                            Connected = true;
                            wake.Set();
                            try {
                                using (var fs = new FileStream(h, FileAccess.Read, 1, false)) {
                                    var b = new byte[64];
                                    while (true) {
                                        int n = fs.Read(b, 0, b.Length);
                                        if (n <= 0) break;
                                        if (n >= 2 && b[0] == 1 && (b[1] & 0x80) != 0) { Toggles++; wake.Set(); }
                                    }
                                }
                            } catch { }   // micro débranché
                            Connected = false;
                            wake.Set();
                        }
                    }
                } catch { }
                Thread.Sleep(2000);
            }
        }

        void CheckLoop() {
            while (true) {
                wake.WaitOne();
                // Laisse passer le bruit de l'appui et regroupe les appuis rapprochés
                while (wake.WaitOne(400)) { }
                int s = Unknown;
                int t = Toggles;
                if (Connected) {
                    try { s = CheckOnce(); }
                    catch (Exception e) { LastError = e.Message; }
                }
                State = s;
                CheckedToggles = t;
                Version++;
            }
        }

        static IMMDevice FindCaptureDevice() {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDeviceCollection col;
            if (en.EnumAudioEndpoints(1 /* eCapture */, 1 /* ACTIVE */, out col) != 0) return null;
            int n;
            col.GetCount(out n);
            var key = new PropKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
            for (int i = 0; i < n; i++) {
                IMMDevice dev;
                col.Item(i, out dev);
                IPropertyStore ps;
                if (dev.OpenPropertyStore(0, out ps) != 0) continue;
                PropVariant v;
                if (ps.GetValue(ref key, out v) != 0) continue;
                string name = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null;
                PropVariantClear(ref v);
                if (name != null && name.IndexOf(NameMatch, StringComparison.OrdinalIgnoreCase) >= 0) return dev;
            }
            return null;
        }

        int CheckOnce() {
            var dev = FindCaptureDevice();
            if (dev == null) { LastError = "endpoint micro introuvable"; return Unknown; }
            var iid = new Guid("726778CD-F60A-4eda-82DE-E47610CD78AA");
            object o;
            int hr = dev.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o);
            if (hr != 0) { LastError = "Activate 0x" + hr.ToString("X8"); return Unknown; }
            var ac = (IAudioClient2)o;
            var props = new AudioClientProperties { cbSize = 16, Options = 1 /* RAW */ };
            hr = ac.SetClientProperties(ref props);
            if (hr != 0) { LastError = "mode raw refusé 0x" + hr.ToString("X8"); return Unknown; }
            IntPtr fmt;
            ac.GetMixFormat(out fmt);
            int ch = Marshal.ReadInt16(fmt, 2), bits = Marshal.ReadInt16(fmt, 14), rate = Marshal.ReadInt32(fmt, 4);
            hr = ac.Initialize(0 /* partagé */, 0, 2000000, 0, fmt, IntPtr.Zero);
            Marshal.FreeCoTaskMem(fmt);
            if (hr != 0) { LastError = "Initialize 0x" + hr.ToString("X8"); return Unknown; }
            var ciid = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
            object co;
            ac.GetService(ref ciid, out co);
            var cc = (IAudioCaptureClient)co;

            // On ignore les 150 premières ms (démarrage du flux), puis on
            // juge sur au moins 250 ms : un seul échantillon non nul = actif.
            long needed = (long)rate * ch / 4, judged = 0;
            bool nonZero = false;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            ac.Start();
            try {
                while (!nonZero && sw.ElapsedMilliseconds < 1000 && (judged < needed || sw.ElapsedMilliseconds < 400)) {
                    uint pk;
                    cc.GetNextPacketSize(out pk);
                    while (pk > 0) {
                        IntPtr d; uint fr, fl; ulong a, b;
                        cc.GetBuffer(out d, out fr, out fl, out a, out b);
                        int cnt = (int)fr * ch;
                        if (sw.ElapsedMilliseconds >= 150) {
                            judged += cnt;
                            if ((fl & 2) == 0 /* pas SILENT */ && !nonZero) {
                                if (bits == 32) {
                                    var buf = new int[cnt];
                                    Marshal.Copy(d, buf, 0, cnt);
                                    foreach (var x in buf) if ((x & 0x7FFFFFFF) != 0) { nonZero = true; break; }
                                } else if (bits == 16) {
                                    var buf = new short[cnt];
                                    Marshal.Copy(d, buf, 0, cnt);
                                    foreach (var x in buf) if (x != 0) { nonZero = true; break; }
                                } else {
                                    var buf = new byte[cnt * bits / 8];
                                    Marshal.Copy(d, buf, 0, buf.Length);
                                    foreach (var x in buf) if (x != 0) { nonZero = true; break; }
                                }
                            }
                        }
                        cc.ReleaseBuffer(fr);
                        cc.GetNextPacketSize(out pk);
                    }
                    Thread.Sleep(10);
                }
            } finally {
                ac.Stop();
                Marshal.ReleaseComObject(cc);
                Marshal.ReleaseComObject(ac);
            }
            if (nonZero) return Active;
            if (judged < needed) { LastError = "pas assez d'audio reçu"; return Unknown; }
            return Muted;
        }
    }

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

[HotkeyDeck.Native]::EnableDpiAwareness()
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
    LogFile      = Join-Path $env:TEMP 'hotkey_deck.log'
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
    $hr = [HotkeyDeck.Native]::SetDefaultAudioDevice("{0.0.0.00000000}.$guid")
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
$osd = New-Object HotkeyDeck.OsdForm
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

# Icône optionnelle devant la valeur (glyphe Segoe Fluent Icons, ex. micro)
$txtIcon = New-Object System.Windows.Forms.Label
$txtIcon.AutoSize  = $false
$txtIcon.TextAlign = 'MiddleCenter'
$IconFont    = New-Object System.Drawing.Font('Segoe Fluent Icons', 20)
$IconFontBig = New-Object System.Drawing.Font('Segoe Fluent Icons', 26)
$txtIcon.Font      = $IconFont
$txtIcon.ForeColor = [System.Drawing.Color]::White
$txtIcon.Visible   = $false
$osd.Controls.Add($txtIcon)
$txtIcon.BringToFront()

# Coins arrondis Windows 11 + ombre
$osd.add_HandleCreated({
    $v = 2
    [HotkeyDeck.Native]::DwmSetWindowAttribute($osd.Handle, 33, [ref]$v, 4) | Out-Null
    [HotkeyDeck.Native]::DwmSetWindowAttribute($osd.Handle, 2,  [ref]$v, 4) | Out-Null
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

$ValueBounds = $txtValue.Bounds

function Show-Osd([string]$label, [string]$value, [int]$durationMs = 0, [string]$bgColor = '202020', [string]$glyph = '') {
    $dur = if ($durationMs -gt 0) { $durationMs } else { 2000 }
    $osd.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#$bgColor")
    $txtLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($(if ($bgColor -eq '801010') { '#FFCCCC' } else { '#AAAAAA' }))
    $txtLabel.Text = $label
    $txtValue.Text = $value
    if ($glyph -and -not $value) {
        # Icône seule, centrée à la place de la valeur
        $txtIcon.Font      = $IconFontBig
        $txtIcon.Text      = $glyph
        $txtIcon.BackColor = $osd.BackColor
        $txtIcon.Bounds    = $ValueBounds
        $txtIcon.Visible   = $true
        $txtValue.Visible  = $false
    } elseif ($glyph) {
        # Icône + texte centrés ensemble sur la ligne de la valeur
        $txtIcon.Font = $IconFont
        $txtValue.Visible = $true
        $tw  = [System.Windows.Forms.TextRenderer]::MeasureText($value, $txtValue.Font).Width
        $iw  = Px 32; $gap = Px 6
        $x   = [int](($osd.ClientSize.Width - ($iw + $gap + $tw)) / 2)
        $txtIcon.Text      = $glyph
        $txtIcon.BackColor = $osd.BackColor
        $txtIcon.Bounds    = New-Object System.Drawing.Rectangle($x, $ValueBounds.Y, $iw, $ValueBounds.Height)
        $txtValue.TextAlign = 'MiddleLeft'
        $txtValue.Bounds    = New-Object System.Drawing.Rectangle(($x + $iw + $gap), $ValueBounds.Y, ($tw + (Px 4)), $ValueBounds.Height)
        $txtIcon.Visible   = $true
    } else {
        $txtIcon.Visible    = $false
        $txtValue.Visible   = $true
        $txtValue.TextAlign = 'MiddleCenter'
        $txtValue.Bounds    = $ValueBounds
    }
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
        $f = New-Object HotkeyDeck.BlackForm
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
        [HotkeyDeck.Native]::PlaceTopmost($f.Handle, $b.X, $b.Y, $b.Width, $b.Height)
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
#  MICRO (HyperX QuadCast S)
# ============================================================
function New-MicIcon([string]$hex, [bool]$slash) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $c = [System.Drawing.ColorTranslator]::FromHtml("#$hex")
    $br = New-Object System.Drawing.SolidBrush $c
    $pen = New-Object System.Drawing.Pen $c, 2.5

    # Capsule
    $cap = New-Object System.Drawing.Drawing2D.GraphicsPath
    $cap.AddArc(11, 2, 10, 10, 180, 180)
    $cap.AddArc(11, 10, 10, 10, 0, 180)
    $cap.CloseFigure()
    $g.FillPath($br, $cap)
    # Arceau, pied et socle
    $g.DrawArc($pen, 7, 8, 18, 16, 0, 180)
    $g.DrawLine($pen, 16, 24, 16, 29)
    $g.DrawLine($pen, 10, 29, 22, 29)
    if ($slash) {
        $g.DrawLine((New-Object System.Drawing.Pen $c, 3.5), 4, 3, 28, 29)
    }
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$MicIcons = @{
    On   = New-MicIcon '3FB950' $false
    Off  = New-MicIcon 'F85149' $true
    Gone = New-MicIcon '8B949E' $true
}

$S.Mic = @{ Ver = 0; Tog = 0; State = -1; Connected = $null }

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = $MicIcons.Gone
$tray.Text    = 'QuadCast : recherche…'
$tray.Visible = $true

function Update-MicIcon {
    $m = $S.Mic
    if (-not $m.Connected) {
        $tray.Icon = $MicIcons.Gone; $tray.Text = 'QuadCast : débranché'
    } elseif ($m.State -eq [HotkeyDeck.MicWatcher]::Muted) {
        $tray.Icon = $MicIcons.Off;  $tray.Text = 'QuadCast : COUPÉ'
    } elseif ($m.State -eq [HotkeyDeck.MicWatcher]::Active) {
        $tray.Icon = $MicIcons.On;   $tray.Text = 'QuadCast : actif'
    } else {
        $tray.Icon = $MicIcons.Gone; $tray.Text = 'QuadCast : état inconnu (clic = revérifier)'
    }
}

function Show-MicOsd {
    if (-not $MicOsd) { return }
    # Coupé : icône seule (glyphe Segoe Fluent Icons F781 = micro barré)
    if ($S.Mic.State -eq [HotkeyDeck.MicWatcher]::Muted) { Show-Osd 'Micro' '' 1000 '202020' ([string][char]0xF781) }
    else                                                  { Show-Osd 'Micro' 'Activé' 1000 }
}

$micWatcher = New-Object HotkeyDeck.MicWatcher

# Clic gauche : revérifie l'état réel du micro
$tray.add_MouseClick({ param($src, $e) if ($e.Button -eq 'Left') { Safe { $micWatcher.Recheck() } } })

function Poll-Mic {
    $m = $S.Mic
    $con = $micWatcher.Connected
    if ($con -ne $m.Connected) {
        $m.Connected = $con
        Log "Micro : QuadCast $(if ($con) { 'détecté' } else { 'débranché' })"
        if (-not $con) { $m.State = -1 }
        Update-MicIcon
    }

    # Appui sur le capteur : on affiche tout de suite l'état inversé,
    # la vérification audio qui suit corrigera si besoin
    $tog = $micWatcher.Toggles
    if ($tog -ne $m.Tog) {
        $odd = (($tog - $m.Tog) % 2) -ne 0
        $m.Tog = $tog
        if ($odd -and $m.State -gt 0) {
            $m.State = 3 - $m.State   # Active (1) <-> Muted (2)
            Update-MicIcon
            Show-MicOsd
        }
    }

    $ver = $micWatcher.Version
    if ($ver -ne $m.Ver) {
        $m.Ver = $ver
        # Résultat périmé si un appui a eu lieu pendant la vérification
        # (une nouvelle vérification est déjà en route)
        if ($micWatcher.CheckedToggles -ne $micWatcher.Toggles) { return }
        $prev = $m.State
        $m.State = $micWatcher.State
        if ($m.State -eq [HotkeyDeck.MicWatcher]::Unknown -and $m.Connected) {
            Log "Micro : vérification impossible ($($micWatcher.LastError))"
        }
        if ($m.State -ne $prev) {
            Update-MicIcon
            # Correction d'un affichage faux (pas au démarrage)
            if ($prev -gt 0 -and $m.State -gt 0) {
                Log "Micro : état corrigé par la vérification"
                Show-MicOsd
            }
        }
    }
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
        7   { Toggle-Deck }
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

$S.Hk = New-Object HotkeyDeck.HotkeyWindow
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

$micWatcher.Start()
$micTimer = New-Object System.Windows.Forms.Timer
$micTimer.Interval = 50
$micTimer.add_Tick({ Safe { Poll-Mic } })
$micTimer.Start()

# Deck à l'écran (touche ²)
. (Join-Path $PSScriptRoot 'deck.ps1')

Log "Démarrage script — profil actif détecté : $((GetProfile).Label) ($(Fmt (GetProfile).Cur) dB)"
if ($failed.Count) {
    Show-Osd '⚠ Raccourcis indisponibles' ($failed -join ', ') 5000 '801010'
} else {
    Show-Osd "Démarrage — $((GetProfile).Label)" "$(Fmt (GetProfile).Cur) dB" 3500
}

[System.Windows.Forms.Application]::Run()
