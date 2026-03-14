"""
=============================================================================
ENTRENAMIENTO CON SEGMENTACIÓN HSV THRESHOLD
MobileNetV1 + MobileNetV2 — Tres Resoluciones
Trabajo de Grado - Acelerador CNN en Zynq-7020
=============================================================================
Entrena ambos modelos con segmentación HSV threshold en lugar de U-Net.
Propósito: validar que el modelo entrenado con una segmentación implementable
en hardware (HSV threshold) tiene un accuracy aceptable para producción.

Segmentación HSV:
  - Convierte BGR → HSV
  - Filtra rango de verde/marrón típico de hojas de tomate
  - Aplica morfología para limpiar ruido
  - Pinta fondo en negro (mismo formato que U-Net)

Mismas condiciones que todos los entrenamientos anteriores:
  - SEED=42 → mismo test set → comparación directa con U-Net
  - Adam lr=1e-3, batch=32, epochs=30, mismos callbacks
  - Cuantización INT8 e INT16
  - Test set completo (1350 imágenes)
=============================================================================
"""

import os
import re
import time
import warnings

import numpy as np
import pandas as pd
import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns
from sklearn.model_selection import train_test_split
from sklearn.metrics import confusion_matrix, accuracy_score

import tensorflow as tf
from tensorflow.keras import layers, models
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau

warnings.filterwarnings("ignore")

# =============================================================================
# CONFIGURACIÓN — Ajusta estas rutas
# =============================================================================
# IMPORTANTE: apunta al dataset ORIGINAL sin segmentar,
# este script aplica su propia segmentación HSV
DATASET_ROOT = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/PlantVillage"
OUTPUT_DIR   = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/resultados_hsv"

RESOLUTIONS = [256, 128, 96]
BATCH_SIZE  = 32
EPOCHS      = 30
SEED        = 42
VAL_SPLIT   = 0.15
TEST_SPLIT  = 0.15
QUANT_MODES = ["int8", "int16"]
MAX_CH      = 64
# =============================================================================

os.makedirs(OUTPUT_DIR, exist_ok=True)
tf.random.set_seed(SEED)
np.random.seed(SEED)


# =============================================================================
# SEGMENTACIÓN HSV THRESHOLD
# Diseñada para ser replicable en hardware (VHDL / C bare-metal)
# Solo usa operaciones aritméticas simples, sin estructuras de grafos
# =============================================================================

def segment_hsv(img_bgr):
    """
    Segmentación por threshold en espacio HSV.

    Lógica implementable en hardware:
      1. Convertir RGB→HSV (multiplicaciones y comparaciones enteras)
      2. Threshold en H (tono): cubre verde, verde-amarillo, marrón
      3. Threshold en S (saturación): elimina zonas grises/blancas (fondo)
      4. Morfología CLOSE+OPEN: rellena huecos y elimina ruido
      5. Aplicar máscara: fondo = negro (igual que U-Net)

    Rangos HSV en OpenCV: H=[0,179], S=[0,255], V=[0,255]
      Verde sano + verde-amarillo:  H=[15, 95], S=[30, 255], V=[20, 255]
      Marrón/naranja (necrosis):    H=[ 5, 20], S=[50, 255], V=[20, 220]
    """
    hsv = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2HSV)

    # Verde y verde-amarillo (hoja sana y algunas enfermedades)
    mask_green = cv2.inRange(hsv,
                              np.array([15,  30,  20], dtype=np.uint8),
                              np.array([95, 255, 255], dtype=np.uint8))

    # Marrón/naranja (manchas de enfermedades, necrosis)
    mask_brown = cv2.inRange(hsv,
                              np.array([ 5,  50,  20], dtype=np.uint8),
                              np.array([20, 255, 220], dtype=np.uint8))

    mask   = cv2.bitwise_or(mask_green, mask_brown)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    mask   = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    mask   = cv2.morphologyEx(mask, cv2.MORPH_OPEN,  kernel, iterations=1)

    return cv2.bitwise_and(img_bgr, img_bgr, mask=mask)


# =============================================================================
# UTILIDADES
# =============================================================================

