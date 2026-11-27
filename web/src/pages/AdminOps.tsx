import { useState } from 'react';
import { get, post, put, type Row } from '../api';
import { ErrorBox, Page, SearchSelect, Spinner, StatusPill, errText, fmt, fmtDate, todayIso, useLoad, useToast, useWarehouses, whsOpts } from '../ui';

const hm = (m?: number | null) => (m == null ? '-' : `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`);

function WhsPick({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const wh = useWarehouses();
  return <div><SearchSelect options={whsOpts(wh.data)} value={value} onChange={onChange} placeholder="Cari & pilih gudang" /></div>;
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
      extra={<div className="formrow"><WhsPick value={whs} onChange={setWhs} /><input className="input" type="date" value={tgl} onChange={(e) => setTgl(e.target.value)} /></div>}
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
              <div className="formrow">
                <input className="input narrow" type="time" value={ed[p.planId]?.eta ?? p.eta ?? ''} onChange={(e) => setEd({ ...ed, [p.planId]: { ...ed[p.planId], eta: e.target.value } })} aria-label="ETA" />
                <div><SearchSelect options={(data.docks as string[]).map((d) => ({ value: d, label: d }))} value={ed[p.planId]?.dock ?? p.dock ?? ''} onChange={(v) => setEd({ ...ed, [p.planId]: { ...ed[p.planId], dock: v } })} allowEmpty="Otomatis" placeholder="Jalur" /></div>
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

const isoMinus = (days: number) => { const d = new Date(); d.setDate(d.getDate() - days); return d.toISOString().slice(0, 10); };

/// Daftar Surat Jalan yang sudah dibuat, dengan filter gudang, status, periode dan kata kunci.
function DaftarSuratJalan({ onOpen, reloadKey }: { onOpen: (id: number) => void; reloadKey: number }) {
  const wh = useWarehouses();
  const [whs, setWhs] = useState('');
  const [status, setStatus] = useState('');
  const [dari, setDari] = useState(isoMinus(30));
  const [sampai, setSampai] = useState(todayIso());
  const [q, setQ] = useState('');
  const [cari, setCari] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/cms/surat-jalan', { whs, status, dari, sampai, q: cari }), [whs, status, dari, sampai, cari, reloadKey]);
  const rows = data ?? [];
  const aktif = rows.filter((r) => r.status !== 'Batal');
  return (
    <div className="card stack">
      <strong>Daftar Surat Jalan</strong>
      <div className="formrow">
        <div><SearchSelect options={whsOpts(wh.data)} value={whs} onChange={setWhs} allowEmpty="Semua gudang" placeholder="Cari gudang" /></div>
        <select className="input" value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Status">
          <option value="">Semua status</option><option value="Terbit">Terbit</option><option value="Batal">Batal</option>
        </select>
        <label className="stack tight"><span className="small muted">Dari</span><input className="input" type="date" value={dari} max={sampai} onChange={(e) => setDari(e.target.value)} /></label>
        <label className="stack tight"><span className="small muted">Sampai</span><input className="input" type="date" value={sampai} min={dari} onChange={(e) => setSampai(e.target.value)} /></label>
      </div>
      <div className="row">
        <input className="input grow" placeholder="Cari no. SJ / no. polisi / container / sopir / SPMB / customer / PO" value={q}
          onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && setCari(q.trim())} />
        <button className="btn small" onClick={() => setCari(q.trim())}>Cari</button>
        {cari && <button className="btn small ghost" onClick={() => { setQ(''); setCari(''); }}>Reset</button>}
      </div>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      <div className="small muted">{rows.length} Surat Jalan{rows.length >= 500 ? ' (maks 500, persempit filter)' : ''} · {aktif.length} aktif · total {fmt(aktif.reduce((a, r) => a + Number(r.totalKg ?? 0), 0))} kg</div>
      <div className="tablewrap"><table className="table cards">
        <thead><tr><th>No. SJ</th><th>Tanggal</th><th>Gudang</th><th>Kendaraan</th><th>SPMB</th><th>Customer · PO</th><th className="num">Total</th><th>Status</th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.sjId} className="click" onClick={() => onOpen(r.sjId)}>
              <td data-label="No. SJ" className="mono"><strong>{r.sjNo}</strong></td>
              <td data-label="Tanggal">{fmtDate(r.tglSj)}</td>
              <td data-label="Gudang">{r.whsCode}</td>
              <td data-label="Kendaraan"><span className="mono">{r.noPolisi ?? '-'}</span><div className="small muted">{r.containerNo ? `${r.containerNo} · ` : ''}{r.sopir ? `sopir ${r.sopir}` : ''}</div></td>
              <td data-label="SPMB" className="mono small">{r.spmb}</td>
              <td data-label="Customer · PO">{r.customer}<div className="small muted">{r.po ? `PO ${r.po}` : ''}</div></td>
              <td data-label="Total" className="num">{fmt(r.totalKg)} kg<div className="small muted">{fmt(r.totalSak)} sak · {fmt(r.totalPalet)} plt</div></td>
              <td data-label="Status"><StatusPill status={r.status} /></td>
            </tr>
          ))}
          {data && rows.length === 0 && <tr><td colSpan={8} className="empty">Tidak ada Surat Jalan untuk filter ini</td></tr>}
        </tbody>
      </table></div>
    </div>
  );
}

