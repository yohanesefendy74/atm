using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

/// CMS Admin: cek input krani, pilah TrxCode, isi PT / CardCode / No DO / No BL, edit qty (backup *_scan), posting -> Close.
/// Semua endpoint di sini wajib role Admin dan dibatasi cabang (BPLId) user login.
public static class CmsEndpoints
{
    static IResult Bad(string message) => Results.BadRequest(new { message });

    /// Kelompok dokumen menentukan pilihan TrxCode yang boleh dipilih Admin.
    public static string Group(string objType, string trxCode) =>
        objType == "6730" ? "inbound" : (objType == "6720" || trxCode == "SS") ? "adjust" : "outbound";

    public static string[] AllowedTrx(string group, bool titipan) => group switch
    {
        // Retur Customer tidak ikut aturan titipan
        "inbound" => titipan ? new[] { "BT", "RC" } : new[] { "IB", "RC" },
        "outbound" => titipan ? new[] { "BT" } : new[] { "OB" },
        // KR & RP tidak boleh di warehouse titipan
        _ => titipan ? new[] { "SS" } : new[] { "KR", "SS", "RP" },
    };

    /// Susut (SS) = ObjType 6710, Penyesuaian (KR) & Repacking (RP) = 6720.
    public static string TargetObjType(string trxCode, string current) => trxCode switch
    {
        "SS" => "6710",
        "KR" or "RP" => "6720",
        _ => current,
    };

    /// CardType yang wajib untuk TrxCode: S supplier, C customer, null = tanpa BP.
    public static string? RequiredCardType(string objType, string trxCode) => trxCode switch
    {
        "IB" => "S",
        "BT" => objType == "6730" ? "S" : "C",
        "OB" or "RC" => "C",
        _ => null,
    };

