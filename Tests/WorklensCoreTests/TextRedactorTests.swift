import Foundation
import Testing
@testable import WorklensCore

/// #49. Two halves that matter equally: what must be replaced, and what must survive untouched.
/// The second half is the one that keeps reports readable — a redactor that eats CPFs, phone
/// numbers and boleto lines is worse than none, because it is silent about it.
@Suite("TextRedactor")
struct TextRedactorTests {
    private let redactor = TextRedactor()

    // MARK: - Replaced

    @Test("a Luhn-valid card is replaced and a Luhn-invalid one is not")
    func luhnGate() {
        let valid = redactor.redact("charge 4111111111111111 today")
        #expect(valid.text == "charge [CARD_1] today")
        #expect(valid.counts == [.card: 1])

        let invalid = redactor.redact("charge 4111111111111112 today")
        #expect(invalid.text == "charge 4111111111111112 today")
        #expect(invalid.isClean)
    }

    @Test("a card written in groups of four is replaced, spaces or dashes")
    func groupedCard() {
        #expect(redactor.redact("4111 1111 1111 1111").text == "[CARD_1]")
        #expect(redactor.redact("4111-1111-1111-1111").text == "[CARD_1]")
        // Amex is 4-6-5.
        #expect(redactor.redact("3782 822463 10005").text == "[CARD_1]")
    }

    @Test("two different cards get two numbers; the same card twice keeps one")
    func cardNumbering() {
        let two = redactor.redact("4111111111111111 then 5555555555554444")
        #expect(two.text == "[CARD_1] then [CARD_2]")
        #expect(two.counts == [.card: 2])

        // Same value, two spellings: one placeholder, two occurrences counted.
        let repeated = redactor.redact("4111111111111111 and 4111 1111 1111 1111")
        #expect(repeated.text == "[CARD_1] and [CARD_1]")
        #expect(repeated.counts == [.card: 2])
    }

    @Test("an IBAN passing mod-97 is replaced, one failing it is not")
    func iban() {
        #expect(redactor.redact("IBAN DE89 3704 0044 0532 0130 00 please").text == "IBAN [IBAN_1] please")
        #expect(redactor.redact("IBAN DE89370400440532013000").text == "IBAN [IBAN_1]")
        #expect(redactor.redact("IBAN DE89370400440532013001").isClean)
    }

    @Test("a six-digit code next to \"código\" becomes [OTP]")
    func otp() {
        let result = redactor.redact("Seu código de verificação é 483920 — WhatsApp")
        #expect(result.text == "Seu código de verificação é [OTP] — WhatsApp")
        #expect(result.counts == [.otp: 1])
        #expect(redactor.redact("Verification code: 12345678").text == "Verification code: [OTP]")
        #expect(redactor.redact("483920 is your login code").text == "[OTP] is your login code")
        // Far from any such word, six digits are just six digits.
        #expect(redactor.redact("invoice 483920 for the quarter").isClean)
    }

    @Test("an sk- key inside a URL query goes with the query and still counts (#332)")
    func secretInURLQuery() {
        let result = redactor.redact("https://console.example.com/keys?api_key=sk-live-9f8a7b6c5d4e3f2a1b&tab=1")
        #expect(result.text == "https://console.example.com/keys")
        #expect(result.counts == [.secret: 1])
    }

    @Test("a query with nothing secret in it is dropped, host and path kept")
    func urlQueryDropped() {
        let result = redactor.redact("Inbox — https://mail.google.com/mail/u/0?ik=9f2c&view=pt")
        #expect(result.text == "Inbox — https://mail.google.com/mail/u/0")
        // Dropping a query is not a redaction of a *kind*: nothing was replaced by a placeholder.
        #expect(result.isClean)
    }

    @Test("a JWT is replaced")
    func jwt() {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(redactor.redact("Authorization \(token)").text == "Authorization [SECRET_1]")
        #expect(redactor.redact("Bearer \(token)").text == "Bearer [SECRET_1]")
    }

