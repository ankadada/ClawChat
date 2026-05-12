/**
 * OpenClaw Installer - Handles environment setup for Termux
 */

import { execSync, execFileSync, spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import { installBypass, getBypassScriptPath, getNodeOptions, BYPASS_SCRIPT } from './bionic-bypass.js';

const HOME = process.env.HOME || '/data/data/com.termux/files/home';
const BASHRC = path.join(HOME, '.bashrc');
const ZSHRC = path.join(HOME, '.zshrc');
const PROOT_ROOTFS = '/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs';
const PROOT_UBUNTU_ROOT = path.join(PROOT_ROOTFS, 'ubuntu', 'root');

export function checkDependencies() {
  const deps = {
    node: false,
    npm: false,
    git: false,
    proot: false
  };

  try {
    execSync('node --version', { stdio: 'pipe' });
    deps.node = true;
  } catch { /* not installed */ }

  try {
    execSync('npm --version', { stdio: 'pipe' });
    deps.npm = true;
  } catch { /* not installed */ }

  try {
    execSync('git --version', { stdio: 'pipe' });
    deps.git = true;
  } catch { /* not installed */ }

  try {
    execSync('which proot-distro', { stdio: 'pipe' });
    deps.proot = true;
  } catch { /* not installed */ }

  return deps;
}

export function installTermuxDeps() {
  console.log('Installing Termux dependencies...');

  const packages = ['nodejs-lts', 'git', 'openssh'];

  try {
    execSync('pkg update -y', { stdio: 'inherit' });
    execSync(`pkg install -y ${packages.join(' ')}`, { stdio: 'inherit' });
    return true;
  } catch (err) {
    console.error('Failed to install Termux packages:', err.message);
    return false;
  }
}

export function setupBionicBypass() {
  console.log('Setting up Bionic Bypass...');

  const scriptPath = installBypass();
  const nodeOptions = getNodeOptions();
  const exportLine = `export NODE_OPTIONS="${nodeOptions}"`;

  // Add to shell configs
  for (const rcFile of [BASHRC, ZSHRC]) {
    if (fs.existsSync(rcFile)) {
      const content = fs.readFileSync(rcFile, 'utf8');
      if (!content.includes('bionic-bypass')) {
        fs.appendFileSync(rcFile, `\n# OpenClaw Bionic Bypass\n${exportLine}\n`);
        console.log(`Updated ${path.basename(rcFile)}`);
      }
    }
  }

  // Also set for current session
  process.env.NODE_OPTIONS = nodeOptions;

  return scriptPath;
}

export function installOpenClaw() {
  console.log('Installing OpenClaw...');

  try {
    execSync('npm install -g openclaw', { stdio: 'inherit' });
    return true;
  } catch (err) {
    console.error('Failed to install OpenClaw:', err.message);
    console.log('You may need to install it manually: npm install -g openclaw');
    return false;
  }
}

export function configureTermux() {
  console.log('Configuring Termux for background operation...');

  // Create wake-lock script
  const wakeLockScript = path.join(HOME, '.openclaw', 'wakelock.sh');
  const wakeLockContent = `#!/bin/bash
# Keep Termux awake while OpenClaw runs
termux-wake-lock
trap "termux-wake-unlock" EXIT
exec "$@"
`;

  fs.mkdirSync(path.dirname(wakeLockScript), { recursive: true });
  fs.writeFileSync(wakeLockScript, wakeLockContent, 'utf8');
  fs.chmodSync(wakeLockScript, '755');

  console.log('Wake-lock script created');
  console.log('');
  console.log('IMPORTANT: Disable battery optimization for Termux in Android settings!');

  return true;
}

// Cache for getInstallStatus to avoid repeated synchronous subprocess calls.
// Call getInstallStatus(true) to force a fresh check.
let _installStatusCache = null;

export function getInstallStatus(forceRefresh = false) {
  if (_installStatusCache && !forceRefresh) {
    return _installStatusCache;
  }

  const PROOT_ROOTFS = '/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs';

  // Check proot-distro
  let hasProot = false;
  try {
    execSync('command -v proot-distro', { stdio: 'pipe' });
    hasProot = true;
  } catch { /* not installed */ }

  // Check if ubuntu is installed by checking rootfs directory
  let hasUbuntu = false;
  try {
    hasUbuntu = fs.existsSync(path.join(PROOT_ROOTFS, 'ubuntu'));
  } catch { /* check failed */ }

  // Check if openclaw exists in proot ubuntu
  // Primary: fast filesystem check (avoids proot exec which can timeout on first login)
  let hasOpenClawInProot = false;
  if (hasUbuntu) {
    try {
      const openclawPkg = path.join(PROOT_ROOTFS, 'ubuntu', 'usr', 'local', 'lib', 'node_modules', 'openclaw', 'package.json');
      const hasNode = fs.existsSync(path.join(PROOT_ROOTFS, 'ubuntu', 'usr', 'local', 'bin', 'node'));
      hasOpenClawInProot = fs.existsSync(openclawPkg) && hasNode;
    } catch { /* check failed */ }

    // Fallback: proot exec with longer timeout and login shell
    if (!hasOpenClawInProot) {
      try {
        execSync('proot-distro login ubuntu -- bash -lc "command -v openclaw"', { stdio: 'pipe', timeout: 30000 });
        hasOpenClawInProot = true;
      } catch { /* not installed */ }
    }
  }

  // Check bionic bypass in proot
  let hasBionicBypassInProot = false;
  try {
    const prootBypassPath = path.join(PROOT_ROOTFS, 'ubuntu', 'root', '.openclaw', 'bionic-bypass.js');
    hasBionicBypassInProot = fs.existsSync(prootBypassPath);
  } catch { /* check failed */ }

  _installStatusCache = {
    proot: hasProot,
    ubuntu: hasUbuntu,
    openClawInProot: hasOpenClawInProot,
    bionicBypassInProot: hasBionicBypassInProot,
    // Legacy (for termux-native mode)
    bionicBypass: fs.existsSync(getBypassScriptPath()),
    nodeOptions: process.env.NODE_OPTIONS?.includes('bionic-bypass') || false,
    openClaw: (() => {
      try {
        execSync('command -v openclaw', { stdio: 'pipe' });
        return true;
      } catch { return false; }
    })()
  };
  return _installStatusCache;
}

export function installProot() {
  console.log('Installing proot-distro...');
  try {
    execSync('pkg install -y proot-distro', { stdio: 'inherit' });
    return true;
  } catch (err) {
    console.error('Failed to install proot-distro:', err.message);
    return false;
  }
}

export function installUbuntu() {
  console.log('Installing Ubuntu in proot (this may take a while)...');
  try {
    execSync('proot-distro install ubuntu', { stdio: 'inherit' });
    return true;
  } catch (err) {
    console.error('Failed to install Ubuntu:', err.message);
    return false;
  }
}

export function setupProotUbuntu() {
  console.log('Setting up Node.js and OpenClaw in Ubuntu...');

  const steps = [
    ['bash', '-c', 'apt update && apt upgrade -y'],
    ['bash', '-c', 'apt install -y curl wget git'],
    ['bash', '-c', 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'],
    ['bash', '-c', 'apt install -y nodejs'],
    ['bash', '-c', 'npm install -g openclaw'],
  ];

  try {
    for (const args of steps) {
      execFileSync('proot-distro', ['login', 'ubuntu', '--', ...args], { stdio: 'inherit' });
    }
    return true;
  } catch (err) {
    console.error('Failed to setup Ubuntu:', err.message);
    return false;
  }
}

export function setupBionicBypassInProot() {
  console.log('Setting up Bionic Bypass in proot Ubuntu...');

  const prootBypassPath = path.join(PROOT_UBUNTU_ROOT, '.openclaw', 'bionic-bypass.js');
  const prootBypassDir = path.dirname(prootBypassPath);

  try {
    if (!fs.existsSync(prootBypassDir)) {
      fs.mkdirSync(prootBypassDir, { recursive: true });
    }
    fs.writeFileSync(prootBypassPath, BYPASS_SCRIPT, 'utf8');

    // Add to bashrc in proot
    const prootBashrc = path.join(PROOT_UBUNTU_ROOT, '.bashrc');
    const exportLine = 'export NODE_OPTIONS="--require /root/.openclaw/bionic-bypass.js"';

    let bashrcContent = '';
    if (fs.existsSync(prootBashrc)) {
      bashrcContent = fs.readFileSync(prootBashrc, 'utf8');
    }

    if (!bashrcContent.includes('bionic-bypass')) {
      fs.appendFileSync(prootBashrc, `\n# OpenClaw Bionic Bypass\n${exportLine}\n`);
    }

    console.log('Bionic Bypass configured in proot Ubuntu');
    return true;
  } catch (err) {
    console.error('Failed to setup Bionic Bypass in proot:', err.message);
    return false;
  }
}

/**
 * Shell-escape a single argument by wrapping it in single quotes
 * and escaping any embedded single quotes.
 */
export function shellEscape(arg) {
  return "'" + String(arg).replace(/'/g, "'\\''") + "'";
}

export function runInProot(command, args = []) {
  const nodeOptions = '--require /root/.openclaw/bionic-bypass.js';
  const escapedArgs = args.map(shellEscape).join(' ');
  const shellCmd = `export NODE_OPTIONS=${shellEscape(nodeOptions)} && ${command}${escapedArgs ? ' ' + escapedArgs : ''}`;
  return spawn('proot-distro', ['login', 'ubuntu', '--', 'bash', '-c', shellCmd], {
    stdio: 'inherit'
  });
}

export function runInProotWithCallback(command, args = [], onFirstOutput) {
  const nodeOptions = '--require /root/.openclaw/bionic-bypass.js';
  const escapedArgs = args.map(shellEscape).join(' ');
  const shellCmd = `export NODE_OPTIONS=${shellEscape(nodeOptions)} && ${command}${escapedArgs ? ' ' + escapedArgs : ''}`;
  let firstOutput = true;

  const proc = spawn('proot-distro', ['login', 'ubuntu', '--', 'bash', '-c', shellCmd], {
    stdio: ['inherit', 'pipe', 'pipe']
  });

  proc.stdout.on('data', (data) => {
    if (firstOutput) {
      firstOutput = false;
      onFirstOutput();
    }
    process.stdout.write(data);
  });

  proc.stderr.on('data', (data) => {
    if (firstOutput) {
      firstOutput = false;
      onFirstOutput();
    }
    // Filter out harmless proot warnings
    const str = data.toString();
    if (!str.includes('proot warning') && !str.includes("can't sanitize")) {
      process.stderr.write(data);
    }
  });

  return proc;
}