class Timer:
    def __init__(self, label):
        self.label = label
    def __enter__(self):
        self.t0 = time.perf_counter()
        return self
    def __exit__(self, *a):
        self.elapsed = time.perf_counter() - self.t0
        print(f"  ⏱  {self.label}: {self.elapsed:.3f}s")


def get_all_classes(root):
    return sorted([
        d for d in os.listdir(root)
        if os.path.isdir(os.path.join(root, d))
    ])


def collect_file_paths(root):
    class_names = get_all_classes(root)
    label_map   = {n: i for i, n in enumerate(class_names)}
    file_paths, labels = [], []
    for cn in class_names:
        folder = os.path.join(root, cn)
        for f in os.listdir(folder):
            if f.lower().endswith((".jpg", ".jpeg", ".png")):
                file_paths.append(os.path.join(folder, f))
                labels.append(label_map[cn])
    return file_paths, labels, class_names


def split_paths(file_paths, labels):
    """Mismo SEED=42 que todos los entrenamientos anteriores."""
    idx = np.arange(len(file_paths))
    idx_tmp, idx_test = train_test_split(
        idx, test_size=TEST_SPLIT, random_state=SEED, stratify=labels)
    val_ratio = VAL_SPLIT / (1 - TEST_SPLIT)
    idx_train, idx_val = train_test_split(
        idx_tmp, test_size=val_ratio, random_state=SEED,
        stratify=np.array(labels)[idx_tmp])
    fp = np.array(file_paths)
    lb = np.array(labels)
    return (fp[idx_train], lb[idx_train],
            fp[idx_val],   lb[idx_val],
            fp[idx_test],  lb[idx_test])


def load_and_preprocess(path, label, target_size):
    """Carga imagen, aplica HSV threshold, resize, normaliza."""
    def _load(p, sz):
        p   = p.numpy().decode("utf-8")
        sz  = int(sz.numpy())
        img = cv2.imread(p)
        if img is None:
            img = np.zeros((sz, sz, 3), dtype=np.uint8)
        img = segment_hsv(img)
        img = cv2.resize(img, (sz, sz))
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        return img.astype(np.float32) / 255.0
    img = tf.py_function(func=_load, inp=[path, target_size], Tout=tf.float32)
    img.set_shape([None, None, 3])
    img = tf.image.resize(img, [target_size, target_size])
    return img, label


def build_dataset(paths, labels, target_size, batch_size, shuffle=False):
    ds = tf.data.Dataset.from_tensor_slices((paths, labels))
    if shuffle:
        ds = ds.shuffle(buffer_size=len(paths), seed=SEED)
    ds = ds.map(lambda p, l: load_and_preprocess(p, l, target_size),
                num_parallel_calls=tf.data.AUTOTUNE)
    return ds.batch(batch_size).prefetch(tf.data.AUTOTUNE)


def plot_cm(cm, class_names, label):
    short = [re.sub(r"Tomato_+", "", n) for n in class_names]
    n = len(short)
    fig, ax = plt.subplots(figsize=(max(8, n), max(6, n)))
    sns.heatmap(cm, annot=True, fmt="d", cmap="Blues",
                xticklabels=short, yticklabels=short, ax=ax)
    ax.set_xlabel("Predicho")
    ax.set_ylabel("Real")
    ax.set_title(f"Confusion Matrix — {label}")
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, f"cm_{label}.png"), dpi=150)
    plt.close(fig)


def plot_training_curves(history, label):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    axes[0].plot(history.history["accuracy"],     label="Train")
    axes[0].plot(history.history["val_accuracy"],  label="Val")
    axes[0].set_title(f"Accuracy — {label}")
    axes[0].set_xlabel("Época"); axes[0].legend()
    axes[1].plot(history.history["loss"],     label="Train")
    axes[1].plot(history.history["val_loss"],  label="Val")
    axes[1].set_title(f"Loss — {label}")
    axes[1].set_xlabel("Época"); axes[1].legend()
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, f"training_{label}.png"), dpi=150)
    plt.close(fig)


# =============================================================================
# ARQUITECTURAS
# =============================================================================

