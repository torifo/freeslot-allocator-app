#!/usr/bin/env node
// @ts-check
// リポジトリ直下で `flutter build web` を回し、成果物を tools/hub/web-dist/ へ複製する。
// build/web を直接配信しないのは、`flutter run -d chrome` や別ブランチのビルドが
// その場所を書き換えるため。web-dist/ はこのスクリプトでしか更新されない。
import { cpSync, existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '..', '..', '..');
export const distDir = join(here, '..', 'web-dist');

/** `--base-href` は付けない: 秘密プレフィックスは起動ごとの乱数で、ハブが index.html を返すときに書き換える。 */
export const BUILD_WEB_ARGS = ['build', 'web', '--release', '--pwa-strategy=none', '--no-web-resources-cdn'];

/**
 * ビルド成果物を丸ごと差し替える。まず `<dst>.tmp` に組み立ててから rename するので、
 * 途中で失敗しても既存の web-dist は無傷のまま残る（消してから複製すると、
 * 失敗した瞬間にハブが「未ビルド」に落ちる）。
 * @param {string} src 複製元ディレクトリ
 * @param {string} dst 複製先ディレクトリ
 * @returns {void}
 */
export function copyTree(src, dst) {
  const staging = `${dst}.tmp`;
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });
  try {
    cpSync(src, staging, { recursive: true });
    // rename は同名の非空ディレクトリを上書きできないので、直前に退避してから差し替える。
    const previous = `${dst}.old-${process.pid}`;
    const had = existsSync(dst);
    if (had) renameSync(dst, previous);
    try {
      renameSync(staging, dst);
    } catch (error) {
      if (had) renameSync(previous, dst);
      throw error;
    }
    if (had) rmSync(previous, { recursive: true, force: true });
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

/**
 * @param {string} dst 書き込み先ディレクトリ
 * @param {{ gitRev: string, flutterVersion: string, builtAt: string }} info
 * @returns {void}
 */
export function writeBuildInfo(dst, info) {
  writeFileSync(join(dst, 'BUILD_INFO.json'), `${JSON.stringify(info, null, 2)}\n`);
}

/**
 * 失敗しても止めない補助コマンド（git や flutter --version）。
 * @param {string} cmd
 * @param {readonly string[]} args
 * @param {string} cwd
 * @returns {string}
 */
const capture = (cmd, args, cwd) => {
  try {
    return execFileSync(cmd, args, { cwd, encoding: 'utf8' }).trim();
  } catch {
    return 'unknown';
  }
};

/** このファイルが `node scripts/build-web.mjs` として直接起動されたか。import されただけなら false。 */
export const isMain = process.argv[1] !== undefined
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

/** @returns {void} */
export function main() {
  console.log(`flutter ${BUILD_WEB_ARGS.join(' ')} (cwd: ${repoRoot})`);
  try {
    execFileSync('flutter', BUILD_WEB_ARGS, { cwd: repoRoot, stdio: 'inherit' });
  } catch (error) {
    const code = /** @type {NodeJS.ErrnoException} */ (error).code;
    if (code === 'ENOENT') {
      throw new Error(
        'flutter が PATH にありません。Flutter SDK を入れて `flutter --version` が通る状態にしてから、'
        + 'もう一度 `npm run build:web` を実行してください。web 版が無くてもハブ自体は動きます'
        + '（ブラウザ画面だけが「未ビルド」になります）。',
      );
    }
    throw new Error('`flutter build web` が失敗しました。上のログを確認してください。');
  }
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

if (isMain) main();
