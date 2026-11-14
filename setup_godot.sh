#!/bin/bash
set -e
REPO="Xilleet/caribbean_trade"
FILE="Godot_v4.7.2-stable_linux.x86_64.zip"
mkdir -p .godot_bin
if [ ! -f .godot_bin/godot ]; then
    curl -sL "https://github.com/Xilleet/caribbean_trade/releases/download/tools/Godot_v4.7.2-stable_linux.x86_64.zip" -o .godot_bin/godot.zip
    unzip -q .godot_bin/godot.zip -d .godot_bin/
    mv .godot_bin/Godot_v4.7.2-stable_linux.x86_64 .godot_bin/godot
    chmod +x .godot_bin/godot
    rm .godot_bin/godot.zip
fi
