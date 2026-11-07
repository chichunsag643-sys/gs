// Renders tool/icon/build/*.svg into the PNG icon sets. Run after make_icon.py:
//   node tool/icon/render.js
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..', '..');
const build = path.join(__dirname, 'build');

async function png(page, svgFile, size, out) {
  const svg = fs.readFileSync(path.join(build, svgFile), 'utf8');
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<html><body style="margin:0;background:transparent">
    <div style="width:${size}px;height:${size}px">${svg.replace('<svg ', `<svg width="${size}" height="${size}" `)}</div></body></html>`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  await page.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  const res = path.join(root, 'android/app/src/main/res');
  for (const [d, s] of [['mdpi', 48], ['hdpi', 72], ['xhdpi', 96], ['xxhdpi', 144], ['xxxhdpi', 192]]) {
    await png(page, 'legacy.svg', s, path.join(res, `mipmap-${d}/ic_launcher.png`));
  }
  const ios = path.join(root, 'ios/Runner/Assets.xcassets/AppIcon.appiconset');
  for (const f of fs.readdirSync(ios).filter(f => f.endsWith('.png'))) {
    const m = f.match(/Icon-App-([\d.]+)x[\d.]+@(\d)x\.png/);
    const s = Math.round(parseFloat(m[1]) * parseInt(m[2]));
    await png(page, 'square.svg', s, path.join(ios, f));
  }
  const mac = path.join(root, 'macos/Runner/Assets.xcassets/AppIcon.appiconset');
  for (const f of fs.readdirSync(mac).filter(f => f.endsWith('.png'))) {
    const s = parseInt(f.match(/(\d+)/)[1]);
    await png(page, 'macos.svg', s, path.join(mac, f));
  }
  await png(page, 'full.svg', 512, path.join(build, 'full-512.png'));
  await png(page, 'mono.svg', 512, path.join(build, 'mono-512.png'));
  await browser.close();
  console.log('ok');
})();
