import SwiftUI
import AppKit

// MARK: - Цвета

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// Цвет со своими значениями для светлой и тёмной темы.
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        adaptive(NSColor(hex: light), NSColor(hex: dark))
    }
}

enum Palette {
    // Поверхности и текст
    static let page = Color.adaptive(0xf9f9f7, 0x0d0d0d)
    static let card = Color.adaptive(0xfcfcfb, 0x1a1a19)
    static let ink = Color.adaptive(0x0b0b0b, 0xffffff)
    static let ink2 = Color.adaptive(0x52514e, 0xc3c2b7)
    static let muted = Color(hex: 0x898781)
    static let grid = Color.adaptive(0xe1e0d9, 0x2c2c2a)
    static let axis = Color.adaptive(0xc3c2b7, 0x383835)
    static let border = Color.adaptive(NSColor(hex: 0x0b0b0b, alpha: 0.10), NSColor(hex: 0xffffff, alpha: 0.10))

    // Ряды данных — в фиксированном порядке
    static let blue = Color.adaptive(0x2a78d6, 0x3987e5)
    static let orange = Color.adaptive(0xeb6834, 0xd95926)
    static let aqua = Color.adaptive(0x1baf7a, 0x199e70)

    // Состояния — только вместе со значком и подписью
    static let good = Color(hex: 0x0ca30c)
    static let warning = Color(hex: 0xfab219)
    static let serious = Color(hex: 0xec835a)
    static let critical = Color(hex: 0xd03b3b)
}

enum Severity: Int, Comparable {
    case good, warning, serious, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .good: return Palette.good
        case .warning: return Palette.warning
        case .serious: return Palette.serious
        case .critical: return Palette.critical
        }
    }

    var icon: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .serious: return "flame.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// Пороги для кристалла Apple Silicon: троттлинг начинается около 100°.
func tempSeverity(_ t: Double) -> Severity {
    t < 70 ? .good : t < 85 ? .warning : t < 98 ? .serious : .critical
}

func tempLabel(_ t: Double) -> String {
    switch tempSeverity(t) {
    case .good: return "Норма"
    case .warning: return "Тепло"
    case .serious: return "Горячо"
    case .critical: return "Предел"
    }
}

func thermalSeverity(_ level: Int) -> Severity {
    level <= 0 ? .good : level == 1 ? .warning : level == 2 ? .serious : .critical
}

func thermalTitle(_ level: Int) -> String {
    switch level {
    case ...0: return "Норма"
    case 1: return "Умеренный нагрев"
    case 2: return "Сильный нагрев"
    case 3: return "Критический нагрев"
    default: return "Аварийный режим"
    }
}

func thermalDetail(_ level: Int) -> String {
    switch level {
    case ...0: return "macOS не ограничивает производительность."
    case 1: return "macOS начала снижать частоту чипа, чтобы сдержать нагрев."
    case 2: return "Производительность заметно ограничена из-за нагрева."
    default: return "Жёсткое ограничение: система близка к перегреву."
    }
}

// MARK: - Форматирование

private let ruLocale = Locale(identifier: "ru_RU")

func fmtNumber(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", locale: ruLocale, value)
}

func fmtTemp(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))°" } ?? "—"
}

func fmtPct(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

func fmtWatts(_ value: Double?) -> String {
    guard let value else { return "—" }
    let watts = abs(value)
    return fmtNumber(watts, digits: watts >= 10 ? 0 : watts >= 1 ? 1 : 2) + " Вт"
}

func fmtBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return fmtNumber(gb, digits: gb >= 100 ? 0 : 1) + " ГБ" }
    return fmtNumber(Double(bytes) / 1_048_576, digits: 0) + " МБ"
}

func fmtRate(_ bytesPerSecond: Double) -> String {
    let kb = bytesPerSecond / 1024
    if kb >= 1024 { return fmtNumber(kb / 1024, digits: kb >= 10240 ? 0 : 1) + " МБ/с" }
    return fmtNumber(kb, digits: 0) + " КБ/с"
}

func fmtFreq(_ mhz: Double?) -> String {
    guard let mhz else { return "—" }
    return fmtNumber(mhz / 1000, digits: 2) + " ГГц"
}

func fmtMinutes(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
}

// MARK: - Общие элементы

/// Локальное состояние вида — замена @State. В SDK macOS 27 @State стал макросом, плагин которого
/// есть только в Xcode; с одними Command Line Tools он не собирается, а сам тип State доступен.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

struct CardTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.headline).foregroundStyle(Palette.ink)
    }
}

/// Состояние всегда показывается значком и подписью, а не одним цветом.
struct StatusBadge: View {
    let severity: Severity
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severity.icon).foregroundStyle(severity.color)
            Text(label).foregroundStyle(Palette.ink2)
        }
        .font(.caption)
        .fixedSize()
    }
}

/// Полоса заполнения: дорожка — тот же цвет, но светлее.
struct Meter: View {
    let value: Double
    var color: Color = Palette.blue
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                    .opacity(value > 0.004 ? 1 : 0)
            }
        }
        .frame(height: height)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var detail = ""
    var badge: (Severity, String)?
    var meter: Double?
    var meterColor: Color = Palette.blue

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label).font(.subheadline).foregroundStyle(Palette.ink2)
                    Spacer(minLength: 4)
                    if let badge { StatusBadge(severity: badge.0, label: badge.1) }
                }
                Text(value)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // Место под полосу держим всегда, чтобы плитки в ряду были одной высоты.
                Meter(value: meter ?? 0, color: meterColor).opacity(meter == nil ? 0 : 1)
                Text(detail.isEmpty ? " " : detail)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
    }
}

struct KeyValue: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(Palette.ink2)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Palette.ink).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Ключ легенды: цветная метка рядом, сам текст — обычными чернилами.
struct LegendKey: View {
    let color: Color
    let name: String
    var value: String?

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 12, height: 3)
            Text(name).foregroundStyle(Palette.ink2)
            if let value { Text(value).foregroundStyle(Palette.ink).monospacedDigit() }
        }
        .font(.caption)
    }
}
