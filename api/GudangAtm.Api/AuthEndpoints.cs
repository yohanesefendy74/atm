using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Dapper;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.Data.SqlClient;
using Microsoft.IdentityModel.Tokens;

namespace GudangAtm.Api;

public record AuthOptions(
    string ConnString,
    SymmetricSecurityKey SigningKey,
    string JwtIssuer,
    int JwtHours,
    string[] AdminUsers);

public static class AuthEndpoints
{
    public const string RoleClaim = "role";

    static IResult Unauthorized(string message) => Results.Json(new { message }, statusCode: 401);

    /// Cek user + password ke OUSR, dengan penguncian setelah 5x gagal.
    static async Task<(LoginUser? user, IResult? error)> Verify(LoginRequest req, AuthOptions opt, LoginGuard guard, HttpContext ctx, ILogger log)
    {
        var code = (req.UserCode ?? "").Trim();
        if (code.Length == 0 || string.IsNullOrEmpty(req.Password) || code.Length > 50 || req.Password.Length > 128)
            return (null, Results.BadRequest(new { message = "User dan password wajib diisi" }));

        if (guard.LockedFor(code) is { } wait)
        {
            await Audit.TryWrite(opt.ConnString, ctx, "LOGIN_LOCKED", code, null, log);
            return (null, Results.Json(new { message = $"Akun dikunci sementara karena salah password berulang. Coba lagi {Math.Ceiling(wait.TotalMinutes)} menit lagi." }, statusCode: 429));
        }

        // OUSR.password disimpan Base64 (encoding, bukan enkripsi) — lihat README bagian keamanan.
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(req.Password));
        await using var db = new SqlConnection(opt.ConnString);
        var user = await db.QueryFirstOrDefaultAsync<LoginUser>(Sql.Login, new { userCode = code, passwordB64 = b64 });
        if (user is null)
        {
            guard.Fail(code);
            await Audit.TryWrite(opt.ConnString, ctx, "LOGIN_FAIL", code, null, log);
            // pesan sama untuk user tidak ada / password salah (tidak membocorkan user mana yang valid)
            return (null, Unauthorized("User atau password salah"));
        }
        guard.Success(code);
        await Audit.TryWrite(opt.ConnString, ctx, "LOGIN_OK", user.UserCode, null, log);
        return (user, null);
    }

    static List<string> RolesFor(LoginUser u, AuthOptions opt)
    {
        var roles = new List<string> { Roles.Krani };
        if (u.SuperUser || opt.AdminUsers.Contains(u.UserCode, StringComparer.OrdinalIgnoreCase)) roles.Add(Roles.Admin);
        return roles;
    }

    static List<Claim> Claims(LoginUser u, List<string> roles)
    {
        var c = new List<Claim>
        {
            new("uid", u.UserId.ToString()),
            new("ucode", u.UserCode),
            new("bpl", u.BplId.ToString()),
            new("name", u.Name ?? u.UserCode),
            new("whs", u.DefaultWhs ?? ""),
        };
        c.AddRange(roles.Select(r => new Claim(RoleClaim, r)));
        return c;
    }

    static object Me(ClaimsPrincipal p) => new
    {
        userId = int.Parse(p.FindFirstValue("uid")!),
        userCode = p.FindFirstValue("ucode"),
        name = p.FindFirstValue("name"),
        bplId = int.Parse(p.FindFirstValue("bpl")!),
        defaultWhs = p.FindFirstValue("whs"),
        roles = p.FindAll(RoleClaim).Select(c => c.Value).ToArray(),
    };

    public static void MapAuth(this WebApplication app, AuthOptions opt)
    {
        // Token anti-CSRF untuk SPA (dibaca dari body, dikirim balik di header X-XSRF-TOKEN)
        app.MapGet("/api/auth/csrf", (IAntiforgery af, HttpContext ctx) =>
            Results.Ok(new { token = af.GetAndStoreTokens(ctx).RequestToken }));

        // ---- Web (cookie HttpOnly + SameSite=Strict)
        app.MapPost("/api/auth/web-login", async (LoginRequest req, LoginGuard guard, IAntiforgery af, HttpContext ctx, ILogger<LoginGuard> log) =>
        {
            var (user, error) = await Verify(req, opt, guard, ctx, log);
            if (user is null) return error!;
            var roles = RolesFor(user, opt);
            var principal = new ClaimsPrincipal(new ClaimsIdentity(Claims(user, roles), CookieAuthenticationDefaults.AuthenticationScheme, "ucode", RoleClaim));
            await ctx.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal);
            // token CSRF terikat ke identitas -> buat baru untuk user yang baru login
            ctx.User = principal;
            var csrf = af.GetAndStoreTokens(ctx).RequestToken;
            return Results.Ok(new { user = Me(principal), csrf });
        }).RequireRateLimiting("login");

        app.MapPost("/api/auth/logout", async (HttpContext ctx) =>
        {
            await Audit.TryWrite(opt.ConnString, ctx, "LOGOUT", ctx.User.UserCode(), null, ctx.RequestServices.GetRequiredService<ILogger<LoginGuard>>());
            await ctx.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return Results.Ok(new { ok = true });
        }).RequireAuthorization();

        app.MapGet("/api/auth/me", (ClaimsPrincipal u) => Results.Ok(Me(u))).RequireAuthorization();

        // ---- Aplikasi HP (Bearer JWT, tidak memakai cookie)
        app.MapPost("/api/auth/login", async (LoginRequest req, LoginGuard guard, HttpContext ctx, ILogger<LoginGuard> log) =>
        {
            var (user, error) = await Verify(req, opt, guard, ctx, log);
            if (user is null) return error!;
            var roles = RolesFor(user, opt);
            var token = new JwtSecurityToken(
                issuer: opt.JwtIssuer,
                claims: Claims(user, roles),
                expires: DateTime.UtcNow.AddHours(opt.JwtHours),
                signingCredentials: new SigningCredentials(opt.SigningKey, SecurityAlgorithms.HmacSha256));
            return Results.Ok(new { token = new JwtSecurityTokenHandler().WriteToken(token), user, roles });
        }).RequireRateLimiting("login");
    }
}