def dw_block(x, filters, strides=1, name_prefix="dw"):
    """Bloque DW+PW de MobileNetV1 — idéntico a tomato.py"""
    x = layers.DepthwiseConv2D(3, strides=strides, padding="same",
                                use_bias=False,
                                name=f"{name_prefix}_dw")(x)
    x = layers.BatchNormalization(name=f"{name_prefix}_dw_bn")(x)
    x = layers.ReLU(name=f"{name_prefix}_dw_relu")(x)
    x = layers.Conv2D(filters, 1, padding="same", use_bias=False,
                      name=f"{name_prefix}_pw")(x)
    x = layers.BatchNormalization(name=f"{name_prefix}_pw_bn")(x)
    x = layers.ReLU(name=f"{name_prefix}_pw_relu")(x)
    return x


def build_mobilenetv1(input_size, num_classes):
    """MobileNetV1 — arquitectura idéntica a tomato.py"""
    inp = layers.Input(shape=(input_size, input_size, 3))
    x   = layers.Conv2D(min(32, MAX_CH), 3, strides=2, padding="same",
                        use_bias=False, name="conv1")(inp)
    x   = layers.BatchNormalization(name="conv1_bn")(x)
    x   = layers.ReLU(name="conv1_relu")(x)
    cfg = [(64,1),(64,2),(64,1),(64,2),(64,1),(64,2),
           (64,1),(64,1),(64,1),(64,1),(64,1),(64,2),(64,1)]
    for i, (ch, s) in enumerate(cfg):
        x = dw_block(x, min(ch, MAX_CH), strides=s, name_prefix=f"dw{i+1}")
    x = layers.GlobalAveragePooling2D(name="gap")(x)
    x = layers.Dense(num_classes, activation="softmax", name="output")(x)
    return models.Model(inp, x, name=f"MobileNetV1_HSV_{input_size}")


def inverted_residual_block(x, filters, strides=1, expand_ratio=2,
                             name_prefix="irb"):
    """Bloque invertido de MobileNetV2 — idéntico a tomatoV2.py"""
    in_ch  = x.shape[-1]
    exp_ch = in_ch * expand_ratio   # Sin cap — igual que la versión que dio 94%

    if expand_ratio != 1:
        x_exp = layers.Conv2D(exp_ch, 1, padding="same", use_bias=False,
                               name=f"{name_prefix}_exp")(x)
        x_exp = layers.BatchNormalization(name=f"{name_prefix}_exp_bn")(x_exp)
        x_exp = layers.ReLU(6.0, name=f"{name_prefix}_exp_relu6")(x_exp)
    else:
        x_exp = x

    x_dw = layers.DepthwiseConv2D(3, strides=strides, padding="same",
                                   use_bias=False,
                                   name=f"{name_prefix}_dw")(x_exp)
    x_dw = layers.BatchNormalization(name=f"{name_prefix}_dw_bn")(x_dw)
    x_dw = layers.ReLU(6.0, name=f"{name_prefix}_dw_relu6")(x_dw)

    x_pw = layers.Conv2D(filters, 1, padding="same", use_bias=False,
                          name=f"{name_prefix}_pw")(x_dw)
    x_pw = layers.BatchNormalization(name=f"{name_prefix}_pw_bn")(x_pw)

    if strides == 1 and in_ch == filters:
        return layers.Add(name=f"{name_prefix}_add")([x, x_pw])
    return x_pw


def build_mobilenetv2(input_size, num_classes):
    """MobileNetV2 — arquitectura idéntica a tomatoV2.py (la que dio ~93%)"""
    inp = layers.Input(shape=(input_size, input_size, 3))
    x   = layers.Conv2D(min(32, MAX_CH), 3, strides=2, padding="same",
                        use_bias=False, name="conv1")(inp)
    x   = layers.BatchNormalization(name="conv1_bn")(x)
    x   = layers.ReLU(6.0, name="conv1_relu6")(x)

    cfg = [
        (1, 16, 1),
        (2, 24, 2),
        (2, 24, 1),
        (2, 32, 2),
        (2, 32, 1),
        (2, 64, 2),
        (2, 64, 1),
        (2, 64, 1),
        (2, 64, 1),
    ]
    for i, (t, c, s) in enumerate(cfg):
        x = inverted_residual_block(x, min(c, MAX_CH), strides=s,
                                     expand_ratio=t, name_prefix=f"irb{i+1}")

    x = layers.Conv2D(min(64, MAX_CH), 1, padding="same", use_bias=False,
                       name="conv_last")(x)
    x = layers.BatchNormalization(name="conv_last_bn")(x)
    x = layers.ReLU(6.0, name="conv_last_relu6")(x)
    x = layers.GlobalAveragePooling2D(name="gap")(x)
    x = layers.Dense(num_classes, activation="softmax", name="output")(x)
    return models.Model(inp, x, name=f"MobileNetV2_HSV_{input_size}")


