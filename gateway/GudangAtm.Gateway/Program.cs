using System.IO.Ports;
using System.Text;
using GudangAtm.Gateway;

// ---- Mode alat bantu (jalankan dari PowerShell, bukan sebagai service) -----------------------------------------
//   GudangAtm.Gateway.exe --sniff COM3 9600 [detik] [perintah]   rekam data mentah timbangan (untuk menentukan format)
//   GudangAtm.Gateway.exe --tes-timbang TP-01                    baca berat satu kali sesuai appsettings
//   GudangAtm.Gateway.exe --tes-cetak LP-01                      cetak label uji
if (args.Length > 0 && args[0] == "--sniff") { Sniff(args); return; }

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings { Args = args, ContentRootPath = AppContext.BaseDirectory });
builder.Services.AddWindowsService(o => o.ServiceName = "GudangAtmGateway");

if (args.Length > 0 && args[0] is "--tes-timbang" or "--tes-cetak")
{
    var cfg = builder.Configuration;
    var log = LoggerFactory.Create(b => b.AddConsole()).CreateLogger("tes");
    if (args[0] == "--tes-timbang")
    {
        var o = (cfg.GetSection("Timbangan").Get<List<ScaleOptions>>() ?? new()).FirstOrDefault(x => x.Kode == args.ElementAtOrDefault(1));
        if (o is null) { Console.WriteLine("Kode timbangan tidak ada di appsettings.json"); return; }
        using var sc = new ScaleReader(o, log);
        sc.Start();
        var (r, err) = await sc.ReadAsync(TimeSpan.FromSeconds(12));
        Console.WriteLine(r is null ? "GAGAL: " + err : $"Berat: {r.Kg} kg  stabil={r.Stabil}");
    }
    else
    {
        var p = (cfg.GetSection("Printer").Get<List<PrinterOptions>>() ?? new()).FirstOrDefault(x => x.Kode == args.ElementAtOrDefault(1));
        if (p is null) { Console.WriteLine("Kode printer tidak ada di appsettings.json"); return; }
        var tspl = "SIZE 100 mm,70 mm\r\nGAP 3 mm,0 mm\r\nDIRECTION 1\r\nCLS\r\nQRCODE 24,24,M,5,A,0,M2,S7,\"TES-GUDANG-ATM\"\r\nTEXT 250,24,\"2\",0,1,1,\"TES CETAK GUDANG ATM\"\r\nPRINT 1,1\r\n";
        try { await PrinterClient.SendAsync(p, tspl); Console.WriteLine("Terkirim. Periksa labelnya."); }
        catch (Exception ex) { Console.WriteLine("GAGAL: " + ex.Message); }
    }
    return;
}

builder.Services.AddHostedService<Worker>();
await builder.Build().RunAsync();

static void Sniff(string[] a)
{
    // --sniff COM3 9600 [detik] [perintah]   atau   --sniff 192.168.1.50:4001 0 [detik] [perintah]  (jembatan ESP32/converter)
    var target = a.ElementAtOrDefault(1) ?? "COM1";
    var baud = int.TryParse(a.ElementAtOrDefault(2), out var b) ? b : 9600;
    var detik = int.TryParse(a.ElementAtOrDefault(3), out var d) ? d : 30;
    var cmd = a.ElementAtOrDefault(4);
    Console.WriteLine($"Merekam {target} selama {detik} dtk. Letakkan beban / tekan tombol print di indikator.");
    Stream st; IDisposable owner;
    if (target.Contains(':'))
    {
        var hp = target.Split(':');
        var c = new System.Net.Sockets.TcpClient(hp[0], int.Parse(hp[1]));
        c.ReceiveTimeout = 500; st = c.GetStream(); st.ReadTimeout = 500; owner = c;
    }
    else
    {
        var p = new SerialPort(target, baud, Parity.None, 8, StopBits.One) { ReadTimeout = 500 };
        p.Open(); st = p.BaseStream; owner = p;
    }
    using var _ = owner;
    if (!string.IsNullOrEmpty(cmd)) { var cb = Encoding.ASCII.GetBytes(ScaleReader.Unescape(cmd)); st.Write(cb, 0, cb.Length); Console.WriteLine("Perintah dikirim: " + cmd); }
    var end = DateTime.UtcNow.AddSeconds(detik);
    var buf = new byte[256];
    while (DateTime.UtcNow < end)
    {
        int n;
        try { n = st.Read(buf, 0, buf.Length); } catch (Exception e) when (e is TimeoutException or IOException) { continue; }
        if (n == 0) { Console.WriteLine("Koneksi ditutup."); break; }
        var hex = BitConverter.ToString(buf, 0, n);
        var txt = new StringBuilder();
        for (int i = 0; i < n; i++) txt.Append(buf[i] switch { 13 => "\\r", 10 => "\\n", < 32 or > 126 => ".", _ => ((char)buf[i]).ToString() });
        Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff}  {txt}    [{hex}]");
    }
    Console.WriteLine("Selesai. Kirim hasil rekaman ini ke pengembang untuk menyetel Pattern.");
}
