//
//  Manufacturer.swift
//  ManicEmu
//
//  Created by Daiuno on 2025/11/12.
//  Copyright © 2025 Manic EMU. All rights reserved.
//



enum Manufacturer: Int, CaseIterable {
    case nintendo, sony, sega, arcade, atari, sun, microsoft, modRetro, nokia, nec, snk, commodore, bandai, adobe
    
    // QoL build: only the makers of the shipped systems (ModRetro = Chromatic, which runs as GB).
    // The other cases stay because their raw values are saved in the theme's manufacturer order.
    static var allCases: [Manufacturer] {
        [.nintendo, .modRetro]
    }
    
    init?(title: String) {
        if let m = Manufacturer.allCases.first(where: { $0.title == title }) {
            self = m
        } else {
            return nil
        }
    }
    
    var title: String {
        switch self {
        case .nintendo:
            "Nintendo"
        case .sony:
            "SONY"
        case .sega:
            "SEGA"
        case .arcade:
            "Arcade"
        case .atari:
            "Atari"
        case .sun:
            "Sun"
        case .microsoft:
            "Microsoft"
        case .modRetro:
            "ModRetro"
        case .nokia:
            "Nokia"
        case .nec:
            "NEC"
        case .snk:
            "SNK"
        case .commodore:
            "Commodore"
        case .bandai:
            "Bandai"
        case .adobe:
            "Adobe"
        }
    }
    
    var gameTypes: [GameType] {
        if self == .modRetro {
            return [.chm]
        }
        return System.allGameTypes.filter({ $0.manufacturer == self })
    }
    
    var normalImage: UIImage {
        switch self {
        case .modRetro:
            R.image.modretro_normal()!
        default:
            R.image.nintendo_normal()!
        }
    }
    
    var highlightImage: UIImage {
        switch self {
        case .modRetro:
            R.image.modretro_highlight()!
        default:
            R.image.nintendo_highlight()!
        }
    }
    
    var iconSize: CGFloat {
        switch self {
        case .nintendo, .arcade, .sun:
            return 25
        case .commodore:
            return 20
        default:
            return 15
        }
    }
}