# =============================================================================
# ENTRENAMIENTO
# =============================================================================

def train_model(model, ds_train, ds_val, label):
    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"]
    )
    cbs = [
        EarlyStopping(monitor="val_accuracy", patience=7,
                      restore_best_weights=True),
        ReduceLROnPlateau(monitor="val_loss", factor=0.5,
                          patience=3, min_lr=1e-6)
    ]
    print(f"  Parámetros: {model.count_params():,}")
    with Timer(f"Entrenamiento {label}") as t:
        history = model.fit(ds_train, validation_data=ds_val,
                            epochs=EPOCHS, callbacks=cbs, verbose=1)
    return history, t.elapsed


# =============================================================================
# EVALUACIÓN FLOAT32
# =============================================================================

def evaluate_model(model, ds_test, paths_test, labels_test,
                   class_names, label, resolution):
    results = {}
    with Timer("Inferencia batch") as t:
        y_pred_proba = model.predict(ds_test, verbose=0)
    results["inference_batch_s"] = t.elapsed
    y_pred = np.argmax(y_pred_proba, axis=1)
    results["accuracy"] = accuracy_score(labels_test, y_pred)
    print(f"  Accuracy float32: {results['accuracy']:.4f}")

    times = []
    for p in paths_test[:100]:
        img = cv2.imread(p)
        if img is None:
            continue
        img = segment_hsv(img)
        img = cv2.resize(img, (resolution, resolution))
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        t0  = time.perf_counter()
        model.predict(img[np.newaxis], verbose=0)
        times.append(time.perf_counter() - t0)
    results["inference_single_ms"] = np.mean(times) * 1000 if times else 0
    print(f"  Tiempo/imagen: {results['inference_single_ms']:.4f} ms")

    cm = confusion_matrix(labels_test, y_pred)
    plot_cm(cm, class_names, f"{label}_float32")
    return results


# =============================================================================
# CUANTIZACIÓN Y EVALUACIÓN
# =============================================================================

def make_representative_dataset(paths_calib, target_size):
    """Calibración con HSV aplicado — consistencia total con entrenamiento."""
    samples = list(paths_calib[:200])
    def gen():
        for p in samples:
            img = cv2.imread(p)
            if img is None:
                continue
            img = segment_hsv(img)
            img = cv2.resize(img, (target_size, target_size))
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
            yield [img[np.newaxis]]
    return gen


