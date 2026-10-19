import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { ApiError, get, type Row } from './api';
import { back } from './router';

// ---------------------------------------------------------------- format
const nf = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 2 });
export const fmt = (v: unknown) => (v === null || v === undefined || v === '' ? '-' : nf.format(Number(v)));
export const fmtDate = (v: unknown) => {
  if (!v) return '-';
  const d = new Date(String(v));
  return isNaN(d.getTime()) ? '-' : d.toLocaleDateString('id-ID', { day: '2-digit', month: '2-digit', year: 'numeric' });
};
export const num = (v: unknown) => {
  const n = Number(String(v ?? '').replace(',', '.'));
  return isFinite(n) ? n : 0;
};
export const todayIso = () => new Date().toISOString().slice(0, 10);
export const isInbound = (objType: unknown) => String(objType) === '6730';

// ---------------------------------------------------------------- ikon (SVG inline, tanpa font ikon eksternal)
const P: Record<string, string> = {
  back: 'M15 5l-7 7 7 7',
  next: 'M9 5l7 7-7 7',
  home: 'M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z',
  in: 'M12 3v11m0 0l-4-4m4 4l4-4M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4',
  out: 'M12 14V3m0 0L8 7m4-4l4 4M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4',
  scan: 'M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10',
  chart: 'M5 20V11M12 20V5M19 20v-7M3 20h18',
  print: 'M7 8V3h10v5M7 17H5a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2M7 14h10v7H7z',
  plus: 'M12 5v14M5 12h14',
  x: 'M6 6l12 12M18 6L6 18',
  check: 'M5 12l5 5 9-10',
  lock: 'M6 11h12v10H6zM8 11V8a4 4 0 0 1 8 0v3',
  cms: 'M4 5h16v10H4zM8 19h8M12 15v4',
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4',
  eye: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
  logout: 'M15 4h4v16h-4M10 8l-4 4 4 4M6 12h10',
  truck: 'M3 6h11v10H3zM14 9h4l3 3v4h-7M7 19.3a1.8 1.8 0 1 0 0-3.6 1.8 1.8 0 0 0 0 3.6zM17 19.3a1.8 1.8 0 1 0 0-3.6 1.8 1.8 0 0 0 0 3.6z',
};
export function Icon({ name, size = 20 }: { name: keyof typeof P | string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={P[name] ?? ''} />
    </svg>
  );
}

// ---------------------------------------------------------------- toast
type ToastMsg = { text: string; err?: boolean } | null;
const ToastCtx = createContext<(text: string, err?: boolean) => void>(() => {});
export function ToastProvider({ children }: { children: ReactNode }) {
  const [msg, setMsg] = useState<ToastMsg>(null);
  useEffect(() => {
    if (!msg) return;
    const t = setTimeout(() => setMsg(null), msg.err ? 5000 : 3000);
    return () => clearTimeout(t);
  }, [msg]);
  const show = useCallback((text: string, err?: boolean) => setMsg({ text, err }), []);
  return (
    <ToastCtx.Provider value={show}>
      {children}
      {msg && (
        <div className={'toast' + (msg.err ? ' err' : '')} role={msg.err ? 'alert' : 'status'}>
          {msg.text}
        </div>
      )}
    </ToastCtx.Provider>
  );
}
export const useToast = () => useContext(ToastCtx);
export const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));

// ---------------------------------------------------------------- layout halaman
export function Page(props: {
  title: string;
  eyebrow?: string;
  accent?: 'in' | 'out' | 'ink';
  backTo?: string;
  actions?: ReactNode;
  extra?: ReactNode;
  footer?: ReactNode;
  footerNote?: ReactNode;
  narrow?: boolean;
  children: ReactNode;
}) {
  const accent = 'accent-' + (props.accent ?? 'in');
  return (
    <div className={accent}>
      <header className="pagehead">
        <div className="titlebar">
          {props.backTo && (
            <button className="back" onClick={() => back(props.backTo!)} aria-label="Kembali">
              <Icon name="back" size={22} />
            </button>
          )}
          <div className="grow">
            {props.eyebrow && <div className="eyebrow">{props.eyebrow}</div>}
            <h1>{props.title}</h1>
          </div>
          {props.actions}
        </div>
        {props.extra && <div className="extra">{props.extra}</div>}
      </header>
      <main className={'content' + (props.footer ? ' with-footer' : '')}>
        <div className={props.narrow ? 'narrow stack' : 'stack'}>{props.children}</div>
      </main>
      {props.footer && (
        <div className="footerbar">
          {props.footerNote && <div className="note">{props.footerNote}</div>}
          {props.footer}
        </div>
      )}
    </div>
  );
}

