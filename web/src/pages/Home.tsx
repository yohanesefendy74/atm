import { get, type Row } from '../api';
import { useAuth } from '../auth';
import { Link } from '../router';
import { ErrorBox, Icon, Page, StatusPill, fmt, isInbound, useLoad } from '../ui';

export default function Home() {
  const { user, isAdmin } = useAuth();
  const { data, error, reload } = useLoad(
    () => Promise.all([get<Row[]>('/api/docs', { kind: 'inbound' }), get<Row[]>('/api/docs', { kind: 'outbound' })]),
    [],
  );
  const [ins, outs] = data ?? [[], []];
  const today = new Date().toDateString();
  const isToday = (d: Row) => new Date(String(d.docDate)).toDateString() === today;
  const ready = [...ins, ...outs].filter((d) => d.status === 'Siap cetak').length;
  const recent = [...ins, ...outs].sort((a, b) => Number(b.docEntry) - Number(a.docEntry)).slice(0, 6);
  const h = new Date().getHours();
  const greet = h < 11 ? 'Selamat pagi' : h < 15 ? 'Selamat siang' : h < 18 ? 'Selamat sore' : 'Selamat malam';

  return (
    <Page eyebrow="Gudang ATM" title={`${greet}, ${user?.name ?? ''}`} accent="ink">
      {error !== null && <ErrorBox error={error} onRetry={reload} />}
      <div className="grid2">
        <div className="card stat accent-in">
          <div className="eyebrow">Inbound hari ini</div>
          <div className="n">{ins.filter(isToday).length}</div>
          <div className="small muted">{ins.filter((d) => d.status === 'Menunggu PT').length} menunggu PT</div>
        </div>
        <div className="card stat accent-out">
          <div className="eyebrow">Outbound hari ini</div>
          <div className="n">{outs.filter(isToday).length}</div>
          <div className="small muted">{outs.filter((d) => d.status === 'Menunggu DO').length} menunggu DO</div>
        </div>
      </div>
      <div className="cardgrid">
        <Link to="/inbound/new" className="action in">
          <span className="ic">
            <Icon name="in" size={24} />
          </span>
          <span className="grow">
            <div className="t">Terima Barang</div>
            <div className="s">Inbound · header & detail barang</div>
          </span>
        </Link>
        <Link to="/outbound/new" className="action out">
          <span className="ic">
            <Icon name="out" size={24} />
          </span>
          <span className="grow">
            <div className="t">Kirim Barang</div>
            <div className="s">Outbound OB / KR / RP · scan palet</div>
          </span>
        </Link>
      </div>
      <div className="cardgrid">
        <Link to="/inbound?status=Siap%20cetak" className="card click row">
          <Icon name="print" /> <span className="grow">Cetak label QR</span> <span className="pill">{ready}</span>
        </Link>
        {isAdmin ? (
          <Link to="/cms" className="card click row">
            <Icon name="cms" /> <span className="grow">CMS · cek input krani</span>
          </Link>
        ) : (
          <Link to="/reports/stock-container" className="card click row">
            <Icon name="chart" /> <span className="grow">Cek stok per container</span>
          </Link>
        )}
      </div>
      <div className="card stack tight">
        <strong>Aktivitas terakhir</strong>
        {recent.length === 0 && <span className="muted">Belum ada dokumen</span>}
        {recent.map((d) => (
          <Link key={`${d.objType}-${d.docEntry}`} to={`/docs/${d.objType}/${d.docEntry}`} className="row list-item">
            <span className={isInbound(d.objType) ? 'pill' : 'pill out'}>{d.trxCode}</span>
            <span className="grow">
              <div className="mono">{d.docEntry}</div>
              <div className="small muted mono">
                {fmt(d.qtyKg)} KG · {fmt(d.qtySak)} sak
              </div>
            </span>
            <StatusPill status={String(d.status)} />
          </Link>
        ))}
      </div>
    </Page>
  );
}
