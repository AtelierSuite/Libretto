import Testing
@testable import LibrettoEngine

@Suite("Number formats")
struct NumberFormatTests {
    private func counted(_ format: String, _ values: [Int]) -> [String] {
        values.map { ListCounter.format($0, as: format) }
    }

    @Test("English ordinals, words and Chicago marks")
    func western() {
        #expect(counted("ordinal", [1, 2, 3, 4, 11, 12, 13, 21, 102]) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "102nd"])
        #expect(counted("cardinalText", [1, 15, 21, 100, 342]) == ["One", "Fifteen", "Twenty-one", "One hundred", "Three hundred forty-two"])
        #expect(counted("ordinalText", [1, 2, 5, 12, 20, 21, 100]) == ["First", "Second", "Fifth", "Twelfth", "Twentieth", "Twenty-first", "One hundredth"])
        #expect(counted("chicago", [1, 2, 3, 4, 5, 9]) == ["*", "†", "‡", "§", "**", "***"])
        #expect(ListCounter.format(7, as: "none") == "")
    }

    @Test("Full-width, enclosed and other scripts' digits")
    func digits() {
        #expect(ListCounter.format(12, as: "decimalFullWidth") == "１２")
        #expect(counted("decimalEnclosedFullstop", [1, 20, 21]) == ["⒈", "⒛", "21"])
        #expect(counted("decimalEnclosedParen", [1, 20]) == ["⑴", "⒇"])
        #expect(ListCounter.format(3, as: "decimalEnclosedCircle") == "③")
        #expect(ListCounter.format(305, as: "ideographDigital") == "三〇五")
        #expect(ListCounter.format(42, as: "hindiNumbers") == "٤٢")
        #expect(ListCounter.format(42, as: "thaiNumbers") == "๔๒")
    }

    @Test("Japanese, Chinese and Korean counting")
    func eastAsian() {
        #expect(counted("japaneseCounting", [1, 10, 11, 20, 100, 101, 110, 1000, 10000, 10001, 110000])
            == ["一", "十", "十一", "二十", "百", "百一", "百十", "千", "一万", "一万一", "十一万"])
        #expect(counted("japaneseLegal", [1, 10, 20, 100]) == ["壱", "壱拾", "弐拾", "壱百"])
        #expect(counted("chineseCounting", [10, 11, 100, 101, 110, 1001, 1010, 10000, 10001, 10100])
            == ["十", "十一", "一百", "一百零一", "一百一十", "一千零一", "一千零一十", "一万", "一万零一", "一万零一百"])
        #expect(counted("chineseLegalSimplified", [10, 105]) == ["壹拾", "壹佰零伍"])
        #expect(counted("koreanCounting", [1, 10, 11, 20, 100]) == ["일", "십", "십일", "이십", "백"])
        #expect(ListCounter.format(10, as: "koreanDigital") == "일영")
    }

    @Test("Kana, ideographic cycles and alphabets count on, then double")
    func sequences() {
        #expect(counted("aiueoFullWidth", [1, 2, 3, 46, 47]) == ["ア", "イ", "ウ", "ン", "アア"])
        #expect(counted("irohaFullWidth", [1, 2, 3]) == ["イ", "ロ", "ハ"])
        #expect(counted("aiueo", [1, 2]) == ["ｱ", "ｲ"])
        #expect(counted("ideographTraditional", [1, 2, 10, 11]) == ["甲", "乙", "癸", "甲"])
        #expect(counted("ideographZodiac", [1, 12, 13]) == ["子", "亥", "子"])
        #expect(counted("ganada", [1, 2, 15]) == ["가", "나", "가가"])
        #expect(counted("russianLower", [1, 2, 10, 29]) == ["а", "б", "к", "аа"])
        #expect(ListCounter.format(3, as: "russianUpper") == "В")
        #expect(counted("hebrew1", [1, 10, 15, 16, 42, 115]) == ["א", "י", "טו", "טז", "מב", "קטו"])
        #expect(counted("hebrew2", [1, 2, 23]) == ["א", "ב", "אא"])
        #expect(counted("arabicAlpha", [1, 2]) == ["أ", "ب"])
        #expect(counted("arabicAbjad", [3]) == ["ج"])
    }
}
