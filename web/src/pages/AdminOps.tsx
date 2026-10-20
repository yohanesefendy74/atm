import { useState } from 'react';
import { get, post, type Row } from '../api';
import { ErrorBox, Page, Spinner, StatusPill, errText, fmt, fmtDate, todayIso, useLoad, useToast, useWarehouses } from '../ui';

const hm = (m?: number | null) => (m == null ? '-' : `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`);

function WhsPick({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const wh = useWarehouses();
  return (
    <select className="input" value={value} onChange={(e) => onChange(e.target.value)} aria-label="Gudang">
      <option value="">Pilih gudang</option>
      {(wh.data ?? []).map((w) => <option key={w.whsCode} value={w.whsCode}>{w.whsCode} · {w.whsName}</option>)}
    </select>
  );
}

export function AdminJadwal() {
  const toast = useToast();
  const [whs, setWhs] = useState('');
  const [tgl, setTgl] = useState(todayIso());
  const { data, error, loading, reload } = useLoad(() => (whs ? get<Row>('/api/cms/jadwal', { whs, tgl }) : Promise.resolve(null)), [whs, tgl]);
  const [ed, setEd] = useState<Record<number, { eta?: string; dock?: string }>>({});
  const [hasil, setHasil] = useState<Row[] | null>(null);
  const body = () => ({ WhsCode: whs, Tgl: tgl, Items: ((data?.plans as Row[]) ?? []).map((p) => ({ PlanId: p.planId, Eta: ed[p.planId]?.eta ?? p.eta ?? null, Dock: ed[p.planId]?.dock ?? p.dock ?? null })) });
  async function hitung() { try { setHasil(await post<Row[]>('/api/cms/jadwal/hitung', body())); } catch (e) { toast(errText(e), true); } }
  async function terapkan() { try { await post('/api/cms/jadwal/terapkan', body()); toast('Jadwal diterapkan & dikirim ke krani'); setHasil(null); reload(); } catch (e) { toast(errText(e), true); } }
  const out = (id: number) => hasil?.find((h) => h.planId === id);
  return (
    <Page eyebrow="Admin" title="Jadwal Bongkar / Muat" accent="ink"
      extra={<div className="row"><WhsPick value={whs} onChange={setWhs} /><input className="input" type="date" value={tgl} onChange={(e) => setTgl(e.target.value)} /></div>}
      footer={whs && <div className="row"><button className="btn outline" onClick={hitung}>Hitung</button><button className="btn" onClick={terapkan}>Terapkan & kirim</button></div>}>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && <Spinner />}
      {data && (data.plans as Row[]).length === 0 && <div className="empty">Tidak ada dokumen terjadwal pada tanggal ini (isi Tanggal jadwal saat menerbitkan SPBB/SPMB)</div>}
      <div className="stack">
        {data && (data.plans as Row[]).map((p) => {
          const o = out(p.planId);
          return (
            <div key={p.planId} className="card stack tight">
              <div className="row"><strong className="mono grow">{p.planNo}</strong><StatusPill status={p.status} /></div>
              <div className="small">{p.party} · {fmt(p.kg)} kg · {p.noPolisi ?? 'belum datang'}</div>
              <div className="row">
                <input className="input" type="time" value={ed[p.planId]?.eta ?? p.eta ?? ''} onChange={(e) => setEd({ ...ed, [p.planId]: { ...ed[p.planId], eta: e.target.value } })} aria-label="ETA" />
                <select className="input" value={ed[p.planId]?.dock ?? p.dock ?? ''} onChange={(e) => setEd({ ...ed, [p.planId]: { ...ed[p.planId], dock: e.target.value } })} aria-label="Jalur">
                  <option value="">Otomatis</option>{(data.docks as string[]).map((d) => <option key={d}>{d}</option>)}
                </select>
              </div>
              {o && <div className={'small ' + (o.lewat ? 'pill amber' : '')}>Jalur {o.dock ?? '-'} · {hm(o.mulai)}-{hm(o.selesai)} · {o.durasi} mnt{o.tunggu > 0 ? ` · tunggu ${o.tunggu} mnt` : ''}{o.lewat ? ' · MELEWATI JAM KERJA' : ''}</div>}
              {!o && p.jadwalMulai && <div className="small muted">Terjadwal {p.dock} · {String(p.jadwalMulai).slice(11, 16)}-{String(p.jadwalSelesai).slice(11, 16)}</div>}
            </div>
          );
        })}
      </div>
    </Page>
  );
}