export function AdminSuratJalan() {
  const toast = useToast();
  const [whs, setWhs] = useState('');
  const [tab, setTab] = useState<'buat' | 'daftar'>('daftar');
  const [rk, setRk] = useState(0);
  const list = { reload: () => setRk((n) => n + 1) };
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
      toast(`Terbit ${r.sjNo}`); setPick({}); list.reload(); cand.reload(); setTab('daftar');
    } catch (e) { toast(errText(e), true); }
  }
  async function lihat(id: number) { try { setDetail(await get<Row>(`/api/cms/surat-jalan/${id}`)); window.scrollTo({ top: 0, behavior: 'smooth' }); } catch (e) { toast(errText(e), true); } }
  async function batal(id: number) { if (!confirm('Batalkan Surat Jalan ini?')) return; try { await post(`/api/cms/surat-jalan/${id}/batal`); toast('Dibatalkan'); setDetail(null); list.reload(); cand.reload(); } catch (e) { toast(errText(e), true); } }
  return (
    <Page eyebrow="Admin" title="Surat Jalan" accent="ink" extra={tab === 'buat' ? <WhsPick value={whs} onChange={setWhs} /> : undefined}>
      <div className="chips" role="tablist">
        <button className="chip" aria-pressed={tab === 'daftar'} onClick={() => setTab('daftar')}>Daftar Surat Jalan</button>
        <button className="chip" aria-pressed={tab === 'buat'} onClick={() => setTab('buat')}>Buat Surat Jalan</button>
      </div>
      {tab === 'buat' && !whs && <div className="small muted">Pilih gudang untuk melihat SPMB yang siap dibuatkan Surat Jalan.</div>}
      {tab === 'daftar' && !detail && <DaftarSuratJalan onOpen={lihat} reloadKey={rk} />}
      {tab === 'buat' && whs && (
        <>
          <div className="card stack">
            <strong>SPMB siap dibuatkan Surat Jalan</strong>
            {(cand.data ?? []).length === 0 && <div className="small muted">Tidak ada</div>}
            {(cand.data ?? []).map((c) => (
              <div key={c.planId} className="card pad-s stack tight">
                <label className="row"><input type="checkbox" checked={!!pick[c.planId]} onChange={(e) => { const n = { ...pick }; if (e.target.checked) n[c.planId] = { po: c.poTerakhir ?? '', alamat: '' }; else delete n[c.planId]; setPick(n); }} />
                  <span className="grow mono">{c.planNo} <span className="small muted">{c.whsCode}</span></span>{c.titipan && <span className="pill amber">Titipan</span>}</label>
                <div className="small">{c.cardName} · {fmt(c.kg)} kg</div>
                {pick[c.planId] && (<>
                  <input className="input" placeholder="No. PO" value={pick[c.planId].po} onChange={(e) => setPick({ ...pick, [c.planId]: { ...pick[c.planId], po: e.target.value } })} />
                  <input className="input" placeholder="Alamat kirim" value={pick[c.planId].alamat} onChange={(e) => setPick({ ...pick, [c.planId]: { ...pick[c.planId], alamat: e.target.value } })} />
                </>)}
              </div>
            ))}
            {ids.length > 0 && (<>
              <SearchSelect options={(veh.data ?? []).map((v) => ({ value: String(v.regId), label: `${v.noPolisi} · ${v.sopir}` }))} value={reg} onChange={setReg} allowEmpty="(tanpa kendaraan)" placeholder="Kendaraan (opsional)" />
              <input className="input" type="date" max={todayIso()} value={tgl} onChange={(e) => setTgl(e.target.value)} />
              <button className="btn" onClick={buat}>Terbitkan Surat Jalan ({ids.length} SPMB)</button>
            </>)}
          </div>
        </>
      )}
      {detail && (
        <div className="card stack">
          <div className="row"><strong className="mono grow">{detail.header.sjNo}</strong><StatusPill status={detail.header.status} /></div>
          <div className="small muted">{fmtDate(detail.header.tglSj)} · {detail.header.noPolisi ?? 'tanpa kendaraan'}{detail.header.containerNo ? ` · ${detail.header.containerNo}` : ''}{detail.header.sopir ? ` · sopir ${detail.header.sopir}` : ''} · {fmt(detail.header.totalKg)} kg</div>
          {(detail.plans as Row[]).map((p) => <div key={p.planId} className="small">{p.planNo} · {p.cardName} · PO {p.numAtCard ?? '-'}<br />{p.alamatKirim}</div>)}
          {(detail.lines as Row[]).map((l) => <div key={l.sjLine} className="small">{l.itemCode} · muat {fmt(l.qtyMuat)} kg (rencana {fmt(l.qtyPlan)}){l.noBL ? ` · BL ${l.noBL}` : ''}{l.ptCode ? ` · PT ${l.ptCode}` : ''}</div>)}
          <div className="row">
            <button className="btn small outline" onClick={() => window.print()}>Cetak</button>
            {detail.header.status !== 'Batal' && <button className="btn small ghost" onClick={() => batal(detail.header.sjId)}>Batalkan</button>}
            <button className="btn small ghost" onClick={() => setDetail(null)}>Tutup / kembali ke daftar</button>
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
  const [qs, setQs] = useState('');
  const ks = useLoad(() => (tab === 'sesi' ? get<Row[]>('/api/cms/kontainer-sesi', { whs, q: qs }) : Promise.resolve([])), [tab, whs, qs]);
  const [sesi, setSesi] = useState<Row | null>(null);
  const kg = (v: unknown) => (v == null ? '-' : fmt(v));
  async function buatKode() { try { const r = await post<Row>('/api/cms/kode-persetujuan', { WhsCode: whs, Tujuan: 'TIMBANG' }); setKode(r.kode); } catch (e) { toast(errText(e), true); } }
  const T = (cols: [string, string][], rows: Row[]) => (
    <div className="tablewrap"><table className="table cards"><thead><tr>{cols.map(([, l]) => <th key={l}>{l}</th>)}</tr></thead><tbody>
      {rows.map((r, i) => <tr key={i}>{cols.map(([k, l]) => <td key={k} data-label={l}>{k.toLowerCase().includes('waktu') || k === 'jamMasuk' || k === 'jamKeluar' ? String(r[k] ?? '-').replace('T', ' ').slice(0, 16) : String(r[k] ?? '-')}</td>)}</tr>)}
    </tbody></table></div>
  );
  return (
    <Page eyebrow="Admin" title="Kendaraan & Riwayat Berat" accent="ink" extra={
      <div className="stack tight"><WhsPick value={whs} onChange={setWhs} />
        <div className="chips">{[['dalam', 'Di dalam'], ['sesi', 'Timbang kontainer'], ['yard', 'Yard kontainer'], ['mobil', 'Riwayat tara mobil'], ['kontainer', 'Riwayat tara kontainer']].map(([k, t]) => <button key={k} className="chip" aria-pressed={tab === k} onClick={() => setTab(k)}>{t}</button>)}</div></div>}>
      {whs && <div className="card pad-s row"><button className="btn small" onClick={buatKode}>Buat kode persetujuan</button>{kode && <span className="mono"><strong>{kode}</strong> · berlaku 15 menit, sekali pakai</span>}</div>}
      {tab === 'dalam' && (
        <div className="tablewrap"><table className="table cards"><thead><tr><th>Tiket</th><th>Plat</th><th>Sopir</th><th>Keperluan</th><th>Dokumen</th><th>Masuk</th><th /></tr></thead><tbody>
          {(dalam.data ?? []).map((r) => (
            <tr key={r.regId}><td data-label="Tiket" className="mono">{r.tiket}</td><td data-label="Plat" className="mono">{r.noPolisi}</td><td data-label="Sopir">{r.sopir}</td>
              <td data-label="Keperluan">{r.keperluan}</td><td data-label="Dokumen" className="mono">{r.planNo ?? '-'}</td><td data-label="Masuk">{String(r.jamMasuk ?? '').replace('T', ' ').slice(0, 16)}</td>
              <td><button className="btn small outline" onClick={async () => {
                const v = prompt(`No. polisi baru untuk ${r.noPolisi}`, r.noPolisi);
                if (!v || v === r.noPolisi) return;
                try { const x = await put<Row>(`/api/cms/kendaraan/${r.regId}/plat`, { NoPolisi: v }); toast(`Plat diubah ke ${x.noPolisi} · ${x.dokumen} dokumen open ikut dikoreksi`); dalam.reload(); } catch (e) { toast(errText(e), true); }
              }}>Ubah plat</button></td></tr>
          ))}</tbody></table></div>
      )}
      {tab === 'sesi' && (<>
        <input className="input" placeholder="Cari kontainer / SPBB / plat" value={qs} onChange={(e) => setQs(e.target.value)} />
        <div className="tablewrap"><table className="table cards"><thead><tr><th>Kontainer</th><th>SPBB</th><th>Status</th><th>Isi (T1-T2)</th><th>Kosong (T4-T3)</th><th>Net</th><th>Krani</th><th>Selisih</th><th /></tr></thead><tbody>
          {(ks.data ?? []).map((k) => (
            <tr key={k.sesiId}><td data-label="Kontainer" className="mono">{k.containerNo}</td><td data-label="SPBB" className="mono">{k.planNo ?? '-'}</td><td data-label="Status">{k.status}</td>
              <td data-label="Isi" className="num">{kg(k.beratIsi)}</td><td data-label="Kosong" className="num">{kg(k.beratKosong)}</td><td data-label="Net" className="num">{kg(k.net)}</td>
              <td data-label="Krani" className="num">{kg(k.netKrani)}</td><td data-label="Selisih" className="num">{k.selisihPersen != null ? `${k.selisihPersen}%` : '-'}</td>
              <td><button className="btn small outline" onClick={async () => setSesi(await get<Row>(`/api/cms/kontainer-sesi/${k.sesiId}`))}>Detail</button></td></tr>
          ))}</tbody></table></div>
        {sesi && (
          <div className="card stack">
            <div className="row"><strong className="mono grow">{sesi.header.containerNo} · {sesi.header.planNo ?? '-'}</strong><button className="btn small ghost" onClick={() => setSesi(null)}>Tutup</button></div>
            <div className="small">T1 {kg(sesi.header.t1)} ({sesi.header.plat1 ?? '-'}) · T2 {kg(sesi.header.t2)} → isi <strong>{kg(sesi.header.beratIsi)}</strong> kg</div>
            <div className="small">T3 {kg(sesi.header.t3)} ({sesi.header.plat3 ?? '-'}) · T4 {kg(sesi.header.t4)} → kosong <strong>{kg(sesi.header.beratKosong)}</strong> kg</div>
            <div>Net barang <strong>{kg(sesi.header.net)}</strong> kg · input krani {kg(sesi.header.netKrani)} kg{sesi.header.selisihPersen != null ? ` · selisih ${sesi.header.selisihPersen}%` : ''}</div>
            {sesi.header.peringatan && <div className="small muted">{sesi.header.peringatan}</div>}
            <div className="tablewrap"><table className="table cards"><thead><tr><th>Barang</th><th>Karung</th><th>KG krani</th><th>Sampel (krg / kg)</th><th>Estimasi (krg × rata²)</th><th>KG timbang</th></tr></thead><tbody>
              {((sesi.alokasi as Row[]).length ? (sesi.alokasi as Row[]) : (sesi.items as Row[])).map((a) => (
                <tr key={a.planLine}><td data-label="Barang">{a.itemCode}</td><td data-label="Karung" className="num">{kg(a.sakTotal)}</td><td data-label="KG krani" className="num">{kg(a.kgKrani)}</td>
                  <td data-label="Sampel" className="num">{a.sakSampel ? `${a.sakSampel} krg / ${fmt(a.kgSampel)} kg` : 'belum'}</td>
                  <td data-label="Estimasi" className="num">{kg(a.estimasiSisaKg)}</td><td data-label="KG timbang" className="num"><strong>{kg(a.kgTimbang)}</strong></td></tr>
              ))}</tbody></table></div>
          </div>
        )}
      </>)}
      {tab === 'yard' && T([['containerNo', 'Kontainer'], ['status', 'Lokasi'], ['posisi', 'Area'], ['kondisi', 'Kondisi'], ['taraKg', 'Tara kg'], ['dialokasikan', 'Dialokasikan']], yard.data ?? [])}
      {tab === 'mobil' && (<><input className="input" placeholder="Cari plat (kosong = ringkasan)" value={plat} onChange={(e) => setPlat(e.target.value)} />
        {plat ? T([['noPolisi', 'Plat'], ['taraKg', 'Tara kg'], ['sumber', 'Sumber'], ['selisihRataPersen', 'Selisih %'], ['sopir', 'Sopir'], ['waktuTimbang', 'Waktu'], ['oleh', 'Oleh']], rm.data ?? [])
          : T([['noPolisi', 'Plat'], ['jumlahTimbang', 'Jml'], ['rataTara', 'Rata'], ['minTara', 'Min'], ['maxTara', 'Maks'], ['taraTerakhir', 'Terakhir']], rm.data ?? [])}</>)}
      {tab === 'kontainer' && (<><input className="input" placeholder="Cari kontainer (kosong = ringkasan)" value={cont} onChange={(e) => setCont(e.target.value)} />
        {cont ? T([['containerNo', 'Kontainer'], ['taraKg', 'Tara kg'], ['peristiwa', 'Peristiwa'], ['noPolisi', 'Plat'], ['selisihRataPersen', 'Selisih %'], ['waktuTimbang', 'Waktu']], rk.data ?? [])
          : T([['containerNo', 'Kontainer'], ['jumlahTimbang', 'Jml'], ['rataTara', 'Rata'], ['minTara', 'Min'], ['maxTara', 'Maks'], ['taraTerakhir', 'Terakhir']], rk.data ?? [])}</>)}
    </Page>
  );
}
