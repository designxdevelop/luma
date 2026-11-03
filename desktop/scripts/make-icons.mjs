// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Copies the Mac app's icon (macos/Luma/Assets.xcassets/AppIcon.appiconset) so every
// platform ships the same Luma lightbulb. Run: node scripts/make-icons.mjs (outputs are checked in).

import { copyFileSync, mkdirSync } from 'node:fs';

const set = '../macos/Luma/Assets.xcassets/AppIcon.appiconset';
mkdirSync('assets', { recursive: true });
copyFileSync(`${set}/icon_256x256@2x.png`, 'assets/icon.png');      // 512 px: installer, window, Linux
copyFileSync(`${set}/icon_32x32.png`, 'assets/tray.png');           // tray (resized to 16 in main)
copyFileSync(`${set}/icon_32x32@2x.png`, 'src/renderer/static/luma.png'); // sidebar brand
console.log('Copied the Mac app icon to assets/ and the renderer.');
