# Relancer le script (après une modification)

`virtual_deck.ps1` (qui charge `deck.ps1`) tourne via la tâche planifiée **"Virtual Deck"**, en administrateur, sous `conhost --headless`. Une modification ne s'applique qu'après relance.

`schtasks /End` ne suffit pas : il arrête `conhost` mais le `powershell.exe` du script survit, et la nouvelle instance se ferme aussitôt (mutex `Local\VirtualDeck`, instance unique). Ce processus étant élevé, un `Stop-Process` non élevé échoue (« Accès refusé »).

Relance qui marche (demande UAC à l'utilisateur, à prévenir) :

```powershell
Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '-NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq ''powershell.exe'' -and $_.ProcessId -ne $PID -and $_.CommandLine -like ''*virtual_deck.ps1*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Start-Sleep 1; schtasks /Run /TN ''Virtual Deck''"'
```

Vérifier ensuite qu'une ligne « Démarrage script » récente apparaît dans `%TEMP%\virtual_deck.log`.
