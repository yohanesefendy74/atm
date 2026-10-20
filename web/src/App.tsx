import type { ReactNode } from 'react';
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
import LabelPrint from './pages/Labels';
import { KpiReport, ReportsMenu, StockCardReport, StockContainerReport, StockItemReport } from './pages/Reports';
import { CmsDetail, CmsList } from './pages/Cms';

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
  if (path === '/reports/stock-card') return <StockCardReport />;
  if (path === '/reports/kpi') return <KpiReport />;
  if (path === '/admin/plan') return isAdmin ? <PlanList /> : <Forbidden />;
  if (path === '/admin/plan/baru') return isAdmin ? <PlanNew /> : <Forbidden />;
  const pp = match('/admin/plan/:id', path);
  if (pp) return isAdmin ? <PlanDetail id={pp.id} /> : <Forbidden />;
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
            <Link to="/admin/plan" current={on('/admin/plan')}>Rencana SPBB / SPMB</Link>
            <Link to="/admin/jadwal" current={on('/admin/jadwal')}>Jadwal</Link>
            <Link to="/admin/surat-jalan" current={on('/admin/surat-jalan')}>Surat Jalan</Link>
            <Link to="/admin/kendaraan" current={on('/admin/kendaraan')}>Kendaraan & Berat</Link>
            <Link to="/admin/master" current={on('/admin/master')}>Master Data</Link>
            <Link to="/admin/setup" current={on('/admin/setup')}>Setup</Link>
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
        <Link to="/reports" current={on('/reports')}>
          <Icon name="chart" size={22} />
          Laporan
        </Link>
      </nav>
    </div>
  );
}
