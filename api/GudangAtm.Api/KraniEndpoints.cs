using System.Data;
using System.Security.Claims;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

/// Endpoint krani (dipakai aplikasi HP lewat Bearer token dan web lewat cookie).
public static class KraniEndpoints
{
    static IResult Bad(string message) => Results.BadRequest(new { message });
    static string? Empty(string? s) => Helpers.Empty(s);
    static string? ValidateLines(List<DocLine> lines) => Helpers.ValidateLines(lines);

    static Task<SavedDoc> SaveDoc(SqlConnection db, ClaimsPrincipal u, string objType, string trxCode, string whsCode, string noMobil,
        string? containerNo, DateTime? docDate, List<(DocLine line, int flag)> lines) =>
        Helpers.SaveDoc(db, u, objType, trxCode, whsCode, noMobil, containerNo, docDate, lines);

    public static void MapKrani(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        // ---------------------------------------------------------------- Master
        api.MapGet("/warehouses", async (ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.Warehouses, new { userId = u.UserId() }));
        });

        api.MapGet("/items", async (string? q) =>
        {
            var term = (q ?? "").Trim();
            if (term.Length > 50) term = term[..50];
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.Items, new { q = $"%{term}%" }));
        });

        api.MapGet("/brands", async () =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync<string>(Sql.Brands));
        });

        // ---------------------------------------------------------------- Dokumen
        api.MapGet("/docs", async (string kind, ClaimsPrincipal u) =>
        {
            var objTypes = kind == "inbound" ? new[] { "6730" } : new[] { "6710", "6720" };
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.DocList, new { bplId = u.BplId(), userId = u.UserId(), objTypes }));
        });

        api.MapGet("/docs/{objType}/{docEntry:long}", async (string objType, long docEntry, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var h = await db.QueryFirstOrDefaultAsync<DocHeaderRow>(Sql.DocHeader, new { objType, docEntry, bplId = u.BplId(), userId = u.UserId() });
            if (h is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            var lines = await db.QueryAsync(Sql.DocLines, new { objType, docEntry });
            return Results.Ok(new { header = h, lines });
        });

        api.MapPost("/inbound", async (InboundRequest req, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (string.IsNullOrWhiteSpace(req.NoMobil)) return Bad("No. mobil wajib diisi");
            var herr = Helpers.ValidateHeader(req.NoMobil, req.ContainerNo, req.Lines?.Count ?? 0);
            if (herr is not null) return Bad(herr);
            if (req.Lines is null || req.Lines.Count == 0) return Bad("Detail barang masih kosong");
            var err = ValidateLines(req.Lines);
            if (err is not null) return Bad(err);

            await using var db = dbf();
            await db.OpenAsync();
            var isTitipan = await db.QueryFirstOrDefaultAsync<bool?>(Sql.WarehouseAccess,
                new { userId = u.UserId(), whsCode = req.WhsCode });
            if (isTitipan is null) return Bad($"Warehouse {req.WhsCode} tidak ada di hak akses Anda");

            var saved = await SaveDoc(db, u, "6730", isTitipan.Value ? "BT" : "IB", req.WhsCode, req.NoMobil,
                req.ContainerNo, req.DocDate, req.Lines.Select(l => (l, 1)).ToList());
            await Audit.Safe(db, u, ctx, "CREATE", saved.ObjType, saved.DocEntry, $"{saved.TrxCode} {req.Lines.Count} baris");
            return Results.Ok(saved);
        });

        api.MapPost("/outbound", async (OutboundRequest req, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var jenis = (req.Jenis ?? "").Trim().ToUpperInvariant();
            if (jenis is not ("OB" or "KR" or "RP")) return Bad("Jenis transaksi harus OB, KR atau RP");
            if (string.IsNullOrWhiteSpace(req.NoMobil) && jenis == "OB") return Bad("No. mobil wajib diisi");
            var outLines = req.OutLines ?? new List<DocLine>();
            var inLines = req.InLines ?? new List<DocLine>();
            if (outLines.Count == 0) return Bad("Belum ada palet yang discan");
            if (jenis == "OB" && inLines.Count > 0) return Bad("Item Inbound hanya untuk KR / RP");
            var err = Helpers.ValidateHeader(req.NoMobil ?? "", req.ContainerNo, outLines.Count + inLines.Count, mobilRequired: jenis == "OB")
                      ?? ValidateLines(outLines) ?? ValidateLines(inLines);
            if (err is not null) return Bad(err);

            await using var db = dbf();
            await db.OpenAsync();
            var isTitipan = await db.QueryFirstOrDefaultAsync<bool?>(Sql.WarehouseAccess,
                new { userId = u.UserId(), whsCode = req.WhsCode });
            if (isTitipan is null) return Bad($"Warehouse {req.WhsCode} tidak ada di hak akses Anda");
            if (isTitipan.Value && jenis != "OB") return Bad("KR dan RP tidak boleh di warehouse titipan");

            // Aturan v2: alasan wajib (KR), selisih berat Repacking, ruangan tidak boleh titipan untuk KR/RP
            decimal? selisih = null;
            if (jenis == "KR" && string.IsNullOrWhiteSpace(req.AlasanKode)) return Bad("Alasan penyesuaian wajib dipilih");
            if (req.AlasanKode == "lain" && (req.Catatan ?? "").Trim().Length < 5) return Bad("Catatan minimal 5 huruf bila alasan 'lain'");
            if (jenis != "OB" && !string.IsNullOrWhiteSpace(req.KodeRuangan))
            {
                var rt = await db.QueryFirstOrDefaultAsync<(bool Titipan, string WhsCode)?>("SELECT Titipan, WhsCode FROM WHS_MasterRuangan WHERE KodeRuangan = @k AND Aktif = 1", new { k = req.KodeRuangan });
                if (rt is null || rt.Value.WhsCode != req.WhsCode) return Bad("Ruangan tidak valid untuk gudang ini");
                if (rt.Value.Titipan) return Bad("KR dan RP tidak boleh di ruangan titipan");
            }
            if (jenis == "RP")
            {
                var src = outLines.Sum(l => l.Qty); var hasil = inLines.Sum(l => l.Qty);
                if (inLines.Count == 0) return Bad("Repacking harus punya item hasil");
                selisih = src <= 0 ? 0 : Math.Round(Math.Abs(src - hasil) / src * 100, 2);
                var lim = await db.ExecuteScalarAsync<decimal?>("SELECT Nilai FROM WHS_Setup WHERE Kode = 'REPACK_WARN_PCT'") ?? 2m;
                if (selisih > lim) return Bad($"Selisih berat Repacking {selisih:N2}% melebihi batas {lim:N0}% · periksa timbangan");
            }
            var trxCode = isTitipan.Value ? "BT" : jenis;
            var objType = jenis == "OB" ? "6710" : "6720";
            var lines = outLines.Select(l => (l, -1)).Concat(inLines.Select(l => (l, 1))).ToList();
            var saved = await SaveDoc(db, u, objType, trxCode, req.WhsCode, req.NoMobil ?? "", req.ContainerNo, req.DocDate, lines);
            if (jenis != "OB")
                await db.ExecuteAsync("UPDATE OKRN SET AlasanKode = @a, Catatan = @c, SelisihPersen = @s WHERE ObjType = @o AND DocEntry = @d",
                    new { a = Helpers.Empty(req.AlasanKode), c = Helpers.Empty(req.Catatan), s = selisih, o = saved.ObjType, d = saved.DocEntry });
            await Audit.Safe(db, u, ctx, "CREATE", saved.ObjType, saved.DocEntry, $"{saved.TrxCode} {outLines.Count} keluar / {inLines.Count} masuk");
            return Results.Ok(saved);
        });

        // ---------------------------------------------------------------- Scan palet
        // QR berisi yymmdd-ItemCode-ContainerNo. ItemCode boleh mengandung '-', container tidak.
        api.MapGet("/pallet", async (string qr, string whsCode, ClaimsPrincipal u) =>
        {
            if (qr is null || qr.Length > 80) return Bad("QR tidak valid");
            var parts = qr.Trim().Split('-');
            if (parts.Length < 3 || parts[0].Length != 6 || !parts[0].All(char.IsDigit))
                return Bad("Format QR tidak dikenal (harus yymmdd-itemcode-container)");
            var yymmdd = parts[0];
            var containerNo = parts[^1];
            var itemCode = string.Join('-', parts[1..^1]);

            await using var db = dbf();
            var access = await db.QueryFirstOrDefaultAsync<bool?>(Sql.WarehouseAccess, new { userId = u.UserId(), whsCode });
            if (access is null) return Bad($"Warehouse {whsCode} tidak ada di hak akses Anda");
            var src = await db.QueryFirstOrDefaultAsync<PalletSourceRow>(Sql.PalletSource, new { itemCode, containerNo, yymmdd, bplId = u.BplId() });
            if (src is null) return Results.NotFound(new { message = $"Palet {itemCode} container {containerNo} tidak ditemukan" });
            var stock = await db.QueryFirstAsync<StockRow>(Sql.StockForPallet, new { whsCode, itemCode, containerNo });

            decimal kgPerSak = src.Qty2 > 0 ? Math.Round(src.Qty / src.Qty2, 2) : 0;
            decimal sakPerPalet = src.QtyPalet > 0 ? Math.Ceiling(src.Qty2 / src.QtyPalet) : 0;
            return Results.Ok(new
            {
                qr,
                src.ItemCode,
                src.ItemName,
                src.Brand,
                src.Origin,
                containerNo,
                src.InboundDate,
                kgPerSak,
                sakPerPalet,
                stock.StockKg,
                stock.StockSak,
                stock.StockPalet,
            });
        });

        // ---------------------------------------------------------------- Label QR
        // Terkunci sampai Admin mengisi PT (OKRN.U_IDU_Kode_PT). Baris PT di label = OPRC.PrcName.
        api.MapGet("/labels/{objType}/{docEntry:long}", async (string objType, long docEntry, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var h = await db.QueryFirstOrDefaultAsync<DocHeaderRow>(Sql.DocHeader, new { objType, docEntry, bplId = u.BplId(), userId = u.UserId() });
            if (h is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            if (string.IsNullOrWhiteSpace(h.PtCode))
                return Results.Json(new { message = "Label belum bisa dicetak: PT belum diisi Admin di CMS" }, statusCode: 409);

            var rows = await db.QueryAsync<LabelLineRow>(Sql.LabelLines, new { objType, docEntry });
            var yymmdd = h.DocDate.ToString("yyMMdd");
            var items = rows.Select(r => new
            {
                r.ItemCode,
                r.ItemName,
                r.Brand,
                packKg = r.Qty2 > 0 ? Math.Round(r.Qty / r.Qty2, 2) : 0,
                sakPerPalet = r.QtyPalet > 0 ? Math.Ceiling(r.Qty2 / r.QtyPalet) : 0,
                qtyPalet = (int)r.QtyPalet,
                qr = $"{yymmdd}-{r.ItemCode}-{h.ContainerNo}",
            }).ToList();
            return Results.Ok(new
            {
                h.ObjType,
                h.DocEntry,
                h.DocDate,
                h.ContainerNo,
                ptName = h.PtName ?? h.PtCode,
                items,
            });
        });

        // ---------------------------------------------------------------- Laporan
        api.MapGet("/reports/stock-item", async (string? whsCode, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.StockPerItem, new { bplId = u.BplId(), userId = u.UserId(), whsCode = Empty(whsCode) }));
        });

        api.MapGet("/reports/stock-container", async (string? whsCode, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.StockPerContainer, new { bplId = u.BplId(), userId = u.UserId(), whsCode = Empty(whsCode) }));
        });

        api.MapGet("/reports/stock-card", async (string itemCode, string? whsCode, string? containerNo, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var rows = (await db.QueryAsync<StockCardRow>(Sql.StockCard,
                new { bplId = u.BplId(), userId = u.UserId(), itemCode, whsCode = Empty(whsCode), containerNo = Empty(containerNo) })).ToList();
            decimal kg = 0, sak = 0, pal = 0;
            foreach (var r in rows)
            {
                kg += r.Kg; sak += r.Sak; pal += r.Palet;
                r.SaldoKg = kg; r.SaldoSak = sak; r.SaldoPalet = pal;
            }
            return Results.Ok(rows);
        });

        api.MapGet("/reports/kpi", async (DateTime? from, DateTime? to, string? whsCode, ClaimsPrincipal u) =>
        {
            var t = (to ?? DateTime.Today).Date;
            var f = (from ?? t.AddDays(-6)).Date;
            await using var db = dbf();
            object row = await db.QueryFirstAsync(Sql.Kpi,new { bplId = u.BplId(), userId = u.UserId(), from = f, to = t, whsCode = Empty(whsCode) });
            return Results.Ok(row);
        });
    }
}

