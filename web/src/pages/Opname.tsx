import { useMemo, useState } from 'react';
import { ApiError, api, get, post, put, type Row } from '../api';
import { Link, navigate } from '../router';
import { ErrorBox, Icon, Page, SearchSelect, Spinner, errText, fmt, fmtDate, todayIso, useLoad, useToast, useWarehouses, whsOpts } from '../ui';
import { QrSvg } from './Labels';

// ============================================================ Stock opname (Admin)
// Alur: buat (pilih ruangan, bagi rak ke 2 krani) -> freeze -> krani hitung buta per rak -> validasi -> posting dokumen OP.

const ST: Record<string, string> = { Hitung: 'amber', Validasi: 'out', Posted: 'green', Batal: 'grey' };
const statusOf = (r: Row) => (r.status === 'Hitung' && r.jumlahRak > 0 && r.rakSelesai === r.jumlahRak ? 'Validasi' : r.status);
const errMsg = (e: unknown) => (e instanceof ApiError && e.errors?.length ? `${e.message}: ${e.errors.join('; ')}` : errText(e));

export function OpnameList() {
  const wh = useWarehouses();
  const [whs, setWhs] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/cms/opname', { whs }), [whs]);
  const [baru, setBaru] = useState(false);
  return (
    <Page eyebrow="Admin" title="Stock Opname" accent="ink"
      actions={<button className="btn small" onClick={() => setBaru(!baru)}>{baru ? 'Tutup form' : '+ Opname baru'}</button>}>
      <p className="hint">Admin memilih ruangan, membagi rak ke krani, lalu freeze saldo. Setiap rak dihitung dua krani berbeda tanpa melihat saldo; hasilnya divalidasi Admin sebelum diposting.</p>
      {baru && <OpnameBaru onDone={(id) => navigate(`/admin/opname/${id}`)} />}
      <div className="formrow">
        <div><SearchSelect options={whsOpts(wh.data)} value={whs} onChange={setWhs} allowEmpty="Semua gudang" placeholder="Filter gudang" /></div>
        <span className="spacer" />
        <Link to="/admin/master?tab=rak" className="btn small outline">Master rak & barcode</Link>
      </div>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      <div className="tablewrap"><table className="table cards">
        <thead><tr><th>No. opname</th><th>Gudang</th><th>Tgl opname</th><th>Ruangan</th><th>Rak selesai</th><th>Krani</th><th>Status</th></tr></thead>
        <tbody>
          {(data ?? []).map((r) => {
            const st = statusOf(r);
            return (
              <tr key={r.opnameId} className="click" onClick={() => navigate(`/admin/opname/${r.opnameId}`)}>
                <td data-label="No." className="mono"><strong>{r.opnameNo}</strong></td>
                <td data-label="Gudang">{r.whsCode}</td>
                <td data-label="Tgl">{fmtDate(r.tglOpname)}</td>
                <td data-label="Ruangan">{r.ruangan}</td>
                <td data-label="Rak">{r.rakSelesai} / {r.jumlahRak}</td>
                <td data-label="Krani" className="small">{r.krani}</td>
                <td data-label="Status"><span className={`pill ${ST[st] ?? ''}`}>{st}</span>{r.postDocEntry && <div className="small mono">OP {r.postObjType}/{r.postDocEntry}</div>}</td>
              </tr>
            );
          })}
          {data && data.length === 0 && <tr><td colSpan={7} className="empty">Belum ada opname</td></tr>}
        </tbody>
      </table></div>
    </Page>
  );
}

type Asg = { kodeRuangan: string; kodeRak: string; krani1: number; krani2: number };

