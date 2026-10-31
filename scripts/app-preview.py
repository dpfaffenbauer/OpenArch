#!/usr/bin/env -S uv run --no-project --with numpy --with pillow python
"""Cuts the App Store previews from takes of the iOS app's -demo run
(iOS/OpenArch/Demo.swift): captions, a score made here, and the format App
Store Connect takes: 886x1920, H.264, 30 fps, stereo AAC, at most 30 seconds.

    scripts/app-preview.py record <udid> <display or -> <take.mov> <take.log>
    scripts/app-preview.py cut iphone|duo <take.mov> <take.log> <out.mp4>
"""
import re
import signal
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

BPM = 128
BAR = 240 / BPM
W, H = 886, 1920
ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "iOS/OpenArch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def font(size, weight="Bold"):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name(weight)
    except OSError:
        pass
    return f


# name, offset from the scene's mark, bars, caption, caption's y on the iPhone
SCENES = [
    ("spaces", 0.0, 2, "Ein Browser.\nViele Spaces.", 1240),
    ("command", -0.5, 1, "Tippen. Finden. Offen.", 620),
    ("page", 0.0, 1, "Tippen. Finden. Offen.", 620),
    ("pin", -0.4, 2, "Anheften,\nwas bleiben soll.", 1240),
    ("tabs", 0.0, 2, "Favoriten mit einem Tipp.", 1560),
    ("read", -0.1, 2, None, 1560),
    ("share", -0.9, 1, "Ordner teilen:\nverschlüsselt, ohne Konto.", 1670),
    ("qr", 0.0, 1, "Ordner teilen:\nverschlüsselt, ohne Konto.", 1670),
    ("end", 0.0, 2, None, 0),
]
READ = {"iphone": "Die Seite im Mittelpunkt.", "duo": "Die Seite bis zum Rand."}
FPS = 30


def record(udid, display, out, log, seconds=80):
    subprocess.run(["xcrun", "simctl", "terminate", udid, "at.pfaffenbauer.openarch"], capture_output=True)
    command = ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force"]
    if display != "-":
        command.append(f"--display={display}")
    recorder = subprocess.Popen([*command, out], stderr=subprocess.PIPE, text=True)
    print(recorder.stderr.readline().strip())
    with open(log, "w") as file:
        file.write(f"[rec] start {time.time()}\n")
        file.flush()
        app = subprocess.Popen(["xcrun", "simctl", "launch", "--console-pty", udid, "at.pfaffenbauer.openarch", "-demo"],
                               stdout=file, stderr=subprocess.STDOUT)
        end = time.time() + seconds
        while time.time() < end and "[demo] done" not in open(log, errors="ignore").read():
            time.sleep(0.5)
    time.sleep(1)
    recorder.send_signal(signal.SIGINT)
    recorder.wait(timeout=60)
    app.terminate()


def marks(log):
    text = open(log, errors="ignore").read()
    start = float(re.search(r"\[rec\] start ([\d.]+)", text).group(1))
    return {m.group(1): float(m.group(2)) - start for m in re.finditer(r"\[demo\] scene (\w+) ([\d.]+)", text)}


def sync_offset(take, tabs):
    """The recorder's clock starts with its first frame, a little off the log's.
    The picture says by how much: the first favorite opens at the "tabs" mark."""
    log = subprocess.run(["ffmpeg", "-hide_banner", "-i", take, "-vf", "scale=160:-1,select='gt(scene,0.04)',showinfo",
                          "-f", "null", "-"], capture_output=True, text=True).stderr
    cuts = [float(t) for t in re.findall(r"pts_time:([\d.]+)", log)]
    near = [t for t in cuts if tabs - 0.2 <= t <= tabs + 0.8]
    offset = near[0] - tabs if near else 0.0
    print(f"the picture is {offset:+.2f} s off the log")
    return offset


def caption_pill(text, y, path):
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    f = font(64)
    box = draw.multiline_textbbox((0, 0), text, font=f, align="center", spacing=12)
    tw, th = box[2] - box[0], box[3] - box[1]
    x0, y0 = (W - tw) / 2 - 44, y - 36
    draw.rounded_rectangle((x0, y0, x0 + tw + 88, y0 + th + 80), 44, fill=(12, 14, 20, 225))
    draw.multiline_text(((W - tw) / 2 - box[0], y - box[1] + 4), text, font=f, fill="white", align="center", spacing=12)
    image.save(path)