export const Spinner = () => <div className="spinner" role="progressbar" aria-label="Memuat" />;

export function ErrorBox({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const errs = error instanceof ApiError ? error.errors : undefined;
  return (
    <div className="error" role="alert">
      {errText(error)}
      {errs && errs.length > 0 && (
        <ul>
          {errs.map((e) => (
            <li key={e}>{e}</li>
          ))}
        </ul>
      )}
      {onRetry && (
        <div>
          <button className="btn small ghost" onClick={onRetry}>
            Coba lagi
          </button>
        </div>
      )}
    </div>
  );
}

export function StatusPill({ status }: { status: string }) {
  const cls =
    status === 'Selesai' ? 'green' : status === 'Siap cetak' ? '' : status.startsWith('Menunggu') ? 'amber' : status === 'Open' ? 'amber' : 'grey';
  return <span className={'pill ' + cls}>{status}</span>;
}

export function KV({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="kv">
      <span className="k">{k}</span>
      <span className="v">{v}</span>
    </div>
  );
}

export function Totals({ items }: { items: [string, ReactNode][] }) {
  return (
    <div className="totals">
      {items.map(([k, v]) => (
        <div className="kv" key={k}>
          <span className="k">{k}</span>
          <span className="v">{v}</span>
        </div>
      ))}
    </div>
  );
}

export function Steps({ labels, current }: { labels: string[]; current: number }) {
  return (
    <ol className="steps" aria-label="Langkah">
      {labels.map((l, i) => (
        <li key={l} className={i < current ? 'done' : i === current ? 'on' : ''} aria-current={i === current ? 'step' : undefined}>
          {i + 1} {l}
        </li>
      ))}
    </ol>
  );
}

// ---------------------------------------------------------------- data hook
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError(null);
    fn()
      .then((d) => alive && setData(d))
      .catch((e) => alive && setError(e))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { data, error, loading, reload: () => setTick((t) => t + 1), setData };
}

// ---------------------------------------------------------------- warehouse
export type Warehouse = { whsCode: string; whsName: string; isTitipan: boolean; isDefault: boolean };
export const useWarehouses = () => useLoad(() => get<Warehouse[]>('/api/warehouses'), []);

export function WarehouseSelect(props: { list: Warehouse[]; value: string; onChange: (w: Warehouse) => void; id?: string; allowAll?: boolean }) {
  const cur = props.list.find((w) => w.whsCode === props.value);
  return (
    <div className="inputrow">
      <select
        id={props.id}
        className="input"
        value={props.value}
        onChange={(e) => {
          const w = props.list.find((x) => x.whsCode === e.target.value);
          if (w) props.onChange(w);
          else if (props.allowAll) props.onChange({ whsCode: '', whsName: '', isTitipan: false, isDefault: false });
        }}
      >
        {props.allowAll && <option value="">Semua warehouse</option>}
        {props.list.map((w) => (
          <option key={w.whsCode} value={w.whsCode}>
            {w.whsCode} · {w.whsName}
          </option>
        ))}
      </select>
      {cur?.isTitipan && <span className="pill">TITIPAN</span>}
    </div>
  );
}

