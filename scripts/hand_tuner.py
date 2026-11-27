"""VOTV VR hand tuner (desktop window). Controls thread, 2026-11-27.

UEVR 1.05 gives Lua scripts no menu-drawing library, so the in-game hand panel can't exist; this window does the
same job from the desktop (also visible in the headset through Virtual Desktop's desktop view) while the game runs.

- Pose presets per button state (open, trigger, grip, fist, thumb rest, thumb press): 5 finger curls each, saved
  to <UEVR profile>/votv_hand_presets.txt, which votv_controls.dll reloads within 250 ms.
- "Preview" shows the selected preset on both in-game hands (setting hands_preview).
- Bend and placement settings: written to scripts/votv_controls.txt in the UEVR profile (live, re-read every 250 ms)
  and to the repo's profile copy (the launcher copies that one over at every start, so it is the one that lasts).

Run: Hand-Tuner.bat, or .venv\\Scripts\\python -I scripts\\hand_tuner.py
"""
import os
import re
import tkinter as tk
from tkinter import ttk

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE = os.path.join(os.environ.get("APPDATA", ""), "UnrealVRMod", "VotV-Win64-Shipping")
LIVE_SETTINGS = os.path.join(PROFILE, "scripts", "votv_controls.txt")
REPO_SETTINGS = os.path.join(REPO, "profile", "VotV-Win64-Shipping", "scripts", "votv_controls.txt")
PRESETS_FILE = os.path.join(PROFILE, "votv_hand_presets.txt")

PRESETS = [("open", "Open hand (nothing pressed)"), ("trigger", "Trigger pulled"), ("grip", "Grip held"),
           ("fist", "Grip + trigger (fist)"), ("thumb_rest", "Thumb resting on a button"),
           ("thumb_press", "Thumb pressing a button")]
FINGERS = ["Thumb", "Index", "Middle", "Ring", "Pinky"]
DEFAULT_PRESETS = {"open": [0.1] * 5, "trigger": [0.1, 0.85, 0.1, 0.1, 0.1], "grip": [0.2, 0.1, 0.9, 0.9, 0.9],
                   "fist": [0.6, 0.9, 0.9, 0.9, 0.9], "thumb_rest": [0.5, 0, 0, 0, 0], "thumb_press": [0.9, 0, 0, 0, 0]}
SETTINGS = [  # key, label, low, high, resolution
    # finger bend itself comes from the game's Kerfur animations (0 = its open hand, 1 = its fist)
    ("hands_x", "Hand forward (cm)", -25, 25, 0.5), ("hands_y", "Hand sideways (cm)", -25, 25, 0.5),
    ("hands_z", "Hand up (cm)", -25, 25, 0.5), ("hands_pitch", "Hand pitch", -180, 180, 1),
    ("hands_yaw", "Hand yaw", -180, 180, 1), ("hands_roll", "Hand roll", -180, 180, 1),
    ("hands_scale", "Hand size", 0.5, 2, 0.01),
]


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def get_setting(text, key, default):
    m = re.search(r"^" + re.escape(key) + r"\s*=\s*(-?[\d.]+)", text, re.M)
    return float(m.group(1)) if m else default


def set_setting(text, key, value):
    line = f"{key}={value:g}"
    if re.search(r"^" + re.escape(key) + r"\s*=", text, re.M):
        return re.sub(r"^" + re.escape(key) + r"\s*=.*$", line, text, flags=re.M)
    return text.rstrip("\n") + "\n" + line + "\n"


def write_settings(changes):
    for path in (LIVE_SETTINGS, REPO_SETTINGS):
        text = read(path)
        if not text and path == LIVE_SETTINGS and not os.path.isdir(os.path.dirname(path)):
            continue
        for k, v in changes.items():
            text = set_setting(text, k, v)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)


def load_presets():
    p = {k: list(v) for k, v in DEFAULT_PRESETS.items()}
    for name, rest in re.findall(r"^(\w+)=(.*)$", read(PRESETS_FILE), re.M):
        vals = [float(x) for x in rest.split()]
        if name in p and len(vals) == 5:
            p[name] = vals
    return p


