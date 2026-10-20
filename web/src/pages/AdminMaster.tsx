import { useState } from 'react';
import { get, post, put, type Row } from '../api';
import { ErrorBox, Page, Spinner, errText, useLoad, useToast, useWarehouses } from '../ui';

type Field = { k: string; label: string; type?: 'text' | 'number' | 'bool' | 'whs'; pk?: boolean; hint?: string };
type Cfg = { key: string; title: string; path: string; fields: Field[]; pkPut?: boolean; whsFilter?: boolean; createable?: boolean };

const CFG: Cfg[] = [
  { key: 'ruangan', title: 'Ruangan', path: 'ruangan', whsFilter: true, createable: true, fields: [
    { k: 'kodeRuangan', label: 'Kode', pk: true, hint: 'mis. RG-A1' }, { k: 'whsCode', label: 'Gudang', type: 'whs' }, { k: 'namaRuangan', label: 'Nama' },
    { k: 'kapasitasTon', label: 'Kapasitas (ton)', type: 'number' }, { k: 'titipan', label: 'Titipan', type: 'bool' }, { k: 'aktif', label: 'Aktif', type: 'bool' }] },
  { key: 'palet', title: 'Palet', path: 'palet', createable: true, fields: [
    { k: 'paletCode', label: 'Kode', pk: true }, { k: 'panjangCm', label: 'Panjang cm', type: 'number' }, { k: 'lebarCm', label: 'Lebar cm', type: 'number' },
    { k: 'tinggiCm', label: 'Tinggi cm', type: 'number' }, { k: 'beratKg', label: 'Berat kg', type: 'number' }, { k: 'aktif', label: 'Aktif', type: 'bool' }] },
  { key: 'jenis', title: 'Jenis Container', path: 'jenis-container', fields: [
    { k: 'kode', label: 'Kode', pk: true }, { k: 'nama', label: 'Nama' }, { k: 'batasMuatanKg', label: 'Batas muatan kg', type: 'number' }, { k: 'aktif', label: 'Aktif', type: 'bool' }] },
  { key: 'dock', title: 'Jalur (Dock)', path: 'dock', whsFilter: true, createable: true, fields: [
    { k: 'dockCode', label: 'Kode', pk: true }, { k: 'whsCode', label: 'Gudang', type: 'whs' }, { k: 'nama', label: 'Nama' }, { k: 'aktif', label: 'Aktif', type: 'bool' }] },
  { key: 'timbangan', title: 'Timbangan', path: 'timbangan', whsFilter: true, createable: true, fields: [
    { k: 'kodeTimbangan', label: 'Kode', pk: true, hint: 'mis. TP-01' }, { k: 'whsCode', label: 'Gudang', type: 'whs' }, { k: 'alat', label: 'Jenis (KENDARAAN/PALET)' },
    { k: 'lokasi', label: 'Lokasi' }, { k: 'alamatLan', label: 'Alamat Gateway/ESP32' }, { k: 'gatewayId', label: 'Gateway' },
    { k: 'tolOverridePct', label: 'Toleransi % (opsional)', type: 'number' }, { k: 'aktif', label: 'Aktif', type: 'bool' }] },
  { key: 'printer', title: 'Printer', path: 'printer', whsFilter: true, createable: true, fields: [
    { k: 'kodePrinter', label: 'Kode', pk: true }, { k: 'whsCode', label: 'Gudang', type: 'whs' }, { k: 'gatewayId', label: 'Gateway' },
    { k: 'lokasi', label: 'Lokasi' }, { k: 'ukuranMm', label: 'Ukuran label' }, { k: 'aktif', label: 'Aktif', type: 'bool' }] },
];

const CAMEL_REQ = (r: Row) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k[0].toUpperCase() + k.slice(1), v]));

