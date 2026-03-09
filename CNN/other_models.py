"""
=============================================================================
COMPARATIVA DE MODELOS CNN - DETECCIÓN DE ENFERMEDADES EN TOMATES
Trabajo de Grado - Acelerador CNN en Zynq-7020
=============================================================================
Entrena y evalúa 3 modelos alternativos para comparar con MobileNetV1:
  - LeNet-5 adaptado
  - MobileNetV2 restringido (~210k parámetros)
  - EfficientNet-B0 reducido (~210k parámetros)

Mismas condiciones que el segundo entrenamiento de MobileNetV1:
  - Dataset segmentado con U-Net
  - Resolución 256x256 (la que dio mejor resultado)
  - Mismas métricas: accuracy, confusion matrix, tiempos
  - Mismos hiperparámetros: Adam, lr=1e-3, batch=32, epochs=30
  - Cuantización INT8 e INT16
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
# CONFIGURACIÓN
# =============================================================================
DATASET_ROOT = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/PlantVillage_segmentado"
OUTPUT_DIR   = "/mnt/c/Users/ANGEL OBANDO/Documents/Trabajo de grado/CNN/resultados_comparativa"
os.makedirs(OUTPUT_DIR, exist_ok=True)

RESOLUTION  = 256    # Solo la resolución que dio mejor resultado
BATCH_SIZE  = 32
EPOCHS      = 30
SEED        = 42
VAL_SPLIT   = 0.15
TEST_SPLIT  = 0.15
QUANT_MODES = ["int8", "int16"]
# =============================================================================

tf.random.set_seed(SEED)
np.random.seed(SEED)


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
    """Mismo SEED que MobileNetV1 → mismo test set → comparación justa."""
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
    """Carga imagen sin segmentación (ya vienen segmentadas del dataset)."""
    def _load(p, sz):
        p  = p.numpy().decode("utf-8")
        sz = int(sz.numpy())
        img = cv2.imread(p)
        if img is None:
            img = np.zeros((sz, sz, 3), dtype=np.uint8)
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


def plot_training_curves(history, model_name):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    axes[0].plot(history.history["accuracy"],    label="Train")
    axes[0].plot(history.history["val_accuracy"], label="Val")
    axes[0].set_title(f"Accuracy — {model_name}")
    axes[0].set_xlabel("Época"); axes[0].legend()
    axes[1].plot(history.history["loss"],    label="Train")
    axes[1].plot(history.history["val_loss"], label="Val")
    axes[1].set_title(f"Loss — {model_name}")
    axes[1].set_xlabel("Época"); axes[1].legend()
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, f"training_{model_name}.png"), dpi=150)
    plt.close(fig)


# =============================================================================
# ARQUITECTURAS
# =============================================================================

# --- LeNet-5 adaptado ---
# LeNet original tiene 5 capas con parámetros (2 conv + 3 dense).
# Lo adaptamos para entrada 256x256 y salida de 9 clases,
# escalando los filtros para quedar cerca de ~210k parámetros.

def build_lenet(input_size, num_classes):
    inp = layers.Input(shape=(input_size, input_size, 3))

    x = layers.Conv2D(32, 5, padding="same", activation="relu", name="conv1")(inp)
    x = layers.MaxPooling2D(2, name="pool1")(x)

    x = layers.Conv2D(64, 5, padding="same", activation="relu", name="conv2")(x)
    x = layers.MaxPooling2D(2, name="pool2")(x)

    x = layers.Conv2D(64, 3, padding="same", activation="relu", name="conv3")(x)
    x = layers.MaxPooling2D(2, name="pool3")(x)

    x = layers.GlobalAveragePooling2D(name="gap")(x)
    x = layers.Dense(128, activation="relu", name="fc1")(x)
    x = layers.Dense(num_classes, activation="softmax", name="output")(x)

    return models.Model(inp, x, name="LeNet_adapted")


# --- MobileNetV2 restringido ---
# MobileNetV2 usa bloques invertidos con residual connections.
# Canales limitados a 64 para quedar cerca de ~210k parámetros.

def inverted_residual_block(x, filters, strides=1, expand_ratio=2,
                             name_prefix="irb"):
    in_ch = x.shape[-1]
    exp_ch = in_ch * expand_ratio

    # Expansion
    if expand_ratio != 1:
        x_exp = layers.Conv2D(exp_ch, 1, padding="same", use_bias=False,
                               name=f"{name_prefix}_exp")(x)
        x_exp = layers.BatchNormalization(name=f"{name_prefix}_exp_bn")(x_exp)
        x_exp = layers.ReLU(6.0, name=f"{name_prefix}_exp_relu")(x_exp)
    else:
        x_exp = x

    # Depthwise
    x_dw = layers.DepthwiseConv2D(3, strides=strides, padding="same",
                                   use_bias=False,
                                   name=f"{name_prefix}_dw")(x_exp)
    x_dw = layers.BatchNormalization(name=f"{name_prefix}_dw_bn")(x_dw)
    x_dw = layers.ReLU(6.0, name=f"{name_prefix}_dw_relu")(x_dw)

    # Projection
    x_pw = layers.Conv2D(filters, 1, padding="same", use_bias=False,
                          name=f"{name_prefix}_pw")(x_dw)
    x_pw = layers.BatchNormalization(name=f"{name_prefix}_pw_bn")(x_pw)

    # Residual connection solo si shape coincide
    if strides == 1 and in_ch == filters:
        return layers.Add(name=f"{name_prefix}_add")([x, x_pw])
    return x_pw


def build_mobilenetv2(input_size, num_classes, max_ch=64):
    inp = layers.Input(shape=(input_size, input_size, 3))

    # Conv inicial
    x = layers.Conv2D(min(32, max_ch), 3, strides=2, padding="same",
                       use_bias=False, name="conv1")(inp)
    x = layers.BatchNormalization(name="conv1_bn")(x)
    x = layers.ReLU(6.0, name="conv1_relu")(x)

    # Bloques invertidos — configuración reducida para ~210k params
    # (t=expand_ratio, c=channels, s=stride)
    cfg = [
        # t, c,  s
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
        c_capped = min(c, max_ch)
        x = inverted_residual_block(x, c_capped, strides=s,
                                     expand_ratio=t,
                                     name_prefix=f"irb{i+1}")

    # Conv final
    x = layers.Conv2D(min(64, max_ch), 1, padding="same", use_bias=False,
                       name="conv_last")(x)
    x = layers.BatchNormalization(name="conv_last_bn")(x)
    x = layers.ReLU(6.0, name="conv_last_relu")(x)

    x = layers.GlobalAveragePooling2D(name="gap")(x)
    x = layers.Dense(num_classes, activation="softmax", name="output")(x)

    return models.Model(inp, x, name="MobileNetV2_restricted")


# --- EfficientNet-B0 reducido ---
# EfficientNet usa MBConv blocks con Squeeze-and-Excitation.
# Versión reducida para quedar cerca de ~210k parámetros.

def se_block(x, se_ratio=4, name_prefix="se"):
    """Squeeze-and-Excitation block."""
    ch  = x.shape[-1]
    se_ch = max(1, ch // se_ratio)
    se = layers.GlobalAveragePooling2D(name=f"{name_prefix}_gap")(x)
    se = layers.Reshape((1, 1, ch), name=f"{name_prefix}_reshape")(se)
    se = layers.Conv2D(se_ch, 1, activation="relu",
                        name=f"{name_prefix}_fc1")(se)
    se = layers.Conv2D(ch, 1, activation="sigmoid",
                        name=f"{name_prefix}_fc2")(se)
    return layers.Multiply(name=f"{name_prefix}_mul")([x, se])


def mbconv_block(x, filters, strides=1, expand_ratio=2, se_ratio=4,
                  name_prefix="mb"):
    in_ch = x.shape[-1]
    exp_ch = in_ch * expand_ratio

    # Expansion
    if expand_ratio != 1:
        x_exp = layers.Conv2D(exp_ch, 1, padding="same", use_bias=False,
                               name=f"{name_prefix}_exp")(x)
        x_exp = layers.BatchNormalization(name=f"{name_prefix}_exp_bn")(x_exp)
        x_exp = layers.Activation("swish", name=f"{name_prefix}_exp_swish")(x_exp)
    else:
        x_exp = x

    # Depthwise
    x_dw = layers.DepthwiseConv2D(3, strides=strides, padding="same",
                                   use_bias=False,
                                   name=f"{name_prefix}_dw")(x_exp)
    x_dw = layers.BatchNormalization(name=f"{name_prefix}_dw_bn")(x_dw)
    x_dw = layers.Activation("swish", name=f"{name_prefix}_dw_swish")(x_dw)

    # SE
    x_se = se_block(x_dw, se_ratio=se_ratio, name_prefix=f"{name_prefix}_se")

    # Projection
    x_pw = layers.Conv2D(filters, 1, padding="same", use_bias=False,
                          name=f"{name_prefix}_pw")(x_se)
    x_pw = layers.BatchNormalization(name=f"{name_prefix}_pw_bn")(x_pw)

    # Residual
    if strides == 1 and in_ch == filters:
        return layers.Add(name=f"{name_prefix}_add")([x, x_pw])
    return x_pw


def build_efficientnet(input_size, num_classes, max_ch=64):
    inp = layers.Input(shape=(input_size, input_size, 3))

    # Stem
    x = layers.Conv2D(min(32, max_ch), 3, strides=2, padding="same",
                       use_bias=False, name="stem_conv")(inp)
    x = layers.BatchNormalization(name="stem_bn")(x)
    x = layers.Activation("swish", name="stem_swish")(x)

    # MBConv blocks — versión reducida
    cfg = [
        # expand, filters, stride
        (1, 16, 1),
        (2, 24, 2),
        (2, 24, 1),
        (2, 40, 2),
        (2, 40, 1),
        (2, 64, 2),
        (2, 64, 1),
        (2, 64, 1),
    ]

    for i, (t, c, s) in enumerate(cfg):
        c_capped = min(c, max_ch)
        x = mbconv_block(x, c_capped, strides=s, expand_ratio=t,
                          name_prefix=f"mb{i+1}")

    # Head
    x = layers.Conv2D(min(64, max_ch), 1, padding="same", use_bias=False,
                       name="head_conv")(x)
    x = layers.BatchNormalization(name="head_bn")(x)
    x = layers.Activation("swish", name="head_swish")(x)

    x = layers.GlobalAveragePooling2D(name="gap")(x)
    x = layers.Dense(num_classes, activation="softmax", name="output")(x)

    return models.Model(inp, x, name="EfficientNet_reduced")


# =============================================================================
# ENTRENAMIENTO
# =============================================================================

def train_model(model, ds_train, ds_val, model_name):
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
    print(f"\n  Parámetros {model_name}: {model.count_params():,}")
    with Timer(f"Entrenamiento {model_name}") as t:
        history = model.fit(
            ds_train, validation_data=ds_val,
            epochs=EPOCHS, callbacks=cbs, verbose=1
        )
    return history, t.elapsed


# =============================================================================
# EVALUACIÓN
# =============================================================================

def evaluate_model(model, paths_test, labels_test, class_names,
                   model_name, resolution):
    # Usar tf.data en lugar de cargar todo en RAM
    ds_test = build_dataset(paths_test, labels_test, resolution,
                            BATCH_SIZE, shuffle=False)

    t0 = time.perf_counter()
    y_pred_proba = model.predict(ds_test, verbose=0)
    batch_time = time.perf_counter() - t0
    y_pred = np.argmax(y_pred_proba, axis=1)

    acc = accuracy_score(labels_test, y_pred)
    ms_per_img = (batch_time / len(paths_test)) * 1000

    print(f"  Accuracy float32: {acc:.4f}")
    print(f"  Tiempo/imagen: {ms_per_img:.2f} ms")

    cm = confusion_matrix(labels_test, y_pred)
    plot_cm(cm, class_names, f"{model_name}_float32")

    return {"accuracy": acc, "inference_single_ms": ms_per_img,
            "inference_batch_s": batch_time}

# =============================================================================
# CUANTIZACIÓN
# =============================================================================

def make_representative_dataset(paths_calib, target_size):
    samples = list(paths_calib[:200])
    def gen():
        for p in samples:
            img = cv2.imread(p)
            if img is None:
                continue
            img = cv2.resize(img, (target_size, target_size))
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
            yield [img[np.newaxis]]
    return gen


def quantize_and_evaluate(model, paths_test, labels_test, class_names,
                           model_name, target_size, qmode, paths_calib):
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
    conversion_time = t.elapsed

    model_path = os.path.join(OUTPUT_DIR, f"model_{model_name}_{qmode}.tflite")
    with open(model_path, "wb") as f:
        f.write(tflite_model)
    model_kb = os.path.getsize(model_path) / 1024
    print(f"  Tamaño {qmode}: {model_kb:.1f} KB")

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

    y_pred = []
    t0 = time.perf_counter()
    for p in paths_test:
        img = cv2.imread(p)
        if img is None:
            y_pred.append(0); continue
        img = cv2.resize(img, (target_size, target_size))
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        y_pred.append(run_one(img))
    elapsed = time.perf_counter() - t0

    acc        = accuracy_score(labels_test, y_pred)
    ms_per_img = (elapsed / len(paths_test)) * 1000

    print(f"  Accuracy {qmode}: {acc:.4f}  |  {ms_per_img:.2f} ms/img")
    cm = confusion_matrix(labels_test, y_pred)
    plot_cm(cm, class_names, f"{model_name}_{qmode}")

    return {"accuracy": acc, "inference_single_ms": ms_per_img,
            "model_size_kb": model_kb, "conversion_s": conversion_time}


# =============================================================================
# TABLA COMPARATIVA FINAL
# =============================================================================

def generate_comparison_plot(df):
    """Gráfico de barras comparando accuracy de todos los modelos."""
    df_p = df[df["accuracy"] != "ERROR"].copy()
    df_p["accuracy"] = df_p["accuracy"].astype(float)

    model_names = df_p["model"].unique()
    quants      = df_p["quant"].unique()
    x     = np.arange(len(model_names))
    width = 0.25

    fig, ax = plt.subplots(figsize=(14, 6))
    for i, q in enumerate(quants):
        vals = [df_p.loc[(df_p["model"]==m)&(df_p["quant"]==q), "accuracy"].values
                for m in model_names]
        vals = [v[0] if len(v) else 0 for v in vals]
        bars = ax.bar(x + i*width, vals, width, label=q.upper())
        for bar, val in zip(bars, vals):
            ax.text(bar.get_x()+bar.get_width()/2, bar.get_height()+0.005,
                    f"{val:.3f}", ha="center", va="bottom", fontsize=8)

    ax.set_xticks(x + width)
    ax.set_xticklabels(model_names, rotation=15, ha="right")
    ax.set_ylim(0, 1.05)
    ax.set_ylabel("Accuracy")
    ax.set_title("Comparativa de Modelos — Dataset Segmentado U-Net (256×256)")
    ax.legend()
    plt.tight_layout()
    fig.savefig(os.path.join(OUTPUT_DIR, "comparativa_modelos.png"), dpi=150)
    plt.close(fig)
    print("  Gráfico comparativo guardado: comparativa_modelos.png")


# =============================================================================
# MAIN
# =============================================================================

def main():
    print("=" * 60)
    print("  COMPARATIVA DE MODELOS CNN — TOMATE / ZYNQ-7020")
    print("=" * 60)

    if not os.path.isdir(DATASET_ROOT):
        print(f"[ERROR] No se encontró: '{DATASET_ROOT}'")
        return

    # Indexar archivos
    print("\n  Indexando archivos...")
    file_paths, labels, class_names = collect_file_paths(DATASET_ROOT)
    labels = np.array(labels)
    num_classes = len(class_names)
    print(f"  Total: {len(file_paths)} imágenes | {num_classes} clases")

    (paths_train, y_train,
     paths_val,   y_val,
     paths_test,  y_test) = split_paths(file_paths, labels)
    print(f"  Train={len(paths_train)}  Val={len(paths_val)}  Test={len(paths_test)}")

    # Datasets
    ds_train = build_dataset(paths_train, y_train, RESOLUTION, BATCH_SIZE, shuffle=True)
    ds_val   = build_dataset(paths_val,   y_val,   RESOLUTION, BATCH_SIZE)

    # Modelos a comparar
    model_builders = {
        "LeNet":        lambda: build_lenet(RESOLUTION, num_classes),
        "MobileNetV2":  lambda: build_mobilenetv2(RESOLUTION, num_classes),
        "EfficientNet": lambda: build_efficientnet(RESOLUTION, num_classes),
    }

    summary_rows = []

    for model_name, builder in model_builders.items():
        print(f"\n{'='*60}")
        print(f"  MODELO: {model_name}")
        print(f"{'='*60}")

        model = builder()

        # Entrenamiento
        history, train_time = train_model(model, ds_train, ds_val, model_name)
        plot_training_curves(history, model_name)

        # Guardar modelo
        model_path = os.path.join(OUTPUT_DIR, f"model_{model_name}.keras")
        model.save(model_path)
        model_kb_full = os.path.getsize(model_path) / 1024

        # Evaluación float32
        print(f"\n  >> Evaluación Float32")
        f32 = evaluate_model(
            model, paths_test, y_test, class_names, model_name, RESOLUTION
        )
        summary_rows.append({
            "model": model_name,
            "params": model.count_params(),
            "quant": "float32",
            "accuracy": f32["accuracy"],
            "inference_single_ms": f32["inference_single_ms"],
            "model_size_kb": model_kb_full,
            "train_s": train_time,
            "conversion_s": None
        })

        # Cuantizaciones
        for qmode in QUANT_MODES:
            print(f"\n  >> Cuantización {qmode.upper()}")
            try:
                qres = quantize_and_evaluate(
                    model, paths_test, y_test, class_names,
                    model_name, RESOLUTION, qmode, paths_train
                )
                summary_rows.append({
                    "model": model_name,
                    "params": model.count_params(),
                    "quant": qmode,
                    "accuracy": qres["accuracy"],
                    "inference_single_ms": qres["inference_single_ms"],
                    "model_size_kb": qres["model_size_kb"],
                    "train_s": train_time,
                    "conversion_s": qres["conversion_s"]
                })
            except Exception as e:
                print(f"  [WARN] {qmode} falló: {e}")
                summary_rows.append({
                    "model": model_name, "quant": qmode,
                    "accuracy": "ERROR", "inference_single_ms": "ERROR",
                    "model_size_kb": "ERROR"
                })

        tf.keras.backend.clear_session()

    # Tabla resumen
    df = pd.DataFrame(summary_rows)
    csv_path = os.path.join(OUTPUT_DIR, "comparativa_modelos.csv")
    df.to_csv(csv_path, index=False)

    print(f"\n{'='*60}")
    print("  TABLA COMPARATIVA FINAL")
    print(f"{'='*60}")
    print(df.to_string(index=False))
    print(f"\n  Guardada en: {csv_path}")

    generate_comparison_plot(df)
    print(f"\n  [ OK ] Comparativa completada. Resultados en: {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()