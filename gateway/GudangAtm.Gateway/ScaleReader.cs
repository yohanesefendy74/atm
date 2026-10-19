using System.IO.Ports;
using System.Net.Sockets;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace GudangAtm.Gateway;

public record Reading(decimal Kg, bool Stabil, DateTime At);

/// Membaca indikator timbangan lewat RS232 terus-menerus di latar belakang; permintaan timbang mengambil pembacaan terbaru yang stabil.
public sealed class ScaleReader : IDisposable
{
    readonly ScaleOptions o;
    readonly ILogger log;
    readonly Regex pat, stabilPat;
    readonly object gate = new();
    readonly List<Reading> recent = new();
    Stream? stream;
    TcpClient? tcp;
    bool Tcp => o.Mode.Equals("Tcp", StringComparison.OrdinalIgnoreCase);
    string Tujuan => Tcp ? $"{o.Host}:{o.TcpPort}" : o.Port;
    CancellationTokenSource? cts;
    public string? LastError { get; private set; }

    public ScaleReader(ScaleOptions o, ILogger log)
    {
        this.o = o; this.log = log;
        pat = new Regex(o.Pattern, RegexOptions.Compiled);
        stabilPat = new Regex(string.IsNullOrEmpty(o.StabilPattern) ? "(?!)" : o.StabilPattern, RegexOptions.Compiled);
    }

    public static string Unescape(string s) => s.Replace("\\r", "\r").Replace("\\n", "\n").Replace("\\t", "\t");

    public void Start()
    {
        cts = new CancellationTokenSource();
        _ = Task.Run(() => Loop(cts.Token));
    }

    async Task Loop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (Tcp)
                {
                    tcp = new TcpClient();
                    tcp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                    using var cc = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    cc.CancelAfter(TimeSpan.FromSeconds(8));
                    await tcp.ConnectAsync(o.Host, o.TcpPort, cc.Token);
                    stream = tcp.GetStream();
                }
                else
                {
                    port = new SerialPort(o.Port, o.Baud, Enum.Parse<Parity>(o.Parity, true), o.DataBits, Enum.Parse<StopBits>(o.StopBits, true))
                    { ReadTimeout = 2000, WriteTimeout = 2000, Encoding = Encoding.ASCII };
                    port.Open();
                    stream = port.BaseStream;
                }
                LastError = null;
                log.LogInformation("Timbangan {Kode}: {T} terhubung", o.Kode, Tujuan);
                var buf = new byte[256];
                var line = new StringBuilder();
                while (!ct.IsCancellationRequested)
                {
                    int n;
                    try { n = await stream.ReadAsync(buf, 0, buf.Length, ct); }
                    catch (TimeoutException) { continue; }
                    if (n == 0) throw new IOException("Koneksi ditutup oleh alat");
                    for (int i = 0; i < n; i++)
                    {
                        var c = (char)buf[i];
                        if (c is '\r' or '\n') { if (line.Length > 0) { Feed(line.ToString()); line.Clear(); } }
                        else if (line.Length < 200) line.Append(c);
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                LastError = $"{Tujuan}: {ex.Message}";
                log.LogWarning("Timbangan {Kode}: {Err}. Coba lagi 5 detik.", o.Kode, LastError);
                try { await Task.Delay(5000, ct); } catch (OperationCanceledException) { }
            }
            finally { stream = null; try { port?.Dispose(); } catch { } try { tcp?.Dispose(); } catch { } port = null; tcp = null; }
        }
    }

    void Feed(string text)
    {
        var m = pat.Match(text);
        if (!m.Success) return;
        var raw = (m.Groups.Count > 1 && m.Groups[1].Success ? m.Groups[1].Value : m.Value).Replace(',', '.');
        if (!decimal.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return;
        if (o.Satuan.Equals("g", StringComparison.OrdinalIgnoreCase)) v /= 1000m;
        var flag = stabilPat.IsMatch(text);
        lock (gate)
        {
            recent.Add(new Reading(v, flag, DateTime.UtcNow));
            if (recent.Count > 20) recent.RemoveAt(0);
        }
    }

    /// Menunggu pembacaan stabil sampai timeout. Bila tidak stabil, mengembalikan pembacaan terakhir dengan Stabil=false.
    public async Task<(Reading? r, string? err)> ReadAsync(TimeSpan timeout)
    {
        var st = stream;
        if (st is null) return (null, LastError ?? $"{Tujuan} belum terhubung");
        if (!string.IsNullOrEmpty(o.PerintahMinta))
        {
            try { var cmd = Encoding.ASCII.GetBytes(Unescape(o.PerintahMinta)); st.Write(cmd, 0, cmd.Length); st.Flush(); } catch (Exception ex) { return (null, "Gagal mengirim perintah: " + ex.Message); }
        }
        var until = DateTime.UtcNow + timeout;
        var since = DateTime.UtcNow.AddSeconds(-1);   // abaikan data lebih tua dari 1 detik sebelum permintaan
        Reading? last = null;
        while (DateTime.UtcNow < until)
        {
            lock (gate)
            {
                var fresh = recent.Where(x => x.At >= since).ToList();
                last = fresh.LastOrDefault();
                if (last is not null)
                {
                    if (!string.IsNullOrEmpty(o.StabilPattern))
                    { if (last.Stabil) return (last, null); }
                    else if (fresh.Count >= o.MinStabil && fresh.TakeLast(o.MinStabil).All(x => x.Kg == last.Kg))
                        return (last with { Stabil = true }, null);
                }
            }
            await Task.Delay(150);
        }
        return last is null ? (null, "Tidak ada data dari timbangan (cek kabel / baud / PerintahMinta)") : (last with { Stabil = false }, null);
    }

    public void Dispose() { cts?.Cancel(); try { port?.Dispose(); } catch { } try { tcp?.Dispose(); } catch { } }
}
