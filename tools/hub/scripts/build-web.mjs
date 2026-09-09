#!/usr/bin/env node
// リポジトリ直下で `flutter build web` を回し、成果物を tools/hub/web-dist/ へ複製する。
// build/web を直接配信しないのは、`flutter run -d chrome` や別ブランチのビルドが
// その場所を書き換えるため。web-dist/ はこのスクリプトでしか更新されない。
import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '..', '..', '..');
export const distDir = join(here, '..', 'web-dist');

/** `--base-href` は付けない: 秘密プレフィックスは起動ごとの乱数で、ハブが index.html を返すときに書き換える。 */
export const BUILD_WEB_ARGS = ['build', 'web', '--release', '--pwa-strategy=none', '--no-web-resources-cdn'];

/** 複製前に消す: 前回のビルドに残ったファイルが重なると「消したはずの資産」が配られる。 */
export function copyTree(src, dst) {
  rmSync(dst, { recursive: true, force: true });
  mkdirSync(dst, { recursive: true });
  cpSync(src, dst, { recursive: true });
}

export function writeBuildInfo(dst, info) {
  writeFileSync(join(dst, 'BUILD_INFO.json'), `${JSON.stringify(info, null, 2)}\n`);
}

const capture = (cmd, args, cwd) => {
  try {
    return execFileSync(cmd, args, { cwd, encoding: 'utf8' }).trim();
  } catch {
    return 'unknown';
  }
};

// import されただけのときはビルドしない（テストが関数だけを使う）。
if (process.argv[1] && process.argv[1].endsWith('build-web.mjs')) {
  console.log(`flutter ${BUILD_WEB_ARGS.join(' ')} (cwd: ${repoRoot})`);
  execFileSync('flutter', BUILD_WEB_ARGS, { cwd: repoRoot, stdio: 'inherit' });
  const built = join(repoRoot, 'build', 'web');
  if (!existsSync(join(built, 'index.html'))) throw new Error('build/web/index.html not found after the build');
  copyTree(built, distDir);
  writeBuildInfo(distDir, {
    gitRev: capture('git', ['rev-parse', 'HEAD'], repoRoot),
    flutterVersion: capture('flutter', ['--version', '--machine'], repoRoot).slice(0, 400),
    builtAt: new Date().toISOString(),
  });
  console.log(`copied to ${distDir}`);
}
