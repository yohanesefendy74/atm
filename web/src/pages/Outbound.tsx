import { useEffect, useRef, useState, type FormEvent } from 'react';
import { get, post, type Row } from '../api';
import { useAuth } from '../auth';
import { navigate } from '../router';
import {
  ErrorBox, Icon, KV, LineForm, LineRow, Page, Steps, Totals, errText, fmt, fmtDate, num, todayIso, useToast,
  useWarehouses, WarehouseSelect, type Line, type Warehouse,
} from '../ui';
import Scanner from './Scanner';

type Pallet = {
  id: number;
  qr: string;
  itemCode: string;
  itemName: string;
  brand: string | null;
  origin: string | null;
  containerNo: string;
  kgPerSak: number;
  sakPerPalet: number;
  stockSak: number;
  partial: boolean;
  sak: number;
  kgManual: number | null;
};
const kgAuto = (p: Pallet) => p.sak * p.kgPerSak;
const kgOf = (p: Pallet) => p.kgManual ?? kgAuto(p);

type Jenis = 'OB' | 'KR' | 'RP';
const STEPS = ['Header', 'Scan palet', 'Simpan'];
let seq = 1;

export default function OutboundNew() {
  const { user } = useAuth();
  const toast = useToast();
  const whs = useWarehouses();
  const [step, setStep] = useState<'header' | 'add' | 'scan' | 'summary'>('header');
  const [wh, setWh] = useState<Warehouse | null>(null);
  const [jenis, setJenis] = useState<Jenis>('OB');
  const [mobil, setMobil] = useState('');
  const [container, setContainer] = useState<string | null>(null);
  const [pallets, setPallets] = useState<Pallet[]>([]);
  const [inLines, setInLines] = useState<Line[]>([]);
  const [sel, setSel] = useState<number | null>(null);
  const [armed, setArmed] = useState(true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const [manual, setManual] = useState('');
  const manualRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!wh && whs.data?.length) setWh(whs.data.find((w) => w.isDefault) ?? whs.data[0]);
  }, [whs.data, wh]);

  const titipan = !!wh?.isTitipan;
  const cur: Jenis = titipan ? 'OB' : jenis;
  const trx = titipan ? 'BT' : cur;
  const isAdj = cur !== 'OB';
  const jenisLabel = { BT: 'BT · Titipan', OB: 'OB · Outbound', KR: 'KR · Penyesuaian', RP: 'RP · Repacking' }[trx];

  const next = (to: 'add' | 'scan') => {
    if (!wh) return setErr(new Error('Pilih warehouse'));
    if (cur === 'OB' && !mobil.trim()) return setErr(new Error('No. mobil wajib diisi'));
    setErr(null);
    setStep(to);
  };

  const addQr = async (raw: string) => {
    const qr = raw.trim();
    if (!qr || !wh) return;
    setBusy(true);
    setArmed(false);
    try {
      const r = await get<Row>('/api/pallet', { qr, whsCode: wh.whsCode });
      if (container && container !== r.containerNo) throw new Error(`QR container lain ditolak. Outbound ini untuk container ${container}.`);
      const p: Pallet = {
        id: seq++,
        qr,
        itemCode: r.itemCode,
        itemName: r.itemName,
        brand: r.brand,
        origin: r.origin,
        containerNo: r.containerNo,
        kgPerSak: num(r.kgPerSak),
        sakPerPalet: num(r.sakPerPalet),
        stockSak: num(r.stockSak),
        partial: false,
        sak: num(r.sakPerPalet),
        kgManual: null,
      };
      const nth = pallets.filter((x) => x.itemCode === p.itemCode).length + 1;
      setContainer(r.containerNo);
      setPallets((ps) => [...ps, p]);
      setSel(p.id);
      const stockPal = p.sakPerPalet > 0 ? Math.ceil(p.stockSak / p.sakPerPalet) : 0;
      toast(stockPal > 0 && nth > stockPal ? `Perhatian: stok ${p.itemCode} di container ini ±${stockPal} palet` : `${p.itemCode} · palet ke-${nth} ditambahkan`);
    } catch (e) {
      toast(errText(e), true);
    } finally {
      setBusy(false);
      setManual('');
    }
  };

  const update = (id: number, patch: Partial<Pallet>) => setPallets((ps) => ps.map((p) => (p.id === id ? { ...p, ...patch } : p)));
  const remove = (id: number) => {
    const rest = pallets.filter((p) => p.id !== id);
    setPallets(rest);
    if (rest.length === 0) setContainer(null);
    setSel(rest.length ? rest[rest.length - 1].id : null);
  };

  // palet digabung per item; tiap palet discan = 1 QtyPalet
  const outLines = Object.values(
    pallets.reduce<Record<string, Row>>((acc, p) => {
      const l = (acc[p.itemCode] ??= { itemCode: p.itemCode, itemName: p.itemName, brand: p.brand, origin: p.origin, uom: 'KG', qty: 0, qty2: 0, qtyPalet: 0, partial: 0 });
      l.qty += kgOf(p);
      l.qty2 += p.sak;
      l.qtyPalet += 1;
      if (p.partial) l.partial += 1;
      return acc;
    }, {}),
  );

  const save = async () => {
    setBusy(true);
    setErr(null);
    try {
      const r = await post<Row>('/api/outbound', {
        whsCode: wh!.whsCode,
        jenis: cur,
        noMobil: mobil.trim().toUpperCase(),
        containerNo: container,
        docDate: todayIso(),
        outLines: outLines.map((l) => ({ itemCode: l.itemCode, uom: 'KG', brand: l.brand, origin: l.origin, qty: Math.round(l.qty * 100) / 100, qty2: l.qty2, qtyPalet: l.qtyPalet })),
        inLines: isAdj ? inLines.map((l) => ({ itemCode: l.itemCode, uom: l.uom, brand: l.brand || null, origin: l.origin || null, qty: l.qty, qty2: l.qty2, qtyPalet: l.qtyPalet })) : [],
      });
      toast(`Outbound ${r.docEntry} (${r.trxCode}) tersimpan`);
      navigate('/outbound', true);
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };

  // ------------------------------------------------------------ header
  if (step === 'header')
    return (
      <Page
        eyebrow="Outbound baru"
        title="Data Header"
        accent="out"
        backTo="/outbound"
        extra={<Steps labels={STEPS} current={0} />}
        narrow
        footer={
          <>
            {isAdj && (
              <button className="btn green outline" onClick={() => next('add')}>
                <Icon name="plus" /> Item Inbound{inLines.length ? ` (${inLines.length} baris)` : ''}
              </button>
            )}
            <button className="btn" onClick={() => next('scan')}>
              Lanjut scan palet <Icon name="next" />
            </button>
          </>
        }
      >
        {whs.error !== null && <ErrorBox error={whs.error} onRetry={whs.reload} />}
        <div className="field">
          <label htmlFor="wh">
            Warehouse <span className="req">*</span>
          </label>
          <WarehouseSelect id="wh" list={whs.data ?? []} value={wh?.whsCode ?? ''} onChange={setWh} />
          <span className="hint">Daftar sesuai hak akses akun Anda</span>
        </div>
        <div className="field">
          <span className="label">
            Jenis transaksi <span className="req">*</span>
          </span>
          <div className="seg" role="radiogroup" aria-label="Jenis transaksi">
            {(
              [
                ['OB', titipan ? 'BT' : 'OB', titipan ? 'Titipan' : 'Outbound'],
                ['KR', 'KR', 'Penyesuaian'],
                ['RP', 'RP', 'Repacking'],
              ] as [Jenis, string, string][]
            ).map(([key, code, label]) => (
              <button key={key} role="radio" aria-checked={cur === key} disabled={titipan && key !== 'OB'} onClick={() => setJenis(key)}>
                <span className="code">{code}</span>
                <span className="lbl">{label}</span>
              </button>
            ))}
          </div>
          <span className="hint">
            {titipan ? 'Warehouse titipan: otomatis BT · KR & RP tidak tersedia' : isAdj ? 'Scan palet keluar dan tambah Item Inbound' : 'Scan palet keluar'}
          </span>
        </div>
        <label className="field">
          <span className="label">No. Mobil {cur === 'OB' && <span className="req">*</span>}</span>
          <input className="input mono" value={mobil} maxLength={20} placeholder="B 9555 KLA" onChange={(e) => setMobil(e.target.value.toUpperCase())} />
        </label>
        <div className="card tint accent-out small">Container asal diisi otomatis dari QR palet pertama yang discan. 1 outbound = 1 container.</div>
        <div className="card grid2">
          <KV k="Tanggal" v={fmtDate(new Date())} />
          <KV k="Petugas" v={user?.name} />
        </div>
        {err !== null && <ErrorBox error={err} />}
      </Page>
    );

  // ------------------------------------------------------------ Item Inbound (KR/RP)
  if (step === 'add')
    return (
      <Page
        eyebrow={jenisLabel}
        title="Item Inbound"
        accent="out"
        extra={
          <div className="row wrap">
            <button className="btn small ghost" onClick={() => setStep('header')}>
              <Icon name="back" size={16} /> Header
            </button>
            <span className="pill ground mono">{wh?.whsCode}</span>
            {container && <span className="pill ground mono">{container}</span>}
          </div>
        }
        narrow
        footer={
          <button className="btn" onClick={() => setStep('scan')}>
            Lanjut scan palet <Icon name="next" />
          </button>
        }
      >
        <LineForm accent="green" sakLabel="Sak" onAdd={(l) => setInLines([...inLines, l])} />
        <strong>Item Inbound · {inLines.length} baris</strong>
        {inLines.map((l, i) => (
          <LineRow key={i} l={l} sak="sak" badge={<span className="pill green">MASUK</span>} onDelete={() => setInLines(inLines.filter((_, j) => j !== i))} />
        ))}
        <p className="hint">Label QR Item Inbound bisa dicetak setelah Admin mengisi PT di CMS.</p>
      </Page>
    );

  // ------------------------------------------------------------ scan
  if (step === 'scan') {
    const p = pallets.find((x) => x.id === sel) ?? null;
    const nth = p ? pallets.filter((x) => x.itemCode === p.itemCode).indexOf(p) + 1 : 0;
    const submitManual = (e: FormEvent) => {
      e.preventDefault();
      void addQr(manual);
    };
    return (
      <Page
        eyebrow={`Langkah 2 dari 3 · ${jenisLabel}`}
        title="Scan palet keluar"
        accent="out"
        extra={
          <button className="btn small ghost" onClick={() => setStep('header')}>
            <Icon name="back" size={16} /> Header
          </button>
        }
        narrow
        footer={
          <>
            {!armed && (
              <button
                className="btn ghost"
                disabled={busy}
                onClick={() => {
                  setArmed(true);
                  manualRef.current?.focus();
                }}
              >
                <Icon name="scan" /> Scan palet berikutnya
              </button>
            )}
            <button className="btn" disabled={pallets.length === 0} onClick={() => setStep('summary')}>
              Selesai scan · Ringkasan
            </button>
          </>
        }
      >
        <Scanner
          armed={armed && !busy}
          onScan={addQr}
          message={!armed ? 'Palet terbaca · tekan "Scan palet berikutnya"' : container ? `Container ${container} · QR container lain ditolak` : 'Arahkan kamera ke QR palet'}
        />
        <form onSubmit={submitManual} className="inputrow">
          <input
            ref={manualRef}
            className="input mono grow"
            value={manual}
            maxLength={80}
            onChange={(e) => setManual(e.target.value.toUpperCase())}
            placeholder="Scan / ketik QR: 261009-GLA-001-TGHU8812345"
            aria-label="QR palet"
            autoFocus
          />
          <button className="btn auto" type="submit" disabled={busy || !manual.trim()}>
            Tambah
          </button>
        </form>

        {p ? (
          <div className="card stack">
            <div className="row top">
              <span className="pill green">
                <Icon name="check" size={14} />
              </span>
              <div className="grow">
                <div className="mono">
                  <strong>
                    {p.itemCode} · palet ke-{nth}
                  </strong>
                </div>
                <div className="mono small muted">QR {p.qr}</div>
                <div className="small muted">
                  Isi palet: {fmt(p.sakPerPalet * p.kgPerSak)} KG · {fmt(p.sakPerPalet)} krg
                </div>
              </div>
              <button className="btn small ghost" onClick={() => remove(p.id)}>
                Batalkan
              </button>
            </div>
            <div className="seg" role="radiogroup" aria-label="Jumlah keluar">
              <button role="radio" aria-checked={!p.partial} onClick={() => update(p.id, { partial: false, sak: p.sakPerPalet, kgManual: null })}>
                <span className="lbl">Keluar utuh</span>
              </button>
              <button role="radio" aria-checked={p.partial} onClick={() => update(p.id, { partial: true, sak: Math.max(1, p.sakPerPalet - 1), kgManual: null })}>
                <span className="lbl">Keluar sebagian</span>
              </button>
            </div>
            {p.partial && (
              <>
                <div className="grid2">
                  <div className="field">
                    <span className="label">Qty 2 (Karung)</span>
                    <div className="inputrow">
                      <button className="btn ghost auto" aria-label="Kurangi karung" onClick={() => update(p.id, { sak: Math.max(1, p.sak - 1), kgManual: null })}>
                        −
                      </button>
                      <input
                        className="input num"
                        inputMode="numeric"
                        value={p.sak}
                        onChange={(e) => update(p.id, { sak: Math.min(Math.max(0, num(e.target.value)), p.sakPerPalet || 9999), kgManual: null })}
                        aria-label="Jumlah karung keluar"
                      />
                      <button className="btn auto" aria-label="Tambah karung" onClick={() => update(p.id, { sak: Math.min(p.sak + 1, p.sakPerPalet || 9999), kgManual: null })}>
                        +
                      </button>
                    </div>
                  </div>
                  <label className="field">
                    <span className="label">Qty (KG)</span>
                    <input
                      className="input num"
                      inputMode="decimal"
                      value={p.kgManual ?? kgAuto(p)}
                      onChange={(e) => {
                        const v = num(e.target.value);
                        update(p.id, { kgManual: v === kgAuto(p) ? null : v });
                      }}
                    />
                  </label>
                </div>
                <div className="row">
                  <span className="hint grow">
                    {p.kgManual === null
                      ? `Otomatis dari karung: ${fmt(p.sak)} × ${fmt(p.kgPerSak)} KG`
                      : `Diubah manual · selisih ${p.kgManual - kgAuto(p) > 0 ? '+' : ''}${fmt(p.kgManual - kgAuto(p))} KG dari otomatis`}
                  </span>
                  {p.kgManual !== null && (
                    <button className="btn small ghost" onClick={() => update(p.id, { kgManual: null })}>
                      Pakai otomatis
                    </button>
                  )}
                </div>
                <div className="card amber pad-s">
                  <div className="row">
                    <strong className="grow">Sisa di palet</strong>
                    <span className="mono">
                      {fmt(Math.max(0, p.sakPerPalet - p.sak) * p.kgPerSak)} KG · {fmt(Math.max(0, p.sakPerPalet - p.sak))} krg
                    </span>
                  </div>
                  <div className="small">Tercatat di sistem · label QR tetap dipakai</div>
                </div>
              </>
            )}
          </div>
        ) : (
          <div className="empty">Belum ada palet. Scan QR label palet.</div>
        )}

        <div className="row">
          <span className="grow">
            <strong className="accent-out">Keluar</strong> · {pallets.length} palet
          </span>
          {isAdj && (
            <span>
              <strong>Item Inbound</strong> · {inLines.length} item
            </span>
          )}
        </div>
        {pallets.map((x) => (
          <button key={x.id} className={'list-item' + (x.id === sel ? ' card accent' : '')} onClick={() => setSel(x.id)}>
            <span className="mono grow">
              {x.itemCode}
              {x.partial ? ' · sebagian' : ''}
            </span>
            <span className="num">
              {fmt(x.sak)} krg · {fmt(kgOf(x))} KG
            </span>
          </button>
        ))}
        <Totals items={[['Total palet', pallets.length], ['Total KG', fmt(pallets.reduce((s, x) => s + kgOf(x), 0))], ['Total karung', fmt(pallets.reduce((s, x) => s + x.sak, 0))]]} />
      </Page>
    );
  }

  // ------------------------------------------------------------ ringkasan
  const btn = trx === 'RP' ? 'Simpan repacking & kirim ke Admin' : trx === 'KR' ? 'Simpan penyesuaian & kirim ke Admin' : `Simpan outbound · ${pallets.length} palet`;
  return (
    <Page
      eyebrow={`Langkah 3 dari 3 · ${jenisLabel}`}
      title="Ringkasan Outbound"
      accent="out"
      extra={
        <button className="btn small ghost" onClick={() => setStep('scan')}>
          <Icon name="back" size={16} /> Kembali ke scan
        </button>
      }
      narrow
      footerNote={isAdj && inLines.length ? `${trx} · Menunggu PT · label Item Inbound dicetak setelah Admin mengisi PT` : 'Tersimpan sebagai Menunggu DO · No DO di-assign di CMS'}
      footer={
        <button className="btn" disabled={busy} onClick={save}>
          <Icon name="truck" /> {busy ? 'Menyimpan…' : btn}
        </button>
      }
    >
      <div className="card grid3">
        <KV k="Warehouse" v={wh?.whsCode} />
        <KV k="No. Mobil" v={mobil || '-'} />
        <KV k="Container asal" v={container ?? '-'} />
      </div>
      <strong>Barang keluar · {outLines.length} item</strong>
      {outLines.map((l) => (
        <div key={l.itemCode} className="card pad-s stack tight">
          <div className="row">
            <span className="mono grow">
              <strong>{l.itemCode}</strong>
            </span>
            <span className="pill out">KELUAR</span>
          </div>
          <div className="small muted">{[l.itemName, l.brand, l.origin].filter(Boolean).join(' · ')}</div>
          {l.partial > 0 && (
            <span className="pill amber">
              {l.qtyPalet - l.partial} utuh + {l.partial} sebagian
            </span>
          )}
          <div className="grid3">
            <KV k="Qty (KG)" v={fmt(l.qty)} />
            <KV k="Qty 2 (Karung)" v={fmt(l.qty2)} />
            <KV k="Qty Palet" v={fmt(l.qtyPalet)} />
          </div>
        </div>
      ))}
      {isAdj && (
        <>
          <strong>Item Inbound · {inLines.length} item</strong>
          {inLines.map((l, i) => (
            <LineRow key={i} l={l} sak="sak" badge={<span className="pill green">MASUK</span>} />
          ))}
        </>
      )}
      {err !== null && <ErrorBox error={err} />}
    </Page>
  );
}