export function AdminSuratJalan() {
  const toast = useToast();
  const [whs, setWhs] = useState('');
  const list = useLoad(() => (whs ? get<Row[]>('/api/cms/surat-jalan', { whs }) : Promise.resolve([])), [whs]);
  const cand = useLoad(() => (whs ? get<Row[]>('/api/cms/surat-jalan/kandidat', { whs }) : Promise.resolve([])), [whs]);
  const veh = useLoad(() => (whs ? get<Row[]>('/api/kendaraan', { whs, status: 'Di dalam' }) : Promise.resolve([])), [whs]);
  const [pick, setPick] = useState<Record<number, { po: string; alamat: string }>>({});
  const [reg, setReg] = useState('');
  const [tgl, setTgl] = useState(todayIso());
  const [detail, setDetail] = useState<Row | null>(null);
  const ids = Object.keys(pick).map(Number);
  async function buat() {
    try {
      const r = await post<Row>('/api/cms/surat-jalan', { WhsCode: whs, TglSj: tgl, RegId: reg ? Number(reg) : null, Plans: ids.map((id) => ({ PlanId: id, NumAtCard: pick[id].po || null, AlamatKirim: pick[id].alamat })) });
      toast(`Terbit ${r.sjNo}`); setPick({}); list.reload(); cand.reload();
    } catch (e) { toast(errText(e), true); }
  }
  async function lihat(id: number) { setDetail(await get<Row>(`/api/cms/surat-jalan/${id}`)); }
  async function batal(id: number) { if (!confirm('Batalkan Surat Jalan ini?')) return; try { await post(`/api/cms/surat-jalan/${id}/batal`); toast('Dibatalkan'); setDetail(null); list.reload(); cand.reload(); } catch (e) { toast(errText(e), true); } }
  return (
    <Page eyebrow="Admin" title="Surat Jalan" accent="ink" extra={<WhsPick value={whs} onChange={setWhs} />}>
      {whs && (
        <>
          <div className="card stack">
            <strong>SPMB siap dibuatkan Surat Jalan</strong>
            {(cand.data ?? []).length === 0 && <div className="small muted">Tidak ada</div>}
            {(cand.data ?? []).map((c) => (
              <div key={c.planId} className="card pad-s stack tight">
                <label className="row"><input type="checkbox" checked={!!pick[c.planId]} onChange={(e) => { const n = { ...pick }; if (e.target.checked) n[c.planId] = { po: c.poTerakhir ?? '', alamat: '' }; else delete n[c.planId]; setPick(n); }} />
                  <span className="grow mono">{c.planNo}</span>{c.titipan && <span className="pill amber">Titipan</span>}</label>
                <div className="small">{c.cardName} · {fmt(c.kg)} kg</div>
                {pick[c.planId] && (<>
                  <input className="input" placeholder="No. PO" value={pick[c.planId].po} onChange={(e) => setPick({ ...pick, [c.planId]: { ...pick[c.planId], po: e.target.value } })} />
                  <input className="input" placeholder="Alamat kirim" value={pick[c.planId].alamat} onChange={(e) => setPick({ ...pick, [c.planId]: { ...pick[c.planId], alamat: e.target.value } })} />
                </>)}
              </div>
            ))}
            {ids.length > 0 && (<>
              <select className="input" value={reg} onChange={(e) => setReg(e.target.value)} aria-label="Kendaraan"><option value="">Kendaraan (opsional)</option>{(veh.data ?? []).map((v) => <option key={v.regId} value={v.regId}>{v.noPolisi} · {v.sopir}</option>)}</select>
              <input className="input" type="date" max={todayIso()} value={tgl} onChange={(e) => setTgl(e.target.value)} />
              <button className="btn" onClick={buat}>Terbitkan Surat Jalan ({ids.length} SPMB)</button>
            </>)}
          </div>
          <div className="stack">
            {(list.data ?? []).map((s) => (
              <button key={s.sjId} className="card pad-s click stack tight" onClick={() => lihat(s.sjId)}>
                <div className="row"><strong className="mono grow">{s.sjNo}</strong><StatusPill status={s.status} /></div>
                <div className="small">{fmtDate(s.tglSj)} · {s.noPolisi ?? '-'} · {s.jumlahSpmb} SPMB · {fmt(s.totalKg)} kg</div>
              </button>
            ))}
          </div>
        </>
      )}
      {detail && (
        <div className="card stack">
          <strong className="mono">{detail.header.sjNo}</strong>
          {(detail.plans as Row[]).map((p) => <div key={p.planId} className="small">{p.planNo} · {p.cardName} · PO {p.numAtCard ?? '-'}<br />{p.alamatKirim}</div>)}
          {(detail.lines as Row[]).map((l) => <div key={l.sjLine} className="small">{l.itemCode} · muat {fmt(l.qtyMuat)} kg (rencana {fmt(l.qtyPlan)})</div>)}
          <div className="row">
            <button className="btn small outline" onClick={() => window.print()}>Cetak</button>
            {detail.header.status !== 'Batal' && <button className="btn small ghost" onClick={() => batal(detail.header.sjId)}>Batalkan</button>}
            <button className="btn small ghost" onClick={() => setDetail(null)}>Tutup</button>
          </div>
        </div>
      )}
    </Page>
  );
}