def quantize_and_evaluate(model, paths_test, labels_test, class_names,
                           label, target_size, qmode, paths_calib):
    results = {}
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    rep_gen   = make_representative_dataset(paths_calib, target_size)

    if qmode == "int8":
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        converter.representative_dataset = rep_gen
        converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        converter.inference_input_type  = tf.int8
        converter.inference_output_type = tf.int8
    elif qmode == "int16":
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        converter.representative_dataset = rep_gen
        converter.target_spec.supported_ops = [
            tf.lite.OpsSet.EXPERIMENTAL_TFLITE_BUILTINS_ACTIVATIONS_INT16_WEIGHTS_INT8
        ]

    with Timer(f"Conversión {qmode}") as t:
        tflite_model = converter.convert()
    results["conversion_s"] = t.elapsed

    model_path = os.path.join(OUTPUT_DIR, f"model_{label}_{qmode}.tflite")
    with open(model_path, "wb") as f:
        f.write(tflite_model)
    results["model_size_kb"] = os.path.getsize(model_path) / 1024
    print(f"  Tamaño {qmode}: {results['model_size_kb']:.1f} KB")

    interp = tf.lite.Interpreter(model_path=model_path)
    interp.allocate_tensors()
    in_det  = interp.get_input_details()[0]
    out_det = interp.get_output_details()[0]

    def run_one(img_float):
        if in_det["dtype"] == np.int8:
            scale, zp = in_det["quantization"]
            inp = (img_float / scale + zp).astype(np.int8)
        else:
            inp = img_float.astype(np.float32)
        interp.set_tensor(in_det["index"], inp[np.newaxis])
        interp.invoke()
        out = interp.get_tensor(out_det["index"])[0]
        if out_det["dtype"] == np.int8:
            scale, zp = out_det["quantization"]
            out = (out.astype(np.float32) - zp) * scale
        return np.argmax(out)

    print(f"  Evaluando {len(paths_test)} imágenes en {qmode} (con HSV)...")
    y_pred = []
    t0 = time.perf_counter()
    for p in paths_test:
        img = cv2.imread(p)
        if img is None:
            y_pred.append(0)
            continue
        img = segment_hsv(img)
        img = cv2.resize(img, (target_size, target_size))
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        y_pred.append(run_one(img))
    elapsed = time.perf_counter() - t0

    results["accuracy"]            = accuracy_score(labels_test, y_pred)
    results["inference_single_ms"] = (elapsed / len(paths_test)) * 1000
    print(f"  Accuracy {qmode}: {results['accuracy']:.4f}")
    print(f"  Tiempo/imagen: {results['inference_single_ms']:.4f} ms")

    cm = confusion_matrix(labels_test, y_pred)
    plot_cm(cm, class_names, f"{label}_{qmode}")
    return results


# =============================================================================
# LOOP POR MODELO
# =============================================================================

def run_model(model_name, builder, paths_train, y_train, paths_val, y_val,
              paths_test, y_test, class_names, num_classes, summary_rows):

    print(f"\n{'='*65}")
    print(f"  MODELO: {model_name}")
    print(f"{'='*65}")

    for resolution in RESOLUTIONS:
        res_label = f"{resolution}x{resolution}"
        label     = f"{model_name}_HSV_{res_label}"
        print(f"\n  --- Resolución: {res_label} ---")

        ds_train = build_dataset(paths_train, y_train,
                                  resolution, BATCH_SIZE, shuffle=True)
        ds_val   = build_dataset(paths_val,   y_val,   resolution, BATCH_SIZE)
        ds_test  = build_dataset(paths_test,  y_test,  resolution, BATCH_SIZE)

        model = builder(resolution, num_classes)
        history, train_time = train_model(model, ds_train, ds_val, label)
        plot_training_curves(history, label)

        keras_path = os.path.join(OUTPUT_DIR, f"model_{label}.keras")
        model.save(keras_path)
        keras_kb = os.path.getsize(keras_path) / 1024
        print(f"  Modelo guardado ({keras_kb:.1f} KB)")

        print(f"\n  >> Float32")
        f32 = evaluate_model(model, ds_test, paths_test, y_test,
                              class_names, label, resolution)
        summary_rows.append({
            "modelo": model_name, "segmentacion": "HSV",
            "resolucion": res_label, "cuantizacion": "float32",
            "accuracy": f32["accuracy"],
            "inferencia_ms_img": f32["inference_single_ms"],
            "tamano_modelo_kb": keras_kb,
            "tiempo_entrenamiento_s": train_time,
            "tiempo_conversion_s": None,
            "n_params": model.count_params()
        })

        for qmode in QUANT_MODES:
            print(f"\n  >> {qmode.upper()}")
            try:
                qres = quantize_and_evaluate(
                    model, paths_test, y_test, class_names,
                    label, resolution, qmode, paths_train
                )
                summary_rows.append({
                    "modelo": model_name, "segmentacion": "HSV",
                    "resolucion": res_label, "cuantizacion": qmode,
                    "accuracy": qres["accuracy"],
                    "inferencia_ms_img": qres["inference_single_ms"],
                    "tamano_modelo_kb": qres["model_size_kb"],
                    "tiempo_entrenamiento_s": train_time,
                    "tiempo_conversion_s": qres["conversion_s"],
                    "n_params": model.count_params()
                })
            except Exception as e:
                print(f"  [WARN] {qmode} falló: {e}")
                summary_rows.append({
                    "modelo": model_name, "segmentacion": "HSV",
                    "resolucion": res_label, "cuantizacion": qmode,
                    "accuracy": "ERROR"
                })

        tf.keras.backend.clear_session()