    public static void MapCms(this RouteGroupBuilder cms, Func<SqlConnection> dbf, IConfiguration cfg)
    {
        cms.MapGet("/docs", async (string? status, string? objType, ClaimsPrincipal u) =>
        {
            var st = status switch { "C" => "C", "all" => null, _ => "O" };
            var ot = objType is "6710" or "6720" or "6730" ? objType : null;
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.CmsList, new { bplId = u.BplId(), status = st, objType = ot }));
        });

        cms.MapGet("/docs/{objType}/{docEntry:long}", async (string objType, long docEntry, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            object? header = (await db.QueryAsync(Sql.CmsHeader, new { objType, docEntry, bplId = u.BplId() })).FirstOrDefault();
            if (header is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            var h = await db.QueryFirstAsync<CmsHeaderRow>(Sql.CmsHeader, new { objType, docEntry, bplId = u.BplId() });
            var lines = await db.QueryAsync(Sql.CmsLines, new { objType, docEntry });
            var group = Group(h.ObjType, h.TrxCode);
            return Results.Ok(new
            {
                header,
                lines,
                group,
                allowedTrx = AllowedTrx(group, h.IsTitipan),
            });
        });

        cms.MapGet("/pt", async (string? q) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.PtLookup, new { q = Like(q) }));
        });

        cms.MapGet("/bp", async (string? q, string cardType) =>
        {
            if (cardType is not ("S" or "C")) return Bad("cardType harus S atau C");
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(Sql.BpLookup, new { q = Like(q), cardType }));
        });

        cms.MapGet("/retur-check", async (string cardCode, string numAtCard) =>
        {
            await using var db = dbf();
            var n = await db.ExecuteScalarAsync<int>(Sql.ReturDoValid, new { cardCode, numAtCard });
            return Results.Ok(new { valid = n > 0 });
        });

        cms.MapGet("/audit/{objType}/{docEntry:long}", async (string objType, long docEntry, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            // hanya dokumen cabang (BPLId) Admin yang login
            return Results.Ok(await db.QueryAsync(@"
SELECT TOP 50 LogTime AS logTime, UserCode AS userCode, Action AS action, Detail AS detail
FROM WHS_AuditLog WHERE ObjType = @objType AND DocEntry = @docEntry
  AND EXISTS (SELECT 1 FROM OKRN h WHERE h.ObjType = @objType AND h.DocEntry = @docEntry AND h.BPLId = @bplId)
ORDER BY LogTime DESC", new { objType, docEntry, bplId = u.BplId() }));
        });

        // ------------------------------------------------------------ Simpan perubahan Admin
        cms.MapPut("/docs/{objType}/{docEntry:long}", async (string objType, long docEntry, CmsSaveRequest req, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var trx = (req.TrxCode ?? "").Trim().ToUpperInvariant();
            if ((req.NumAtCard?.Length ?? 0) > 100 || (req.BlNo?.Length ?? 0) > 50 || (req.PtCode?.Length ?? 0) > 30 || (req.CardCode?.Length ?? 0) > 30)
                return Bad("Isian terlalu panjang");
            if ((req.Lines?.Count ?? 0) > 200) return Bad("Terlalu banyak baris");

            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.ReadCommitted);
            try
            {
                var h = await db.QueryFirstOrDefaultAsync<CmsHeaderRow>(Sql.CmsHeader, new { objType, docEntry, bplId = u.BplId() }, tx);
                if (h is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
                if (h.DocStatus == "C") return Bad("Dokumen sudah diposting (Close), tidak bisa diubah");

                var group = Group(h.ObjType, h.TrxCode);
                if (!AllowedTrx(group, h.IsTitipan).Contains(trx))
                    return Bad($"TrxCode {trx} tidak boleh untuk dokumen ini{(h.IsTitipan ? " (warehouse titipan)" : "")}");

                var lines = (await db.QueryAsync<CmsLineRow>(Sql.CmsLines, new { objType, docEntry }, tx)).ToList();
                var newObjType = TargetObjType(trx, h.ObjType);
                if (trx == "SS" && lines.Any(l => l.Flag == 1)) return Bad("Susut (SS) hanya untuk barang keluar; hapus Item Inbound dulu");

                var pt = Clean(req.PtCode);
                if (pt is not null && await db.ExecuteScalarAsync<int>(Sql.PtExists, new { ptCode = pt }, tx) == 0)
                    return Bad($"PT {pt} tidak ada di OPRC");

                var card = Clean(req.CardCode);
                var needType = RequiredCardType(newObjType, trx);
                if (needType is null) card = null;
                else if (card is not null)
                {
                    var type = await db.ExecuteScalarAsync<string?>(Sql.CardType, new { cardCode = card }, tx);
                    if (type is null) return Bad($"CardCode {card} tidak ditemukan");
                    if (type != needType) return Bad($"{trx} memerlukan {(needType == "S" ? "Supplier" : "Customer")} (CardType {needType})");
                }

                foreach (var e in req.Lines ?? new())
                {
                    var line = lines.FirstOrDefault(l => l.LineNum == e.LineNum);
                    if (line is null) return Bad($"Baris {e.LineNum} tidak ada");
                    if (e.Qty <= 0 || e.Qty2 < 0 || e.QtyPalet < 0 || e.Qty > 10_000_000 || e.Qty2 > 1_000_000 || e.QtyPalet > 10_000) return Bad($"Qty baris {e.LineNum + 1} tidak valid");
                    if ((e.NumAtCard?.Length ?? 0) > 50) return Bad("No DO per baris terlalu panjang");
                    var ruang = Clean(e.KodeRuangan);
                    if (ruang is not null && await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterRuangan WHERE KodeRuangan = @r AND WhsCode = @w AND Aktif = 1", new { r = ruang, w = h.WhsCode }, tx) == 0)
                        return Bad($"Ruangan {ruang} bukan milik gudang {h.WhsCode}");
                    await db.ExecuteAsync(Sql.CmsUpdateLine, new
                    {
                        objType, docEntry, lineNum = e.LineNum, qty = e.Qty, qty2 = e.Qty2, qtyPalet = e.QtyPalet, ruang,
                        numAtCard = trx == "RC" ? Clean(e.NumAtCard) : null,
                    }, tx);
                }

                var n = await db.ExecuteAsync(Sql.CmsUpdateHeader, new
                {
                    objType, docEntry, bplId = u.BplId(), trxCode = trx, ptCode = pt, cardCode = card,
                    numAtCard = Clean(req.NumAtCard), blNo = group == "inbound" && trx != "RC" ? Clean(req.BlNo) : null,
                }, tx);
                if (n == 0) return Bad("Dokumen berubah oleh user lain, muat ulang");

                var finalEntry = docEntry;
                if (newObjType != h.ObjType)
                {
                    // Pindah ObjType = nomor baru dari SYS_NOURUT untuk ObjType tujuan
                    var p = new DynamicParameters();
                    p.Add("@ObjType", newObjType);
                    p.Add("@DocDate", h.DocDate.Date, DbType.Date);
                    p.Add("@DocEntry", dbType: DbType.Int64, direction: ParameterDirection.Output);
                    await db.ExecuteAsync(Sql.NextDocEntry, p, tx, commandType: CommandType.StoredProcedure);
                    finalEntry = p.Get<long>("@DocEntry");
                    await db.ExecuteAsync(Sql.MoveLines, new { objType, docEntry, newObjType, newDocEntry = finalEntry }, tx);
                    await db.ExecuteAsync(Sql.MoveHeader, new { objType, docEntry, newObjType, newDocEntry = finalEntry, bplId = u.BplId() }, tx);
                }

                await db.ExecuteAsync(Sql.UpdateTotals, new { objType = newObjType, docEntry = finalEntry }, tx);
                await Audit.Write(db, tx, u, ctx, "CMS_SAVE", newObjType, finalEntry,
                    $"{h.TrxCode}->{trx}; PT={pt}; BP={card}; baris diedit={req.Lines?.Count ?? 0}" +
                    (newObjType != h.ObjType ? $"; nomor lama {h.ObjType}/{docEntry}" : ""));
                await tx.CommitAsync();
                return Results.Ok(new { objType = newObjType, docEntry = finalEntry, renumbered = newObjType != h.ObjType });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });

        // ------------------------------------------------------------ Posting -> stok, status Close
        cms.MapPost("/docs/{objType}/{docEntry:long}/post", async (string objType, long docEntry, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.ReadCommitted);
            try
            {
                var h = await db.QueryFirstOrDefaultAsync<CmsHeaderRow>(Sql.CmsHeader, new { objType, docEntry, bplId = u.BplId() }, tx);
                if (h is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
                if (h.DocStatus == "C") return Bad("Dokumen sudah diposting");
                var lines = (await db.QueryAsync<CmsLineRow>(Sql.CmsLines, new { objType, docEntry }, tx)).ToList();

                var errors = new List<string>();
                var group = Group(h.ObjType, h.TrxCode);
                if (!AllowedTrx(group, h.IsTitipan).Contains(h.TrxCode)) errors.Add($"TrxCode {h.TrxCode} belum dipilah dengan benar");
                if (string.IsNullOrWhiteSpace(h.PtCode)) errors.Add("PT belum diisi");
                if (lines.Count == 0) errors.Add("Dokumen tanpa baris");
                foreach (var l in lines.Where(l => string.IsNullOrWhiteSpace(l.KodeRuangan))) errors.Add($"Baris {l.LineNum + 1} ({l.ItemCode}) belum punya ruangan");

                var needType = RequiredCardType(h.ObjType, h.TrxCode);
                if (needType is not null)
                {
                    if (string.IsNullOrWhiteSpace(h.CardCode)) errors.Add(needType == "S" ? "Supplier (CardCode) belum diisi" : "Customer (CardCode) belum diisi");
                    else if (h.CardType != needType) errors.Add("CardType tidak sesuai TrxCode");
                }
                if ((h.TrxCode is "IB" or "OB" or "BT") && string.IsNullOrWhiteSpace(h.NumAtCard))
                    errors.Add("Nomor DO / NumAtCard belum diisi");
                if (h.ObjType == "6730" && (h.TrxCode is "IB" or "BT") && string.IsNullOrWhiteSpace(h.BlNo))
                    errors.Add("No BL belum diisi");

                if (h.TrxCode == "RC" && !string.IsNullOrWhiteSpace(h.CardCode))
                {
                    foreach (var l in lines)
                    {
                        if (string.IsNullOrWhiteSpace(l.NumAtCard)) { errors.Add($"Baris {l.LineNum + 1} {l.ItemCode}: No DO retur belum diisi"); continue; }
                        var ok = await db.ExecuteScalarAsync<int>(Sql.ReturDoValid, new { cardCode = h.CardCode, numAtCard = l.NumAtCard }, tx);
                        if (ok == 0) errors.Add($"Baris {l.LineNum + 1} {l.ItemCode}: DO {l.NumAtCard} tidak ada di ODLN customer {h.CardCode}");
                    }
                }

                // Flag harus konsisten dengan ObjType/TrxCode
                foreach (var l in lines)
                {
                    var okFlag = h.ObjType switch
                    {
                        "6730" => l.Flag == 1,
                        "6710" => l.Flag == -1,
                        _ => l.Flag is 1 or -1,
                    };
                    if (!okFlag) errors.Add($"Baris {l.LineNum + 1}: Flag {l.Flag} tidak sesuai {h.ObjType}");
                }

                if (errors.Count > 0)
                {
                    await tx.RollbackAsync();
                    return Results.BadRequest(new { message = "Belum bisa diposting", errors });
                }

                // Mutasi ke SaldoWhs / ItemHistoryWhs lewat stored procedure (opsional, lihat database/web_security.sql)
                var stockProc = cfg["Posting:StockProcedure"];
                if (!string.IsNullOrWhiteSpace(stockProc))
                    await db.ExecuteAsync(stockProc, new { ObjType = objType, DocEntry = docEntry }, tx, commandType: CommandType.StoredProcedure);

                await db.ExecuteAsync(Sql.CloseLines, new { objType, docEntry }, tx);
                var n = await db.ExecuteAsync(Sql.CloseHeader, new { objType, docEntry, bplId = u.BplId() }, tx);
                if (n == 0)
                {
                    await tx.RollbackAsync();
                    return Bad("Dokumen berubah oleh user lain, muat ulang");
                }
                await Audit.Write(db, tx, u, ctx, "CMS_POST", objType, docEntry, $"{h.TrxCode} {lines.Count} baris");
                await tx.CommitAsync();
                return Results.Ok(new { objType, docEntry, status = "C" });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });
    }

    static string Like(string? q)
    {
        var t = (q ?? "").Trim();
        if (t.Length > 50) t = t[..50];
        return $"%{t}%";
    }

    static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
