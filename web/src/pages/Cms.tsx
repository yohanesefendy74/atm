import { useEffect, useState } from 'react';
import { get, post, put, type Row } from '../api';
import { Link, navigate } from '../router';
import { ErrorBox, Icon, KV, Page, Spinner, errText, fmt, fmtDate, num, useLoad, useToast } from '../ui';

const TRX: Record<string, string> = {
  IB: 'Inbound Supplier',
  RC: 'Retur Customer',
  BT: 'Barang Titipan',
  OB: 'Outbound',
  KR: 'Penyesuaian',
  SS: 'Susut',
  RP: 'Repacking',
};
const OBJ: Record<string, string> = { '6730': 'Inbound', '6710': 'Outbound', '6720': 'Penyesuaian' };

const needCardType = (objType: string, trx: string): 'S' | 'C' | null =>
  trx === 'IB' ? 'S' : trx === 'BT' ? (objType === '6730' ? 'S' : 'C') : trx === 'OB' || trx === 'RC' ? 'C' : null;
const targetObj = (trx: string, cur: string) => (trx === 'SS' ? '6710' : trx === 'KR' || trx === 'RP' ? '6720' : cur);

export function CmsList() {
  const [status, setStatus] = useState('O');
  const [obj, setObj] = useState('');
  const [q, setQ] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/cms/docs', { status, objType: obj }), [status, obj]);
  const s = q.trim().toUpperCase();
  const rows = (data ?? []).filter((r) => !s || [r.docEntry, r.krani, r.containerNo, r.noMobil, r.cardName, r.trxCode].some((v) => String(v ?? '').toUpperCase().includes(s)));
  const waitPt = (data ?? []).filter((r) => r.docStatus === 'O' && !r.ptCode).length;
  const edited = (data ?? []).filter((r) => Number(r.editedLines) > 0).length;

  return (
    <Page
      eyebrow="CMS Admin"
      title="Cek input krani"
      accent="ink"
      extra={
        <div className="stack tight">
          <input className="input" placeholder="Cari no. dokumen / krani / container / BP" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Cari" />
          <div className="chips" role="group" aria-label="Filter">
            {[
              ['O', 'Belum diposting'],
              ['C', 'Close'],
              ['all', 'Semua status'],
            ].map(([v, l]) => (
              <button key={v} className="chip" aria-pressed={status === v} onClick={() => setStatus(v)}>
                {l}
              </button>
            ))}
            <span className="muted">|</span>
            {[
              ['', 'Semua'],
              ['6730', 'Inbound'],
              ['6710', 'Outbound'],
              ['6720', 'Penyesuaian'],
            ].map(([v, l]) => (
              <button key={v || 'all'} className="chip" aria-pressed={obj === v} onClick={() => setObj(v)}>
                {l}
              </button>
            ))}
          </div>
        </div>
      }
    >
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      {data && (
        <div className="grid2">
          <div className="card stat accent-ink">
            <div className="eyebrow">Antrian</div>
            <div className="n">{(data ?? []).filter((r) => r.docStatus === 'O').length}</div>
            <div className="small muted">{waitPt} belum ada PT (label krani terkunci)</div>
          </div>
          <div className="card stat accent-out">
            <div className="eyebrow">Qty diedit admin</div>
            <div className="n">{edited}</div>
            <div className="small muted">nilai krani tersimpan di *_scan</div>
          </div>
        </div>
      )}
      {data && (
        <table className="table cards">
          <thead>
            <tr>
              <th>No. dokumen</th>
              <th>Tanggal</th>
              <th>Trx</th>
              <th>Warehouse</th>
              <th>Container</th>
              <th>PT</th>
              <th>BP</th>
              <th>Krani</th>
              <th className="num">KG</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={`${r.objType}-${r.docEntry}`} className="click" onClick={() => navigate(`/cms/${r.objType}/${r.docEntry}`)}>
                <td data-label="No. dokumen" className="mono">
                  <Link to={`/cms/${r.objType}/${r.docEntry}`}>
                    <strong>{r.docEntry}</strong>
                  </Link>
                </td>
                <td data-label="Tanggal">{fmtDate(r.docDate)}</td>
                <td data-label="Trx">
                  <span className="pill mono">{r.trxCode}</span>
                </td>
                <td data-label="Warehouse" className="mono">
                  {r.whsCode} {r.isTitipan && <span className="pill">TITIPAN</span>}
                </td>
                <td data-label="Container" className="mono">{r.containerNo ?? '-'}</td>
                <td data-label="PT">{r.ptCode ? r.ptName ?? r.ptCode : <span className="pill amber">Belum</span>}</td>
                <td data-label="BP">{r.cardName ?? '-'}</td>
                <td data-label="Krani" className="mono">{r.krani}</td>
                <td data-label="KG" className="num">{fmt(r.qtyKg)}</td>
                <td data-label="Status">
                  {r.docStatus === 'C' ? <span className="pill green">Close</span> : <span className="pill amber">Open</span>}
                  {Number(r.editedLines) > 0 && <span className="pill out">diedit</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {data && rows.length === 0 && <div className="empty">Tidak ada dokumen</div>}
    </Page>
  );
}

/** Kolom pencarian PT (OPRC) atau Business Partner (OCRD). */
function Lookup(props: { url: string; query?: Record<string, string>; value: string; label: string; onChange: (code: string, name: string) => void; disabled?: boolean }) {
  const [q, setQ] = useState(props.value);
  const [list, setList] = useState<Row[]>([]);
  const [open, setOpen] = useState(false);
  useEffect(() => setQ(props.value), [props.value]);
  useEffect(() => {
    if (!open || q.trim().length < 1) return;
    const t = setTimeout(() => {
      get<Row[]>(props.url, { ...(props.query ?? {}), q: q.trim() })
        .then(setList)
        .catch(() => setList([]));
    }, 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, open]);
  return (
    <div className="stack tight">
      <input
        className="input mono"
        value={q}
        maxLength={30}
        disabled={props.disabled}
        aria-label={props.label}
        placeholder="Ketik kode / nama"
        onFocus={() => setOpen(true)}
        onChange={(e) => {
          setQ(e.target.value);
          setOpen(true);
          if (!e.target.value) props.onChange('', '');
        }}
      />
      {open && list.length > 0 && (
        <div className="card pad-s stack tight" role="listbox">
          {list.map((r) => (
            <button
              key={r.code}
              type="button"
              className="list-item"
              role="option"
              aria-selected={r.code === props.value}
              onClick={() => {
                props.onChange(r.code, r.name);
                setQ(r.code);
                setOpen(false);
              }}
            >
              <span className="mono">{r.code}</span>
              <span className="grow small muted">{r.name}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

type Edit = { qty: string; qty2: string; qtyPalet: string; numAtCard: string };

export function CmsDetail({ objType, docEntry }: { objType: string; docEntry: string }) {
  const toast = useToast();
  const doc = useLoad(() => get<Row>(`/api/cms/docs/${encodeURIComponent(objType)}/${encodeURIComponent(docEntry)}`), [objType, docEntry]);
  const audit = useLoad(() => get<Row[]>(`/api/cms/audit/${encodeURIComponent(objType)}/${encodeURIComponent(docEntry)}`).catch(() => [] as Row[]), [objType, docEntry]);
  const [trx, setTrx] = useState('');
  const [pt, setPt] = useState({ code: '', name: '' });
  const [bp, setBp] = useState({ code: '', name: '' });
  const [numAtCard, setNumAtCard] = useState('');
  const [bl, setBl] = useState('');
  const [edits, setEdits] = useState<Record<number, Edit>>({});
  const [retur, setRetur] = useState<Record<number, boolean | null>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);

  const h = doc.data?.header as Row | undefined;
  const lines = (doc.data?.lines as Row[]) ?? [];
  const allowed = (doc.data?.allowedTrx as string[]) ?? [];
  const closed = h?.docStatus === 'C';

  useEffect(() => {
    if (!h) return;
    setTrx(allowed.includes(h.trxCode) ? h.trxCode : allowed[0] ?? h.trxCode);
    setPt({ code: h.ptCode ?? '', name: h.ptName ?? '' });
    setBp({ code: h.cardCode ?? '', name: h.cardName ?? '' });
    setNumAtCard(h.numAtCard ?? '');
    setBl(h.blNo ?? '');
    const e: Record<number, Edit> = {};
    lines.forEach((l) => (e[l.lineNum] = { qty: String(l.qty), qty2: String(l.qty2), qtyPalet: String(l.qtyPalet), numAtCard: l.numAtCard ?? '' }));
    setEdits(e);
    setRetur({});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [doc.data]);

  if (doc.error !== null)
    return (
      <Page eyebrow="CMS" title={docEntry} backTo="/cms" accent="ink">
        <ErrorBox error={doc.error} onRetry={doc.reload} />
      </Page>
    );
  if (!h) return <Spinner />;

  const cardType = needCardType(targetObj(trx, h.objType), trx);
  const isInbound = h.objType === '6730';
  const newObj = targetObj(trx, h.objType);
  const changed = (l: Row, k: 'qty' | 'qty2' | 'qtyPalet') => edits[l.lineNum] && num(edits[l.lineNum][k]) !== Number(l[k]);
  const dirty =
    trx !== h.trxCode ||
    pt.code !== (h.ptCode ?? '') ||
    bp.code !== (h.cardCode ?? '') ||
    numAtCard !== (h.numAtCard ?? '') ||
    bl !== (h.blNo ?? '') ||
    lines.some((l) => changed(l, 'qty') || changed(l, 'qty2') || changed(l, 'qtyPalet') || (edits[l.lineNum]?.numAtCard ?? '') !== (l.numAtCard ?? ''));

  const body = () => ({
    trxCode: trx,
    ptCode: pt.code || null,
    cardCode: cardType ? bp.code || null : null,
    numAtCard: numAtCard.trim() || null,
    blNo: bl.trim() || null,
    lines: lines.map((l) => ({
      lineNum: l.lineNum,
      qty: num(edits[l.lineNum]?.qty),
      qty2: num(edits[l.lineNum]?.qty2),
      qtyPalet: num(edits[l.lineNum]?.qtyPalet),
      numAtCard: edits[l.lineNum]?.numAtCard?.trim() || null,
    })),
  });

  const save = async (): Promise<{ objType: string; docEntry: number } | null> => {
    setBusy(true);
    setErr(null);
    try {
      const r = await put<Row>(`/api/cms/docs/${h.objType}/${h.docEntry}`, body());
      if (r.renumbered) {
        toast(`Tersimpan · nomor baru ${r.objType}/${r.docEntry}`);
        navigate(`/cms/${r.objType}/${r.docEntry}`, true);
      } else {
        toast('Perubahan tersimpan');
        doc.reload();
        audit.reload();
      }
      return { objType: r.objType, docEntry: r.docEntry };
    } catch (e) {
      setErr(e);
      return null;
    } finally {
      setBusy(false);
    }
  };

  const postDoc = async () => {
    if (!window.confirm(`Posting ${h.docEntry} ke stok? Setelah Close dokumen tidak bisa diubah.`)) return;
    let key: { objType: string; docEntry: number } | null = { objType: h.objType, docEntry: h.docEntry };
    if (dirty) key = await save();
    if (!key) return;
    setBusy(true);
    setErr(null);
    try {
      await post(`/api/cms/docs/${key.objType}/${key.docEntry}/post`);
      toast(`${key.docEntry} diposting · status Close`);
      navigate('/cms', true);
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };

  const checkRetur = async (lineNum: number) => {
    const no = edits[lineNum]?.numAtCard?.trim();
    if (!bp.code || !no) return toast('Isi customer dan No DO dulu', true);
    try {
      const r = await get<Row>('/api/cms/retur-check', { cardCode: bp.code, numAtCard: no });
      setRetur({ ...retur, [lineNum]: !!r.valid });
    } catch (e) {
      toast(errText(e), true);
    }
  };

  const setEdit = (lineNum: number, k: keyof Edit, v: string) => setEdits({ ...edits, [lineNum]: { ...edits[lineNum], [k]: v } });

  return (
    <Page
      eyebrow={`CMS · ${OBJ[h.objType] ?? h.objType} · ObjType ${h.objType}`}
      title={String(h.docEntry)}
      backTo="/cms"
      accent="ink"
      actions={closed ? <span className="pill green">Close</span> : <span className="pill amber">Open</span>}
      footerNote={closed ? 'Dokumen sudah diposting.' : dirty ? 'Ada perubahan belum disimpan.' : 'Posting menulis ke stok lalu header & semua baris menjadi Close.'}
      footer={
        closed ? undefined : (
          <>
            <button className="btn ghost" disabled={busy || !dirty} onClick={() => void save()}>
              Simpan perubahan
            </button>
            <button className="btn ink" disabled={busy} onClick={() => void postDoc()}>
              <Icon name="check" /> Posting ke stok
            </button>
          </>
        )
      }
    >
      {err !== null && <ErrorBox error={err} />}
      <div className="card grid3">
        <KV k="Warehouse" v={`${h.whsCode}${h.isTitipan ? ' · TITIPAN' : ''}`} />
        <KV k="No. Mobil" v={h.noMobil ?? '-'} />
        <KV k="Container" v={h.containerNo ?? '-'} />
        <KV k="Tanggal" v={fmtDate(h.docDate)} />
        <KV k="Krani" v={h.krani} />
        <KV k="Input krani" v={h.trxCode} />
      </div>

      <div className="card stack">
        <div className="field">
          <span className="label">TrxCode · pilah dari input krani</span>
          <div className="chips" role="radiogroup" aria-label="TrxCode">
            {allowed.map((t) => (
              <button key={t} className="chip" role="radio" aria-checked={trx === t} aria-pressed={trx === t} disabled={closed} onClick={() => setTrx(t)}>
                {t} · {TRX[t]}
              </button>
            ))}
          </div>
          {newObj !== h.objType && (
            <span className="hint">
              {trx} memakai ObjType {newObj}: dokumen akan mendapat nomor baru dari SYS_NOURUT saat disimpan.
            </span>
          )}
          {h.isTitipan && <span className="hint">Warehouse titipan: KR & RP tidak tersedia.</span>}
        </div>
        <div className="grid2">
          <div className="field">
            <span className="label">
              {trx === 'RC' ? 'PT / Consignee' : 'PT'} <span className="req">*</span>
            </span>
            <Lookup url="/api/cms/pt" label="PT" value={pt.code} disabled={closed} onChange={(code, name) => setPt({ code, name })} />
            <span className="hint">{pt.name || 'Kode PT dari OPRC · wajib diisi agar krani bisa cetak label QR'}</span>
          </div>
          {cardType && (
            <div className="field">
              <span className="label">
                CardCode ({cardType === 'S' ? 'Supplier' : 'Customer'}) <span className="req">*</span>
              </span>
              <Lookup url="/api/cms/bp" query={{ cardType }} label="CardCode" value={bp.code} disabled={closed} onChange={(code, name) => setBp({ code, name })} />
              <span className="hint">{bp.name || `Hanya BP ${cardType === 'S' ? 'Supplier' : 'Customer'} (CardType ${cardType})`}</span>
            </div>
          )}
          {(trx === 'IB' || trx === 'OB' || trx === 'BT') && (
            <label className="field">
              <span className="label">
                Nomor DO / NumAtCard <span className="req">*</span>
              </span>
              <input className="input mono" value={numAtCard} maxLength={100} disabled={closed} onChange={(e) => setNumAtCard(e.target.value)} />
            </label>
          )}
          {isInbound && (trx === 'IB' || trx === 'BT') && (
            <label className="field">
              <span className="label">
                No BL <span className="req">*</span>
              </span>
              <input className="input mono" value={bl} maxLength={50} disabled={closed} onChange={(e) => setBl(e.target.value)} />
              <span className="hint">Bill of Lading</span>
            </label>
          )}
        </div>
      </div>

      <strong>Detail barang · {lines.length} baris</strong>
      <p className="hint">Kolom abu-abu = nilai asli krani (*_scan). Nilai yang diubah admin ditandai oranye.</p>
      <table className="table cards">
        <thead>
          <tr>
            <th>Item</th>
            <th>Arah</th>
            <th className="num">Qty (KG)</th>
            <th className="num">Krani</th>
            <th className="num">Qty 2</th>
            <th className="num">Krani</th>
            <th className="num">Palet</th>
            <th className="num">Krani</th>
            {trx === 'RC' && <th>No DO retur (ODLN)</th>}
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => (
            <tr key={l.lineNum}>
              <td data-label="Item">
                <span className="mono">
                  <strong>{l.itemCode}</strong>
                </span>
                <div className="small muted">{[l.itemName, l.brand, l.origin].filter(Boolean).join(' · ')}</div>
              </td>
              <td data-label="Arah">{Number(l.flag) === 1 ? <span className="pill green">MASUK</span> : <span className="pill out">KELUAR</span>}</td>
              {(['qty', 'qty2', 'qtyPalet'] as const).map((k) => [
                <td key={k} data-label={k === 'qty' ? 'Qty (KG)' : k === 'qty2' ? 'Qty 2' : 'Palet'} className="num">
                  <input
                    className={'input num' + (changed(l, k) ? ' changed' : '')}
                    inputMode="decimal"
                    value={edits[l.lineNum]?.[k] ?? ''}
                    disabled={closed}
                    aria-label={`${k} ${l.itemCode}`}
                    onChange={(e) => setEdit(l.lineNum, k, e.target.value)}
                  />
                </td>,
                <td key={k + 's'} data-label="Krani" className="num muted">
                  {fmt(l[k === 'qty' ? 'qtyScan' : k === 'qty2' ? 'qty2Scan' : 'qtyPaletScan'] ?? l[k])}
                </td>,
              ])}
              {trx === 'RC' && (
                <td data-label="No DO retur">
                  <div className="inputrow">
                    <input
                      className="input mono"
                      value={edits[l.lineNum]?.numAtCard ?? ''}
                      maxLength={50}
                      disabled={closed}
                      onChange={(e) => {
                        setEdit(l.lineNum, 'numAtCard', e.target.value);
                        setRetur({ ...retur, [l.lineNum]: null });
                      }}
                    />
                    <button className="btn small ghost" type="button" onClick={() => void checkRetur(l.lineNum)}>
                      Cek
                    </button>
                    {retur[l.lineNum] === true && <span className="pill green">Valid</span>}
                    {retur[l.lineNum] === false && <span className="pill red">Tidak ada</span>}
                  </div>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>

      <div className="card stack tight">
        <strong>Riwayat (audit log)</strong>
        {(audit.data ?? []).length === 0 && <span className="small muted">Belum ada catatan</span>}
        {(audit.data ?? []).map((a, i) => (
          <div key={i} className="small">
            <span className="mono">{new Date(String(a.logTime)).toLocaleString('id-ID')}</span> · <strong>{a.userCode}</strong> · {a.action} {a.detail ? `· ${a.detail}` : ''}
          </div>
        ))}
      </div>
    </Page>
  );
}
