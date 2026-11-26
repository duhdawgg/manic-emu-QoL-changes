//
//  System.swift
//  Delta
//
//  Created by Riley Testut on 4/30/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-or-later



enum System: CaseIterable
{
    // QoL build: only the systems this build ships cores for.
    case _3ds
    case ds
    case gba
    case gbc
    case gb
    
    static var registeredSystems: [System] {
        let systems = System.allCases.filter { Delta.registeredCores.keys.contains($0.gameType) }
        return systems
    }
    
    static var allCores: [DeltaCoreProtocol] {
        return [ThreeDS.core,
                DS.core,
                GBA.core,
                GBC.core,
                GB.core]
    }
    
    ///Returns all supported game types.
    ///By default, it uses the user's sorting order.
    ///If the user has not set a sorting order, it returns them in reverse order based on the sequence of newly added platforms.
    static var allGameTypes: [GameType] {
        let allSystems = System.allCases
        if var gameTypeOrders = R.Config.PlatformOrder {
            if gameTypeOrders.count != allSystems.count {
                let missGameTypes = allSystems.map({
                    $0.gameType.localizedShortName
                }).filter({
                    !gameTypeOrders.contains([$0])
                })
                gameTypeOrders = missGameTypes + gameTypeOrders
            }
            let supported = allSystems.map { $0.gameType }
            return gameTypeOrders.compactMap { GameType(shortName: $0) }.filter { supported.contains($0) }
        } else {
            return allSystems.map { $0.gameType }
        }
    }
}

extension System {
    
    var gameType: GameType {
        switch self
        {
        case ._3ds: return ._3ds
        case .ds: return .ds
        case .gba: return .gba
        case .gbc: return .gbc
        case .gb: return .gb
        }
    }
}
