// Draws Blimp's mark (a tilted capsule with a sound wave cut through it) and
// writes every app icon from it, so they all match: the Android launcher,
// themed and notification icons, the Windows .ico, and the website and store
// pictures. Needs only Node, no packages.
//
// Usage: node tool/make_icons.js [preview folder]
// The preview folder, if given, gets PNGs of each size to look over.
//
// It also prints the mark as path data in a 100 box, which is what AppLogo
// in lib/screens/home_screen.dart draws; copy it there if the shape changes.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const repo = path.join(__dirname, "..");
const preview = process.argv[2];
const YELLOW = [0xfa, 0xcc, 0x15];
const INK = [0x11, 0x11, 0x11];

// ---- Geometry, in a 512 box, before tilting -------------------------------
const C = 256, ANGLE = -14 * Math.PI / 180;
const CAP = { x: 86, y: 171, w: 340, h: 170 }; // capsule; radius = h/2
const WAVE = [[134,256],[182,256],[210,214],[248,300],[286,200],[322,292],[346,256],[378,256]];
const HALF = 11; // half the wave's width

// A path is a list of segments: ["M",x,y] ["L",x,y] ["A",cx,cy,r,a0,a1] ["Z"]
function capsule() {
  const r = CAP.h / 2, x0 = CAP.x + r, x1 = CAP.x + CAP.w - r, cy = CAP.y + r;
  return [["M", x0, CAP.y], ["L", x1, CAP.y], ["A", x1, cy, r, -Math.PI / 2, Math.PI / 2],
          ["L", x0, CAP.y + CAP.h], ["A", x0, cy, r, Math.PI / 2, Math.PI * 1.5], ["Z"]];
}

