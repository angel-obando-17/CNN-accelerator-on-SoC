"""
=============================================================================
PIPELINE DE SEGMENTACIÓN CON U-NET
Trabajo de Grado - Acelerador CNN en Zynq-7020
=============================================================================
Este script hace 3 cosas en orden:

  1. Convierte los .json de LabelMe a máscaras binarias PNG
  2. Entrena una U-Net pequeña con los 9 pares imagen+máscara
  3. Aplica la U-Net a todas las imágenes del dataset (reemplaza GrabCut)

ESTRUCTURA ESPERADA:
  MASKS_DIR/
    Tomato_Bacterial_Spot1.json
    Tomato_Early_Blight1.json
    ... (9 archivos .json de LabelMe)

  DATASET_ROOT/
    Tomato_Bacterial_Spot/
    Tomato_Early_Blight/
    ... (9 carpetas con imágenes)
=============================================================================
"""

import os
import json
import shutil
import numpy as np
import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from tqdm import tqdm

import tensorflow as tf
from tensorflow.keras import layers, models

# =============================================================================
# CONFIGURACIÓN — Rutas de los directorios.
# =============================================================================
MASKS_DIR    = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/mascaras_manual"                      # Carpeta con los .json de LabelMe
DATASET_ROOT = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/PlantVillage"                         # Carpeta con las 9 clases de tomate
OUTPUT_DIR   = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/resultados_experimentos/segmentacion" # Donde se guardan resultados intermedios
SEGMENTED_DATASET = "PlantVillage_segmentado"                                                                  # Dataset segmentado final

IMG_SIZE  = 256   # Tamaño al que se redimensiona para la U-Net
SEED      = 42
# =============================================================================

os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(os.path.join(OUTPUT_DIR, "pares"), exist_ok=True)
tf.random.set_seed(SEED)
np.random.seed(SEED)


# =============================================================================
# PASO 1 — Convertir .json de LabelMe a máscaras binarias PNG
# =============================================================================

def labelme_json_to_mask(json_path, output_size=None):
    """
    Lee un .json de LabelMe y genera una máscara binaria.
    Retorna (imagen_original_bgr, mascara_binaria_uint8)
    """
    with open(json_path, "r") as f:
        data = json.load(f)

    # Ruta de la imagen — LabelMe guarda la ruta relativa o el nombre
    img_dir  = os.path.dirname(json_path)
    img_path = data.get("imagePath", "")

    # Intentar encontrar la imagen: primero junto al json, luego en el dataset
    candidates = [
        os.path.join(img_dir, img_path),
        os.path.join(img_dir, os.path.basename(img_path)),
    ]
    
    img_basename = os.path.basename(img_path.replace("\\", "/"))
    for root, dirs, files in os.walk(DATASET_ROOT):
        for f in files:
            if f.lower() == img_basename.lower():
                candidates.append(os.path.join(root, f))

    img = None
    for c in candidates:
        if os.path.exists(c):
            img = cv2.imread(c)
            if img is not None:
                break

    if img is None:
        raise FileNotFoundError(
            f"No se encontró la imagen '{img_path}' referenciada en {json_path}.\n"
            f"Asegúrate de que la imagen esté en el dataset o junto al .json."
        )

    h, w = img.shape[:2]
    mask = np.zeros((h, w), dtype=np.uint8)

    # Dibujar cada polígono anotado como 'leaf'
    for shape in data.get("shapes", []):
        if shape.get("shape_type") == "polygon":
            points = np.array(shape["points"], dtype=np.int32)
            cv2.fillPoly(mask, [points], 255)

    if output_size:
        img  = cv2.resize(img,  (output_size, output_size))
        mask = cv2.resize(mask, (output_size, output_size),
                          interpolation=cv2.INTER_NEAREST)

    return img, mask