function MasterTable({ cfg }: { cfg: Cfg }) {
  const toast = useToast();
  const wh = useWarehouses();
  const [whs, setWhs] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>(`/api/cms/master/${cfg.path}`, cfg.whsFilter ? { whs } : undefined), [cfg.path, whs]);
  const [form, setForm] = useState<Row | null>(null);
  const [isNew, setIsNew] = useState(false);
  const pk = cfg.fields.find((f) => f.pk)!.k;

  async function save() {
    if (!form) return;
    try {
      const body = CAMEL_REQ(form);
      if (isNew) await post(`/api/cms/master/${cfg.path}`, body);
      else await put(`/api/cms/master/${cfg.path}/${encodeURIComponent(form[pk])}`, body);
      toast('Tersimpan');
      setForm(null);
      reload();
    } catch (e) { toast(errText(e), true); }
  }

  return (
    <div className="stack">
      <div className="row">
        {cfg.whsFilter && (
          <select className="input" value={whs} onChange={(e) => setWhs(e.target.value)} aria-label="Filter gudang">
            <option value="">Semua gudang</option>
            {(wh.data ?? []).map((w) => <option key={w.whsCode} value={w.whsCode}>{w.whsCode} · {w.whsName}</option>)}
          </select>
        )}
        <span className="grow" />
        {cfg.createable && <button className="btn small" onClick={() => { setIsNew(true); setForm({ aktif: true }); }}>+ Baru</button>}
      </div>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      <div className="tablewrap"><table className="table">
        <thead><tr>{cfg.fields.map((f) => <th key={f.k}>{f.label}</th>)}<th /></tr></thead>
        <tbody>
          {(data ?? []).map((r) => (
            <tr key={r[pk]}>
              {cfg.fields.map((f) => <td key={f.k} data-label={f.label}>{f.type === 'bool' ? (r[f.k] ? 'Ya' : 'Tidak') : String(r[f.k] ?? '-')}</td>)}
              <td><button className="btn small outline" onClick={() => { setIsNew(false); setForm({ ...r }); }}>Ubah</button></td>
            </tr>
          ))}
        </tbody>
      </table></div>
      {form && (
        <div className="card stack">
          <strong>{isNew ? 'Tambah' : 'Ubah'} {cfg.title}</strong>
          {cfg.fields.map((f) => (
            <label key={f.k} className="stack tight">
              <span className="small muted">{f.label}</span>
              {f.type === 'bool' ? (
                <input type="checkbox" checked={!!form[f.k]} onChange={(e) => setForm({ ...form, [f.k]: e.target.checked })} />
              ) : f.type === 'whs' ? (
                <>
                  <input className="input" list="dl-whs" value={form[f.k] ?? ''} onChange={(e) => setForm({ ...form, [f.k]: e.target.value.split(' ')[0] })} disabled={!isNew && f.k === 'whsCode'} />
                  <datalist id="dl-whs">{(wh.data ?? []).map((w) => <option key={w.whsCode} value={w.whsCode}>{w.whsName}</option>)}</datalist>
                </>
              ) : (
                <input className="input" type={f.type === 'number' ? 'number' : 'text'} placeholder={f.hint} value={form[f.k] ?? ''} disabled={f.pk && !isNew}
                  onChange={(e) => setForm({ ...form, [f.k]: f.type === 'number' ? (e.target.value === '' ? null : Number(e.target.value)) : e.target.value })} />
              )}
            </label>
          ))}
          <div className="row"><button className="btn small" onClick={save}>Simpan</button><button className="btn small ghost" onClick={() => setForm(null)}>Batal</button></div>
        </div>
      )}
    </div>
  );
}