// Outline of the wave drawn with round caps and joins.
function waveOutline() {
  const p = WAVE, n = p.length;
  const dir = [], nor = [];
  for (let i = 0; i < n - 1; i++) {
    const dx = p[i+1][0] - p[i][0], dy = p[i+1][1] - p[i][1], l = Math.hypot(dx, dy);
    dir.push([dx / l, dy / l]); nor.push([-dy / l, dx / l]);
  }
  const off = (pt, nv, s) => [pt[0] + s * HALF * nv[0], pt[1] + s * HALF * nv[1]];
  const ang = (c, q) => Math.atan2(q[1] - c[1], q[0] - c[0]);
  // Arc around c from a to b, going the way that passes `through` (outside).
  const arc = (c, a, b, through) => {
    let a0 = ang(c, a), a1 = ang(c, b), mid = ang(c, through);
    const norm = (x) => ((x % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI);
    // Try the positive direction; if `through` isn't on it, go negative.
    const span = norm(a1 - a0), m = norm(mid - a0);
    if (m <= span) return ["A", c[0], c[1], HALF, a0, a0 + span];
    return ["A", c[0], c[1], HALF, a0, a0 - (2 * Math.PI - span)];
  };
  const side = (s, idx) => { // walk one side; s=+1 left, -1 right; idx = vertex order
    const out = [];
    for (let k = 1; k < idx.length - 1; k++) {
      const v = idx[k], sa = s > 0 ? v - 1 : v, sb = s > 0 ? v : v - 1; // segments before/after
      const na = s > 0 ? nor[sa] : nor[sa].map(x => -x), nb = s > 0 ? nor[sb] : nor[sb].map(x => -x);
      const da = s > 0 ? dir[sa] : dir[sa].map(x => -x), db = s > 0 ? dir[sb] : dir[sb].map(x => -x);
      const pa = off(p[v], na, 1), pb = off(p[v], nb, 1);
      // Where the two edge lines cross. If that's before this side reaches
      // the corner, this is the inside of the bend and the edges just meet
      // there; otherwise it's the outside, rounded off with an arc.
      const den = da[0] * db[1] - da[1] * db[0];
      const t = ((pb[0] - pa[0]) * db[1] - (pb[1] - pa[1]) * db[0]) / den;
      const ip = [pa[0] + t * da[0], pa[1] + t * da[1]];
      if (t < 0) out.push(["L", ...ip]);
      else { out.push(["L", ...pa]); out.push(arc(p[v], pa, pb, [p[v][0] + HALF * (na[0] + nb[0]), p[v][1] + HALF * (na[1] + nb[1])])); }
    }
    return out;
  };
  const segs = [];
  const fwd = [...Array(n).keys()], back = [...fwd].reverse();
  segs.push(["M", ...off(p[0], nor[0], 1)]);
  segs.push(...side(1, fwd));
  const endA = off(p[n-1], nor[n-2], 1), endB = off(p[n-1], nor[n-2], -1);
  segs.push(["L", ...endA]);
  segs.push(arc(p[n-1], endA, endB, [p[n-1][0] + HALF * dir[n-2][0], p[n-1][1] + HALF * dir[n-2][1]]));
  segs.push(...side(-1, back));
  const stA = off(p[0], nor[0], -1), stB = off(p[0], nor[0], 1);
  segs.push(["L", ...stA]);
  segs.push(arc(p[0], stA, stB, [p[0][0] - HALF * dir[0][0], p[0][1] - HALF * dir[0][1]]));
  segs.push(["Z"]);
  return segs;
}

const MARK = [...capsule(), ...waveOutline()];

// Tilt, scale and move a point: tilt about the centre, then scale and shift.
function tf(s, tx, ty) {
  const c = Math.cos(ANGLE), sn = Math.sin(ANGLE);
  return ([x, y]) => {
    const dx = x - C, dy = y - C;
    return [(C + dx * c - dy * sn) * s + tx, (C + dx * sn + dy * c) * s + ty];
  };
}

// SVG / Android path data. Arcs keep their radius (scaled); only end points move.
function pathData(s, tx, ty, dp = 2) {
  const T = tf(s, tx, ty), f = (v) => +v.toFixed(dp);
  let d = "";
  for (const seg of MARK) {
    if (seg[0] === "M" || seg[0] === "L") { const q = T([seg[1], seg[2]]); d += `${seg[0]}${f(q[0])},${f(q[1])}`; }
    else if (seg[0] === "A") {
      const [, cx, cy, r, a0, a1] = seg;
      const end = T([cx + r * Math.cos(a1), cy + r * Math.sin(a1)]);
      const large = Math.abs(a1 - a0) > Math.PI + 1e-6 ? 1 : 0, sweep = a1 > a0 ? 1 : 0;
      d += `A${f(r * s)},${f(r * s)} 0 ${large} ${sweep} ${f(end[0])},${f(end[1])}`;
    } else d += "Z";
  }
  return d;
}

// Flatten to polygons for drawing pixels.
function polygons(s, tx, ty) {
  const T = tf(s, tx, ty), polys = [];
  let cur = null;
  for (const seg of MARK) {
    if (seg[0] === "M") { cur = [T([seg[1], seg[2]])]; polys.push(cur); }
    else if (seg[0] === "L") cur.push(T([seg[1], seg[2]]));
    else if (seg[0] === "A") {
      const [, cx, cy, r, a0, a1] = seg, steps = Math.max(8, Math.ceil(Math.abs(a1 - a0) * 24));
      for (let i = 1; i <= steps; i++) { const a = a0 + (a1 - a0) * i / steps; cur.push(T([cx + r * Math.cos(a), cy + r * Math.sin(a)])); }
    }
  }
  return polys;
}

function roundRect(x, y, w, h, r) {
  const pts = [], k = 16;
  const corner = (cx, cy, a) => { for (let i = 0; i <= k; i++) { const t = a + (Math.PI / 2) * i / k; pts.push([cx + r * Math.cos(t), cy + r * Math.sin(t)]); } };
  corner(x + w - r, y + r, -Math.PI / 2); corner(x + w - r, y + h - r, 0);
  corner(x + r, y + h - r, Math.PI / 2); corner(x + r, y + r, Math.PI);
  return [pts];
}
function circle(cx, cy, r) {
  const pts = []; for (let i = 0; i < 256; i++) { const a = 2 * Math.PI * i / 256; pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]); }
  return [pts];
}

