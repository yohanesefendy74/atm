using System.Collections.Concurrent;
using System.Security.Claims;
using Dapper;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public static class Roles
{
    public const string Admin = "Admin";
    public const string Krani = "Krani";
}

public static class UserExt
{
    public static int UserId(this ClaimsPrincipal u) => int.Parse(u.FindFirstValue("uid")!);
    public static int BplId(this ClaimsPrincipal u) => int.Parse(u.FindFirstValue("bpl")!);
    public static string UserCode(this ClaimsPrincipal u) => u.FindFirstValue("ucode") ?? "";
    public static string Ip(this HttpContext c) => c.Connection.RemoteIpAddress?.ToString() ?? "";
}

/// Penguncian akun setelah salah password berulang (per user code), di memori server.
/// Dikombinasikan dengan rate limit per IP di Program.cs.
public class LoginGuard
{
    private readonly ConcurrentDictionary<string, (int Fails, DateTime? LockedUntil)> _state = new();
    public int MaxFails { get; init; } = 5;
    public TimeSpan LockFor { get; init; } = TimeSpan.FromMinutes(15);

    private static string Key(string userCode) => userCode.Trim().ToUpperInvariant();

    public TimeSpan? LockedFor(string userCode)
    {
        if (_state.TryGetValue(Key(userCode), out var s) && s.LockedUntil is { } until && until > DateTime.UtcNow)
            return until - DateTime.UtcNow;
        return null;
    }

    public void Fail(string userCode) => _state.AddOrUpdate(Key(userCode),
        _ => (1, null),
        (_, s) =>
        {
            // Kunci lama yang sudah habis dibuang; bila tetap disimpan, hitungan selalu kembali ke 1 dan akun tidak pernah terkunci lagi.
            var expired = s.LockedUntil is { } u && u <= DateTime.UtcNow;
            var fails = expired ? 1 : s.Fails + 1;
            return fails >= MaxFails ? (0, DateTime.UtcNow.Add(LockFor)) : (fails, expired ? null : s.LockedUntil);
        });

    public void Success(string userCode) => _state.TryRemove(Key(userCode), out _);
}

/// Catatan audit ke tabel WHS_AuditLog. Login dicatat "best effort"; perubahan CMS dicatat dalam transaksi yang sama.
public static class Audit
{
    public static Task Write(SqlConnection db, SqlTransaction? tx, ClaimsPrincipal? u, HttpContext ctx, string action,
        string? objType = null, long? docEntry = null, string? detail = null, string? userCode = null) =>
        db.ExecuteAsync(Sql.Audit, new
        {
            userId = u?.FindFirstValue("uid") is { } id ? int.Parse(id) : (int?)null,
            userCode = userCode ?? u?.UserCode(),
            action,
            objType,
            docEntry,
            detail = detail is { Length: > 1000 } ? detail[..1000] : detail,
            ip = ctx.Ip(),
        }, tx);

    /// Audit yang tidak boleh menggagalkan proses utama (dokumen sudah tersimpan).
    public static async Task Safe(SqlConnection db, ClaimsPrincipal u, HttpContext ctx, string action,
        string? objType = null, long? docEntry = null, string? detail = null)
    {
        try
        {
            await Write(db, null, u, ctx, action, objType, docEntry, detail);
        }
        catch (Exception e)
        {
            ctx.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("Audit")
                .LogWarning(e, "Audit log gagal ditulis ({Action} {ObjType}/{DocEntry})", action, objType, docEntry);
        }
    }

    public static async Task TryWrite(string connString, HttpContext ctx, string action, string? userCode, string? detail, ILogger log)
    {
        try
        {
            await using var db = new SqlConnection(connString);
            await Write(db, null, null, ctx, action, detail: detail, userCode: userCode);
        }
        catch (Exception e)
        {
            log.LogWarning(e, "Audit log gagal ditulis ({Action})", action);
        }
    }
}

public static class SecurityMiddleware
{
    /// Header keamanan untuk semua respons (SPA dan API).
    public static IApplicationBuilder UseSecurityHeaders(this IApplicationBuilder app) => app.Use(async (ctx, next) =>
    {
        var h = ctx.Response.Headers;
        h["X-Content-Type-Options"] = "nosniff";
        h["X-Frame-Options"] = "DENY";
        h["Referrer-Policy"] = "no-referrer";
        h["Cross-Origin-Opener-Policy"] = "same-origin";
        h["Cross-Origin-Resource-Policy"] = "same-origin";
        h["Permissions-Policy"] = "camera=(self), microphone=(), geolocation=(), payment=(), usb=()";
        h["Content-Security-Policy"] =
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; font-src 'self'; " +
            "connect-src 'self'; media-src 'self' blob:; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";
        if (ctx.Request.Path.StartsWithSegments("/api"))
            h["Cache-Control"] = "no-store";
        await next();
    });

    /// Anti-CSRF untuk request yang memakai cookie (web). Request dengan Bearer token (aplikasi HP) tidak memakai cookie
    /// sehingga tidak rentan CSRF dan tidak dicek di sini.
    public static IApplicationBuilder UseCsrfProtection(this IApplicationBuilder app) => app.Use(async (ctx, next) =>
    {
        var method = ctx.Request.Method;
        var unsafeMethod = !(HttpMethods.IsGet(method) || HttpMethods.IsHead(method) || HttpMethods.IsOptions(method));
        var bearer = ctx.Request.Headers.Authorization.ToString().StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase);
        var isMobileLogin = ctx.Request.Path.Equals("/api/auth/login", StringComparison.OrdinalIgnoreCase);
        if (unsafeMethod && !bearer && !isMobileLogin && ctx.Request.Path.StartsWithSegments("/api"))
        {
            var af = ctx.RequestServices.GetRequiredService<IAntiforgery>();
            try
            {
                await af.ValidateRequestAsync(ctx);
            }
            catch (AntiforgeryValidationException)
            {
                ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
                await ctx.Response.WriteAsJsonAsync(new { message = "Sesi keamanan kedaluwarsa, muat ulang halaman" });
                return;
            }
        }
        await next();
    });
}
