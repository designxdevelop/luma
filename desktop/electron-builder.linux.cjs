// Linux packaging config. Inherits the shared `build` block from package.json (files, appId, icon,
// product name) and adds Linux targets only, so the Windows NSIS config is untouched.
//
//   npx electron-builder --config electron-builder.linux.cjs --linux tar.gz --x64   -> release-linux/*-x64.tar.gz
//   npx electron-builder --config electron-builder.linux.cjs --linux tar.gz --arm64 -> release-linux/*-arm64.tar.gz
//
// tar.gz is the default: portable and needs no FUSE. AppImage and deb are opt-in on the command line
// (`--linux AppImage deb`) when the build host has the tools. Artifacts are unsigned.
const { build } = require('./package.json');

const { win, nsis, ...shared } = build;

module.exports = {
  ...shared,
  directories: { ...shared.directories, output: 'release-linux' },
  // Arch is part of every filename so x64 and arm64 artifacts can never be confused.
  artifactName: 'luma-${version}-linux-${arch}.${ext}',
  linux: {
    executableName: 'luma',
    target: [{ target: 'tar.gz', arch: ['x64'] }],
    icon: 'assets/icon.png',
    category: 'Utility',
    synopsis: 'Govee light controller with LAN Screen Sync',
    description: 'Luma controls Govee lights over the cloud API and the local network.',
    maintainer: 'Design X Develop LLC <https://github.com/designxdevelop/luma>',
    // The sandbox is never disabled here. See docs/LINUX.md for chrome-sandbox on tar.gz installs.
    desktop: {
      entry: { Name: 'Luma', Comment: 'Govee light controller', Categories: 'Utility;', StartupWMClass: 'Luma' },
    },
  },
  deb: { depends: ['libgtk-3-0', 'libnotify4', 'libnss3', 'libxss1', 'libxtst6', 'xdg-utils', 'libatspi2.0-0', 'libuuid1', 'libsecret-1-0'] },
};