    @Test("a PEM private key block is replaced whole")
    func privateKey() {
        let pem = """
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEAx7Vv0mB0Q6h1kQ8+5nJq2s3Rr5aTn0mQmMhFqQ3Yc8t3F9wB
            9m0eJ6Yh6mZ0oX1lQdKk3n8Y2Z0v0kWq3nJ1pS5eF7wQ==
            -----END RSA PRIVATE KEY-----
            """
        let result = redactor.redact("id_rsa\n\(pem)\ndone")
        #expect(result.text == "id_rsa\n[SECRET_1]\ndone")
        #expect(result.counts == [.secret: 1])
    }

    @Test("other secret shapes are replaced")
    func secretShapes() {
        #expect(redactor.redact("AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY").text == "[SECRET_1]")
        #expect(redactor.redact("xoxb-2394827349-2039482734-Kj8sHd7fGh2Ls9dK").text == "[SECRET_1]")
        #expect(redactor.redact("ghp_16C7e42F292c6912E7710c838347Ae178B4a").text == "[SECRET_1]")
        #expect(redactor.redact("github_pat_11ABCDEFG0abcdefghijkl_ABCDEFGHIJ").text == "[SECRET_1]")
        #expect(redactor.redact("AKIAIOSFODNN7EXAMPLE").text == "[SECRET_1]")
    }

