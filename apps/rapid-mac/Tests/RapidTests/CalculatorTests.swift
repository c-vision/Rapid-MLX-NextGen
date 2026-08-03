import Foundation
import Testing
@testable import Rapid

@Suite("CalculatorTool")
struct CalculatorTests {
    @Test("Basic arithmetic")
    func basicArithmetic() {
        #expect(CalculatorTool.evaluate("2 + 3") == "5")
        #expect(CalculatorTool.evaluate("10 - 4") == "6")
        #expect(CalculatorTool.evaluate("6 * 7") == "42")
        #expect(CalculatorTool.evaluate("100 / 4") == "25")
    }

    @Test("Operator precedence + parens")
    func precedence() {
        #expect(CalculatorTool.evaluate("2 + 3 * 4") == "14")
        #expect(CalculatorTool.evaluate("(2 + 3) * 4") == "20")
        #expect(CalculatorTool.evaluate("(1 + 2) * (3 + 4)") == "21")
    }

    @Test("Caret operator rewritten to pow()")
    func caretBecomesPow() {
        #expect(CalculatorTool.evaluate("2 ^ 10") == "1024")
        #expect(CalculatorTool.evaluate("3 ^ 4") == "81")
    }

    @Test("Named functions sqrt / abs / log / ln")
    func namedFunctions() {
        #expect(CalculatorTool.evaluate("sqrt(144)") == "12")
        #expect(CalculatorTool.evaluate("abs(-7)") == "7")
        #expect(CalculatorTool.evaluate("log(100)") == "2")
        #expect(CalculatorTool.evaluate("ln(1)") == "0")
        #expect(CalculatorTool.evaluate("pow(2, 8)") == "256")
        #expect(CalculatorTool.evaluate("max(3, 1, 4, 1, 5, 9, 2, 6)") == "9")
        #expect(CalculatorTool.evaluate("min(3, 1, 4)") == "1")
    }

    @Test("Constants pi and e")
    func constants() {
        let pi = CalculatorTool.evaluate("pi")
        #expect(pi?.hasPrefix("3.1415") == true)
        let e = CalculatorTool.evaluate("e")
        #expect(e?.hasPrefix("2.7182") == true)
    }

    @Test("Unknown identifiers fail safely (no crash, returns nil)")
    func rejectsUnknownIdentifiers() {
        // Single source of safety: no selector dispatch surface at
        // all because we don't use NSExpression. Garbage just
        // doesn't parse.
        #expect(CalculatorTool.evaluate("FUNCTION(self, 'init')") == nil)
        #expect(CalculatorTool.evaluate("SELF.something") == nil)
        #expect(CalculatorTool.evaluate("'malicious string'") == nil)
        #expect(CalculatorTool.evaluate("rm -rf /") == nil)
    }

    @Test("Division by zero returns nil rather than infinity / crash")
    func divisionByZero() {
        #expect(CalculatorTool.evaluate("1 / 0") == nil)
        #expect(CalculatorTool.evaluate("5 % 0") == nil)
    }

    @Test("Integer-valued results don't carry trailing .0")
    func integerFormatting() {
        #expect(CalculatorTool.evaluate("8 * 9") == "72")
        #expect(CalculatorTool.evaluate("100 / 4") == "25")
    }

    @Test("Right-associative power: 2^3^2 = 2^(3^2) = 512")
    func powerRightAssoc() {
        #expect(CalculatorTool.evaluate("2 ^ 3 ^ 2") == "512")
    }

    @Test("Empty / garbage input returns nil")
    func emptyOrGarbage() {
        #expect(CalculatorTool.evaluate("") == nil)
        #expect(CalculatorTool.evaluate(")((") == nil)
        #expect(CalculatorTool.evaluate("1 + +") == nil)
    }

    // MARK: - Model-typography normalization (2026-07 dogfood)
    //
    // qwen3.5-4b called the tool with `"10 − 7 ="` and the turn died:
    // − is U+2212 MINUS SIGN (not ASCII "-") and the trailing "=" is
    // the writing-into-a-calculator habit small models learn from
    // training data. Both are faithful intent, not garbage.

