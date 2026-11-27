import { useState, type FormEvent } from 'react';
import { ApiError } from '../api';
import { useAuth } from '../auth';
import { ErrorBox, Icon } from '../ui';

export default function Login() {
  const { login } = useAuth();
  const [userCode, setUserCode] = useState('');
  const [password, setPassword] = useState('');
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!userCode.trim() || !password) return setError(new Error('UserName dan Password wajib diisi'));
    setBusy(true);
    setError(null);
    try {
      try {
        await login(userCode.trim(), password);
      } catch (err) {
        // Satu user satu sesi: masih login di perangkat lain -> tanya dulu sebelum mengeluarkan perangkat itu
        if (err instanceof ApiError && err.status === 409) {
          if (!confirm(`${err.message}\n\nLanjutkan login di sini?`)) { setBusy(false); return; }
          await login(userCode.trim(), password, true);
        } else throw err;
      }
    } catch (err) {
      setError(err);
      setPassword('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login">
      <form onSubmit={submit} autoComplete="on" noValidate>
        <img src="/logo.png" alt="Level UP" />
        <div className="lrow">
          <label htmlFor="u">UserName</label>
          <input id="u" className="input" value={userCode} maxLength={50} autoComplete="username" autoCapitalize="none" onChange={(e) => setUserCode(e.target.value)} />
        </div>
        <div className="lrow">
          <label htmlFor="p">Password</label>
          <div className="pw">
            <input
              id="p"
              className="input"
              type={show ? 'text' : 'password'}
              value={password}
              maxLength={128}
              autoComplete="current-password"
              placeholder="Password"
              onChange={(e) => setPassword(e.target.value)}
            />
            <button type="button" onClick={() => setShow(!show)} aria-label={show ? 'Sembunyikan password' : 'Tampilkan password'}>
              <Icon name="eye" />
            </button>
          </div>
        </div>
        {error !== null && <ErrorBox error={error} />}
        <button className="btn danger" type="submit" disabled={busy}>
          {busy ? 'Memeriksa…' : 'Login'}
        </button>
        <button className="btn navy" type="button" onClick={() => setError(new Error('Ganti password dilakukan oleh Admin di ERP.'))}>
          Change Password
        </button>
        <p className="hint">
          Koneksi terenkripsi (HTTPS). Akun terkunci 15 menit setelah 5x salah password.
        </p>
      </form>
    </div>
  );
}