// Even-odd coverage, 16 sub-rows per pixel, exact-ish horizontal edges.
function coverage(size, polys) {
  const cov = new Float32Array(size * size), SUB = 16;
  const edges = [];
  for (const poly of polys) for (let i = 0; i < poly.length; i++) {
    const a = poly[i], b = poly[(i + 1) % poly.length];
    if (a[1] !== b[1]) edges.push(a[1] < b[1] ? [a, b] : [b, a]);
  }
  for (let row = 0; row < size * SUB; row++) {
    const y = (row + 0.5) / SUB, xs = [];
    for (const [a, b] of edges) if (y >= a[1] && y < b[1]) xs.push(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]));
    xs.sort((m, n) => m - n);
    const py = Math.floor(row / SUB);
    for (let i = 0; i + 1 < xs.length; i += 2) {
      const x0 = Math.max(0, xs[i]), x1 = Math.min(size, xs[i + 1]);
      if (x1 <= x0) continue;
      const p0 = Math.floor(x0), p1 = Math.floor(x1);
      if (p0 === p1) { cov[py * size + p0] += (x1 - x0) / SUB; continue; }
      cov[py * size + p0] += (p0 + 1 - x0) / SUB;
      for (let px = p0 + 1; px < p1; px++) cov[py * size + px] += 1 / SUB;
      if (p1 < size) cov[py * size + p1] += (x1 - p1) / SUB;
    }
  }
  return cov;
}

// Layers drawn back to front: [polys, rgb]
function render(size, layers) {
  const px = new Float32Array(size * size * 4);
  for (const [polys, rgb] of layers) {
    const cov = coverage(size, polys);
    for (let i = 0; i < size * size; i++) {
      const a = Math.min(1, cov[i]); if (!a) continue;
      const da = px[i*4+3], oa = a + da * (1 - a);
      for (let c = 0; c < 3; c++) px[i*4+c] = (rgb[c] * a + px[i*4+c] * da * (1 - a)) / oa;
      px[i*4+3] = oa;
    }
  }
  return png(size, px);
}

function png(size, px) {
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0;
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4, o = y * (size * 4 + 1) + 1 + x * 4;
      raw[o] = Math.round(px[i]); raw[o+1] = Math.round(px[i+1]); raw[o+2] = Math.round(px[i+2]); raw[o+3] = Math.round(px[i+3] * 255);
    }
  }
  const crcTable = [...Array(256)].map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcTable[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}

// ---- Variants ---------------------------------------------------------------
// The mark's tip reaches 170 units from the centre. `reach` is that as a share of half the image.
const markAt = (size, reach) => { const s = (reach * size / 2) / 170; return polygons(s, size / 2 - C * s, size / 2 - C * s); };

const fullSquare = (size) => render(size, [[roundRect(0, 0, size, size, 0), YELLOW], [markAt(size, 0.6), INK]]);
const legacyRound = (size) => render(size, [[circle(size/2, size/2, size/2), YELLOW], [markAt(size, 0.64), INK]]);
// Windows: rounded square with a small margin; small sizes fill more and get a bigger mark.
const winIcon = (size) => {
  const m = size >= 48 ? size * 0.03 : 0, r = size * 0.2;
  const reach = size <= 24 ? 0.84 : size <= 48 ? 0.74 : 0.64;
  return render(size, [[roundRect(m, m, size - 2*m, size - 2*m, r), YELLOW], [markAt(size, reach), INK]]);
};