def convert_all_masks():
    """Convierte todos los .json a máscaras PNG y guarda los pares."""
    json_files = sorted([
        f for f in os.listdir(MASKS_DIR)
        if f.endswith(".json")
    ])

    if not json_files:
        raise RuntimeError(
            f"No se encontraron archivos .json en '{MASKS_DIR}'.\n"
            f"Verifica la variable MASKS_DIR."
        )

    print(f"\n  Convirtiendo {len(json_files)} máscaras de LabelMe...")
    pairs = []  # lista de (img_bgr, mask_binary)

    for jf in json_files:
        json_path = os.path.join(MASKS_DIR, jf)
        base_name = os.path.splitext(jf)[0]

        try:
            img, mask = labelme_json_to_mask(json_path, output_size=IMG_SIZE)
        except FileNotFoundError as e:
            print(f"  [ FAIL ]  {e}")
            continue

        # Guardar imagen y máscara como PNG
        img_out  = os.path.join(OUTPUT_DIR, "pares", f"{base_name}_img.png")
        mask_out = os.path.join(OUTPUT_DIR, "pares", f"{base_name}_mask.png")
        cv2.imwrite(img_out,  img)
        cv2.imwrite(mask_out, mask)

        pairs.append((img, mask))
        print(f"  [ OK ] {jf} → máscara guardada")

    # Generar figura comparativa
    plot_mask_comparisons(pairs, json_files)
    return pairs


def plot_mask_comparisons(pairs, names):
    """Guarda una figura mostrando imagen original vs máscara por cada par."""
    n = len(pairs)
    fig, axes = plt.subplots(n, 2, figsize=(8, 4 * n))
    if n == 1:
        axes = [axes]
    for i, ((img, mask), jf) in enumerate(zip(pairs, names)):
        img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        axes[i][0].imshow(img_rgb)
        axes[i][0].set_title(os.path.splitext(jf)[0], fontsize=8)
        axes[i][0].axis("off")
        axes[i][1].imshow(mask, cmap="gray")
        axes[i][1].set_title("Máscara manual", fontsize=8)
        axes[i][1].axis("off")
    plt.suptitle("Pares imagen — máscara manual", fontsize=12, fontweight="bold")
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "mascaras_manuales.png"), dpi=150)
    plt.close(fig)
    print(f"    Comparativa guardada: mascaras_manuales.png")


# =============================================================================
# PASO 2 — U-Net pequeña para segmentación de hojas
# =============================================================================

def conv_block(x, filters, name):
    x = layers.Conv2D(filters, 3, padding="same", activation="relu",
                      name=f"{name}_c1")(x)
    x = layers.Conv2D(filters, 3, padding="same", activation="relu",
                      name=f"{name}_c2")(x)
    return x


def build_unet(input_size=256):
    """
    U-Net ligera para segmentación binaria de hojas.
    Entrada: imagen RGB 256x256
    Salida: máscara binaria 256x256 (sigmoid)
    """
    inp = layers.Input(shape=(input_size, input_size, 3), name="input")

    # Encoder
    c1 = conv_block(inp, 16, "enc1")
    p1 = layers.MaxPooling2D(2, name="pool1")(c1)

    c2 = conv_block(p1, 32, "enc2")
    p2 = layers.MaxPooling2D(2, name="pool2")(c2)

    c3 = conv_block(p2, 64, "enc3")
    p3 = layers.MaxPooling2D(2, name="pool3")(c3)

    # Bottleneck
    bn = conv_block(p3, 128, "bottleneck")

    # Decoder
    u1 = layers.Conv2DTranspose(64, 2, strides=2, padding="same", name="up1")(bn)
    u1 = layers.Concatenate(name="cat1")([u1, c3])
    c4 = conv_block(u1, 64, "dec1")

    u2 = layers.Conv2DTranspose(32, 2, strides=2, padding="same", name="up2")(c4)
    u2 = layers.Concatenate(name="cat2")([u2, c2])
    c5 = conv_block(u2, 32, "dec2")

    u3 = layers.Conv2DTranspose(16, 2, strides=2, padding="same", name="up3")(c5)
    u3 = layers.Concatenate(name="cat3")([u3, c1])
    c6 = conv_block(u3, 16, "dec3")

    # Salida
    out = layers.Conv2D(1, 1, activation="sigmoid", name="output")(c6)

    return models.Model(inp, out, name="UNet_leaf")


