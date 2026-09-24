// ScanlyApi — Scenario A: Faktura-analys
// ─────────────────────────────────────────────────────────────────
// Starta lokalt: dotnet run  →  Swagger: http://localhost:5000/swagger
//
// Miljövariabler (Container Apps → Settings → Environment variables):
//   AZURE_DI_ENDPOINT     https://{din-di-resurs}.cognitiveservices.azure.com/
//   AZURE_DI_KEY          API-nyckel (används om Managed Identity inte är tillgänglig)
//   AZURE_STORAGE_URL     https://{ditt-konto}.blob.core.windows.net/
//
// Auth-prioritet: AZURE_DI_KEY (API-nyckel) → DefaultAzureCredential (Managed Identity)
// Managed Identity-roller (om ingen nyckel används):
//   "Cognitive Services User"       →  på Document Intelligence-resursen
//   "Storage Blob Data Contributor" →  på Storage Account
//
// Saknas AZURE_DI_ENDPOINT → API:et körs i demo-läge (mock-svar, ingen Azure-anrop)
// ─────────────────────────────────────────────────────────────────

using Azure;
using Azure.AI.FormRecognizer.DocumentAnalysis;
using Azure.Identity;
using Azure.Storage.Blobs;
using System.Text.Json;

var diEndpoint = Environment.GetEnvironmentVariable("AZURE_DI_ENDPOINT");
var diKey = Environment.GetEnvironmentVariable("AZURE_DI_KEY");
var storageUrl = Environment.GetEnvironmentVariable("AZURE_STORAGE_URL");
var azureMode = diEndpoint is not null && storageUrl is not null;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(o => o.SwaggerDoc("v1", new() { Title = "Scanly API", Version = "v1" }));
var app = builder.Build();
app.UseSwagger();
app.UseSwaggerUI();
var logger = app.Logger;

// Azure-klienter — aktiveras automatiskt när miljövariablerna är satta
DocumentAnalysisClient? diClient = null;
BlobContainerClient? blobs = null;
if (azureMode)
{
    var storageCred = new DefaultAzureCredential();
    diClient = diKey is not null
        ? new DocumentAnalysisClient(new Uri(diEndpoint!), new AzureKeyCredential(diKey))
        : new DocumentAnalysisClient(new Uri(diEndpoint!), storageCred);
    blobs = new BlobServiceClient(new Uri(storageUrl!), storageCred).GetBlobContainerClient("invoices");
    await blobs.CreateIfNotExistsAsync();
}

// In-memory cache (demo-lägets enda lagring, Azure-lägets snabbcache)
var fakturor = new Dictionary<string, FakturaResultat>();

// ── GET /health ──────────────────────────────────────────────────
app.MapGet("/health", () => new { status = "ok", mode = azureMode ? "azure" : "demo" })
   .WithTags("Status").Produces<object>(200);

// ── POST /invoices ───────────────────────────────────────────────
app.MapPost("/invoices", async (IFormFile file) =>
{
    if (file is null || file.Length == 0)
    {
        logger.LogWarning("En tom eller ogiltig fil skickades till /invoices");
        return Results.BadRequest(new { fel = "Skicka en PDF- eller bildfil." });

    }

    var id = Guid.NewGuid().ToString("N")[..8];

    logger.LogInformation(
        "Börjar behandla faktura {InvoiceId}. Fil: {FileName}, Storlek: {FileSize} bytes",
        id,
        file.FileName,
        file.Length);


    FakturaResultat r;

    if (!azureMode || diClient is null)
    {
        r = new(id, "Demo Leverantör AB", 12500m,
            DateTime.UtcNow.AddDays(30).ToString("yyyy-MM-dd"), "SEK", "klar (demo-läge)", new List<Radpost>());
    }
    else
    {
        try
        {
            using var stream = file.OpenReadStream();

            logger.LogInformation(
                "Startar Document Intelligence-analys för faktura {InvoiceId}",
                id);

            var op = await diClient.AnalyzeDocumentAsync(
                WaitUntil.Completed,
                "prebuilt-invoice",
                stream);

            var doc = op.Value.Documents.FirstOrDefault();

            logger.LogInformation(
                "Document Intelligence-analys klar för faktura {InvoiceId}",
                id);

            r = ParseFaktura(doc, id);

            await blobs!.UploadBlobAsync(
                $"{id}.json",
                new BinaryData(JsonSerializer.Serialize(r)));

            logger.LogInformation(
                "Analysresultat för faktura {InvoiceId} sparat i Blob Storage",
                id);
        }
        catch (RequestFailedException ex)
        {
            logger.LogError(
                ex,
                "Azure-fel vid behandling av faktura {InvoiceId}. Statuskod: {StatusCode}",
                id,
                ex.Status);

            return Results.Problem(
                title: "Kunde inte behandla fakturan",
                detail: "Filen kunde inte analyseras av Document Intelligence. Kontrollera att filtypen stöds och att filen inte är lösenordsskyddad.",
                statusCode: StatusCodes.Status400BadRequest);
        }
        catch (Exception ex)
        {
            logger.LogError(
                ex,
                "Oväntat fel vid behandling av faktura {InvoiceId}",
                id);

            return Results.Problem(
                title: "Internt serverfel",
                detail: "Fakturan kunde inte behandlas.",
                statusCode: StatusCodes.Status500InternalServerError);
        }
    }


    fakturor[id] = r;

    return Results.Created($"/invoices/{id}", new { id, r.Status });
})
.WithTags("Fakturor")
.WithSummary("Ladda upp faktura (PDF/bild) för Document Intelligence-analys")
.Produces<object>(201)
.Produces(400)
.DisableAntiforgery();

