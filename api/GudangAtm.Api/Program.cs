using System.Security.Claims;
using System.Text;
using System.Threading.RateLimiting;
using Dapper;
using GudangAtm.Api;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using System.Net;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Data.SqlClient;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseWindowsService(); // jalan sebagai Windows Service (sc.exe / deploy\03-install-service.ps1); di konsol tetap jalan biasa
var cfg = builder.Configuration;

var connString = cfg.GetConnectionString("Gudang") ?? throw new InvalidOperationException("ConnectionStrings:Gudang belum diisi");
var jwtKey = cfg["Jwt:Key"] ?? throw new InvalidOperationException("Jwt:Key belum diisi");
if (jwtKey.Length < 32 || (jwtKey.StartsWith("GANTI", StringComparison.OrdinalIgnoreCase) && !builder.Environment.IsDevelopment()))
    throw new InvalidOperationException("Jwt:Key harus diganti dengan teks acak minimal 32 karakter");
var signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey));
var auth = new AuthOptions(
    connString,
    signingKey,
    cfg["Jwt:Issuer"] ?? "GudangAtm.Api",
    cfg.GetValue("Jwt:HoursValid", 12),
    cfg.GetSection("Security:AdminUsers").Get<string[]>() ?? Array.Empty<string>());

// HTTPS wajib di produksi (cookie Secure + __Host-). Bisa dimatikan hanya untuk uji coba lokal.
var requireHttps = cfg.GetValue("Security:RequireHttps", true);
var sessionMinutes = cfg.GetValue("Security:SessionMinutes", 30);

builder.WebHost.ConfigureKestrel(k =>
{
    k.AddServerHeader = false;
    k.Limits.MaxRequestBodySize = 1 * 1024 * 1024; // 1 MB
});
builder.Services.Configure<FormOptions>(o => o.MultipartBodyLengthLimit = 1 * 1024 * 1024);

builder.Services.AddSingleton(new LoginGuard
{
    MaxFails = cfg.GetValue("Security:MaxLoginFails", 5),
    LockFor = TimeSpan.FromMinutes(cfg.GetValue("Security:LockMinutes", 15)),
});

builder.Services.AddAntiforgery(o =>
{
    o.HeaderName = "X-XSRF-TOKEN";
    o.Cookie.Name = requireHttps ? "__Host-gudang-af" : "gudang-af";
    o.Cookie.HttpOnly = true;
    o.Cookie.SameSite = SameSiteMode.Strict;
    o.Cookie.SecurePolicy = requireHttps ? CookieSecurePolicy.Always : CookieSecurePolicy.SameAsRequest;
});

builder.Services
    .AddAuthentication(o =>
    {
        o.DefaultScheme = "smart";
        o.DefaultChallengeScheme = "smart";
    })
    // Web memakai cookie, aplikasi HP memakai header Authorization: Bearer
    .AddPolicyScheme("smart", "Cookie atau Bearer", o => o.ForwardDefaultSelector = ctx =>
        ctx.Request.Headers.Authorization.ToString().StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? JwtBearerDefaults.AuthenticationScheme
            : CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(o =>
    {
        o.Cookie.Name = requireHttps ? "__Host-gudang" : "gudang";
        o.Cookie.HttpOnly = true;
        o.Cookie.SameSite = SameSiteMode.Strict;
        o.Cookie.SecurePolicy = requireHttps ? CookieSecurePolicy.Always : CookieSecurePolicy.SameAsRequest;
        o.Cookie.Path = "/";
        o.SlidingExpiration = true;
        o.ExpireTimeSpan = TimeSpan.FromMinutes(sessionMinutes);
        o.Events.OnRedirectToLogin = c => { c.Response.StatusCode = StatusCodes.Status401Unauthorized; return Task.CompletedTask; };
        o.Events.OnRedirectToAccessDenied = c => { c.Response.StatusCode = StatusCodes.Status403Forbidden; return Task.CompletedTask; };
        // Cek ulang tiap 5 menit bahwa user masih ada di OUSR -> user yang dihapus kehilangan sesi web
        o.Events.OnValidatePrincipal = async c =>
        {
            var now = DateTimeOffset.UtcNow;
            if (c.Properties.Items.TryGetValue("chk", out var last) && DateTimeOffset.TryParse(last, out var t) && now - t < TimeSpan.FromMinutes(5))
                return;
            var uid = c.Principal?.FindFirstValue("uid");
            await using var db = new SqlConnection(connString);
            var exists = uid is not null && await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM OUSR WHERE USERID = @uid", new { uid = int.Parse(uid) }) > 0;
            if (!exists)
            {
                c.RejectPrincipal();
                await c.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
                return;
            }
            c.Properties.Items["chk"] = now.ToString("o");
            c.ShouldRenew = true;
        };
    })
    .AddJwtBearer(o =>
    {
        o.MapInboundClaims = false;
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = auth.JwtIssuer,
            ValidateAudience = false,
            ValidateLifetime = true,
            IssuerSigningKey = signingKey,
            ClockSkew = TimeSpan.FromMinutes(2),
            NameClaimType = "ucode",
            RoleClaimType = AuthEndpoints.RoleClaim,
        };
    });