function OpnameBaru({ onDone }: { onDone: (id: number) => void }) {
  const toast = useToast();
  const wh = useWarehouses();
  const [whs, setWhs] = useState('');
  const [tgl, setTgl] = useState(todayIso());
  const [on, setOn] = useState<Record<string, boolean>>({});
  const [asg, setAsg] = useState<Record<string, [number, number]>>({});
  const [cat, setCat] = useState('');
  const [busy, setBusy] = useState(false);
  const form = useLoad(() => (whs ? get<Row>('/api/cms/opname/form', { whs }) : Promise.resolve(null)), [whs]);
  const rooms: Row[] = (form.data?.rooms as Row[]) ?? [];
  const kranis: Row[] = (form.data?.kranis as Row[]) ?? [];
  const kOpts = kranis.map((k) => ({ value: String(k.userId), label: `${k.userCode} · ${k.name ?? ''}` }));

  // Rak per ruangan dari master; ruangan tanpa rak = satu rak "ALL" (seluruh ruangan)
  const raks = useMemo(() => {
    const list: { room: string; rak: string; nama?: string }[] = [];
    for (const r of rooms.filter((x) => on[x.kodeRuangan])) {
      const m = ((form.data?.raks as Row[]) ?? []).filter((k) => k.kodeRuangan === r.kodeRuangan);
      if (m.length === 0) list.push({ room: r.kodeRuangan, rak: 'ALL', nama: 'Seluruh ruangan' });
      else m.forEach((k) => list.push({ room: r.kodeRuangan, rak: k.kodeRak, nama: k.namaRak }));
    }
    return list;
  }, [rooms, on, form.data]);

  const key = (x: { room: string; rak: string }) => `${x.room}|${x.rak}`;
  const pairOf = (x: { room: string; rak: string }, i: number): [number, number] => {
    const a = asg[key(x)];
    if (a) return a;
    const n = kranis.length;
    return n >= 2 ? [kranis[i % n].userId, kranis[(i + 1) % n].userId] : [0, 0];
  };
  const list: Asg[] = raks.map((x, i) => { const p = pairOf(x, i); return { kodeRuangan: x.room, kodeRak: x.rak, krani1: p[0], krani2: p[1] }; });
  const same = list.some((a) => a.krani1 === a.krani2);
  const kosong = list.some((a) => !a.krani1 || !a.krani2);
  const err = !whs ? 'Pilih gudang' : list.length === 0 ? 'Pilih minimal satu ruangan' : kranis.length < 2 ? 'Gudang ini butuh minimal 2 krani' : same ? 'Di setiap rak, krani hitung ke-1 dan ke-2 harus orang yang berbeda' : kosong ? 'Pilih krani untuk setiap rak' : null;

  async function simpan() {
    setBusy(true);
    try {
      const r = await post<Row>('/api/cms/opname', { WhsCode: whs, TglOpname: tgl, Raks: list, Catatan: cat || null });
      toast(`${r.opnameNo} dibuat dan saldo dibekukan`);
      onDone(r.opnameId);
    } catch (e) { toast(errMsg(e), true); } finally { setBusy(false); }
  }

  return (
    <div className="card stack">
      <strong>Buat opname baru</strong>
      <div className="formrow">
        <label className="stack tight"><span className="small muted">Warehouse *</span>
          <SearchSelect options={whsOpts(wh.data)} value={whs} onChange={(v) => { setWhs(v); setOn({}); setAsg({}); }} placeholder="Cari & pilih gudang" /></label>
        <label className="stack tight"><span className="small muted">Tanggal opname *</span>
          <input className="input" type="date" value={tgl} onChange={(e) => setTgl(e.target.value)} /></label>
      </div>
      {form.error !== null && <ErrorBox error={form.error} onRetry={form.reload} />}
      {whs && form.loading && !form.data && <Spinner />}
      {rooms.length > 0 && (
        <div className="stack tight">
          <span className="small muted">Ruangan yang di-opname * · {rooms.filter((r) => on[r.kodeRuangan]).length} dipilih</span>
          <div className="tablewrap"><table className="table cards">
            <thead><tr><th /><th>Ruangan</th><th className="num">Stok kg</th><th className="num">Item</th><th>Catatan</th></tr></thead>
            <tbody>{rooms.map((r) => (
              <tr key={r.kodeRuangan}>
                <td><input type="checkbox" aria-label={`Pilih ${r.kodeRuangan}`} disabled={!!r.opnameAktif} checked={!!on[r.kodeRuangan]} onChange={(e) => setOn({ ...on, [r.kodeRuangan]: e.target.checked })} /></td>
                <td data-label="Ruangan"><span className="mono">{r.kodeRuangan}</span> · {r.namaRuangan} {r.titipan && <span className="pill amber">ruangan titipan</span>}</td>
                <td data-label="Stok kg" className="num">{fmt(r.stokKg)}</td>
                <td data-label="Item" className="num">{r.jumlahItem}</td>
                <td data-label="Catatan" className="small">{r.opnameAktif ? `Sedang opname ${r.opnameAktif}` : ''}</td>
              </tr>))}</tbody>
          </table></div>
        </div>
      )}
      {raks.length > 0 && (
        <div className="stack tight">
          <span className="small muted">Pembagian per rak · {raks.length} rak. Rak diatur di Master Data · Rak; banyak krani bisa menghitung satu ruangan bersamaan.</span>
          <div className="tablewrap"><table className="table cards">
            <thead><tr><th>Ruangan</th><th>Rak</th><th>Hitung ke-1</th><th>Hitung ke-2</th></tr></thead>
            <tbody>{raks.map((x, i) => {
              const p = pairOf(x, i);
              const set = (ix: 0 | 1) => (v: string) => { const b: [number, number] = [p[0], p[1]]; b[ix] = Number(v); setAsg({ ...asg, [key(x)]: b }); };
              return (
                <tr key={key(x)}>
                  <td data-label="Ruangan" className="mono">{x.room}</td>
                  <td data-label="Rak"><span className="mono">{x.rak}</span> {x.nama && <span className="small muted">{x.nama}</span>}</td>
                  <td data-label="Hitung ke-1"><SearchSelect options={kOpts} value={String(p[0] || '')} onChange={set(0)} placeholder="Cari krani" /></td>
                  <td data-label="Hitung ke-2"><SearchSelect options={kOpts} value={String(p[1] || '')} onChange={set(1)} placeholder="Cari krani" />
                    {p[0] === p[1] && p[0] !== 0 && <div className="small" style={{ color: 'var(--red)' }}>Harus beda dengan hitung ke-1</div>}</td>
                </tr>
              );
            })}</tbody>
          </table></div>
        </div>
      )}
      <label className="stack tight"><span className="small muted">Catatan</span><input className="input" maxLength={250} value={cat} onChange={(e) => setCat(e.target.value)} /></label>
      <div className="card amber stack tight">
        <strong>Transaksi ditahan mulai tanggal opname</strong>
        <span className="small">Di ruangan terpilih, transaksi bertanggal {fmtDate(tgl)} atau sesudahnya tidak bisa dibuat atau diposting sampai opname diposting atau dibatalkan. Dokumen bertanggal sebelumnya tetap bisa diposting; setelah itu lakukan freeze ulang.</span>
      </div>
      <p className="hint">Hitung buta: krani tidak melihat saldo sistem, dan hitungan ke-1 dan ke-2 tidak saling terlihat.</p>
      <div className="row">
        <span className="small" style={{ color: err ? 'var(--red)' : 'var(--green-text)' }}>{err ?? `✓ ${new Set(list.map((a) => a.kodeRuangan)).size} ruangan · ${list.length} rak`}</span>
        <span className="spacer" />
        <button className="btn small" disabled={!!err || busy} onClick={simpan}>Simpan & freeze saldo</button>
      </div>
    </div>
  );
}

