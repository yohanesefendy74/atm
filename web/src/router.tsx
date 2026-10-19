import { useSyncExternalStore, type MouseEvent, type ReactNode } from 'react';

// Router kecil berbasis History API (tanpa dependensi). Server mengembalikan index.html untuk semua path non-/api.
const EVT = 'gudang:navigate';

export function navigate(to: string, replace = false) {
  if (to === location.pathname + location.search) return;
  if (replace) history.replaceState(null, '', to);
  else history.pushState(null, '', to);
  window.dispatchEvent(new Event(EVT));
  window.scrollTo(0, 0);
}

function subscribe(cb: () => void) {
  window.addEventListener('popstate', cb);
  window.addEventListener(EVT, cb);
  return () => {
    window.removeEventListener('popstate', cb);
    window.removeEventListener(EVT, cb);
  };
}

export function usePath(): string {
  return useSyncExternalStore(subscribe, () => location.pathname);
}

export function useQuery(): URLSearchParams {
  const s = useSyncExternalStore(subscribe, () => location.search);
  return new URLSearchParams(s);
}

/** Cocokkan pola seperti /docs/:objType/:docEntry. */
export function match(pattern: string, path: string): Record<string, string> | null {
  const p = pattern.split('/').filter(Boolean);
  const a = path.split('/').filter(Boolean);
  if (p.length !== a.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < p.length; i++) {
    if (p[i].startsWith(':')) params[p[i].slice(1)] = decodeURIComponent(a[i]);
    else if (p[i] !== a[i]) return null;
  }
  return params;
}

export function Link(props: { to: string; className?: string; children: ReactNode; current?: boolean; label?: string }) {
  const onClick = (e: MouseEvent<HTMLAnchorElement>) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    navigate(props.to);
  };
  return (
    <a href={props.to} className={props.className} onClick={onClick} aria-current={props.current ? 'page' : undefined} aria-label={props.label}>
      {props.children}
    </a>
  );
}

export function back(fallback: string) {
  if (history.length > 1) history.back();
  else navigate(fallback);
}
