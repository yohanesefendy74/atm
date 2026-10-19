import { useState, type FormEvent } from 'react';
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
      await login(userCode.trim(), password);
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
        <button className="btn navy" type="button" onClick={() => setError(new Error('Ganti password dilakukan oleh Admin di SAP.'))}>
          Change Password
        </button>
        <p className="hint">
          Koneksi terenkripsi (HTTPS). Akun terkunci 15 menit setelah 5x salah password.
        </p>
      </form>
    </div>
  );
}