builder.Services.AddAuthorization(o =>
{
    o.AddPolicy("Admin", p => p.RequireRole(Roles.Admin));
});

builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    // Login: 10 percobaan / menit / IP
    o.AddPolicy("login", ctx => RateLimitPartition.GetFixedWindowLimiter(
        ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 10, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
    // Semua request: 600 / menit per user (atau per IP bila belum login)
    o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx => RateLimitPartition.GetFixedWindowLimiter(
        ctx.User.FindFirstValue("uid") ?? ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 600, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});

// Di belakang reverse proxy (IIS/nginx): isi Security:KnownProxies supaya IP asli dipakai untuk rate limit & audit
var proxies = cfg.GetSection("Security:KnownProxies").Get<string[]>() ?? Array.Empty<string>();
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    foreach (var ip in proxies) o.KnownProxies.Add(IPAddress.Parse(ip));
});

var app = builder.Build();
if (proxies.Length > 0) app.UseForwardedHeaders();

// Error tidak membocorkan detail ke client; detail tetap tercatat di log server.
app.UseExceptionHandler(e => e.Run(async ctx =>
{
    ctx.Response.StatusCode = StatusCodes.Status500InternalServerError;
    await ctx.Response.WriteAsJsonAsync(new { message = "Terjadi kesalahan di server. Hubungi IT bila berulang." });
}));

if (requireHttps)
{
    app.UseHsts();
    app.UseHttpsRedirection();
}

app.UseSecurityHeaders();

// SPA (hasil build web/ disalin ke wwwroot)
app.UseDefaultFiles();
app.UseStaticFiles(new StaticFileOptions
{
    OnPrepareResponse = c =>
    {
        var path = c.Context.Request.Path.Value ?? "";
        c.Context.Response.Headers.CacheControl = path.StartsWith("/assets/")
            ? "public, max-age=31536000, immutable"
            : "no-cache";
    },
});

// Distribusi internal aplikasi (APK) tanpa Play Store: file ditaruh di folder di luar publish API (tidak terhapus saat update API)
{
    var unduh = cfg["Unduh:Folder"] ?? (OperatingSystem.IsWindows() ? @"C:\GudangAtm\unduh" : Path.Combine(app.Environment.ContentRootPath, "unduh"));
    Directory.CreateDirectory(unduh);
    var mime = new Microsoft.AspNetCore.StaticFiles.FileExtensionContentTypeProvider();
    mime.Mappings[".apk"] = "application/vnd.android.package-archive";
    mime.Mappings[".ipa"] = "application/octet-stream";
    app.UseDefaultFiles(new DefaultFilesOptions { RequestPath = "/unduh", FileProvider = new Microsoft.Extensions.FileProviders.PhysicalFileProvider(unduh) });
    app.UseStaticFiles(new StaticFileOptions
    {
        RequestPath = "/unduh",
        FileProvider = new Microsoft.Extensions.FileProviders.PhysicalFileProvider(unduh),
        ContentTypeProvider = mime,
        OnPrepareResponse = c => c.Context.Response.Headers.CacheControl = "no-cache",
    });
}

app.UseAuthentication();
app.UseRateLimiter();
app.UseCsrfProtection();
app.UseAuthorization();

SqlConnection Db() => new(connString);

app.MapGet("/api/health", () => Results.Ok(new { ok = true }));
app.MapAuth(auth);
app.MapGateway(Db);   // PC gateway gudang, auth lewat X-Gateway-Key (bukan cookie)

var api = app.MapGroup("/api").RequireAuthorization();
api.MapKrani(Db);
api.MapAlat(Db);
api.MapMasterBaca(Db);
api.MapPlanKrani(Db);
api.MapKendaraan(Db);
api.MapPlanKraniSave(Db);

var cms = app.MapGroup("/api/cms").RequireAuthorization("Admin");
cms.MapCms(Db, cfg);
cms.MapMaster(Db);
cms.MapPlan(Db);
cms.MapJadwal(Db);
cms.MapKendaraanAdmin(Db);
cms.MapSuratJalan(Db);

// Path /api yang tidak dikenal -> 404 JSON, selain itu -> halaman SPA
app.Map("/api/{**rest}", () => Results.NotFound(new { message = "Endpoint tidak ditemukan" }));
app.MapFallbackToFile("index.html");

app.Run();