    @Test("The exact dogfood input evaluates: unicode minus + trailing =")
    func dogfoodShape() {
        #expect(CalculatorTool.evaluate("10 \u{2212} 7 =") == "3")
    }

    @Test("Unicode operator lookalikes all normalize")
    func unicodeOperators() {
        #expect(CalculatorTool.evaluate("10 \u{2013} 7") == "3")   // en dash
        #expect(CalculatorTool.evaluate("10 \u{2014} 7") == "3")   // em dash
        #expect(CalculatorTool.evaluate("6 \u{00D7} 7") == "42")   // ×
        #expect(CalculatorTool.evaluate("6 \u{22C5} 7") == "42")   // dot operator
        #expect(CalculatorTool.evaluate("6 \u{00B7} 7") == "42")   // middle dot
        #expect(CalculatorTool.evaluate("100 \u{00F7} 4") == "25") // ÷
        // Full-width OPERATORS from CJK-trained models normalize…
        #expect(CalculatorTool.evaluate("2 ＋ 3") == "5")
        #expect(CalculatorTool.evaluate("（2 ＋ 3） ＊ 4 ＝") == "20")
        // …full-width DIGITS deliberately do not (Double() can't parse
        // them; normalizing digits is a bigger contract than operator
        // typography and hasn't been seen in dogfood).
        #expect(CalculatorTool.evaluate("２ ＋ ３") == nil)
    }

    @Test("Everything after the first = is the model's guess — evaluate the LHS")
    func equalsCutsToLHS() {
        #expect(CalculatorTool.evaluate("2 + 3 =") == "5")
        #expect(CalculatorTool.evaluate("2 + 3 =  ") == "5")
        #expect(CalculatorTool.evaluate("2 + 3 ==") == "5")
        // Round 2 of the dogfood arms race: the model now supplies its
        // guess after the equals. The tool's whole job is to answer
        // with the truth — including when the guess is wrong.
        #expect(CalculatorTool.evaluate("10 \u{2212} 7 = 3") == "3")
        #expect(CalculatorTool.evaluate("2 + 2 = 5") == "4")
        // Degenerate shapes still fail: nothing before the equals, or
        // an LHS that isn't arithmetic (equation-solving requests).
        #expect(CalculatorTool.evaluate("=") == nil)
        #expect(CalculatorTool.evaluate("= 3") == nil)
        #expect(CalculatorTool.evaluate("2x + 3 = 7") == nil)
    }

    @Test("normalize is a no-op on already-clean ASCII expressions")
    func normalizeNoOp() {
        #expect(CalculatorTool.normalize("2 * (3 + 5)") == "2 * (3 + 5)")
        #expect(CalculatorTool.normalize("sqrt(144) + 7") == "sqrt(144) + 7")
    }
}

@Suite("WeatherTool parsers")
struct WeatherToolParserTests {
    @Test("Weather uses only the Open-Meteo search and forecast endpoints")
    func endpointURLs() throws {
        let geocodingURL = try #require(WeatherTool.geocodingURL(location: "Tokyo"))
        let geocoding = try #require(URLComponents(url: geocodingURL, resolvingAgainstBaseURL: false))
        #expect(geocoding.host == "geocoding-api.open-meteo.com")
        #expect(geocoding.path == "/v1/search")
        #expect(geocoding.queryItems?.first(where: { $0.name == "name" })?.value == "Tokyo")
        let count = Int(geocoding.queryItems?.first(where: { $0.name == "count" })?.value ?? "")
        #expect((count ?? 0) > 1)
        #expect(geocoding.queryItems?.contains(where: { $0.name == "language" }) == false)

        let chineseURL = try #require(WeatherTool.geocodingURL(location: "西安"))
        let chinese = try #require(URLComponents(url: chineseURL, resolvingAgainstBaseURL: false))
        #expect(chinese.queryItems?.first(where: { $0.name == "language" })?.value == "zh")

        let forecastURL = try #require(WeatherTool.forecastURL(lat: 35.6895, lon: 139.69171, imperial: false))
        let forecast = try #require(URLComponents(url: forecastURL, resolvingAgainstBaseURL: false))
        #expect(forecast.host == "api.open-meteo.com")
        #expect(forecast.path == "/v1/forecast")
        #expect(forecast.queryItems?.first(where: { $0.name == "current" })?.value == "temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code")
    }

