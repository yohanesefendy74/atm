using System.Net.Http.Json;
using Microsoft.Extensions.Options;

namespace GudangAtm.Gateway;

record JobDto(long JobId, string Tipe, string Target, string? Payload);
record PollResp(List<JobDto> Jobs);

/// Memanggil API (long-poll) untuk mengambil pekerjaan timbang / cetak, menjalankannya di alat lokal, lalu melapor.
public sealed class Worker : BackgroundService
{
    readonly ILogger<Worker> log;
    readonly ApiOptions api;
    readonly Dictionary<string, ScaleReader> scales = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, PrinterOptions> printers = new(StringComparer.OrdinalIgnoreCase);
    readonly HttpClient http;

    public Worker(ILogger<Worker> log, IConfiguration cfg)
    {
        this.log = log;
        api = cfg.GetSection("Api").Get<ApiOptions>() ?? new();
        if (string.IsNullOrWhiteSpace(api.Key) || api.Key.Length < 20) throw new InvalidOperationException("Api:Key belum diisi (set environment Api__Key)");
        foreach (var s in cfg.GetSection("Timbangan").Get<List<ScaleOptions>>() ?? new()) scales[s.Kode] = new ScaleReader(s, log);
        foreach (var p in cfg.GetSection("Printer").Get<List<PrinterOptions>>() ?? new()) printers[p.Kode] = p;

        var h = new HttpClientHandler();
        if (api.TrustSelfSigned) h.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
        http = new HttpClient(h) { BaseAddress = new Uri(api.BaseUrl.TrimEnd('/') + "/"), Timeout = TimeSpan.FromSeconds(45) };
        http.DefaultRequestHeaders.Add("X-Gateway-Id", api.GatewayId);
        http.DefaultRequestHeaders.Add("X-Gateway-Key", api.Key);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        foreach (var s in scales.Values) s.Start();
        var versi = typeof(Worker).Assembly.GetName().Version?.ToString(3);
        var jeda = 2;
        log.LogInformation("Gateway {Id} mulai. Timbangan: {S}. Printer: {P}", api.GatewayId, string.Join(",", scales.Keys), string.Join(",", printers.Keys));
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var resp = await http.PostAsJsonAsync("api/gateway/poll", new { versi }, ct);
                if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized) throw new InvalidOperationException("API menolak Gateway ID / key");
                resp.EnsureSuccessStatusCode();
                var data = await resp.Content.ReadFromJsonAsync<PollResp>(cancellationToken: ct);
                jeda = 2;
                foreach (var job in data?.Jobs ?? new()) await Jalankan(job, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
            catch (Exception ex)
            {
                log.LogWarning("Hubungan ke API gagal: {Msg}. Ulang {S} dtk.", ex.Message, jeda);
                try { await Task.Delay(TimeSpan.FromSeconds(jeda), ct); } catch (OperationCanceledException) { }
                jeda = Math.Min(jeda * 2, 30);
            }
        }
        foreach (var s in scales.Values) s.Dispose();
    }

    async Task Jalankan(JobDto job, CancellationToken ct)
    {
        bool ok = false; decimal? kg = null; bool? stabil = null; string? pesan = null;
        try
        {
            if (job.Tipe == "TIMBANG")
            {
                if (!scales.TryGetValue(job.Target, out var sc)) pesan = $"Timbangan {job.Target} tidak diatur di gateway";
                else
                {
                    var (r, err) = await sc.ReadAsync(TimeSpan.FromSeconds(10));
                    if (r is null) pesan = err;
                    else { ok = true; kg = r.Kg; stabil = r.Stabil; pesan = r.Stabil ? "Stabil" : "Belum stabil (bergoyang)"; }
                }
            }
            else if (job.Tipe == "CETAK")
            {
                if (!printers.TryGetValue(job.Target, out var p)) pesan = $"Printer {job.Target} tidak diatur di gateway";
                else { await PrinterClient.SendAsync(p, job.Payload ?? ""); ok = true; pesan = "Terkirim ke printer"; }
            }
            else pesan = "Jenis pekerjaan tidak dikenal";
        }
        catch (Exception ex) { pesan = ex.Message; log.LogWarning("Job {Id} gagal: {Msg}", job.JobId, ex.Message); }

        try { (await http.PostAsJsonAsync($"api/gateway/hasil/{job.JobId}", new { ok, beratKg = kg, stabil, pesan }, ct)).EnsureSuccessStatusCode(); }
        catch (Exception ex) { log.LogWarning("Lapor hasil job {Id} gagal: {Msg}", job.JobId, ex.Message); }
    }
}
