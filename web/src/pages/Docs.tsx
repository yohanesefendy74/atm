import { useState } from 'react';
import { get, type Row } from '../api';
import { Link, navigate, useQuery } from '../router';
import { ErrorBox, Icon, KV, Page, Spinner, StatusPill, fmt, fmtDate, isInbound, useLoad } from '../ui';

const FILTERS = {
  inbound: ['Menunggu PT', 'Siap cetak', 'Selesai'],
  outbound: ['Menunggu DO', 'Menunggu PT', 'Siap cetak', 'Selesai'],
};

export function DocList({ kind }: { kind: 'inbound' | 'outbound' }) {
  const query = useQuery();
  const [filter, setFilter] = useState(query.get('status') ?? 'Semua');
  const [search, setSearch] = useState('');
  const { data, error, loading, reload } = useLoad(() => get<Row[]>('/api/docs', { kind }), [kind]);
  const isIn = kind === 'inbound';
  const q = search.trim().toUpperCase();
  const shown = (data ?? []).filter(
    (d) =>
      (filter === 'Semua' || d.status === filter) &&
      (!q || [d.docEntry, d.noMobil, d.containerNo, d.trxCode].some((v) => String(v ?? '').toUpperCase().includes(q))),
  );

  return (
    <Page
      eyebrow={isIn ? 'Inbound' : 'Outbound'}
      title={isIn ? 'Penerimaan Barang' : 'Pengeluaran Barang'}
      accent={isIn ? 'in' : 'out'}
      actions={
        <Link to={`/${kind}/new`} className="btn small auto">
          <Icon name="plus" size={18} /> Baru
        </Link>
      }
      extra={
        <div className="stack tight">
          <input className="input" placeholder="Cari no. dokumen / mobil / kontainer" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Cari" />
          <div className="chips" role="group" aria-label="Filter status">
            {['Semua', ...FILTERS[kind]].map((f) => (
              <button key={f} className="chip" aria-pressed={filter === f} onClick={() => setFilter(f)}>
                {f}
              </button>
            ))}
          </div>
        </div>
      }
    >
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {loading && !data && <Spinner />}
      {!loading && shown.length === 0 && <div className="empty">Tidak ada dokumen</div>}
      <div className="cardgrid">
        {shown.map((d) => {
          const ready = d.status === 'Siap cetak';
          const to = ready ? `/labels/${d.objType}/${d.docEntry}` : `/docs/${d.objType}/${d.docEntry}`;
          return (
            <Link key={`${d.objType}-${d.docEntry}`} to={to} className={'card click stack tight' + (ready ? ' accent' : '')}>
              <div className="row">
                <span className="grow">
                  <span className="mono">
                    <strong>{d.docEntry}</strong>
                  </span>{' '}
                  <span className="mono small muted">· {d.trxCode}</span>
                </span>
                <StatusPill status={String(d.status)} />
              </div>
              <div className="mono small muted">{[d.whsCode, d.noMobil, d.containerNo ?? 'tanpa kontainer'].filter(Boolean).join(' · ')}</div>
              <div className="small">
                {fmt(d.lineCount)} baris · {fmt(d.qtyKg)} KG · {fmt(d.qtySak)} sak · {fmt(d.qtyPalet)} plt
              </div>
              {d.status === 'Menunggu PT' && (
                <div className="row small muted">
                  <Icon name="lock" size={14} /> Label terkunci sampai PT diisi Admin
                </div>
              )}
              {ready && (
                <span className="btn small">
                  <Icon name="print" size={16} /> Cetak {fmt(d.labelCount)} label QR
                </span>
              )}
            </Link>
          );
        })}
      </div>
      <p className="hint">
        {isIn
          ? 'Inbound dicatat tanpa PO. Label QR bisa dicetak setelah Admin mengisi PT di CMS.'
          : 'Outbound dicatat tanpa DO. Label Item Inbound (KR/RP) bisa dicetak setelah Admin mengisi PT.'}
      </p>
    </Page>
  );
}

const NOTES: Record<string, string> = {
  'Menunggu PT': 'Menunggu Admin mengisi PT di CMS. Label QR bisa dicetak setelah itu.',
  'Menunggu DO': 'Menunggu Admin mengisi customer & No DO di CMS.',
  Selesai: 'Sudah diposting Admin. Stok sudah ter-update.',
};

export function DocDetail({ objType, docEntry }: { objType: string; docEntry: string }) {
  const { data, error, reload } = useLoad(() => get<{ header: Row; lines: Row[] }>(`/api/docs/${encodeURIComponent(objType)}/${encodeURIComponent(docEntry)}`), [objType, docEntry]);
  const h = data?.header;
  const isIn = isInbound(objType);
  const hasIn = (data?.lines ?? []).some((l) => Number(l.flag) === 1);
  const status = !h ? '' : h.docStatus === 'C' ? 'Selesai' : !hasIn ? 'Menunggu DO' : h.ptCode ? 'Siap cetak' : 'Menunggu PT';

  return (
    <Page eyebrow={h ? `${h.trxCode} · ${status}` : 'Dokumen'} title={docEntry} accent={isIn ? 'in' : 'out'} backTo={isIn ? '/inbound' : '/outbound'} narrow>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {!data && error === null && <Spinner />}
      {h && (
        <>
          {NOTES[status] && <div className="card amber">{NOTES[status]}</div>}
          <div className="card grid3">
            <KV k="Warehouse" v={h.whsCode} />
            <KV k="No. Mobil" v={h.noMobil ?? '-'} />
            <KV k="Kontainer" v={h.containerNo ?? '-'} />
            <KV k="Tanggal" v={fmtDate(h.docDate)} />
            <KV k="PT" v={h.ptName ?? h.ptCode ?? '-'} />
            <KV k="TrxCode" v={h.trxCode} />
          </div>
          <strong>Detail · {data.lines.length} baris</strong>
          {data.lines.map((l) => (
            <div key={l.lineNum} className={'card pad-s stack tight' + (!isIn && Number(l.flag) === 1 ? ' green' : '')}>
              <div className="row">
                <span className="mono grow">
                  <strong>{l.itemCode}</strong>
                </span>
                {!isIn && (Number(l.flag) === 1 ? <span className="pill green">MASUK</span> : <span className="pill out">KELUAR</span>)}
              </div>
              <div className="small muted">{[l.itemName, l.brand, l.origin].filter(Boolean).join(' · ')}</div>
              <div className="grid3">
                <KV k={`Qty (${l.uom ?? 'KG'})`} v={fmt(Math.abs(Number(l.qty)))} />
                <KV k="Qty 2 (Sak)" v={fmt(Math.abs(Number(l.qty2)))} />
                <KV k="Qty Palet" v={fmt(Math.abs(Number(l.qtyPalet)))} />
              </div>
            </div>
          ))}
          {status === 'Siap cetak' && (
            <button className="btn" onClick={() => navigate(`/labels/${objType}/${docEntry}`)}>
              <Icon name="print" /> Cetak label QR
            </button>
          )}
        </>
      )}
    </Page>
  );
}