public static class Helpers
{
    public static string? Empty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    static readonly Regex Container = new(@"^[A-Z]{4}\d{7}$", RegexOptions.Compiled);
    static readonly Regex Plate = new(@"^[A-Z0-9 \-]{1,20}$", RegexOptions.Compiled);

    public static string? ValidateHeader(string noMobil, string? containerNo, int lineCount, bool mobilRequired = true)
    {
        var mobil = (noMobil ?? "").Trim().ToUpperInvariant();
        if (mobilRequired && mobil.Length == 0) return "No. mobil wajib diisi";
        if (mobil.Length > 0 && !Plate.IsMatch(mobil)) return "No. mobil hanya huruf/angka, maksimal 20 karakter";
        var cont = (containerNo ?? "").Replace(" ", "").ToUpperInvariant();
        if (cont.Length > 0 && !Container.IsMatch(cont)) return "Format kontainer: 4 huruf + 7 angka";
        if (lineCount > 200) return "Maksimal 200 baris per dokumen";
        return null;
    }

    public static string? ValidateLines(List<DocLine> lines)
    {
        foreach (var l in lines)
        {
            if (string.IsNullOrWhiteSpace(l.ItemCode) || l.ItemCode.Length > 50) return "Item code wajib diisi (maks. 50 karakter)";
            if ((l.Brand?.Length ?? 0) > 100 || (l.Origin?.Length ?? 0) > 100 || (l.Uom?.Length ?? 0) > 10) return $"Brand/Origin/UOM {l.ItemCode} terlalu panjang";
            if (l.Qty > 10_000_000 || l.Qty2 > 1_000_000 || l.QtyPalet > 10_000) return $"Qty {l.ItemCode} tidak wajar";
            if (l.Qty <= 0) return $"Qty KG {l.ItemCode} harus lebih dari 0";
            if (l.Qty2 < 0 || l.QtyPalet < 0) return $"Qty sak / palet {l.ItemCode} tidak boleh minus";
        }
        return null;
    }