// ---------------------------------------------------------------- item search
export type Item = { itemCode: string; itemName: string; groupName: string; uom: string };
export function ItemSearch({ onPick, placeholder }: { onPick: (i: Item) => void; placeholder?: string }) {
  const [q, setQ] = useState('');
  const [list, setList] = useState<Item[]>([]);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (q.trim().length < 2) {
      setList([]);
      return;
    }
    const t = setTimeout(() => {
      get<Item[]>('/api/items', { q: q.trim() })
        .then((l) => {
          setList(l);
          setOpen(true);
        })
        .catch(() => setList([]));
    }, 250);
    return () => clearTimeout(t);
  }, [q]);
  return (
    <div className="stack tight">
      <input
        className="input mono"
        value={q}
        maxLength={50}
        placeholder={placeholder ?? 'Ketik kode / nama item'}
        onChange={(e) => setQ(e.target.value.toUpperCase())}
        onFocus={() => setOpen(true)}
        aria-label="Cari item"
        autoComplete="off"
      />
      {open && list.length > 0 && (
        <div className="card pad-s stack tight" role="listbox">
          {list.map((i) => (
            <button
              key={i.itemCode}
              type="button"
              className="list-item"
              role="option"
              aria-selected="false"
              onClick={() => {
                onPick(i);
                setQ(i.itemCode);
                setOpen(false);
              }}
            >
              <span className="grow">
                <span className="mono">{i.itemCode}</span>
                <br />
                <span className="small muted">
                  {i.itemName} · {i.groupName}
                </span>
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export const useBrands = () => useLoad(() => get<string[]>('/api/brands'), []);

/** Baris barang (inbound / Item Inbound KR-RP). */
export type Line = { itemCode: string; itemName: string; groupName: string; uom: string; brand: string; origin: string; qty: number; qty2: number; qtyPalet: number };

export function LineForm({ onAdd, sakLabel = 'Karung', accent = 'in' }: { onAdd: (l: Line) => void; sakLabel?: string; accent?: 'in' | 'green' }) {
  const brands = useBrands();
  const [item, setItem] = useState<Item | null>(null);
  const [key, setKey] = useState(0);
  const [uom, setUom] = useState('KG');
  const [brand, setBrand] = useState('');
  const [origin, setOrigin] = useState('');
  const [qty, setQty] = useState('');
  const [qty2, setQty2] = useState('');
  const [palet, setPalet] = useState('');
  const [err, setErr] = useState('');

  const add = () => {
    if (!item) return setErr('Pilih Item Code dulu');
    if (num(qty) <= 0) return setErr(`Qty (${uom}) harus diisi`);
    if (num(qty2) <= 0) return setErr(`Qty 2 (${sakLabel}) harus diisi`);
    if (num(palet) <= 0) return setErr('Qty Palet harus diisi');
    onAdd({ ...item, uom, brand, origin: origin.trim(), qty: num(qty), qty2: num(qty2), qtyPalet: num(palet) });
    setItem(null);
    setKey((k) => k + 1);
    setQty('');
    setQty2('');
    setPalet('');
    setErr('');
  };

  return (
    <div className="card stack">
      <div className="field">
        <span className="label">
          Item Code <span className="req">*</span>
        </span>
        <ItemSearch key={key} onPick={setItem} />
        {item && (
          <span className="hint">
            {item.itemName} · Grup: {item.groupName}
          </span>
        )}
      </div>
      <div className="grid3">
        <label className="field">
          <span className="label">UOM</span>
          <select className="input mono" value={uom} onChange={(e) => setUom(e.target.value)}>
            <option>KG</option>
            <option>TON</option>
          </select>
        </label>
        <label className="field">
          <span className="label">Brand</span>
          <select className="input" value={brand} onChange={(e) => setBrand(e.target.value)}>
            <option value="">-</option>
            {(brands.data ?? []).map((b) => (
              <option key={b}>{b}</option>
            ))}
          </select>
        </label>
        <label className="field">
          <span className="label">Origin</span>
          <input className="input" value={origin} maxLength={100} onChange={(e) => setOrigin(e.target.value)} />
        </label>
      </div>
      <div className="grid3">
        <label className="field">
          <span className="label">
            Qty <span className="muted">({uom})</span>
          </span>
          <input className="input num" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} />
        </label>
        <label className="field">
          <span className="label">
            Qty 2 <span className="muted">({sakLabel})</span>
          </span>
          <input className="input num" inputMode="numeric" value={qty2} onChange={(e) => setQty2(e.target.value)} />
        </label>
        <label className="field">
          <span className="label">Qty Palet</span>
          <input className="input num" inputMode="numeric" value={palet} onChange={(e) => setPalet(e.target.value)} />
        </label>
      </div>
      {err && <div className="error">{err}</div>}
      <button type="button" className={'btn' + (accent === 'green' ? ' green' : '')} onClick={add}>
        <Icon name="plus" /> Tambah baris
      </button>
    </div>
  );
}

export function LineRow({ l, onDelete, badge, sak = 'krg' }: { l: Line | Row; onDelete?: () => void; badge?: ReactNode; sak?: string }) {
  return (
    <div className="list-item">
      {badge}
      <div className="grow">
        <div className="mono">{l.itemCode}</div>
        <div className="small muted">{[l.itemName, l.brand, l.origin].filter(Boolean).join(' · ')}</div>
      </div>
      <div className="num">
        {fmt(l.qty)} {l.uom ?? 'KG'}
        {'\n'}
        {fmt(l.qty2)} {sak} · {fmt(l.qtyPalet)} plt
      </div>
      {onDelete && (
        <button className="iconbtn" onClick={onDelete} aria-label={`Hapus ${l.itemCode}`}>
          <Icon name="x" />
        </button>
      )}
    </div>
  );
}
