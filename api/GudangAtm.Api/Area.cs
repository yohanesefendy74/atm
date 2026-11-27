using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

/// Area gudang = OWHS.State. Satu area bisa berisi beberapa kode gudang yang memakai pos timbang, yard dan kendaraan bersama:
/// satu mobil boleh mengerjakan SPBB / SPMB dari kode gudang berbeda dalam area yang sama.
/// Gudang tanpa State dianggap area sendiri (hanya kode gudang itu).
public static class Area
{
    /// Potongan SQL: daftar kode gudang satu area dengan parameter @param (dipakai sebagai "WhsCode IN (...)").
    public static string In(string param) =>
        $"(SELECT w2.WhsCode FROM OWHS w1 JOIN OWHS w2 ON w2.State = w1.State WHERE w1.WhsCode = {param} AND ISNULL(w1.State, '') <> '' UNION SELECT {param})";

    public static async Task<List<string>> Gudang(SqlConnection db, SqlTransaction? tx, string whs) =>
        (await db.QueryAsync<string>($"SELECT WhsCode FROM {In("@whs")} x", new { whs }, tx)).ToList();

    public static async Task<bool> Sama(SqlConnection db, SqlTransaction? tx, string a, string b) =>
        string.Equals(a, b, StringComparison.OrdinalIgnoreCase)
        || await db.ExecuteScalarAsync<int>($"SELECT COUNT(*) FROM {In("@a")} x WHERE x.WhsCode = @b", new { a, b }, tx) > 0;

    /// User punya akses ke salah satu kode gudang dalam area.
    public static async Task<bool> Akses(SqlConnection db, SqlTransaction? tx, int userId, string whs) =>
        await db.ExecuteScalarAsync<int>($"SELECT COUNT(*) FROM USR9 WHERE UserId = @userId AND WhsCode IN {In("@whs")}", new { userId, whs }, tx) > 0;
}