    @Test("Open-Meteo geocoding resolves Tokyo, Japan")
    func geocodingTokyo() throws {
        let json = """
        {
          "results": [{
            "name": "Tokyo",
            "latitude": 35.6895,
            "longitude": 139.69171,
            "country": "Japan",
            "admin1": "Tokyo",
            "timezone": "Asia/Tokyo"
          }]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let hit = try #require(WeatherTool.parseGeocodingResponse(data, location: "Tokyo"))
        #expect(hit.fullName == "Tokyo, Japan")
        #expect(hit.latitude == 35.6895)
        #expect(hit.longitude == 139.69171)
        #expect(hit.timezone == "Asia/Tokyo")
    }

    @Test("A bare romanization matching only a tiny homonym returns nil")
    func geocodingRejectsAmbiguousXian() throws {
        // Open-Meteo returns only the tiny Galician "Xián" for the bare
        // romanization "Xian"; the real Xi'an is reached via the native "西安"
        // + language path (see geocodingMatchesCountryCodeAcrossLanguages).
        // Near-names such as "Xianyang" fold to a different key and are not
        // treated as "Xian". With no major same-named city present, an
        // unqualified "Xian" stays not-found rather than resolving to the tiny
        // homonym. (#584 preserves this while letting "Medellin" → Medellín.)
        let json = """
        {
          "results": [
            {
              "name": "Xián",
              "latitude": 42.74443,
              "longitude": -7.69034,
              "country": "Spain",
              "admin1": "Galicia",
              "country_code": "ES"
            },
            {
              "name": "Xianyang",
              "latitude": 34.32944,
              "longitude": 108.70929,
              "country": "China",
              "admin1": "Shaanxi",
              "country_code": "CN",
              "population": 1034081
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(WeatherTool.parseGeocodingResponse(data, location: "Xian") == nil)
    }

    @Test("A localized country response matches an English country qualifier")
    func geocodingMatchesCountryCodeAcrossLanguages() throws {
        let json = """
        {
          "results": [
            {
              "name": "西安",
              "latitude": 34.25833,
              "longitude": 108.92861,
              "country": "中国",
              "admin1": "陕西",
              "country_code": "CN",
              "population": 9600000
            },
            {
              "name": "西安",
              "latitude": 28.46667,
              "longitude": 111.05,
              "country": "中国",
              "admin1": "湖南",
              "country_code": "CN"
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let hit = try #require(WeatherTool.parseGeocodingResponse(
            data,
            location: "西安",
            qualifiers: ["China"]
        ))
        #expect(hit.admin1 == "陕西")
    }

    @Test("An unqualified Springfield never defaults to the first state")
    func geocodingRejectsAmbiguousSpringfield() throws {
        let json = """
        {
          "results": [
            {
              "name": "Springfield",
              "latitude": 37.21533,
              "longitude": -93.29824,
              "country": "United States",
              "admin1": "Missouri",
              "country_code": "US",
              "population": 170188
            },
            {
              "name": "Springfield",
              "latitude": 39.80172,
              "longitude": -89.64371,
              "country": "United States",
              "admin1": "Illinois",
              "country_code": "US",
              "population": 114394
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(WeatherTool.parseGeocodingResponse(data, location: "Springfield") == nil)
        let illinois = try #require(WeatherTool.parseGeocodingResponse(
            data,
            location: "Springfield",
            qualifiers: ["Illinois", "US"]
        ))
        #expect(illinois.admin1 == "Illinois")
    }

    @Test("An ASCII spelling of an accented city resolves to the dominant city")
    func geocodingResolvesAsciiAccentedCity() throws {
        // #584: the user (or the model, guided to canonical English) types
        // "Medellin"; Open-Meteo's canonical name is the accented "Medellín".
        // The dominant real city must win over a tiny exact-ASCII homonym
        // (Medellin, Philippines) instead of being dropped by an accent filter.
        let json = """
        {
          "results": [
            {
              "name": "Medellín",
              "latitude": 6.25184,
              "longitude": -75.56359,
              "country": "Colombia",
              "admin1": "Antioquia",
              "country_code": "CO",
              "population": 1999979
            },
            {
              "name": "Medellin",
              "latitude": 11.12907,
              "longitude": 123.96355,
              "country": "Philippines",
              "admin1": "Central Visayas",
              "country_code": "PH",
              "population": 11741
            },
            {
              "name": "Medellín",
              "latitude": 38.96667,
              "longitude": -5.95,
              "country": "Spain",
              "admin1": "Extremadura",
              "country_code": "ES",
              "population": 2357
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let hit = try #require(WeatherTool.parseGeocodingResponse(data, location: "Medellin"))
        #expect(hit.name == "Medellín")
        #expect(hit.country == "Colombia")
    }

    @Test("An ASCII spelling of a multi-word accented city resolves")
    func geocodingResolvesSaoPaulo() throws {
        // "Sao Paulo" → the accented "São Paulo", Brazil (pop ~12.4M) dominates
        // the same-named towns that carry no population.
        let json = """
        {
          "results": [
            {
              "name": "São Paulo",
              "latitude": -23.5475,
              "longitude": -46.63611,
              "country": "Brazil",
              "admin1": "São Paulo",
              "country_code": "BR",
              "population": 12400232
            },
            {
              "name": "São Paulo",
              "latitude": 40.15,
              "longitude": -8.51667,
              "country": "Portugal",
              "admin1": "Coimbra"
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let hit = try #require(WeatherTool.parseGeocodingResponse(data, location: "Sao Paulo"))
        #expect(hit.country == "Brazil")
    }

    @Test("A small, unambiguous, exactly-spelled city still resolves")
    func geocodingResolvesSmallExactCity() throws {
        // The population floor that rejects a bare accented homonym must not
        // reject a small city the user spelled exactly (no accent fold needed).
        let json = """
        {
          "results": [{
            "name": "Cupertino",
            "latitude": 37.323,
            "longitude": -122.03218,
            "country": "United States",
            "admin1": "California",
            "country_code": "US",
            "population": 60000
          }]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let hit = try #require(WeatherTool.parseGeocodingResponse(data, location: "Cupertino"))
        #expect(hit.admin1 == "California")
    }

    @Test("A geocoding response with no results returns nil")
    func geocodingNoResults() throws {
        let data = try #require("{ \"generationtime_ms\": 0.1 }".data(using: .utf8))
        #expect(WeatherTool.parseGeocodingResponse(data, location: "Nowhere") == nil)
    }

    @Test("Open-Meteo forecast parses the four requested current fields")
    func forecastHappyPath() throws {
        let json = """
        {
          "current": {
            "temperature_2m": 22.4,
            "relative_humidity_2m": 68,
            "wind_speed_10m": 12.5,
            "weather_code": 2
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let reading = try #require(WeatherTool.parseForecastResponse(data))
        #expect(reading.temperature == 22.4)
        #expect(reading.weatherCode == 2)
        #expect(reading.windSpeed == 12.5)
        #expect(reading.humidity == 68)
    }

    @Test("WMO weather code labels cover the documented ranges")
    func weatherLabels() {
        #expect(WeatherTool.weatherCodeLabel(0) == "Clear sky")
        #expect(WeatherTool.weatherCodeLabel(2) == "Partly cloudy")
        #expect(WeatherTool.weatherCodeLabel(61) == "Light rain")
        #expect(WeatherTool.weatherCodeLabel(95) == "Thunderstorm")
        #expect(WeatherTool.weatherCodeLabel(999).hasPrefix("Code "))
    }
}