    public static async Task<SavedDoc> SaveDoc(
        SqlConnection db, ClaimsPrincipal u, string objType, string trxCode, string whsCode, string noMobil,
        string? containerNo, DateTime? docDate, List<(DocLine line, int flag)> lines)
    {
        // Tanggal dokumen hanya boleh hari ini s/d 3 hari ke belakang (cegah backdate / tanggal ekstrem)
        var date = (docDate ?? DateTime.Today).Date;
        if (date > DateTime.Today || date < DateTime.Today.AddDays(-3)) date = DateTime.Today;
        var cont = string.IsNullOrWhiteSpace(containerNo) ? null : containerNo.Replace(" ", "").ToUpperInvariant();

        await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.ReadCommitted);
        try
        {
            var p = new DynamicParameters();
            p.Add("@ObjType", objType);
            p.Add("@DocDate", date, DbType.Date);
            p.Add("@DocEntry", dbType: DbType.Int64, direction: ParameterDirection.Output);
            await db.ExecuteAsync(Sql.NextDocEntry, p, tx, commandType: CommandType.StoredProcedure);
            var docEntry = p.Get<long>("@DocEntry");

            await db.ExecuteAsync(Sql.InsertHeader, new
            {
                objType,
                docEntry,
                docDate = date,
                bplId = int.Parse(u.FindFirstValue("bpl")!),
                whsCode,
                userId = int.Parse(u.FindFirstValue("uid")!),
                trxCode,
                noMobil = noMobil.Trim().ToUpperInvariant(),
                containerNo = cont,
            }, tx);

            var lineNum = 0;
            foreach (var (l, flag) in lines)
            {
                await db.ExecuteAsync(Sql.InsertLine, new
                {
                    objType,
                    docEntry,
                    lineNum = lineNum++,
                    itemCode = l.ItemCode.Trim(),
                    uom = l.Uom ?? "KG",
                    brand = l.Brand,
                    origin = l.Origin,
                    qty = l.Qty,
                    qty2 = l.Qty2,
                    qtyPalet = l.QtyPalet,
                    flag,
                }, tx);
            }

            await db.ExecuteAsync(Sql.UpdateTotals, new { objType, docEntry }, tx);
            await tx.CommitAsync();
            return new SavedDoc(objType, docEntry, trxCode);
        }
        catch
        {
            try { await tx.RollbackAsync(); } catch { /* koneksi putus: error asli tetap dilempar */ }
            throw;
        }
    }

}