type V = { kg: number; sak: number; palet: number } | null;
const vk = (v: V) => (v ? `${fmt(v.kg)} kg` : '—');
const vs = (v: V) => (v ? `${fmt(v.sak)} sak · ${fmt(v.palet)} plt` : 'tidak ada');
const sg = (n: number) => (n > 0 ? '+' : n < 0 ? '−' : '') + fmt(Math.abs(n));
const catOf = (r: Row) => (r.status === 'Cocok' ? 'Cocok' : r.status === 'Beda antar krani' ? 'Perlu keputusan' : 'Selisih');
const PILL: Record<string, string> = { Cocok: 'green', 'Beda antar krani': 'red', 'Tidak ada di saldo': 'amber', 'Tidak ditemukan': 'red', 'Selisih saldo': 'amber' };

export function OpnameDetail({ id }: { id: string }) {
  const toast = useToast();
  const { data, error, loading, reload } = useLoad(() => get<Row>(`/api/cms/opname/${encodeURIComponent(id)}`), [id]);
  const [filter, setFilter] = useState('Semua');
  const [busy, setBusy] = useState(false);
  const h = data?.header as Row | undefined;
  const raks: Row[] = (data?.raks as Row[]) ?? [];
  const rows: Row[] = (data?.rows as Row[]) ?? [];
  const aktif = h?.status === 'Hitung';

  async function act(fn: () => Promise<unknown>, ok: string) {
    setBusy(true);
    try { await fn(); toast(ok); reload(); } catch (e) { toast(errMsg(e), true); } finally { setBusy(false); }
  }
  const setFinal = (r: Row, v: string) => {
    if (v === 'ulang') {
      if (!confirm('Hapus hitungan ke-1 dan ke-2 di rak tempat barang ini dihitung, lalu minta krani menghitung ulang?')) return;
      return act(() => post(`/api/cms/opname/${id}/ulang`, { Kunci: r.kunci }), 'Rak dibuka untuk hitung ulang');
    }
    return act(() => put(`/api/cms/opname/${id}/final`, { Kunci: r.kunci, Pilihan: v || null }), 'Keputusan disimpan');
  };

  if (error !== null) return <Page title="Stock Opname" backTo="/admin/opname" accent="ink"><ErrorBox error={error} onRetry={reload} /></Page>;
  if (!h) return <Page title="Stock Opname" backTo="/admin/opname" accent="ink">{loading && <Spinner />}</Page>;

  const selesaiRak = raks.filter((k) => k.selesai1 && k.selesai2).length;
  const open = rows.filter((r) => !r.final).length;
  const diff = (r: Row) => (r.final ? Number(r.final.kg) - Number(r.saldo.kg) : 0);
  const plus = rows.reduce((a, r) => a + Math.max(0, diff(r)), 0);
  const minus = rows.reduce((a, r) => a + Math.min(0, diff(r)), 0);
  const shown = rows.filter((r) => filter === 'Semua' || catOf(r) === filter);
  const st = h.status === 'Hitung' && selesaiRak === raks.length && raks.length > 0 ? 'Validasi' : h.status;
  const blokir = selesaiRak < raks.length ? `${raks.length - selesaiRak} rak belum selesai dihitung` : data?.stale ? 'Freeze ulang dulu: saldo berubah setelah freeze' : open > 0 ? `${open} baris beda antar krani belum diputuskan` : null;

  return (
    <Page eyebrow={`Stock opname · ${h.whsCode}`} title={h.opnameNo} backTo="/admin/opname" accent="ink"
      actions={<span className={`pill ${ST[st] ?? ''}`}>{st}</span>}
      footer={aktif ? (
        <div className="row">
          <button className="btn small ghost" disabled={busy} onClick={() => confirm('Batalkan opname ini? Transaksi yang ditahan akan bisa diposting lagi.') && act(() => post(`/api/cms/opname/${id}/batal`), 'Opname dibatalkan')}>Batalkan</button>
          <button className="btn" disabled={busy || !!blokir} onClick={() => confirm(`Posting opname? Selisih +${fmt(plus)} / −${fmt(Math.abs(minus))} kg dibukukan sebagai dokumen OP bertanggal ${fmtDate(h.tglOpname)}.`) && act(() => post(`/api/cms/opname/${id}/post`), 'Opname diposting')}>Posting opname</button>
        </div>
      ) : undefined}
      footerNote={aktif ? (blokir ?? `Siap posting: selisih +${fmt(plus)} / −${fmt(Math.abs(minus))} kg`) : undefined}>
      <div className="small muted">Tgl opname {fmtDate(h.tglOpname)} · transaksi bertanggal ≥ {fmtDate(h.tglOpname)} di ruangan ini ditahan · dibuat {h.createdByCode} {h.catatan ? `· ${h.catatan}` : ''}</div>
      {h.status === 'Posted' && <div className="card green">Diposting {fmtDate(h.postedAt)}{h.postDocEntry ? ` · dokumen OP ${h.postObjType}/${h.postDocEntry}` : ' · tanpa selisih'}</div>}

      {aktif && data?.stale > 0 && (
        <div className="card amber stack tight">
          <strong>Saldo berubah setelah freeze</strong>
          <span className="small">{data?.stale} baris saldo berbeda dengan snapshot (ada dokumen bertanggal sebelum {fmtDate(h.tglOpname)} yang diposting sesudah freeze). Freeze ulang supaya selisih dihitung dari saldo terbaru.</span>
          <div><button className="btn small" disabled={busy} onClick={() => act(() => post(`/api/cms/opname/${id}/freeze`), 'Freeze ulang selesai')}>Freeze ulang sekarang</button></div>
        </div>
      )}
      <div className="card stack tight">
        <div className="row"><strong>Saldo dibekukan (freeze ke-{h.freezeKe})</strong><span className="spacer" />
          {aktif && !data?.stale && <button className="btn small outline" disabled={busy} onClick={() => act(() => post(`/api/cms/opname/${id}/freeze`), 'Freeze ulang selesai')}>Freeze ulang</button>}</div>
        <span className="small muted">{h.freezeAt ? new Date(h.freezeAt).toLocaleString('id-ID') : ''} oleh {h.freezeByCode} · saldo dari dokumen terposting bertanggal sebelum {fmtDate(h.tglOpname)}, per ruangan, item, container, lot QR, BL, titipan dan PT. Freeze ulang hanya sebelum posting; hasil hitung krani tetap disimpan.</span>
      </div>

      <div className="card stack tight">
        <div className="row"><strong>Rak · {selesaiRak} dari {raks.length} selesai</strong><span className="spacer" />
          <Link to={`/admin/opname/${id}/barcode`} className="btn small outline"><Icon name="print" size={16} /> Cetak barcode rak</Link></div>
        <div className="tablewrap"><table className="table cards">
          <thead><tr><th>Ruangan · rak</th><th>Hitung ke-1</th><th>Hitung ke-2</th>{aktif && <th />}</tr></thead>
          <tbody>{raks.map((k) => (
            <tr key={`${k.kodeRuangan}|${k.kodeRak}`}>
              <td data-label="Rak"><span className="mono">{k.kodeRuangan} · {k.kodeRak}</span> {k.namaRak && <span className="small muted">{k.namaRak}</span>}</td>
              {[1, 2].map((n) => (
                <td key={n} data-label={`Hitung ke-${n}`}>{k[`krani${n}Code`]} <span className={`pill ${k[`selesai${n}`] ? 'green' : k[`baris${n}`] > 0 ? 'amber' : 'grey'}`}>{k[`selesai${n}`] ? 'Dikirim' : k[`baris${n}`] > 0 ? 'Sedang dihitung' : 'Belum'}</span> <span className="small muted">{k[`baris${n}`]} baris</span></td>
              ))}
              {aktif && <td><button className="btn small ghost" disabled={busy} onClick={() => confirm(`Hapus hitungan rak ${k.kodeRak} (ke-1 & ke-2) dan minta hitung ulang?`) && act(() => post(`/api/cms/opname/${id}/ulang`, { KodeRuangan: k.kodeRuangan, KodeRak: k.kodeRak, Ke: 0 }), 'Rak dibuka untuk hitung ulang')}>Hitung ulang</button></td>}
            </tr>))}</tbody>
        </table></div>
      </div>

      <div className="chips" role="tablist">
        {['Semua', 'Perlu keputusan', 'Selisih', 'Cocok'].map((n) => (
          <button key={n} className="chip" aria-pressed={filter === n} onClick={() => setFilter(n)}>{n} · {n === 'Semua' ? rows.length : rows.filter((r) => catOf(r) === n).length}</button>
        ))}
      </div>
      <p className="hint">Hitungan semua rak dijumlah per ruangan, item, container, lot, BL, titipan dan PT. Beda antar krani wajib diputuskan atau dihitung ulang.</p>
      <div className="tablewrap"><table className="table cards">
        <thead><tr><th>Ruangan · rak</th><th>Item · container</th><th>Lot · BL · PT</th><th className="num">Saldo freeze</th><th className="num">Hitung 1</th><th className="num">Hitung 2</th><th className="num">Final vs saldo</th><th>Final</th><th>Status</th></tr></thead>
        <tbody>{shown.map((r) => {
          const k = r.key as Row;
          const d = r.final ? diff(r) : null;
          const val = r.pilihan ?? r.pilihanDefault ?? '';
          return (
            <tr key={r.kunci}>
              <td data-label="Ruangan"><span className="mono">{k.kodeRuangan}</span><div className="small muted">{(r.rak as string[]).join(', ') || '—'}</div></td>
              <td data-label="Item"><span className="mono"><strong>{k.itemCode}</strong></span> {r.itemName}<div className="small mono">{k.containerNo || '—'}</div></td>
              <td data-label="Lot · BL · PT" className="small"><span className="mono">{k.noLot ? `L${k.noLot}` : 'label lama · tanpa lot'}</span><div>{k.titipan ? 'TITIPAN' : `BL ${k.noBL || '—'}`} · PT {r.ptName ?? (k.ptCode || '—')}</div></td>
              <td data-label="Saldo" className="num">{r.adaSaldo ? vk(r.saldo) : '—'}<div className="small muted">{r.adaSaldo ? vs(r.saldo) : 'tidak ada'}</div></td>
              <td data-label="Hitung 1" className="num">{vk(r.h1)}<div className="small muted">{vs(r.h1)}</div></td>
              <td data-label="Hitung 2" className="num">{vk(r.h2)}<div className="small muted">{vs(r.h2)}</div></td>
              <td data-label="Final vs saldo" className="num mono" style={{ color: d === null ? undefined : d === 0 ? 'var(--green-text)' : 'var(--out)' }}>{d === null ? '—' : `${sg(d)} kg`}</td>
              <td data-label="Final">
                {aktif ? (
                  <select className="input" value={val} disabled={busy} onChange={(e) => setFinal(r, e.target.value)}>
                    <option value="">Pilih…</option><option value="h1">Hitung 1</option><option value="h2">Hitung 2</option>
                    {r.adaSaldo && <option value="saldo">Pakai saldo</option>}<option value="ulang">Minta hitung ulang</option>
                  </select>
                ) : (val === 'h1' ? 'Hitung 1' : val === 'h2' ? 'Hitung 2' : val === 'saldo' ? 'Saldo' : '—')}
              </td>
              <td data-label="Status"><span className={`pill ${PILL[r.status] ?? ''}`}>{r.status}</span>{r.dobel && <div className="small" style={{ color: 'var(--amber-text)' }}>! {r.dobel}</div>}</td>
            </tr>
          );
        })}
        {shown.length === 0 && <tr><td colSpan={9} className="empty">Tidak ada baris</td></tr>}</tbody>
      </table></div>
    </Page>
  );
}