def augment_pair(img, mask):
    """
    Data augmentation para aumentar las 9 muestras.
    Genera múltiples variantes de cada par imagen+máscara.
    """
    augmented = [(img, mask)]  # incluir original

    # Espejo horizontal
    augmented.append((cv2.flip(img, 1), cv2.flip(mask, 1)))

    # Espejo vertical
    augmented.append((cv2.flip(img, 0), cv2.flip(mask, 0)))

    # Rotaciones
    for angle in [-30, -15, 15, 30]:
        h, w = img.shape[:2]
        M   = cv2.getRotationMatrix2D((w/2, h/2), angle, 1.0)
        aug_img  = cv2.warpAffine(img,  M, (w, h), borderMode=cv2.BORDER_REFLECT_101)
        aug_mask = cv2.warpAffine(mask, M, (w, h),
                                  flags=cv2.INTER_NEAREST,
                                  borderMode=cv2.BORDER_REFLECT_101)
        augmented.append((aug_img, aug_mask))

    # Brillo leve
    for factor in [0.85, 1.15]:
        aug_img = np.clip(img.astype(np.float32) * factor, 0, 255).astype(np.uint8)
        augmented.append((aug_img, mask.copy()))

    return augmented


def prepare_training_data(pairs):
    """
    Prepara arrays X (imágenes) e Y (máscaras) con augmentación.
    Con 9 pares y las augmentaciones genera ~81 muestras de entrenamiento.
    """
    X, Y = [], []
    for img, mask in pairs:
        for aug_img, aug_mask in augment_pair(img, mask):
            img_rgb = cv2.cvtColor(aug_img, cv2.COLOR_BGR2RGB)
            X.append(img_rgb.astype(np.float32) / 255.0)
            Y.append((aug_mask > 127).astype(np.float32)[..., np.newaxis])

    X = np.array(X)
    Y = np.array(Y)
    print(f"  Muestras de entrenamiento (con augmentación): {len(X)}")
    return X, Y


def train_unet(pairs):
    """Entrena la U-Net con los pares imagen+máscara."""
    print("\n  Preparando datos de entrenamiento con augmentación...")
    X, Y = prepare_training_data(pairs)

    model = build_unet(IMG_SIZE)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss="binary_crossentropy",
        metrics=["accuracy",
                 tf.keras.metrics.MeanIoU(num_classes=2, name="iou")]
    )
    model.summary(print_fn=lambda s: None)
    print(f"  Parámetros U-Net: {model.count_params():,}")

    callbacks = [
        tf.keras.callbacks.EarlyStopping(
            monitor="loss", patience=15, restore_best_weights=True
        ),
        tf.keras.callbacks.ReduceLROnPlateau(
            monitor="loss", factor=0.5, patience=7, min_lr=1e-6
        )
    ]

    print("\n  Entrenando U-Net...")
    history = model.fit(
        X, Y,
        batch_size=min(8, len(X)),
        epochs=200,
        callbacks=callbacks,
        verbose=1
    )

    # Guardar modelo
    unet_path = os.path.join(OUTPUT_DIR, "unet_leaf.keras")
    model.save(unet_path)
    print(f"\n  [ OK ] U-Net guardada: {unet_path}")

    plot_unet_training(history)
    evaluate_unet_on_pairs(model, X, Y)
    return model


def plot_unet_training(history):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    axes[0].plot(history.history["loss"])
    axes[0].set_title("Loss — U-Net")
    axes[0].set_xlabel("Época")
    axes[1].plot(history.history["iou"])
    axes[1].set_title("IoU — U-Net")
    axes[1].set_xlabel("Época")
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "unet_training.png"), dpi=150)
    plt.close(fig)


