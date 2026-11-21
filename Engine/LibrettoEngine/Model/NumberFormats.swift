import Foundation

/// The `w:numFmt` formats past letters and roman numerals, as Word counts in them.
enum NumberFormats {
    static func format(_ value: Int, as format: String) -> String? {
        switch format {
        case "none": return ""
        case "decimalHalfWidth": return String(value)
        case "ordinal": return ordinal(value)
        case "cardinalText": return capitalised(englishCardinal(value))
        case "ordinalText": return capitalised(englishOrdinal(value))
        case "decimalFullWidth", "decimalFullWidth2": return digits(value, zero: 0xFF10)
        case "decimalEnclosedFullstop": return enclosed(value, first: 0x2488)
        case "decimalEnclosedParen": return enclosed(value, first: 0x2474)
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese", "ideographEnclosedCircle":
            return enclosed(value, first: 0x2460)
        case "hindiNumbers", "arabicIndic": return digits(value, zero: 0x0660)
        case "thaiNumbers": return digits(value, zero: 0x0E50)
        case "hindiCounting": return digits(value, zero: 0x0966)
        case "ideographDigital", "japaneseDigitalTenThousand", "taiwaneseDigital":
            return String(String(value).map { ideographDigits[Int(String($0))!] })
        case "koreanDigital", "koreanDigital2":
            return String(value).map { koreanDigits[Int(String($0))!] }.joined()
        case "japaneseCounting": return eastAsianCounting(value, digits: ideographDigits, style: .japanese)
        case "japaneseLegal": return eastAsianCounting(value, digits: japaneseLegalDigits, style: .japaneseLegal)
        case "chineseCounting", "chineseCountingThousand", "taiwaneseCounting", "taiwaneseCountingThousand", "ideographLegalTraditional":
            return eastAsianCounting(value, digits: ideographDigits, style: .chinese)
        case "chineseLegalSimplified": return eastAsianCounting(value, digits: chineseLegalDigits, style: .chineseLegal)
        case "koreanCounting": return eastAsianCounting(value, digits: koreanCountingDigits, style: .korean)
        case "aiueo": return cycled(value, through: aiueoHalfWidth)
        case "aiueoFullWidth": return cycled(value, through: aiueoFullWidth)
        case "iroha": return cycled(value, through: irohaHalfWidth)
        case "irohaFullWidth": return cycled(value, through: irohaFullWidth)
        case "ideographTraditional": return looped(value, through: "甲乙丙丁戊己庚辛壬癸")
        case "ideographZodiac": return looped(value, through: "子丑寅卯辰巳午未申酉戌亥")
        case "ganada": return cycled(value, through: "가나다라마바사아자차카타파하")
        case "chosung": return cycled(value, through: "ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ")
        case "russianLower": return cycled(value, through: russian)
        case "russianUpper": return cycled(value, through: russian.uppercased())
        case "hebrew1": return hebrewNumeral(value)
        case "hebrew2": return cycled(value, through: "אבגדהוזחטיכלמנסעפצקרשת")
        case "arabicAlpha": return cycled(value, through: "أبتثجحخدذرزسشصضطظعغفقكلمنهوي")
        case "arabicAbjad": return cycled(value, through: "أبجدهوزحطيكلمنسعفصقرشتثخذضظغ")
        case "chicago": return chicago(value)
        default: return nil
        }
    }

