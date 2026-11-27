import { useEffect, useState, type ReactNode } from 'react';
import { useAuth } from './auth';
import { AdminMaster, AdminSetup } from './pages/AdminMaster';
import { PlanDetail, PlanList, PlanNew } from './pages/AdminRencana';
import { AdminJadwal, AdminKendaraan, AdminSuratJalan } from './pages/AdminOps';
import { Link, match, navigate, usePath } from './router';
import { Icon, Spinner } from './ui';
import Login from './pages/Login';
import Home from './pages/Home';
import { DocDetail, DocList } from './pages/Docs';
import InboundNew from './pages/Inbound';
import OutboundNew from './pages/Outbound';
import LabelPrint, { PlanLabelPrint } from './pages/Labels';
import { KpiReport, ReportsMenu, StockCardReport, StockContainerReport, StockItemReport, StockRuanganReport } from './pages/Reports';
import { CmsDetail, CmsList } from './pages/Cms';
import { OpnameDetail, OpnameList, OpnameRakLabels } from './pages/Opname';

function Forbidden() {
  return (
    <div className="content">
      <div className="error">Halaman ini khusus Admin.</div>
    </div>
  );
}

function route(path: string, isAdmin: boolean): ReactNode {
  if (path === '/') return <Home />;
  if (path === '/inbound') return <DocList kind="inbound" />;
  if (path === '/inbound/new') return <InboundNew />;
  if (path === '/outbound') return <DocList kind="outbound" />;
  if (path === '/outbound/new') return <OutboundNew />;
  let p = match('/docs/:objType/:docEntry', path);
  if (p) return <DocDetail objType={p.objType} docEntry={p.docEntry} />;
  p = match('/labels/:objType/:docEntry', path);
  if (p) return <LabelPrint objType={p.objType} docEntry={p.docEntry} />;
  if (path === '/reports') return <ReportsMenu />;
  if (path === '/reports/stock-item') return <StockItemReport />;
  if (path === '/reports/stock-container') return <StockContainerReport />;
  if (path === '/reports/stock-ruangan') return <StockRuanganReport />;
  if (path === '/reports/stock-card') return <StockCardReport />;
  if (path === '/reports/kpi') return <KpiReport />;
  if (path === '/admin/plan') return isAdmin ? <PlanList /> : <Forbidden />;
  if (path === '/admin/plan/baru') return isAdmin ? <PlanNew /> : <Forbidden />;
  const pl = match('/admin/plan/:id/labels', path);
  if (pl) return isAdmin ? <PlanLabelPrint planId={pl.id} /> : <Forbidden />;
  const pp = match('/admin/plan/:id', path);
  if (pp) return isAdmin ? <PlanDetail id={pp.id} /> : <Forbidden />;
  if (path === '/admin/opname') return isAdmin ? <OpnameList /> : <Forbidden />;
  const ob = match('/admin/opname/:id/barcode', path);
  if (ob) return isAdmin ? <OpnameRakLabels id={ob.id} /> : <Forbidden />;
  const od = match('/admin/opname/:id', path);
  if (od) return isAdmin ? <OpnameDetail id={od.id} /> : <Forbidden />;
  if (path === '/admin/jadwal') return isAdmin ? <AdminJadwal /> : <Forbidden />;
  if (path === '/admin/surat-jalan') return isAdmin ? <AdminSuratJalan /> : <Forbidden />;
  if (path === '/admin/kendaraan') return isAdmin ? <AdminKendaraan /> : <Forbidden />;
  if (path === '/admin/master') return isAdmin ? <AdminMaster /> : <Forbidden />;
  if (path === '/admin/setup') return isAdmin ? <AdminSetup /> : <Forbidden />;
  if (path === '/cms') return isAdmin ? <CmsList /> : <Forbidden />;
  p = match('/cms/:objType/:docEntry', path);
  if (p) return isAdmin ? <CmsDetail objType={p.objType} docEntry={p.docEntry} /> : <Forbidden />;
  return (
    <div className="content">
      <div className="empty">Halaman tidak ditemukan</div>
    </div>
  );
}

export default function App() {
  const { user, ready, isAdmin, logout } = useAuth();
  const path = usePath();

  if (!ready) return <Spinner />;
  if (!user) return <Login />;

  const on = (prefix: string) => (prefix === '/' ? path === '/' : path === prefix || path.startsWith(prefix + '/'));
  const outActive = on('/outbound');
  return <Shell path={path} on={on} outActive={outActive} isAdmin={isAdmin} user={user} logout={logout} />;
}