// ── GET /invoices/{id} ───────────────────────────────────────────
app.MapGet("/invoices/{id}", async (string id) =>
{
    if (fakturor.TryGetValue(id, out var cached)) return Results.Ok(cached);
    if (blobs is null) return Results.NotFound();

    var blob = blobs.GetBlobClient($"{id}.json");
    if (!await blob.ExistsAsync()) return Results.NotFound();
    var download = await blob.DownloadContentAsync();
    return Results.Ok(JsonSerializer.Deserialize<FakturaResultat>(download.Value.Content));
})
.WithTags("Fakturor").WithSummary("Hämta analysresultat för en faktura")
.Produces<FakturaResultat>(200).Produces(404);

// ── GET /invoices ────────────────────────────────────────────────
app.MapGet("/invoices", async () =>
{
    if (blobs is null) return Results.Ok(fakturor.Values);
    var ids = new List<string>();
    await foreach (var b in blobs.GetBlobsAsync()) ids.Add(b.Name.Replace(".json", ""));
    return Results.Ok(ids);
})
.WithTags("Fakturor").WithSummary("Lista alla faktura-ID:n").Produces<List<string>>(200);

app.Run();

// Lokal funktion måste ligga FÖRE record-deklarationen i top-level context
static FakturaResultat ParseFaktura(AnalyzedDocument? doc, string id)
{
    if (doc is null)
        return new(id, "Okänd", 0m, "", "SEK", "fel: tomt svar", new List<Radpost>());

    string Get(string k) =>
        doc.Fields.TryGetValue(k, out var f)
            ? f.Content ?? ""
            : "";

    decimal GetDec(string k)
    {
        if (!doc.Fields.TryGetValue(k, out var f) || f.Value is null)
            return 0m;

        try
        {
            return (decimal)f.Value.AsCurrency().Amount;
        }
        catch
        {
            return 0m;
        }
    }

    List<Radpost> GetRadposter()
    {
        var radposter = new List<Radpost>();

        if (!doc.Fields.TryGetValue("Items", out var itemsField) ||
            itemsField.Value is null)
        {
            return radposter;
        }

        foreach (var item in itemsField.Value.AsList())
        {
            var itemObject = item.Value.AsDictionary();

            string GetItemString(string key)
            {
                return itemObject.TryGetValue(key, out var field)
                    ? field.Content ?? ""
                    : "";
            }

            decimal GetItemDecimal(string key)
            {
                if (!itemObject.TryGetValue(key, out var field) ||
                    field.Value is null)
                {
                    return 0m;
                }

                try
                {
                    if (field.Value.AsCurrency() is { } currency)
                        return (decimal)currency.Amount;
                }
                catch
                {
                    // Not a Currency field
                }

                try
                {
                    return (decimal)field.Value.AsDouble();
                }
                catch
                {
                    return 0m;
                }
            }

            radposter.Add(new Radpost(
                GetItemString("Description"),
                GetItemDecimal("Quantity"),
                GetItemDecimal("UnitPrice"),
                GetItemDecimal("Amount")));
        }

        return radposter;
    }

    return new(
        id,
        Get("VendorName"),
        GetDec("InvoiceTotal"),
        Get("DueDate"),
        "SEK",
        "klar",
        GetRadposter());
}

// ── Modeller ─────────────────────────────────────────────────────
record FakturaResultat(
    string Id,
    string Leverantor,
    decimal Totalbelopp,
    string Forfallodatum,
    string Valuta,
    string Status,
    List<Radpost> Radposter);

record Radpost(
    string Beskrivning,
    decimal Antal,
    decimal Enhetspris,
    decimal Belopp);