def evaluate_unet_on_pairs(model, X, Y):
    """Muestra predicciones vs máscaras manuales para las 9 muestras originales."""
    # Solo las 9 originales (sin augmentación = índices múltiplos de 9)
    n_aug = len(X) // 9
    orig_idx = list(range(0, len(X), n_aug))[:9]

    fig, axes = plt.subplots(len(orig_idx), 3,
                              figsize=(10, 4 * len(orig_idx)))
    for row, i in enumerate(orig_idx):
        pred = model.predict(X[i:i+1], verbose=0)[0, :, :, 0]
        pred_bin = (pred > 0.5).astype(np.uint8) * 255

        axes[row][0].imshow(X[i])
        axes[row][0].set_title("Imagen", fontsize=8)
        axes[row][0].axis("off")

        axes[row][1].imshow(Y[i, :, :, 0], cmap="gray")
        axes[row][1].set_title("Máscara manual", fontsize=8)
        axes[row][1].axis("off")

        axes[row][2].imshow(pred_bin, cmap="gray")
        axes[row][2].set_title(f"U-Net (pred)", fontsize=8)
        axes[row][2].axis("off")

    plt.suptitle("Evaluación U-Net sobre muestras originales", fontweight="bold")
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "unet_predicciones.png"), dpi=150)
    plt.close(fig)
    print("    Predicciones guardadas: unet_predicciones.png")


# =============================================================================
# PASO 3 — Aplicar U-Net a todo el dataset
# =============================================================================

def segment_image_unet(model, img_bgr, threshold=0.5):
    """
    Segmenta una imagen usando la U-Net entrenada.
    Retorna la imagen BGR con el fondo en negro.
    """
    h_orig, w_orig = img_bgr.shape[:2]

    # Preprocesar para U-Net
    img_resized = cv2.resize(img_bgr, (IMG_SIZE, IMG_SIZE))
    img_rgb     = cv2.cvtColor(img_resized, cv2.COLOR_BGR2RGB)
    img_input   = img_rgb.astype(np.float32) / 255.0

    # Predicción
    pred = model.predict(img_input[np.newaxis], verbose=0)[0, :, :, 0]
    mask = (pred > threshold).astype(np.uint8) * 255

    # Post-procesamiento: rellenar huecos y suavizar bordes
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask   = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask   = cv2.morphologyEx(mask, cv2.MORPH_OPEN,  kernel)

    # Redimensionar máscara al tamaño original
    mask_orig = cv2.resize(mask, (w_orig, h_orig),
                           interpolation=cv2.INTER_NEAREST)

    # Aplicar máscara
    result = cv2.bitwise_and(img_bgr, img_bgr, mask=mask_orig)
    return result


def apply_unet_to_dataset(model):
    """
    Aplica la U-Net a todas las imágenes del dataset y guarda
    el resultado en SEGMENTED_DATASET manteniendo la estructura de carpetas.
    """
    classes = sorted([
        d for d in os.listdir(DATASET_ROOT)
        if os.path.isdir(os.path.join(DATASET_ROOT, d))
    ])

    print(f"\n  Aplicando U-Net a {len(classes)} clases...")
    total_processed = 0
    total_failed    = 0

    for class_name in classes:
        src_folder = os.path.join(DATASET_ROOT, class_name)
        dst_folder = os.path.join(SEGMENTED_DATASET, class_name)
        os.makedirs(dst_folder, exist_ok=True)

        files = [f for f in os.listdir(src_folder)
                 if f.lower().endswith((".jpg", ".jpeg", ".png"))]

        for fname in tqdm(files, desc=f"  {class_name[:40]}", leave=False):
            src_path = os.path.join(src_folder, fname)
            dst_path = os.path.join(dst_folder, fname)

            img = cv2.imread(src_path)
            if img is None:
                total_failed += 1
                continue

            try:
                segmented = segment_image_unet(model, img)
                cv2.imwrite(dst_path, segmented)
                total_processed += 1
            except Exception as e:
                # Si falla la U-Net en alguna imagen, copiar original
                shutil.copy2(src_path, dst_path)
                total_failed += 1

        print(f"  [ OK ] {class_name}: {len(files)} imágenes procesadas")

    print(f"\n  Total procesadas: {total_processed}")
    if total_failed > 0:
        print(f"  [ FAIL ]  Fallos (copiadas sin segmentar): {total_failed}")