function Gateways() {
  const toast = useToast();
  const { data, error, reload } = useLoad(() => get<Row[]>('/api/cms/master/gateway'), []);
  const wh = useWarehouses();
  const [id, setId] = useState('');
  const [whs, setWhs] = useState('');
  const [ket, setKet] = useState('');
  const [key, setKey] = useState<string | null>(null);
  async function buat() {
    try { const r = await post<Row>('/api/cms/master/gateway', { GatewayId: id, WhsCode: whs, Keterangan: ket }); setKey(`${r.gatewayId}: ${r.apiKey}`); setId(''); reload(); } catch (e) { toast(errText(e), true); }
  }
  async function baru(g: string) {
    if (!confirm(`Buat key baru untuk ${g}? Key lama langsung tidak berlaku.`)) return;
    try { const r = await post<Row>(`/api/cms/master/gateway/${g}/key-baru`); setKey(`${r.gatewayId}: ${r.apiKey}`); } catch (e) { toast(errText(e), true); }
  }
  return (
    <div className="stack">
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {key && <div className="card amber stack"><strong>Simpan key ini sekarang (tidak ditampilkan lagi)</strong><code className="mono">{key}</code></div>}
      <div className="tablewrap"><table className="table"><thead><tr><th>ID</th><th>Gudang</th><th>Keterangan</th><th>Status</th><th>Versi</th><th /></tr></thead><tbody>
        {(data ?? []).map((g) => (
          <tr key={g.gatewayId}><td data-label="ID" className="mono">{g.gatewayId}</td><td data-label="Gudang">{g.whsCode}</td><td data-label="Keterangan">{g.keterangan}</td>
            <td data-label="Status">{g.online ? <span className="pill green">Online</span> : <span className="pill grey">Offline</span>}</td><td data-label="Versi">{g.versi ?? '-'}</td>
            <td><button className="btn small outline" onClick={() => baru(g.gatewayId)}>Key baru</button></td></tr>
        ))}</tbody></table></div>
      <div className="card stack"><strong>Gateway baru</strong>
        <input className="input" placeholder="ID mis. GW-JKT01" value={id} onChange={(e) => setId(e.target.value)} />
        <input className="input" list="dl-whs2" placeholder="Gudang" value={whs} onChange={(e) => setWhs(e.target.value.split(' ')[0])} />
        <datalist id="dl-whs2">{(wh.data ?? []).map((w) => <option key={w.whsCode} value={w.whsCode}>{w.whsName}</option>)}</datalist>
        <input className="input" placeholder="Keterangan" value={ket} onChange={(e) => setKet(e.target.value)} />
        <button className="btn small" onClick={buat}>Buat</button></div>
    </div>
  );
}

export function AdminMaster() {
  const [tab, setTab] = useState('ruangan');
  const cfg = CFG.find((c) => c.key === tab);
  return (
    <Page eyebrow="Admin" title="Master Data" accent="ink" extra={
      <div className="chips" role="tablist">
        {[...CFG.map((c) => [c.key, c.title]), ['gateway', 'Gateway']].map(([k, t]) => <button key={k} className="chip" aria-pressed={tab === k} onClick={() => setTab(k)}>{t}</button>)}
      </div>}>
      {cfg ? <MasterTable key={cfg.key} cfg={cfg} /> : <Gateways />}
    </Page>
  );
}

export function AdminSetup() {
  const toast = useToast();
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/cms/setup'), []);
  const [edit, setEdit] = useState<Record<string, string>>({});
  async function simpan() {
    const items = Object.entries(edit).map(([Kode, v]) => ({ Kode, Nilai: Number(v) }));
    if (!items.length) return;
    try { await put('/api/cms/setup', { Items: items }); toast('Setup tersimpan'); setEdit({}); reload(); } catch (e) { toast(errText(e), true); }
  }
  return (
    <Page eyebrow="Admin" title="Setup" accent="ink" footer={<button className="btn" disabled={!Object.keys(edit).length} onClick={simpan}>Simpan perubahan</button>}>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      <div className="stack">
        {(data ?? []).map((s) => (
          <label key={s.kode} className="card pad-s stack tight">
            <span className="mono small">{s.kode}</span><span className="small muted">{s.keterangan}</span>
            <input className="input" type="number" step="any" value={edit[s.kode] ?? String(s.nilai)} onChange={(e) => setEdit({ ...edit, [s.kode]: e.target.value })} />
          </label>
        ))}
      </div>
    </Page>
  );
}