# =============================================================================
# MAIN
# =============================================================================
# MUESTRAS VISUALES — Una imagen por clase, mismo seed que save_segmented_samples.py
# =============================================================================

def save_segmentation_samples(dataset_root, class_names):
    """
    Toma 1 imagen por clase con RandomState(42) — reproduce exactamente
    las mismas 9 imágenes que se usaron para comparar GrabCut vs U-Net.
    Guarda un mosaico con original a la izquierda y HSV a la derecha.
    """
    print("\n  Generando muestras visuales de segmentación HSV...")
    rng = np.random.RandomState(42)

    originals, segmented, titles = [], [], []

    for cn in class_names:
        folder = os.path.join(dataset_root, cn)
        files  = sorted([
            f for f in os.listdir(folder)
            if f.lower().endswith((".jpg", ".jpeg", ".png"))
        ])
        if not files:
            continue
        chosen  = files[rng.randint(0, len(files))]
        img_bgr = cv2.imread(os.path.join(folder, chosen))
        if img_bgr is None:
            continue
        img_seg = segment_hsv(img_bgr)
        originals.append(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))
        segmented.append(cv2.cvtColor(img_seg, cv2.COLOR_BGR2RGB))
        titles.append(re.sub(r"Tomato_+", "", cn))

    n   = len(originals)
    fig, axes = plt.subplots(n, 2, figsize=(8, n * 3))
    fig.suptitle("Segmentación HSV Threshold — Una muestra por clase",
                 fontsize=13, fontweight="bold", y=1.01)

    for i in range(n):
        axes[i, 0].imshow(originals[i])
        axes[i, 0].set_title(f"{titles[i]}\nOriginal", fontsize=8)
        axes[i, 0].axis("off")
        axes[i, 1].imshow(segmented[i])
        axes[i, 1].set_title(f"{titles[i]}\nHSV Threshold", fontsize=8)
        axes[i, 1].axis("off")

    plt.tight_layout()
    out_path = os.path.join(OUTPUT_DIR, "segmentacion_muestras_hsv.png")
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Mosaico guardado: segmentacion_muestras_hsv.png")


# =============================================================================

def main():
    print("=" * 65)
    print("  ENTRENAMIENTO CON SEGMENTACIÓN HSV THRESHOLD")
    print("  MobileNetV1 + MobileNetV2 — Tres Resoluciones")
    print("  Trabajo de Grado - Acelerador CNN en Zynq-7020")
    print("=" * 65)

    if not os.path.isdir(DATASET_ROOT):
        print(f"[ERROR] No se encontró: '{DATASET_ROOT}'")
        return

    with Timer("Indexado de archivos"):
        file_paths, labels, class_names = collect_file_paths(DATASET_ROOT)
    labels      = np.array(labels)
    num_classes = len(class_names)
    print(f"  Total: {len(file_paths)} imágenes | {num_classes} clases")

    # Generar muestras visuales ANTES de entrenar
    # (si algo falla en el entrenamiento ya tienes las imágenes)
    save_segmentation_samples(DATASET_ROOT, class_names)

    (paths_train, y_train,
     paths_val,   y_val,
     paths_test,  y_test) = split_paths(file_paths, labels)
    print(f"  Train={len(paths_train)}  Val={len(paths_val)}  Test={len(paths_test)}")

    summary_rows = []

    run_model("MobileNetV1", build_mobilenetv1,
              paths_train, y_train, paths_val, y_val,
              paths_test, y_test, class_names, num_classes, summary_rows)

    run_model("MobileNetV2", build_mobilenetv2,
              paths_train, y_train, paths_val, y_val,
              paths_test, y_test, class_names, num_classes, summary_rows)

    df       = pd.DataFrame(summary_rows)
    csv_path = os.path.join(OUTPUT_DIR, "tabla_hsv_completa.csv")
    df.to_csv(csv_path, index=False)

    print(f"\n{'='*65}")
    print("  TABLA RESUMEN FINAL — HSV Threshold")
    print(f"{'='*65}")
    print(df.to_string(index=False))
    print(f"\n  CSV guardado en: {csv_path}")
    print(f"\n  [ OK ] Resultados en: {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()