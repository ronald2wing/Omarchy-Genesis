#!/usr/bin/env python3

"""Genesis wake-word listener using openWakeWord (MIT).

Streams the microphone and detects a wake word with an openWakeWord model
(ONNX runtime). On detection it starts a Genesis listening session via
`omarchy-shell -q genesis begin`; the service handles capture, transcription,
and the 10-second auto-stop, and a cooldown prevents immediate re-triggering.

Requirements: run `bin/wake-word-setup` once (installs openwakeword +
onnxruntime + sounddevice into a venv and downloads a model). `wakeWord.model`
accepts a shipped name (hey_jarvis, alexa, hey_mycroft, hey_rhasspy) or a path
to a custom `.onnx` model; anything unrecognized falls back to `hey_jarvis`.
"""

import json
import os
import subprocess
import time

import numpy as np
import sounddevice as sd
from openwakeword import get_pretrained_model_paths
from openwakeword.model import Model

HOME = os.environ.get("HOME", "/tmp")
# Config lives outside the plugin dir so writes don't trip the shell's hot-reload.
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config")), "genesis", "config.json")

RATE = 16000
BLOCK = 1280  # 80 ms, openWakeWord's preferred frame size


def config_value(path, default):
    try:
        with open(CONFIG, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return default
    for key in path.split("."):
        if not isinstance(data, dict) or key not in data:
            return default
        data = data[key]
    return data


def trigger_service(method):
    subprocess.run(
        ["omarchy-shell", "-q", "genesis", method],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def resolve_model(model_name):
    """Resolve `wakeWord.model` to something openWakeWord can load.

    Returns the reference to pass to Model(): an existing file path, or a
    shipped model name. Returns None when the name matches neither, so the
    caller can fall back to a shipped model.
    """
    if os.path.exists(model_name):
        return model_name
    shipped = [os.path.basename(p) for p in get_pretrained_model_paths("onnx")]
    name = model_name.replace(" ", "_")
    return model_name if any(name in s for s in shipped) else None


def main():
    model_name = str(config_value("wakeWord.model", "hey_jarvis"))
    threshold = float(config_value("wakeWord.threshold", "0.5"))
    cooldown = 10.0

    ref = resolve_model(model_name)
    if ref is None:
        print(
            f"wake-word: no model for '{model_name}'. To use it, train a custom "
            "openWakeWord model (see the README) and point wakeWord.model at the "
            ".onnx file. Falling back to 'hey_jarvis' for now.",
            flush=True,
        )
        ref = "hey_jarvis"

    model = Model(wakeword_models=[ref], inference_framework="onnx")
    print(f"Genesis wake-word listening for '{ref}'")

    last_trigger = 0.0

    def callback(indata, frames, time_info, status):
        nonlocal last_trigger
        if status:
            return
        audio = (indata.flatten() * 32767).astype(np.int16)
        now = time.time()
        if now - last_trigger < cooldown:
            return
        for score in model.predict(audio).values():
            if score > threshold:
                last_trigger = now
                print("Wake word detected.")
                trigger_service("begin")
                break

    with sd.InputStream(samplerate=RATE, channels=1, blocksize=BLOCK, callback=callback):
        while True:
            sd.sleep(1000)


if __name__ == "__main__":
    main()
