# Copie les profils Peace / la config Equalizer APO dans peace-config\ (versionné).
# Restauration : recopier le contenu de peace-config\ vers C:\Program Files\EqualizerAPO\config\
# (en admin, Peace fermé), puis appliquer un profil avec Ctrl+Alt+F1/F2.
$src = 'C:\Program Files\EqualizerAPO\config'
$dst = Join-Path $PSScriptRoot 'peace-config'
New-Item -ItemType Directory -Force $dst | Out-Null
foreach ($f in 'Casque.peace', 'Enceintes.peace', 'Last Configuration.peace', 'peace.ini', 'peace.txt', 'config.txt') {
    Copy-Item (Join-Path $src $f) $dst -Force
}
Write-Host "Profils copiés dans $dst"
