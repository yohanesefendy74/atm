import { useState } from 'react';
import { get, type Row } from '../api';
import { Link } from '../router';
import { ErrorBox, Icon, ItemSearch, KV, Page, Spinner, Totals, WarehouseSelect, fmt, fmtDate, useLoad, useWarehouses, type Item } from '../ui';

export function ReportsMenu() {
  const items: [string, string, string, string][] = [
    ['/reports/stock-card', 'Kartu Stok', 'Mutasi masuk/keluar per item + saldo berjalan', 'chart'],
    ['/reports/stock-item', 'Stock per Barang', 'Saldo KG, sak, palet per item', 'in'],
    ['/reports/stock-container', 'Stock per Container', 'Saldo per container & item', 'scan'],
    ['/reports/kpi', 'KPI Gudang', 'Jumlah dokumen, tonase & palet keluar-masuk', 'truck'],
  ];
  return (
    <Page eyebrow="Laporan" title="Kartu Stock Gudang" narrow>
      {items.map(([to, t, s, ic]) => (
        <Link key={to} to={to} className="card click row">
          <span className="pill">
            <Icon name={ic} />
          </span>
          <span className="grow">
            <strong>{t}</strong>
            <div className="small muted">{s}</div>
          </span>
          <Icon name="next" />
        </Link>
      ))}
      <p className="hint">Stok dihitung dari dokumen yang sudah diposting Admin (status Close).</p>
    </Page>
  );
}