def caption_top(text, top, height, path):
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    size = 80
    while True:
        f = font(size)
        box = draw.multiline_textbbox((0, 0), text, font=f, align="center", spacing=14)
        if box[2] - box[0] <= W - 70:
            break
        size -= 2
    tw, th = box[2] - box[0], box[3] - box[1]
    draw.multiline_text(((W - tw) / 2 - box[0], top + (height - th) / 2 - box[1]), text, font=f, fill="white",
                        align="center", spacing=14)
    image.save(path)


def end_card(y, path, side=220):
    """The icon, the name and the line under it."""
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    icon = Image.open(ICON).convert("RGBA").resize((side, side), Image.LANCZOS)
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, side - 1, side - 1), side * 0.23, fill=255)
    image.paste(icon, ((W - side) // 2, y), mask)
    scale = side / 220
    draw.text((W / 2, y + side + 40 * scale), "OpenArch", font=font(int(104 * scale)), fill="white", anchor="ma")
    draw.text((W / 2, y + side + 172 * scale), "Open Source. Ohne Konto.", font=font(int(50 * scale), "Semibold"),
              fill="white", anchor="ma")
    image.save(path)


def score(seconds, path, rate=48000):
    """Four on the floor in A minor; everything is synthesized here, so that
    there is nothing to license."""
    n = int(seconds * rate)
    beat = 60 / BPM
    left, right = np.zeros(n), np.zeros(n)
    t_all = np.arange(n) / rate
    rng = np.random.default_rng(7)

    def add(signal, at, pan=0.5):
        i = int(at * rate)
        if i >= n:
            return
        part = signal[: n - i]
        left[i:i + len(part)] += part * np.cos(pan * np.pi / 2) * 1.41
        right[i:i + len(part)] += part * np.sin(pan * np.pi / 2) * 1.41

    t = np.arange(int(0.28 * rate)) / rate
    kick = np.sin(2 * np.pi * (48 * t + 34 * (1 - np.exp(-t * 28)) / 28 * 3)) * np.exp(-t * 11)
    t = np.arange(int(0.05 * rate)) / rate
    hat = np.diff(rng.standard_normal(len(t) + 1)) * np.exp(-t * 90) * 0.13
    t = np.arange(int(0.2 * rate)) / rate
    clap = np.diff(rng.standard_normal(len(t) + 1)) * np.exp(-t * 24) * 0.2

    # A minor, F, C, G: one chord per bar.
    roots = [55.0, 43.65, 65.41, 49.0]
    chords = [[220, 261.63, 329.63], [174.61, 220, 261.63], [196, 261.63, 329.63], [196, 246.94, 293.66]]
    steps = int(seconds / beat * 2) + 1
    # What ducks under the kick.
    duck = np.ones(n)
    for k in range(int(seconds / beat) + 1):
        i = int(k * beat * rate)
        length = min(int(beat * rate * 0.9), n - i)
        if length > 0:
            duck[i:i + length] = 0.28 + 0.72 * (np.arange(length) / length) ** 0.7

    pad, bass = np.zeros(n), np.zeros(n)
    for step in range(steps):
        at = step * beat / 2
        bar = int(at / BAR) % 4
        i = int(at * rate)
        length = min(int(beat / 2 * rate), n - i)
        if length <= 0:
            continue
        t = np.arange(length) / rate
        env = np.exp(-t * 7)
        for note in chords[bar]:
            for detune in (0.997, 1.003):
                phase = (note * detune * t) % 1
                pad[i:i + length] += (2 * phase - 1) * env * 0.05
        root = roots[bar] * (2 if step % 4 == 3 else 1)
        bass[i:i + length] += np.tanh(2.2 * np.sin(2 * np.pi * root * t)) * np.exp(-t * 4) * 0.34

    # One pole low pass that opens over the piece.
    cutoff = np.interp(t_all, [0, seconds * 0.8, seconds], [1400, 5200, 5200])
    a = 1 - np.exp(-2 * np.pi * cutoff / rate)
    y = 0.0
    filtered = np.zeros(n)
    for i, (sample, coefficient) in enumerate(zip(pad, a)):
        y += coefficient * (sample - y)
        filtered[i] = y
    filtered *= duck
    bass *= duck
    left += filtered * 0.9 + bass
    right += filtered * 1.1 + bass

    hits = int((seconds - BAR) / beat)
    for k in range(hits):
        add(kick, k * beat)
        add(hat, (k + 0.5) * beat, 0.62)
        add(hat * 0.5, (k + 0.75) * beat, 0.38)
        if k % 2 == 1:
            add(clap, k * beat, 0.5)
    # The last two bars ring out on the chord.
    add(kick * 1.2, hits * beat)
    fade = np.clip((seconds - t_all) / 0.9, 0, 1)
    left, right = left * fade, right * fade
    stereo = np.stack([left, right], 1)
    stereo *= 0.72 / np.abs(stereo).max()
    with wave.open(str(path), "wb") as file:
        file.setnchannels(2)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes((stereo * 32767).astype("<i2").tobytes())


def cut(variant, take, log, out):
    at = marks(log)
    offset_all = sync_offset(take, at["tabs"])
    at = {name: t + offset_all for name, t in at.items()}
    total = sum(s[2] for s in SCENES) * BAR
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        music = temp / "score.wav"
        score(total, music)
        inputs = ["-i", take, "-i", str(music)]
        filters, parts = [], []
        duo = variant == "duo"
        # On the Duo, the outer display fills the width, with the captions above it.
        if duo:
            band = 480
            place = (f"scale={W}:-2:flags=lanczos,pad={W}:{H}:0:{band}:color=0x0E1116")
        else:
            band = 0
            place = (f"scale={W}:-2:flags=lanczos,crop={W}:{H}")
        clock = 0.0
        overlays = []
        count = 2
        previous = None
        for index, (name, offset, bars, text, y) in enumerate(SCENES):
            start = at[name] + offset
            length = bars * BAR
            # The recorder writes only frames that differ, and none at the end.
            filters.append(f"[0:v]fps={FPS},tpad=stop_mode=clone:stop_duration=20,"
                           f"trim=start={start:.3f}:duration={length:.3f},setpts=PTS-STARTPTS,"
                           f"{place},setsar=1,format=yuv420p[v{index}]")
            parts.append(f"[v{index}]")
            line = READ[variant] if name == "read" else text
            if line == previous and overlays:
                # The same caption stays over the cut.
                overlays[-1] = (overlays[-1][0], overlays[-1][1], clock + length)
                clock += length
                continue
            previous = line
            png = temp / f"c{index}.png"
            if name == "end":
                if duo:
                    end_card(44, png, side=170)
                else:
                    end_card(1040, png)
            elif duo:
                caption_top(line, 0, band, png)
            else:
                caption_pill(line, y, png)
            inputs += ["-loop", "1", "-t", f"{total:.3f}", "-i", str(png)]
            overlays.append((count, clock + 0.05, clock + length))
            count += 1
            clock += length
        filters.append(f"{''.join(parts)}concat=n={len(parts)}:v=1:a=0[base]")
        last = "base"
        for n, (input_index, begin, end) in enumerate(overlays):
            fade_out = "" if n == len(overlays) - 1 else f",fade=out:st={end - 0.14:.3f}:d=0.12:alpha=1"
            filters.append(f"[{input_index}:v]format=rgba,fade=in:st={begin:.3f}:d=0.12:alpha=1{fade_out}[o{n}]")
            filters.append(f"[{last}][o{n}]overlay=enable='between(t,{begin:.3f},{end:.3f})':format=auto[b{n}]")
            last = f"b{n}"
        filters.append(f"[{last}]fade=out:st={total - 0.35:.3f}:d=0.35,format=yuv420p[video]")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs,
                        "-filter_complex", ";".join(filters), "-map", "[video]", "-map", "1:a",
                        "-t", f"{total:.3f}", "-r", str(FPS),
                        "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.0", "-preset", "slow",
                        "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "11M",
                        "-x264-params", "nal-hrd=cbr:force-cfr=1",
                        "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
                        "-movflags", "+faststart", out], check=True)


if __name__ == "__main__":
    if sys.argv[1] == "record":
        record(*sys.argv[2:6])
    else:
        cut(*sys.argv[2:6])
