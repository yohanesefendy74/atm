import { useState } from 'react';
import { get, post, put, type Row } from '../api';
import { Link, match, navigate } from '../router';
import { ErrorBox, KV, Page, Spinner, StatusPill, errText, fmt, fmtDate, useLoad, useToast, useWarehouses } from '../ui';

export function PlanList() {
  const [jenis, setJenis] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/cms/plan', { jenis }), [jenis]);
  return (
    <Page eyebrow="Admin" title="Rencana SPBB / SPMB" accent="ink" actions={<Link to="/admin/plan/baru" className="btn small auto">+ Baru</Link>}
      extra={<div className="chips">{['', 'SPBB', 'SPMB'].map((j) => <button key={j} className="chip" aria-pressed={jenis === j} onClick={() => setJenis(j)}>{j || 'Semua'}</button>)}</div>}>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      <div className="cardgrid">
        {(data ?? []).map((p) => (
          <Link key={p.planId} to={`/admin/plan/${p.planId}`} className="card click stack tight">
            <div className="row"><strong className="mono grow">{p.planNo}</strong><StatusPill status={p.status} />{p.titipan && <span className="pill amber">Titipan</span>}</div>
            <div className="small">{p.cardName ?? '-'} · {p.whsCode} · {p.kodeRuangan ?? '-'}</div>
            <div className="small muted">Dok: {p.dokumen} · Jadwal {fmtDate(p.tglJadwal)} {p.etaDatang ?? ''}</div>
            <div className="small">Realisasi {fmt(p.qtyDone)} / {fmt(p.qtyPlan)} kg</div>
          </Link>
        ))}
      </div>
      {!loading && (data ?? []).length === 0 && <div className="empty">Belum ada dokumen</div>}
    </Page>
  );
}

type Src = Row; type SrcLine = Row & { pick?: boolean; qtyPlan?: number; kontainer?: string; palet?: string; paletPlan?: number };