    // MARK: - Western

    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 100, value % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    private static func englishCardinal(_ value: Int) -> String {
        guard value >= 0 else { return String(value) }
        if value < 20 { return ones[value] }
        if value < 100 { return tens[value / 10] + (value % 10 == 0 ? "" : "-" + ones[value % 10]) }
        for (size, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand"), (100, "hundred")]
        where value >= size {
            let rest = value % size
            return englishCardinal(value / size) + " " + name + (rest == 0 ? "" : " " + englishCardinal(rest))
        }
        return String(value)
    }

    private static let irregularOrdinals = [
        "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
    ]

    private static func englishOrdinal(_ value: Int) -> String {
        let cardinal = englishCardinal(value)
        // Only the last word changes: twenty-one, twenty-first.
        let split = cardinal.lastIndex { $0 == " " || $0 == "-" }.map { cardinal.index(after: $0) } ?? cardinal.startIndex
        let last = String(cardinal[split...])
        let ordinal: String
        if let irregular = irregularOrdinals[last] {
            ordinal = irregular
        } else if last.hasSuffix("y") {
            ordinal = last.dropLast() + "ieth"
        } else {
            ordinal = last + "th"
        }
        return cardinal[..<split] + ordinal
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func chicago(_ value: Int) -> String {
        guard value > 0 else { return String(value) }
        let marks: [Character] = ["*", "†", "‡", "§"]
        return String(repeating: marks[(value - 1) % 4], count: (value - 1) / 4 + 1)
    }

    // MARK: - Digits and sequences

    private static func digits(_ value: Int, zero: UInt32) -> String {
        String(String(value).unicodeScalars.map { scalar -> Character in
            guard let digit = Int(String(scalar)) else { return Character(scalar) }
            return Character(UnicodeScalar(zero + UInt32(digit))!)
        })
    }

    /// One of the 20 enclosed numbers; plain past them, as Word has it.
    private static func enclosed(_ value: Int, first: UInt32) -> String {
        guard (1...20).contains(value) else { return String(value) }
        return String(Character(UnicodeScalar(first + UInt32(value - 1))!))
    }

    /// A sequence that, once run through, starts over with each sign doubled, as Word's letters do.
    private static func cycled(_ value: Int, through signs: String) -> String {
        let signs = Array(signs)
        guard value > 0 else { return String(value) }
        return String(repeating: signs[(value - 1) % signs.count], count: (value - 1) / signs.count + 1)
    }

    /// A sequence that starts over from its first sign.
    private static func looped(_ value: Int, through signs: String) -> String {
        let signs = Array(signs)
        guard value > 0 else { return String(value) }
        return String(signs[(value - 1) % signs.count])
    }

    private static let russian = "абвгдежзиклмнопрстуфхцчшщэюя"
    private static let aiueoFullWidth = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"
    private static let aiueoHalfWidth = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ"
    private static let irohaFullWidth = "イロハニホヘトチリヌルヲワカヨタレソツネナラムウヰノオクヤマケフコエテアサキユメミシヱヒモセスン"
    private static let irohaHalfWidth = "ｲﾛﾊﾆﾎﾍﾄﾁﾘﾇﾙｦﾜｶﾖﾀﾚｿﾂﾈﾅﾗﾑｳｲﾉｵｸﾔﾏｹﾌｺｴﾃｱｻｷﾕﾒﾐｼｴﾋﾓｾｽﾝ"

    // MARK: - East Asian counting

    private static let ideographDigits: [Character] = Array("〇一二三四五六七八九")
    private static let japaneseLegalDigits: [Character] = Array("〇壱弐参四伍六七八九")
    private static let chineseLegalDigits: [Character] = Array("零壹贰叁肆伍陆柒捌玖")
    private static let koreanDigits = ["영", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구"]
    private static let koreanCountingDigits: [Character] = Array("영일이삼사오육칠팔구")

    private enum CountingStyle {
        case japanese, japaneseLegal, chinese, chineseLegal, korean

        /// Ten, hundred, thousand and ten thousand.
        var units: [Character] {
            switch self {
            case .japanese: return ["十", "百", "千", "万"]
            case .japaneseLegal: return ["拾", "百", "阡", "萬"]
            case .chinese: return ["十", "百", "千", "万"]
            case .chineseLegal: return ["拾", "佰", "仟", "万"]
            case .korean: return ["십", "백", "천", "만"]
            }
        }

        /// Whether a one before ten, a hundred or a thousand is written out.
        var writesLeadingOne: Bool { self == .japaneseLegal || self == .chineseLegal }

        /// Chinese marks a gap in the places with a zero: 一百零一.
        var zero: Character? {
            switch self {
            case .chinese, .chineseLegal: return "零"
            default: return nil
            }
        }
    }

    private static func eastAsianCounting(_ value: Int, digits: [Character], style: CountingStyle) -> String {
        guard value > 0, value < 100_000_000 else { return value == 0 ? String(digits[0]) : String(value) }
        let units = style.units
        /// Up to four places; `leading` when they start the number.
        func group(_ number: Int, leading: Bool) -> String {
            var result = ""
            var gap = false
            var started = false
            for (place, unit) in [(1000, units[2]), (100, units[1]), (10, units[0]), (1, nil)] as [(Int, Character?)] {
                let digit = number / place % 10
                if digit == 0 {
                    if started || !leading { gap = true }
                    continue
                }
                if gap, let zero = style.zero { result.append(zero) }
                gap = false
                // Japanese and Korean leave out the one before ten, a hundred and a thousand;
                // Chinese only before a ten that starts the number.
                let omitsOne = digit == 1 && unit != nil && !style.writesLeadingOne
                    && (style.zero == nil || (place == 10 && leading && !started))
                if !omitsOne { result.append(digits[digit]) }
                if let unit { result.append(unit) }
                started = true
            }
            return result
        }
        let high = value / 10000
        let low = value % 10000
        guard high > 0 else { return group(low, leading: true) }
        var result = style == .korean && high == 1 ? "" : group(high, leading: true)
        result.append(units[3])
        if low > 0 { result += group(low, leading: false) }
        return result
    }

    // MARK: - Hebrew

    private static func hebrewNumeral(_ value: Int) -> String {
        guard value > 0 else { return String(value) }
        var remaining = value % 1000 == 0 ? 1000 : value % 1000
        if remaining == 1000 { return "א׳" }
        var result = ""
        let hundreds: [(Int, String)] = [(400, "ת"), (300, "ש"), (200, "ר"), (100, "ק")]
        for (amount, letter) in hundreds {
            while remaining >= amount {
                result += letter
                remaining -= amount
            }
        }
        // Fifteen and sixteen are written as nine and six, and nine and seven, to avoid spelling the divine name.
        if remaining == 15 { return result + "טו" }
        if remaining == 16 { return result + "טז" }
        let tensLetters = ["", "י", "כ", "ל", "מ", "נ", "ס", "ע", "פ", "צ"]
        let onesLetters = ["", "א", "ב", "ג", "ד", "ה", "ו", "ז", "ח", "ט"]
        return result + tensLetters[remaining / 10] + onesLetters[remaining % 10]
    }
}
