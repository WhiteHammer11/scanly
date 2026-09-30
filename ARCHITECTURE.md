# Scanly AB – Lösningsarkitektur

## 1. Översikt

Scanly AB är en molnbaserad applikation för automatisk behandling av fakturor.

Lösningen består av ett .NET 8 REST API som körs i Azure Container Apps. Användaren skickar in en faktura som PDF via API:t. API:t skickar fakturan till Azure Document Intelligence för analys och sparar sedan resultatet som JSON i Azure Blob Storage.

Projektet använder GitHub Actions för CI/CD och Azure Container Registry för lagring av containerimages. Azure-infrastrukturen beskrivs med Bicep som Infrastructure as Code.

## 2. Arkitekturdiagram

```mermaid
flowchart LR

    Client[Klient]

    API[Azure Container Apps<br/>Scanly REST API<br/>.NET 8]

    DI[Azure Document Intelligence<br/>prebuilt-invoice]

    Blob[Azure Blob Storage<br/>invoices]

    ACR[Azure Container Registry]

    GitHub[GitHub Repository]

    Actions[GitHub Actions<br/>CI/CD]

    Bicep[Bicep<br/>Infrastructure as Code]

    Client -->|HTTPS / POST /invoices| API

    API -->|1. Skickar faktura| DI
    DI -->|2. Strukturerat fakturaresultat| API

    API -->|3. Sparar JSON| Blob

    GitHub -->|push main| Actions
    Actions -->|build + push| ACR
    Actions -->|deploy| API

    ACR -->|Container image| API

    Bicep -->|Provisionerar| Azure[Azure-resurser]

    Azure --> ACR
    Azure --> Blob
    Azure --> API

    API -.->|Managed Identity + RBAC| Blob
    API -.->|Managed Identity + AcrPull| ACR

    API -.->|AZURE_DI_KEY<br/>Container Apps Secret| DI

    ## 3. API och fakturaflöde

Scanly använder ett .NET 8 REST API som körs i Azure Container Apps.

API:t har följande endpoints:

- `GET /health` – kontrollerar att API:t är tillgängligt.
- `POST /invoices` – tar emot en faktura som PDF, analyserar den och sparar resultatet.
- `GET /invoices/{id}` – hämtar resultatet för en specifik faktura.
- `GET /invoices` – listar lagrade fakturor.

### Flöde för en faktura

1. Klienten skickar en PDF-faktura till `POST /invoices`.
2. API:t skickar PDF-filen till Azure Document Intelligence.
3. Document Intelligence använder modellen `prebuilt-invoice` för att identifiera information från fakturan.
4. API:t omvandlar resultatet till Scanlys strukturerade fakturaformat.
5. Resultatet serialiseras till JSON.
6. JSON-filen sparas i Azure Blob Storage i containern `invoices`.
7. API:t returnerar ett svar till klienten med fakturans ID och status.

Ett lyckat anrop returnerar HTTP-status `201 Created` och statusen `klar`.

### Dokumentation och testning

API:t exponerar Swagger UI för att göra det möjligt att testa endpoints och se API-kontraktet.

Swagger används bland annat för att testa fakturaflödet genom att ladda upp en PDF till `POST /invoices`.

## 4. Azure-resurser

### Azure Container Apps

Scanly API körs som en container i Azure Container Apps.

Container Appen ansvarar för att köra API:t och göra det tillgängligt via HTTPS. Applikationen är konfigurerad med extern ingress och körs på port 8080.

Container Appen är konfigurerad med minst 2 repliker för att uppfylla kravet på tillgänglighet och kan skala upp vid högre belastning.

### Azure Container Registry

Azure Container Registry (ACR) används för att lagra Docker-imagen för Scanly API.

GitHub Actions bygger Docker-imagen och pushar den till ACR. Container Appen hämtar sedan imagen från registret vid deployment.

Container Appens Managed Identity har rollen `AcrPull` för att kunna hämta containerimagen utan att använda hårdkodade credentials.

### Azure Blob Storage

Azure Blob Storage används för att lagra det strukturerade JSON-resultatet från fakturaanalysen.

Containern `invoices` används för fakturorna.

API:t använder Managed Identity för åtkomst till Blob Storage. Container Appens Managed Identity har rollen `Storage Blob Data Contributor`.

Det innebär att API:t kan skriva fakturornas JSON-resultat till Storage utan att en Storage Account Key behöver ligga i applikationen.

### Azure Document Intelligence

Azure Document Intelligence används för att analysera fakturornas innehåll.

API:t använder modellen `prebuilt-invoice` för att identifiera information från PDF-fakturor, exempelvis fakturanummer, datum, leverantör och belopp.

Document Intelligence-resursen är en delad Azure-resurs som ligger i en annan tenant. Därför används API-key-baserad autentisering istället för Managed Identity.

API-nyckeln lagras som en Azure Container Apps Secret och exponeras för applikationen genom miljövariabeln `AZURE_DI_KEY`.

Endpointen konfigureras genom `AZURE_DI_ENDPOINT`.

### Azure Managed Identity

Container Appen använder en System Assigned Managed Identity.

Managed Identity används för åtkomst till våra Azure-resurser där det är möjligt, framför allt:

- Azure Blob Storage
- Azure Container Registry

Det minskar behovet av att lagra credentials direkt i applikationskoden.

## 5. Infrastructure as Code

Azure-infrastrukturen beskrivs med Bicep.

Huvudfilen är:

`infrastructure/main.bicep`

Det finns även separata parameterfiler för olika miljöer:

- `infrastructure/dev.bicepparam`
- `infrastructure/prod.bicepparam`

Bicep används för att beskriva och parametrera Azure-resurser istället för att all infrastruktur behöver skapas manuellt.

### Resurser som definieras

Bicep-konfigurationen beskriver bland annat:

- Azure Storage Account
- Blob Storage-container
- Azure Container Registry
- Azure Container Apps Environment
- Azure Container App
- Managed Identity
- RBAC-rolltilldelningar

### Parametrisering

Resursnamn och andra miljöberoende värden ligger i parameterfilerna. Det gör det möjligt att använda samma grundläggande Bicep-template för olika miljöer.

Exempel på parametrar är:

- Storage Account-namn
- ACR-namn
- Document Intelligence-endpoint

### Validering

Bicep-filerna har byggts och kontrollerats med Azure CLI.

`az deployment group what-if` användes för att se vilka förändringar en deployment skulle göra innan resurser ändrades.

Det gör det möjligt att upptäcka potentiella förändringar i infrastrukturen innan en faktisk deployment genomförs.
## 6. Säkerhet och secrets

Scanly använder Azure Managed Identity, RBAC och Azure Container Apps Secrets för att undvika att känsliga credentials behöver lagras i källkoden.

### Managed Identity och RBAC

Container Appen använder en System Assigned Managed Identity.

Identiteten används för åtkomst till Azure Container Registry och Azure Blob Storage.

Följande roller används:

- `AcrPull` – för att hämta containerimagen från ACR.
- `Storage Blob Data Contributor` – för att skriva fakturornas JSON-resultat till Blob Storage.

### Document Intelligence API-key

Document Intelligence använder API-key eftersom den delade Document Intelligence-resursen ligger i en annan tenant.

API-nyckeln lagras som en **Container Apps Secret** och refereras av applikationen genom miljövariabeln:

`AZURE_DI_KEY`

Document Intelligence-endpointen konfigureras genom:

`AZURE_DI_ENDPOINT`

API-nyckeln ligger därför inte direkt i källkoden eller i GitHub-repositoryt.

### Miljövariabler

Konfigurationsvärden som varierar mellan miljöer hanteras genom miljövariabler och Bicep-parameterfiler istället för att hårdkodas i applikationen.

## 7. CI/CD och deployment

Projektet använder GitHub Actions för att automatisera build, test och deployment.

När ändringar pushas till repositoryts `main`-branch körs workflowet och hanterar deploymentkedjan.

### Deploymentflöde

1. Kod pushas till GitHub.
2. GitHub Actions bygger och testar applikationen.
3. Docker-imagen byggs.
4. Imagen pushas till Azure Container Registry.
5. Azure Container Apps uppdateras med den nya imagen.
6. API:t startar med den nya versionen.
7. En health check används för att kontrollera att applikationen är tillgänglig.

På detta sätt behöver deployment inte göras manuellt varje gång en ny version av applikationen ska publiceras.

### Containerisering

API:t körs som en Docker-container.

Docker-imagen innehåller applikationen och dess runtime så att samma applikation kan köras lokalt och i Azure Container Apps.

## 8. Designval och begränsningar

### Designval

Lösningen är uppdelad mellan flera Azure-tjänster där varje tjänst har ett tydligt ansvar.

- Container Apps kör själva API:t.
- Document Intelligence ansvarar för fakturaanalysen.
- Blob Storage används för lagring av resultat.
- ACR används för containerimages.
- Bicep används för Infrastructure as Code.
- GitHub Actions används för CI/CD.

Denna uppdelning gör att de olika delarna kan utvecklas och hanteras separat.

### Begränsningar

Document Intelligence är en delad kursresurs som ligger i en annan tenant. Därför kan Managed Identity inte användas för autentisering mot den resursen. API-key används istället och lagras säkert som en Container Apps Secret.

Lösningen är främst byggd för kursprojektets behov och använder därför en relativt enkel arkitektur. Vid en större produktionsmiljö skulle ytterligare funktioner kunna behövas, exempelvis mer omfattande övervakning, loggning och backupstrategier.