export function PlanNew() {
  const toast = useToast();
  const wh = useWarehouses();
  const [jenis, setJenis] = useState<'SPBB' | 'SPMB'>('SPBB');
  const [src, setSrc] = useState('BL');
  const [whs, setWhs] = useState('');
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Src[]>([]);
  const [docs, setDocs] = useState<{ head: Src; lines: SrcLine[] }[]>([]);
  const [ruang, setRuang] = useState('');
  const [ruangList, setRuangList] = useState<Row[]>([]);
  const [paletList, setPaletList] = useState<Row[]>([]);
  const [kraniList, setKraniList] = useState<Row[]>([]);
  const [kranis, setKranis] = useState<number[]>([]);
  const [pt, setPt] = useState('');
  const [titipanCard, setTitipanCard] = useState('');
  const [eta, setEta] = useState('');
  const [tgl, setTgl] = useState('');
  const [busy, setBusy] = useState(false);

  const srcOpts = jenis === 'SPBB' ? ['BL', 'DO'] : ['SO'];
  async function cari() {
    try { setFound(await get<Row[]>('/api/cms/plan/sumber', { src, q })); } catch (e) { toast(errText(e), true); }
  }
  async function pilihWhs(w: string) {
    setWhs(w);
    if (!w) return;
    try {
      setRuangList(await get<Row[]>('/api/cms/master/ruangan', { whs: w }));
      setKraniList(await get<Row[]>('/api/cms/plan/krani', { whs: w }));
      setPaletList(await get<Row[]>('/api/cms/master/palet'));
    } catch (e) { toast(errText(e), true); }
  }
  async function tambah(d: Src) {
    if (docs.some((x) => x.head.docEntry === d.docEntry)) return;
    if (jenis === 'SPMB' && docs.length > 0 && docs[0].head.cardCode !== d.cardCode) return toast('SPMB hanya untuk satu customer', true);
    try {
      const r = await get<{ header: Src; lines: SrcLine[] }>(`/api/cms/plan/sumber/${src}/${d.docEntry}`);
      setDocs([...docs, { head: r.header, lines: r.lines.map((l) => ({ ...l, pick: true, qtyPlan: Math.max(0, Number(l.tersedia)), kontainer: l.containerNo ?? '' })) }]);
    } catch (e) { toast(errText(e), true); }
  }
  const upd = (di: number, li: number, patch: Partial<SrcLine>) => setDocs(docs.map((d, i) => (i !== di ? d : { ...d, lines: d.lines.map((l, j) => (j !== li ? l : { ...l, ...patch })) })));
  const room = ruangList.find((r) => r.kodeRuangan === ruang);

  async function terbit() {
    const lines = docs.flatMap((d) => d.lines.filter((l) => l.pick && (l.qtyPlan ?? 0) > 0).map((l) => ({
      BaseDocEntry: d.head.docEntry, BaseLineNum: l.lineNum, QtyPlan: l.qtyPlan, ContainerNo: l.kontainer || null, KodeRuangan: ruang,
      PaletCode: l.palet || null, PaletPlan: l.paletPlan ?? null, FreeTxt: l.freeTxt ?? null })));
    if (!lines.length) return toast('Pilih minimal satu baris dengan qty', true);
    setBusy(true);
    try {
      const r = await post<Row>('/api/cms/plan', { Jenis: jenis, WhsCode: whs, Src: src, Docs: docs.map((d) => d.head.docEntry), KodeRuangan: ruang,
        CardCodeTitipan: room?.titipan ? titipanCard || null : null, PtCode: pt || null, EtaDatang: eta || null, TglJadwal: tgl || null, Kranis: kranis, Lines: lines });
      toast(`Terbit ${r.planNo}`);
      navigate(`/admin/plan/${r.planId}`);
    } catch (e) { toast(errText(e), true); } finally { setBusy(false); }
  }

  return (
    <Page eyebrow="Admin" title="Terbitkan SPBB / SPMB" accent="ink" backTo="/admin/plan" footer={<button className="btn" disabled={busy || !docs.length || !ruang} onClick={terbit}>Terbitkan</button>}>
      <div className="card stack">
        <div className="chips">{(['SPBB', 'SPMB'] as const).map((j) => <button key={j} className="chip" aria-pressed={jenis === j} onClick={() => { setJenis(j); setSrc(j === 'SPBB' ? 'BL' : 'SO'); setDocs([]); setFound([]); }}>{j}</button>)}</div>
        <select className="input" value={whs} onChange={(e) => pilihWhs(e.target.value)} aria-label="Gudang">
          <option value="">Pilih gudang</option>{(wh.data ?? []).map((w) => <option key={w.whsCode} value={w.whsCode}>{w.whsCode} · {w.whsName}</option>)}
        </select>
        <div className="row">
          {srcOpts.length > 1 && <select className="input" value={src} onChange={(e) => setSrc(e.target.value)}>{srcOpts.map((s) => <option key={s}>{s}</option>)}</select>}
          <input className="input grow" placeholder={`Cari ${src}: no / BP / PO`} value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && cari()} />
          <button className="btn small" onClick={cari}>Cari</button>
        </div>
        {found.map((d) => (
          <button key={d.docEntry} className="card pad-s click" onClick={() => tambah(d)}><span className="mono">{d.docNum}</span> · {d.cardName} · {fmtDate(d.docDate)} {d.numAtCard ? `· PO ${d.numAtCard}` : ''}</button>
        ))}
      </div>
      {docs.map((d, di) => (
        <div key={d.head.docEntry} className="card stack">
          <div className="row"><strong className="grow">{src} {d.head.docNum} · {d.head.cardName}</strong><button className="btn small ghost" onClick={() => setDocs(docs.filter((_, i) => i !== di))}>Hapus</button></div>
          {d.lines.map((l, li) => (
            <div key={l.lineNum} className="card pad-s stack tight">
              <label className="row"><input type="checkbox" checked={!!l.pick} onChange={(e) => upd(di, li, { pick: e.target.checked })} /> <span className="grow">{l.itemCode} · {l.dscription}</span></label>
              <div className="small muted">Open {fmt(l.openQty)} · teralokasi {fmt(l.teralokasi)} · tersedia {fmt(l.tersedia)} kg {l.brandName ? `· ${l.brandName}` : ''}</div>
              <div className="row">
                <input className="input" type="number" value={l.qtyPlan ?? 0} onChange={(e) => upd(di, li, { qtyPlan: Number(e.target.value) })} aria-label="Qty rencana kg" />
                <input className="input" placeholder="Container" value={l.kontainer ?? ''} onChange={(e) => upd(di, li, { kontainer: e.target.value.toUpperCase() })} />
              </div>
              {jenis === 'SPBB' && (
                <div className="row">
                  <input className="input" list="dl-palet" placeholder="Jenis palet" value={l.palet ?? ''} onChange={(e) => upd(di, li, { palet: e.target.value })} />
                  <input className="input" type="number" placeholder="Jml palet" value={l.paletPlan ?? ''} onChange={(e) => upd(di, li, { paletPlan: Number(e.target.value) })} />
                </div>
              )}
            </div>
          ))}
        </div>
      ))}
      <datalist id="dl-palet">{paletList.filter((p) => p.aktif).map((p) => <option key={p.paletCode} value={p.paletCode}>{p.beratKg} kg</option>)}</datalist>
      <datalist id="dl-ruang">{ruangList.filter((r) => r.aktif).map((r) => <option key={r.kodeRuangan} value={r.kodeRuangan}>{r.namaRuangan}{r.titipan ? ' (titipan)' : ''}</option>)}</datalist>
      <div className="card stack">
        <label className="stack tight"><span className="small muted">Ruangan</span><input className="input" list="dl-ruang" value={ruang} onChange={(e) => setRuang(e.target.value)} /></label>
        {room?.titipan && <label className="stack tight"><span className="small muted">Kode customer titipan (pemilik barang)</span><input className="input" value={titipanCard} onChange={(e) => setTitipanCard(e.target.value)} /></label>}
        {jenis === 'SPBB' && <label className="stack tight"><span className="small muted">Kode PT (opsional)</span><input className="input" value={pt} onChange={(e) => setPt(e.target.value)} /></label>}
        <div className="row"><label className="stack tight grow"><span className="small muted">Tanggal jadwal</span><input className="input" type="date" value={tgl} onChange={(e) => setTgl(e.target.value)} /></label>
          <label className="stack tight grow"><span className="small muted">ETA (HH:MM, opsional)</span><input className="input" type="time" value={eta} onChange={(e) => setEta(e.target.value)} /></label></div>
        <div className="stack tight"><span className="small muted">Krani</span>
          {kraniList.map((k) => <label key={k.userId} className="row"><input type="checkbox" checked={kranis.includes(k.userId)} onChange={(e) => setKranis(e.target.checked ? [...kranis, k.userId] : kranis.filter((x) => x !== k.userId))} /> {k.userCode} · {k.name}</label>)}
        </div>
      </div>
    </Page>
  );
}

