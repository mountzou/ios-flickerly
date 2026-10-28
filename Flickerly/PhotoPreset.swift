import Foundation

enum PhotoPresetFamily: String, CaseIterable, Identifiable, Sendable {
    case originals
    case paper
    case nilut

    var id: String { rawValue }
    var name: String {
        switch self {
        case .originals: "Originals"
        case .paper: "Paper"
        case .nilut: "NILUT"
        }
    }
    var caption: String {
        switch self {
        case .originals: "Film-inspired looks"
        case .paper: "Soft tones with a printed feel"
        case .nilut: "Colorful looks for a fresh perspective"
        }
    }
    var presets: [PhotoPreset] { PhotoPreset.allCases.filter { $0.family == self } }
}

enum PaperVariant: Equatable, Sendable { case matte, warm, archive }

enum NILUTStyle: Int, CaseIterable, Sendable {
    case style1 = 1
    case style2 = 3
    case style3 = 4
    case natural = 101
    case softWarm = 102
    case coolMatte = 103

    var resourceName: String {
        switch self {
        case .style1: "style-1"
        case .style2: "style-2"
        case .style3: "style-3"
        case .natural: "natural"
        case .softWarm: "soft-warm"
        case .coolMatte: "cool-matte"
        }
    }
}

enum PhotoPreset: String, CaseIterable, Identifiable, Sendable {
    static let blackAndWhite: [PhotoPreset] = [.mono, .silver35, .scratch16, .paperArchive]

    case amber
    case tide
    case mono
    case film35
    case silver35
    case dust35
    case glow800
    case scratch16
    case expired35
    case paper35
    case paperWarm
    case paperArchive
    case nilut1
    case nilut2
    case nilut3
    case nilutNatural
    case nilutSoftWarm
    case nilutCoolMatte

    var id: String { rawValue }
    var name: String {
        switch self {
        case .film35: "Film 35"
        case .silver35: "Silver 35"
        case .dust35: "Dust 35"
        case .glow800: "Glow 800"
        case .scratch16: "Scratch 16"
        case .expired35: "Expired 35"
        case .paper35: "Paper Matte"
        case .paperWarm: "Paper Warm"
        case .paperArchive: "Paper Archive"
        case .nilut1: "NILUT Style 1"
        case .nilut2: "NILUT Style 2"
        case .nilut3: "NILUT Style 3"
        case .nilutNatural: "NILUT Natural"
        case .nilutSoftWarm: "NILUT Soft Warm"
        case .nilutCoolMatte: "NILUT Cool Matte"
        default: rawValue.capitalized
        }
    }

    var number: String {
        switch self {
        case .amber: "01"
        case .tide: "02"
        case .mono: "03"
        case .film35: "04"
        case .silver35: "05"
        case .dust35: "06"
        case .glow800: "07"
        case .scratch16: "08"
        case .expired35: "09"
        case .paper35: "10"
        case .paperWarm: "11"
        case .paperArchive: "12"
        case .nilut1: "13"
        case .nilut2: "14"
        case .nilut3: "15"
        case .nilutNatural: "16"
        case .nilutSoftWarm: "17"
        case .nilutCoolMatte: "18"
        }
    }

    var family: PhotoPresetFamily {
        if nilutStyle != nil { return .nilut }
        return paperVariant == nil ? .originals : .paper
    }

    var nilutStyle: NILUTStyle? {
        switch self {
        case .nilut1: .style1
        case .nilut2: .style2
        case .nilut3: .style3
        case .nilutNatural: .natural
        case .nilutSoftWarm: .softWarm
        case .nilutCoolMatte: .coolMatte
        default: nil
        }
    }

    var paperVariant: PaperVariant? {
        switch self {
        case .paper35: .matte
        case .paperWarm: .warm
        case .paperArchive: .archive
        default: nil
        }
    }

    var code: String {
        switch self {
        case .paper35: "P1"
        case .paperWarm: "P2"
        case .paperArchive: "P3"
        case .nilut1: "N1"
        case .nilut2: "N2"
        case .nilut3: "N3"
        case .nilutNatural: "N4"
        case .nilutSoftWarm: "N5"
        case .nilutCoolMatte: "N6"
        default: number
        }
    }

    var shortName: String {
        switch self {
        case .paper35: "Matte"
        case .paperWarm: "Warm"
        case .paperArchive: "Archive"
        case .nilut1: "Style 1"
        case .nilut2: "Style 2"
        case .nilut3: "Style 3"
        case .nilutNatural: "Natural"
        case .nilutSoftWarm: "Soft Warm"
        case .nilutCoolMatte: "Cool Matte"
        default: name
        }
    }

    var caption: String {
        switch self {
        case .amber: "Warm · soft"
        case .tide: "Cool · clean"
        case .mono: "Timeless · B&W"
        case .film35: "Warm · film grain"
        case .silver35: "B&W · grain"
        case .dust35: "Dust · scratches"
        case .glow800: "Grain · glow"
        case .scratch16: "B&W · scratches"
        case .expired35: "Faded · light leaks"
        case .paper35: "Matte paper · grain"
        case .paperWarm: "Warm · cream paper"
        case .paperArchive: "B&W · patina"
        case .nilut1: "Color · contrast"
        case .nilut2: "Cool · cyan"
        case .nilut3: "Pink · highlights"
        case .nilutNatural: "Depth · clear color"
        case .nilutSoftWarm: "Golden · soft color"
        case .nilutCoolMatte: "Cool · soft blacks"
        }
    }

    var symbol: String {
        switch self {
        case .mono: "circle.lefthalf.filled"
        case .film35, .silver35, .dust35, .scratch16, .expired35: "film"
        case .glow800: "sparkles"
        case .paper35, .paperWarm, .paperArchive: "doc"
        case .nilut1, .nilut2, .nilut3, .nilutNatural, .nilutSoftWarm, .nilutCoolMatte: "slider.horizontal.3"
        case .amber, .tide: "sun.max"
        }
    }
}
