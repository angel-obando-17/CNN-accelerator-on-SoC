cd "C:\Users\ANGEL OBANDO\Documents\Trabajo de grado\CNN"

Get-ChildItem mascaras_manual\*.json | ForEach-Object {
    $json = Get-Content $_.FullName | ConvertFrom-Json
    $imgPath = Join-Path (Split-Path $_.FullName) $json.imagePath
    $resolved = [System.IO.Path]::GetFullPath($imgPath)
    if (Test-Path $resolved) {
        Copy-Item $resolved mascaras_manual\
        Write-Host "[ OK ] Copiada: $(Split-Path $json.imagePath -Leaf)"
    } else {
        Write-Host "[ FAIL ] NO encontrada: $($json.imagePath)"
    }
}



python -c "import tensorflow as tf; gpus = tf.config.list_physical_devices('GPU'); [print(tf.config.experimental.get_device_details(g)) for g in gpus]"

python -c "import tensorflow as tf; import numpy as np; import cv2; import sklearn; print('TF:', tf.__version__); print('NumPy:', np.__version__); print('GPU:', tf.config.list_physical_devices('GPU'))"