def save_presets(p):
    os.makedirs(PROFILE, exist_ok=True)
    with open(PRESETS_FILE, "w", encoding="utf-8", newline="\n") as f:
        for name, _ in PRESETS:
            f.write(name + "=" + " ".join(f"{v:.2f}" for v in p[name]) + "\n")


class App:
    def __init__(self, root):
        self.root = root
        root.title("VOTV VR hand tuner")
        self.presets = load_presets()
        self.pending = {}
        self.after = None
        live = read(LIVE_SETTINGS) or read(REPO_SETTINGS)

        top = ttk.LabelFrame(root, text="Pose presets (saved instantly; the game picks them up within a second)")
        top.pack(fill="x", padx=8, pady=6)
        self.sel = tk.StringVar(value=PRESETS[0][0])
        self.preview = tk.BooleanVar(value=False)
        row = ttk.Frame(top); row.pack(fill="x")
        for name, label in PRESETS:
            ttk.Radiobutton(row, text=label, value=name, variable=self.sel, command=self.on_select).pack(anchor="w")
        ttk.Checkbutton(top, text="Preview this preset on both hands in game", variable=self.preview,
                        command=self.on_preview).pack(anchor="w", pady=4)
        self.finger_vars = []
        for i, fname in enumerate(FINGERS):
            v = tk.DoubleVar()
            self.finger_vars.append(v)
            f = ttk.Frame(top); f.pack(fill="x")
            ttk.Label(f, text=fname, width=8).pack(side="left")
            tk.Scale(f, from_=0, to=1, resolution=0.01, orient="horizontal", length=360, variable=v,
                     command=lambda _v, i=i: self.on_finger(i)).pack(side="left")

        bottom = ttk.LabelFrame(root, text="Hand placement (live)")
        bottom.pack(fill="x", padx=8, pady=6)
        self.setting_vars = {}
        for key, label, lo, hi, res in SETTINGS:
            v = tk.DoubleVar(value=get_setting(live, key, 0))
            self.setting_vars[key] = v
            f = ttk.Frame(bottom); f.pack(fill="x")
            ttk.Label(f, text=label, width=32).pack(side="left")
            tk.Scale(f, from_=lo, to=hi, resolution=res, orient="horizontal", length=300, variable=v,
                     command=lambda _v, k=key: self.on_setting(k)).pack(side="left")
        self.status = ttk.Label(root, text=f"Presets: {PRESETS_FILE}")
        self.status.pack(anchor="w", padx=8, pady=4)
        self.on_select()

    def on_select(self):
        vals = self.presets[self.sel.get()]
        for i, v in enumerate(self.finger_vars):
            v.set(vals[i])
        if self.preview.get():
            self.on_preview()

    def on_finger(self, i):
        self.presets[self.sel.get()][i] = round(self.finger_vars[i].get(), 2)
        save_presets(self.presets)
        self.status.config(text=f"Saved {self.sel.get()} to {PRESETS_FILE}")

    def on_preview(self):
        idx = [n for n, _ in PRESETS].index(self.sel.get()) + 1
        self.queue({"hands_preview": idx if self.preview.get() else 0})

    def on_setting(self, key):
        self.queue({key: self.setting_vars[key].get()})

    def queue(self, changes):
        self.pending.update(changes)
        if self.after:
            self.root.after_cancel(self.after)
        self.after = self.root.after(150, self.flush)

    def flush(self):
        write_settings(self.pending)
        self.status.config(text="Settings written: " + ", ".join(f"{k}={v:g}" for k, v in self.pending.items()))
        self.pending = {}
        self.after = None


if __name__ == "__main__":
    root = tk.Tk()
    App(root)
    root.protocol("WM_DELETE_WINDOW", lambda: (write_settings({"hands_preview": 0}), root.destroy()))
    root.mainloop()
