#Requires AutoHotkey v2.0

; OSD pour Peace (preamp en dB) — dual profil casque / enceintes
;
; Raccourcis:
;   F13              → baisser (step dB)
;   F14              → monter  (step dB)
;   F15              → toggle mute
;   Ctrl+Alt+F1      → profil enceintes (Peace gère le switch EQ)
;   Ctrl+Alt+F2      → profil casque    (idem)

; Réinstalle le hook clavier périodiquement (les jeux peuvent l'éjecter)
SetTimer(() => InstallKeybdHook(true, true), 5000)

; Admin requis pour écrire dans Program Files
if !A_IsAdmin {
    Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp()
}

peaceFile      := "C:\Program Files\EqualizerAPO\config\peace.txt"
casqueFile     := "C:\Program Files\EqualizerAPO\config\Casque.peace"
enceintesFile  := "C:\Program Files\EqualizerAPO\config\Enceintes.peace"
peaceExe       := "C:\Program Files\EqualizerAPO\config\Peace.exe"
peaceDir       := "C:\Program Files\EqualizerAPO\config"

; ============================================================
;  JOURNAL DE DIAGNOSTIC
; ============================================================
; Log horodaté (hors du dépôt git) pour pouvoir rejouer après coup ce qui
; s'est passé lors d'un switch casque/enceintes qui semble avoir raté.
logFile := A_Temp "\peace_preamp.log"

LogEvent(msg) {
    global logFile
    try {
        if FileExist(logFile) && FileGetSize(logFile) > 262144
            FileDelete(logFile)
    }
    ts := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "." Format("{:03}", A_MSec)
    try FileAppend(ts "  " msg "`r`n", logFile, "UTF-8")
}

; ============================================================
;  CONFIGURATION DES PROFILS
; ============================================================

profiles := Map()

profiles["casque"] := {
    label     : "Casque",
    default   : -15.0,
    cur       :   0.0,
    min       : -30.0,
    max       :  -8.0,   ; = -(boost max de l'EQ casque : +8 dB)
    step      :   0.5,
    warnZone  :   1.5
}

profiles["enceintes"] := {
    label     : "Enceintes",
    default   : -10.0,
    cur       :   0.0,
    min       : -30.0,
    max       :  -3.0,   ; = -(boost max de l'EQ enceintes : +3 dB)
    step      :   0.5,
    warnZone  :   1.5
}

activeKey := DetectActiveProfile()
profiles["casque"].cur    := profiles["casque"].default
profiles["enceintes"].cur := profiles["enceintes"].default
muted := false

; Sync le profil actif avec la valeur réelle de peace.txt au démarrage
profiles[activeKey].cur := ReadPreamp()

; ============================================================
;  LECTURE / ÉCRITURE PREAMP
; ============================================================

ReadPreamp() {
    global peaceFile
    try {
        loop read, peaceFile {
            if RegExMatch(A_LoopReadLine, "^Preamp:\s*([-\d.]+)", &m)
                return Float(m[1])
        }
    }
    return 0.0
}

WritePreamp(val) {
    global peaceFile, profiles, activeKey
    ; Filet de sécurité matériel : jamais au-dessus du plafond du profil actif
    val := Min(val, profiles[activeKey].max)
    content := ""
    loop read, peaceFile
        content .= RegExReplace(A_LoopReadLine, "^Preamp:.*", "Preamp: " Format("{:.1f}", val) " dB") "`r`n"
    f := FileOpen(peaceFile, "w")
    f.Write(content)
    f.Close()
}

; Sync périodique : vérifie que p.cur correspond à ce qu'il y a dans peace.txt
SyncPreamp() {
    global muted
    p := GetProfile()
    if (muted)   ; peace.txt est à -60, p.cur est la valeur pré-mute → pas de sync
        return
    actual := ReadPreamp()
    drift  := Abs(actual - p.cur)
    if (drift >= 0.5) {
        p.cur := actual
        ShowOSD("⚠ Sync (" p.label ")", Fmt(actual) " dB", 2500, "804000")
    }
}

SetTimer(SyncPreamp, 5000)

; ============================================================
;  OSD
; ============================================================
osdW     := 280
osdX     := (A_ScreenWidth  - osdW - 20) // 2
osdY     := A_ScreenHeight - 165
hideMs    := 2000
osdAlpha  := 242
osdHideAt := 0

osd      := ""
txtLabel := ""
txtValue := ""

CreateOSD() {
    global osd, txtLabel, txtValue, osdW, osdX, osdY
    SetTimer(OSDTick, 0)
    if IsObject(osd)
        try osd.Destroy()
    osd := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
    osd.MarginX := 10
    osd.MarginY := 12
    osd.BackColor := "202020"
    osd.SetFont("s10 cAAAAAA", "Segoe UI")
    txtLabel := osd.AddText("Center w" osdW " h22", "")
    osd.SetFont("s22 cFFFFFF Bold", "Segoe UI")
    txtValue := osd.AddText("Center w" osdW, "")
    osd.Show("NoActivate x" osdX " y" osdY)
    WinSetTransparent(242, osd)
    osd.Hide()
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", osd.Hwnd, "UInt", 33, "UInt*", 2, "UInt", 4)
    DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", osd.Hwnd, "UInt", 2, "UInt*", 2, "UInt", 4)
}

CreateOSD()

; Affichage initial : quel profil/périphérique est actif dès le lancement du
; script (utile notamment au démarrage de Windows, sans avoir à toucher un
; raccourci pour le savoir).
LogEvent("Démarrage script — profil actif détecté : " profiles[activeKey].label " (" Fmt(profiles[activeKey].cur) " dB)")
ShowOSD("Démarrage — " profiles[activeKey].label, Fmt(profiles[activeKey].cur) " dB", 3500)

ShowOSD(label, value, durationMs := 0, bgColor := "202020") {
    global osd, txtLabel, txtValue, hideMs, osdAlpha, osdHideAt, osdX, osdY
    if !IsObject(osd)
        CreateOSD()
    dur := durationMs > 0 ? durationMs : hideMs
    osd.BackColor := bgColor
    if (bgColor = "801010")
        txtLabel.SetFont("s10 cFFCCCC norm", "Segoe UI")
    else
        txtLabel.SetFont("s10 cAAAAAA norm", "Segoe UI")
    txtLabel.Text := label
    txtValue.Text := value
    osdAlpha  := 242
    osdHideAt := A_TickCount + dur
    WinSetTransparent(242, osd)
    WinSetAlwaysOnTop(1, osd)
    osd.Show("NoActivate x" osdX " y" osdY)
    SetTimer(OSDTick, 25)
}

OSDTick() {
    global osd, osdAlpha, osdHideAt
    if (A_TickCount < osdHideAt)
        return
    osdAlpha -= 27
    if (osdAlpha <= 0) {
        SetTimer(OSDTick, 0)
        osd.Hide()
        osdAlpha := 242
        WinSetTransparent(242, osd)
        return
    }
    WinSetTransparent(osdAlpha, osd)
}

; ============================================================
;  DEVICES AUDIO — anti-dérive GUID (DAC USB qui change d'identité)
; ============================================================
; Chaque profil .peace est verrouillé sur un "Device GUID" Windows figé.
; Un DAC USB peut se voir attribuer un nouveau GUID par
; Windows à chaque reconnexion/veille, ce qui rend le profil incapable de
; retrouver le périphérique → le switch ne fait plus rien, silencieusement.
; On revérifie donc le GUID juste avant chaque switch et on le corrige au vol.

MMRenderKey := "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"
PKEY_JackName    := "{a45c254e-df1c-4efd-8020-67d146a850e0},2"
PKEY_ProductName := "{b3f8fa53-0004-438e-9003-51a46e139bfc},6"

; Lit "Device=<jack>, <produit>" dans le fichier .peace
ReadDeviceRef(peaceProfileFile) {
    loop read, peaceProfileFile {
        if RegExMatch(A_LoopReadLine, "^Device=([^,]+),\s*(.+)$", &m)
            return { jack: Trim(m[1]), product: Trim(m[2]) }
    }
    return ""
}

; Lit le "Device GUID=" déclaré dans un profil .peace
ReadProfileGuid(peaceProfileFile) {
    loop read, peaceProfileFile {
        if RegExMatch(A_LoopReadLine, "^Device GUID=(\{[0-9a-fA-F-]+\})", &m)
            return m[1]
    }
    return ""
}

; Détecte quel profil est réellement chargé dans Peace au démarrage du script,
; en comparant le GUID du device actif (écrit par Peace dans peace.txt) à celui
; déclaré dans chaque profil. Évite de supposer "enceintes" à tort si la
; dernière session s'est terminée sur "casque".
DetectActiveProfile() {
    global peaceFile, casqueFile, enceintesFile
    currentGuid := ""
    loop read, peaceFile {
        if RegExMatch(A_LoopReadLine, "^Device:.*(\{[0-9a-fA-F-]+\})", &m) {
            currentGuid := m[1]
            break
        }
    }
    if (currentGuid = "")
        return "enceintes"
    if (ReadProfileGuid(casqueFile) = currentGuid)
        return "casque"
    return "enceintes"
}

; Cherche parmi les endpoints AUDIO ACTIFS celui dont jack+produit correspondent
FindActiveDeviceGuid(jack, product) {
    global MMRenderKey, PKEY_JackName, PKEY_ProductName
    loop reg, MMRenderKey, "K" {
        guidKey := A_LoopRegName
        try state := RegRead(MMRenderKey "\" guidKey, "DeviceState")
        catch
            continue
        if ((state & 0xF) != 1)   ; pas "Active"
            continue
        try {
            j := RegRead(MMRenderKey "\" guidKey "\Properties", PKEY_JackName)
            p := RegRead(MMRenderKey "\" guidKey "\Properties", PKEY_ProductName)
        } catch
            continue
        if (j = jack && p = product)
            return guidKey
    }
    return ""
}

; Comme FindActiveDeviceGuid, mais retente pendant quelques centaines de ms.
; Utile car un DAC USB qui vient d'être branché/réveillé met parfois un
; instant avant que Windows ne le marque "Active" dans le registre — sans
; retry, un switch pile à ce moment-là échoue silencieusement.
FindActiveDeviceGuidRetry(jack, product, maxWaitMs := 1200, intervalMs := 150) {
    start := A_TickCount
    loop {
        g := FindActiveDeviceGuid(jack, product)
        if (g != "")
            return g
        if (A_TickCount - start >= maxWaitMs)
            return ""
        Sleep(intervalMs)
    }
}

; Vérifie que le périphérique du profil est bien branché/actif.
; Si oui : corrige le "Device GUID=" dans le fichier s'il a dérivé, renvoie true
;          et ressort le GUID actif via outGuid (pour switcher la sortie Windows).
; Si non (éteint/débranché) : renvoie false sans toucher au fichier.
EnsureDeviceReady(peaceProfileFile, &outGuid := "") {
    ref := ReadDeviceRef(peaceProfileFile)
    if !IsObject(ref) {
        LogEvent("EnsureDeviceReady: pas de ligne Device= dans " peaceProfileFile " -> on laisse passer")
        return true  ; pas de ligne Device= trouvée, on ne bloque pas
    }

    activeGuid := FindActiveDeviceGuidRetry(ref.jack, ref.product)
    if (activeGuid = "") {
        LogEvent("EnsureDeviceReady: ÉCHEC — '" ref.jack "' / '" ref.product "' introuvable parmi les endpoints actifs (après retry)")
        return false
    }
    LogEvent("EnsureDeviceReady: '" ref.jack "' / '" ref.product "' -> " activeGuid)

    content := ""
    changed := false
    loop read, peaceProfileFile {
        line := A_LoopReadLine
        if RegExMatch(line, "^Device GUID=\{[0-9a-fA-F-]+\}") {
            newLine := "Device GUID=" activeGuid
            if (line != newLine)
                changed := true
            line := newLine
        }
        content .= line "`r`n"
    }
    if changed {
        f := FileOpen(peaceProfileFile, "w")
        f.Write(content)
        f.Close()
        LogEvent("EnsureDeviceReady: GUID corrigé dans " peaceProfileFile " (dérive détectée)")
    }
    outGuid := activeGuid
    return true
}

; Après avoir envoyé le hotkey de switch à Peace, on ne peut pas supposer
; que le changement a réussi : on relit peace.txt jusqu'à ce que la ligne
; "Device:" corresponde bien au GUID attendu (ou jusqu'au timeout). Ça
; confirme réellement que Peace a chargé le bon profil, au lieu de deviner
; que le Preamp vaut la valeur "default" codée en dur.
ConfirmProfileApplied(expectedGuid, timeoutMs := 1500, intervalMs := 100) {
    global peaceFile
    start := A_TickCount
    loop {
        actualGuid := "", actualPreamp := ""
        loop read, peaceFile {
            line := A_LoopReadLine
            if InStr(line, "Device:") && RegExMatch(line, "(\{[0-9a-fA-F-]+\})", &m)
                actualGuid := m[1]
            else if RegExMatch(line, "^Preamp:\s*([-\d.]+)", &m2)
                actualPreamp := Float(m2[1])
        }
        if (actualGuid = expectedGuid)
            return actualPreamp = "" ? 0.0 : actualPreamp
        if (A_TickCount - start >= timeoutMs)
            return ""
        Sleep(intervalMs)
    }
}

; Peace garde en mémoire une association périphérique↔profil qui ne se
; rafraîchit pas toujours quand un DAC USB change de GUID (même si notre
; fichier .peace est déjà correct) — le switch échoue alors silencieusement
; jusqu'à ce que Peace soit relancé. On automatise ce redémarrage comme
; filet de récupération quand une confirmation échoue.
RestartPeace() {
    global peaceExe, peaceDir
    LogEvent("Redémarrage de Peace (cache périphérique probablement périmé)")
    ProcessClose("Peace.exe")
    ProcessWaitClose("Peace.exe", 3)
    try Run(peaceExe, peaceDir)
    Sleep(1500)  ; laisse Peace s'initialiser et réenregistrer ses hotkeys
}

; ============================================================
;  SORTIE AUDIO WINDOWS PAR DÉFAUT
; ============================================================
; Bascule le device de lecture par défaut de Windows (les 3 rôles :
; multimédia, communications, console) via l'interface COM non documentée
; IPolicyConfig — le même mécanisme utilisé par nircmd / EarTrumpet.

CLSID_PolicyConfig := "{870af99c-171d-4f9e-af0d-e63df40c2bc9}"
IID_IPolicyConfig  := "{f8679f50-850a-41cf-9c72-430f290290c8}"

SetDefaultAudioDevice(guid) {
    global CLSID_PolicyConfig, IID_IPolicyConfig
    deviceId := "{0.0.0.00000000}." guid
    try {
        pPolicyConfig := ComObject(CLSID_PolicyConfig, IID_IPolicyConfig)
        for role in [0, 1, 2]  ; eConsole, eMultimedia, eCommunications
            ComCall(13, pPolicyConfig, "wstr", deviceId, "int", role)
    }
}

; ============================================================
;  UTILITAIRES
; ============================================================
GetProfile() {
    global profiles, activeKey
    return profiles[activeKey]
}

Fmt(val) {
    return Format("{:.1f}", val)
}

; ============================================================
;  HOTKEYS
; ============================================================

; --- Volume bas ---
$F13:: {
    global muted
    p := GetProfile()

    newVal := p.cur - p.step
    if (newVal < p.min) {
        p.cur := p.min
        muted := false
        WritePreamp(p.cur)
        ShowOSD(p.label, Fmt(p.cur) " dB  [MIN]")
        return
    }

    p.cur  := newVal
    muted  := false
    WritePreamp(p.cur)

    if (p.cur > p.max)
        ShowOSD("Plafond dépassé (" Fmt(p.max) " dB)", "⚠   " Fmt(p.cur) " dB", 0, "801010")
    else if (p.cur >= p.max - p.warnZone)
        ShowOSD(p.label, "⚠   " Fmt(p.cur) " dB")
    else
        ShowOSD(p.label, Fmt(p.cur) " dB")
}

; --- Volume haut ---
$F14:: {
    global muted
    p := GetProfile()

    newVal := p.cur + p.step
    if (newVal > p.max) {
        p.cur := p.max
        muted := false
        WritePreamp(p.cur)
        ShowOSD("Plafond (" Fmt(p.max) " dB)", "⚠   " Fmt(p.cur) " dB", 0, "801010")
        return
    }

    p.cur  := newVal
    muted  := false
    WritePreamp(p.cur)

    if (p.cur >= p.max - p.warnZone)
        ShowOSD(p.label, "⚠   " Fmt(p.cur) " dB")
    else
        ShowOSD(p.label, Fmt(p.cur) " dB")
}

; --- Mute toggle ---
$F15:: {
    global muted
    p := GetProfile()
    muted := !muted
    if (muted)
        WritePreamp(-60.0)
    else
        WritePreamp(p.cur)
    ShowOSD(p.label, muted ? "🔇" : Fmt(p.cur) " dB")
}

; --- Profil enceintes ---
$^!F1:: {
    global activeKey, muted, osdX, osdY, osdW, enceintesFile
    LogEvent("Ctrl+Alt+F1 pressé -> demande profil Enceintes")
    if !EnsureDeviceReady(enceintesFile, &guid) {
        ShowOSD("⚠ Enceintes", "Non détecté", 3000, "801010")
        return
    }
    if (guid != "")
        SetDefaultAudioDevice(guid)
    activeKey := "enceintes"
    muted := false
    Send("^!{F1}")
    p := GetProfile()
    result := ConfirmProfileApplied(guid)
    recovered := false
    if (result = "") {
        LogEvent("⚠ Switch Enceintes non confirmé, tentative de récupération (redémarrage de Peace)")
        RestartPeace()
        Send("^!{F1}")
        result := ConfirmProfileApplied(guid, 2500)
        recovered := true
    }
    osdX := (A_ScreenWidth - osdW - 20) // 2
    osdY := A_ScreenHeight - 165
    if (result = "") {
        LogEvent("⚠ Switch Enceintes toujours non confirmé après redémarrage de Peace")
        p.cur := p.default
        ShowOSD("⚠ " p.label, "Non confirmé", 3000, "804000")
    } else {
        p.cur := result
        LogEvent("✓ Switch Enceintes confirmé" (recovered ? " (après redémarrage de Peace)" : "") ", Preamp=" Fmt(p.cur) " dB")
        ShowOSD(p.label, Fmt(p.cur) " dB", 2500)
    }
}

; --- Profil casque ---
$^!F2:: {
    global activeKey, muted, osdX, osdY, osdW, casqueFile
    LogEvent("Ctrl+Alt+F2 pressé -> demande profil Casque")
    if !EnsureDeviceReady(casqueFile, &guid) {
        ShowOSD("⚠ Casque", "Non détecté", 3000, "801010")
        return
    }
    if (guid != "")
        SetDefaultAudioDevice(guid)
    activeKey := "casque"
    muted := false
    Send("^!{F2}")
    p := GetProfile()
    result := ConfirmProfileApplied(guid)
    recovered := false
    if (result = "") {
        LogEvent("⚠ Switch Casque non confirmé, tentative de récupération (redémarrage de Peace)")
        RestartPeace()
        Send("^!{F2}")
        result := ConfirmProfileApplied(guid, 2500)
        recovered := true
    }
    osdX := (A_ScreenWidth - osdW - 20) // 2
    osdY := A_ScreenHeight - 165
    if (result = "") {
        LogEvent("⚠ Switch Casque toujours non confirmé après redémarrage de Peace")
        p.cur := p.default
        ShowOSD("⚠ " p.label, "Non confirmé", 3000, "804000")
    } else {
        p.cur := result
        LogEvent("✓ Switch Casque confirmé" (recovered ? " (après redémarrage de Peace)" : "") ", Preamp=" Fmt(p.cur) " dB")
        ShowOSD(p.label, Fmt(p.cur) " dB", 2500)
    }
}

; ============================================================
;  ÉCRAN NOIR (anti burn-in OLED pendant une absence courte)
; ============================================================
; Ctrl+Alt+B → couvre tous les écrans de noir opaque, sans éteindre
; le signal vidéo (donc pas de cycle de nettoyage de pixels du moniteur).
; Se ferme sur Échap ou clic gauche uniquement (pas de boucle "toutes
; touches" : ça avait enregistré des hotkeys sur Ctrl/Alt/Shift/Win seuls
; et bloqué tout le clavier le 2026-09-19).

blackScreenGuis := []

IsBlackScreenActive() {
    global blackScreenGuis
    return blackScreenGuis.Length > 0
}

ShowBlackScreen() {
    global blackScreenGuis
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &L, &T, &R, &B)
        g := Gui("-Caption +AlwaysOnTop +ToolWindow")
        g.BackColor := "000000"
        g.Show(Format("x{1} y{2} w{3} h{4} NoActivate", L, T, R - L, B - T))
        blackScreenGuis.Push(g)
    }
}

HideBlackScreen() {
    global blackScreenGuis
    for g in blackScreenGuis
        g.Destroy()
    blackScreenGuis := []
}

$^!b:: {
    if IsBlackScreenActive()
        HideBlackScreen()
    else
        ShowBlackScreen()
}

#HotIf IsBlackScreenActive()
Escape::HideBlackScreen()
LButton::HideBlackScreen()
#HotIf