function WhsFilter({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const whs = useWarehouses();
  return <WarehouseSelect list={whs.data ?? []} value={value} allowAll onChange={(w) => onChange(w.whsCode)} />;
}

export function StockItemReport() {
  const [whs, setWhs] = useState('');
  const { data, error, reload } = useLoad(() => get<Row[]>('/api/reports/stock-item', { whsCode: whs }), [whs]);
  const sum = (k: string) => (data ?? []).reduce((s, r) => s + Number(r[k] ?? 0), 0);
  return (
    <Page eyebrow="Laporan" title="Stock per Barang" backTo="/reports" extra={<WhsFilter value={whs} onChange={setWhs} />}>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {!data && error === null && <Spinner />}
      {data && (
        <>
          <Totals items={[['Total KG', fmt(sum('kg'))], ['Total sak', fmt(sum('sak'))], ['Total palet', fmt(sum('palet'))]]} />
          <table className="table cards">
            <thead>
              <tr>
                <th>Item</th>
                <th className="num">KG</th>
                <th className="num">Sak</th>
                <th className="num">Palet</th>
                <th className="num">Container</th>
              </tr>
            </thead>
            <tbody>
              {data.map((r) => (
                <tr key={r.itemCode}>
                  <td data-label="Item">
                    <span className="mono">{r.itemCode}</span> · {r.itemName}
                  </td>
                  <td className="num" data-label="KG">{fmt(r.kg)}</td>
                  <td className="num" data-label="Sak">{fmt(r.sak)}</td>
                  <td className="num" data-label="Palet">{fmt(r.palet)}</td>
                  <td className="num" data-label="Container">{fmt(r.containers)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {data.length === 0 && <div className="empty">Tidak ada stok</div>}
        </>
      )}
    </Page>
  );
}

export function StockContainerReport() {
  const [whs, setWhs] = useState('');
  const { data, error, reload } = useLoad(() => get<Row[]>('/api/reports/stock-container', { whsCode: whs }), [whs]);
  return (
    <Page eyebrow="Laporan" title="Stock per Container" backTo="/reports" extra={<WhsFilter value={whs} onChange={setWhs} />}>
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {!data && error === null && <Spinner />}
      {data && (
        <table className="table cards">
          <thead>
            <tr>
              <th>Container</th>
              <th>Item</th>
              <th>Masuk</th>
              <th className="num">KG</th>
              <th className="num">Sak</th>
              <th className="num">Palet</th>
            </tr>
          </thead>
          <tbody>
            {data.map((r) => (
              <tr key={`${r.containerNo}-${r.itemCode}`}>
                <td data-label="Container" className="mono">
                  <strong>{r.containerNo ?? 'tanpa kontainer'}</strong>
                </td>
                <td data-label="Item">
                  <span className="mono">{r.itemCode}</span> · {r.itemName} {r.brand ? `· ${r.brand}` : ''}
                </td>
                <td data-label="Masuk">{fmtDate(r.inboundDate)}</td>
                <td className="num" data-label="KG">{fmt(r.kg)}</td>
                <td className="num" data-label="Sak">{fmt(r.sak)}</td>
                <td className="num" data-label="Palet">{fmt(r.palet)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {data && data.length === 0 && <div className="empty">Tidak ada stok</div>}
    </Page>
  );
}

export function StockCardReport() {
  const [whs, setWhs] = useState('');
  const [item, setItem] = useState<Item | null>(null);
  const [cont, setCont] = useState('');
  const [contQ, setContQ] = useState('');
  const { data, error, reload } = useLoad(
    () => (item ? get<Row[]>('/api/reports/stock-card', { itemCode: item.itemCode, whsCode: whs, containerNo: contQ }) : Promise.resolve(null)),
    [item?.itemCode, whs, contQ],
  );
  const last = data && data.length ? data[data.length - 1] : null;
  return (
    <Page
      eyebrow="Laporan"
      title="Kartu Stok"
      backTo="/reports"
      extra={
        <div className="stack tight">
          <ItemSearch onPick={setItem} placeholder="Cari item" />
          <div className="grid2">
            <WhsFilter value={whs} onChange={setWhs} />
            <form
              onSubmit={(e) => {
                e.preventDefault();
                setContQ(cont.trim());
              }}
            >
              <input className="input mono" placeholder="Container (opsional) + Enter" value={cont} maxLength={13} onChange={(e) => setCont(e.target.value.toUpperCase())} />
            </form>
          </div>
        </div>
      }
    >
      {!item && <div className="empty">Pilih item untuk melihat kartu stok</div>}
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {item && !data && error === null && <Spinner />}
      {last && <Totals items={[['Saldo KG', fmt(last.saldoKg)], ['Saldo sak', fmt(last.saldoSak)], ['Saldo palet', fmt(last.saldoPalet)]]} />}
      {data && (
        <table className="table cards">
          <thead>
            <tr>
              <th>Tanggal</th>
              <th>Dokumen</th>
              <th>Container</th>
              <th className="num">Mutasi KG</th>
              <th className="num">Mutasi sak</th>
              <th className="num">Saldo KG</th>
            </tr>
          </thead>
          <tbody>
            {data.map((r, i) => (
              <tr key={i}>
                <td data-label="Tanggal">{fmtDate(r.docDate)}</td>
                <td data-label="Dokumen" className="mono">
                  {r.trxCode} {r.docEntry}
                </td>
                <td data-label="Container" className="mono">{r.containerNo ?? '-'}</td>
                <td className="num" data-label="Mutasi KG">
                  {Number(r.kg) > 0 ? '+' : ''}
                  {fmt(r.kg)}
                </td>
                <td className="num" data-label="Mutasi sak">{fmt(r.sak)}</td>
                <td className="num" data-label="Saldo KG">{fmt(r.saldoKg)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {data && data.length === 0 && <div className="empty">Belum ada mutasi</div>}
    </Page>
  );
}

export function KpiReport() {
  const [whs, setWhs] = useState('');
  const [range, setRange] = useState(7);
  const to = new Date();
  const from = range === 0 ? new Date(to.getFullYear(), to.getMonth(), 1) : new Date(to.getTime() - (range - 1) * 86400000);
  const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const { data, error, reload } = useLoad(() => get<Row>('/api/reports/kpi', { from: iso(from), to: iso(to), whsCode: whs }), [whs, range]);
  const tiles: [string, string, string][] = [
    ['Dok inbound', 'inboundDocs', 'accent-in'],
    ['Dok outbound', 'outboundDocs', 'accent-out'],
    ['KG masuk', 'kgIn', 'accent-in'],
    ['KG keluar', 'kgOut', 'accent-out'],
    ['Palet masuk', 'paletIn', 'accent-in'],
    ['Palet keluar', 'paletOut', 'accent-out'],
    ['Belum diposting', 'openDocs', 'accent-ink'],
    ['Menunggu PT', 'waitingPt', 'accent-ink'],
  ];
  return (
    <Page
      eyebrow="Laporan"
      title="KPI Gudang"
      backTo="/reports"
      extra={
        <div className="stack tight">
          <WhsFilter value={whs} onChange={setWhs} />
          <div className="chips" role="group" aria-label="Periode">
            {[
              [1, 'Hari ini'],
              [7, '7 hari'],
              [0, 'Bulan ini'],
            ].map(([v, l]) => (
              <button key={l} className="chip" aria-pressed={range === v} onClick={() => setRange(Number(v))}>
                {l}
              </button>
            ))}
          </div>
        </div>
      }
    >
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      {!data && error === null && <Spinner />}
      {data && (
        <div className="grid2">
          {tiles.map(([label, key, cls]) => (
            <div key={key} className={'card stat ' + cls}>
              <div className="eyebrow">{label}</div>
              <div className="n">{fmt(data[key])}</div>
            </div>
          ))}
        </div>
      )}
      <KV k="Periode" v={`${fmtDate(from)} – ${fmtDate(to)}`} />
    </Page>
  );
}
