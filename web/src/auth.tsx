import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { ApiError, get, post, setCsrf, setUnauthorizedHandler } from './api';

export type User = {
  userId: number;
  userCode: string;
  name: string;
  bplId: number;
  defaultWhs: string;
  roles: string[];
};

type Ctx = {
  user: User | null;
  ready: boolean;
  isAdmin: boolean;
  login: (userCode: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
};

const AuthCtx = createContext<Ctx | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    setUnauthorizedHandler(() => {
      setCsrf(null);
      setUser(null);
    });
    get<User>('/api/auth/me')
      .then(setUser)
      .catch(() => setUser(null))
      .finally(() => setReady(true));
  }, []);

  const login = useCallback(async (userCode: string, password: string) => {
    const r = await post<{ user: User; csrf: string }>('/api/auth/web-login', { userCode, password });
    setCsrf(r.csrf);
    setUser(r.user);
  }, []);

  const logout = useCallback(async () => {
    try {
      await post('/api/auth/logout');
    } catch (e) {
      if (!(e instanceof ApiError)) throw e;
    }
    setCsrf(null);
    setUser(null);
  }, []);

  return (
    <AuthCtx.Provider value={{ user, ready, isAdmin: !!user?.roles.includes('Admin'), login, logout }}>{children}</AuthCtx.Provider>
  );
}

export function useAuth(): Ctx {
  const c = useContext(AuthCtx);
  if (!c) throw new Error('AuthProvider belum dipasang');
  return c;
}
