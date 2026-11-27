using System.Collections.Concurrent;
using System.Security.Claims;
using Dapper;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

/// Satu user hanya boleh punya SATU sesi aktif (web atau HP).
/// - Login saat masih ada sesi aktif (dipakai dalam IdleMinutes terakhir) ditolak 409, kecuali user memilih "keluarkan perangkat lain" (Paksa).
/// - Login baru mengganti SesiId; perangkat lama langsung ditolak (401 SESI_DIGANTI) pada request berikutnya.
/// Tabel dbo.WHS_UserSesi (gudang_atm_v2_tambahan.sql). Bila tabel belum ada, aturan ini dilewati (tidak mengunci login).
public sealed class SesiStore(string connString, int idleMinutes)
{
    readonly ConcurrentDictionary<int, (string Sid, DateTime Cek, DateTime Seen)> _cache = new();
    public int IdleMinutes => idleMinutes;

    static bool TabelBelumAda(SqlException e) => e.Number == 208;

    public record Aktif(string Perangkat, DateTime LoginAt, DateTime LastSeen);

    /// Sesi lain yang masih aktif untuk user ini (null bila tidak ada / sudah idle).
    public async Task<Aktif?> CariAktif(int userId)
    {
        try
        {
            await using var db = new SqlConnection(connString);
            return await db.QueryFirstOrDefaultAsync<Aktif>(
                "SELECT Perangkat, LoginAt, LastSeen FROM WHS_UserSesi WHERE UserId = @userId AND LastSeen > DATEADD(MINUTE, -@idle, SYSDATETIME())",
                new { userId, idle = idleMinutes });
        }
        catch (SqlException e) when (TabelBelumAda(e)) { return null; }
    }

    public async Task<string> Mulai(int userId, string perangkat, string? ip)
    {
        var sid = Guid.NewGuid().ToString("N");
        try
        {
            await using var db = new SqlConnection(connString);
            await db.ExecuteAsync(@"
MERGE WHS_UserSesi AS t USING (SELECT @userId AS UserId) s ON t.UserId = s.UserId
WHEN MATCHED THEN UPDATE SET SesiId = @sid, Perangkat = @perangkat, Ip = @ip, LoginAt = SYSDATETIME(), LastSeen = SYSDATETIME()
WHEN NOT MATCHED THEN INSERT (UserId, SesiId, Perangkat, Ip, LoginAt, LastSeen) VALUES (@userId, @sid, @perangkat, @ip, SYSDATETIME(), SYSDATETIME());",
                new { userId, sid, perangkat, ip });
        }
        catch (SqlException e) when (TabelBelumAda(e)) { }
        _cache[userId] = (sid, DateTime.UtcNow, DateTime.UtcNow);
        return sid;
    }

    public async Task Selesai(int userId, string? sid)
    {
        _cache.TryRemove(userId, out _);
        try
        {
            await using var db = new SqlConnection(connString);
            // tanpa hak DELETE: sesi dikosongkan (tidak aktif, sid lama tidak sah lagi)
            await db.ExecuteAsync("UPDATE WHS_UserSesi SET SesiId = '', LastSeen = '2000-01-01' WHERE UserId = @userId AND SesiId = @sid", new { userId, sid });
        }
        catch (SqlException e) when (TabelBelumAda(e)) { }
    }

    /// true bila sid masih sesi aktif user. Dicache 15 detik; LastSeen diperbarui paling sering 1x per menit.
    public async Task<bool> Sah(int userId, string? sid)
    {
        var now = DateTime.UtcNow;
        if (_cache.TryGetValue(userId, out var c) && now - c.Cek < TimeSpan.FromSeconds(15))
        {
            if (c.Sid != sid) return false;
            if (now - c.Seen < TimeSpan.FromMinutes(1)) return true;
        }
        try
        {
            await using var db = new SqlConnection(connString);
            var cur = await db.ExecuteScalarAsync<string?>("SELECT SesiId FROM WHS_UserSesi WHERE UserId = @userId", new { userId });
            if (cur is null || cur != sid) { _cache[userId] = (cur ?? "", now, now); return false; }
            await db.ExecuteAsync("UPDATE WHS_UserSesi SET LastSeen = SYSDATETIME() WHERE UserId = @userId AND SesiId = @sid", new { userId, sid });
            _cache[userId] = (sid, now, now);
            return true;
        }
        catch (SqlException e) when (TabelBelumAda(e)) { return true; }
    }
}

public static class SesiMiddleware
{
    public const string Pesan = "Akun ini sudah login di perangkat lain. Silakan login ulang.";

    /// Setelah UseAuthentication: request /api dari user login wajib membawa sesi (claim "sid") yang masih aktif.
    public static IApplicationBuilder UseSatuSesi(this IApplicationBuilder app) => app.Use(async (ctx, next) =>
    {
        var path = ctx.Request.Path.Value ?? "";
        if (ctx.User.Identity?.IsAuthenticated == true && path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase)
            && !path.StartsWith("/api/auth/login", StringComparison.OrdinalIgnoreCase)
            && !path.StartsWith("/api/auth/web-login", StringComparison.OrdinalIgnoreCase)
            && !path.StartsWith("/api/auth/csrf", StringComparison.OrdinalIgnoreCase)
            && int.TryParse(ctx.User.FindFirstValue("uid"), out var uid))
        {
            var store = ctx.RequestServices.GetRequiredService<SesiStore>();
            if (!await store.Sah(uid, ctx.User.FindFirstValue("sid")))
            {
                if (!ctx.Request.Headers.Authorization.ToString().StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
                    await ctx.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await ctx.Response.WriteAsJsonAsync(new { message = Pesan, code = "SESI_DIGANTI" });
                return;
            }
        }
        await next();
    });
}
