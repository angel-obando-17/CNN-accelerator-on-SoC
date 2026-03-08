"""
=============================================================================
PREPARACIÓN DEL DATASET - TOMATE
=============================================================================
Este script hace 3 cosas en orden:

  1. Elimina la carpeta Tomato__Tomato_mosaic_virus
  2. Augmenta Tomato_Leaf_Mold de 952 → 1000 imágenes con transformaciones leves
  3. Balancea todas las demás clases a exactamente 1000 imágenes
     (elimina muestras aleatorias de las que tienen más de 1000)
=============================================================================
"""

import os
import random
import shutil
import numpy as np
import cv2
from tqdm import tqdm

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
DATASET_ROOT    = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/PlantVillage"
TARGET_SAMPLES  = 1000
CLASS_TO_DELETE = "Tomato__Tomato_mosaic_virus"
CLASS_TO_AUG    = "Tomato_Leaf_Mold"
SEED            = 42
# =============================================================================

random.seed(SEED)
np.random.seed(SEED)


def get_image_files(folder):
    return sorted([
        f for f in os.listdir(folder)
        if f.lower().endswith((".jpg", ".jpeg", ".png"))
    ])


# =============================================================================
# PASO 1 — Eliminar clase no deseada
# =============================================================================
def delete_class(root, class_name):
    path = os.path.join(root, class_name)
    if os.path.isdir(path):
        shutil.rmtree(path)
        print(f"    Clase eliminada: {class_name}")
    else:
        print(f"    No se encontró la carpeta: {class_name} (puede que ya esté eliminada)")


# =============================================================================
# PASO 2 — Augmentación leve para Tomato_Leaf_Mold (952 → 1000)
# =============================================================================

def augment_image(img):
    """
    Aplica UNA transformación aleatoria leve:
      - Espejo horizontal
      - Espejo vertical
      - Brillo leve (+/- 15%)
      - Contraste leve (+/- 10%)
      - Rotación leve (+/- 15°)
    """
    choice = random.randint(0, 4)

    if choice == 0:
        # Espejo horizontal
        return cv2.flip(img, 1)

    elif choice == 1:
        # Espejo vertical
        return cv2.flip(img, 0)

    elif choice == 2:
        # Brillo leve
        factor = 1.0 + random.uniform(-0.15, 0.15)
        aug = np.clip(img.astype(np.float32) * factor, 0, 255).astype(np.uint8)
        return aug

    elif choice == 3:
        # Contraste leve
        mean = img.mean()
        factor = 1.0 + random.uniform(-0.10, 0.10)
        aug = np.clip((img.astype(np.float32) - mean) * factor + mean, 0, 255).astype(np.uint8)
        return aug

    else:
        # Rotación leve
        h, w = img.shape[:2]
        angle = random.uniform(-15, 15)
        M = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
        aug = cv2.warpAffine(img, M, (w, h),
                              borderMode=cv2.BORDER_REFLECT_101)
        return aug


def augment_class(root, class_name, target):
    folder = os.path.join(root, class_name)
    files  = get_image_files(folder)
    current = len(files)
    needed  = target - current

    if needed <= 0:
        print(f"    {class_name} ya tiene {current} imágenes, no necesita augmentación.")
        return

    print(f"    Augmentando {class_name}: {current} → {target} (+{needed} imágenes)")

    # Pool de imágenes fuente para augmentar (muestreo con reemplazo)
    source_files = random.choices(files, k=needed)

    for i, fname in enumerate(tqdm(source_files, desc="    Augmentando", leave=False)):
        src_path = os.path.join(folder, fname)
        img = cv2.imread(src_path)
        if img is None:
            continue

        aug_img = augment_image(img)

        # Nombre único para la imagen augmentada
        base, ext = os.path.splitext(fname)
        new_name  = f"{base}_aug_{i:04d}{ext}"
        dst_path  = os.path.join(folder, new_name)

        # Evitar sobreescribir si ya existe
        counter = 0
        while os.path.exists(dst_path):
            counter += 1
            new_name = f"{base}_aug_{i:04d}_{counter}{ext}"
            dst_path = os.path.join(folder, new_name)

        cv2.imwrite(dst_path, aug_img)

    final_count = len(get_image_files(folder))
    print(f"    {class_name}: {final_count} imágenes finales")


