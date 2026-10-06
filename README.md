# hotkey-deck

Raccourcis clavier et deck à l'écran pour piloter un PC Windows de jeu, sans se faire repérer par les anti-cheats :

- **Son** : volume (preamp d'[Equalizer APO](https://sourceforge.net/projects/equalizerapo/) / [Peace](https://sourceforge.net/projects/peace-equalizer-apo-extension/)) avec OSD, mute, bascule casque/enceintes
- **Micro** : état du HyperX QuadCast S (actif / coupé) à l'OSD et dans le deck
- **Écran** : écran noir anti burn-in OLED, bascule du HDR Windows
- **GPU** : bascule entre les profils MSI Afterburner stock et overclock, températures CPU/GPU
- **Enregistrement** : sauvegarde de l'Instant Replay NVIDIA

Tout tient dans un script PowerShell lancé au démarrage. Le projet est né comme simple contrôle du preamp de Peace en AutoHotkey (`peace_preamp.ahk`, conservé comme repli).

| Fichier | Rôle |
|---------|------|
| `hotkey_deck.ps1` | **Script principal** : raccourcis, son, micro, OSD, écran noir ; charge `deck.ps1` |
| `deck.ps1` | Deck à l'écran (touche `²`) |
| `backup_peace.ps1` | Sauvegarde des profils Peace dans `peace-config\` |
| `templates\` | Modèles `peace.txt` des profils Casque / Enceintes |
| `peace_preamp.ahk` | Version d'origine (AutoHotkey v2), détectée par certains anti-cheats |

## Raccourcis

| Raccourci | Action |
|-----------|--------|
| `F13` | Baisser le volume (-0.5 dB) |
| `F14` | Monter le volume (+0.5 dB) |
| `F15` | Mute |
| `Ctrl+Alt+F1` | Profil Enceintes |
| `Ctrl+Alt+F2` | Profil Casque |
| `Ctrl+Alt+B` | Écran noir (Échap ou clic pour fermer) |
| `²` | Deck à l'écran |

> Les touches F13–F15 sont assignées via un clavier programmable (molette). Elles marchent aussi avec Maj/Ctrl/Alt enfoncés (sprint, accroupi en jeu).

## Deck à l'écran

Équivalent d'un Stream Deck affiché par-dessus l'écran. La touche **²** l'ouvre au centre de l'écran de la fenêtre active. On clique sur un bouton, ou on tape son numéro (1–6). Échap, ² ou un clic ailleurs le referment, et le focus revient au jeu.

```
    SON           ÉCRAN          JEU
  [Casque]      [HDR]          [Overclock GPU]
  [Enceintes]   [Écran noir]   [Instant Replay]
  ─────────────────────────────────────────────
   Micro actif      CPU 46°        GPU 27°
```

Les boutons sont rangés par thème, numérotés colonne par colonne. Une carte « allumée » (teintée) indique un état actif. La barre du bas est en lecture seule.

| Bouton | Action |
|--------|--------|
| Casque, Enceintes | Applique ce profil audio (comme `Ctrl+Alt+F1/F2`) ; le profil actif est allumé avec son volume. Recliquer dessus ne le réapplique pas (ça remettrait le volume par défaut) |
| HDR | Active/désactive le HDR Windows sur les écrans qui le supportent (API DisplayConfig) |
| Écran noir | Comme `Ctrl+Alt+B` |
| Overclock GPU | Applique le profil Afterburner 2 (OC) ou 1 (stock) via `MSIAfterburner.exe -ProfileN` ; allumé quand l'OC est actif (limite de puissance relevée, lue via NVML) |
| Instant Replay | Envoie `Alt+F10` (sauvegarde Instant Replay NVIDIA) |

Barre d'état : état du micro (revérifié à chaque ouverture du deck et suivi en direct), températures CPU et GPU lues dans la mémoire partagée d'Afterburner (rafraîchies chaque seconde).

Les numéros de profils Afterburner, le raccourci NVIDIA et les seuils de l'alerte température sont réglables dans `$DeckCfg`, en haut de `deck.ps1`.

**Alerte température** : l'OSD prévient quand le CPU ou le GPU reste au-dessus de 67 °C pendant deux relevés de suite (relevé toutes les 5 s, donc ~10 s : les pics brefs sont ignorés). Une seule alerte par dépassement, réarmée une fois redescendu sous 64 °C (en jeu, The Finals en 4K : ~58 °C CPU et ~60 °C GPU, max 63 °C).

**Plein écran** : le deck s'affiche par-dessus les jeux en plein écran fenêtré / sans bordure (cas de la plupart des jeux DX12 / DX11 récents). Aucun programme externe ne peut s'afficher par-dessus un jeu en plein écran **exclusif** sans s'injecter dans son rendu (ce que font seulement les overlays autorisés par les anti-cheats : Steam, Discord, NVIDIA). Dans ce cas, le deck s'ouvre sur l'autre écran.

## Compatibilité anti-cheat

La première version (AutoHotkey) était détectée par Easy Anti-Cheat (The Finals) à cause de son hook clavier bas niveau. Le script PowerShell n'en utilise aucun :

- **Raccourcis via `RegisterHotKey`** (API Windows standard, comme Discord ou OBS). Windows avale les touches réservées : `²` ne tape plus de ², y compris dans les jeux qui l'utilisent pour leur console.
- **Mesures en lecture seule** : mémoire partagée d'Afterburner, NVML, capture audio du micro.
- **Une seule entrée simulée** : `Alt+F10` pour l'Instant Replay (NVIDIA n'offre pas d'API), envoyée pendant que le deck a le focus, donc jamais reçue par le jeu.

## Son : fonctionnement

- **Le switch de profil écrit directement `peace.txt`** (lu par Equalizer APO via `Include: peace.txt` dans `config.txt`) au lieu d'envoyer `Ctrl+Alt+F1/F2` à Peace. Le contenu vient de modèles capturés depuis Peace dans `templates/` : seules les lignes `Device:` (GUID actuel) et `Preamp:` sont réécrites. La sortie audio Windows par défaut suit le profil.
- **Plafond par profil** : Casque -8 dB, Enceintes -5 dB. Chaque plafond vaut l'opposé du plus gros boost de l'EQ du profil (+8 / +5 dB), pour que le signal ne sature jamais. L'OSD prévient à l'approche du plafond.
- **Peace reste cohérent avec le profil appliqué** : à son ouverture, Peace recharge `Last Configuration.peace` (et non le profil sélectionné) puis réécrit `peace.txt` avec. Le switch recopie donc aussi le profil dans `Last Configuration.peace` (après correction de son GUID) et met à jour `Selected Configuration=` dans `peace.ini`, sinon ouvrir Peace annulerait le switch. Limite : changer de profil *pendant* que Peace est ouvert ne met pas son interface à jour, et il réenregistrera son ancien état en se fermant.
- **Les modèles se mettent à jour seuls** : si l'EQ est modifié dans Peace, la sync périodique (5 s) recopie le nouveau `peace.txt` dans le modèle du profil concerné.
- **GUID du DAC USB corrigé automatiquement** quand il change d'identité, avec nouvelle tentative (~1.2 s) si le périphérique n'est pas encore actif.
- **Peace est fermé au démarrage** : il réserve lui aussi `Ctrl+Alt+F1/F2`, ce qui empêcherait le script de les obtenir. Il n'est pas nécessaire au son (c'est Equalizer APO qui applique `peace.txt`). Désactivable via `$ClosePeace` en haut du script.

Les profils sont définis dans `$S.Profiles`, en haut de `hotkey_deck.ps1` :

| Paramètre | Description |
|-----------|-------------|
| `Default` | Valeur initiale au changement de profil |
| `Min` | Plancher (dB) |
| `Max` | Plafond (dB) |
| `Step` | Pas d'incrémentation (dB) |
| `WarnZone` | Zone d'avertissement avant le plafond (dB) |

## Micro (HyperX QuadCast S)

Le micro n'expose pas son état de mute. Le script écoute son interface HID, qui signale chaque appui sur le capteur (bascule seulement), puis vérifie l'état réel en capture audio « raw » (sans les effets Windows type Voice Clarity) : coupé = zéros exacts, actif = souffle de fond permanent. L'OSD affiche le nouvel état à chaque appui ; le deck le montre dans sa barre d'état et le revérifie à son ouverture.

## Installation

1. Installer [Equalizer APO](https://sourceforge.net/projects/equalizerapo/) et [Peace](https://sourceforge.net/projects/peace-equalizer-apo-extension/), créer les profils `Casque.peace` et `Enceintes.peace`.
2. Capturer les modèles : appliquer chaque profil dans Peace et copier `C:\Program Files\EqualizerAPO\config\peace.txt` vers `templates\casque.txt` / `templates\enceintes.txt`.
3. Pour le deck : [MSI Afterburner](https://www.msi.com/Landing/afterburner) (profils 1 et 2, monitoring des températures CPU/GPU activé) et l'Instant Replay de l'app NVIDIA (`Alt+F10`).
4. Lancement au démarrage via la tâche planifiée **"Hotkey Deck"** (déclencheur : ouverture de session, niveau d'exécution : le plus élevé — nécessaire pour écrire dans `Program Files` et fermer Peace s'il tourne en admin), action :

   ```
   conhost.exe --headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "C:\Users\Thomas\Documents\hotkey-deck\hotkey_deck.ps1"
   ```

   `conhost --headless` évite le flash d'une fenêtre console. Une seule instance peut tourner à la fois (mutex).

Les fichiers `.ps1` doivent rester encodés en **UTF-8 avec BOM** (Windows PowerShell 5.1 lit sinon les accents et symboles de l'OSD en ANSI).

### Sauvegarde des profils

`backup_peace.ps1` copie les profils Peace (`Casque.peace`, `Enceintes.peace`), `peace.ini`, `peace.txt` et `config.txt` dans `peace-config\`. À relancer puis commiter après chaque modification de l'EQ. Pour restaurer, recopier `peace-config\` vers `C:\Program Files\EqualizerAPO\config\` (en admin, Peace fermé). Les GUID des périphériques sont corrigés automatiquement au prochain switch.

### Diagnostic

Journal dans `%TEMP%\hotkey_deck.log` (rotation au-delà de 256 Ko) : démarrage, raccourcis non réservables, switchs de profil, mises à jour des modèles, micro, actions du deck, erreurs.

## Version AutoHotkey (`peace_preamp.ahk`)

Version d'origine, limitée au son (preamp, profils, écran noir). Conservée comme repli : son hook clavier bas niveau et le binaire AutoHotkey sont détectés par certains anti-cheats. Elle passe par les raccourcis de Peace (`Ctrl+Alt+F1/F2`) pour changer de profil, réinstalle périodiquement son hook clavier (que certains jeux éjectent) et s'auto-élève via `RunAs` si on la lance à la main.

Prérequis : [AutoHotkey v2](https://www.autohotkey.com/), Equalizer APO et Peace. Pour y revenir au démarrage, remettre comme action de la tâche planifiée **"Hotkey Deck"** :

```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\Users\Thomas\Documents\hotkey-deck\peace_preamp.ahk"
```

Journal dans `%TEMP%\peace_preamp.log`. Ses profils sont dans la `Map` `profiles` en haut du script.
