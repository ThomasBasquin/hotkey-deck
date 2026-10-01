# Peace Preamp AHK

Contrôle du preamp de [Peace](https://sourceforge.net/projects/peace-equalizer-apo-extension/) (interface graphique d'Equalizer APO) avec un OSD à l'écran, et bascule casque/enceintes.

Deux versions coexistent :

| Fichier | Statut | Notes |
|---------|--------|-------|
| `peace_switch.ps1` | **Version principale** (PowerShell) | Aucun hook clavier/souris ni injection de touches : n'est pas détecté comme logiciel de triche par les anti-cheats (ex. Easy Anti-Cheat dans The Finals) |
| `peace_preamp.ahk` | Version d'origine (AutoHotkey v2) | Conservée comme référence / repli ; son hook clavier bas niveau et le binaire AutoHotkey sont détectés par certains anti-cheats |

## Fonctionnalités

- Réglage du preamp par pas de 0.5 dB avec affichage OSD
- Deux profils : **Casque** (plafond -10 dB) et **Enceintes** (plafond -3 dB)
- Mute toggle
- Avertissement visuel à l'approche du plafond
- Synchronisation périodique avec `peace.txt` (détecte les changements externes)
- OSD affichant le profil actif dès le lancement du script
- Bascule de la sortie audio Windows par défaut avec le profil
- Correction automatique du GUID du périphérique (DAC USB qui change d'identité), avec nouvelle tentative (~1.2 s) si le périphérique n'est pas encore actif
- Écran noir anti burn-in OLED sur tous les écrans (Échap ou clic pour fermer)

## Raccourcis

| Raccourci | Action |
|-----------|--------|
| `F13` | Baisser le preamp (-0.5 dB) |
| `F14` | Monter le preamp (+0.5 dB) |
| `F15` | Toggle mute |
| `Ctrl+Alt+F1` | Profil Enceintes |
| `Ctrl+Alt+F2` | Profil Casque |
| `Ctrl+Alt+B` | Écran noir |

> Les touches F13–F15 sont typiquement assignées via un clavier programmable ou un logiciel de remapping.

## Version PowerShell (`peace_switch.ps1`)

### Différences de fonctionnement avec la version AHK

- **Raccourcis via `RegisterHotKey`** (API Windows standard, comme Discord ou OBS) au lieu d'un hook clavier bas niveau.
- **Le switch de profil écrit directement `peace.txt`** (lu par Equalizer APO via `Include: peace.txt` dans `config.txt`) au lieu d'envoyer `Ctrl+Alt+F1/F2` à Peace. Le contenu vient de modèles capturés depuis Peace dans `templates/` : seules les lignes `Device:` (GUID actuel) et `Preamp:` sont réécrites.
- **Peace reste cohérent avec le profil appliqué** : à son ouverture, Peace recharge `Last Configuration.peace` (et non le profil sélectionné) puis réécrit `peace.txt` avec. Le switch recopie donc aussi le profil dans `Last Configuration.peace` (après correction de son GUID) et met à jour `Selected Configuration=` dans `peace.ini`, sinon ouvrir Peace annulerait le switch. Limite : changer de profil *pendant* que Peace est ouvert ne met pas son interface à jour, et il réenregistrera son ancien état en se fermant.
- **Les modèles se mettent à jour seuls** : si l'EQ est modifié dans Peace, la sync périodique recopie le nouveau `peace.txt` dans le modèle du profil concerné.
- **Peace est fermé au démarrage** : il réserve lui aussi `Ctrl+Alt+F1/F2`, ce qui empêcherait le script de les obtenir. Il n'est pas nécessaire au son (c'est Equalizer APO qui applique `peace.txt`). Désactivable via `$ClosePeace` en haut du script.
- **DPI par écran** : l'OSD et l'écran noir s'affichent correctement sur des écrans à mises à l'échelle différentes.

### Installation

1. Installer [Equalizer APO](https://sourceforge.net/projects/equalizerapo/) et [Peace](https://sourceforge.net/projects/peace-equalizer-apo-extension/), créer les profils `Casque.peace` et `Enceintes.peace`.
2. Capturer les modèles : appliquer chaque profil dans Peace et copier `C:\Program Files\EqualizerAPO\config\peace.txt` vers `templates\casque.txt` / `templates\enceintes.txt`.
3. Lancement au démarrage via la tâche planifiée **"Peace Preamp Controller"** (déclencheur : ouverture de session, niveau d'exécution : le plus élevé — nécessaire pour pouvoir fermer Peace s'il tourne en admin), action :

   ```
   conhost.exe --headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "C:\Users\Thomas\Documents\AutoHotkey\peace_switch.ps1"
   ```

   `conhost --headless` évite le flash d'une fenêtre console. Une seule instance peut tourner à la fois (mutex).

Le fichier `.ps1` doit rester encodé en **UTF-8 avec BOM** (Windows PowerShell 5.1 lit sinon les accents et symboles de l'OSD en ANSI).

### Diagnostic

Journal dans `%TEMP%\peace_switch.log` (rotation au-delà de 256 Ko) : démarrage, raccourcis non réservables, switchs de profil, mises à jour des modèles, erreurs.

## Version AutoHotkey (`peace_preamp.ahk`)

### Prérequis

- [AutoHotkey v2](https://www.autohotkey.com/)
- Equalizer APO et Peace

### Installation

Le script a besoin des droits administrateur (il écrit dans `Program Files\EqualizerAPO\config\`) et s'auto-élève via `RunAs` s'il est lancé manuellement. Pour revenir à cette version au démarrage, remettre comme action de la tâche planifiée **"Peace Preamp Controller"** :

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\Users\Thomas\Documents\AutoHotkey\peace_preamp.ahk"
```

Contrairement à la version PowerShell, elle passe par les raccourcis de Peace (`Ctrl+Alt+F1/F2`) pour changer de profil, et réinstalle périodiquement son hook clavier (que certains jeux éjectent).

### Diagnostic

Journal dans `%TEMP%\peace_preamp.log` (rotation au-delà de 256 Ko).

## Configuration

Les profils sont définis en haut de chaque script (`$S.Profiles` en PowerShell, `Map` `profiles` en AHK). Chaque profil contient :

| Paramètre | Description |
|-----------|-------------|
| `default` | Valeur initiale au changement de profil |
| `min` | Plancher (dB) |
| `max` | Plafond (dB) |
| `step` | Pas d'incrémentation (dB) |
| `warnZone` | Zone d'avertissement avant le plafond (dB) |