def generate_segmentation_samples(model):
    """
    Genera una figura de muestra con resultados de segmentación
    para cada clase, útil para incluir en el documento.
    """
    classes = sorted([
        d for d in os.listdir(DATASET_ROOT)
        if os.path.isdir(os.path.join(DATASET_ROOT, d))
    ])

    import random
    random.seed(SEED)

    fig, axes = plt.subplots(len(classes), 3,
                              figsize=(10, 4 * len(classes)))

    for i, class_name in enumerate(classes):
        folder = os.path.join(DATASET_ROOT, class_name)
        files  = [f for f in os.listdir(folder)
                  if f.lower().endswith((".jpg", ".jpeg", ".png"))]
        if not files:
            continue
        fname  = random.choice(files)
        img    = cv2.imread(os.path.join(folder, fname))
        if img is None:
            continue

        segmented = segment_image_unet(model, img)
        img_rgb   = cv2.cvtColor(img,       cv2.COLOR_BGR2RGB)
        seg_rgb   = cv2.cvtColor(segmented, cv2.COLOR_BGR2RGB)

        # Máscara
        img_r = cv2.resize(img, (IMG_SIZE, IMG_SIZE))
        pred  = model.predict(
            (cv2.cvtColor(img_r, cv2.COLOR_BGR2RGB).astype(np.float32)/255.0)[np.newaxis],
            verbose=0
        )[0, :, :, 0]
        mask_vis = (pred > 0.5).astype(np.uint8) * 255

        short = class_name.replace("Tomato_", "").replace("Tomato__", "")
        axes[i][0].imshow(img_rgb)
        axes[i][0].set_ylabel(short, fontsize=7, rotation=0,
                               labelpad=75, va="center")
        axes[i][0].set_title("Original" if i == 0 else "", fontsize=9)
        axes[i][0].axis("off")

        axes[i][1].imshow(mask_vis, cmap="gray")
        axes[i][1].set_title("Máscara U-Net" if i == 0 else "", fontsize=9)
        axes[i][1].axis("off")

        axes[i][2].imshow(seg_rgb)
        axes[i][2].set_title("Segmentada" if i == 0 else "", fontsize=9)
        axes[i][2].axis("off")

    plt.suptitle("Segmentación U-Net — Muestra por clase", fontweight="bold")
    plt.tight_layout()
    out = os.path.join(OUTPUT_DIR, "segmentacion_muestras.png")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"    Muestras de segmentación guardadas: segmentacion_muestras.png")


# =============================================================================
# MAIN
# =============================================================================

def main():
    print("=" * 60)
    print("  PIPELINE DE SEGMENTACIÓN U-NET — HOJAS DE TOMATE")
    print("=" * 60)

    # Verificar rutas
    for path, name in [(MASKS_DIR, "MASKS_DIR"), (DATASET_ROOT, "DATASET_ROOT")]:
        if not os.path.isdir(path):
            print(f"\n[ERROR] No se encontró {name} = '{path}'")
            print("  Ajusta las variables al inicio del script.")
            return

    # Paso 1: Convertir máscaras
    print("\n" + "─"*60)
    print("  PASO 1 — Convirtiendo máscaras LabelMe")
    print("─"*60)
    pairs = convert_all_masks()

    if len(pairs) == 0:
        print("\n[ERROR] No se pudo cargar ningún par imagen+máscara.")
        print("  Verifica que las imágenes originales estén accesibles.")
        return

    print(f"\n  Pares cargados correctamente: {len(pairs)}")

    # Paso 2: Entrenar U-Net
    print("\n" + "─"*60)
    print("  PASO 2 — Entrenando U-Net")
    print("─"*60)
    model = train_unet(pairs)

    # Paso 3: Aplicar al dataset
    print("\n" + "─"*60)
    print("  PASO 3 — Aplicando U-Net al dataset completo")
    print("─"*60)
    generate_segmentation_samples(model)
    apply_unet_to_dataset(model)

    print("\n" + "="*60)
    print("  [ OK ] PIPELINE COMPLETADO")
    print("="*60)
    print(f"\n  Dataset segmentado en: {SEGMENTED_DATASET}/")
    print(f"  Resultados intermedios en: {OUTPUT_DIR}/")
    print(f"\n  Próximo paso:")
    print(f"  Actualiza DATASET_ROOT en tomato_cnn_experiments.py")
    print(f"  para apuntar a '{SEGMENTED_DATASET}' y reentrena el modelo.")


if __name__ == "__main__":
    main()