// ============================================================ Barcode rak (QR berisi RAK-<ruangan>-<rak>)
function RakSheet({ title, backTo, raks }: { title: string; backTo: string; raks: Row[] }) {
  return (
    <Page eyebrow="Barcode rak" title={title} accent="ink" backTo={backTo} narrow
      footerNote="Ukuran kertas 100 × 70 mm, margin 0. Tempel di setiap rak; krani scan barcode ini sebelum menghitung palet di rak itu."
      footer={raks.length > 0 ? <button className="btn" onClick={() => window.print()}><Icon name="print" /> Cetak {raks.length} barcode</button> : undefined}>
      <div className="noprint stack">{raks.map((k) => <RakLabel key={k.barcode} k={k} />)}</div>
      <div className="printonly" aria-hidden="true">{raks.map((k) => <RakLabel key={k.barcode} k={k} />)}</div>
    </Page>
  );
}

function RakLabel({ k }: { k: Row }) {
  return (
    <div className="plabel">
      <div className="l">
        <div className="small">RUANGAN {k.kodeRuangan}</div>
        <div className="cont">RAK {k.kodeRak}</div>
        <div>{k.namaRak ?? ''}</div>
        <div className="qrtext">{k.barcode}</div>
      </div>
      <div className="r"><QrSvg text={k.barcode} /></div>
    </div>
  );
}

