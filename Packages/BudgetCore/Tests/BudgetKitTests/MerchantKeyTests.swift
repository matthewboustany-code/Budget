import Testing
import BudgetKit

/// `RecurringDetector.normalize` is the merchant key for recurring series and
/// category rules, so the same merchant must key the same however the bank
/// spells it.
struct MerchantKeyTests {
    @Test("Web-style, store-numbered, and plain spellings share one key", arguments: [
        "Netflix", "NETFLIX.COM", "netflix.com", "www.netflix.com", "NETFLIX #123", "Netflix 800-585-8131",
    ])
    func sameMerchant(_ raw: String) {
        #expect(RecurringDetector.normalize(raw) == "netflix")
    }

    @Test func punctuationSeparatesWords() {
        #expect(RecurringDetector.normalize("Uber 063015 SF**POOL**") == "uber sf pool")
        #expect(RecurringDetector.normalize("AMZN Mktp US*2K4") == "amzn mktp us")
    }

    @Test func apostrophesAndAmpersandsJoin() {
        #expect(RecurringDetector.normalize("McDonald's") == "mcdonalds")
        #expect(RecurringDetector.normalize("McDonald\u{2019}s #4521") == "mcdonalds")
        #expect(RecurringDetector.normalize("AT&T Wireless") == "att wireless")
    }

    @Test func keepsTheFirstThreeWords() {
        #expect(RecurringDetector.normalize("Whole Foods Market #10234 Austin") == "whole foods market")
        #expect(RecurringDetector.normalize("#123") == "")
    }

    @Test func legacyKeyIsWhatTheMigrationLooksFor() {
        #expect(RecurringDetector.legacyNormalize("NETFLIX.COM") == "netflixcom")
        #expect(RecurringDetector.legacyNormalize("Uber 063015 SF**POOL**") == "uber sfpool")
    }
}
