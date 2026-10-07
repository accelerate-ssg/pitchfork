import std/[json, tables, os, strutils, sequtils]
import ../src/pitchfork/liquid_lib

let testDir = currentSourcePath().parentDir() / "menu"

# Load template
let tmplSource = readFile(testDir / "pricing.liquid")

# Load partials from files
let partialsDir = testDir / "partials"
var partials = initTable[string, string]()
for kind, path in walkDir(partialsDir):
  if kind == pcFile and path.endsWith(".liquid"):
    let name = path.extractFilename().changeFileExt("")
    partials[name] = readFile(path)

# Build context matching context.yaml
let context = %*{
  "site": {
    "title": "Accodeing to you",
    "email": "info@accodeing.com",
    "description": "Accodeing to you is a small consultancy specializing in agile methods, software craftsmanship, TDD, coaching and long term business relationships.",
    "url": "https://accodeing.com",
    "variables": {
      "hourly_rate": 995,
      "web_app_hosting_per_month": 5000,
      "heimr_hosting_per_year": 1860,
      "heimr_domain_per_year": 350,
      "heimr_email_inbox_per_year": 650
    },
    "security_researchers": [
      {
        "name": "Parth Narula",
        "description": "Penetration tester and founder of ScriptJacker",
        "contributions": [
          {
            "date": "2024-03-19",
            "description": "Responsible disclosure of several configuration issues in and a possible exploit in one of our internet facing services."
          }
        ]
      }
    ],
    "navigation": [
      {
        "title": "Hemsida och drift",
        "permalink": "/hosting",
        "children": [
          {"title": "SEO", "permalink": "/hosting/seo"},
          {"title": "Priser", "permalink": "/hosting/pricing"},
          {"title": "Villkor", "permalink": "/hosting/terms"},
          {"title": "BolagsKraft", "permalink": "/hosting/bolagskraft"},
          {"title": "Ändringsbegäran", "permalink": "/hosting/change_request"},
          {"title": "Analys", "permalink": "/hosting/details/analysis"},
          {"title": "Kontaktvägar", "permalink": "/hosting/details/connect"},
          {"title": "Inflyttning", "permalink": "/hosting/details/move_in"},
          {"title": "Slappna av", "permalink": "/hosting/details/relax"},
          {"title": "Säkerhet", "permalink": "/hosting/details/security"},
          {"title": "Hastighet", "permalink": "/hosting/details/speed"}
        ]
      },
      {
        "title": "Utbildning",
        "permalink": "/training",
        "children": [
          {"title": "Moderna webbapplikationer", "permalink": "/training/modern_web_applications"},
          {"title": "Testning av webbapplikationer", "permalink": "/training/testing_web_applications"}
        ]
      },
      {
        "title": "Webbapplikationer",
        "permalink": "/web_applications",
        "children": [
          {"title": "Ruby on Rails", "permalink": "/web_applications/ruby_and_rails"},
          {"title": "Priser", "permalink": "/web_applications/pricing"}
        ]
      },
      {
        "title": "Molntjänster",
        "permalink": "/services"
      },
      {
        "title": "Blog",
        "permalink": "/blog"
      },
      {
        "title": "Blogg",
        "permalink": "/blogg"
      },
      {
        "title": "Säkerhet",
        "permalink": "/security",
        "children": [
          {"title": "Policy", "permalink": "/security/policy"}
        ]
      }
    ]
  },
  "item": {
    "title": "Priser",
    "permalink": "/hosting/pricing",
    "order": 1,
    "description": "",
    "keywords": "",
    "content_html": "<h1 id=\"priser\">Priser</h1>\n\n<p>Vi erbjuder en aktiv förvaltning av hemsidor, inte ett vanligt webbhotell. I vårt koncept ingår att vi uppdaterar sidan regelbundet, med innehåll från dig, och att vi ser till så att ditt företag finns korrekt inlagt i, till exempel, Google my business och Google maps.</p>\n\n<p>Vi tycker att så mycket som möjligt skall ingå i priset så att kostnaden blir så översiktlig som möjligt för dig. Vi är inte 100% där ännu (vi jobbar på det), så vi gjorde en priskalkylator så länge. Med den kan du enkelt titta på några exempel, eller se vad just din sida skulle kosta.</p>\n",
    "content_html_after": "<hr class=\"break\" />\n\n<h1 id=\"frågor\">Frågor</h1>\n\n<h2 id=\"vad-ingår-i-driften\">Vad ingår i driften?</h2>\n<p>Som standard ingår detta i grundkostnaden på 1380:- per år:</p>\n<ul>\n  <li>En domän, .com, .se, .net, .org eller annan domän i samma prisklass</li>\n  <li>Två e-postadresser med 3 GB lagringsutrymme var</li>\n  <li>Obegränsat antal epostalias på dina domäner (vidarebefodran av epost från en adress på din domän till en annan epostadress)</li>\n  <li>Krypterad trafik till och från hemsidan (<a href=\"https://it-ord.idg.se/ord/https/\">HTTPS</a>)</li>\n  <li>Drift av din hemsida på Googles ledande molnplattform från deras datacenter i Hamina, Finland</li>\n  <li>Automatisk övervakning av hemsidan för att garantera att den alltid är uppe</li>\n  <li>Automatiska uppgraderingar av tekniken på din sida för att garantera säkerhet, stabilitet och att den anpassar sig till nya krav och teknologier</li>\n</ul>\n\n<h2 id=\"varför-fakturarar-ni-årsvis\">Varför fakturarar ni årsvis?</h2>\n<p>Vi fakturerar för hela året i mars. Eftersom vi måste betala flera av tjänsterna (som epostkonton och domäner) årsvis, så behöver vi en viss framförhållning, därför faktureras även du årsvis. Det ger också mycket bättre möjlighet för oss att planera, så att vi kan garantera en bra tjänst till dig.</p>\n\n<h2 id=\"hur-vet-jag-om-ni-gör-någon-nytta\">Hur vet jag om ni gör någon nytta?</h2>\n<p>Förutom att vår plattform i sig är byggd för att vara så snabb det bara går, så har vi också statistik över hur din sida har utvecklats under året. Innan vi fakturerar i mars så hör vi av oss till dig för att titta på statistiken från året som har gått.</p>\n\n<p>Vi tittar på hur trafiken har utvecklats, var du ligger i sökmotorernas ranking, och pratar lite om vilken nytta du har av sidan och hur vi kan maximera den för dig.</p>\n\n<h2 id=\"hur-avslutar-man-tjänsten\">Hur avslutar man tjänsten?</h2>\n<p>Om du tycker att vi inte lever upp till förväntningarna, eller om vi tycker att sidan inte är av tillräcklig stor nytta för dig, så är återkopplingen vi gör under våren ett bra tillfälle att komma överens om att avsluta tjänsten. Vi vill att vår tjänst är en investering, inte en kostnad, och kommer att vägleda dig mot andra alternativ om vi inte känner att den är rätt för dig.</p>\n\n<h2 id=\"om-jag-vill-ha-en-dyrare-domän-till-min-sida\">Om jag vill ha en dyrare domän till min sida?</h2>\n<p>Vår registrar, Gandi, har stöd för alla domäner, och vi kan köpa/flytta vilken domän du än vill ha till våra system. Det är bara priser per år som blir högre om du har/vill ha en dyrare domän. Eftersom vi har ett samarbete med Gandi, så får vi dessutom lägre priser på deras utbud, så hör gärna av dig för att få en aktuell prisuppgift för den domän du helst skulle vilja ha.</p>\n\n<h2 id=\"om-ni-registrerar-domänen-tillhör-den-inte-er-då\">Om ni registrerar domänen, tillhör den inte er då?</h2>\n<p>Nej! Vi registrerar alla domäner så att företaget/personen som har sidan också är den som står som primär kontakt. Vi står som teknisk kontakt och har möjlighet att administrera domänen, men vi äger inte rätten till domänen, det gör du.</p>\n\n<h1 id=\"jag-har-en-annan-fråga\">Jag har en annan fråga!</h1>\n<p>Vad bra :) Vi tycker om frågor, de är första steget till förståelse och kunskap. Du kan nå oss på flera sätt, välj det som passar dig bäst:</p>\n\n<script src=\"/assets/javascripts/obfuscated-contact-link.js\"></script>\n\n<p>Telefon på <a href=\"tel:+45107500560\">010-750 05 60</a> mellan 8.30 - 12:00.</p>\n"
  }
}

echo "Loaded partials: ", toSeq(partials.keys).join(", ")
echo ""

# Render
let output = render(tmplSource, context, partials)

# Write output to file for inspection
let outputPath = testDir / "rendered_output.html"
writeFile(outputPath, output)
echo "Rendered output written to: ", outputPath
echo ""
echo output