export function OpnameRakLabels({ id }: { id: string }) {
  const { data, error, reload } = useLoad(() => get<Row>(`/api/cms/opname/${encodeURIComponent(id)}`), [id]);
  if (error !== null) return <Page title="Barcode rak" backTo={`/admin/opname/${id}`}><ErrorBox error={error} onRetry={reload} /></Page>;
  if (!data) return <Page title="Barcode rak" backTo={`/admin/opname/${id}`}><Spinner /></Page>;
  return <RakSheet title={String((data.header as Row).opnameNo)} backTo={`/admin/opname/${id}`} raks={data.raks as Row[]} />;
}

// ============================================================ Master rak (tab di Master Data)
export function RakMaster() {
  const toast = useToast();
  const wh = useWarehouses();
  const [whs, setWhs] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/cms/master/rak', { whs }), [whs]);
  const rooms = useLoad(() => get<Row[]>('/api/cms/master/ruangan', { whs }), [whs]);
  const [ru, setRu] = useState('');
  const [kode, setKode] = useState('');
  const [nama, setNama] = useState('');
  const [cetak, setCetak] = useState(false);

  async function tambah() {
    try { await post('/api/cms/master/rak', { KodeRuangan: ru, KodeRak: kode, NamaRak: nama || null }); toast('Rak ditambah'); setKode(''); setNama(''); reload(); }
    catch (e) { toast(errText(e), true); }
  }
  async function ubah(r: Row, aktif: boolean) {
    try { await put(`/api/cms/master/rak/${encodeURIComponent(r.kodeRuangan)}/${encodeURIComponent(r.kodeRak)}`, { KodeRuangan: r.kodeRuangan, KodeRak: r.kodeRak, NamaRak: r.namaRak, Aktif: aktif }); reload(); }
    catch (e) { toast(errText(e), true); }
  }
  async function hapus(r: Row) {
    if (!confirm(`Hapus rak ${r.kodeRak}?`)) return;
    try { await api(`/api/cms/master/rak/${encodeURIComponent(r.kodeRuangan)}/${encodeURIComponent(r.kodeRak)}`, { method: 'DELETE' }); reload(); }
    catch (e) { toast(errText(e), true); }
  }
  if (cetak) return (
    <div className="stack">
      <button className="btn small ghost noprint" onClick={() => setCetak(false)}>← Kembali ke daftar rak</button>
      <RakSheet title={whs ? `Rak ${whs}` : 'Semua rak'} backTo="/admin/master" raks={(data ?? []).filter((r) => r.aktif)} />
    </div>
  );
  return (
    <div className="stack">
      <div className="formrow">
        <div><SearchSelect options={whsOpts(wh.data)} value={whs} onChange={setWhs} allowEmpty="Semua gudang" placeholder="Filter gudang" /></div>
        <span className="spacer" />
        <button className="btn small outline" disabled={!data?.length} onClick={() => setCetak(true)}><Icon name="print" size={16} /> Cetak barcode rak</button>
      </div>
      <p className="hint">Rak hanya untuk membagi pekerjaan stock opname; saldo tetap per ruangan. Ruangan tanpa rak dihitung sebagai satu rak (ALL).</p>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      <div className="tablewrap"><table className="table cards">
        <thead><tr><th>Ruangan</th><th>Rak</th><th>Nama</th><th>Barcode</th><th>Aktif</th><th /></tr></thead>
        <tbody>{(data ?? []).map((r) => (
          <tr key={r.barcode}>
            <td data-label="Ruangan"><span className="mono">{r.kodeRuangan}</span> <span className="small muted">{r.namaRuangan}</span></td>
            <td data-label="Rak" className="mono">{r.kodeRak}</td>
            <td data-label="Nama">{r.namaRak ?? '-'}</td>
            <td data-label="Barcode" className="mono small">{r.barcode}</td>
            <td data-label="Aktif"><input type="checkbox" checked={!!r.aktif} aria-label="Aktif" onChange={(e) => ubah(r, e.target.checked)} /></td>
            <td>{r.dipakai === 0 && <button className="btn small ghost" onClick={() => hapus(r)}>Hapus</button>}</td>
          </tr>))}</tbody>
      </table></div>
      <div className="card stack"><strong>Rak baru</strong>
        <SearchSelect options={(rooms.data ?? []).filter((r) => r.aktif).map((r) => ({ value: r.kodeRuangan, label: `${r.kodeRuangan} · ${r.namaRuangan} (${r.whsCode})` }))} value={ru} onChange={setRu} placeholder="Cari & pilih ruangan" />
        <input className="input" placeholder="Kode rak, mis. A01-01" value={kode} onChange={(e) => setKode(e.target.value.toUpperCase())} />
        <input className="input" placeholder="Nama / keterangan (opsional)" value={nama} onChange={(e) => setNama(e.target.value)} />
        <button className="btn small" disabled={!ru || !kode} onClick={tambah}>Tambah</button>
      </div>
    </div>
  );
}