function ico(sizes) {
  const imgs = sizes.map(winIcon);
  const head = Buffer.alloc(6 + 16 * sizes.length);
  head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(sizes.length, 4);
  let off = head.length;
  sizes.forEach((s, i) => {
    const e = 6 + 16 * i;
    head[e] = s >= 256 ? 0 : s; head[e+1] = s >= 256 ? 0 : s; head[e+2] = 0; head[e+3] = 0;
    head.writeUInt16LE(1, e+4); head.writeUInt16LE(32, e+6);
    head.writeUInt32LE(imgs[i].length, e+8); head.writeUInt32LE(off, e+12); off += imgs[i].length;
  });
  return Buffer.concat([head, ...imgs]);
}

// store_listing/ is kept only on the maintainer's computer, so it's skipped when missing.
const w = (rel, data) => {
  const p = path.join(repo, rel);
  if (!fs.existsSync(path.dirname(p))) return console.log("skipped", rel, "(folder missing)");
  fs.writeFileSync(p, data); console.log("wrote", rel);
};

// Android adaptive foreground (108dp canvas, mark well inside the 66dp safe zone). Also the themed icon.
const fgS = (0.62 * 36) / 170; // tip at 62% of the 36dp radius the launcher shows
w("android/app/src/main/res/drawable/ic_launcher_foreground.xml", `<?xml version="1.0" encoding="utf-8"?>
<!-- The launcher icon's mark: a tilted capsule with a sound wave cut through
     it, inside the 66dp safe zone that every launcher's mask keeps. Also the
     monochrome themed icon. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FF111111"
        android:fillType="evenOdd"
        android:pathData="${pathData(fgS, 54 - C * fgS, 54 - C * fgS)}" />
</vector>
`);

// Notification icon: a white silhouette in 24dp.
const stS = 11 / 170;
w("android/app/src/main/res/drawable/ic_stat_music.xml", `<?xml version="1.0" encoding="utf-8"?>
<!-- Status bar icon for the playback notification: the app's capsule mark.
     Android draws it as a white silhouette, so it's a single solid shape
     with the wave cut out. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:fillType="evenOdd"
        android:pathData="${pathData(stS, 12 - C * stS, 12 - C * stS)}" />
</vector>
`);

// Master SVG for the website and anyone making graphics.
const svS = (0.6 * 256) / 170;
w("docs/img/icon.svg", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" fill="#FACC15"/><path fill="#111111" fill-rule="evenodd" d="${pathData(svS, 256 - C * svS, 256 - C * svS)}"/></svg>
`);

// The mark alone in a 100 box, for the in-app logo.
const ffS = 50 / 170;
console.log("FLUTTER_PATH " + pathData(ffS, 50 - C * ffS, 50 - C * ffS));

w("docs/img/icon.png", fullSquare(512));
w("store_listing/icon_512.png", fullSquare(512));
w("store_listing/launch_video/assets/icon.png", fullSquare(512));
for (const [dir, s] of [["mdpi",48],["hdpi",72],["xhdpi",96],["xxhdpi",144],["xxxhdpi",192]])
  w(`android/app/src/main/res/mipmap-${dir}/ic_launcher.png`, legacyRound(s));
w("windows/runner/resources/app_icon.ico", ico([16,20,24,32,40,48,64,128,256]));

// Previews to look at.
if (!preview) process.exit(0);
fs.mkdirSync(preview, { recursive: true });
for (const s of [16, 24, 32, 48, 256]) fs.writeFileSync(path.join(preview, `win_${s}.png`), winIcon(s));
fs.writeFileSync(path.join(preview, "legacy_192.png"), legacyRound(192));
// Adaptive icon as a launcher shows it: the middle 72dp of 108, in a circle, at 4x.
{
  const size = 288, s = fgS * (size / 72), t = size / 2 - C * s;
  fs.writeFileSync(path.join(preview, "adaptive.png"), render(size, [[circle(size/2, size/2, size/2), YELLOW], [polygons(s, t, t), INK]]));
  const st = 96, s2 = stS * 4, t2 = st / 2 - C * s2;
  fs.writeFileSync(path.join(preview, "stat_96.png"), render(st, [[roundRect(0, 0, st, st, 0), [40, 40, 40]], [polygons(s2, t2, t2), [255, 255, 255]]]));
}