export function AdminKendaraan() {
  const toast = useToast();
  const [whs, setWhs] = useState('');
  const [tab, setTab] = useState('dalam');
  const [plat, setPlat] = useState('');
  const [cont, setCont] = useState('');
  const [kode, setKode] = useState<string | null>(null);
  const dalam = useLoad(() => (whs && tab === 'dalam' ? get<Row[]>('/api/kendaraan', { whs }) : Promise.resolve([])), [whs, tab]);
  const yard = useLoad(() => (whs && tab === 'yard' ? get<Row[]>('/api/yard', { whs }) : Promise.resolve([])), [whs, tab]);
  const rm = useLoad(() => (tab === 'mobil' ? get<Row[]>('/api/cms/riwayat/mobil', { plat }) : Promise.resolve([])), [tab, plat]);
  const rk = useLoad(() => (tab === 'kontainer' ? get<Row[]>('/api/cms/riwayat/kontainer', { no: cont }) : Promise.resolve([])), [tab, cont]);
  async function buatKode() { try { const r = await post<Row>('/api/cms/kode-persetujuan', { WhsCode: whs, Tujuan: 'TIMBANG' }); setKode(r.kode); } catch (e) { toast(errText(e), true); } }
  const T = (cols: [string, string][], rows: Row[]) => (
    <div className="tablewrap"><table className="table"><thead><tr>{cols.map(([, l]) => <th key={l}>{l}</th>)}</tr></thead><tbody>
      {rows.map((r, i) => <tr key={i}>{cols.map(([k, l]) => <td key={k} data-label={l}>{k.toLowerCase().includes('waktu') || k === 'jamMasuk' || k === 'jamKeluar' ? String(r[k] ?? '-').replace('T', ' ').slice(0, 16) : String(r[k] ?? '-')}</td>)}</tr>)}
    </tbody></table></div>
  );
  return (
    <Page eyebrow="Admin" title="Kendaraan & Riwayat Berat" accent="ink" extra={
      <div className="stack tight"><WhsPick value={whs} onChange={setWhs} />
        <div className="chips">{[['dalam', 'Di dalam'], ['yard', 'Yard kontainer'], ['mobil', 'Riwayat tara mobil'], ['kontainer', 'Riwayat tara kontainer']].map(([k, t]) => <button key={k} className="chip" aria-pressed={tab === k} onClick={() => setTab(k)}>{t}</button>)}</div></div>}>
      {whs && <div className="card pad-s row"><button className="btn small" onClick={buatKode}>Buat kode persetujuan</button>{kode && <span className="mono"><strong>{kode}</strong> · berlaku 15 menit, sekali pakai</span>}</div>}
      {tab === 'dalam' && T([['tiket', 'Tiket'], ['noPolisi', 'Plat'], ['sopir', 'Sopir'], ['keperluan', 'Keperluan'], ['planNo', 'Dokumen'], ['jamMasuk', 'Masuk'], ['selesaiKrani', 'Krani selesai']], dalam.data ?? [])}
      {tab === 'yard' && T([['containerNo', 'Kontainer'], ['posisi', 'Area'], ['kondisi', 'Kondisi'], ['taraKg', 'Tara kg'], ['dialokasikan', 'Dialokasikan']], yard.data ?? [])}
      {tab === 'mobil' && (<><input className="input" placeholder="Cari plat (kosong = ringkasan)" value={plat} onChange={(e) => setPlat(e.target.value)} />
        {plat ? T([['noPolisi', 'Plat'], ['taraKg', 'Tara kg'], ['sumber', 'Sumber'], ['selisihRataPersen', 'Selisih %'], ['sopir', 'Sopir'], ['waktuTimbang', 'Waktu'], ['oleh', 'Oleh']], rm.data ?? [])
          : T([['noPolisi', 'Plat'], ['jumlahTimbang', 'Jml'], ['rataTara', 'Rata'], ['minTara', 'Min'], ['maxTara', 'Maks'], ['taraTerakhir', 'Terakhir']], rm.data ?? [])}</>)}
      {tab === 'kontainer' && (<><input className="input" placeholder="Cari kontainer (kosong = ringkasan)" value={cont} onChange={(e) => setCont(e.target.value)} />
        {cont ? T([['containerNo', 'Kontainer'], ['taraKg', 'Tara kg'], ['peristiwa', 'Peristiwa'], ['noPolisi', 'Plat'], ['selisihRataPersen', 'Selisih %'], ['waktuTimbang', 'Waktu']], rk.data ?? [])
          : T([['containerNo', 'Kontainer'], ['jumlahTimbang', 'Jml'], ['rataTara', 'Rata'], ['minTara', 'Min'], ['maxTara', 'Maks'], ['taraTerakhir', 'Terakhir']], rk.data ?? [])}</>)}
    </Page>
  );
}
