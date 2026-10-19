// Klien API: cookie sesi HttpOnly (dikirim otomatis, same-origin) + token anti-CSRF di header X-XSRF-TOKEN.
// Tidak ada token yang disimpan di localStorage.

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Row = Record<string, any>;

export class ApiError extends Error {
  status: number;
  errors?: string[];
  constructor(message: string, status: number, errors?: string[]) {
    super(message);
    this.status = status;
    this.errors = errors;
  }
}

let csrf: string | null = null;
let onUnauthorized: () => void = () => {};

export const setCsrf = (t: string | null) => (csrf = t);
export const setUnauthorizedHandler = (fn: () => void) => (onUnauthorized = fn);

async function ensureCsrf() {
  if (csrf) return;
  const r = await fetch('/api/auth/csrf', { credentials: 'same-origin', headers: { Accept: 'application/json' } });
  if (!r.ok) throw new ApiError('Server tidak merespons', r.status);
  csrf = (await r.json()).token;
}

type Opts = { method?: 'GET' | 'POST' | 'PUT' | 'DELETE'; body?: unknown; query?: Record<string, string | number | null | undefined> };

export async function api<T = Row>(path: string, opts: Opts = {}, retry = true): Promise<T> {
  const method = opts.method ?? 'GET';
  const unsafe = method !== 'GET';
  if (unsafe) await ensureCsrf();

  let url = path;
  if (opts.query) {
    const q = new URLSearchParams();
    Object.entries(opts.query).forEach(([k, v]) => {
      if (v !== null && v !== undefined && v !== '') q.set(k, String(v));
    });
    const s = q.toString();
    if (s) url += '?' + s;
  }

  const headers: Record<string, string> = { Accept: 'application/json' };
  if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
  if (unsafe && csrf) headers['X-XSRF-TOKEN'] = csrf;

  let r: Response;
  try {
    r = await fetch(url, {
      method,
      headers,
      credentials: 'same-origin',
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
  } catch {
    throw new ApiError('Tidak bisa terhubung ke server. Cek jaringan.', 0);
  }

  let data: Row | null = null;
  const text = await r.text();
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = null;
    }
  }

  if (r.ok) return data as T;

  if (r.status === 401 && !path.startsWith('/api/auth/web-login')) {
    onUnauthorized();
    throw new ApiError('Sesi berakhir, silakan login ulang', 401);
  }
  // token CSRF kedaluwarsa (mis. setelah server restart) -> ambil ulang sekali
  if (r.status === 400 && unsafe && retry && String(data?.message ?? '').startsWith('Sesi keamanan')) {
    csrf = null;
    return api<T>(path, opts, false);
  }
  if (r.status === 403) throw new ApiError('Anda tidak punya akses untuk fitur ini', 403);
  if (r.status === 429) throw new ApiError(String(data?.message ?? 'Terlalu banyak percobaan, tunggu sebentar'), 429);
  throw new ApiError(String(data?.message ?? `Server error ${r.status}`), r.status, data?.errors as string[] | undefined);
}

export const get = <T = Row>(path: string, query?: Opts['query']) => api<T>(path, { query });
export const post = <T = Row>(path: string, body?: unknown) => api<T>(path, { method: 'POST', body: body ?? {} });
export const put = <T = Row>(path: string, body: unknown) => api<T>(path, { method: 'PUT', body });
