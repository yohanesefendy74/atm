import { useEffect, useState } from 'react';
import { post, type Row } from '../api';
import { useAuth } from '../auth';
import { navigate } from '../router';
import {
  ErrorBox, Icon, KV, LineForm, LineRow, Page, RuanganSelect, Steps, Totals, fmt, fmtDate, todayIso, useToast, useWarehouses,
  WarehouseSelect, type Line, type Warehouse,
} from '../ui';

const STEPS = ['Header', 'Detail barang', 'Simpan'];
const CONTAINER = /^[A-Z]{4}\d{7}$/;

export default function InboundNew() {
  const { user } = useAuth();
  const toast = useToast();
  const whs = useWarehouses();
  const [step, setStep] = useState(0);
  const [wh, setWh] = useState<Warehouse | null>(null);
  const [mobil, setMobil] = useState('');
  const [cont, setCont] = useState('');
  const [lines, setLines] = useState<Line[]>([]);
  const [ruang, setRuang] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!wh && whs.data?.length) setWh(whs.data.find((w) => w.isDefault) ?? whs.data[0]);
  }, [whs.data, wh]);

  const toDetail = () => {
    const c = cont.replace(/\s/g, '').toUpperCase();
    if (!wh) return setErr(new Error('Pilih warehouse'));
    if (!mobil.trim()) return setErr(new Error('No. mobil wajib diisi'));
    if (c && !CONTAINER.test(c)) return setErr(new Error('Format kontainer: 4 huruf + 7 angka (contoh TGHU8812345)'));
    setCont(c);
    setErr(null);
    setStep(1);
  };

  const save = async () => {
    setBusy(true);
    setErr(null);
    try {
      const r = await post<Row>('/api/inbound', {
        whsCode: wh!.whsCode,
        noMobil: mobil.trim().toUpperCase(),
        containerNo: cont,
        docDate: todayIso(),
        lines: lines.map((l) => ({ itemCode: l.itemCode, uom: l.uom, brand: l.brand || null, origin: l.origin || null, qty: l.qty, qty2: l.qty2, qtyPalet: l.qtyPalet, kodeRuangan: l.kodeRuangan })),
      });
      toast(`Inbound ${r.docEntry} (${r.trxCode}) tersimpan · Menunggu PT`);
      navigate('/inbound', true);
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };

  const total = (k: 'qty' | 'qty2' | 'qtyPalet') => lines.reduce((s, l) => s + l[k], 0);

  if (step === 0)
    return (
      <Page
        eyebrow="Inbound baru"
        title="Data Header"
        backTo="/inbound"
        extra={<Steps labels={STEPS} current={0} />}
        narrow
        footer={
          <button className="btn" onClick={toDetail}>
            Lanjut isi detail barang <Icon name="next" />
          </button>
        }
      >
        {whs.error !== null && <ErrorBox error={whs.error} onRetry={whs.reload} />}
        <div className="field">
          <label htmlFor="wh">
            Warehouse <span className="req">*</span>
          </label>
          <WarehouseSelect id="wh" list={whs.data ?? []} value={wh?.whsCode ?? ''} onChange={setWh} />
          <span className="hint">{wh?.isTitipan ? 'Warehouse titipan: transaksi otomatis BT (Barang Titipan)' : 'Daftar sesuai hak akses akun Anda'}</span>
        </div>
        <label className="field">
          <span className="label">
            No. Mobil <span className="req">*</span>
          </span>
          <input className="input mono" value={mobil} maxLength={20} placeholder="B 9123 KXT" onChange={(e) => setMobil(e.target.value.toUpperCase())} />
        </label>
        <label className="field">
          <span className="label">No. Kontainer</span>
          <input className="input mono" value={cont} maxLength={13} placeholder="TGHU8812345" onChange={(e) => setCont(e.target.value.toUpperCase())} />
          <span className="hint">Format 4 huruf + 7 angka. 1 inbound = 1 kontainer. Kosongkan bila tanpa kontainer.</span>
        </label>
        <div className="card grid2">
          <KV k="Tanggal" v={fmtDate(new Date())} />
          <KV k="Petugas" v={user?.name} />
        </div>
        {err !== null && <ErrorBox error={err} />}
      </Page>
    );

  if (step === 1)
    return (
      <Page
        eyebrow="Langkah 2 dari 3"
        title="Detail barang curah"
        extra={
          <div className="row wrap">
            <button className="btn small ghost" onClick={() => setStep(0)}>
              <Icon name="back" size={16} /> Header
            </button>
            <span className="pill ground mono">{wh?.whsCode}</span>
            <span className="pill ground mono">{mobil}</span>
            {cont && <span className="pill ground mono">{cont}</span>}
          </div>
        }
        narrow
        footer={
          <button className="btn outline" disabled={lines.length === 0} onClick={() => setStep(2)}>
            Lanjut ke ringkasan <Icon name="next" />
          </button>
        }
      >
        <div className="field">
          <label>Ruangan tujuan <span className="req">*</span></label>
          <RuanganSelect whs={wh?.whsCode ?? ''} value={ruang} onChange={setRuang} titipan={wh?.isTitipan ? true : undefined} />
          <p className="hint">Berlaku untuk barang yang ditambahkan berikutnya. Satu container boleh masuk ke beberapa ruangan.</p>
        </div>
        <LineForm onAdd={(l) => (ruang ? setLines([...lines, { ...l, kodeRuangan: ruang }]) : toast('Pilih ruangan tujuan dulu', true))} />
        <strong>Sudah ditambahkan · {lines.length} baris</strong>
        {lines.map((l, i) => (
          <LineRow key={i} l={l} onDelete={() => setLines(lines.filter((_, j) => j !== i))} />
        ))}
      </Page>
    );

  return (
    <Page
      eyebrow="Langkah 3 dari 3"
      title="Ringkasan Inbound"
      extra={
        <button className="btn small ghost" onClick={() => setStep(1)}>
          <Icon name="back" size={16} /> Ubah detail
        </button>
      }
      narrow
      footerNote={
        <>
          Tersimpan sebagai <strong>Menunggu PT</strong> · label QR bisa dicetak setelah Admin mengisi PT di CMS
        </>
      }
      footer={
        <button className="btn" disabled={busy} onClick={save}>
          <Icon name="check" /> {busy ? 'Menyimpan…' : 'Simpan & kirim ke Admin'}
        </button>
      }
    >
      <div className="card grid3">
        <KV k="Warehouse" v={wh?.whsCode} />
        <KV k="No. Mobil" v={mobil} />
        <KV k="Kontainer" v={cont || '-'} />
      </div>
      <strong>Detail barang · {lines.length} baris</strong>
      {lines.map((l, i) => (
        <LineRow key={i} l={l} />
      ))}
      <Totals items={[['Total KG', fmt(total('qty'))], ['Total karung', fmt(total('qty2'))], ['Total palet', fmt(total('qtyPalet'))]]} />
      {err !== null && <ErrorBox error={err} />}
    </Page>
  );
}
