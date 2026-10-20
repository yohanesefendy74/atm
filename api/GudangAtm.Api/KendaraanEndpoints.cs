using System.Data;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record TimbangIn(string? KodeTimbangan, decimal BeratKg, string Sumber, string? IndikatorStatus, string? TeksMentah);
public record MasukReq(string WhsCode, string Keperluan, string? PlanNo, string NoPolisi, string Sopir, string? ContainerNo, string? AlasanBedaPlan,
    bool KontainerBawaan, TimbangIn Timbang, bool AckPeringatan, string? KodeAdmin);
public record KeluarReq(TimbangIn Timbang, bool KontainerTinggal, string? YardArea, decimal? TaraKontainer, bool AckPeringatan, string? KodeAdmin);
public record KodeAdminReq(string WhsCode, string? Tujuan);

/// Registrasi kendaraan (pos timbang / layar gudang), timbang masuk-keluar, yard kontainer, riwayat berat, kode persetujuan Admin.
public static partial class KendaraanEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });
    static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    [GeneratedRegex(@"^[A-Z]{1,2}\d{1,4}[A-Z]{1,3}$")] private static partial Regex PlatRx();

    public static string NormPlat(string? s) => Regex.Replace((s ?? "").ToUpperInvariant(), @"[\s\-\.]", "");
    public static string FormatPlat(string n)
    {
        var m = Regex.Match(n, @"^([A-Z]{1,2})(\d{1,4})([A-Z]{1,3})$");
        return m.Success ? $"{m.Groups[1].Value} {m.Groups[2].Value} {m.Groups[3].Value}" : n;
    }

    static async Task<Dictionary<string, decimal>> Setup(SqlConnection db, SqlTransaction? tx = null) =>
        (await db.QueryAsync<(string Kode, decimal Nilai)>("SELECT Kode, Nilai FROM WHS_Setup", transaction: tx)).ToDictionary(x => x.Kode, x => x.Nilai);

    static string Hash(string s) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(s))).ToLowerInvariant();

    /// Memakai kode persetujuan Admin (sekali pakai, 15 menit). Mengembalikan null bila sah, atau pesan salah.
    static async Task<string?> PakaiKodeAdmin(SqlConnection db, SqlTransaction tx, string whs, string? kode, int userId)
    {
        if (!Regex.IsMatch(kode ?? "", @"^\d{6}$")) return "Kode persetujuan Admin harus 6 digit";
        var id = await db.ExecuteScalarAsync<long?>(@"SELECT TOP 1 Id FROM WHS_KodeAdmin WITH (UPDLOCK) WHERE WhsCode = @whs AND KodeHash = @h AND UsedAt IS NULL AND ExpiresAt > SYSDATETIME() ORDER BY Id DESC",
            new { whs, h = Hash(kode!) }, tx);
        if (id is null) return "Kode persetujuan Admin salah atau sudah kedaluwarsa";
        await db.ExecuteAsync("UPDATE WHS_KodeAdmin SET UsedBy = @u, UsedAt = SYSDATETIME() WHERE Id = @id", new { id, u = userId }, tx);
        return null;
    }

    static async Task<string> NextTiket(SqlConnection db, SqlTransaction tx)
    {
        var prefix = $"TB-{DateTime.Today:yyMMdd}-";
        var last = await db.ExecuteScalarAsync<string?>("SELECT TOP 1 Tiket FROM WHS_Kendaraan WITH (UPDLOCK, HOLDLOCK) WHERE Tiket LIKE @p ORDER BY Tiket DESC", new { p = prefix + "%" }, tx);
        return prefix + ((last is null ? 0 : int.Parse(last[prefix.Length..])) + 1).ToString("0000");
    }

    public static void MapKendaraanAdmin(this RouteGroupBuilder cms, Func<SqlConnection> dbf)
    {
        // Admin membuat kode persetujuan untuk diberikan ke krani/pos (berlaku 15 menit, sekali pakai)
        cms.MapPost("/kode-persetujuan", async (KodeAdminReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs = r.WhsCode }) == 0) return Results.Forbid();
            var kode = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("000000");
            await db.ExecuteAsync("INSERT WHS_KodeAdmin (KodeHash, WhsCode, Tujuan, CreatedBy, ExpiresAt) VALUES (@h, @whs, @t, @u, DATEADD(MINUTE, 15, SYSDATETIME()))",
                new { h = Hash(kode), whs = r.WhsCode, t = Clean(r.Tujuan), u = u.UserId() });
            await Audit.Safe(db, u, ctx, "KODE_ADMIN", "KODE", null, $"{r.WhsCode} {r.Tujuan}");
            return Results.Ok(new { kode, berlakuMenit = 15 });
        });

        // Riwayat berat (read-only) untuk CMS
        cms.MapGet("/riwayat/mobil", async (string? plat) =>
        {
            await using var db = dbf();
            var np = NormPlat(plat);
            return Results.Ok(np == ""
                ? await db.QueryAsync("SELECT TOP 200 NoPolisi AS noPolisi, JumlahTimbang AS jumlahTimbang, RataTara AS rataTara, MinTara AS minTara, MaxTara AS maxTara, TaraTerakhir AS taraTerakhir FROM vw_WHS_TaraMobil ORDER BY NoPolisi")
                : await db.QueryAsync("SELECT TOP 200 r.NoPolisi AS noPolisi, r.TaraKg AS taraKg, r.Sumber AS sumber, r.SelisihRataPersen AS selisihRataPersen, r.Sopir AS sopir, r.WaktuTimbang AS waktuTimbang, u.USER_CODE AS oleh FROM WHS_RiwayatBeratMobil r LEFT JOIN OUSR u ON u.USERID = r.UserId WHERE REPLACE(r.NoPolisi, ' ', '') = @np ORDER BY r.WaktuTimbang DESC", new { np }));
        });
        cms.MapGet("/riwayat/kontainer", async (string? no) =>
        {
            await using var db = dbf();
            var c = (no ?? "").ToUpperInvariant().Replace(" ", "").Replace("-", "");
            return Results.Ok(c == ""
                ? await db.QueryAsync("SELECT TOP 200 ContainerNo AS containerNo, JumlahTimbang AS jumlahTimbang, RataTara AS rataTara, MinTara AS minTara, MaxTara AS maxTara, TaraTerakhir AS taraTerakhir FROM vw_WHS_TaraKontainer ORDER BY ContainerNo")
                : await db.QueryAsync("SELECT TOP 200 r.ContainerNo AS containerNo, r.TaraKg AS taraKg, r.Peristiwa AS peristiwa, r.NoPolisi AS noPolisi, r.Sumber AS sumber, r.SelisihRataPersen AS selisihRataPersen, r.WaktuTimbang AS waktuTimbang FROM WHS_RiwayatBeratKontainer r WHERE r.ContainerNo = @c ORDER BY r.WaktuTimbang DESC", new { c }));
        });
    }

    public static void MapKendaraan(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        // Kendaraan yang sedang di dalam gudang
        api.MapGet("/kendaraan", async (string whs, string? status, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs }) == 0) return Results.Forbid();
            return Results.Ok(await db.QueryAsync(@"
SELECT k.RegId AS regId, k.Tiket AS tiket, k.Keperluan AS keperluan, k.NoPolisi AS noPolisi, k.Sopir AS sopir, k.ContainerNo AS containerNo, k.JamMasuk AS jamMasuk, k.JamKeluar AS jamKeluar,
       k.SelesaiKrani AS selesaiKrani, k.Status AS status, p.PlanNo AS planNo, p.Jenis AS jenis, k.Peringatan AS peringatan
FROM WHS_Kendaraan k LEFT JOIN WHS_Plan p ON p.PlanId = k.PlanId
WHERE k.WhsCode = @whs AND (@status IS NULL AND k.Status = 'Di dalam' OR k.Status = @status) ORDER BY k.RegId DESC", new { whs, status = Clean(status) }));
        });

        // Cari dokumen yang cocok dengan plat / container (untuk pengisian otomatis)
        api.MapGet("/kendaraan/cari-dokumen", async (string whs, string? plat, string? container, string keperluan, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs }) == 0) return Results.Forbid();
            var jenis = keperluan == "Bongkar" ? "SPBB" : "SPMB";
            var cont = (container ?? "").ToUpperInvariant().Replace(" ", "").Replace("-", "");
            return Results.Ok(await db.QueryAsync(@"
SELECT TOP 20 p.PlanNo AS planNo, p.Jenis AS jenis, p.CardName AS party, p.Status AS status, r.Titipan AS titipan, p.EtaDatang AS eta,
       (SELECT TOP 1 UserId FROM WHS_PlanKrani WHERE PlanId = p.PlanId) AS kraniId
FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan
WHERE p.WhsCode = @whs AND p.Jenis = @jenis AND p.Status IN ('Terbit','Proses')
  AND (@cont = '' OR EXISTS (SELECT 1 FROM WHS_Plan1 l WHERE l.PlanId = p.PlanId AND l.ContainerNo = @cont))
ORDER BY p.PlanId DESC", new { whs, jenis, cont }));
        });

        // Tara terakhir / rata-rata untuk plat dan kontainer
        api.MapGet("/kendaraan/tara", async (string? plat, string? container) =>
        {
            await using var db = dbf();
            var np = NormPlat(plat);
            var c = (container ?? "").ToUpperInvariant().Replace(" ", "").Replace("-", "");
            var mobil = np == "" ? null : await db.QueryFirstOrDefaultAsync("SELECT TOP 1 JumlahTimbang AS jumlah, RataTara AS rata, TaraTerakhir AS terakhir FROM vw_WHS_TaraMobil WHERE REPLACE(NoPolisi, ' ', '') = @np", new { np });
            var kont = c == "" ? null : await db.QueryFirstOrDefaultAsync("SELECT TOP 1 JumlahTimbang AS jumlah, RataTara AS rata, TaraTerakhir AS terakhir FROM vw_WHS_TaraKontainer WHERE ContainerNo = @c", new { c });
            return Results.Ok(new { mobil, kontainer = kont });
        });

        api.MapGet("/yard", async (string whs, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs }) == 0) return Results.Forbid();
            return Results.Ok(await db.QueryAsync("SELECT ContainerNo AS containerNo, Posisi AS posisi, Kondisi AS kondisi, TaraKg AS taraKg, Dialokasikan AS dialokasikan FROM WHS_Kontainer WHERE WhsCode = @whs AND Status = 'Di yard' ORDER BY Posisi", new { whs }));
        });

        // ------------------------------------------------------------ Registrasi masuk + timbang masuk
        api.MapPost("/kendaraan/masuk", async (MasukReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (r.Keperluan is not ("Bongkar" or "Muat" or "AmbilKontainer")) return Bad("Keperluan tidak valid");
            var plat = NormPlat(r.NoPolisi);
            if (!PlatRx().IsMatch(plat)) return Bad("Format plat tidak valid · contoh B 1234 ABC");
            var sopir = (r.Sopir ?? "").Trim();
            if (sopir.Length < 3 || sopir.Length > 60 || !Regex.IsMatch(sopir, @"^[A-Za-z .'\-]+$")) return Bad("Nama sopir minimal 3 huruf, tanpa angka atau simbol");
            var cont = Clean(r.ContainerNo)?.ToUpperInvariant().Replace(" ", "").Replace("-", "");
            if (r.Timbang is null || r.Timbang.BeratKg <= 0 || r.Timbang.BeratKg > 500000) return Bad("Berat timbangan tidak valid");
            if (r.Timbang.Sumber is not ("LAN" or "GATEWAY" or "BLE" or "MANUAL")) return Bad("Sumber timbangan tidak valid");

            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs = r.WhsCode }, tx) == 0) return Results.Forbid();
                var st = await Setup(db, tx);
                decimal S(string k, decimal d) => st.TryGetValue(k, out var v) ? v : d;
                var warnings = new List<string>();

                if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Kendaraan WHERE REPLACE(NoPolisi, ' ', '') = @plat AND Status = 'Di dalam'", new { plat }, tx) > 0)
                    return Bad($"{FormatPlat(plat)} masih tercatat di dalam gudang · timbang keluar dulu");

                // dokumen
                long? planId = null; bool? planTitipan = null;
                if (r.Keperluan != "AmbilKontainer")
                {
                    var no = Clean(r.PlanNo)?.ToUpperInvariant();
                    if (no is null || !Regex.IsMatch(no, @"^SP(BB|MB)/\d{4}/\d{4}$")) return Bad("Format dokumen salah · contoh SPBB/2610/0014");
                    if (no[..4] != (r.Keperluan == "Bongkar" ? "SPBB" : "SPMB")) return Bad(r.Keperluan == "Bongkar" ? "Bongkar memakai dokumen SPBB, bukan SPMB" : "Muat memakai dokumen SPMB, bukan SPBB");
                    var p = await db.QueryFirstOrDefaultAsync<(long PlanId, string WhsCode, string Status, bool? Titipan)?>("SELECT p.PlanId, p.WhsCode, p.Status, rm.Titipan FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan rm ON rm.KodeRuangan = p.KodeRuangan WHERE p.PlanNo = @no", new { no }, tx);
                    if (p is null) return Bad("Dokumen tidak ditemukan");
                    if (p.Value.WhsCode != r.WhsCode) return Bad($"Dokumen untuk {p.Value.WhsCode}, bukan gudang ini ({r.WhsCode})");
                    if (p.Value.Status == "Partial") return Bad("Dokumen Partial (masih ada outstanding) tidak bisa untuk registrasi kendaraan masuk");
                    if (p.Value.Status is "Selesai" or "SelesaiKurang") return Bad("Dokumen sudah selesai · tidak bisa menerima kendaraan lagi");
                    if (p.Value.Status == "Batal") return Bad("Dokumen dibatalkan oleh Admin");
                    if (p.Value.Status is not ("Terbit" or "Proses")) return Bad("Dokumen belum diterbitkan");
                    if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_PlanKrani WHERE PlanId = @id", new { id = p.Value.PlanId }, tx) == 0) return Bad("Belum ada krani yang ditugaskan · hubungi Admin");
                    planId = p.Value.PlanId; planTitipan = p.Value.Titipan;
                }

                // kontainer
                if (cont is not null && !PlanEndpoints.Iso6346(cont)) return Bad("Nomor kontainer tidak valid (ISO 6346: 4 huruf + 7 angka, digit pemeriksa)");
                if (r.Keperluan == "AmbilKontainer" && cont is null) return Bad("Pilih kontainer kosong dari yard");
                if (cont is not null)
                {
                    var plat2 = await db.ExecuteScalarAsync<string?>("SELECT TOP 1 NoPolisi FROM WHS_Kendaraan WHERE ContainerNo = @c AND Status = 'Di dalam'", new { c = cont }, tx);
                    if (plat2 is not null) return Bad($"Kontainer sedang di dalam gudang di {plat2}");
                    var y = await db.QueryFirstOrDefaultAsync<(string Posisi, string? Kondisi, string? Dialokasikan)?>("SELECT Posisi, Kondisi, Dialokasikan FROM WHS_Kontainer WHERE ContainerNo = @c AND WhsCode = @w AND Status = 'Di yard'", new { c = cont, w = r.WhsCode }, tx);
                    if (r.Keperluan == "Bongkar" && y is not null) return Bad($"Kontainer sudah tercatat di yard ({y.Value.Posisi}) · tidak bisa datang lagi sebelum diambil");
                    if (r.Keperluan is "Muat" or "AmbilKontainer" && y is not null)
                    {
                        if (y.Value.Kondisi != "Kosong") return Bad("Kontainer yard masih berisi · hanya kontainer kosong yang bisa diambil");
                        if (y.Value.Dialokasikan is not null && y.Value.Dialokasikan != r.PlanNo) return Bad($"Sudah dialokasikan ke {y.Value.Dialokasikan}");
                    }
                    if (r.Keperluan == "AmbilKontainer" && y is null) return Bad("Kontainer tidak ada di yard");
                }

                // timbangan
                if (r.Timbang.Sumber != "MANUAL" && Clean(r.Timbang.IndikatorStatus) is { } ind && ind != "Normal" && ind != "Stabil") return Bad("Berat belum stabil · tunggu indikator STABIL");
                var masukBruto = r.Keperluan == "Bongkar"; // Bongkar: bruto masuk. Muat/Ambil: tara masuk.
                var berat = r.Timbang.BeratKg;
                var hist = await db.QueryFirstOrDefaultAsync<(decimal? Terakhir, decimal? Rata)>("SELECT TaraTerakhir AS Terakhir, RataTara AS Rata FROM vw_WHS_TaraMobil WHERE REPLACE(NoPolisi, ' ', '') = @plat", new { plat }, tx);
                var kontTara = cont is null ? 0 : (await db.ExecuteScalarAsync<decimal?>("SELECT TaraTerakhir FROM vw_WHS_TaraKontainer WHERE ContainerNo = @c", new { c = cont }, tx) ?? 0);
                decimal? selisihRata = null;
                if (masukBruto)
                {
                    if (berat > S("BRUTO_MAX_KG", 52000)) return Bad($"Bruto {berat:N0} kg melebihi batas {S("BRUTO_MAX_KG", 52000):N0} kg · kendaraan overload, tidak boleh masuk");
                    if (hist.Terakhir is { } lt && berat <= lt) return Bad($"Bruto lebih ringan dari tara terakhir plat ini ({lt:N0} kg) · cek timbangan");
                }
                else
                {
                    if (berat > S("TARA_MAX_KG", 20000)) return Bad($"Tara {berat:N0} kg tidak wajar (maks {S("TARA_MAX_KG", 20000):N0}) · kendaraan masih bermuatan?");
                    var exp = (hist.Terakhir ?? 0) + (r.KontainerBawaan ? kontTara : 0);
                    if (exp > 0)
                    {
                        selisihRata = Math.Round(Math.Abs(berat - exp) / exp * 100, 2);
                        if (selisihRata > S("TARA_DEV_PCT", 2)) warnings.Add($"Tara beda {selisihRata:N1}% dari tara terakhir plat ini ({exp:N0} kg)");
                    }
                }
                if (r.Timbang.Sumber == "MANUAL")
                {
                    var e = await PakaiKodeAdmin(db, tx, r.WhsCode, r.KodeAdmin, u.UserId());
                    if (e is not null) return Bad("Berat manual: " + e);
                    warnings.Add("Berat manual dengan persetujuan Admin");
                }
                if (warnings.Count > 0 && !r.AckPeringatan) return Results.Json(new { message = "Ada peringatan. Konfirmasi bahwa sudah diperiksa.", warnings, perluKonfirmasi = true }, statusCode: 409);

                if (planId is not null && planTitipan is not null && cont is null) { /* titipan dicek di dokumen, bukan di kendaraan */ }
                var tiket = await NextTiket(db, tx);
                var reg = await db.ExecuteScalarAsync<long>(@"INSERT WHS_Kendaraan (Tiket, WhsCode, Keperluan, PlanId, NoPolisi, Sopir, ContainerNo, AlasanBedaPlan, KontainerBawaan, Peringatan, InUser)
                    OUTPUT INSERTED.RegId VALUES (@tiket, @whs, @kep, @plan, @plat, @sopir, @cont, @alasan, @kb, @per, @uid)",
                    new { tiket, whs = r.WhsCode, kep = r.Keperluan, plan = planId, plat = FormatPlat(plat), sopir, cont, alasan = Clean(r.AlasanBedaPlan), kb = r.KontainerBawaan, per = warnings.Count == 0 ? null : string.Join("; ", warnings), uid = u.UserId() }, tx);
                var tid = await db.ExecuteScalarAsync<long>(@"INSERT WHS_Timbang (RegId, Alat, KodeTimbangan, Jenis, BeratKg, Sumber, IndikatorStatus, SelisihPersen, TeksMentah, Peringatan, UserId)
                    OUTPUT INSERTED.TimbangId VALUES (@reg, 'KENDARAAN', @kode, @jenis, @berat, @sumber, @ind, @sel, @raw, @per, @uid)",
                    new { reg, kode = Clean(r.Timbang.KodeTimbangan), jenis = masukBruto ? "BRUTO" : "TARA", berat, sumber = r.Timbang.Sumber, ind = Clean(r.Timbang.IndikatorStatus), sel = selisihRata, raw = r.Timbang.TeksMentah is { Length: > 200 } t ? t[..200] : r.Timbang.TeksMentah, per = warnings.Count == 0 ? null : string.Join("; ", warnings), uid = u.UserId() }, tx);
                if (!masukBruto)
                {
                    var taraMobil = berat - (r.KontainerBawaan ? kontTara : 0);
                    if (taraMobil > 0)
                        await db.ExecuteAsync(@"INSERT WHS_RiwayatBeratMobil (NoPolisi, WhsCode, TaraKg, Sumber, KodeTimbangan, TimbangId, RegId, Sopir, SelisihRataPersen, UserId)
                            VALUES (@plat, @whs, @tara, @sumber, @kode, @tid, @reg, @sopir, @sel, @uid)",
                            new { plat = FormatPlat(plat), whs = r.WhsCode, tara = taraMobil, sumber = r.Timbang.Sumber, kode = Clean(r.Timbang.KodeTimbangan), tid, reg, sopir, sel = selisihRata, uid = u.UserId() }, tx);
                }
                if (planId is not null) await db.ExecuteAsync("UPDATE WHS_Plan SET Status = 'Proses' WHERE PlanId = @id AND Status = 'Terbit'", new { id = planId }, tx);
                if (r.Keperluan == "AmbilKontainer" && cont is not null)
                    await db.ExecuteAsync("UPDATE WHS_Kontainer SET Dialokasikan = @t WHERE ContainerNo = @c AND WhsCode = @w", new { t = $"REG{reg}", c = cont, w = r.WhsCode }, tx);
                await Audit.Write(db, tx, u, ctx, "KENDARAAN_MASUK", "KENDARAAN", reg, $"{tiket} {FormatPlat(plat)} {r.Keperluan} {berat:N0} kg {r.Timbang.Sumber}");
                await tx.CommitAsync();
                return Results.Ok(new { regId = reg, tiket, warnings });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });

        // Krani menandai selesai (syarat boleh keluar)
        api.MapPost("/kendaraan/{regId:long}/selesai-krani", async (long regId, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var k = await db.QueryFirstOrDefaultAsync<(string WhsCode, long? PlanId, string Status)?>("SELECT WhsCode, PlanId, Status FROM WHS_Kendaraan WHERE RegId = @regId", new { regId });
            if (k is null) return Results.NotFound(new { message = "Kendaraan tidak ditemukan" });
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @w", new { uid = u.UserId(), w = k.Value.WhsCode }) == 0) return Results.Forbid();
            if (k.Value.Status != "Di dalam") return Bad("Kendaraan tidak di dalam gudang");
            if (k.Value.PlanId is not null && await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM OKRN WHERE RegId = @regId", new { regId }) == 0) return Bad("Belum ada input krani untuk kendaraan ini");
            await db.ExecuteAsync("UPDATE WHS_Kendaraan SET SelesaiKrani = 1 WHERE RegId = @regId", new { regId });
            await Audit.Safe(db, u, ctx, "KENDARAAN_SELESAI", "KENDARAAN", regId, null);
            return Results.Ok();
        });

        // ------------------------------------------------------------ Timbang keluar
        api.MapPost("/kendaraan/{regId:long}/keluar", async (long regId, KeluarReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (r.Timbang is null || r.Timbang.BeratKg <= 0 || r.Timbang.BeratKg > 500000) return Bad("Berat timbangan tidak valid");
            if (r.Timbang.Sumber is not ("LAN" or "GATEWAY" or "BLE" or "MANUAL")) return Bad("Sumber timbangan tidak valid");
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                var k = await db.QueryFirstOrDefaultAsync<(string WhsCode, string Keperluan, long? PlanId, string NoPolisi, string? ContainerNo, bool SelesaiKrani, string Status, bool KontainerBawaan)?>(
                    "SELECT WhsCode, Keperluan, PlanId, NoPolisi, ContainerNo, SelesaiKrani, Status, KontainerBawaan FROM WHS_Kendaraan WITH (UPDLOCK) WHERE RegId = @regId", new { regId }, tx);
                if (k is null) return Results.NotFound(new { message = "Kendaraan tidak ditemukan" });
                var kk = k.Value;
                if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @w", new { uid = u.UserId(), w = kk.WhsCode }, tx) == 0) return Results.Forbid();
                if (kk.Status != "Di dalam") return Bad("Kendaraan sudah keluar atau dibatalkan");
                if (kk.Keperluan != "AmbilKontainer" && !kk.SelesaiKrani) return Bad("Krani belum menyelesaikan pekerjaan · kendaraan belum boleh keluar");
                if (r.Timbang.Sumber != "MANUAL" && Clean(r.Timbang.IndikatorStatus) is { } ind && ind != "Normal" && ind != "Stabil") return Bad("Berat belum stabil · tunggu indikator STABIL");

                var st = await Setup(db, tx);
                decimal S(string k2, decimal d) => st.TryGetValue(k2, out var v) ? v : d;
                var berat = r.Timbang.BeratKg;
                var warnings = new List<string>();
                if (berat > S("BRUTO_MAX_KG", 52000)) return Bad($"Bruto melebihi batas {S("BRUTO_MAX_KG", 52000):N0} kg · kendaraan overload");
                var masuk = await db.QueryFirstOrDefaultAsync<(string Jenis, decimal BeratKg)?>("SELECT TOP 1 Jenis, BeratKg FROM WHS_Timbang WHERE RegId = @regId AND Alat = 'KENDARAAN' ORDER BY TimbangId", new { regId }, tx);
                if (masuk is null) return Bad("Timbang masuk tidak ditemukan");

                // berat palet (jenis palet x jumlah) dan input krani (net) untuk kendaraan ini
                var paletKg = await db.ExecuteScalarAsync<decimal?>(@"SELECT SUM(d.QtyPalet * mp.BeratKg) FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
                    JOIN WHS_MasterPalet mp ON mp.PaletCode = d.PaletCode WHERE h.RegId = @regId", new { regId }, tx) ?? 0;
                var inputKrani = await db.ExecuteScalarAsync<decimal?>("SELECT SUM(d.Quantity) FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry WHERE h.RegId = @regId AND d.Flag <> 0 AND (h.ObjType = '6730' OR d.Flag = -1)", new { regId }, tx) ?? 0;

                decimal? taraKont = r.TaraKontainer;
                if (r.KontainerTinggal)
                {
                    if (kk.ContainerNo is null) return Bad("Kendaraan ini tidak membawa kontainer");
                    if (taraKont is null or < 1500 or > 6000) return Bad("Tara kontainer harus 1.500-6.000 kg");
                    if (!Regex.IsMatch(r.YardArea ?? "", @"^YARD-[A-C]\d{2}$")) return Bad("Area yard format YARD-A01");
                    if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Kontainer WHERE WhsCode = @w AND Posisi = @p AND Status = 'Di yard'", new { w = kk.WhsCode, p = r.YardArea }, tx) > 0) return Bad($"Area {r.YardArea} sudah terisi");
                }

                decimal net, bandingkan; string jenisKeluar;
                if (kk.Keperluan == "Bongkar")
                {
                    // masuk = bruto; keluar = tara (mobil kosong, bisa + kontainer bawaan)
                    jenisKeluar = "TARA";
                    if (berat > S("TARA_MAX_KG", 20000) + (kk.ContainerNo is not null && !r.KontainerTinggal ? 6000 : 0)) return Bad("Tara tidak wajar · kendaraan masih bermuatan?");
                    net = masuk.Value.BeratKg - berat - (r.KontainerTinggal ? taraKont ?? 0 : 0) - paletKg;
                    bandingkan = inputKrani;
                }
                else if (kk.Keperluan == "Muat")
                {
                    // masuk = tara; keluar = bruto
                    jenisKeluar = "BRUTO";
                    var taraKontMuat = kk.ContainerNo is null ? 0 : (taraKont ?? await db.ExecuteScalarAsync<decimal?>("SELECT TaraTerakhir FROM vw_WHS_TaraKontainer WHERE ContainerNo = @c", new { c = kk.ContainerNo }, tx) ?? 0);
                    net = berat - masuk.Value.BeratKg - taraKontMuat - paletKg;
                    bandingkan = inputKrani;
                }
                else
                {
                    // ambil kontainer kosong: keluar = tara mobil + kontainer; tidak ada net barang
                    jenisKeluar = "BRUTO";
                    net = 0; bandingkan = 0;
                }

                decimal? selisih = null; var perluAdmin = false;
                if (kk.Keperluan != "AmbilKontainer")
                {
                    if (net <= 0) return Bad("Net barang ≤ 0 · cek berat dan pilihan kontainer");
                    if (bandingkan > 0)
                    {
                        selisih = Math.Round(Math.Abs(net - bandingkan) / bandingkan * 100, 2);
                        var tolScale = Clean(r.Timbang.KodeTimbangan) is { } kt ? await db.ExecuteScalarAsync<decimal?>("SELECT TolOverridePct FROM WHS_MasterTimbangan WHERE KodeTimbangan = @kt", new { kt }, tx) : null;
                        var tol = tolScale ?? S("NET_TOL_PCT", 0.5m);
                        var adm = S("NET_ADMIN_PCT", 2);
                        if (selisih > adm) perluAdmin = true;
                        else if (selisih > tol) warnings.Add($"Net timbang {net:N0} kg beda {selisih:N2}% dari input krani {bandingkan:N0} kg");
                    }
                }
                if (r.Timbang.Sumber == "MANUAL" || perluAdmin)
                {
                    var e = await PakaiKodeAdmin(db, tx, kk.WhsCode, r.KodeAdmin, u.UserId());
                    if (e is not null) return Bad((perluAdmin ? $"Selisih net {selisih:N2}% melebihi batas · " : "Berat manual: ") + e);
                    warnings.Add(perluAdmin ? $"Selisih net {selisih:N2}% disetujui Admin" : "Berat manual dengan persetujuan Admin");
                }
                if (warnings.Count > 0 && !r.AckPeringatan) return Results.Json(new { message = "Ada peringatan. Konfirmasi bahwa sudah diperiksa.", warnings, perluKonfirmasi = true }, statusCode: 409);

                var peringatan = warnings.Count == 0 ? null : string.Join("; ", warnings);
                var tid = await db.ExecuteScalarAsync<long>(@"INSERT WHS_Timbang (RegId, OKRN_DocEntry, Alat, KodeTimbangan, Jenis, BeratKg, Sumber, IndikatorStatus, TaraKontainer, NetHitung, NetInputKrani, SelisihPersen, KodeAdminOleh, TeksMentah, Peringatan, UserId)
                    OUTPUT INSERTED.TimbangId VALUES (@reg, NULL, 'KENDARAAN', @kode, @jenis, @berat, @sumber, @ind, @tk, @net, @inp, @sel, @adm, @raw, @per, @uid)",
                    new { reg = regId, kode = Clean(r.Timbang.KodeTimbangan), jenis = jenisKeluar, berat, sumber = r.Timbang.Sumber, ind = Clean(r.Timbang.IndikatorStatus), tk = taraKont, net = kk.Keperluan == "AmbilKontainer" ? (decimal?)null : net, inp = bandingkan > 0 ? bandingkan : (decimal?)null, sel = selisih, adm = perluAdmin || r.Timbang.Sumber == "MANUAL" ? u.UserId() : (int?)null, raw = r.Timbang.TeksMentah is { Length: > 200 } t ? t[..200] : r.Timbang.TeksMentah, per = peringatan, uid = u.UserId() }, tx);

                // riwayat: tara mobil keluar (bongkar) dan tara kontainer yang ditinggal
                if (kk.Keperluan == "Bongkar")
                {
                    var taraMobil = berat - (kk.ContainerNo is not null && !r.KontainerTinggal ? 0 : 0);
                    if (taraMobil > 0)
                        await db.ExecuteAsync(@"INSERT WHS_RiwayatBeratMobil (NoPolisi, WhsCode, TaraKg, Sumber, KodeTimbangan, TimbangId, RegId, UserId) VALUES (@plat, @w, @tara, @sumber, @kode, @tid, @reg, @uid)",
                            new { plat = kk.NoPolisi, w = kk.WhsCode, tara = taraMobil, sumber = r.Timbang.Sumber, kode = Clean(r.Timbang.KodeTimbangan), tid, reg = regId, uid = u.UserId() }, tx);
                }
                if (r.KontainerTinggal && kk.ContainerNo is not null)
                {
                    await db.ExecuteAsync(@"INSERT WHS_RiwayatBeratKontainer (ContainerNo, WhsCode, TaraKg, Peristiwa, NoPolisi, Sumber, KodeTimbangan, TimbangId, RegId, UserId)
                        VALUES (@c, @w, @tara, 'MASUK_YARD', @plat, @sumber, @kode, @tid, @reg, @uid)",
                        new { c = kk.ContainerNo, w = kk.WhsCode, tara = taraKont, plat = kk.NoPolisi, sumber = r.Timbang.Sumber, kode = Clean(r.Timbang.KodeTimbangan), tid, reg = regId, uid = u.UserId() }, tx);
                    await db.ExecuteAsync(@"MERGE WHS_Kontainer AS t USING (SELECT @c AS ContainerNo, @w AS WhsCode) s ON t.ContainerNo = s.ContainerNo AND t.WhsCode = s.WhsCode
                        WHEN MATCHED THEN UPDATE SET Posisi = @p, Kondisi = 'Kosong', TaraKg = @tara, Status = 'Di yard', MasukRegId = @reg, KeluarRegId = NULL, Dialokasikan = NULL
                        WHEN NOT MATCHED THEN INSERT (ContainerNo, WhsCode, Posisi, Kondisi, TaraKg, Status, MasukRegId) VALUES (@c, @w, @p, 'Kosong', @tara, 'Di yard', @reg);",
                        new { c = kk.ContainerNo, w = kk.WhsCode, p = r.YardArea, tara = taraKont, reg = regId }, tx);
                }
                if (kk.Keperluan is "Muat" or "AmbilKontainer" && kk.ContainerNo is not null)
                    await db.ExecuteAsync("UPDATE WHS_Kontainer SET Status = 'Keluar', KeluarRegId = @reg WHERE ContainerNo = @c AND WhsCode = @w AND Status = 'Di yard'", new { c = kk.ContainerNo, w = kk.WhsCode, reg = regId }, tx);

                await db.ExecuteAsync("UPDATE WHS_Kendaraan SET Status = 'Keluar', JamKeluar = SYSDATETIME(), OutUser = @u, CatatanKeluar = @c WHERE RegId = @reg", new { u = u.UserId(), c = peringatan, reg = regId }, tx);
                await Audit.Write(db, tx, u, ctx, "KENDARAAN_KELUAR", "KENDARAAN", regId, $"{kk.NoPolisi} {kk.Keperluan} {berat:N0} kg net {net:N0} selisih {selisih}%");
                await tx.CommitAsync();
                return Results.Ok(new { regId, net, input = bandingkan, selisihPersen = selisih, warnings });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });
    }
}