export function PlanDetail({ id }: { id: string }) {
  const toast = useToast();
  const { data, error, loading, reload } = useLoad(() => get<Row>(`/api/cms/plan/${id}`), [id]);
  const [kraniList, setKraniList] = useState<Row[] | null>(null);
  const [sel, setSel] = useState<number[]>([]);
  const h = data?.header;
  async function aksi(path: string, body?: unknown, ok = 'Berhasil') {
    try { await post(`/api/cms/plan/${id}/${path}`, body); toast(ok); reload(); } catch (e) { toast(errText(e), true); }
  }
  async function bukaKrani() {
    setKraniList(await get<Row[]>('/api/cms/plan/krani', { whs: h.WhsCode }));
    setSel((data!.kranis as Row[]).map((k) => k.userId));
  }
  async function simpanKrani() {
    try { await put(`/api/cms/plan/${id}/krani`, { Kranis: sel }); toast('Krani diperbarui'); setKraniList(null); reload(); } catch (e) { toast(errText(e), true); }
  }
  const aktif = h && ['Terbit', 'Proses', 'Partial'].includes(h.Status);
  return (
    <Page eyebrow="Admin" title={h?.PlanNo ?? 'Dokumen'} accent="ink" backTo="/admin/plan">
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      {h && (
        <>
          <div className="card stack tight">
            <KV k="Status" v={<StatusPill status={h.Status} />} /><KV k="Jenis" v={h.Jenis} /><KV k="Gudang" v={h.WhsCode} />
            <KV k="Ruangan" v={`${h.KodeRuangan ?? '-'}${h.titipan ? ' (titipan)' : ''}`} /><KV k="BP" v={h.CardName ?? '-'} />
            <KV k="Krani" v={(data!.kranis as Row[]).map((k) => k.userCode).join(', ') || '-'} />
            {h.CloseReason && <KV k="Alasan tutup" v={h.CloseReason} />}
          </div>
          <div className="card stack tight"><strong>Dokumen sumber</strong>
            {(data!.docs as Row[]).map((d) => <div key={`${d.baseType}${d.baseDocEntry}`} className="small">{d.baseType} {d.baseDocNum} · {d.cardName} {d.numAtCard ? `· PO ${d.numAtCard}` : ''}</div>)}</div>
          <div className="tablewrap"><table className="table"><thead><tr><th>Item</th><th>Container</th><th>Rencana</th><th>Realisasi</th><th>Sisa</th></tr></thead><tbody>
            {(data!.lines as Row[]).map((l) => <tr key={l.PlanLine}><td data-label="Item">{l.ItemCode}<div className="small muted">{l.Dscription}</div></td><td data-label="Container" className="mono">{l.ContainerNo ?? '-'}</td>
              <td data-label="Rencana" className="num">{fmt(l.QtyPlan)}</td><td data-label="Realisasi" className="num">{fmt(l.QtyDone)}</td><td data-label="Sisa" className="num">{fmt(l.QtyOutstanding)}</td></tr>)}
          </tbody></table></div>
          {aktif && (
            <div className="stack">
              <button className="btn outline" onClick={bukaKrani}>Atur krani</button>
              {kraniList && <div className="card stack">{kraniList.map((k) => <label key={k.userId} className="row"><input type="checkbox" checked={sel.includes(k.userId)} onChange={(e) => setSel(e.target.checked ? [...sel, k.userId] : sel.filter((x) => x !== k.userId))} /> {k.userCode} · {k.name}</label>)}<button className="btn small" onClick={simpanKrani}>Simpan krani</button></div>}
              <div className="row">
                <button className="btn small outline" onClick={() => { const a = prompt('Alasan: Supplier kurang kirim / Barang rusak/ditolak / Sisa dibatalkan Admin'); if (a) aksi('tutup-sisa', { Alasan: a }, 'Sisa ditutup'); }}>Tutup sisa</button>
                <button className="btn small ghost" onClick={() => { if (confirm('Batalkan dokumen ini?')) aksi('batal', undefined, 'Dibatalkan'); }}>Batal</button>
              </div>
            </div>
          )}
        </>
      )}
    </Page>
  );
}

export const matchPlan = (path: string) => match('/admin/plan/:id', path);