const ADMIN_LINKS: [string, string][] = [
  ['/cms', 'CMS · Cek input krani'],
  ['/admin/plan', 'Rencana SPBB / SPMB'],
  ['/admin/opname', 'Stock Opname'],
  ['/admin/jadwal', 'Jadwal'],
  ['/admin/surat-jalan', 'Surat Jalan'],
  ['/admin/kendaraan', 'Kendaraan & Berat'],
  ['/admin/master', 'Master Data'],
  ['/admin/setup', 'Setup'],
];

function Shell({ path, on, outActive, isAdmin, user, logout }: {
  path: string; on: (p: string) => boolean; outActive: boolean; isAdmin: boolean;
  user: { name: string; userCode: string }; logout: () => Promise<unknown>;
}) {
  // Di HP sidebar disembunyikan: semua menu (termasuk Admin) ada di tombol "Menu" bar bawah
  const [menu, setMenu] = useState(false);
  useEffect(() => setMenu(false), [path]);
  useEffect(() => {
    if (!menu) return;
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && setMenu(false);
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [menu]);

  return (
    <div className="shell">
      <nav className="sidebar" aria-label="Menu utama">
        <img src="/logo.png" alt="Level UP" />
        <div className="sect">Krani</div>
        <Link to="/" current={on('/')}>
          <Icon name="home" /> Beranda
        </Link>
        <Link to="/inbound" current={on('/inbound')}>
          <Icon name="in" /> Inbound
        </Link>
        <Link to="/outbound" current={on('/outbound')}>
          <Icon name="out" /> Outbound
        </Link>
        <Link to="/reports" current={on('/reports')}>
          <Icon name="chart" /> Laporan
        </Link>
        {isAdmin && (
          <>
            <div className="sect">Admin</div>
            <Link to="/cms" current={on('/cms')}>
              <Icon name="cms" /> CMS · Cek input krani
            </Link>
            {ADMIN_LINKS.slice(1).map(([to, label]) => <Link key={to} to={to} current={on(to)}>{label}</Link>)}
          </>
        )}
        <div className="who">
          <div>{user.name}</div>
          <div className="mono small">
            {user.userCode} · {isAdmin ? 'Admin' : 'Krani'}
          </div>
          <button className="btn small ghost" onClick={() => logout().then(() => navigate('/', true))}>
            <Icon name="logout" size={16} /> Logout
          </button>
        </div>
      </nav>

      <div className="main">{route(path, isAdmin)}</div>

      <nav className="bottomnav" aria-label="Navigasi utama">
        <Link to="/" current={on('/')}>
          <Icon name="home" size={22} />
          Beranda
        </Link>
        <Link to="/inbound" current={on('/inbound')}>
          <Icon name="in" size={22} />
          Inbound
        </Link>
        <Link to="/outbound/new" className="scan" label="Scan QR palet">
          <Icon name="scan" size={26} />
        </Link>
        <Link to={isAdmin ? '/cms' : '/outbound'} className="out" current={isAdmin ? on('/cms') : outActive}>
          <Icon name={isAdmin ? 'cms' : 'out'} size={22} />
          {isAdmin ? 'CMS' : 'Outbound'}
        </Link>
        <button type="button" className="menubtn" aria-expanded={menu} aria-controls="menu-hp" onClick={() => setMenu(!menu)}>
          <Icon name="menu" size={22} />
          Menu
        </button>
      </nav>

      {menu && (
        <div className="sheet-backdrop" onClick={() => setMenu(false)}>
          <nav id="menu-hp" className="sheet" aria-label="Semua menu" onClick={(e) => e.stopPropagation()}>
            <div className="sheet-head">
              <div><strong>{user.name}</strong><div className="small muted mono">{user.userCode} · {isAdmin ? 'Admin' : 'Krani'}</div></div>
              <button type="button" className="btn small ghost" onClick={() => setMenu(false)}>Tutup</button>
            </div>
            <div className="sect">Krani</div>
            <Link to="/" current={on('/')}><Icon name="home" /> Beranda</Link>
            <Link to="/inbound" current={on('/inbound')}><Icon name="in" /> Inbound</Link>
            <Link to="/outbound" current={outActive}><Icon name="out" /> Outbound</Link>
            <Link to="/reports" current={on('/reports')}><Icon name="chart" /> Laporan</Link>
            {isAdmin && (
              <>
                <div className="sect">Admin</div>
                {ADMIN_LINKS.map(([to, label]) => <Link key={to} to={to} current={on(to)}>{label}</Link>)}
              </>
            )}
            <button type="button" className="btn small ghost logout" onClick={() => logout().then(() => navigate('/', true))}>
              <Icon name="logout" size={16} /> Logout
            </button>
          </nav>
        </div>
      )}
    </div>
  );
}