# =============================================================================
# PASO 3 — Balancear todas las clases a TARGET_SAMPLES
# =============================================================================

def balance_class(root, class_name, target):
    folder = os.path.join(root, class_name)
    files  = get_image_files(folder)
    current = len(files)

    if current == target:
        print(f"    {class_name}: ya tiene exactamente {target} imágenes")
        return

    if current < target:
        print(f"    {class_name}: tiene {current} < {target}. "
              f"Considera augmentarla también.")
        return

    # Eliminar aleatoriamente el exceso
    to_delete = random.sample(files, current - target)
    for fname in to_delete:
        os.remove(os.path.join(folder, fname))

    final_count = len(get_image_files(folder))
    print(f"    {class_name}: {current} → {final_count} imágenes")


# =============================================================================
# MAIN
# =============================================================================
def main():
    print("=" * 60)
    print("  PREPARACIÓN DEL DATASET — TOMATE")
    print("=" * 60)

    if not os.path.isdir(DATASET_ROOT):
        print(f"\n[ERROR] No se encontró DATASET_ROOT = '{DATASET_ROOT}'")
        print("  Ajusta la variable al inicio del script.")
        return

    # Listar clases actuales
    all_classes = sorted([
        d for d in os.listdir(DATASET_ROOT)
        if os.path.isdir(os.path.join(DATASET_ROOT, d))
    ])
    print(f"\n  Clases encontradas antes de preparar: {len(all_classes)}")
    for c in all_classes:
        n = len(get_image_files(os.path.join(DATASET_ROOT, c)))
        print(f"    {c}: {n} imágenes")

    # --- Paso 1: Eliminar clase ---
    print(f"\n{'─'*60}")
    print("  PASO 1 — Eliminando clase no deseada")
    print(f"{'─'*60}")
    delete_class(DATASET_ROOT, CLASS_TO_DELETE)

    # --- Paso 2: Augmentar clase minoritaria ---
    print(f"\n{'─'*60}")
    print("  PASO 2 — Augmentando clase minoritaria")
    print(f"{'─'*60}")
    augment_class(DATASET_ROOT, CLASS_TO_AUG, TARGET_SAMPLES)

    # --- Paso 3: Balancear todas las clases ---
    print(f"\n{'─'*60}")
    print("  PASO 3 — Balanceando todas las clases a 1000 imágenes")
    print(f"{'─'*60}")

    remaining_classes = sorted([
        d for d in os.listdir(DATASET_ROOT)
        if os.path.isdir(os.path.join(DATASET_ROOT, d))
    ])

    for class_name in remaining_classes:
        balance_class(DATASET_ROOT, class_name, TARGET_SAMPLES)

    # --- Resumen final ---
    print(f"\n{'='*60}")
    print("  RESUMEN FINAL")
    print(f"{'='*60}")
    total = 0
    for class_name in sorted(os.listdir(DATASET_ROOT)):
        path = os.path.join(DATASET_ROOT, class_name)
        if not os.path.isdir(path):
            continue
        n = len(get_image_files(path))
        total += n
        status = "OK" if n == TARGET_SAMPLES else "FAIL "
        print(f"  {status} {class_name}: {n} imágenes")

    final_classes = len([
        d for d in os.listdir(DATASET_ROOT)
        if os.path.isdir(os.path.join(DATASET_ROOT, d))
    ])
    print(f"\n  Total clases: {final_classes}")
    print(f"  Total imágenes: {total}")
    print(f"  Dataset listo para entrenar.")


if __name__ == "__main__":
    main()