    @Test("a password pair keeps its key and loses its value")
    func passwordPair() {
        let title = redactor.redact("db.sh — senha=hunter2 — Terminal")
        #expect(title.text == "db.sh — senha=[PASSWORD] — Terminal")
        #expect(title.counts == [.password: 1])
        // The userinfo goes whole; a scheme other than http(s) keeps its query, so the key in
        // it is what redacts the value.
        #expect(redactor.redact("postgres://app:x@h/db?password=s3cr3t!").text
            == "postgres://h/db?password=[PASSWORD]")
        // A password rule beats the card rule on the same span: the key says what it is.
        #expect(redactor.redact("pwd=4111111111111111").text == "pwd=[PASSWORD]")
    }

    @Test("JSON and YAML credentials lose their value (security review #3)")
    func jsonAndYAMLPasswords() {
        let json = redactor.redact(#"{"user":"ana","password":"hunter2"}"#)
        #expect(json.text == #"{"user":"ana","password":[PASSWORD]}"#)
        #expect(json.counts == [.password: 1])
        #expect(redactor.redact(#"{"password": "hunter2", "port": 5432}"#).text
            == #"{"password": [PASSWORD], "port": 5432}"#)
        #expect(redactor.redact("{'passwd': 'hunter2'}").text == "{'passwd': [PASSWORD]}")
        #expect(redactor.redact("password: hunter2").text == "password: [PASSWORD]")
        #expect(redactor.redact("  db_password:\thunter2\n  host: db").text
            == "  db_password:\t[PASSWORD]\n  host: db")
        #expect(redactor.redact("DB_PASSWORD=hunter2").text == "DB_PASSWORD=[PASSWORD]")
        #expect(redactor.redact("mysql --password=hunter2 app").text == "mysql --password=[PASSWORD] app")
        #expect(redactor.redact(#"{"pin":1,"password":12345}"#).text == #"{"pin":1,"password":[PASSWORD]}"#)
        // A label at the end of a line takes nothing from the next one.
        #expect(redactor.redact("Password:\nForgot it?").text == "Password:\nForgot it?")
    }

    @Test("credential assignment names lose their value (security review #3)")
    func credentialAssignments() {
        let aws = "aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        #expect(redactor.redact(aws).text == "aws_secret_access_key=[SECRET_1]")
        #expect(redactor.redact(aws).counts == [.secret: 1])
        #expect(redactor.redact("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY").text
            == "aws_secret_access_key = [SECRET_1]")
        let cases: [(String, String)] = [
            ("client_secret: 8f2b1c9d4e7a6f30", "client_secret: [SECRET_1]"),
            (#""api_key": "q8Zt4mW2pX9vL1nB""#, #""api_key": [SECRET_1]"#),
            ("GITHUB_TOKEN=abcdef0123456789abcdef", "GITHUB_TOKEN=[SECRET_1]"),
            ("STRIPE_SECRET_KEY=rk_live_51H8abcdEFGH", "STRIPE_SECRET_KEY=[SECRET_1]"),
            ("x-api-key: 0123456789abcdef", "x-api-key: [SECRET_1]"),
            ("access_token=ya29.a0AfH6SMBxyz12", "access_token=[SECRET_1]"),
            ("secret = 'correct horse battery'", "secret = [SECRET_1]"),
            (#"{"private_key_id": "x", "private_key": "MIIEvQIBADANBgkq"}"#,
             #"{"private_key_id": "x", "private_key": [SECRET_1]}"#),
        ]
        for (input, expected) in cases {
            #expect(redactor.redact(input).text == expected, "\(input)")
        }
        // The same key twice keeps one number, and redacting again changes nothing.
        let twice = redactor.redact("token=abcdefgh12345 then token=abcdefgh12345")
        #expect(twice.text == "token=[SECRET_1] then token=[SECRET_1]")
        #expect(redactor.redact(twice.text).text == twice.text)
        #expect(redactor.redact("sk-live-9f8a7b6c5d4e3f2a1b api_key=[SECRET_1]").text
            == "[SECRET_1] api_key=[SECRET_1]")
    }

    @Test("prose with a credential word in it stays readable")
    func credentialWordsInProse() {
        let kept = [
            "Token: expired",
            "secret: no",
            "max_tokens=4096",
            "The secret to good tests is small fixtures.",
            "Forgot password?",
            "Reset your password at the link below",
            "token 1234 of 5000",
            "keyboard: Magic Keyboard",
            "password_hint=dog",
        ]
        for text in kept {
            #expect(redactor.redact(text).text == text, "\(text)")
        }
        // A colon after "password" takes only the next word, never the line; and a plain word
        // with more words after it is a sentence, not a password.
        #expect(redactor.redact("password: hunter2 link sent").text == "password: [PASSWORD] link sent")
        #expect(redactor.redact("password: reset link sent").text == "password: reset link sent")
    }

    @Test("title-like prose after a credential word and a colon stays (security review)")
    func credentialColonProse() {
        let kept = [
            "Password: troubleshooting guide",
            "token: authentication",
            "Reset your password: step 2",
            "Secret Santa: gift ideas",
            "Token: expired.",
            "secret: keep it safe",
            "Help — Password: Forgot it — Settings",
            #"{"enabled": true, "secret": null}"#,
            "hasPassword: false",
        ]
        for text in kept {
            let result = redactor.redact(text)
            #expect(result.text == text, "\(text)")
            #expect(result.isClean, "\(text)")
        }
    }

    @Test("YAML block scalars lose every line of their value (security review)")
    func yamlBlockScalars() {
        let cases: [(String, String)] = [
            ("password: |\n  hunter2\nhost: db", "password: [PASSWORD]\nhost: db"),
            ("password: >\n  hunter2", "password: [PASSWORD]"),
            ("password: |-\n  hunter2\n  second line", "password: [PASSWORD]"),
            ("db:\n  password: >-\n    hunter2\n    more\n\n  host: db", "db:\n  password: [PASSWORD]\n\n  host: db"),
            ("- password: |+ # rotated\n    hunter2\n- user: ana", "- password: [PASSWORD]\n- user: ana"),
            ("client_secret: |\n  abc\n  def\nnext: 1", "client_secret: [SECRET_1]\nnext: 1"),
            ("private_key: |\n  MIIEvQIBADANBgkq\n  hkiG9w0BAQEFAASC\nport: 1", "private_key: [SECRET_1]\nport: 1"),
        ]
        for (input, expected) in cases {
            let result = redactor.redact(input)
            #expect(result.text == expected, "\(input)")
            #expect(result.total == 1, "\(input)")
            #expect(!result.text.contains("hunter2"), "\(input)")
        }
    }

    @Test("camelCase and compound credential names lose their value (security review)")
    func camelCaseCredentialNames() {
        let cases: [(String, String)] = [
            ("awsSecretAccessKey=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "awsSecretAccessKey=[SECRET_1]"),
            ("clientSecret: s3cr3tvalue", "clientSecret: [SECRET_1]"),
            ("clientSecret = 'abc'", "clientSecret = [SECRET_1]"),
            ("apiKey=abc", "apiKey=[SECRET_1]"),
            ("apikey: zz", "apikey: [SECRET_1]"),
            (#"{"accessToken":"abc"}"#, #"{"accessToken":[SECRET_1]}"#),
            ("accessToken: xyz", "accessToken: [SECRET_1]"),
            ("refreshToken: abc", "refreshToken: [SECRET_1]"),
            ("privateKey: abc123", "privateKey: [SECRET_1]"),
            ("const githubToken = 'ghx'", "const githubToken = [SECRET_1]"),
            ("SLACK_TOKEN: xoxq", "SLACK_TOKEN: [SECRET_1]"),
            ("dbPassword=hunter2", "dbPassword=[PASSWORD]"),
            ("newPassword: letmein", "newPassword: [PASSWORD]"),
        ]
        for (input, expected) in cases {
            #expect(redactor.redact(input).text == expected, "\(input)")
        }
    }

    @Test("a quoted value honours backslash escapes (security review)")
    func escapedQuotes() {
        #expect(redactor.redact(#"{"password":"hunter\"two"}"#).text == #"{"password":[PASSWORD]}"#)
        #expect(redactor.redact(#"{"password":"hunter\"two","user":"ana"}"#).text
            == #"{"password":[PASSWORD],"user":"ana"}"#)
        #expect(redactor.redact(#"secret = 'it\'s mine' # note"#).text == "secret = [SECRET_1] # note")
        #expect(redactor.redact(#"{"api_key":"a\\"}"#).text == #"{"api_key":[SECRET_1]}"#)
        // A quote cut off by the end of a title takes the rest of the line.
        #expect(redactor.redact(#"{"password":"hunter2 and more"#).text == #"{"password":[PASSWORD]"#)
    }

    @Test("credential-specific keys have no minimum length (security review)")
    func shortCredentialValues() {
        let cases: [(String, String)] = [
            ("api_key=abc123", "api_key=[SECRET_1]"),
            ("password=x", "password=[PASSWORD]"),
            ("pwd: a1", "pwd: [PASSWORD]"),
            ("passwd: hunter", "passwd: [PASSWORD]"),
            ("client_secret=ab", "client_secret=[SECRET_1]"),
            ("private_key: k1", "private_key: [SECRET_1]"),
            ("token=abc", "token=[SECRET_1]"),
            (#"{"token": "abc"}"#, #"{"token": [SECRET_1]}"#),
            ("secret: s3cr3t!x", "secret: [SECRET_1]"),
        ]
        for (input, expected) in cases {
            #expect(redactor.redact(input).text == expected, "\(input)")
        }
    }

    @Test("a URL's userinfo is dropped in text, and its password counts (security review #3)")
    func urlUserinfo() {
        let result = redactor.redact("clone https://alice:hunter2@example.com/repo.git now")
        #expect(result.text == "clone https://example.com/repo.git now")
        #expect(result.counts == [.password: 1])
        #expect(redactor.redact("https://alice:hunter2@example.com/").text == "https://example.com/")
        #expect(redactor.redact("DATABASE_URL=postgres://app:s3cr3t@db.internal:5432/app").text
            == "DATABASE_URL=postgres://db.internal:5432/app")
        #expect(redactor.redact("mongodb+srv://u:p@cluster0.example.net").text == "mongodb+srv://cluster0.example.net")
        // A user with no password is still not the address.
        let user = redactor.redact("ssh://git@github.com/owner/repo")
        #expect(user.text == "ssh://github.com/owner/repo")
        #expect(user.isClean)
        #expect(TextRedactor.stripURLQueries("https://a:b@x.example.com/p?q=1") == "https://x.example.com/p")
        // An @ in a path, or an email address, is not userinfo.
        for kept in ["https://example.com/@ana/post", "write to ana@example.com", "https://[::1]:8080/a"] {
            #expect(redactor.redact(kept).text == kept, "\(kept)")
        }
    }

    @Test("placeholders already in a text are counted when redacting it again")
    func placeholderCounts() {
        #expect(TextRedactor.placeholderCounts(in: "[CARD_1] and [CARD_2], senha=[PASSWORD], [OTP]")
            == [.card: 2, .password: 1, .otp: 1])
        #expect(TextRedactor.placeholderCounts(in: "[AXStaticText] [x]").isEmpty)
        let again = redactor.redact("Checkout — [CARD_1] — senha=[PASSWORD]")
        #expect(again.countsWithPlaceholders == [.card: 1, .password: 1])
    }

    @Test("REDACT_EXTRA_PATTERNS adds a kind of its own")
    func customPatterns() {
        let custom = TextRedactor(extraPatterns: [#"ACCT-\d{6}"#])
        let result = custom.redact("ACCT-114322 and ACCT-990011 and ACCT-114322")
        #expect(result.text == "[CUSTOM_1] and [CUSTOM_2] and [CUSTOM_1]")
        #expect(result.counts == [.custom: 3])
        #expect(custom.invalidPatterns.isEmpty)
    }

    @Test("an unparseable extra pattern is dropped, not fatal, and the rest still run")
    func invalidExtraPattern() {
        let custom = TextRedactor(extraPatterns: ["ACCT-[", #"REF-\d{4}"#])
        #expect(custom.invalidPatterns == ["ACCT-["])
        #expect(custom.redact("REF-8842").text == "[CUSTOM_1]")
    }

    @Test("counts serialize to the details_json shape")
    func countsJSON() {
        let result = redactor.redact("4111111111111111 senha=x")
        #expect(result.countsJSON == ["card": 1, "password": 1])
        #expect(result.total == 2)
    }

    // MARK: - Kept

    /// The whole point of the scope decision: this string is one line of somebody's actual work,
    /// and it must come back byte for byte.
    @Test("names, phones, emails, CPF, CNPJ, IPs, NF-e keys and boleto lines are untouched")
    func keptAsIs() {
        let kept = [
            "Ana Paula Ribeiro <ana.ribeiro@exemplo.com.br>",
            "+55 11 98765-4321 / (415) 555-0132",
            "CPF 123.456.789-09",
            "CNPJ 52.601.815/0001-20 e 52601815000120",
            "Rua Haddock Lobo, 595 — Cerqueira César, São Paulo 01414-001",
            "host 10.0.0.5 and 2001:db8::8a2e:370:7334",
            "NF-e 35240611222333000181550010000012341000012345",
            "34191.79001 01043.510047 91020.150008 9 98120000012345",
            "2026-09-08 — R$ 1.499,90 — Worklens 1.2.3",
            "https://docs.google.com/document/d/1a2b3c/edit",
        ].joined(separator: " | ")

        let result = redactor.redact(kept)
        #expect(result.text == kept)
        #expect(result.isClean)
    }

    @Test("an empty or clean string is returned unchanged with no counts")
    func trivial() {
        #expect(redactor.redact("").text == "")
        #expect(redactor.redact("Slack — #eng-worklens").isClean)
    }

    // MARK: - Shape

    @Test("the same value used from many tasks at once matches sequential use")
    func concurrency() async {
        let text = """
            card 4111111111111111 and 5555555555554444, IBAN DE89370400440532013000,
            senha=hunter2, código 483920, key sk-live-9f8a7b6c5d4e3f2a1b
            """
        let sequential = redactor.redact(text)
        #expect(sequential.counts == [.card: 2, .iban: 1, .password: 1, .otp: 1, .secret: 1])

        let shared = redactor
        let results = await withTaskGroup(of: TextRedactor.Redacted.self) { group in
            for _ in 0..<32 {
                group.addTask { shared.redact(text) }
            }
            var all: [TextRedactor.Redacted] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 == sequential })
    }

    @Test("checksums")
    func checksums() {
        #expect(TextRedactor.passesLuhn("4111111111111111"))
        #expect(TextRedactor.passesLuhn("4111 1111 1111 1111"))
        #expect(!TextRedactor.passesLuhn("4111111111111112"))
        #expect(!TextRedactor.passesLuhn("411111111111"))  // 12 digits: too short to be a card
        #expect(TextRedactor.passesIBAN("DE89 3704 0044 0532 0130 00"))
        #expect(TextRedactor.passesIBAN("BR9700360305000010009795493P1"))
        #expect(!TextRedactor.passesIBAN("DE89370400440532013001"))
    }

    /// #53 calls this on every tick, off the main actor, so the budget is a real one. The number
    /// this prints is the one quoted in the PR.
    @Test("3 000 characters redact in well under 5 ms")
    func budget() {
        let unit = "Ana Paula — invoice 8842 — https://app.example.com/inv/8842 — R$ 1.499,90 — "
        var text = ""
        while text.count < 3_000 { text += unit }
        text = String(text.prefix(3_000))
        #expect(text.count == 3_000)

        // Warm the regex engine, then take the best of five: this is a floor measurement, not a
        // benchmark harness, and a cold first call is not what the tick pays.
        _ = redactor.redact(text)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = redactor.redact(text)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print("TextRedactor.redact(3000 chars): \(String(format: "%.3f", best)) ms")
        #expect(best < 5.0)
    }

    // MARK: - URL queries (#332)

    @Test("stripURLQueries drops queries and fragments, with or without a scheme")
    func stripURLQueries() {
        let cases: [(String, String)] = [
            ("[AXTextField] mail.example.com/inbox?token=abc", "[AXTextField] mail.example.com/inbox"),
            ("example.com?q=x&y=1", "example.com"),
            ("HTTPS://Example.com/a?b=1#c", "HTTPS://Example.com/a"),
            ("https://example.com/a#top", "https://example.com/a"),
            ("docs.example.com/guide#install", "docs.example.com/guide"),
            ("open app.example.com:8443/x?id=7 now", "open app.example.com:8443/x now"),
            ("a https://x.example.com/?u=b.example.com?k=1 b", "a https://x.example.com/ b"),
        ]
        for (input, expected) in cases {
            #expect(TextRedactor.stripURLQueries(input) == expected, "\(input)")
        }
    }

    @Test("prose and non-hosts are left byte for byte")
    func stripURLQueriesLeavesProse() {
        let prose = [
            "localhost:8080/a?x=1",
            "Is it example.com?",
            "node.js?",
            "see README.md",
            "e.g. this",
            "v1.2.3?x=1",
            "write to me@example.com?subject=hi",
            "C#",
            "What?",
            "a=b?c=d",
            "example.com#top",
            "Olá, tudo bem? Sim.",
        ]
        for text in prose {
            #expect(Array(TextRedactor.stripURLQueries(text).utf8) == Array(text.utf8), "\(text)")
            #expect(redactor.redact(text).text == text)
        }
    }

    @Test("a scheme-less query goes in redact too, counting nothing unless a secret was in it")
    func redactSchemelessQuery() {
        let plain = redactor.redact("[AXTextField] mail.example.com/inbox?folder=abc")
        #expect(plain.text == "[AXTextField] mail.example.com/inbox")
        #expect(plain.isClean)
        // `token=abc` is a credential assignment of any length, so it counts as it goes.
        let token = redactor.redact("[AXTextField] mail.example.com/inbox?token=abc")
        #expect(token.text == "[AXTextField] mail.example.com/inbox")
        #expect(token.counts == [.secret: 1])

        let secret = redactor.redact("mail.example.com/x?key=sk-live-9f8a7b6c5d4e3f2a1b and sk-live-0a1b2c3d4e5f6a7b8c")
        // The one inside the query goes with it and still counts; the one outside keeps its
        // placeholder, numbered from 1 because nothing was written for the first.
        #expect(secret.text == "mail.example.com/x and [SECRET_1]")
        #expect(secret.counts == [.secret: 2])
    }

    @Test("a secret that only reaches into a dropped query keeps its placeholder, and none of it survives")
    func redactSecretPartlyInQuery() {
        let result = redactor.redact("https://x.example.com/a?auth=Bearer abcdefghijklmnop")
        #expect(result.text == "https://x.example.com/a [SECRET_1]")
        #expect(!result.text.contains("auth"))
        #expect(!result.text.contains("abcdefghijklmnop"))
        #expect(result.counts == [.secret: 1])
    }

    /// A window outline is mostly addresses; the scheme-less rules must not backtrack across them.
    @Test("a URL-dense 3 000-character outline redacts in well under 5 ms")
    func urlDenseBudget() {
        let unit = "[AXLink] docs.example.com/a/b/c/d/e/f/g/h [AXTextField] mail.example.com/inbox/x/y/z?q=1 "
        var text = ""
        while text.count < 3_000 { text += unit }
        text = String(text.prefix(3_000))
        _ = redactor.redact(text)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = redactor.redact(text)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print("TextRedactor.redact(3000 URL-dense chars): \(String(format: "%.3f", best)) ms")
        #expect(best < 5.0)
    }
}
