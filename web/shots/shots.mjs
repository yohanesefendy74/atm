// Gambar layar web (Admin & krani) dengan API tiruan, ukuran desktop & HP. Dipakai di CI untuk memeriksa tata letak.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const root = path.resolve('../../api/GudangAtm.Api/wwwroot');
const out = path.resolve(process.argv[2] ?? 'out');
fs.mkdirSync(out, { recursive: true });

const whs = [{ whsCode: 'WHS-001', whsName: 'GUDANG PUSAT', isTitipan: false, isDefault: true }, { whsCode: 'WHS-T01', whsName: 'GUDANG TITIPAN', isTitipan: true, isDefault: false }];
const ruang = [{ kodeRuangan: 'RG-A1', namaRuangan: 'Ruang A1', titipan: false, aktif: true, whsCode: 'WHS-001', kapasitasTon: 500 }, { kodeRuangan: 'RG-B2', namaRuangan: 'Ruang B2', titipan: false, aktif: true, whsCode: 'WHS-001', kapasitasTon: 300 }];
const mock = (p) => {
  if (p === '/api/auth/me') return { userId: 1, userCode: 'admin', name: 'Administrator', roles: ['Admin', 'Krani'], bplId: 1 };
  if (p === '/api/auth/csrf') return { token: 'x' };
  if (p === '/api/warehouses') return whs;
  if (p.endsWith('/master/ruangan')) return ruang;
  if (p.endsWith('/master/palet')) return [{ paletCode: 'PL-STD', panjangCm: 120, lebarCm: 100, tinggiCm: 15, beratKg: 25, aktif: true }];
  if (p === '/api/cms/setup') return [{ kode: 'NET_TOL_PCT', nilai: 0.5, keterangan: 'Toleransi net timbang vs input krani (%)' }, { kode: 'BRUTO_MAX_KG', nilai: 52000, keterangan: 'Bruto maksimum (kg)' }];
  if (p === '/api/cms/plan') return [{ planId: 1, planNo: 'SPBB/2610/0001', jenis: 'SPBB', whsCode: 'WHS-001', cardName: 'PT SUPPLIER MAJU', status: 'Terbit', kodeRuangan: 'RG-A1', dokumen: '12345', tglJadwal: '2026-10-21', qtyPlan: 25000, qtyDone: 0 }];
  if (p === '/api/cms/docs') return [{ objType: '6730', docEntry: 2610000001, docDate: '2026-10-21', trxCode: 'IB', whsCode: 'WHS-001', containerNo: 'EMCU1234567', krani: 'krani1', qtyKg: 25000, status: 'Open', cardName: 'PT SUPPLIER MAJU' }];
  if (p.startsWith('/api/reports/stock-container')) return [{ containerNo: 'EMCU1234567', kodeRuangan: 'RG-A1', itemCode: 'GLA-001', itemName: 'Gula Pasir', brand: 'MERAH', inboundDate: '2026-10-01', kg: 12500, sak: 250, palet: 10 }];
  if (p.startsWith('/api/reports/stock-item')) return [{ itemCode: 'GLA-001', itemName: 'Gula Pasir', kg: 12500, sak: 250, palet: 10, containers: 1, ruangan: 1 }];
  if (p === '/api/cms/jadwal') return { setup: {}, docks: ['D1', 'D2'], plans: [{ planId: 1, planNo: 'SPBB/2610/0001', jenis: 'SPBB', party: 'PT SUPPLIER MAJU', status: 'Terbit', kg: 25000, eta: '08:30' }] };
  if (p.startsWith('/api/cms/master/')) return [];
  if (p === '/api/cms/saldo/selisih') return { barisSaldo: 10, selisih: [] };
  return [];
};

const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.png': 'image/png', '.woff2': 'font/woff2', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname.startsWith('/api/')) {
    res.setHeader('Content-Type', 'application/json');
    return res.end(JSON.stringify(mock(u.pathname)));
  }
  let f = path.join(root, u.pathname);
  if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) f = path.join(root, 'index.html');
  res.setHeader('Content-Type', types[path.extname(f)] ?? 'application/octet-stream');
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(5179, r));

const pages = [
  ['plan-baru', '/admin/plan/baru', async (p) => { await p.click('button.chip:has-text("SPBB")'); }],
  ['plan-list', '/admin/plan'],
  ['master', '/admin/master'],
  ['jadwal', '/admin/jadwal'],
  ['surat-jalan', '/admin/surat-jalan'],
  ['kendaraan', '/admin/kendaraan'],
  ['setup', '/admin/setup'],
  ['cms', '/cms'],
  ['inbound-baru', '/inbound/new'],
  ['outbound-baru', '/outbound/new'],
  ['stok-container', '/reports/stock-container'],
];
const browser = await chromium.launch();
const errors = [];
for (const [vp, size] of [['desktop', { width: 1280, height: 800 }], ['hp', { width: 390, height: 844 }]]) {
  const ctx = await browser.newContext({ viewport: size, deviceScaleFactor: 1 });
  for (const [name, url, act] of pages) {
    const pg = await ctx.newPage();
    pg.on('pageerror', (e) => errors.push(`${vp} ${name}: ${e.message}`));
    await pg.goto(`http://localhost:5179${url}`, { waitUntil: 'networkidle' });
    if (act) { try { await act(pg); } catch (e) { errors.push(`${vp} ${name} aksi: ${e.message}`); } }
    await pg.waitForTimeout(400);
    // overflow horizontal = tata letak rusak di layar sempit
    const ov = await pg.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    if (ov > 2) errors.push(`${vp} ${name}: halaman melebar ${ov}px (scroll horizontal)`);
    await pg.screenshot({ path: path.join(out, `${vp}_${name}.png`), fullPage: true });
    await pg.close();
  }
  await ctx.close();
}
await browser.close();
server.close();
fs.writeFileSync(path.join(out, 'errors.txt'), errors.join('\n'));
console.log('ERRORS(' + errors.length + ')\n' + errors.join('\n'));
