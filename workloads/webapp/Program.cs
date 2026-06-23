// Tiny ASP.NET Core minimal-API "hello world" used by the demo lab so
// Application Insights has real traffic + dependencies + intentional failures.
//
// Endpoints:
//   GET /                  -> 200 "Hello from Azure Monitor Demo Lab"
//   GET /healthz           -> 200 "OK"
//   GET /api/explode       -> 500 (used by load gen to produce failures)
//   GET /api/slow          -> 200 after 1.5-3 s (slow-trace demo)
//   GET /api/dep           -> calls a public HTTPS endpoint -> AppDependencies row
//   GET /api/checkout      -> emits a CUSTOM metric (amlab.cartValue) + CUSTOM event
//                            (CheckoutCompleted) via TelemetryClient. Demonstrates
//                            custom telemetry alongside codeless auto-instrumentation.
//   GET /api/inefficient   -> deliberately bad .NET code (string concat in loop,
//                            excessive exception throwing, sync-over-async). Used
//                            by scripts/trigger-code-optimization.ps1 to surface
//                            App Insights Code Optimizations recommendations.

using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddHttpClient();

var app = builder.Build();

app.MapGet("/", () => Results.Text("Hello from Azure Monitor Demo Lab"));
app.MapGet("/healthz", () => Results.Text("OK"));

app.MapGet("/api/explode", () =>
{
    throw new InvalidOperationException("Intentional demo failure for App Insights.");
});

app.MapGet("/api/slow", async () =>
{
    var rnd = Random.Shared.Next(1500, 3000);
    await Task.Delay(rnd);
    return Results.Text($"slow ok in {rnd}ms");
});

app.MapGet("/api/dep", async (IHttpClientFactory f) =>
{
    var http = f.CreateClient();
    var r = await http.GetAsync("https://aka.ms/azurelandingzonesfaq");
    return Results.Text($"dep status={(int)r.StatusCode}");
});

// FEATURE - Custom telemetry alongside codeless auto-instrumentation.
//   - customMetrics | where name == "amlab.cartValue"
//   - customEvents  | where name == "CheckoutCompleted"
app.MapGet("/api/checkout", (HttpRequest request, TelemetryClient tc) =>
{
    var cart = Math.Round(Random.Shared.NextDouble() * 250.0 + 5.0, 2);
    var items = Random.Shared.Next(1, 6);
    var paymentOk = Random.Shared.NextDouble() > 0.05; // 5% intentional failure rate
    var channel = request.Headers.TryGetValue("X-Amlab-Channel", out var v) ? v.ToString() : "web";

    // Custom metrics aggregate locally inside the SDK (pre-aggregated metrics).
    tc.GetMetric("amlab.cartValue").TrackValue(cart);
    tc.GetMetric("amlab.cartItems").TrackValue(items);

    // Custom event — visible in Usage / customEvents table.
    tc.TrackEvent("CheckoutCompleted",
        properties: new Dictionary<string, string>
        {
            { "paymentResult", paymentOk ? "ok" : "declined" },
            { "channel",       channel }
        },
        metrics: new Dictionary<string, double>
        {
            { "cartValue", cart },
            { "items",     items }
        });

    if (!paymentOk)
    {
        return Results.Problem("payment declined", statusCode: 402);
    }
    return Results.Json(new { cartValue = cart, items, payment = "ok" });
});

// FEATURE - Intentionally inefficient endpoint that surfaces App Insights
// Code Optimizations recommendations. Profiler captures stacks, the Code
// Optimizations service analyses them, and within a few hours of sustained
// traffic recommendations show up under "Investigate -> Code Optimizations".
//
// Anti-patterns combined here on purpose (each is a known detection class):
//   1. String concatenation in a tight loop  -> "Use StringBuilder" insight
//   2. Throw + catch in a hot loop           -> "Excessive exceptions" insight
//   3. Sync-over-async (Task.Result/.Wait()) -> "Sync over async" insight
//   4. Large List<T> Contains() in a loop    -> O(n*n) CPU hot-path
//
// Triggered by scripts/trigger-code-optimization.ps1.
app.MapGet("/api/inefficient", (IHttpClientFactory f) =>
{
    // (1) String concatenation in a loop — classic Code Optimizations target.
    var s = string.Empty;
    for (var i = 0; i < 5_000; i++)
    {
        s += "x" + i.ToString();
    }

    // (2) Throw + catch in a hot loop — flagged as "excessive exceptions".
    var caught = 0;
    for (var i = 0; i < 200; i++)
    {
        try
        {
            throw new InvalidOperationException("intentional anti-pattern");
        }
        catch (InvalidOperationException)
        {
            caught++;
        }
    }

    // (3) Sync-over-async — blocking on an async HTTP call from a thread-pool thread.
    var http = f.CreateClient();
    var depStatus = (int)http.GetAsync("https://aka.ms/azurelandingzonesfaq").Result.StatusCode;

    // (4) O(n*n) List.Contains in a loop — CPU hot-path that Profiler will sample.
    var pool = Enumerable.Range(0, 5_000).ToList();
    var hits = 0;
    for (var i = 0; i < 5_000; i++)
    {
        if (pool.Contains(i)) { hits++; }
    }

    return Results.Json(new
    {
        len = s.Length,
        caughtExceptions = caught,
        depStatus,
        containsHits = hits
    });
});

app.Run();
